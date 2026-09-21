import SwiftUI

// MARK: - 进程分组（用户点名的杀手子功能）

/// 分组卡片的四种在场状态。并排显示时必须一眼分开（总工截图复核问题 4）：
/// 「零命中」和「根本没在采样」是两件不同的事，混在一起会让人去重启一个其实正常的服务。
enum GroupMatchState: Hashable {
    case waitingFirstSample
    case pausedWithoutMatch
    case noMatch
    case matched
}

/// 按匹配模式把全系统进程聚成一组的汇总卡。
struct PerformanceProcessGroupsCard: View {
    let groups: [ProcessGroupSnapshot]
    let context: SampleContext
    let isTruncated: Bool
    /// 节拍文案（唯一真值派生），透传给组卡的「下一步」提示。
    let intervalText: String
    let onRemove: (UUID) -> Void

    var body: some View {
        GlassSection("进程分组",
                     subtitle: "按匹配模式在全系统进程里查找，与所选项目无关",
                     icon: .handles) {
            if groups.isEmpty {
                EmptyStateView(icon: IconName.add.rawValue,
                               title: "还没有分组规则",
                               message: "在下方「匹配模式」里添加分组，例如 java、nginx、mysqld 这类通用进程名。")
            } else {
                groupList
                // **留短藏长**：屏上只留「零命中该怎么读」这半句（它挡的是"服务挂了"这个误读），
                // 时间预算与覆盖度去处进 ⓘ。完整口径仍由 `coverageFootnote` 一处产出。
                NoteLine(Self.zeroMatchReading, help: coverageFootnote)
            }
        }
    }

    /// 分组之间用 `Spacing.group`(32) + 一条发丝线分开。
    ///
    /// 旧写法是 `LazyVGrid(adaptive 420)` 里摆若干块带井的卡，边界由灰盒自己交代；
    /// 井拿掉之后如果没有那道组间距，相邻两张卡的文字会读成同一段（「不规整拥挤」的
    /// 另一半成因就是**去掉面却不补间距**）。这里不改单列/双列的取舍来省这点钱：
    /// 一张分组卡有 4 格数据 + 一行匹配模式，双列并排时列宽不足会把「N/M 个进程取到」
    /// 截成两行，所以收成单列。
    private var groupList: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.group) {
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    DataRowSeparator()
                }
                PerformanceGroupCard(group: item,
                                     context: context,
                                     isTruncated: isTruncated,
                                     intervalText: intervalText,
                                     onRemove: { onRemove(item.id) })
            }
        }
    }

    private var coverageFootnote: String {
        var note = "命中数为 0 只说明「这一帧没有匹配的进程」，不说明服务出了问题。"
        if isTruncated {
            note += "本轮取线程 / 句柄的时间预算已用完，覆盖度见各卡里的 N/M。"
        }
        return note
    }

    /// 屏上留的那半句（挡的是「服务挂了」这个误读）；完整口径进 ⓘ。
    static let zeroMatchReading = "命中数为 0 只说明「这一帧没有匹配的进程」"
}

/// 单组汇总：组头（含状态徽标）+ 匹配模式提示 + 四项指标（CPU 核当量 / 内存 / 线程 / 打开文件）。
struct PerformanceGroupCard: View {
    let group: ProcessGroupSnapshot
    let context: SampleContext
    let isTruncated: Bool
    let intervalText: String
    let onRemove: () -> Void

    private static let cellColumns = [GridItem(.flexible(), spacing: Theme.Spacing.md),
                                      GridItem(.flexible(), spacing: Theme.Spacing.md)]

    private var pattern: String { group.group.matchPattern }
    private var coreCount: Int { max(1, context.snapshot?.cpuCoreCount ?? 1) }
    private var state: GroupMatchState { PerformanceGroupCard.matchState(context: context, group: group) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            header
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xxs) {
                // 屏上只留**这一组在匹配什么**（模式本身是数据），
                // 「怎么匹配的」进 ⓘ —— ⓘ 里放的仍是目录里那条**整句键**，不改原文
                // （`LocalizationGuardTests` 守卫 3 钉着：动了原文就是烂尾键）。
                Text(localizedFormat("匹配模式 %@", pattern))
                    .font(Theme.Typo.monoSmall.font)
                    .foregroundStyle(deEmphasized ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.middle)
                CopyHelpBadge(localizedFormat("匹配模式 %1$@ · 对进程名与命令行做包含匹配", pattern))
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // **不再画井**：旧写法是卡一口 `.contentInset` + 里面四个格子各一口井 = 井里套井，
        // 那是「界面发脏」的成因。契约 3 里井只给表格 / 日志列表 / 代码块，
        // 一张分组汇总卡不是井。组界交给页头的 `groupLabel` + `Spacing.group` 留白 + 一条分隔线。
    }

    /// 零命中的卡整体弱化：标题降级为次要墨色，不铺任何指标数字。
    private var deEmphasized: Bool { state != .matched }

    private var header: some View {
        HStack(spacing: Theme.Spacing.xxs) {
            Text(group.group.title)
                .font(Theme.Typo.cardTitle.font)
                .foregroundStyle(deEmphasized ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(1)
            ThemedIcon(statusIcon, role: .badge)
                .foregroundStyle(PerformanceGroupCard.badgeRole(for: state).textColor)
                .help(PerformanceGroupCard.copy(for: state, pattern: pattern,
                                                totalProcesses: context.snapshot?.processCount,
                                                intervalText: intervalText).title)
            SemanticBadge(PerformanceGroupCard.badgeText(for: state),
                          role: PerformanceGroupCard.badgeRole(for: state))
            Spacer(minLength: Theme.Spacing.xs)
            Button(action: onRemove) {
                ThemedIcon(.remove, role: .badge, label: "移除分组规则")
            }
            .buttonStyle(.plain)
            .frame(minWidth: Theme.Layout.minHitTarget, minHeight: Theme.Layout.minHitTarget)
            .help(Text(localizedFormat("移除分组规则「%@」，只删规则，不干预任何进程", group.group.title)))
        }
    }

    private var statusIcon: IconName {
        switch state {
        case .waitingFirstSample: return .refresh
        case .pausedWithoutMatch: return .pause
        case .noMatch: return .emptyUnknown
        case .matched: return .noRisk
        }
    }

    // MARK: 状态判定与文案（纯函数面，单测直接钉）

    static func matchState(context: SampleContext, group: ProcessGroupSnapshot) -> GroupMatchState {
        if !group.matchedProcesses.isEmpty { return .matched }
        if context.snapshot == nil { return .waitingFirstSample }
        return context.isPaused ? .pausedWithoutMatch : .noMatch
    }

    static func badgeText(for state: GroupMatchState) -> String {
        switch state {
        case .waitingFirstSample: return "等待样本"
        case .pausedWithoutMatch: return "采样暂停"
        case .noMatch: return "零命中"
        case .matched: return "命中中"
        }
    }

    static func badgeRole(for state: GroupMatchState) -> Theme.SemanticRole {
        switch state {
        case .waitingFirstSample: return Theme.Semantic.neutral
        case .pausedWithoutMatch: return Theme.Semantic.warning
        case .noMatch: return Theme.Semantic.neutral
        case .matched: return Theme.Semantic.success
        }
    }

    /// 三段式：现状 / 为什么 / 下一步（《40 WS-H》§7.4）。
    ///
    /// `intervalText` 是节拍文案，**默认值也从唯一真值算出来**（性能 spec §5.1：
    /// 页面里再写一个 `1.5 秒` 字面量，节拍一改界面就说谎）。调用方有 monitor 时应显式传
    /// `monitor.sampleIntervalText`；默认值只为让纯函数面在单测里可直接调。
    static func copy(for state: GroupMatchState, pattern: String, totalProcesses: Int?,
                     intervalText: String =
                        "\(Double(MachSystemMonitor.defaultSampleIntervalMilliseconds) / 1000) 秒") ->
        (title: String, message: String, nextStep: String) {
        let scanned = totalProcesses.map { NumberFormat.grouped($0) } ?? Live.missing
        switch state {
        case .waitingFirstSample:
            return ("正在采集首个样本",
                    "首个样本到达后才按匹配模式统计，不预先给出估算值。",
                    "保持「继续」状态，下一帧（约 \(intervalText)后）会立即出数。")
        case .pausedWithoutMatch:
            return ("采样已暂停",
                    "暂停期间不再查找进程，这里显示的是最后一次采集的结果：全系统 \(scanned) 个进程里没有命中「\(pattern)」。",
                    "点页面右上角「继续」恢复采样，再判断服务是否真的没在跑。")
        case .noMatch:
            return ("未检测到匹配进程",
                    "全系统 \(scanned) 个进程里没有任何条目命中「\(pattern)」，因此没有 CPU / 内存 / 线程 / 打开文件数值可显示。",
                    "确认该服务已启动，或在「匹配模式」里把规则改宽一点（例如从 mysqld 改成 mysql）。")
        case .matched:
            return ("", "", "")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .matched:
            LazyVGrid(columns: Self.cellColumns, spacing: Theme.Spacing.md) {
                cpuCell
                memoryCell
                threadsCell
                openFilesCell
            }
        default:
            emptyBlock
        }
    }

    private var emptyBlock: some View {
        let copy = PerformanceGroupCard.copy(for: state, pattern: pattern,
                                             totalProcesses: context.snapshot?.processCount,
                                             intervalText: intervalText)
        return VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xxs) {
                // **全场最重的三态整句按「留短藏长」落地**：屏上留 `title` 那一句最短结论
                // （「采样已暂停」/「未检测到匹配进程」/「正在采集首个样本」），
                // 成因整句进 ⓘ。三态的 `message` 文本一字未改、也不合并成通用话 ——
                // 搬的是落点，不是语义（AGENTS 第四轮红线 5）。
                Text(copy.title)
                    .font(Theme.Typo.cardTitle.font)
                    .foregroundStyle(.secondary)
                CopyHelpBadge(copy.message)
            }
            DataRowSeparator()
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xxs) {
                // 「下一步」是引导文字而不是链接：蓝在这套体系里只代表交互 / 选中
                // （风格契约 5），给它涂 accent 等于把交互语义稀释掉。
                // 双通道靠 `disclose` 箭头符号 + 文字本身，不靠颜色。
                ThemedIcon(.disclose, role: .badge)
                    .foregroundStyle(.secondary)
                Text(copy.nextStep)
                    .font(Theme.Typo.label.font)
                    .foregroundStyle(.secondary)
                    .lineSpacing(Theme.Typo.label.lineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Theme.Spacing.xs)
        .accessibilityElement(children: .combine)
    }

    private var cpuCell: some View {
        let cores = context.hasDerivative ? group.totalCPU : nil
        return GroupMetricCell(
            label: "CPU 核当量",
            value: Live.cores(cores),
            caption: cores.map { "占全机 \(Live.percent($0 / Double(coreCount), precision: 0))" }
                ?? "差分帧未到，不给百分比",
            tint: LoadLevel.role(for: cores.map { $0 / Double(coreCount) }).textColor,
            // 一组里唯一的重音：吃几个核。其余三格留在 13pt。
            tier: Theme.Typo.metricMid
        )
    }

    private var memoryCell: some View {
        GroupMetricCell(
            label: "内存合计",
            value: Live.bytes(group.totalMemoryBytes),
            caption: ProcessMetric.peakMemory(of: group).map { "单进程峰值 \(Live.bytes($0))" } ?? "无成员进程",
            tint: Theme.Palette.Surface.ink
        )
    }

    private var threadsCell: some View {
        GroupMetricCell(
            label: "线程",
            value: Live.grouped(ProcessMetric.groupThreads(of: group)),
            caption: coverageCaption(ProcessMetric.threadsCovered(in: group),
                                     meaningEmpty: "全部成员进程的 task_info 都没返回线程数"),
            tint: .primary
        )
    }

    private var openFilesCell: some View {
        GroupMetricCell(
            label: "打开文件",
            value: Live.grouped(ProcessMetric.groupOpenFiles(of: group)),
            caption: coverageCaption(ProcessMetric.openFilesCovered(in: group),
                                     meaningEmpty: isTruncated
                                        ? "本轮取句柄的时间预算已用完，一个都没读到"
                                        : "全部成员进程的句柄数都未取到"),
            tint: .primary
        )
    }

    /// 把「几个进程真的取到了」量化到组内，而不是用一个总数冒充全覆盖。
    private func coverageCaption(_ covered: Int, meaningEmpty: String) -> String {
        guard group.processCount > 0 else { return "无成员进程" }
        if covered == 0 { return meaningEmpty }
        return "\(NumberFormat.grouped(covered))/\(NumberFormat.grouped(group.processCount)) 个进程取到"
    }
}

/// 组内一格指标：micro-label 标签 + 数字 + 一行口径说明。**不画面**。
///
/// 旧实现每格套一口 `.contentInset` 井，而卡本身又是一口井 —— 井里套井就是
/// 「整个界面黑黢黢很脏」在进程分组上的具体形态。
///
/// 数字默认 13pt（`monoBody`）；一组里**只有 CPU 那一格**抬到 `metricMid`(22)，
/// 因为用户在这张卡上要扫的就是「这一组现在吃几个核」。四格平铺 22pt 会变成
/// 「四枚 22 争位」，而本页的主角已经是顶部 34pt 读数带，不该在每个分组里再造主角。
private struct GroupMetricCell: View {
    let label: String
    let value: String
    let caption: String
    let tint: Color
    var tier: Theme.TypeToken = Theme.Typo.monoBody

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(label)
                .typed(Theme.Typo.groupLabel)
                .foregroundStyle(.secondary)
            LiveNumber(value, tier: tier, tint: tint)
            Text(caption)
                .typed(Theme.Typo.label)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
