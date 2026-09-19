import SwiftUI

// MARK: - 进程占用排行（只读表）

/// 排序口径。CPU 用**核当量**而不是百分比堆叠：`1.00` 就是占满一个核，
/// 八核机上再忙也只到 8.00，不会像百分比那样堆出「780%」这种读不懂的数。
enum ProcessSortKey: String, CaseIterable, Identifiable {
    case cpuCores
    case memory

    var id: String { rawValue }
    var title: String { self == .cpuCores ? "按 CPU 核当量" : "按内存" }
}

/// 对标活动监视器的进程表：列名固定、数值列右对齐等宽、只读、不给行内操作。
struct PerformanceProcessTableCard: View {
    let rows: [ProcessSnapshot]
    let context: SampleContext
    @Binding var sortKey: ProcessSortKey
    let measuredCount: Int
    let totalCount: Int?
    let isTruncated: Bool

    private static let rowLimit = 20

    var body: some View {
        GlassSection("进程占用排行",
                     subtitle: coverageNote,
                     icon: .processes,
                     trailing: AnyView(sortPicker)) {
            if shown.isEmpty {
                EmptyStateView(icon: IconName.emptyTray.rawValue,
                               title: "尚未采到进程数据",
                               message: "完成一次采样后会列出占用最高的进程（PID、名称、CPU 核当量、内存、线程、打开文件）。")
            } else {
                table
                if rows.count > shown.count {
                    NoteLine("已按当前排序列出前 \(NumberFormat.grouped(shown.count)) 项，另有 \(NumberFormat.grouped(rows.count - shown.count)) 个进程未列出。")
                }
                honestyLegend
            }
        }
    }

    private var shown: [ProcessSnapshot] { Array(rows.prefix(Self.rowLimit)) }

    /// 排名只建立在「本用户可查询」的那部分进程上，全系统总数走 sysctl——
    /// 两个数都摊开写，不拿子集的排名冒充全系统的排名。
    private var coverageNote: String {
        guard let totalCount, totalCount > 0, measuredCount > 0 else {
            return "只读展示，不提供任何进程操作"
        }
        var note = "已取指标 \(NumberFormat.grouped(measuredCount)) / 全系统 \(NumberFormat.grouped(totalCount)) 个进程 · 只读"
        if isTruncated { note += " · 句柄列受时间预算限制" }
        return note
    }

    private var sortPicker: some View {
        Picker("排序", selection: $sortKey) {
            ForEach(ProcessSortKey.allCases) { key in Text(key.title).tag(key) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: DataColumn.sortPicker)
        .help("切换排序口径；两种都是全系统范围的占用排序")
    }

    private var table: some View {
        Grid(alignment: .trailing, horizontalSpacing: Theme.Spacing.sm, verticalSpacing: Theme.Spacing.xxs) {
            GridRow {
                TableHeaderCell("进程名称", trailing: false)
                    .gridColumnAlignment(.leading)
                TableHeaderCell("PID", width: DataColumn.pid, help: "进程号，只读展示")
                TableHeaderCell("CPU 核", width: DataColumn.cpuCores,
                                help: "单核等价：1.00 = 占满一个核心，可大于 1")
                TableHeaderCell("内存", width: DataColumn.memory, help: "常驻内存 RSS")
                TableHeaderCell("线程", width: DataColumn.threads, help: "task_info 返回的线程数")
                TableHeaderCell("打开文件", width: DataColumn.openFiles,
                                help: "进程当前持有的描述符数量")
            }
            Divider().gridCellColumns(6)
            ForEach(shown) { process in
                row(process)
            }
        }
    }

    private func row(_ process: ProcessSnapshot) -> some View {
        let cores = ProcessMetric.cpuCores(of: process)
        return GridRow {
            Text(process.name)
                .font(Theme.Typo.body.font)
                .lineLimit(1)
                .truncationMode(.middle)
                .flexCell()
            LiveNumber(Live.grouped(Int(process.pid)), tier: Theme.Typo.monoSmall)
                .numberCell(DataColumn.pid)
            LiveNumber(Live.cores(context.hasDerivative ? cores : nil),
                       tier: Theme.Typo.monoSmall,
                       tint: Self.cpuTint(cores: context.hasDerivative ? cores : nil))
                .numberCell(DataColumn.cpuCores)
                .help(context.hasDerivative
                        ? "单核等价 \(Live.cores(cores))"
                        : "进程 CPU 也是差分指标：上一帧未到时不给 0")
            LiveNumber(Live.bytes(ProcessMetric.residentBytes(of: process)),
                       tier: Theme.Typo.monoSmall)
                .numberCell(DataColumn.memory)
            LiveNumber(Live.grouped(ProcessMetric.threads(of: process)),
                       tier: Theme.Typo.monoSmall)
                .numberCell(DataColumn.threads)
            LiveNumber(Live.grouped(ProcessMetric.openFiles(of: process)),
                       tier: Theme.Typo.monoSmall)
                .numberCell(DataColumn.openFiles)
        }
        .help(process.commandLine.isEmpty ? process.name : process.commandLine)
    }

    /// 把「--」的含义写在表旁边：0 不是「没有线程 / 没打开文件」，而是没读到。
    private var honestyLegend: some View {
        NoteLine(isTruncated
                 ? "线程 / 打开文件显示 -- 表示本轮未取到（内核任务或时间预算已截断），不表示数量为 0。"
                 : "线程 / 打开文件显示 -- 表示未取到（内核任务或无权限），不表示数量为 0。",
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
