import AppKit
import SwiftUI

// MARK: - 窗口侧栏（项目列表 + 九页导航）
//
// 从 `RootView.swift` 整体迁出，让 RootView 只留导航骨架。侧栏本身属控件层，
// macOS 26 上系统已给 `List(.sidebar)` 挂了玻璃材质，所以不再自造窗口背景
// （[LG]「减少控件里的自定义背景、让系统决定」）。
//
// **本轮（WS-O / M1）改成原生 source list**（spec §3，风格契约 7）：
//   · 两个分组 —— `Section("项目")` + `Section("分析视图")`（9 行）。
//     原来九页挤在页头下面一条横滚 chip 条里，吃掉 44pt 纵向空间，还和侧栏选中行、
//     顶栏按钮各用一套材质语言；页名是这九页的主导航，它该住在侧栏。
//   · 项目行不再是一块 48pt 材质胶囊（自带一份投影）。行高收到 30pt，
//     选中态整个交回 `.listStyle(.sidebar)` 原生绘制 —— **零胶囊、零投影、零描边**。
//   · 视图行用手动选中态：`List(selection:)` 只能有一根绑定，而「哪个项目」与
//     「哪一页」是**两个选择轴**，硬塞进一根绑定会让点页面把项目选没。
//
// 保留的真功能：拖放添加项目（`dropDestination`，落点校验只收目录）、上下文菜单、
// 引导卡常驻、底栏「添加项目」+ 本机实时读数。
// `@AppStorage("selectedDetailSection")` 的键名与取值一律不动 ——
// 九页取证脚本靠 `-selectedDetailSection <中文页名>` 传页。

struct ProjectSidebar: View {
    @Environment(AppState.self) private var state
    @Binding var selection: UUID?
    @State private var showImporter = false
    @State private var isDropTargeted = false
    @AppStorage("selectedDetailSection") private var sectionRaw: String = DetailSection.overview.rawValue

    var body: some View {
        List(selection: $selection) {
            if !state.store.projects.isEmpty {
                projectsSection
            }
            analysisSection
            guideSection
        }
        .listStyle(.sidebar)
        // 选中胶囊染色。不写这一行时它跟的是**用户系统强调色**（本机是蓝），
        // 于是"最重要的反馈"跟着每个人的系统设置漂，与钉死的绿色强调对不齐。
        .tint(Theme.Semantic.accent.graphicColor)
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
        Section("项目") {
            ForEach(state.store.projects) { project in
                projectRow(project)
            }
        }
    }

    /// 九页导航。可达性沿用 `DetailSection.isReachable(reportAvailable:)`：
    /// 没有报告时把需要报告的页禁掉，而不是让用户点进一张空卡。
    private var analysisSection: some View {
        Section("分析视图") {
            ForEach(DetailSection.allCases) { section in
                AnalysisSectionRow(
                    section: section,
                    isSelected: section.rawValue == sectionRaw,
                    isEnabled: section.isReachable(reportAvailable: state.selectedReport != nil)
                        // 当前页永远保持可用态：把「正在看的一页」画成禁用灰，
                        // 读屏会念出「已禁用」而屏幕上它明明是选中的。
                        || section.rawValue == sectionRaw
                ) {
                    sectionRaw = section.rawValue
                }
            }
        }
    }

    @ViewBuilder
    private var guideSection: some View {
        if state.store.projects.isEmpty {
            Section("开始使用") { guideCard(mode: .firstRun) }
        } else {
            Section { guideCard(mode: .compact) } header: { EmptyView() }
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
        ProjectRow(project: project, report: state.store.report(for: project))
            .tag(project.id)
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

    /// 侧栏底栏。**独立成 struct**（`SidebarLiveFooter`）：
    /// 它读 `state.monitor.latestSnapshot`，而 `ProjectSidebar.body` 已不再读 `monitor`
    /// 任何属性 —— 否则每 1.5s 一次心跳会把整个 `List`（含全部 `ProjectRow`）
    /// 一起失效重建（O-1，性能规格 §5.2）。独立成视图后，`latestSnapshot` 的失效域
    /// 只落在这一个 body 上，侧栏项目行不再随心跳重建。
    @ViewBuilder
    private var sidebarFooter: some View {
        SidebarLiveFooter(showImporter: $showImporter)
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
                    // 紧凑态**不再在文字左边再来一枚 ⊕**：行尾本来就有一枚可点的
                    // 「选择目录」按钮，两枚同义图标把 17 字的提示挤到截断
                    // （实拍「把项目文件夹拖到这里，或…」）。
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

/// 一行 = 一个项目。**它不再是一块卡**（风格契约 7）：
/// 无 `.surface()`、无 48pt 胶囊、无描边、无投影。
/// 选中态连文字色一起交给系统 —— 侧栏高亮是 `.listStyle(.sidebar)` 的本行，
/// 页面在这里自己涂一层淡底就是第二套选中语言（原来正是这套，和导航条、顶栏各说各话）。
struct ProjectRow: View {
    var project: MonitoredProject
    var report: ProjectReport?

    /// 名字与读数的**左边缘对齐量**：色点直径 + 行内间距。
    private static let metaIndent: CGFloat =
        ShellLayout.statusDotDiameter + Theme.Spacing.xs

    var body: some View {
        // 两行制：名字独占一行，测得读数落在第二行。
        // 原来名字与两格定宽读数抢同一行，`Spacer` 把名字压成「Tcoder…」「Tc…」——
        // 用户九张实拍里每一张都有被截的项目名，而侧栏宽度明明放得下整行读数。
        // 第二行不参与竞争，于是名字拿回整行宽度，读数也不再互相推。
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            HStack(spacing: Theme.Spacing.xs) {
                HealthDot(score: report?.health?.overall)
                Text(project.name)
                    .font(Theme.Typo.body.font)
                    // 侧栏 `List(.sidebar)` 会给行标签套上层级样式，选中行在非活动窗口
                    // 退成灰底后，标签于是是「secondary 压灰底」—— 深色态实测
                    // `#7A7A7A` 压 `#464646` ≈ 2.2:1，九张截图里当前项目名全部读不出。
                    // 名字是这一行的主角，钉绝对纯墨，不随层级连乘。
                    .foregroundStyle(Theme.Palette.Surface.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // 单行截断仍然可能存在（名字可以任意长），所以完整名字必须
                    // 悬停可得 —— 否则「看得见一半」比「看不见」更难查。
                    .help(project.name)
                if project.isDemo {
                    // 原来这里是一套就地自造的淡色胶囊（8pt + 0.15 底），
                    // 与 PerformanceView 的 PerfTag 逐行重复（WS-I §3.1）→ 改用基座件。
                    DemoBadge()
                }
            }
            metaLine
                .padding(.leading, Self.metaIndent)
        }
        .padding(.horizontal, ShellLayout.rowPadding)
        .frame(maxWidth: .infinity, minHeight: ShellLayout.rowMinHeight, alignment: .leading)
    }

    /// 第二行读数。三态在这儿的落法：没有代码报告 = 写「尚未分析」而不是 `--`，
    /// 因为这一格就是「还没有结论」，摆两个短横线会被读成一个测得值。
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
                    .font(Theme.Typo.microLabel.font)
                    .lineLimit(1)
            }
            if let score = report?.health?.overall {
                metricCell("健康 \(score)", width: ShellLayout.healthColumnWidth)
            }
        }
        // 原来是 `.tertiary`：这一格里是**测得值**（行数、健康分），
        // 测得值不得用 tertiary（风格契约 4）。
        .foregroundStyle(.secondary)
    }

    private func metricCell(_ text: String, width: CGFloat) -> some View {
        Text(text)
            // 字号写在每个 Text 上，而不是靠外层 `.font` 经 environment 传进来：
            // 后者与 `.monospacedDigit()` 的先后顺序会决定等宽到底生不生效。
            .font(Theme.Typo.label.font.monospacedDigit())
            .frame(width: width, alignment: .trailing)
    }
}

// MARK: - 实时读数（侧栏底栏）

/// 侧栏底栏的实时读数（本机 CPU / 已用内存）。
///
/// **必须独立成 struct**：它读 `state.monitor.latestSnapshot`，而 `ProjectSidebar`
/// 的 `body` 不再读 `monitor` 任何属性。SwiftUI 的 `@Observable` 失效域按「正在求值
/// 的 view body」划分 —— 如果这里写成 `ProjectSidebar` 的计算属性，读 `latestSnapshot`
/// 会发生在 `ProjectSidebar.body` 的求值过程中，于是每次心跳（每 1.5s）都让整个
/// `List`（含全部 `ProjectRow`）整段失效、整段重建（潜在交互卡顿的根因之一，性能规格 §5.2 O-1）。
/// 独立成视图后，失效域只落在本 body，侧栏项目行不再随心跳重建。
///
/// 注：当前仍订阅整份 `latestSnapshot`，未用 M0 的细粒度读模型（M0 尚未进 main 且
/// `Services/**` 不在本流可写范围）。隔离已使失效域退出 `List`；M0 落地后可进一步改成
/// 只订阅 `cpuUsage` / `memoryUsedBytes` 单字段，但本修复不依赖它。
struct SidebarLiveFooter: View {
    @Environment(AppState.self) private var state
    @Binding var showImporter: Bool

    /// 两行式底栏。**不是一行**：18:29 实拍实测，「按钮 + CPU 定宽格 + 内存定宽格」
    /// 挤在同一行时总宽超出侧栏可用宽，`.frame(width:)` 在过约束的 `HStack` 里会被压缩，
    /// 于是 `36.9 GB` 在格子里折成三行（`36.` / `9` / `GB`），把底栏撑歪。
    /// 定宽格本身够宽（见 `ShellBorderlessTests.test_sidebarLiveReadoutColumnFitsTheWorstCase`），
    /// 不够的是**同一行的预算** —— 所以把读数单独成行，并另加一条同行预算断言。
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            HStack(spacing: Theme.Spacing.xs) {
                GlassButton("添加项目", icon: .add, style: .bordered) {
                    showImporter = true
                }
                Spacer(minLength: Theme.Spacing.xs)
            }
            LiveCPUBadge(snapshot: state.monitor.latestSnapshot)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs)
    }
}

struct LiveCPUBadge: View {
    var snapshot: SystemSnapshot?

    var body: some View {
        HStack(spacing: Theme.Spacing.xxs) {
            ThemedIcon(.cpu, role: .badge)
                .foregroundStyle(.secondary)
            Text(DataAbsence.optional(
                    snapshot.map { "\(Int(($0.cpuUsage * 100).rounded()))%" }).display)
                .font(Theme.Typo.monoSmall.font)
                .frame(width: ShellLayout.liveReadoutColumnWidth, alignment: .trailing)
            Text("·")
                .foregroundStyle(.tertiary)
            Text(DataAbsence.optional(
                    snapshot.map { ByteFormat.string($0.memoryUsedBytes, precision: 1) }).display)
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
