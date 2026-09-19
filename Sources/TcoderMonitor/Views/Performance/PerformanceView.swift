import SwiftUI
import Charts

/// OWNER: WS-C / 性能视图。系统级实时数据全部来自 `state.monitor`；`report` 只用于顶部标识当前项目。
/// 本页只做观测与展示，不干预任何进程；未采到的数据一律走空状态，绝不用 0 冒充真实结果。
struct PerformanceView: View {
    var report: ProjectReport?

    @Environment(AppState.self) private var state
    @State private var sortMode: PerformanceSortMode = .cpu
    @State private var newGroupTitle = ""
    @State private var newGroupPattern = ""

    private static let tileColumns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)
    private static let groupColumns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 2)
    private static let chipColumns = [GridItem(.adaptive(minimum: 176), spacing: 8)]
    private static let chartPointCount = 90
    private static let processRowLimit = 20

    private var monitor: MachSystemMonitor { state.monitor }
    private var snapshot: SystemSnapshot? { monitor.latestSnapshot }
    private var history: [SystemSnapshot] { monitor.history }
    private var coreCount: Int { max(1, snapshot?.cpuCoreCount ?? 1) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                toolbar
                if !monitor.isRunning {
                    BannerRow(text: "采样已暂停：下方数值为最后一次采集结果，点击「继续」恢复实时刷新。", style: .warning)
                }
                metricGrid
                liveChartsCard
                processGroupsCard
                topProcessesCard
                groupEditorCard
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(report?.project.name ?? "未选择项目").font(.title3.weight(.semibold)).lineLimit(1)
                    if report?.project.isDemo == true { DemoChip() }
                }
                Text("上次采样 \(DateFormat.sinceDescription(monitor.lastSampleAt)) · 累计采样点 \(NumberFormat.grouped(history.count))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Button { monitor.sampleNow() } label: {
                Label("重新采样", systemImage: "arrow.triangle.2.circlepath")
            }
            .controlSize(.small)
            .help("立即采集一次系统快照")

            Button { monitor.toggleRunning() } label: {
                Label(monitor.isRunning ? "暂停" : "继续", systemImage: monitor.isRunning ? "pause.circle" : "play.circle")
            }
            .controlSize(.small)
            .help(monitor.isRunning ? "暂停后台采样循环" : "恢复后台采样循环")
        }
    }

    // MARK: - System metric tiles

    private var metricGrid: some View {
        LazyVGrid(columns: Self.tileColumns, spacing: 12) {
            gaugedTile(MetricTile(
                label: "CPU",
                value: value { "\(Int(($0.cpuUsage * 100).rounded()))" },
                unit: "%",
                caption: caption { "\($0.cpuCoreCount) 核 · 负载 \(loadText($0.loadAverage1)) / \(loadText($0.loadAverage5)) / \(loadText($0.loadAverage15))" },
                tint: cpuTint,
                systemImage: "cpu"
            ), fraction: snapshot?.cpuUsage, tint: cpuTint)

            gaugedTile(MetricTile(
                label: "内存",
                value: value { ByteFormat.string($0.memoryUsedBytes, precision: 1) },
                unit: snapshot.map { "/ \(ByteFormat.string($0.memoryTotalBytes, precision: 0))" },
                caption: caption { "压力 \($0.memoryPressure.rawValue) · 占 \(NumberFormat.percent($0.memoryFraction, precision: 0))" },
                tint: memoryTint,
                systemImage: "memorychip"
            ), fraction: snapshot?.memoryFraction, tint: memoryTint)

            // 磁盘与网络是速率，没有可信分母，因此只留等高占位而不画进度条。
            gaugedTile(MetricTile(
                label: "磁盘吞吐",
                value: value { ByteFormat.rate($0.diskReadBytesPerSecond + $0.diskWriteBytesPerSecond) },
                caption: caption { "读 \(ByteFormat.rate($0.diskReadBytesPerSecond)) / 写 \(ByteFormat.rate($0.diskWriteBytesPerSecond))" },
                tint: Theme.caution,
                systemImage: "internaldrive"
            ), fraction: nil, tint: Theme.caution)

            gaugedTile(MetricTile(
                label: "网络吞吐",
                value: value { ByteFormat.bitRate($0.networkInBytesPerSecond + $0.networkOutBytesPerSecond) },
                caption: caption { "↓ \(ByteFormat.bitRate($0.networkInBytesPerSecond)) / ↑ \(ByteFormat.bitRate($0.networkOutBytesPerSecond))" },
                tint: Theme.healthy,
                systemImage: "network"
            ), fraction: nil, tint: Theme.healthy)
        }
    }

    /// tile 下方挂一条 MiniBarGauge；无数据时保留等高占位。
    @ViewBuilder
    private func gaugedTile(_ tile: MetricTile, fraction: Double?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            tile
            if let fraction {
                MiniBarGauge(fraction: fraction, tint: tint, height: 5)
            } else {
                Color.clear.frame(height: 5)
            }
        }
    }

    /// 首个样本到达前显示 "--" 而不是 0。
    private func value(_ transform: (SystemSnapshot) -> String) -> String {
        guard let snapshot else { return "--" }
        return transform(snapshot)
    }

    private func caption(_ transform: (SystemSnapshot) -> String) -> String {
        guard let snapshot else { return "正在采集首个样本" }
        return transform(snapshot)
    }

    private func loadText(_ load: Double) -> String { String(format: "%.2f", load) }

    private var cpuTint: Color {
        guard let usage = snapshot?.cpuUsage else { return Theme.neutral }
        if usage >= 0.85 { return Theme.danger }
        return usage >= 0.6 ? Theme.caution : Theme.accent
    }

    private var memoryTint: Color {
        switch snapshot?.memoryPressure ?? .unknown {
        case .normal: return Theme.healthy
        case .warning: return Theme.caution
        case .critical: return Theme.danger
        case .unknown: return Theme.neutral
        }
    }

    // MARK: - Live charts

    private var liveChartsCard: some View {
        SectionCard(
            "实时曲线",
            subtitle: "最近 \(NumberFormat.grouped(min(history.count, Self.chartPointCount))) 点 · 每 1.5 秒",
            icon: IconName.pulse.rawValue
        ) {
            if history.count > 2 {
                let points = Array(history.suffix(Self.chartPointCount))
                VStack(alignment: .leading, spacing: 10) {
                    chartLabel("CPU 占用率（全机 %）", tint: cpuTint)
                    CPUHistoryChart(snapshots: points).frame(height: 120)
                    chartLabel("内存占用率（已用 / 总量 %）", tint: memoryTint)
                    PerformanceMemoryChart(snapshots: points).frame(height: 110)
                    Divider().opacity(0.4)
                    HStack(spacing: 14) {
                        StatLine(label: "进程数", value: value { NumberFormat.grouped($0.processCount) })
                        StatLine(label: "热状态", value: value { $0.thermalState.rawValue })
                        StatLine(label: "运行时长", value: value { uptimeText($0.uptimeSeconds) })
                        StatLine(label: "采样点", value: NumberFormat.grouped(history.count))
                    }
                    .font(.caption)
                }
            } else {
                EmptyStateView(icon: "waveform", title: "正在采集…", message: "首个采样点到达后显示曲线。")
            }
        }
    }

    private func chartLabel(_ text: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(text).font(.system(size: 9)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private func uptimeText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days) 天 \(hours) 小时" }
        return hours > 0 ? "\(hours) 小时 \(minutes) 分" : "\(minutes) 分"
    }

    // MARK: - Tracked process groups

    private var processGroupsCard: some View {
        SectionCard("工程进程组", subtitle: "按匹配模式在全系统进程中查找，与所选项目无关", icon: "circle.grid.cross") {
            if monitor.trackedGroups.isEmpty {
                EmptyStateView(
                    icon: "square.dashed",
                    title: "还没有进程分组",
                    message: "在下方「匹配模式」里添加分组，例如 java、nginx、mysqld 这类通用进程名。"
                )
            } else {
                LazyVGrid(columns: Self.groupColumns, spacing: 12) {
                    ForEach(monitor.trackedGroups) { item in
                        PerformanceGroupCard(group: item, coreCount: coreCount, hasSnapshot: snapshot != nil) {
                            monitor.removeGroup(id: item.id)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Top processes (read-only table)

    private var sortedProcesses: [ProcessSnapshot] {
        sortMode == .cpu ? monitor.topProcesses : monitor.processesByMemory
    }

    private var topProcessesCard: some View {
        SectionCard(
            "Top 进程",
            subtitle: "只读展示，不提供任何进程操作",
            icon: "list.bullet",
            trailing: AnyView(
                Picker("排序", selection: $sortMode) {
                    ForEach(PerformanceSortMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
            )
        ) {
            let rows = Array(sortedProcesses.prefix(Self.processRowLimit))
            if rows.isEmpty {
                EmptyStateView(
                    icon: "tray",
                    title: "尚未采到进程数据",
                    message: "完成一次采样后会列出占用最高的进程（PID、名称、CPU、内存、线程、句柄）。"
                )
            } else {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 5) {
                    GridRow {
                        Text("PID").frame(width: PerfColumns.pid, alignment: .trailing)
                        Text("名称").frame(maxWidth: .infinity, alignment: .leading)
                        Text("CPU").frame(width: PerfColumns.cpu, alignment: .trailing)
                        Text("内存").frame(width: PerfColumns.memory, alignment: .trailing)
                        Text("线程").frame(width: PerfColumns.threads, alignment: .trailing)
                        Text("句柄").frame(width: PerfColumns.files, alignment: .trailing)
                    }
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)

                    Divider().gridCellColumns(6).opacity(0.4)

                    ForEach(rows) { process in
                        GridRow {
                            Text(String(process.pid)).frame(width: PerfColumns.pid, alignment: .trailing)
                            Text(process.name).lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(String(format: "%.1f%%", process.cpuUsage * 100))
                                .foregroundStyle(process.cpuUsage >= 1 ? Theme.caution : Color.secondary)
                                .frame(width: PerfColumns.cpu, alignment: .trailing)
                            Text(ByteFormat.string(process.memoryBytes, precision: 1)).frame(width: PerfColumns.memory, alignment: .trailing)
                            Text(NumberFormat.grouped(process.threadCount)).frame(width: PerfColumns.threads, alignment: .trailing)
                            Text(NumberFormat.grouped(process.openFileCount)).frame(width: PerfColumns.files, alignment: .trailing)
                        }
                        .font(Theme.monoSmall)
                        .foregroundStyle(.secondary)
                        .help(process.commandLine.isEmpty ? process.name : process.commandLine)
                    }
                }
            }
        }
    }

    // MARK: - Group editor

    private var trimmedTitle: String { newGroupTitle.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedPattern: String { newGroupPattern.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canAddGroup: Bool { !trimmedTitle.isEmpty && !trimmedPattern.isEmpty }

    private var groupEditorCard: some View {
        SectionCard("匹配模式", subtitle: "新增或管理全系统进程分组（只读观测）", icon: "plus.circle") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    TextField("匹配模式，如 java", text: $newGroupPattern)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: .infinity)
                    TextField("分组名称，如 后端服务", text: $newGroupTitle)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: .infinity)
                    Button("添加分组") { addGroup() }
                        .controlSize(.small)
                        .disabled(!canAddGroup)
                        .help("按匹配模式新建一个进程分组")
                }
                .onSubmit { if canAddGroup { addGroup() } }

                Text("匹配模式对进程名与命令行做包含匹配，例如 java、nginx、mysqld。")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)

                Divider().opacity(0.4)
                groupChips
            }
        }
    }

    private var groupChips: some View {
        let groups = monitor.groups()
        return Group {
            if groups.isEmpty {
                Text("当前没有任何分组规则。").font(.caption).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: Self.chipColumns, alignment: .leading, spacing: 8) {
                    ForEach(groups) { group in
                        HStack(spacing: 5) {
                            Text(group.title).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                            Text(group.matchPattern).font(Theme.monoSmall).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                            if group.isBuiltIn {
                                Text("内置").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.accent)
                            }
                            Spacer(minLength: 2)
                            Button { monitor.removeGroup(id: group.id) } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.mini)
                            .help("移除分组规则「\(group.title)」，只删除规则，不影响任何进程")
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Theme.subtleBackground, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.gridLine, lineWidth: 1))
                    }
                }
            }
        }
    }

    private func addGroup() {
        guard canAddGroup else { return }
        monitor.addGroup(title: trimmedTitle, matchPattern: trimmedPattern)
        newGroupTitle = ""
        newGroupPattern = ""
    }
}

// MARK: - Local building blocks

/// 表头与数据行共用的列宽。
private enum PerfColumns {
    static let pid: CGFloat = 46
    static let cpu: CGFloat = 52
    static let memory: CGFloat = 62
    static let threads: CGFloat = 40
    static let files: CGFloat = 44
}

private enum PerformanceSortMode: String, CaseIterable, Identifiable {
    case cpu
    case memory

    var id: String { rawValue }
    var title: String { self == .cpu ? "按 CPU 排序" : "按内存排序" }
}

/// 「示例」小标签，与侧栏同一视觉语言。
private struct DemoChip: View {
    var body: some View {
        Text("示例")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Theme.accent.opacity(0.15), in: Capsule())
    }
}

/// 内存占用率曲线，坐标轴写法与 CPUHistoryChart 保持一致。
private struct PerformanceMemoryChart: View {
    var snapshots: [SystemSnapshot]

    var body: some View {
        Chart(snapshots) { item in
            AreaMark(x: .value("时间", item.timestamp), y: .value("内存", item.memoryFraction * 100))
                .interpolationMethod(.monotone)
                .foregroundStyle(LinearGradient(
                    colors: [Theme.caution.opacity(0.40), Theme.caution.opacity(0.04)],
                    startPoint: .top, endPoint: .bottom
                ))
            LineMark(x: .value("时间", item.timestamp), y: .value("内存", item.memoryFraction * 100))
                .interpolationMethod(.monotone)
                .foregroundStyle(Theme.caution)
                .lineStyle(StrokeStyle(lineWidth: 1.6))
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) { _ in
                AxisGridLine().foregroundStyle(Theme.gridLine)
                AxisValueLabel().font(.system(size: 8))
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisValueLabel(format: .dateTime.hour().minute(), centered: false).font(.system(size: 8))
            }
        }
    }
}

/// 单个进程分组：未命中任何进程时给出说明，而不是四个 0。
private struct PerformanceGroupCard: View {
    var group: ProcessGroupSnapshot
    var coreCount: Int
    var hasSnapshot: Bool
    var onRemove: () -> Void

    private static let cellColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 2)

    private var title: String { group.group.title }
    private var pattern: String { group.group.matchPattern }
    private var cpuShare: Double { group.totalCPU / Double(max(1, coreCount)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if group.group.isBuiltIn { DemoChip() }
                Spacer(minLength: 4)
                Text("\(NumberFormat.grouped(group.processCount)) 个进程").font(.system(size: 9)).foregroundStyle(.tertiary)
                Button(action: onRemove) { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
                    .help("移除分组规则「\(title)」，只删除规则，不干预任何进程")
            }
            Text("匹配模式 \(pattern)")
                .font(Theme.monoSmall)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.subtleBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.gridLine, lineWidth: 1))
    }

    @ViewBuilder
    private var content: some View {
        if !hasSnapshot {
            Text("正在采集首个样本，暂无分组数值。")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
        } else if group.matchedProcesses.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("未检测到匹配进程").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Text("全系统进程里没有任何条目命中「\(pattern)」，因此没有 CPU / 内存 / 线程 / 句柄数值可显示。")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        } else {
            LazyVGrid(columns: Self.cellColumns, spacing: 8) {
                PerformanceMetricCell(
                    label: "CPU",
                    value: NumberFormat.percent(cpuShare, precision: 0),
                    caption: String(format: "核当量 %.2f 核 · 占全机 %@", group.totalCPU, NumberFormat.percent(cpuShare, precision: 1)),
                    tint: cpuTint
                )
                PerformanceMetricCell(
                    label: "内存",
                    value: ByteFormat.string(group.totalMemoryBytes, precision: 1),
                    caption: "平均 \(String(format: "%.1f", average(group.totalMemoryBytes))) MB / 进程",
                    tint: Theme.healthy
                )
                PerformanceMetricCell(
                    label: "线程",
                    value: NumberFormat.grouped(group.totalThreads),
                    caption: "平均 \(String(format: "%.1f", average(group.totalThreads))) / 进程",
                    tint: Theme.accent
                )
                PerformanceMetricCell(
                    label: "打开文件",
                    value: NumberFormat.grouped(group.totalOpenFiles),
                    caption: "平均 \(String(format: "%.1f", average(group.totalOpenFiles))) / 进程",
                    tint: Theme.caution
                )
            }
        }
    }

    private var cpuTint: Color {
        if cpuShare >= 0.8 { return Theme.danger }
        return cpuShare >= 0.45 ? Theme.caution : Theme.accent
    }

    /// 每进程均值；内存按 MB 折算。
    private func average(_ total: Int) -> Double {
        guard group.processCount > 0 else { return 0 }
        return Double(total) / Double(group.processCount)
    }

    private func average(_ total: UInt64) -> Double {
        guard group.processCount > 0 else { return 0 }
        return Double(total) / 1_048_576 / Double(group.processCount)
    }
}

private struct PerformanceMetricCell: View {
    var label: String
    var value: String
    var caption: String
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 9)).foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(caption).font(.system(size: 8)).foregroundStyle(.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
