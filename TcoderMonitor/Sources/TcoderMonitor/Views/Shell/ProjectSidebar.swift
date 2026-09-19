import AppKit
import SwiftUI

// MARK: - 窗口侧栏（项目列表）
//
// 从 `RootView.swift` 整体迁出，让 RootView 只留导航骨架。侧栏本身属控件层，
// macOS 26 上系统已给 `List(.sidebar)` 挂了玻璃材质，所以这里**不再自造背景**
// （[LG]「减少控件里的自定义背景、让系统决定」），只负责行内容与底部读数。

struct ProjectSidebar: View {
    @Environment(AppState.self) private var state
    @Binding var selection: UUID?
    @State private var showImporter = false

    var body: some View {
        @Bindable var state = state

        List(selection: $selection) {
            if !state.store.projects.isEmpty {
                Section("项目列表") {
                    ForEach(state.store.projects) { project in
                        ProjectRow(project: project, report: state.store.report(for: project))
                            .tag(project.id)
                            .contextMenu {
                                Button("重新分析") { state.scan(project: project) }
                                Button("在 Finder 中显示") { NSWorkspace.shared.open(project.url) }
                                Divider()
                                Button("移除", role: .destructive) { state.removeProject(project) }
                            }
                    }
                }
            } else {
                Section("开始使用") {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Text("还没有监控项目")
                            .font(Theme.Typo.body.font)
                            .foregroundStyle(.secondary)
                            .lineSpacing(Theme.Typo.body.lineSpacing)
                        GlassButton("选择目录…", icon: .add, style: .prominent) {
                            showImporter = true
                        }
                        GlassButton("加载示例项目", style: .plain) {
                            state.loadDemoProject()
                        }
                    }
                    .padding(.vertical, Theme.Spacing.xs)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            sidebarFooter
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

    @ViewBuilder
    private var sidebarFooter: some View {
        @Bindable var state = state
        HStack(spacing: Theme.Spacing.xs) {
            GlassButton("添加项目", icon: .add, style: .bordered) {
                showImporter = true
            }
            Spacer(minLength: Theme.Spacing.xs)
            LiveCPUBadge(snapshot: state.monitor.latestSnapshot)
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs)
    }
}

// MARK: - 项目行

struct ProjectRow: View {
    var project: MonitoredProject
    var report: ProjectReport?

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            HealthDot(score: report?.health?.overall)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack(spacing: Theme.Spacing.xxs) {
                    Text(project.name)
                        .font(Theme.Typo.cardTitle.font)
                        .lineLimit(1)
                    if project.isDemo {
                        // 原来这里是一套就地自造的淡色胶囊（8pt + 0.15 底），
                        // 与 PerformanceView 的 PerfTag 逐行重复（WS-I §3.1）→ 改用基座件。
                        SemanticBadge("示例", role: Theme.Semantic.accent)
                    }
                }
                metaLine
            }
            Spacer()
        }
        .padding(.vertical, Theme.Spacing.xxs)
    }

    /// 副标题行。三态在这里的落法：没有代码报告 = 写「尚未分析」而不是「--」，
    /// 因为这一行整体就是「还没有结论」，摆两个短横线会被读成一个测得值。
    private var metaLine: some View {
        HStack(spacing: Theme.Spacing.xs) {
            if let code = report?.code {
                Text("\(NumberFormat.compact(code.codeLines)) 行").monospacedDigit()
            } else {
                Text(ShellCopy.notAnalyzed("代码规模"))
            }
            if let score = report?.health?.overall {
                Text("健康 \(score)").monospacedDigit()
            }
        }
        .font(Theme.Typo.label.font)
        .foregroundStyle(.tertiary)
    }
}

/// 项目健康色点。**未评分必须是空心灰圈**，不能是红点。
///
/// 旧写法 `Theme.color(forScore: report?.health?.overall ?? 0)` 把「从没扫过」渲染成
/// `danger` 最危险的红，和同一行「未分析」的文字自相矛盾（WS-I §3.4 / WS-H §1.4#2 / WS-D #6
/// 三家都点到这一条）。着色走 `graphic` 层：色块是非文本图形，验收线 3:1，
/// 不必借用文字层那套加深的取值。
struct HealthDot: View {
    var score: Int?

    var body: some View {
        let role = Theme.Semantic.role(forScore: score)
        Circle()
            .fill(Self.kind(for: score) == .hollow ? Color.clear : role.graphicColor)
            .overlay {
                if Self.kind(for: score) == .hollow {
                    Circle().stroke(role.graphicColor, lineWidth: Theme.Stroke.emphasis)
                }
            }
            .frame(width: ShellLayout.statusDotDiameter, height: ShellLayout.statusDotDiameter)
            .accessibilityHidden(true)
    }

    /// 画法做成纯函数，供单测钉住「未评分不得出现实心着色点」这条诚实线
    /// （`MetricTile.displayValue` 用的是同一套路子）。
    static func kind(for score: Int?) -> DotKind {
        score == nil ? .hollow : .filled
    }

    enum DotKind: Hashable {
        case filled
        case hollow
    }
}

// MARK: - 实时读数（侧栏底栏）

struct LiveCPUBadge: View {
    var snapshot: SystemSnapshot?

    var body: some View {
        HStack(spacing: Theme.Spacing.xxs) {
            ThemedIcon(.cpu, role: .badge)
                .foregroundStyle(.secondary)
            Text(snapshot.map { "\(Int(($0.cpuUsage * 100).rounded()))%" }
                ?? Theme.Placeholder.missingValue)
                .font(Theme.Typo.monoSmall.font)
                .frame(width: ShellLayout.liveReadoutColumnWidth, alignment: .trailing)
            Text("·")
                .foregroundStyle(.tertiary)
            Text(snapshot.map { ByteFormat.string($0.memoryUsedBytes, precision: 1) }
                ?? Theme.Placeholder.missingValue)
                .font(Theme.Typo.monoSmall.font)
        }
        .foregroundStyle(.secondary)
        .help("本机实时 CPU / 已用内存")
    }
}
