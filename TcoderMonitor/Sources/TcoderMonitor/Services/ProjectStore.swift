import Foundation

/// JSON persistence for the project registry, per-project reports, and score history.
/// Chief-engineer owned: shared by every workstream, so it is frozen.
@MainActor
@Observable
final class ProjectStore {
    private(set) var projects: [MonitoredProject] = []
    private(set) var reports: [UUID: ProjectReport] = [:]
    private(set) var isLoading = false

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    var storageDirectory: URL

    /// 支持目录的解析规则，抽成纯函数以便单测（`TCODER_SUPPORT_DIR` 是本轮为 UI 取证加的隔离入口）。
    ///
    /// 为什么要有这个开关：`~/Library/Application Support/TcoderMonitor` 与 `defaults` 域
    /// `com.tcoder.monitor` 全机唯一，所以任何第二个实例都会与正在运行的实例互相回写覆盖
    /// （AGENTS §7 因此规定"同一时刻只允许一个人启动 App 做验证"）。那条约束直接卡死了
    /// 九页截图取证：本机只要还留着旧实例，取证脚本就必须拒绝跑。
    /// 允许换一个**绝对路径**的支持目录后，取证实例可以写到 /tmp 下自己的沙箱里，
    /// 既不碰用户的项目列表，也不再需要 `e2e_check.sh` 那套"先清空再还原"的危险动作
    /// （那把脚本历史上真清掉过一次用户状态）。
    ///
    /// 只接受绝对路径：相对路径会随进程 CWD 变化而写到意想不到的地方，那比没有这个开关更糟。
    static func resolveStorageDirectory(environment: [String: String],
                                        applicationSupport base: URL) -> URL {
        let fallback = base.appendingPathComponent("TcoderMonitor", isDirectory: true)
        guard let override = environment["TCODER_SUPPORT_DIR"], override.isEmpty == false else {
            return fallback
        }
        guard override.hasPrefix("/") else { return fallback }
        return URL(fileURLWithPath: override, isDirectory: true)
    }

    init() {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        storageDirectory = ProjectStore.resolveStorageDirectory(
            environment: ProcessInfo.processInfo.environment, applicationSupport: base)
        try? fileManager.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        load()
    }

    // MARK: Registry

    func report(for project: MonitoredProject?) -> ProjectReport? {
        guard let project else { return nil }
        return reports[project.id]
    }

    @discardableResult
    func add(path: String, name: String? = nil) -> MonitoredProject {
        let standardizedName = name
            ?? URL(fileURLWithPath: path).lastPathComponent
        if let existing = projects.first(where: { $0.path == path }) {
            return existing
        }
        let project = MonitoredProject(name: standardizedName, path: path)
        projects.append(project)
        reports[project.id] = ProjectReport(project: project)
        persist()
        return project
    }

    func remove(_ project: MonitoredProject) {
        projects.removeAll { $0.id == project.id }
        reports[project.id] = nil
        try? fileManager.removeItem(at: reportURL(for: project.id))
        persist()
    }

    /// 改名。**UI 里目前没有入口**（右键菜单只有「在 Finder 中显示」与「移除」），
    /// 但它是「注册表与报告里的 `project` 必须同步」这条不变式唯一的 exerciser
    /// （`ProjectStoreRoundTripTests` 的生命周期用例靠它断言"两处显示不同名字"），
    /// 所以留着；要做「重命名项目」这个功能时，入口 + 输入框 + 双语键一起补。
    func rename(_ project: MonitoredProject, to newName: String) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index].name = newName
        reports[project.id]?.project = projects[index]
        persist()
    }

    func upsertReport(_ report: ProjectReport) {
        var updated = report
        updated.project.lastScanAt = report.generatedAt
        if let index = projects.firstIndex(where: { $0.id == report.project.id }) {
            projects[index].lastScanAt = report.generatedAt
            updated.project = projects[index]
        }
        reports[report.project.id] = updated
        save(report: updated)
        persist()
    }

    // `markPhase(_:for:)` 已于批次 P7-C 删除：它全仓零调用者，
    // 存在的全部理由是给那五档"正在做哪一路"的假顺序进度落盘用的。
    // 真正写 `lastScanAt` 的是 `upsertReport`，那条链路完好。

    /// Append-only history of overall scores, used by the trend chart.
    func scoreHistory(for projectID: UUID) -> [ScoreHistoryPoint] {
        (scoreHistoryCache[projectID] ?? []).sorted { $0.date < $1.date }
    }

    func recordScore(_ score: Int, for projectID: UUID, projectName: String) {
        var history = scoreHistoryCache[projectID] ?? []
        if let last = history.last, abs(last.date.timeIntervalSinceNow) < 60, last.score == score {
            return
        }
        history.append(ScoreHistoryPoint(date: Date(), score: score, projectName: projectName))
        if history.count > 240 { history.removeFirst(history.count - 240) }
        scoreHistoryCache[projectID] = history
        persistHistory()
    }

    // MARK: Persistence

    private struct PersistedState: Codable {
        var projects: [MonitoredProject]
        var selectedProjectID: UUID?
    }

    private var scoreHistoryCache: [UUID: [ScoreHistoryPoint]] = [:]
    private var selectedProjectID: UUID?

    private var registryURL: URL { storageDirectory.appendingPathComponent("projects.json") }
    private var historyURL: URL { storageDirectory.appendingPathComponent("score-history.json") }
    private var reportsDirectory: URL { storageDirectory.appendingPathComponent("reports", isDirectory: true) }

    private func reportURL(for id: UUID) -> URL {
        reportsDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    private func load() {
        isLoading = true
        defer { isLoading = false }

        if let data = try? Data(contentsOf: registryURL),
           let decoded = try? decoder.decode(PersistedState.self, from: data) {
            projects = decoded.projects
            selectedProjectID = decoded.selectedProjectID
        }
        if let data = try? Data(contentsOf: historyURL),
           let decoded = try? decoder.decode([UUID: [ScoreHistoryPoint]].self, from: data) {
            scoreHistoryCache = decoded
        }

        try? fileManager.createDirectory(at: reportsDirectory, withIntermediateDirectories: true)
        for project in projects {
            if let data = try? Data(contentsOf: reportURL(for: project.id)),
               let report = try? decoder.decode(ProjectReport.self, from: data) {
                reports[project.id] = report
            } else {
                reports[project.id] = ProjectReport(project: project)
            }
        }
    }

    func save(report: ProjectReport) {
        guard let data = try? encoder.encode(report) else { return }
        try? data.write(to: reportURL(for: report.project.id), options: .atomic)
    }

    private func persist() {
        let state = PersistedState(projects: projects, selectedProjectID: selectedProjectID)
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: registryURL, options: .atomic)
    }

    private func persistHistory() {
        guard let data = try? encoder.encode(scoreHistoryCache) else { return }
        try? data.write(to: historyURL, options: .atomic)
    }

    func setSelectedProject(_ id: UUID?) {
        selectedProjectID = id
        persist()
    }

    func selectedProjectIDValue() -> UUID? { selectedProjectID }
}

struct ScoreHistoryPoint: Codable, Equatable, Identifiable, Sendable {
    var date: Date
    var score: Int
    var projectName: String

    var id: Date { date }
}
