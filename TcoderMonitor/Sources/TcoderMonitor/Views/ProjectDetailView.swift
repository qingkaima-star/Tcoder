import SwiftUI

/// 内容区：页头（项目 + 当前状态）+ 页面切换条 + 当前页。
///
/// 本轮把「九页选择」从一个下拉 Picker 换成了玻璃导航条：页名是这九页的**主导航**，
/// 藏在菜单里等于没有导航（对标系统设置的侧栏语义，WS-H §2.2）。
/// 页头不再自造背景色：窗口底色由系统给，内容卡靠材质 + 间距分层（[LG]）。
struct ProjectDetailView: View {
    @Environment(AppState.self) private var state
    @AppStorage("selectedDetailSection") private var sectionRaw: String = DetailSection.overview.rawValue

    private var section: DetailSection { DetailSection(rawValue: sectionRaw) ?? .overview }

    private var sectionBinding: Binding<DetailSection> {
        Binding(
            get: { DetailSection(rawValue: sectionRaw) ?? .overview },
            set: { sectionRaw = $0.rawValue }
        )
    }

    var body: some View {
        @Bindable var state = state

        VStack(spacing: 0) {
            header
            SectionNavBar(selection: sectionBinding,
                          reportAvailable: state.selectedReport != nil)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.bottom, Theme.Spacing.xs)
            Divider()
            content
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestSelectSection)) { note in
            if let target = note.object as? DetailSection { sectionRaw = target.rawValue }
        }
        .onChange(of: state.selectedProjectID) { _, _ in
            maybeAutoScan()
        }
        .onAppear {
            maybeAutoScan()
        }
    }

    /// Scan only when this project has never been attempted. Keying off a missing
    /// section instead would re-scan forever whenever one analyzer legitimately
    /// cannot produce data (a folder that simply isn't a git repo).
    private func maybeAutoScan() {
        guard let project = state.selectedProject, !project.isDemo else { return }
        guard state.store.report(for: project)?.hasBeenScanned == false else { return }
        state.scan(project: project)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
            if let project = state.selectedProject {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(project.name).font(Theme.Typo.pageTitle.font)
                    HStack(spacing: Theme.Spacing.xs) {
                        Text(project.path)
                            .font(Theme.Typo.monoSmall.font)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(project.path)
                        if let scanned = project.lastScanAt {
                            Text("分析于 \(DateFormat.sinceDescription(scanned))")
                                .font(Theme.Typo.label.font)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            } else {
                Text("Tcoder 项目监控").font(Theme.Typo.pageTitle.font)
            }

            Spacer(minLength: Theme.Spacing.md)

            // 表头三态：一次都没扫过就明说「尚未分析」，用 `unverified`（问号）而不是
            // `noRisk`（对勾）—— 对勾会把「没查」渲染成「查过、安全」。
            if state.selectedProject != nil && state.selectedReport == nil && !state.isScanning {
                SemanticBadge(ShellCopy.notAnalyzed("全部指标"),
                              role: Theme.Semantic.neutral,
                              icon: .unverified)
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.top, Theme.Spacing.md)
        .padding(.bottom, Theme.Spacing.xs)
    }

    @ViewBuilder
    private var content: some View {
        if state.selectedProject == nil {
            EmptyStateView(
                icon: IconName.emptyUnknown.rawValue,
                title: "还没有项目",
                message: "在左侧选择本地仓库目录，或加载内置的 Tcoder 示例项目体验完整指标。"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch section {
            case .overview:
                DashboardView()
            case .code:
                CodeMetricsView(report: state.selectedReport)
            case .risk:
                CodeRiskView(report: state.selectedReport)
            case .git:
                GitInsightsView(report: state.selectedReport)
            case .contributors:
                ContributorsView(report: state.selectedReport)
            case .performance:
                PerformanceView(report: state.selectedReport)
            case .logs:
                LogsView(report: state.selectedReport)
            case .dependencies:
                DependenciesView(report: state.selectedReport)
            case .health:
                HealthView(report: state.selectedReport)
            }
        }
    }
}
