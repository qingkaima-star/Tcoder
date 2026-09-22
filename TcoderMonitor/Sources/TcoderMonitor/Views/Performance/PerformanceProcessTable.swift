import SwiftUI

// MARK: - 进程占用排行（只读表）

/// 排序口径。CPU 用**核当量**而不是百分比堆叠：`1.00` 就是占满一个核，
/// 八核机上再忙也只到 8.00，不会像百分比那样堆出「780%」这种读不懂的数。
enum ProcessSortKey: String, CaseIterable, Identifiable {
    case cpuCores
    case memory

    var id: String { rawValue }
    var title: String { localizedCopy(self == .cpuCores ? "按 CPU 核当量" : "按内存") }
}

/// 对标活动监视器的进程表：列名固定、数值列右对齐等宽、只读、不给行内操作。
struct PerformanceProcessTableCard: View {
    let rows: [ProcessSnapshot]
    let context: SampleContext
    @Binding var sortKey: ProcessSortKey
    let measuredCount: Int
    let totalCount: Int?
    let isTruncated: Bool

    /// 默认 8 行，与全仓其他榜单同一口径（巨大文件 / 热点函数 / 重复块 / 贡献者 /
    /// 最近提交都是 8）。原来是 20 行，而按 CPU 核当量排序时第 2 行往后几乎全是 0.00
    /// —— 页尾实拍（`.scratch/evidence-8de2d17/light-tail/性能监控.png`）里
    /// 20 行有 19 行的排序键相同，那 19 行对读者不再携带信息，只是把卡片拉长。
    private static let rowLimit = 8

    @State private var expanded = false

    var body: some View {
        GlassSection("进程占用排行",
                     subtitle: coverageNote,
                     icon: .processes,
                     trailing: AnyView(sortPicker)) {
            if shown.isEmpty {
                // 判词说的是「小文案太多」，不是「把话说两遍」。这句预告（列名的枚举）
                // 与表头逐字重复，盘点表 F 组判 `藏` —— 屏上留空态标题那一句，
                // 整句挂在同容器紧跟的 ⓘ 上（`CopyHelpBadge` 是全站唯一那枚问号）。
                EmptyStateView(icon: IconName.emptyTray.rawValue,
                               title: "尚未采到进程数据",
                               message: "")
                CopyHelpBadge("完成一次采样后会列出占用最高的进程（PID、名称、CPU 核当量、内存、线程、打开文件）。")
            } else {
                table
                // 以前这里是一句 `NoteLine`「另有 N 个进程未列出」——**只报数、不给入口**，
                // 读者看完什么也做不了（功能真实性清单 §S4：交互无消费）。
                // 换成全站同一枚展开按钮：折叠这件事由控件自己交代，点得动。
                if rows.count > Self.rowLimit {
                    DataDisclosureButton(expanded: expanded,
                                         hiddenCount: rows.count - Self.rowLimit,
                                         noun: "个进程") {
                        expanded.toggle()
                    }
                }
                honestyLegend
            }
        }
    }

    private var shown: [ProcessSnapshot] {
        expanded ? rows : Array(rows.prefix(Self.rowLimit))
    }

    /// 排名只建立在「本用户可查询」的那部分进程上，全系统总数走 sysctl——
    /// 两个数都摊开写，不拿子集的排名冒充全系统的排名。
    private var coverageNote: String {
        guard let totalCount, totalCount > 0, measuredCount > 0 else {
            return "只读展示，不提供任何进程操作"
        }
        var note = localizedFormat("已取指标 %1$@ / 全系统 %2$@ 个进程 · 只读",
                                   NumberFormat.grouped(measuredCount),
                                   NumberFormat.grouped(totalCount))
        if isTruncated { note += " · 句柄列受时间预算限制" }
        return note
    }

    private var sortPicker: some View {
        // 与错误日志页的时间窗口同一套：一排纯文字 + 发丝下划线。
        // 原来 `.segmented` 给选中项画灰底胶囊（白底之后全站仅剩的两处灰底选中之一），
        // 还要靠 `PerfLogWidths.sortPicker` 定宽去框住它 —— 文字选择器不需要框。
        TextSegmentedPicker(options: ProcessSortKey.allCases,
                            label: \.title,
                            selection: sortKey,
                            onSelect: { sortKey = $0 })
            .accessibilityLabel("排序")
            .help(localizedCopy("切换排序口径；两种都是全系统范围的占用排序"))
    }

    /// 表头与行都从 `DataColumns.processes` 取布局（#34 收敛前这里是 `Grid` +
    /// 逐格手写的 `TableHeaderCell`，列宽与对齐各写一遍）。
    /// 行距走风格契约 8 的「列表行 8」档（原 `xxs`4 是无井时代为了压住四块灰盒的高度，
    /// 面拿掉后 4pt 会把相邻两行的数字读成同一行）。
    private var table: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            DataTableHeader(columns: DataColumns.processes)
            ForEach(shown) { process in
                row(process)
            }
        }
    }

    private func row(_ process: ProcessSnapshot) -> some View {
        let cores = ProcessMetric.cpuCores(of: process)
        return HStack(spacing: DataRowMetrics.cellGap) {
            Text(process.name)
                .font(Theme.Typo.body.font)
                .lineLimit(1)
                .truncationMode(.middle)
                .tableCell(DataColumns.column(DataColumns.processes, 0))
            LiveNumber(Live.grouped(Int(process.pid)), tier: Theme.Typo.monoSmall)
                .tableCell(DataColumns.column(DataColumns.processes, 1))
            LiveNumber(Live.cores(context.hasDerivative ? cores : nil),
                       tier: Theme.Typo.monoSmall,
                       tint: Self.cpuTint(cores: context.hasDerivative ? cores : nil))
                .tableCell(DataColumns.column(DataColumns.processes, 2))
                .help(context.hasDerivative
                        ? "单核等价 \(Live.cores(cores))"
                        : "进程 CPU 也是差分指标：上一帧未到时不给 0")
            LiveNumber(Live.bytes(ProcessMetric.residentBytes(of: process)),
                       tier: Theme.Typo.monoSmall)
                .tableCell(DataColumns.column(DataColumns.processes, 3))
            LiveNumber(Live.grouped(ProcessMetric.threads(of: process)),
                       tier: Theme.Typo.monoSmall)
                .tableCell(DataColumns.column(DataColumns.processes, 4))
            LiveNumber(Live.grouped(ProcessMetric.openFiles(of: process)),
                       tier: Theme.Typo.monoSmall)
                .tableCell(DataColumns.column(DataColumns.processes, 5))
        }
        // 两态各自表态：取到路径就说路径，取不到就明说"只能给出进程名"。
        // 旧写法 `.help(commandLine.isEmpty ? name : commandLine)` 里的 `commandLine`
        // 在路径缺席时装的是进程名 —— 上屏看着像一条真路径。
        .help(ProcessInspector.identityTooltip(for: process))
    }

    /// 把「--」的含义写在表旁边：0 不是「没有线程 / 没打开文件 / 不占内存」，而是没读到。
    /// 内存这一列原本不在名单里 —— 它以前根本不会显示 `--`（`residentBytes` 返回非
    /// Optional，两路都读不到时画成 `0 B`）。批次 P7-B 余量把它并进同一套三态之后，
    /// 这句说明必须一起改，否则图例反而成了"内存那一列的 -- 是别的意思"。
    private var honestyLegend: some View {
        NoteLine(isTruncated
                 ? "内存 / 线程 / 打开文件显示 -- 表示本轮未取到（内核任务或时间预算已截断），不表示数量为 0。"
                 : "内存 / 线程 / 打开文件显示 -- 表示未取到（内核任务或无权限），不表示数量为 0。",
                 icon: .unverified)
    }

    /// 单进程 CPU 分档。决策与着色分开，决策才测得动（`Color` 由动态 NSColor 包出来，
    /// 两次取值不相等——这是 `MetricTile.forcesNeutralTint` 已经踩过的写法）。
    static func cpuLevel(cores: Double?) -> ProcessCPULevel {
        guard let cores else { return .absent }
        if cores >= 2 { return .heavy }
        if cores >= 1 { return .busy }
        return .idle
    }

    /// 低占用不涂色是刻意的——给每个正常进程挂上颜色会把整张表读成一片警告，
    /// 也让「绿」同时承担「正常」和「低占用」两义（违反 WS-H §5.1 一色一义）。
    static func cpuTint(cores: Double?) -> Color {
        switch cpuLevel(cores: cores) {
        case .absent: return Theme.Semantic.neutral.textColor
        case .idle: return Color.secondary
        case .busy: return Theme.Semantic.warning.textColor
        case .heavy: return Theme.Semantic.danger.textColor
        }
    }
}

/// 进程 CPU 的分档语义（着色决策的纯函数面）。
enum ProcessCPULevel: Hashable {
    case absent, idle, busy, heavy
}
