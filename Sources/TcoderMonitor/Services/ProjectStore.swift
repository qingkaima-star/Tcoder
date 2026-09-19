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

    init() {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        storageDirectory = base.appendingPathComponent("TcoderMonitor", isDirectory: true)
        try? fileManager.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        load()
    }

    // MARK: Registry

    var sortedProjects: [MonitoredProject] {
        projects.sorted { lhs, rhs in
            let l = reports[lhs.id]?.health?.overall ?? -1
            let r = reports[rhs.id]?.health?.overall ?? -1
            if l != r { return l > r }
            return lhs.name < rhs.name
        }
    }

    func report(for project: MonitoredProject?) -> ProjectReport? {
        guard let project else { return nil }
        return reports[project.id]
    }

    @discardableResult
    func add(path: String, name: String? = nil, isDemo: Bool = false) -> MonitoredProject {
        let standardizedName = name
            ?? URL(fileURLWithPath: path).lastPathComponent
        if let existing = projects.first(where: { $0.path == path && $0.isDemo == isDemo }) {
            return existing
        }
        let project = MonitoredProject(name: standardizedName, path: path, isDemo: isDemo)
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

    func markPhase(_ phase: AnalysisPhase, for projectID: UUID) {
        guard var report = reports[projectID] else { return }
        report.generatedAt = Date()
        if case .finished = phase { report.project.lastScanAt = Date() }
        reports[projectID] = report
    }

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
