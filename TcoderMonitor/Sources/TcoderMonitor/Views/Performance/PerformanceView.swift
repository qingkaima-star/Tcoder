import SwiftUI

/// OWNER: WS-M / 性能监控页（杀手功能，对标活动监视器）。
///
/// 数据：系统级实时读数全部来自 `state.monitor`，`report` 只用于标出当前项目。
/// 铁律：本页**只读观测**，不给任何进程操作；未取到的读数一律 `--`，
/// 绝不用 0 或绿色正常冒充（三态句式见《40 WS-H》§7.3）。
///
/// 版面按《40 WS-H》§8.6 的首屏聚焦顺序：工具条 → 系统四指标 → 实时曲线 →
/// 进程分组 → 进程占用排行 → 匹配模式编辑器置底。
struct PerformanceView: View {
    var report: ProjectReport?

    @Environment(AppState.self) private var state

    @State private var sortKey: ProcessSortKey = .cpuCores

    /// 曲线滚动窗口点数。**只给点数**——节拍与窗口秒数都由 `MachSystemMonitor`
    /// 那份唯一真值派生（性能 spec §5.1：页面里再写一个 `1.5` 就是第二个真值来源，
    /// 节拍一改，界面必然说谎）。90 点 × 1.5 秒 ≈ 135 秒。
    private static let chartPointLimit = 90

    private var monitor: MachSystemMonitor { state.monitor }
    private var context: SampleContext { SampleContext.from(monitor) }

    /// 节奏文案。**暂停时不许继续宣称"每 X 秒"**——那时屏幕上的数不再按那个节奏更新。
    /// 读数本身仍是真的（末值有效），说谎的是"节奏"这两个字（性能 spec §5.1 第 4 条）。
    private var cadenceText: String {
        context.isPaused ? localizedCopy("采样已暂停")
            : localizedFormat("每 %@", monitor.sampleIntervalText)
    }

    var body: some View {
        // 版框走基座那一份页骨架（组间 32 / 页边距 24 / 顶部段落 40，全仓只许一份）。
        Theme.Page.Scaffold {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                header
                sampleStats
            }
            statusBanners
            PerformanceSystemTiles(context: context)
            PerformanceLiveCharts(points: chartWindow,
                                  context: context,
                                  windowSeconds: monitor.windowSeconds(pointCount: Self.chartPointLimit),
                                  cadenceText: cadenceText)
            PerformanceProcessGroupsCard(groups: monitor.trackedGroups,
                                         context: context,
                                         isTruncated: monitor.processMetricsTruncated,
                                         intervalText: monitor.sampleIntervalText,
                                         onRemove: { monitor.removeGroup(id: $0) })
            PerformanceProcessTableCard(rows: rankedProcesses,
                                        context: context,
                                        sortKey: $sortKey,
                                        measuredCount: monitor.measuredProcessCount,
                                        totalCount: monitor.latestSnapshot?.processCount,
                                        isTruncated: monitor.processMetricsTruncated)
            PerformanceMatcherEditor(onAdd: { title, pattern in
                _ = monitor.addGroup(title: title, matchPattern: pattern)
            })
        }
    }

    private var chartWindow: [SystemSnapshot] {
        Array(monitor.history.suffix(Self.chartPointLimit))
    }

    private var rankedProcesses: [ProcessSnapshot] {
        switch sortKey {
        case .cpuCores: return monitor.topProcesses
        case .memory: return monitor.processesByMemory
        }
    }

    // MARK: - 页内小标题（页头归 WS-O：项目名 / 路径 / 分析时间在 `ProjectDetailView`）

    /// 只标「这一页是什么 + 这一页的口径」，控件由本页自己摆。
    /// 图标一律灰阶（结构去色，风格契约 5），口径句固定第二行 11pt `.secondary`。
    private var header: some View {
        // 三页手写的标题行收成基座一处（`Theme.Page.Header`）。
        // 原来九页里只有这三页有 H1，且各自抄一遍同样的 HStack ——
        // 同一段版式三份，就是"页级层级有三种状态"的成因。
        Theme.Page.Header(
            title: "性能监控",
            icon: .performance,
            subtitle: "系统级实时读数只观测不干预。数值随采样刷新，取不到的一律显示 --，不会补成 0。",
            isDemo: report?.project.isDemo == true,
            actions: { controls })
    }

    /// 采样元信息：这一屏数据有多新。它不是读数，所以留在标题下方一行、
    /// 11pt 次要墨，**不与页名抢水平线**（原来三枚 `Readout.Field` 与页名同排，
    /// 是「不规整拥挤」的直接来源）。三态与口径文案一字未改。
    private var sampleStats: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text(localizedFormat("上次采样 %1$@ · 采样点 %2$@ · 间隔 %3$@",
                                 DateFormat.sinceDescription(monitor.lastSampleAt),
                                 NumberFormat.grouped(monitor.history.count),
                                 monitor.sampleIntervalText))
                .typed(Theme.Typo.label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    /// 控件层：本页唯一一处真玻璃落点（WS-H §9「玻璃只放导航 / 控件层」）。
    private var controls: some View {
        GlassToolbar {
            GlassButton("重新采样", icon: .refresh, style: .bordered) { monitor.sampleNow() }
            GlassButton(context.isPaused ? "继续" : "暂停",
                        icon: context.isPaused ? .play : .pause,
                        style: .bordered) { monitor.toggleRunning() }
        }
    }

    @ViewBuilder
    private var statusBanners: some View {
        if context.isPaused {
            BannerRow(text: "采样已暂停：下方为最后一次采集结果，点「继续」恢复实时刷新。", style: .warning)
        }
        if let reason = SystemReadings.memoryGapReason(context) {
            BannerRow(text: "内存读数不可信：\(reason)。本页按 -- 显示，未把它画成占满。", style: .error)
        }
    }
}
