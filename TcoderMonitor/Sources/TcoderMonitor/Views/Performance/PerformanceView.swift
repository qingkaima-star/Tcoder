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

    /// 曲线滚动窗口点数。`MachSystemMonitor` 按 1500 毫秒采样 → 90 点 ≈ 135 秒。
    private static let chartPointLimit = 90
    private static let sampleIntervalText = "1.5 秒"
    private static var windowSeconds: TimeInterval { Double(chartPointLimit) * 1.5 }

    private var monitor: MachSystemMonitor { state.monitor }
    private var context: SampleContext { SampleContext.from(monitor) }

    var body: some View {
        // 页面骨架（左右 16 / 顶 24 / 卡间 16 / 超宽屏限宽居中）来自基座，不再各页手搓
        Theme.Page.Scaffold(maxWidth: Theme.Layout.maxWidthDense) {
            header
            statusBanners
            PerformanceSystemTiles(context: context)
            PerformanceLiveCharts(points: chartWindow,
                                  context: context,
                                  windowSeconds: Self.windowSeconds)
            PerformanceProcessGroupsCard(groups: monitor.trackedGroups,
                                         context: context,
                                         isTruncated: monitor.processMetricsTruncated,
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

    // MARK: - 工具条

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                ThemedIcon(.performance, role: .navigation)
                    .foregroundStyle(Theme.Semantic.accent.textColor)
                Text("性能监控").font(Theme.Typo.pageTitle.font)
                if report?.project.isDemo == true {
                    SemanticBadge("示例", role: Theme.Semantic.info)
                }
                Spacer(minLength: Theme.Spacing.sm)
                sampleStats
                controls
            }
            Text("系统级实时读数只观测不干预。数值随采样刷新，取不到的一律显示 --，不会补成 0。")
                .font(Theme.Typo.label.font)
                .foregroundStyle(.secondary)
        }
    }

    /// 三页共用的「标签 + 数字」读数一律走基座 `Theme.Readout`，
    /// 不再引 WS-K 冻结文件里的 `StatLine`（WS-I §3.5 点名的归属错位）。
    private var sampleStats: some View {
        HStack(spacing: Theme.Spacing.md) {
            Theme.Readout.Field("上次采样", DateFormat.sinceDescription(monitor.lastSampleAt))
            Theme.Readout.Field("采样点", NumberFormat.grouped(monitor.history.count))
            Theme.Readout.Field("间隔", Self.sampleIntervalText)
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
