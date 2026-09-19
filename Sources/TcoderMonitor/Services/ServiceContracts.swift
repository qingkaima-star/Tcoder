import Foundation

// MARK: - Frozen service contracts
//
// Implementations live in one owner file each and are dispatched concurrently.
// Signatures here are FROZEN — do not add, rename, or reorder requirements.
// If an implementation needs more input, add a defaulted parameter to its own
// concrete type, never to these protocols.

protocol CodeAnalysisProviding: AnyObject {
    /// Walk the tree once and produce size + complexity + duplication + marker counts.
    func analyze(root: URL, options: ScanOptions) async throws -> CodeMetrics
}

protocol GitAnalysisProviding: AnyObject {
    func analyze(repositoryURL: URL) async throws -> GitInsights
}

protocol LogAnalysisProviding: AnyObject {
    /// - Parameter extraLogURLs: user-chosen files in addition to auto-discovery.
    func analyze(projectRoot: URL, extraLogURLs: [URL], withinDays: Int) async throws -> LogSummary
}

protocol DependencyAnalysisProviding: AnyObject {
    func analyze(projectRoot: URL, allowNetwork: Bool) async throws -> DependencyReport
}

protocol HealthScoringProviding: AnyObject {
    func score(_ inputs: HealthInputs) -> HealthScore
}

/// Runtime monitor is long-lived rather than one-shot, so it exposes observables directly.
protocol SystemMonitoringProviding: AnyObject {
    var latestSnapshot: SystemSnapshot? { get }
    var history: [SystemSnapshot] { get }
    var topProcesses: [ProcessSnapshot] { get }
    var trackedGroups: [ProcessGroupSnapshot] { get }
    var isRunning: Bool { get }

    func start(intervalMilliseconds: UInt64)
    func stop()
    /// Recompute one sample synchronously and return it (used by manual refresh).
    @discardableResult
    func sampleNow() -> SystemSnapshot?
}

enum AnalysisError: LocalizedError, Equatable {
    case notDirectory(String)
    case notGitRepository(String)
    case gitBinaryMissing
    case unreadableFile(String)
    case cancelled
    case timedOut(String)
    case empty(String)
    case networkUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .notDirectory(let p): return "路径不是有效目录：\(p)"
        case .notGitRepository(let p): return "该目录不是 Git 仓库：\(p)"
        case .gitBinaryMissing: return "未找到 git 可执行文件，请确认已安装 Xcode 命令行工具"
        case .unreadableFile(let p): return "文件无法读取：\(p)"
        case .cancelled: return "扫描已取消"
        case .timedOut(let what): return "\(what) 超时"
        case .empty(let what): return "\(what) 没有可用数据"
        case .networkUnavailable(let why): return "网络请求不可用：\(why)"
        }
    }
}
