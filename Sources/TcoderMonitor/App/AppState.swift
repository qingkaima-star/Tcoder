import SwiftUI
import Observation

/// Root application model. Chief-engineer owned — workstreams must not edit this file;
/// they implement the service protocols and the views they are assigned.
@MainActor
@Observable
final class AppState {
    let store: ProjectStore
    let monitor: MachSystemMonitor

    private let codeAnalyzer = FileSystemCodeAnalyzer()
    private let gitAnalyzer = ShellGitAnalyzer()
    private let logAnalyzer = FileLogAnalyzer()
    private let dependencyAnalyzer = ManifestDependencyAnalyzer()
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

    init() {
        store = ProjectStore()
        monitor = MachSystemMonitor()
        monitor.start(intervalMilliseconds: 1_500)
        bootstrapIfNeeded()
    }

    var selectedProject: MonitoredProject? {
        if let id = selectedProjectID, let found = store.projects.first(where: { $0.id == id }) {
            return found
        }
        return store.projects.first
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
        selectedProjectID = store.selectedProjectIDValue() ?? store.projects.first?.id
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

        Task.detached(priority: .userInitiated) { [weak self] in
            async let code = Self.attempt("代码扫描") { try await codeAnalyzer.analyze(root: root, options: .default) }
            async let git = Self.attempt("Git 分析") { try await gitAnalyzer.analyze(repositoryURL: root) }
            async let logs = Self.attempt("日志分析") { try await logAnalyzer.analyze(projectRoot: root, extraLogURLs: logURLs, withinDays: windowDays) }
            async let deps = Self.attempt("依赖分析") { try await dependencyAnalyzer.analyze(projectRoot: root, allowNetwork: network) }

            let codeResult = await code
            let gitResult = await git
            let logResult = await logs
            let depsResult = await deps

            let inputs = HealthInputs(
                code: codeResult.value,
                git: gitResult.value,
                logs: logResult.value,
                dependencies: depsResult.value,
                previousScore: previousScore
            )

            await MainActor.run { [weak self] in
                guard let self else { return }
                var merged = ProjectReport(project: project)
                merged.code = codeResult.value
                merged.git = gitResult.value
                merged.logs = logResult.value
                merged.dependencies = depsResult.value
                merged.health = self.healthScorer.score(inputs)
                merged.generatedAt = Date()

                var problems: [String] = []
                if let error = codeResult.error { problems.append(error) }
                if let error = gitResult.error { problems.append(error) }
                if let error = logResult.error { problems.append(error) }
                if let error = depsResult.error { problems.append(error) }

                self.store.upsertReport(merged)
                if let score = merged.health?.overall {
                    self.store.recordScore(score, for: project.id, projectName: project.name)
                }
                self.phase = .finished
                self.isScanning = false
                self.lastError = problems.isEmpty ? nil : problems.joined(separator: " · ")
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
