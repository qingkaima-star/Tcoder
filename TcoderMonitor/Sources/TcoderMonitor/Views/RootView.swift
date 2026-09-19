import SwiftUI

/// 窗口骨架：侧栏（项目列表）+ 内容（页面切换 + 当前页）。
///
/// 三条流把 `Views/` 切成三块，本文件只负责**外壳**：列宽、导航样式、窗口工具栏。
/// 项目行、实时读数、页面切换条都在 `Views/Shell/**`。
struct RootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        NavigationSplitView {
            ProjectSidebar(selection: $state.selectedProjectID)
                .navigationSplitViewColumnWidth(
                    min: ShellLayout.sidebarMinWidth,
                    ideal: ShellLayout.sidebarIdealWidth,
                    max: ShellLayout.sidebarMaxWidth)
        } detail: {
            ProjectDetailView()
                .toolbar { detailToolbar }
        }
        .navigationSplitViewStyle(.balanced)
    }

    /// 窗口工具栏不自造背景：macOS 26 的系统工具栏本身就是玻璃，
    /// 这里塞自定义材质只会跟系统抢同一层（[LG]）。符号一律走 `IconName`，
    /// 「重新分析」用 `arrow.clockwise`，采样刷新用 `arrow.triangle.2.circlepath`，
    /// 两个语义不再混用（WS-I §7.2 冲突 1）。
    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                state.scanSelected()
            } label: {
                Label("重新分析", systemImage: IconName.reanalyze.rawValue)
            }
            .disabled(state.isScanning || state.selectedProject == nil)
            .help("对当前项目重新执行全部分析器")
        }
        if state.isScanning {
            ToolbarItem(placement: .primaryAction) {
                ProgressOverlay(phase: state.phase,
                                projectName: state.selectedProject?.name ?? "当前项目")
            }
        }
    }
}
