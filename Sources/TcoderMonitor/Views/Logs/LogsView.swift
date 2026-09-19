import SwiftUI

/// OWNER: Workstream C. Rewrite this file.
struct LogsView: View {
    var report: ProjectReport?

    var body: some View {
        EmptyStateView(
            icon: "doc.text.magnifyingglass",
            title: "错误日志 · 开发中",
            message: "由 Workstream C 实现。"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
