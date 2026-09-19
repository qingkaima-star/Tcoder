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
    let onRemove: (UUID) -> Void

    private static let columns = [GridItem(.adaptive(minimum: Theme.Layout.twoColumnMinWidth),
                                           spacing: Theme.Spacing.sm)]

    var body: some View {
        GlassSection("进程分组",
                     subtitle: "按匹配模式在全系统进程里查找，与所选项目无关",
                     icon: .handles) {
            if groups.isEmpty {
                EmptyStateView(icon: IconName.add.rawValue,
                               title: "还没有分组规则",
                               message: "在下方「匹配模式」里添加分组，例如 java、nginx、mysqld 这类通用进程名。")
            } else {
                LazyVGrid(columns: Self.columns, spacing: Theme.Spacing.sm) {
                    ForEach(groups) { item in
                        PerformanceGroupCard(group: item,
                                             context: context,
                                             isTruncated: isTruncated,
                                             onRemove: { onRemove(item.id) })
                    }
                }
                NoteLine(coverageFootnote)
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
}

/// 单组汇总：组头（含状态徽标）+ 匹配模式提示 + 四项指标（CPU 核当量 / 内存 / 线程 / 打开文件）。
struct PerformanceGroupCard: View {
    let group: ProcessGroupSnapshot
    let context: SampleContext
    let isTruncated: Bool
    let onRemove: () -> Void

    private static let cellColumns = [GridItem(.flexible(), spacing: Theme.Spacing.sm),
                                      GridItem(.flexible(), spacing: Theme.Spacing.sm)]

    private var pattern: String { group.group.matchPattern }
    private var coreCount: Int { max(1, context.snapshot?.cpuCoreCount ?? 1) }
    private var state: GroupMatchState { PerformanceGroupCard.matchState(context: context, group: group) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            header
            Text("匹配模式 \(pattern) · 对进程名与命令行做包含匹配")
                .font(Theme.Typo.monoSmall.font)
                .foregroundStyle(deEmphasized ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .truncationMode(.middle)
            content
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(layer: .contentInset, shape: .rounded(Theme.Radius.md))
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
                                                totalProcesses: context.snapshot?.processCount).title)
            SemanticBadge(PerformanceGroupCard.badgeText(for: state),
                          role: PerformanceGroupCard.badgeRole(for: state))
            Spacer(minLength: Theme.Spacing.xs)
            Button(action: onRemove) {
                ThemedIcon(.remove, role: .badge, label: "移除分组规则")
            }
            .buttonStyle(.plain)
            .frame(minWidth: Theme.Layout.minHitTarget, minHeight: Theme.Layout.minHitTarget)
            .help("移除分组规则「\(group.group.title)」，只删规则，不干预任何进程")
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
    static func copy(for state: GroupMatchState, pattern: String, totalProcesses: Int?) ->
        (title: String, message: String, nextStep: String) {
        let scanned = totalProcesses.map { NumberFormat.grouped($0) } ?? Live.missing
        switch state {
        case .waitingFirstSample:
            return ("正在采集首个样本",
                    "首个样本到达后才按匹配模式统计，不预先给出估算值。",
                    "保持「继续」状态，下一帧（约 1.5 秒后）会立即出数。")
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
            LazyVGrid(columns: Self.cellColumns, spacing: Theme.Spacing.sm) {
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
                                             totalProcesses: context.snapshot?.processCount)
        return VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(copy.title)
                .font(Theme.Typo.cardTitle.font)
                .foregroundStyle(.secondary)
            Text(copy.message)
                .font(Theme.Typo.label.font)
                .foregroundStyle(.tertiary)
                .lineSpacing(Theme.Typo.label.lineSpacing)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xxs) {
                ThemedIcon(.disclose, role: .badge)
                    .foregroundStyle(Theme.Semantic.accent.textColor)
                Text(copy.nextStep)
                    .font(Theme.Typo.label.font)
                    .foregroundStyle(Theme.Semantic.accent.textColor)
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
            tint: LoadLevel.role(for: cores.map { $0 / Double(coreCount) }).textColor
        )
    }

    private var memoryCell: some View {
        GroupMetricCell(
            label: "内存合计",
            value: Live.bytes(group.totalMemoryBytes),
            caption: ProcessMetric.peakMemory(of: group).map { "单进程峰值 \(Live.bytes($0))" } ?? "无成员进程",
            tint: Theme.Semantic.neutral.textColor
        )
    }

    private var threadsCell: some View {
        GroupMetricCell(
            label: "线程",
            value: Live.grouped(ProcessMetric.groupThreads(of: group)),
            caption: coverageCaption(ProcessMetric.threadsCovered(in: group),
                                     meaningEmpty: "全部成员进程的 task_info 都没返回线程数"),
            tint: Theme.Semantic.neutral.textColor
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
            tint: Theme.Semantic.neutral.textColor
        )
    }

    /// 把「几个进程真的取到了」量化到组内，而不是用一个总数冒充全覆盖。
    private func coverageCaption(_ covered: Int, meaningEmpty: String) -> String {
        guard group.processCount > 0 else { return "无成员进程" }
        if covered == 0 { return meaningEmpty }
        return "\(NumberFormat.grouped(covered))/\(NumberFormat.grouped(group.processCount)) 个进程取到"
    }
}

/// 组内一格指标：18pt 等宽中数字 + 一行口径说明。
private struct GroupMetricCell: View {
    let label: String
    let value: String
    let caption: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(label)
                .font(Theme.Typo.microLabel.font)
                .foregroundStyle(.secondary)
            LiveNumber(value, tier: Theme.Typo.metricMid, tint: tint)
            Text(caption)
                .font(Theme.Typo.label.font)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.xs)
        .surface(layer: .contentInset, shape: .rounded(Theme.Radius.sm))
    }
}
