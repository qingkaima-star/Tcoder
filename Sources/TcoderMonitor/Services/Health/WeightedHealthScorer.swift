import Foundation

/// OWNER: Workstream C (健康评分). Rewrite this file.
/// Type name `WeightedHealthScorer` and protocol conformance are frozen.
final class WeightedHealthScorer: HealthScoringProviding {
    func score(_ inputs: HealthInputs) -> HealthScore {
        HealthScore(overall: 0)
    }
}
