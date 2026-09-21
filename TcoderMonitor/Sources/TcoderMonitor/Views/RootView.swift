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

    /// 顶栏本身由系统在 macOS 26 上画成玻璃，这里不自造窗口背景（[LG]）；
    /// 但**按钮要主动升到控件层**，否则它是普通边框控件，跟侧栏选中行、导航条
    /// 那两枚玻璃胶囊不是一套材质（第二轮目视结论 3）。
    /// 多个玻璃控件用 `mergedGlassChrome` 归并折射，这也是 [LG] 的明确要求。
    ///
    /// 符号一律走 `IconName`：「重新分析」`arrow.clockwise`，采样刷新
    /// `arrow.triangle.2.circlepath`，两个语义不再混用（WS-I §7.2 冲突 1）。
    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            mergedGlassChrome(spacing: Theme.Spacing.xs) {
                Button {
                    state.scanSelected()
                } label: {
                    Label("重新分析", systemImage: IconName.reanalyze.rawValue)
                }
                .buttonStyle(.plain)
                .glassButtonStyle(.bordered)
                .disabled(state.isScanning || state.selectedProject == nil)
                .help("对当前项目重新执行全部分析器")

                if state.isScanning {
                    ProgressOverlay(phase: state.phase,
                                    projectName: state.selectedProject?.name ?? "当前项目",
                                    completedSections: state.completedSections)
                }
            }
        }
    }
}
