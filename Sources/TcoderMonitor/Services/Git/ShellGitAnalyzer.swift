import Foundation

/// OWNER: Workstream B (Git 分析). Rewrite this file.
/// Type name `ShellGitAnalyzer` and protocol conformance are frozen.
final class ShellGitAnalyzer: GitAnalysisProviding {
    func analyze(repositoryURL: URL) async throws -> GitInsights {
        GitInsights()
    }
}
