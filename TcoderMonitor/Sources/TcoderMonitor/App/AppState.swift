import AppKit
import SwiftUI
import Observation

/// Root application model. Chief-engineer owned — workstreams must not edit this file;
/// they implement the service protocols and the views they are assigned.
/// 本轮（性能轮 P 包）例外：T3 交互期暂停的**接线**只能在编排器里做，页面零改动。
@MainActor
@Observable
final class AppState {
    let store: ProjectStore
    let monitor: MachSystemMonitor

    private let codeAnalyzer = FileSystemCodeAnalyzer()
    private let gitAnalyzer = ShellGitAnalyzer()
    private let logAnalyzer = FileLogAnalyzer()
    private let dependencyAnalyzer = ManifestDependencyAnalyzer()
    private let coverageAnalyzer = CoverageAnalyzer()
    private let healthScorer = WeightedHealthScorer()

    var selectedProjectID: UUID? {
        didSet { store.setSelectedProject(selectedProjectID) }
    }
    var phase: AnalysisPhase = .idle
    var isScanning = false
    var lastError: String?
    var allowNetworkLookups = false
    var logWindowDays = 7

    /// Per-project extra log files chosen by the user (Logs/error.log, crash.log …).
    var extraLogURLs: [UUID: [URL]] = [:]

    static let demoProjectPath = "demo://tcoder-sample"

    // MARK: T3 交互期暂停（滚动 / 拖窗 / resize 期间冻结实时写入）
    //
    // 规范红线四条都落在这段代码里：
    // 1. **只在 `AppState` 实现**：用 `NSEvent` 本地监视器 + `NSWindow` 通知，macOS 14 就有，
    //    不用 macOS 15+ 的 `onScrollPhaseChange`；页面零改动、`Design/**` 零新增 `#available`。
    // 2. **引用计数式**：`MachSystemMonitor` 持票，这里只是其中一个持票人；
    //    切页 / 拖窗与滚动同时在场上时，谁结束都不许提前解冻另一个。
    // 3. **停止 150 毫秒后恢复**：每个事件都重置自己那一源的沉降定时器，
    //    滚动条一路拖就一直暂停，手放开 150 ms 才恢复写界面。
    // 4. **暂停期跳过的帧仍要进环形缓冲**：这里只按"要不要写界面"，
    //    采集与入环在 `MachSystemMonitor.ingest` 里照旧逐帧发生，
    //    恢复后曲线是完整真实轨迹，既没有 0 也没有空白。

    /// 交互停止多久之后恢复实时写入。
    nonisolated static let interactionSettleNanoseconds: UInt64 = 150_000_000

    @ObservationIgnored private var pointerEventMonitor: Any?
    @ObservationIgnored private var windowObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var pointerSettleTask: Task<Void, Never>?
    @ObservationIgnored private var windowSettleTask: Task<Void, Never>?

    init() {
        store = ProjectStore()
        monitor = MachSystemMonitor()
        // 节拍数值只在 `MachSystemMonitor.defaultSampleIntervalMilliseconds` 定义一次
        // （性能 spec §5.1）；这里再写一个 1_500 就是第二个真值来源。
        monitor.start(intervalMilliseconds: MachSystemMonitor.defaultSampleIntervalMilliseconds)
        // 第四轮性能尺子的**产品侧唯一接线点**（`FramePulse.swift` 自己的注释就指定在这里）。
        // 这里不写的话，`FramePulse` 就是一个**产品代码零调用**的实现文件 —— 而 `AGENTS.md`
        // 第四轮红线 8 明写「必须接线进产品代码后才允许合入」。实测过后果：它靠 5 处无关的
        // `NSWorkspace.shared` 白拿了「④static 简写」证据混过可达性守卫，那把尺子其实是空的。
        // 默认零开销：只有 `TCODER_PERF_PROBE=1` 时 `startIfNeeded()` 才建 `displayLink`，
        // 否则立刻返回 false、无任何副作用（由 `PerfHitchGuardTests` 两条用例钉住）。
        FramePulse.shared.startIfNeeded()
        startInteractionGating()
        bootstrapIfNeeded()
    }

    /// 装上交互监视器。`AppState` 与 App 同生命周期，所以故意不摘：
    /// 摘掉就等于把 T3 的暂停关掉。
    private func startInteractionGating() {
        guard pointerEventMonitor == nil else { return }
        // 只监视"用户正在拖着东西"的事件：滚动与三种拖拽。返回事件本身，绝不吞掉。
        pointerEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.scrollWheel, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.notePointerStreamActivity() }
            return event
        }

        let center = NotificationCenter.default
        // live resize 与拖标题栏移动窗口都不走本 App 的事件流（窗口服务器在处理它们），
        // 所以这两条得靠窗口通知补，否则"拖窗不掉帧"这一半根本没被监视到。
        let windowKinds: [NSNotification.Name] = [NSWindow.willStartLiveResizeNotification,
                                                  NSWindow.didEndLiveResizeNotification,
                                                  NSWindow.didMoveNotification]
        for name in windowKinds {
            windowObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.noteWindowActivity() }
            })
        }
    }

    /// 滚动 / 拖拽：每一帧事件都续一次票，并重置 150 ms 沉降定时器。
    private func notePointerStreamActivity() {
        monitor.beginInteractionPause(.pointerStream)
        pointerSettleTask?.cancel()
        pointerSettleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: AppState.interactionSettleNanoseconds)
            guard !Task.isCancelled else { return }
            self?.monitor.endInteractionPause(.pointerStream)
        }
    }

    /// 拖窗 / 改变窗口尺寸：live resize 开始即暂停，结束（或移动事件沉降）后 150 ms 归还票。
    private func noteWindowActivity() {
        monitor.beginInteractionPause(.windowDrag)
        windowSettleTask?.cancel()
        windowSettleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: AppState.interactionSettleNanoseconds)
            guard !Task.isCancelled else { return }
            self?.monitor.endInteractionPause(.windowDrag)
        }
    }

    /// 选中项目的**唯一**判定处：落盘选中（仍存在于列表里）> 第一个非示例项目 > 第一个。
    /// 示例项目的数字是编的，真实项目在场时它不许抢到展示位——今天连着两次把假读数
    /// 当成实测呈现给用户，用户因此问"为什么有 Java"。
    nonisolated static func preferredProjectID(in projects: [MonitoredProject], stored: UUID?) -> UUID? {
        if let stored, projects.contains(where: { $0.id == stored }) { return stored }
        return (projects.first(where: { $0.isDemo == false }) ?? projects.first)?.id
    }

    var selectedProject: MonitoredProject? {
        guard let id = Self.preferredProjectID(in: store.projects, stored: selectedProjectID) else { return nil }
        return store.projects.first(where: { $0.id == id })
    }

    var selectedReport: ProjectReport? {
        store.report(for: selectedProject)
    }

    var hasProjects: Bool { !store.projects.isEmpty }

    // MARK: - Lifecycle

    private func bootstrapIfNeeded() {
        if store.projects.isEmpty {
            // First run: seed the built-in sample so the dashboard is immediately
            // legible before the user points at a real repository.
            loadDemoProject()
            return
        }
        guard selectedProjectID == nil else { return }
        selectedProjectID = Self.preferredProjectID(in: store.projects, stored: store.selectedProjectIDValue())
    }

    // MARK: - Project management

    func addProject(at url: URL) {
        let project = store.add(path: url.path)
        selectedProjectID = project.id
        scan(project: project)
    }

    func loadDemoProject() {
        let project = DemoData.makeProject(in: store)
        selectedProjectID = project.id
        DemoData.install(into: store, project: project)
    }

    func removeProject(_ project: MonitoredProject) {
        store.remove(project)
        extraLogURLs[project.id] = nil
        if selectedProjectID == project.id {
            selectedProjectID = store.projects.first?.id
        }
    }

    func attachLogFiles(to projectID: UUID, urls: [URL]) {
        extraLogURLs[projectID, default: []].append(contentsOf: urls)
    }

    func clearAttachedLogs(for projectID: UUID) {
        extraLogURLs[projectID] = nil
    }

    // MARK: - Scanning

    /// Fan out every analyzer at once, then merge. Analyzer failures are isolated so
    /// one bad repository (no git, no logs) still yields a usable dashboard.
    func scan(project: MonitoredProject) {
        guard !isScanning else { return }
        guard !project.isDemo else {
            lastError = "示例项目已内置数据，无需扫描。"
            return
        }

        isScanning = true
        phase = .code
        lastError = nil

        let root = project.url
        let report = store.report(for: project) ?? ProjectReport(project: project)
        let previousScore = report.health?.overall
        let logURLs = extraLogURLs[project.id] ?? []
        let windowDays = logWindowDays
        let network = allowNetworkLookups

        let codeAnalyzer = self.codeAnalyzer
        let gitAnalyzer = self.gitAnalyzer
        let logAnalyzer = self.logAnalyzer
        let dependencyAnalyzer = self.dependencyAnalyzer
        let coverageAnalyzer = self.coverageAnalyzer

        Task.detached(priority: .userInitiated) { [weak self] in
            async let code = Self.attempt("代码扫描") { try await codeAnalyzer.analyze(root: root, options: .default) }
            async let git = Self.attempt("Git 分析") { try await gitAnalyzer.analyze(repositoryURL: root) }
            async let logs = Self.attempt("日志分析") { try await logAnalyzer.analyze(projectRoot: root, extraLogURLs: logURLs, withinDays: windowDays) }
            async let deps = Self.attempt("依赖分析") { try await dependencyAnalyzer.analyze(projectRoot: root, allowNetwork: network) }
            async let coverage = Self.attempt("覆盖率读取") { try await coverageAnalyzer.analyze(projectRoot: root, options: .default) }

            let codeResult = await code
            let gitResult = await git
            let logResult = await logs
            let depsResult = await deps
            let coverageResult = await coverage

            let inputs = HealthInputs(
                code: codeResult.value,
                git: gitResult.value,
                logs: logResult.value,
                dependencies: depsResult.value,
                coverage: coverageResult.value,
                previousScore: previousScore
            )

            await MainActor.run { [weak self] in
                guard let self else { return }
                var merged = ProjectReport(project: project)
                merged.code = codeResult.value
                merged.git = gitResult.value
                merged.logs = logResult.value
                merged.dependencies = depsResult.value
                merged.coverage = coverageResult.value
                merged.health = self.healthScorer.score(inputs)
                merged.generatedAt = Date()
                merged.attemptedAt = Date()

                let failures = Self.sectionFailures([
                    (codeResult.error, "代码扫描"),
                    (gitResult.error, "Git 分析"),
                    (logResult.error, "错误日志"),
                    (depsResult.error, "依赖分析"),
                    (coverageResult.error, "测试覆盖率"),
                ])
                merged.failedSections = failures.sections

                self.store.upsertReport(merged)
                if let score = merged.health?.overall {
                    self.store.recordScore(score, for: project.id, projectName: project.name)
                }
                self.phase = .finished
                self.isScanning = false
                self.lastError = failures.problems.isEmpty ? nil : failures.problems.joined(separator: " · ")
            }
        }
    }

    func scanSelected() {
        guard let selectedProject else { return }
        if selectedProject.isDemo {
            loadDemoProject()
            return
        }
        scan(project: selectedProject)
    }

    /// 五路分析各自的失败 → 「一条问题清单 + 一份缺席名单」。
    ///
    /// 搬出来的理由是机械的：这五段 `if let` 让 `scan` 被本 App 自扫点名 CC 17。
    /// 顺序、文案、`failedSections` 的取值全部保持原样（顺序由调用方传入的数组决定）。
    private static func sectionFailures(_ items: [(error: String?, section: String)])
        -> (problems: [String], sections: [String]) {
        items.reduce(into: ([String](), [String]())) { acc, item in
            guard let error = item.error else { return }
            acc.0.append(error)
            acc.1.append(item.section)
        }
    }

    private static func attempt<T: Sendable>(
        _ name: String,
        _ work: @Sendable () async throws -> T
    ) async -> (value: T?, error: String?) {
        do {
            return (try await work(), nil)
        } catch {
            return (nil, "\(name)失败：\(error.localizedDescription)")
        }
    }
}
