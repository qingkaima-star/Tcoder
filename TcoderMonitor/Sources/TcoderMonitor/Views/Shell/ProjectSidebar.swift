import AppKit
import SwiftUI

// MARK: - 窗口侧栏（项目列表）
//
// 从 `RootView.swift` 整体迁出，让 RootView 只留导航骨架。侧栏本身属控件层，
// macOS 26 上系统已给 `List(.sidebar)` 挂了玻璃材质，所以不再自造窗口背景
// （[LG]「减少控件里的自定义背景、让系统决定」）。
//
// 第二轮按总工目视结论改的三件事：
//   1. 只有一个项目时整块侧栏是空的 → 行卡化把视觉重量压回去，并在列表尾常驻一张
//      「添加 / 拖入」引导卡占住剩余空间，且**拖放是真能用的**（不是画个虚线框骗人）；
//   2. 扫描中「20k 行 健康 61」左右抖 → 两个读数改成右对齐定宽格，理由见 `ShellLayout`；
//   3. 选中行与顶部导航条用同一条规则（未选中=内容层材质、选中=升到控件层吃玻璃），
//      侧栏、导航条、顶栏于是是同一套材质语言。

struct ProjectSidebar: View {
    @Environment(AppState.self) private var state
    @Binding var selection: UUID?
    @State private var showImporter = false
    @State private var isDropTargeted = false

    var body: some View {
        List(selection: $selection) {
            if !state.store.projects.isEmpty {
                projectsSection
            }
            guideSection
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            sidebarFooter
        }
        // 拖进来是真能加项目的。用 `dropDestination` 而不是 NSItemProvider 的
        // 异步 completion：它在主线程同步回调，不会把 @MainActor 的 state 带进
        // @Sendable 闭包里吃一条并发警告。
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls)
        } isTargeted: { isDropTargeted = $0 }
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

    /// 拆成独立计算属性是必需的：整段内联在一个 `List { }` 里会让类型检查
    /// 在 20 秒内算不出来（实测报 "unable to type-check this expression"）。
    private var projectsSection: some View {
        Section("项目列表") {
            ForEach(state.store.projects) { project in
                projectRow(project)
            }
        }
    }

    private var guideSection: some View {
        Group {
            if state.store.projects.isEmpty {
                Section("开始使用") { guideCard(mode: .firstRun) }
            } else {
                Section { guideCard(mode: .compact) } header: { EmptyView() }
            }
        }
    }

    private func guideCard(mode: AddProjectGuideCard.Mode) -> some View {
        AddProjectGuideCard(
            mode: mode,
            isDropTargeted: isDropTargeted,
            onChooseFolder: { showImporter = true },
            onLoadDemo: { state.loadDemoProject() }
        )
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private func projectRow(_ project: MonitoredProject) -> some View {
        ProjectRow(project: project,
                   report: state.store.report(for: project),
                   isSelected: project.id == selection)
            .tag(project.id)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .contextMenu { rowContextMenu(project) }
    }

    @ViewBuilder
    private func rowContextMenu(_ project: MonitoredProject) -> some View {
        Button("重新分析") { state.scan(project: project) }
        Button("在 Finder 中显示") { NSWorkspace.shared.open(project.url) }
        Divider()
        Button("移除", role: .destructive) { state.removeProject(project) }
    }

    /// 落点校验：只收目录。拖进来的 URL 可能是文件，`ProjectStore` 不校验类型。
    private func handleDrop(_ urls: [URL]) -> Bool {
        guard let url = urls.first, url.isProjectDirectory else { return false }
        state.addProject(at: url)
        return true
    }

    @ViewBuilder
    private var sidebarFooter: some View {
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

// MARK: - 引导卡

/// 列表尾部的常驻引导位。空列表时是首屏引导；已有项目时收成一行也仍然在，
/// 因为「只有一个项目」那块空白原本什么都做不了。
struct AddProjectGuideCard: View {
    enum Mode: Hashable {
        /// 一个项目都没有：大图标 + 说明 + 主行动按钮
        case firstRun
        /// 已有项目：压成一行，只留拖放提示与加号
        case compact
    }

    var mode: Mode
    var isDropTargeted: Bool
    var onChooseFolder: () -> Void
    var onLoadDemo: () -> Void

    var body: some View {
        Group {
            if mode == .firstRun {
                VStack(spacing: Theme.Spacing.xs) {
                    ThemedIcon(.add, role: .hero, label: "添加项目")
                        .foregroundStyle(iconTint)
                    Text("还没有监控项目")
                        .font(Theme.Typo.cardTitle.font)
                        .foregroundStyle(.secondary)
                    hint
                    GlassButton("选择目录…", icon: .add, style: .prominent,
                                action: onChooseFolder)
                    GlassButton("加载示例项目", style: .plain, action: onLoadDemo)
                }
                .frame(maxWidth: .infinity, minHeight: ShellLayout.guideMinHeight)
            } else {
                HStack(spacing: Theme.Spacing.xs) {
                    ThemedIcon(.add, role: .inlineText, label: "添加项目")
                        .foregroundStyle(iconTint)
                    hint
                    Spacer(minLength: Theme.Spacing.xs)
                    Button(action: onChooseFolder) {
                        ThemedIcon(.add, role: .badge, label: "选择目录")
                    }
                    .buttonStyle(.plain)
                    .glassButtonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, minHeight: ShellLayout.guideCompactHeight)
            }
        }
        .multilineTextAlignment(.center)
        .padding(Theme.Spacing.sm)
        // 拖进来时换成实线强调描边，松手之前就看得出落点对不对；
        // 不拖时靠虚线交代「这是一块可以放东西的区域」，而不是又一张不透明卡。
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .strokeBorder(dropTint,
                              style: StrokeStyle(
                                lineWidth: isDropTargeted ? Theme.Stroke.emphasis
                                                          : Theme.Stroke.hairline,
                                dash: isDropTargeted ? [] : ShellLayout.guideDash))
        }
        .animation(.default, value: isDropTargeted)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(mode == .firstRun ? "添加第一个项目" : "添加更多项目")
    }

    private var iconTint: Color {
        isDropTargeted ? Theme.Semantic.accent.textColor : Color.secondary
    }

    private var dropTint: Color {
        isDropTargeted ? Theme.Semantic.accent.textColor : Color(nsColor: .separatorColor)
    }

    private var hint: some View {
        Text("把项目文件夹拖到这里，或选择本地目录")
            .font(Theme.Typo.label.font)
            .foregroundStyle(.tertiary)
            .lineSpacing(Theme.Typo.label.lineSpacing)
    }
}

// MARK: - 项目行

struct ProjectRow: View {
    var project: MonitoredProject
    var report: ProjectReport?
    var isSelected: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
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
        .padding(.horizontal, ShellLayout.rowPadding)
        .padding(.vertical, Theme.Spacing.xs)
        .frame(maxWidth: .infinity, minHeight: ShellLayout.rowMinHeight, alignment: .leading)
        // 与顶部导航条同一条规则：未选中是内容层的一块内嵌材质，选中才升到控件层。
        .surface(layer: isSelected ? .chrome : .contentInset,
                 shape: .rounded(Theme.Radius.md))
    }

    /// 副标题行。三态在这儿的落法：没有代码报告 = 写「尚未分析」而不是 `--`，
    /// 因为这一整行就是「还没有结论」，摆两个短横线会被读成一个测得值。
    ///
    /// 每个读数占一个**右对齐定宽格**：`.monospacedDigit()` 只保证单个数字等宽，
    /// 挡不住 `compact` 结果本身跨位数变宽（`9k`→`182k`）把邻居推走。
    private var metaLine: some View {
        HStack(spacing: Theme.Spacing.xs) {
            if let code = report?.code {
                metricCell("\(NumberFormat.compact(code.codeLines)) 行",
                           width: ShellLayout.lineCountColumnWidth)
            } else {
                Text(ShellCopy.notAnalyzed("代码规模"))
                    .font(Theme.Typo.label.font)
            }
            if let score = report?.health?.overall {
                metricCell("健康 \(score)", width: ShellLayout.healthColumnWidth)
            }
        }
        .foregroundStyle(.tertiary)
    }

    private func metricCell(_ text: String, width: CGFloat) -> some View {
        Text(text)
            // 字号写在每个 Text 上，而不是靠外层 `.font` 经 environment 传进来：
            // 后者与 `.monospacedDigit()` 的先后顺序会决定等宽到底生不生效。
            .font(Theme.Typo.label.font.monospacedDigit())
            .frame(width: width, alignment: .trailing)
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
        // 合并成一个元素：否则读屏会把图标、数字、间隔点念成四段碎片。
        // 这里刻意**不**再套 `.accessibilityLabel`——那会覆盖掉合并来的数值，
        // 只剩一句「本机实时 CPU」，等于把读数从读屏里拿走。
        .accessibilityElement(children: .combine)
        .help("本机实时 CPU / 已用内存")
    }
}

// MARK: - 拖放校验

private extension URL {
    /// 拖进来的必须是目录。`ProjectStore.add(path:)` **不校验类型**，
    /// 扔一个文件进来会被登记成项目、然后每条分析器都扫不出东西 ——
    /// 那种「空项目」比当场拒掉更难查，所以校验落在落点。
    var isProjectDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}
