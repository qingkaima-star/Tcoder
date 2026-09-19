import Foundation

/// OWNER: Workstream C (日志分析). Rewrite this file.
/// Type name `FileLogAnalyzer` and protocol conformance are frozen.
final class FileLogAnalyzer: LogAnalysisProviding {
    func analyze(projectRoot: URL, extraLogURLs: [URL], withinDays: Int) async throws -> LogSummary {
        LogSummary()
    }
}
