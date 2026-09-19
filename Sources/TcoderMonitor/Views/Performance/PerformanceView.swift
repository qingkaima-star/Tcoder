import SwiftUI

/// OWNER: Workstream C. Rewrite this file.
/// `report` is the selected project so per-project process groups can be matched;
/// live values come from `state.monitor` via `@Environment(AppState.self)`.
struct PerformanceView: View {
    var report: ProjectReport?

    var body: some View {
        EmptyStateView(
            icon: "waveform.path.ecg",
            title: "性能监控 · 开发中",
            message: "由 Workstream C 实现。"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
