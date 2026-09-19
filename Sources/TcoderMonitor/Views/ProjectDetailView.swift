import SwiftUI

struct ProjectDetailView: View {
    @Environment(AppState.self) private var state
    @State private var section: DetailSection = .overview

    var body: some View {
        @Bindable var state = state

        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Theme.subtleBackground)
        .onReceive(NotificationCenter.default.publisher(for: .requestSelectSection)) { note in
            if let target = note.object as? DetailSection { section = target }
        }
        .onChange(of: state.selectedProjectID) { _, _ in
            if let project = state.selectedProject, !project.isDemo, state.store.report(for: project)?.code == nil {
                state.scan(project: project)
            }
        }
        .onAppear {
            if let project = state.selectedProject, !project.isDemo,
               state.store.report(for: project)?.code == nil {
                state.scan(project: project)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let project = state.selectedProject {
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name).font(.title2.weight(.semibold))
                    HStack(spacing: 6) {
                        Text(project.path)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMargin()
                        if let scanned = project.lastScanAt {
                            Text("· 分析于 \(DateFormat.sinceDescription(scanned))")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            } else {
                Text("Tcoder 项目监控").font(.title2.weight(.semibold))
            }

            Spacer()

            Picker("视图", selection: $section) {
                ForEach(DetailSection.allCases) { item in
                    Label(item.title, systemImage: item.icon).tag(item)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 150)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if state.selectedProject == nil {
            EmptyStateView(
                icon: "square.stack.3d.up",
                title: "还没有项目",
                message: "点击左下角「添加项目」选择本地仓库目录，\n或加载内置的 Tcoder 示例项目 示例项目体验完整指标。"
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

private extension View {
    /// Keeps long paths from pushing the header width open.
    func truncationMargin() -> some View {
        self.lineLimit(1)
    }
}
