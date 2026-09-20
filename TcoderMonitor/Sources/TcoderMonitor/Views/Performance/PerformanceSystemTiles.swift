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
                NoteLine(SystemReadings.memoryCaliber,
                         role: memoryIsMissing ? Theme.Semantic.warning : Theme.Semantic.neutral,
                         icon: memoryIsMissing ? .riskWarning : .info)
                statusStrip
            }
        }
    }

    private var sectionSubtitle: String {
        guard let cores = SystemReadings.coreCount(context) else { return "等待首个样本" }
        return "\(cores) 个核心 · 口径与活动监视器一致"
    }

    private var memoryIsMissing: Bool { SystemReadings.memoryUsedBytes(context) == nil }

    // MARK: 四枚 tile

    private var cpuTile: some View {
        let fraction = SystemReadings.cpuFraction(context)
        let role = LoadLevel.role(for: fraction)
        let cores = SystemReadings.coresInUse(context)
        return gauged(
            MetricTile(
                label: "CPU",
                value: fraction == nil ? nil : Live.percent(fraction, precision: 0),
                caption: cpuCaption(cores: cores),
                // 34pt 的主读数一律纯墨（风格契约 4）。档位语义交给下面那条量条
                // （`gauged(..., graphic: role.graphicColor)`）—— 参考图就是这个分工：
                // 数字负责读，小面积色负责说"这值要紧"。
                // 原来四格里两格被涂成绿/红，两格是墨，同排读数互相抢注意力。
                systemImage: IconName.cpu.rawValue
            ),
            fraction: fraction,
            graphic: role.graphicColor
        )
    }

    private var memoryTile: some View {
        let used = SystemReadings.memoryUsedBytes(context)
        let total = SystemReadings.memoryTotalBytes(context)
        let fraction = SystemReadings.memoryFraction(context)
        let pressure = SystemReadings.memoryPressure(context)
        let role = LoadLevel.role(for: fraction)
        return gauged(
            MetricTile(
                label: "内存",
                value: used == nil ? nil : Live.bytes(used, precision: 1),
                unit: (used != nil && total != nil) ? "/ \(Live.bytes(total, precision: 0))" : nil,
                caption: used == nil
                    ? (SystemReadings.memoryGapReason(context) ?? "等待首个样本")
                    : "在用 \(Live.percent(fraction, precision: 0)) · 压力 \(pressure?.rawValue ?? Live.missing)",
                tint: Theme.Palette.Surface.ink,
                systemImage: IconName.memory.rawValue
            ),
            fraction: fraction,
            graphic: role.graphicColor
        )
    }

    private var diskTile: some View {
        let total = SystemReadings.diskBytesPerSecond(context)
        return gauged(
            MetricTile(
                label: "磁盘吞吐",
                value: total == nil ? nil : Live.rate(total),
                caption: total == nil
                    ? "首个差分帧到达前不给速率"
                    : "读 \(Live.rate(SystemReadings.diskReadBytesPerSecond(context))) / 写 \(Live.rate(SystemReadings.diskWriteBytesPerSecond(context)))",
                systemImage: IconName.disk.rawValue
            ),
            fraction: nil
        )
    }

    private var networkTile: some View {
        let total = SystemReadings.networkBytesPerSecond(context)
        return gauged(
            MetricTile(
                label: "网络吞吐",
                value: total == nil ? nil : Live.bitRate(total),
                caption: total == nil
                    ? "首个差分帧到达前不给速率"
                    : "↓ \(Live.bitRate(SystemReadings.networkInBytesPerSecond(context))) / ↑ \(Live.bitRate(SystemReadings.networkOutBytesPerSecond(context)))",
                systemImage: IconName.network.rawValue
            ),
            fraction: nil
        )
    }

    /// tile 下面挂一条量表；无数据时保留等高占位，不让整块高度跳动。
    ///
    /// `graphic` 只收**语义**图形色（`LoadLevel.role.graphicColor`）。吞吐类指标没有
    /// 可信分母、也没有好坏分档，所以既不给它画量表、也不给它涂分类色 ——
    /// 旧写法把磁盘涂紫、网络涂青，是无端让眼睛读出「这两件事性质不同」。
    @ViewBuilder
    private func gauged(_ tile: MetricTile, fraction: Double?, graphic: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            tile
            if let fraction, let graphic {
                MiniBarGauge(fraction: fraction, tint: graphic, height: Theme.Layout.gaugeInline)
            } else {
                Color.clear.frame(height: Theme.Layout.gaugeInline)
            }
        }
    }

    private func cpuCaption(cores: Double?) -> String {
        guard let snapshot = context.snapshot else { return "正在采集首个样本" }
        let load = "\(Live.fixed(snapshot.loadAverage1, digits: 2)) / "
            + "\(Live.fixed(snapshot.loadAverage5, digits: 2)) / "
            + "\(Live.fixed(snapshot.loadAverage15, digits: 2))"
        guard context.hasDerivative else { return "负载 \(load) · 差分帧未到，占用率暂不给出" }
        return "在用 \(Live.cores(cores)) 核 / 共 \(snapshot.cpuCoreCount) 核 · 负载 \(load)"
    }

    // MARK: 机器状态条

    private var statusStrip: some View {
        HStack(spacing: Theme.Spacing.xs) {
            ThemedIcon(.temperature, role: .badge).foregroundStyle(.secondary)
            // **一个** Text，而不是"五段 + 两个间隔点"抢一行：
            // 后者在窄窗口下按弹性比例压缩每段，`·` 会单独留在行尾（清单 2.14）。
            // 同页 `sampleStats` 本来就是拼成单串的写法 —— 两种写法并存就是"不规整"本身。
            Text("机身 \(context.snapshot?.thermalState.rawValue ?? Live.missing)"
                 + " · 已运行 \(Self.uptimeText(context.snapshot?.uptimeSeconds))"
                 + " · 全系统 \(Live.grouped(context.snapshot?.processCount)) 个进程")
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
        if days > 0 { return "\(days) 天 \(hours) 小时" }
        if hours > 0 { return "\(hours) 小时 \(minutes) 分" }
        return "\(minutes) 分"
    }
}
