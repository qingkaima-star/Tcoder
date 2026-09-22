import Charts
import SwiftUI

/// 总览页专属尺寸。基座 `Theme.Layout` 里没有这些档，
/// 放这里是为了让 `DashboardView` 及其分件里不再流通裸数字（WS-I §2.6）。
///
/// 占比条的三档尺寸（名称列 / 百分比列 / 条厚）已随 `LanguageBar` 一起删除：
/// 基座 `Theme.Share.Row` 用 `Theme.Layout.shareLabelWidth` / `sharePercentWidth` /
/// `gaugeInline` 自己管，页面再留一份就是第二套真相。
enum DashboardLayout {
    /// hero 区评分环的原始尺寸。页面把它放进自适应行里再拉宽。
    /// `HealthView`（WS-M）也在用这一对，改动要同步那页。
    static let heroRingWidth: CGFloat = 170
    static let heroRingHeight: CGFloat = 150
    /// hero 右侧结论区与环之间的间隙。`sm`(12) → `lg`(20)：卡面撤掉之后，
    /// 环与文字之间没有边界替它们分家了，间隙就是唯一的组内分隔（风格契约 8）。
    static let heroGap: CGFloat = Theme.Spacing.lg
}

// MARK: - 统计读数行
//
// 全仓被引用 56 次、跨 WS-L / WS-M 九个页面，所以**入参签名不动**，只把实现换干净。
// 归属：`AGENTS.md` §4 把 `StatLine` 列为设计系统组件，但它一直住在 Dashboard 文件里
// （WS-I §3.5 判为归属错位）。基座 `Design/**` 不归本流所有，故先落到 `Views/Shell/**`
// ——同模块内换文件不破坏任何调用点，将来总工要下沉到 `Design/` 也只是再挪一次。

struct StatLine: View {
    var label: String
    var value: String

    var body: some View {
        HStack(spacing: Theme.Spacing.xxs) {
            // `label` 是 `String`，`Text(String)` 不查表 —— 九个调用点写的都是中文短标签
            // （磁盘 / 网络 / 进程 / 注释行 / 空行…），英文态就整片吐中文。
            // 这一处包查表，九个调用点同时生效；查不到键仍原样显示中文。
            Text(localizedCopy(label))
                .font(Theme.Typo.label.font)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Text(localizedCopy(value))
                // 数字一律等宽：这是 WS-I §4 那条「全仓 monospacedDigit 命中 = 0」的根修法，
                // 一处改、56 个调用点全站生效。
                // `lineLimit(1)` 同理由：这一格在实时读数旁边，值一旦折成两行，
                // 整行高度被撑开、把下面的脚注往下顶（`1.2 GB/s` 进位时真实发生过）。
                .font(Theme.Typo.label.font.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .layoutPriority(1)   // 挤不下的时候宁可截标签，也不能截测得值
        }
    }
}

// MARK: - 横幅

enum BannerStyle {
    /// `neutral` 取代原来的 `info` 档（批次 P5）：横幅默认档决定"没人表态时长什么样"，
    /// 原来默认蓝 ⇒ 空态说明也涂成语义色。蓝只留给日志等级这类**数据本身**。
    case warning, neutral, error

    /// 横幅是「图形 + 文字」，走 `graphic` 层（验收线 3:1），不借文字层那套加深取值。
    var role: Theme.SemanticRole {
        switch self {
        case .warning: return Theme.Semantic.warning
        case .neutral: return Theme.Semantic.neutral
        case .error: return Theme.Semantic.danger
        }
    }

    var color: Color { role.graphicColor }

    /// 符号从裸串换成登记表条目：警告=实心三角、错误=八边形（更高警戒，WS-H §6.4）。
    /// 原来 error 用 `xmark.octagon.fill`，与全站「关闭/移除」的 xmark 系混在一起。
    var icon: IconName {
        switch self {
        case .warning: return .riskWarning
        case .neutral: return .info
        case .error: return .riskSevere
        }
    }
}

struct BannerRow: View {
    var text: String
    var style: BannerStyle = .neutral
    /// 「留短藏长」槽，形状照 `SectionEmptyNote.help:`：屏上留 `text`，长口径进 ⓘ。
    /// 默认 `nil` ⇒ 现有调用点一字不改。有了它，横幅的长下文不再挂在整条横幅的裸 `.help` 上
    /// （那是全站要收掉的「匿名 tooltip」形状，见 `Design/CopyHelp.swift` 头注）。
    var help: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.xs) {
            ThemedIcon(style.icon, role: .inlineText, selected: true)
                .foregroundStyle(style.role.textColor)
            Text(localizedCopy(text))
                .font(Theme.Typo.narrative.font)
                .lineSpacing(Theme.Typo.narrative.lineSpacing)
                .foregroundStyle(.secondary)
            if let help { CopyHelpBadge(help) }
            Spacer(minLength: Theme.Spacing.xs)
        }
        .padding(Theme.Spacing.sm)
        .bannerRuleSurface(style.role)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// 提示条的表面画法：**左侧一道语义色竖标，不铺色底**。
    ///
    /// 原来这里是 `role.graphicColor.opacity(0.15)` 铺满整条 `Radius.md` 圆角矩形。
    /// 在纯白地面上，一块 1900×40pt 的淡色面是**全页最大的色块**，比它要强调的
    /// 主读数还显眼（用户实拍：Git 页蓝横幅、贡献者页粉横幅、错误日志页米黄横幅、
    /// 依赖页蓝横幅 —— 四页四块，颜色各不相同）。参考图里没有任何整幅色块，
    /// 语义只出现在小面积标记上。
    /// 竖标把彩色面积从约 76000pt² 压到约 80pt²（**降 99.9%**），语义色一个没丢：
    /// 色相仍然说"这是警告 / 提示 / 错误"，位置仍然把它钉在正文左边。
    ///
    /// 抽成一处是为了让 `BannerRow` 与 `DataNotice` 共用同一份配方 ——
    /// 它们本来就是同一个东西的两份实现（#34 之后仍未合并，是"同一件事两种画法"的活样本）。
    func bannerRuleSurface(_ role: Theme.SemanticRole) -> some View {
        overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: Theme.Stroke.emphasis / 2, style: .continuous)
                .fill(role.graphicColor)
                .frame(width: Theme.Stroke.emphasis)
                .padding(.vertical, Theme.Spacing.xs)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - 语言 / 占比条
//
// 这里原本住着一份 `LanguageBar`（含自带的 FNV-1a `stableIndex`），已按 #28 / #32 删除：
// 占比条改走基座 `Theme.Share.Row`，取色走 `Theme.Chart.color(forLabel:)`。
// 留两份哈希的后果是「同名同色」只在单页内成立——`Swift` 与 `swift` 会分到不同号位，
// 中文名字也因 UTF-8 字节序 ≠ unicodeScalars 码点序而错位。

// MARK: - 实时读数区（隔离出 DashboardView 的心跳失效域）

/// 总览页的实时部分：**独立成 struct**，整体从 `DashboardView.body` 的失效域里挪出。
///
/// 它读 `state.monitor.latestSnapshot` 与 `state.monitor.history`（每 1.5s 变一次）。
/// 旧写法这些读发生在 `DashboardView.body` 求值过程中，于是一次心跳就把整页
/// （四枚 tile + 三张静态卡 + 90 点×2 mark）全量重算，主线程热点第一名是
/// `_updateViewGraph`（性能规格 §1 实测 64.3%）。隔离后，心跳只让本 body 失效，
/// 静态分组（代码规模 / 文件构成 / 覆盖率 / 最近提交 / 高频错误）原地不动（O-2）。
///
/// 当前仍订阅整份 `latestSnapshot` / `history`，未用 M0 的细粒度读模型
///（M0 尚未进 main，且 `Services/**` 不在本流可写范围）；隔离已使失效域退出静态区，
/// M0 落地后可进一步只订阅所需字段。
struct DashboardLiveReadout: View {
    @Environment(AppState.self) private var state

    private var report: ProjectReport? { state.selectedReport }
    private var snapshot: SystemSnapshot? { state.monitor.latestSnapshot }

    /// 顺序是**实时性能在前、读数带在后**（设计复核第 2 条的结构解）。
    ///
    /// 原来的顺序是「读数带 → 实时性能 → 代码规模」：曲线自带一段坐标轴留白，
    /// 于是「读数带→实时性能」这一处 32pt 看起来明显大于「实时性能→代码规模」那处 32pt。
    /// **不改间距数值**去迁就观感（那是"为了好看改令牌"，三家会改得不一致），
    /// 改的是**谁挨着谁**：把带留白的曲线块挪到 hero 之后（hero 本身就 airy，两段呼吸同性质），
    /// 让两个紧凑块（读数带 / 代码规模）相邻，视觉不等就没了。
    /// 另一半理由是阅读优先级：这一组全是「本机此刻」的实时数据，比仓库静态的代码规模更该先看。
    ///
    /// ⚠️ 曾考虑的另一种解法——把「实时性能」与「代码规模」配成同列宽双栏——**被棘轮拦下**：
    /// 那要把本视图拆成两个叶子（曲线一个、读数带一个），每个都得自己读一次
    /// `state.monitor.latestSnapshot`，粗粒度读点就从 16 涨到 17，而
    /// `PerfInvalidationRatchetTests.coarseCallSiteCeiling` 当前正好是 16（顶格）。
    /// 双栏要等性能轮把这两处迁到细粒度读模型（`monitor.cpu.value` / `.curve.value`，
    /// 现量 0 处）之后才做得起。
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.group) {
            livePerformanceGroup
            readoutStrip
        }
    }

    // MARK: 读数带（旧「四枚 tile」）

    /// 四枚 tile 的三态口径：
    /// 「没有测到」一律传 `value: nil`，由 `MetricTile` 渲染成 `--` + 中性色；
    /// 真 0 是结论，照实传 `"0"`。原来 CPU 缺值传 `"--"` 而今日错误缺值传 `0`，
    /// 同一块屏上两种自相矛盾的说法并存（WS-I §3.4）。
    ///
    /// 排法换成 `ReadoutStrip` + 列间发丝线：tile 已经不是一块面了，
    /// 四块无边框文字并排会糊成一整段，发丝线替掉原来的盒体边界。
    private var readoutStrip: some View {
        ReadoutStrip {
            cpuTile
            DataBandSeparator()
            memoryTile
            DataBandSeparator()
            errorTile
            DataBandSeparator()
            commitTile
        }
    }

    private var cpuTile: some View {
        MetricTile(
            label: "CPU",
            value: snapshot.map { String(Int(($0.cpuUsage * 100).rounded())) },
            unit: "%",
            caption: snapshot.map {
                localizedFormat("%1$@ 核 · 负载 %2$@",
                                NumberFormat.grouped($0.cpuCoreCount),
                                String(format: "%.2f", $0.loadAverage1))
            },
            // 大数是「占用率」，分子分母那句口径走性能页那一份唯一真值（整句不在这里重抄）。
            captionHelp: PerformanceLiveCharts.cpuBasis(context: SampleContext.from(state.monitor)),
            systemImage: IconName.cpu.rawValue
        )
    }

    private var memoryTile: some View {
        MetricTile(
            // 「Memory」→「内存」：WS-H §7.1 点名的必修项
            label: "内存",
            value: snapshot.map { ByteFormat.string($0.memoryUsedBytes, precision: 1) },
            caption: snapshot.map {
                localizedFormat("共 %1$@ · %2$@",
                                ByteFormat.string($0.memoryTotalBytes, precision: 1),
                                NumberFormat.percent($0.memoryFraction, precision: 0))
            },
            // 「在用」≠「剩余可用」是这一格唯一会被读反的地方，整句走 `SystemReadings` 那一份。
            captionHelp: SystemReadings.memoryCaliber,
            systemImage: IconName.memory.rawValue
        )
    }

    private var errorTile: some View {
        let logs = report?.logs
        let caption: String?
        if logs?.hasData == true {
            caption = localizedFormat("崩溃 %1$@ · 异常 %2$@",
                                      NumberFormat.grouped(logs?.crashCount ?? 0),
                                      NumberFormat.grouped(logs?.exceptionCount ?? 0))
        } else {
            caption = logs == nil ? ShellCopy.notAnalyzed(.errorLogs)
                : ShellCopy.cannotAnalyze(.noLogFiles)
        }
        let count = logs?.hasData == true ? logs?.todayErrorCount : nil
        return MetricTile(
            label: "今日错误",
            value: count.map { NumberFormat.grouped($0) },
            caption: caption,
            tint: DashboardView.hasTodayErrors(count) ? Theme.Semantic.danger.textColor
                                                      : Theme.Palette.Surface.ink,
            systemImage: IconName.riskWarning.rawValue
        )
    }

    private var commitTile: some View {
        MetricTile(
            label: "最近提交",
            // 原来是 `sinceDescription(...).replacingOccurrences(of: " 前", with: "")`：
            // 手工削掉一个中文词，好让大数档少打两个字 —— 英文态 "41 seconds ago" 里
            // 根本没有 " 前"，这个补丁等于只治了半种语言（批次 P5 换成按数字/单位切分）。
            value: report?.git.map { LogRecency.split(DateFormat.sinceDescription($0.lastCommitAt)).value },
            unit: report?.git.map { LogRecency.split(DateFormat.sinceDescription($0.lastCommitAt)).unit } ?? nil,
            caption: report?.git.map {
                localizedFormat("%1$@ 次提交 · %2$@ 位贡献者",
                                NumberFormat.grouped($0.totalCommits),
                                NumberFormat.grouped($0.activeAuthorCount))
            } ?? ShellCopy.notAnalyzed(.gitHistory),
            // 屏上两枚是**含合并的总数**与**作者表行数**；差值口径走 Git 页那个生产者 `GitHistoryScope.headline`，不另写一份。
            captionHelp: report?.git.map { GitHistoryScope($0).headline },
            systemImage: IconName.git.rawValue
        )
    }

    // MARK: 实时性能分组

    /// 节奏文案。**页面不再自己写死间隔数字**——节拍唯一真值是
    /// `MachSystemMonitor.defaultSampleIntervalMilliseconds`，展示串走
    /// `sampleIntervalText`（性能 spec §5.1，`PerfCadenceSingleSourceTests` 钉着）。
    /// 另一半是诚实性：交互暂停期间屏幕上的数不再按那个节奏更新，继续宣称固定节奏
    /// 就是说谎（读数仍是真的，说谎的是「节奏」这两个字），所以暂停时改口。
    /// 与 WS-W 的 `PerformanceView.cadenceText` 同一条口径。
    /// （注：这段说明原先写过带秒数的字面量 —— 那条守卫**不剥注释**，
    /// 说明文字会被当成真命中计数，实测把 5 的基线白占了一格。）
    private var cadenceSubtitle: String {
        state.monitor.isInteractionPaused
            ? "本机 · 采样已暂停"
            : localizedFormat("本机 · 每 %@采样", state.monitor.sampleIntervalText)
    }

    /// 上面那半句节奏话的 ⓘ 长口径（「留短藏长」的下半截），只给**运行态**：暂停态屏上已写着
    /// 「采样已暂停」，而目录里那句整句口径结尾是「点「继续」恢复实时刷新」，「继续」只住在性能页
    /// （`PerformanceView.controls`）——在总览页指一颗本页没有的按钮等于写假指引，故留 `nil` 不画问号。
    /// 运行态这句是性能页页头那条键的**第二落点**（本流不改 `Views/Performance/**`，故重复了字面量，已按「建议收成一处常量」报总工）。落点自检：`ShellReadoutTooltipTests`。
    private var cadenceCaliber: String? { state.monitor.isInteractionPaused ? nil : Self.liveReadingsCaliber }

    /// `cadenceCaliber` 的正文。写成 `static let` 是让这处与它的落点自检共用一份真值。
    static let liveReadingsCaliber = "系统级实时读数只观测不干预。数值随采样刷新，取不到的一律显示 --，不会补成 0。"

    private var livePerformanceGroup: some View {
        GlassSection("实时性能",
                     subtitle: cadenceSubtitle,
                     subtitleHelp: cadenceCaliber,
                     icon: .performance) {
            if state.monitor.history.count > 2 {
                CPUHistoryChart(snapshots: Array(state.monitor.history.suffix(90)))
                    .frame(minHeight: Theme.Layout.chartMinHeight)
                HStack(spacing: Theme.Spacing.md) {
                    StatLine(label: "磁盘", value: snapshotRate(snapshot?.diskReadBytesPerSecond,
                                                                snapshot?.diskWriteBytesPerSecond,
                                                                rate: ByteFormat.rate))
                    StatLine(label: "网络", value: snapshotRate(snapshot?.networkInBytesPerSecond,
                                                                snapshot?.networkOutBytesPerSecond,
                                                                rate: ByteFormat.bitRate))
                    StatLine(label: "进程",
                             value: DataAbsence.optional(
                                snapshot.map { NumberFormat.grouped($0.processCount) }).display)
                    // 「立即采样」原挂在 `GlassSection.trailing`（需 `AnyView`，O-3 清零），
                    // 移回内容区时**并进这一行**：单独占一行会成一个游离控件，
                    // 眼睛读它是「曲线的一部分」还是「读数的一部分」都说不清。
                    Spacer(minLength: Theme.Spacing.sm)
                    GlassButton("立即采样", icon: .refresh, style: .bordered) {
                        state.monitor.sampleNow()
                    }
                }
            } else {
                // 盘点表 A 组第 7 条「藏」：整句预告收进 ⓘ，屏上只留状态本身。
                EmptyStateView(icon: IconName.performance.rawValue,
                               title: "正在采集…",
                               message: "首个采样点",
                               help: "首个采样点到达后显示曲线。")
            }
        }
    }

    /// 读写两个方向求和。快照缺席时给 `DataAbsence.notAnalysed` 的字面（`--`）——
    /// 旧写法 `(snapshot?.diskRead ?? 0) + (… ?? 0)` 会把「没采到」报成 `0 B/s`，
    /// 在监控 App 里这是一句假的好消息（WS-I §3.4）。
    private func snapshotRate(_ read: UInt64?, _ write: UInt64?,
                              rate: (UInt64) -> String) -> String {
        guard let read, let write else { return DataAbsence.notAnalysed.display }
        return rate(read + write)
    }
}
