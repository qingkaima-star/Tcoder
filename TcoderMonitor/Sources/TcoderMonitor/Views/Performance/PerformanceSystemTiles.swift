import SwiftUI

// MARK: - 系统四指标

/// 占用率的分级阈值。写在一处、三页共用，不再各卡各定一个魔法数。
///
/// 低档用 `success` 而不是 `accent`：《40 WS-H》§5.1 规定蓝只表示交互 / 选中，
/// 让它兼任「负载正常」就是一色二义。绿 / 橙 / 红与内存压力条同义，色阶单调。
enum LoadLevel {
    static let cautionAt = 0.60
    static let dangerAt = 0.85

    static func role(for fraction: Double?) -> Theme.SemanticRole {
        guard let fraction, fraction.isFinite else { return Theme.Semantic.neutral }
        if fraction >= dangerAt { return Theme.Semantic.danger }
        if fraction >= cautionAt { return Theme.Semantic.warning }
        return Theme.Semantic.success
    }
}

/// 系统资源区：CPU / 内存 / 磁盘 / 网络**一行四枚纯墨读数** + 内存口径声明 + 机器状态条。
///
/// **这一行就是本页的主角**（风格契约 4「最重的墨给最大的数」）。原来它们是
/// `LazyVGrid(adaptive 220)` 里四块 `.contentInset` 灰盒，每块自带一份投影 ——
/// 基座把面与投影摘掉之后，剩下的问题只有「四个 34pt 谁先被读到」，
/// 答案是**都不该抢**：横向读数带 + 列间发丝线就是活动监视器底栏的排法，
/// 它们是一个整体，而不是四张彼此争位的卡。
///
/// 速率类指标没有可信分母，因此只留等高占位而不画进度条——画一条假的满格线比不画更误导。
struct PerformanceSystemTiles: View {
    let context: SampleContext

    var body: some View {
        GlassSection("系统资源", subtitle: sectionSubtitle, icon: .cpu) {
            ReadoutStrip {
                cpuTile
                DataBandSeparator()
                memoryTile
                DataBandSeparator()
                diskTile
                DataBandSeparator()
                networkTile
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                // **边界（整改意见第九节）**：这一页住在项目详情里、页头挂着项目名，
                // 所以四枚整机读数的正下方第一句必须写清"这不是本项目的开销"。
                // 只加说明、**不删任何读数**——删读数才是藏问题。
                // 这一句与 `PerformanceProcessGroupsCard` 的「与所选项目无关」是一对：
                // 系统级读数与按模式归因的进程读数各说各的边界，没有一份在替另一份背书。
                NoteLine("以上是整机读数：含其它项目与系统服务的开销，不构成本项目的性能结论。",
                         icon: .unverified)
                // **留短藏长**（盘点表 F 组）：屏上只留最容易被读错的那半句
                // （「在用」≠「剩余可用」），44 字的完整口径进 ⓘ 的 hover。
                // 长句走 `SystemReadings.memoryCaliber` 那一份唯一真值，不在这里重抄一遍。
                NoteLine("这是「在用」",
                         role: memoryIsMissing ? Theme.Semantic.warning : Theme.Semantic.neutral,
                         icon: memoryIsMissing ? .riskWarning : .info,
                         help: SystemReadings.memoryCaliber)
                statusStrip
            }
        }
    }

    private var sectionSubtitle: String {
        guard let cores = SystemReadings.coreCount(context) else { return "等待首个样本" }
        return localizedFormat("%1$@ 个核心 · 口径与活动监视器一致", String(cores))
    }

    private var memoryIsMissing: Bool { SystemReadings.memoryUsedBytes(context) == nil }

    // MARK: 四枚 tile

    private var cpuTile: some View {
        let fraction = SystemReadings.cpuFraction(context)
        let role = LoadLevel.role(for: fraction)
        let cores = SystemReadings.coresInUse(context)
        return MetricTile(
            label: "CPU",
            value: fraction == nil ? nil : Live.percent(fraction, precision: 0),
            caption: cpuCaption(cores: cores),
            // 34pt 的主读数一律纯墨（风格契约 4）。档位语义交给值下面那条量条
            // （`gauge: Self.gaugeSlot(fraction, role)`）—— 参考图就是这个分工：
            // 数字负责读，小面积色负责说"这值要紧"。
            // 原来四格里两格被涂成绿/红，两格是墨，同排读数互相抢注意力。
            systemImage: IconName.cpu.rawValue,
            gauge: Self.gaugeSlot(fraction, role)
        )
    }

    private var memoryTile: some View {
        let used = SystemReadings.memoryUsedBytes(context)
        let total = SystemReadings.memoryTotalBytes(context)
        let fraction = SystemReadings.memoryFraction(context)
        let pressure = SystemReadings.memoryPressure(context)
        let role = LoadLevel.role(for: fraction)
        return MetricTile(
            label: "内存",
            value: used == nil ? nil : Live.bytes(used, precision: 1),
            // 分子/分母同精度：`48.0 GB / 64 GB` 是同一行里的两套小数位（批次 P5）。
            unit: (used != nil && total != nil) ? "/ \(Live.bytes(total, precision: 1))" : nil,
            caption: used == nil
                    ? (SystemReadings.memoryGapReason(context) ?? "等待首个样本")
                    : localizedFormat("在用 %1$@ · 压力 %2$@",
                        Live.percent(fraction, precision: 0),
                        localizedCopy(pressure?.rawValue ?? Live.missing)),
            tint: Theme.Palette.Surface.ink,
            systemImage: IconName.memory.rawValue,
            gauge: Self.gaugeSlot(fraction, role)
        )
    }

    private var diskTile: some View {
        let total = SystemReadings.diskBytesPerSecond(context)
        return MetricTile(
            label: "磁盘吞吐",
            value: total == nil ? nil : Live.rate(total),
            caption: total == nil
                    ? "首个差分帧到达前，不给速率"
                    : localizedFormat("读 %1$@ / 写 %2$@",
                        Live.rate(SystemReadings.diskReadBytesPerSecond(context)),
                        Live.rate(SystemReadings.diskWriteBytesPerSecond(context))),
            systemImage: IconName.disk.rawValue,
            gauge: .empty   // 没有可信分母：留等高占位，不画假条
        )
    }

    private var networkTile: some View {
        let total = SystemReadings.networkBytesPerSecond(context)
        return MetricTile(
            label: "网络吞吐",
            value: total == nil ? nil : Live.bitRate(total),
            caption: total == nil
                    ? "首个差分帧到达前，不给速率"
                    : "↓ \(Live.bitRate(SystemReadings.networkInBytesPerSecond(context))) / ↑ \(Live.bitRate(SystemReadings.networkOutBytesPerSecond(context)))",
            systemImage: IconName.network.rawValue,
            gauge: .empty
        )
    }

    /// 量条槽的取值。**没有可信分母时占等高而不画条**（画一条假的满格线比不画更误导）。
    /// 槽位本身归 `MetricTile` 管：它必须钉在值与脚注之间，四格才共一条基线 ——
    /// 原来叠在 tile 之后，本格脚注一换行就把量条推下去约 20pt（实拍四格基线全断）。
    ///
    /// `graphic` 只收**语义**图形色（`LoadLevel.role.graphicColor`）。吞吐类指标没有
    /// 可信分母、也没有好坏分档，所以既不给它画量表、也不给它涂分类色 ——
    /// 旧写法把磁盘涂紫、网络涂青，是无端让眼睛读出「这两件事性质不同」。
    static func gaugeSlot(_ fraction: Double?, _ role: Theme.SemanticRole?) -> MetricTile.MetricGauge {
        guard let fraction, let role else { return .empty }
        return .value(fraction, role.graphicColor)
    }

    private func cpuCaption(cores: Double?) -> String {
        guard let snapshot = context.snapshot else { return "正在采集首个样本" }
        let load = "\(Live.fixed(snapshot.loadAverage1, digits: 2)) / "
            + "\(Live.fixed(snapshot.loadAverage5, digits: 2)) / "
            + "\(Live.fixed(snapshot.loadAverage15, digits: 2))"
        guard context.hasDerivative else { return "负载 \(load) · 差分帧未到，占用率暂不给出" }
        return localizedFormat("在用 %1$@ 核 / 共 %2$@ 核 · 负载 %3$@",
                           Live.cores(cores), String(snapshot.cpuCoreCount), load)
    }

    // MARK: 机器状态条

    private var statusStrip: some View {
        HStack(spacing: Theme.Spacing.xs) {
            ThemedIcon(.temperature, role: .badge).foregroundStyle(.secondary)
            // **一个** Text，而不是"五段 + 两个间隔点"抢一行：
            // 后者在窄窗口下按弹性比例压缩每段，`·` 会单独留在行尾（清单 2.14）。
            // 同页 `sampleStats` 本来就是拼成单串的写法 —— 两种写法并存就是"不规整"本身。
            Text(localizedFormat("机身 %1$@ · 已运行 %2$@ · 全系统 %3$@ 个进程",
                                 SystemReadings.thermalText(context),
                                 Self.uptimeText(context.snapshot?.uptimeSeconds),
                                 Live.grouped(context.snapshot?.processCount)))
            Spacer(minLength: 0)
        }
        .font(Theme.Typo.label.font)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    /// 秒 → 「N 天 N 小时 / N 小时 N 分 / N 分」。 uptime 只需要粗粒度，不铺秒。
    static func uptimeText(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return Live.missing }
        let totalMinutes = Int(seconds / 60)
        let days = totalMinutes / (60 * 24)
        let hours = (totalMinutes / 60) % 24
        let minutes = totalMinutes % 60
        if days > 0 { return localizedFormat("%1$@ 天 %2$@ 小时", String(days), String(hours)) }
        if hours > 0 { return localizedFormat("%1$@ 小时 %2$@ 分", String(hours), String(minutes)) }
        return localizedFormat("%@ 分", String(minutes))
    }
}
