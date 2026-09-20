import SwiftUI

/// 内容区：页头（项目 + 当前状态）+ 当前页。
///
/// **本轮（WS-O / M1）两件事**（spec §3）：
///   1. 页头下面那条九页 chip 条和它那条 `Divider()` 删了 —— 导航搬进侧栏的
///      `Section("分析视图")`，腾出的 44pt 还给内容区。页头不再自造背景色。
///   2. 全仓**第一次**把 `Theme.Palette.Surface.ground` 接到内容滚动容器上
///      （风格契约 1「单一地面」）。基座 M0 只定义了这个令牌不接线，
///      因为在 M0 就硬断言会逼出「为了过门随手涂一个 background」的假接线。
///      地面只有一层：往下各页不得再有第二种填充色，唯一例外是实心井 `.contentInset`。
struct ProjectDetailView: View {
    @Environment(AppState.self) private var state
    @AppStorage("selectedDetailSection") private var sectionRaw: String = DetailSection.overview.rawValue

    private var section: DetailSection { DetailSection(rawValue: sectionRaw) ?? .overview }

    var body: some View {
        @Bindable var state = state

        VStack(spacing: 0) {
            header
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.Surface.ground)
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

    /// 页头：项目名是这一列唯一的主角（`pageTitle` 20），
    /// 路径与分析时间收成**一行** `label`(11)。
    /// 二者都是元数据，可以走 `.tertiary`；测得值不行（风格契约 4）。
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
            if let project = state.selectedProject {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(project.name).font(Theme.Typo.pageTitle.font)
                    HStack(spacing: Theme.Spacing.xs) {
                        Text(project.path)
                            .font(Theme.Typo.label.font.monospacedDigit())
                            // 红线允许路径/时间戳用 `.tertiary`，但 17:25 深色实拍实测：
                            // 11pt 元数据在 `#1C1C1E` 上几乎读不出。基座自己也已经把
                            // `MetricTile` 的 caption 从 tertiary 升到 secondary，这里跟同一档。
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(project.path)
                        if let scanned = project.lastScanAt {
                            Text("·")
                                .font(Theme.Typo.label.font)
                                .foregroundStyle(.tertiary)
                            Text("分析于 \(DateFormat.sinceDescription(scanned))")
                                .font(Theme.Typo.label.font.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text("Tcoder").font(Theme.Typo.pageTitle.font)
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
        .padding(.horizontal, Theme.Spacing.pageMargin)
        .padding(.top, Theme.Spacing.lg)
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
