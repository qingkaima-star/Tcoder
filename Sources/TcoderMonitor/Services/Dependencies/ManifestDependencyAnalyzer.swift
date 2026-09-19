import Foundation

/// OWNER: Workstream B (依赖分析). Rewrite this file.
/// Type name `ManifestDependencyAnalyzer` and protocol conformance are frozen.
final class ManifestDependencyAnalyzer: DependencyAnalysisProviding {
    func analyze(projectRoot: URL, allowNetwork: Bool) async throws -> DependencyReport {
        DependencyReport()
    }
}
