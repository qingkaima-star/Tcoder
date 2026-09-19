import SwiftUI
import AppKit

enum DetailSection: String, CaseIterable, Identifiable, Sendable {
    case overview = "总览"
    case code = "代码规模"
    case risk = "复杂度风险"
    case git = "Git 洞察"
    case contributors = "贡献者"
    case performance = "性能监控"
    case logs = "错误日志"
    case dependencies = "依赖分析"
    case health = "健康评分"

    var id: String { rawValue }

    var title: String { rawValue }

    var icon: String {
        switch self {
        case .overview: return IconName.dashboard.rawValue
        case .code: return IconName.code.rawValue
        case .risk: return "exclamationmark.triangle.fill"
        case .git: return IconName.git.rawValue
        case .contributors: return IconName.people.rawValue
        case .performance: return IconName.pulse.rawValue
        case .logs: return IconName.logs.rawValue
        case .dependencies: return IconName.package.rawValue
        case .health: return IconName.health.rawValue
        }
    }

    var requiresReport: Bool {
        switch self {
        case .overview, .code, .risk, .git, .contributors, .logs, .dependencies, .health: return true
        case .performance: return false
        }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        NavigationSplitView {
            ProjectSidebar(selection: $state.selectedProjectID)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            ProjectDetailView()
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        HStack(spacing: 6) {
                            if state.isScanning {
                                ProgressOverlay(phase: state.phase, projectName: state.selectedProject?.name ?? "")
                            }
                            Button {
                                state.scanSelected()
                            } label: {
                                Label("重新分析", systemImage: "arrow.clockwise")
                            }
                            .disabled(state.isScanning || state.selectedProject == nil)
                            .help("对当前项目重新执行全部分析器")
                        }
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
    }
}

struct ProjectSidebar: View {
    @Environment(AppState.self) private var state
    @Binding var selection: UUID?
    @State private var showImporter = false

    var body: some View {
        @Bindable var state = state
        List(selection: $selection) {
            Section("项目列表") {
                ForEach(state.store.projects) { project in
                    ProjectRow(project: project, report: state.store.report(for: project))
                        .tag(project.id)
                        .contextMenu {
                            Button("重新分析") { state.scan(project: project) }
                            Button("在 Finder 中显示") {
                                NSWorkspace.shared.open(project.url)
                            }
                            Divider()
                            Button("移除", role: .destructive) { state.removeProject(project) }
                        }
                }
            }

            if state.store.projects.isEmpty {
                Section("开始使用") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("还没有监控项目")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("选择目录…") { showImporter = true }
                        Button("加载示例项目") { state.loadDemoProject() }
                            .buttonStyle(.link)
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Button {
                    showImporter = true
                } label: {
                    Label("添加项目", systemImage: "plus")
                }
                .controlSize(.small)

                Spacer()

                LiveCPUBadge(snapshot: state.monitor.latestSnapshot)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                state.addProject(at: url)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestAddProject)) { _ in
            showImporter = true
        }
    }
}

struct ProjectRow: View {
    var project: MonitoredProject
    var report: ProjectReport?

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(Theme.color(forScore: report?.health?.overall ?? 0))
                .frame(width: 9, height: 9)
                .overlay(
                    Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1)
                )
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(project.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    if project.isDemo {
                        Text("示例")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 3)
                            .background(Theme.accent.opacity(0.15), in: Capsule())
                    }
                }
                HStack(spacing: 5) {
                    if let code = report?.code {
                        Text("\(NumberFormat.compact(code.codeLines)) 行")
                    } else if let demo = report?.code {
                        Text("\(NumberFormat.compact(demo.codeLines)) 行")
                    } else {
                        Text("未分析")
                    }
                    if let score = report?.health?.overall {
                        Text("健康 \(score)")
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

struct LiveCPUBadge: View {
    var snapshot: SystemSnapshot?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "cpu")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(snapshot.map { "\(Int(($0.cpuUsage * 100).rounded()))%" } ?? "--")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .frame(width: 34, alignment: .trailing)
            Text("·")
                .foregroundStyle(.tertiary)
            Text(snapshot.map { ByteFormat.string($0.memoryUsedBytes, precision: 1) } ?? "--")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(.secondary)
        .help("本机实时 CPU / 已用内存")
    }
}
