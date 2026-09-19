import SwiftUI

/// OWNER: Workstream C. Rewrite this file.
struct HealthView: View {
    var report: ProjectReport?

    var body: some View {
        EmptyStateView(
            icon: "checkmark.shield.fill",
            title: "健康评分 · 开发中",
            message: "由 Workstream C 实现。"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
