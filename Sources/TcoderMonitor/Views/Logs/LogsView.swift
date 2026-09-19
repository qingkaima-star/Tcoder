import SwiftUI
import Charts
import AppKit
import UniformTypeIdentifiers

/// OWNER: Workstream C —— 错误日志页。
/// 数据全部来自 `report?.logs`（缺失时走 EmptyStateView，不拿 0 冒充结果）；
/// 交互（重新分析 / 附加日志文件 / 时间窗口）一律走 `AppState` 已提供的 API。
struct LogsView: View {
    var report: ProjectReport?

    @Environment(AppState.self) private var state

    /// 改动窗口 / 清空附加文件后，若当前无法自动重算，用它提示用户手动重算。
    @State private var pendingRescanNote: String?

    private static let windowChoices: [Int] = [1, 3, 7, 14, 30]
    private static let metricColumns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)
    private static let fileRowLimit = 40
    private static let logFileExtensions = ["log", "out", "txt", "ips", "crash", "text", "json", "diag"]

    var body: some View {
        @Bindable var state = state

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                toolbar(window: $state.logWindowDays)

                if report?.logs == nil {
                    BannerRow(
                        text: "该项目还没有日志分析结果。选择项目目录后点「重新分析」，或手动附加本地日志文件。",
                        style: .info
                    )
                } else if report?.logs?.hasData == false {
                    BannerRow(
                        text: "项目目录与 ~/Library/Logs 里都没有找到可解析的日志文件。用「附加日志文件…」手动选择 error.log、crash.log 后重新分析。",
                        style: .warning
                    )
                }

                if let error = state.lastError {
                    BannerRow(text: error, style: .error)
                }

                metricGrid
                trendCard
                topErrorsCard
                affectedFilesCard
                scannedFilesCard
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
        .onChange(of: state.logWindowDays) { _, days in
            rescanForNewWindow(days)
        }
    }

    // MARK: - Toolbar

    private func toolbar(window: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: IconName.logs.rawValue)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                        Text("错误日志分析").font(.title3.weight(.semibold))
                    }
                    Text(toolbarSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if state.isScanning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(state.phase.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Button {
                    pendingRescanNote = nil
                    state.scanSelected()
                } label: {
                    Label("重新分析", systemImage: "arrow.clockwise")
                }
                .disabled(state.isScanning || state.selectedProject == nil)
                .help("重新扫描项目目录与全部附加日志文件")

                Button {
                    chooseLogFiles()
                } label: {
                    Label("附加日志文件…", systemImage: "doc.badge.plus")
                }
                .disabled(state.selectedProject == nil)
                .help("选择 error.log、crash.log 等本地文件一并分析")

                Button {
                    clearAttachedFiles()
                } label: {
                    Label("清空附加文件", systemImage: "trash")
                }
                .disabled(attachedItems.isEmpty)
                .help("移除本项目全部手动附加的日志文件")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            HStack(spacing: 8) {
                Text("时间窗口")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("时间窗口", selection: window) {
                    ForEach(Self.windowChoices, id: \.self) { day in
                        Text("最近 \(day) 天").tag(day)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("切换后自动重新分析（示例项目与扫描进行中除外）")
                if let note = pendingRescanNote {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(Theme.caution)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            if !attachedItems.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text("已附加 \(attachedItems.count) 个文件")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        ForEach(attachedItems) { item in
                            attachedChip(item)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
        }
        .padding(14)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.gridLine, lineWidth: 1)
        )
    }

    private var toolbarSubtitle: String {
        guard let logs = report?.logs else {
            return "时间窗口 \(state.logWindowDays) 天 · 当前项目尚未分析"
        }
        return "分析于 \(DateFormat.sinceDescription(logs.analyzedAt)) · 时间窗口 \(state.logWindowDays) 天 · 扫描 \(NumberFormat.grouped(logs.totalLinesScanned)) 行"
    }

    /// 直接构造 Binding 写回 `AppState.logWindowDays`，避免为绑定去改 AppState。
    private var logWindowBinding: Binding<Int> {
        Binding(
            get: { state.logWindowDays },
            set: { days in
                guard days != state.logWindowDays else { return }
                state.logWindowDays = days
                guard let project = state.selectedProject else { return }
                if project.isDemo {
                    pendingRescanNote = "示例项目使用内置固定数据，时间窗口不影响结果。"
                } else if state.isScanning {
                    pendingRescanNote = "改窗口后需重新分析。"
                } else {
                    pendingRescanNote = nil
                    state.scan(project: project)
                }
            }
        )
    }

    private func chooseLogFiles() {
        guard let project = state.selectedProject else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "选择要一并分析的日志文件，例如 error.log、crash.log、app.log"
        panel.prompt = "附加"
        panel.allowedContentTypes = Self.logFileExtensions.compactMap { UTType(filenameExtension: $0) }
        if FileManager.default.fileExists(atPath: project.path) {
            panel.directoryURL = project.url
        }
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        let existing = Set((state.extraLogURLs[project.id] ?? []).map(\.path))
        let fresh = panel.urls.filter { !existing.contains($0.path) }
        guard !fresh.isEmpty else { return }
        state.attachLogFiles(to: project.id, urls: fresh)
        pendingRescanNote = nil
        state.scan(project: project)
    }

    private func clearAttachedFiles() {
        guard let project = state.selectedProject else { return }
        guard !attachedItems.isEmpty else { return }
        state.clearAttachedLogs(for: project.id)
        pendingRescanNote = "清空附加文件后需重新分析。"
    }

    private var attachedItems: [AttachedLogItem] {
        guard let project = state.selectedProject else { return [] }
        var seen = Set<String>()
        var items: [AttachedLogItem] = []
        for url in state.extraLogURLs[project.id] ?? [] where seen.insert(url.path).inserted {
            items.append(AttachedLogItem(url: url, sizeBytes: Self.fileSize(of: url)))
        }
        return items
    }

    private static func fileSize(of url: URL) -> UInt64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attrs[.size] as? NSNumber else { return nil }
        return number.uint64Value
    }

    private func attachedChip(_ item: AttachedLogItem) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "paperclip")
                .font(.system(size: 8))
                .foregroundStyle(Theme.accent)
            Text(item.url.lastPathComponent)
                .font(Theme.monoSmall)
                .lineLimit(1)
            if let size = item.sizeBytes {
                Text(ByteFormat.string(size))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Theme.subtleBackground, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.gridLine, lineWidth: 1))
        .help(item.url.path)
    }

    // MARK: - Metric tiles

    private var metricGrid: some View {
        let logs = report?.logs
        return LazyVGrid(columns: Self.metricColumns, spacing: 12) {
            MetricTile(
                label: "今日错误",
                value: logs.map { NumberFormat.grouped($0.todayErrorCount) } ?? "--",
                caption: caption(todayErrorCaption),
                tint: Theme.danger,
                systemImage: "exclamationmark.triangle"
            )
            MetricTile(
                label: "崩溃",
                value: logs.map { NumberFormat.grouped($0.crashCount) } ?? "--",
                caption: caption(logs.map { "FATAL \(NumberFormat.grouped($0.fatalCount)) 条" } ?? ""),
                tint: Theme.critical,
                systemImage: "burst"
            )
            MetricTile(
                label: "异常",
                value: logs.map { NumberFormat.grouped($0.exceptionCount) } ?? "--",
                caption: caption("窗口内累计"),
                tint: Theme.danger,
                systemImage: "xmark.octagon"
            )
            MetricTile(
                label: "警告",
                value: logs.map { NumberFormat.grouped($0.warningCount) } ?? "--",
                caption: caption(warningCaption),
                tint: Theme.caution,
                systemImage: "exclamationmark.circle"
            )
        }
    }

    /// 「没跑过分析」与「跑了但没日志」是两种空状态，都不能显示成真实的 0。
    private func caption(_ text: @autoclosure () -> String) -> String {
        guard let logs = report?.logs else { return "尚未分析" }
        guard logs.hasData else { return "未发现日志文件" }
        return text()
    }

    private var todayErrorCaption: String {
        guard let logs = report?.logs else { return "" }
        if let code = report?.code, code.codeLines > 0 {
            let perKilo = Double(logs.todayErrorCount) / (Double(code.codeLines) / 1000)
            return String(format: "每千行代码 %.2f 次", perKilo)
        }
        return "错误 + 异常 + 崩溃合计"
    }

    private var warningCaption: String {
        guard let logs = report?.logs, logs.totalLinesScanned > 0 else { return "窗口内累计" }
        return "占扫描行 \(NumberFormat.percent(Double(logs.warningCount) / Double(logs.totalLinesScanned), precision: 2))"
    }

    // MARK: - Trend

    private var trendCard: some View {
        SectionCard("错误趋势", subtitle: trendSubtitle, icon: "chart.bar.xaxis", trailing: riskTrailing) {
            if let logs = report?.logs, !logs.trend.isEmpty {
                LogTrendChart(buckets: logs.trend.sorted { $0.date < $1.date })
                    .frame(height: 178)
                Text("柱状为错误 / 异常 / 崩溃按天堆叠，折线为警告数（与柱状共用纵轴）。")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            } else if report?.logs == nil {
                EmptyStateView(
                    icon: "chart.xyaxis.line",
                    title: "尚未分析",
                    message: "点「重新分析」后，这里按天展示错误、异常与崩溃的分布。"
                )
            } else {
                EmptyStateView(
                    icon: "chart.xyaxis.line",
                    title: "暂无趋势数据",
                    message: "日志行里没有可解析的时间戳时无法分桶。"
                )
            }
        }
    }

    private var trendSubtitle: String? {
        guard let logs = report?.logs, !logs.trend.isEmpty else { return nil }
        let peak = logs.trend.map(\.total).max() ?? 0
        return "共 \(logs.trend.count) 天 · 单日峰值 \(NumberFormat.grouped(peak)) 条"
    }

    private var riskTrailing: AnyView? {
        guard let logs = report?.logs, logs.hasData else { return nil }
        return AnyView(RiskBadge(risk: logs.overallRisk))
    }

    // MARK: - Top errors

    private var topErrorsCard: some View {
        SectionCard("Top Errors", subtitle: topErrorsSubtitle, icon: IconName.logs.rawValue) {
            if let logs = report?.logs, !logs.topErrors.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(logs.topErrors) { cluster in
                        ErrorClusterRow(cluster: cluster)
                        if cluster.id != logs.topErrors.last?.id {
                            Divider().opacity(0.4)
                        }
                    }
                }
            } else if report?.logs == nil {
                EmptyStateView(
                    icon: "checkmark.seal",
                    title: "尚无错误签名数据",
                    message: "该项目还没有日志分析结果，点「重新分析」后再来查看聚类。"
                )
            } else {
                EmptyStateView(
                    icon: "checkmark.seal",
                    title: "未发现错误",
                    message: "在项目内放置 Logs/error.log 或 crash.log，或用「附加日志文件」手动选择。"
                )
            }
        }
    }

    private var topErrorsSubtitle: String? {
        guard let logs = report?.logs else { return nil }
        return "共 \(NumberFormat.grouped(logs.topErrors.count)) 类签名 · 按出现次数排序"
    }

    // MARK: - Affected sources

    @ViewBuilder
    private var affectedFilesCard: some View {
        if let logs = report?.logs, !logs.affectedFiles.isEmpty {
            affectedFilesSection(logs)
        }
    }

    private func affectedFilesSection(_ logs: LogSummary) -> some View {
        let ranked = logs.affectedFiles.sorted {
            $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
        }
        let top = Array(ranked.prefix(10))
        let peak = max(1, top.first?.value ?? 1)
        return SectionCard("受影响源文件", subtitle: "按错误出现次数取前 \(top.count) 项", icon: "doc.on.doc") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(top, id: \.key) { item in
                    HStack(spacing: 8) {
                        Text((item.key as NSString).lastPathComponent)
                            .font(Theme.monoSmall)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .frame(width: 170, alignment: .leading)
                            .help(item.key)
                        MiniBarGauge(fraction: Double(item.value) / Double(peak), tint: Theme.danger, height: 5)
                        Text("\(item.value) 次")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.danger)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: - Scanned files

    @ViewBuilder
    private var scannedFilesCard: some View {
        if let logs = report?.logs, !logs.scannedFiles.isEmpty {
            scannedFilesSection(logs)
        }
    }

    private func scannedFilesSection(_ logs: LogSummary) -> some View {
        let sorted = logs.scannedFiles.sorted {
            $0.sizeBytes != $1.sizeBytes ? $0.sizeBytes > $1.sizeBytes : $0.path < $1.path
        }
        let shown = Array(sorted.prefix(Self.fileRowLimit))
        return SectionCard("已扫描文件", subtitle: "共 \(sorted.count) 个", icon: "list.bullet.rectangle") {
            VStack(spacing: 5) {
                scannedFilesHeader
                Divider().opacity(0.5)
                ScrollView {
                    VStack(spacing: 5) {
                        ForEach(shown) { file in
                            scannedFilesRow(file)
                        }
                    }
                }
                .frame(maxHeight: 280)
                if sorted.count > shown.count {
                    Text("另有 \(sorted.count - shown.count) 个文件未列出")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var scannedFilesHeader: some View {
        HStack(spacing: 8) {
            Text("类型").frame(width: 60, alignment: .leading)
            Text("文件").frame(maxWidth: .infinity, alignment: .leading)
            Text("大小").frame(width: 66, alignment: .trailing)
            Text("行数").frame(width: 74, alignment: .trailing)
            Text("修改").frame(width: 66, alignment: .trailing)
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.tertiary)
    }

    private func scannedFilesRow(_ file: ScannedLogFile) -> some View {
        HStack(spacing: 8) {
            Text(file.role.rawValue)
                .font(.system(size: 9))
                .foregroundStyle(file.role.logsTint)
                .lineLimit(1)
                .frame(width: 60, alignment: .leading)
            Text(file.path)
                .font(Theme.monoSmall)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(file.path)
            Text(ByteFormat.string(UInt64(max(0, file.sizeBytes)), precision: 1))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 66, alignment: .trailing)
            Text("\(NumberFormat.grouped(file.lineCount)) 行")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .trailing)
            Text(DateFormat.sinceDescription(file.modifiedAt))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(width: 66, alignment: .trailing)
        }
    }
}

// MARK: - Page-local pieces

/// 附加文件条目：URL 不是 Identifiable，这里补一个稳定 id（路径 + 序号）。
private struct AttachedLogItem: Identifiable {
    let url: URL
    let sizeBytes: UInt64?

    var id: String { url.path }
}

/// 单条错误签名：签名 + 原文 + 首次/最近 + 可展开的样例与堆栈。
private struct ErrorClusterRow: View {
    let cluster: ErrorCluster

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SeverityBadge(severity: cluster.severity)
                Text(cluster.signature)
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
                    .help(cluster.signature)
                Spacer(minLength: 6)
                Text("\(cluster.count) 次")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.danger)
                    .fixedSize()
            }

            Text(cluster.displayMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)

            Text("第一次: \(cluster.firstSeenDescription) · 最近: \(cluster.lastSeenDescription)")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)

            if !cluster.sampleLines.isEmpty || !cluster.stackTopFrames.isEmpty || !cluster.sourceFile.isEmpty {
                DisclosureGroup {
                    detail
                        .padding(.top, 5)
                } label: {
                    Text("样例与堆栈")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .tint(Theme.accent)
            }
        }
        .padding(.vertical, 2)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !cluster.sampleLines.isEmpty {
                Text("样例行")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                ForEach(Array(cluster.sampleLines.prefix(5).enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(index + 1)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: 16, alignment: .trailing)
                        Text(line)
                            .font(Theme.monoSmall)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
            }

            if !cluster.stackTopFrames.isEmpty {
                Text("堆栈顶帧")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                ForEach(Array(cluster.stackTopFrames.prefix(6).enumerated()), id: \.offset) { _, frame in
                    HStack(alignment: .top, spacing: 6) {
                        Text("▸")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.accent)
                        Text(frame)
                            .font(Theme.monoSmall)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .textSelection(.enabled)
                    }
                }
            }

            if !cluster.sourceFile.isEmpty {
                Text("来源文件 \(cluster.sourceFile)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .help(cluster.sourceFile)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Theme.subtleBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// 按天堆叠柱 + 警告折线。
private struct LogTrendChart: View {
    let buckets: [LogBucket]

    private static let errorsKey = "错误"
    private static let exceptionsKey = "异常"
    private static let crashesKey = "崩溃"

    var body: some View {
        Chart(buckets) { bucket in
            BarMark(
                x: .value("日期", bucket.date, unit: .day),
                y: .value("条数", bucket.errors)
            )
            .foregroundStyle(by: .value("类型", Self.errorsKey))
            .cornerRadius(1.5)

            BarMark(
                x: .value("日期", bucket.date, unit: .day),
                y: .value("条数", bucket.exceptions)
            )
            .foregroundStyle(by: .value("类型", Self.exceptionsKey))
            .cornerRadius(1.5)

            BarMark(
                x: .value("日期", bucket.date, unit: .day),
                y: .value("条数", bucket.crashes)
            )
            .foregroundStyle(by: .value("类型", Self.crashesKey))
            .cornerRadius(1.5)

            LineMark(
                x: .value("日期", bucket.date, unit: .day),
                y: .value("条数", bucket.warnings)
            )
            .foregroundStyle(Theme.accent.opacity(0.75))
            .lineStyle(StrokeStyle(lineWidth: 1.3, dash: [3, 2]))
            .interpolationMethod(.monotone)
        }
        .chartForegroundStyleScale([
            Self.errorsKey: Theme.danger,
            Self.exceptionsKey: Theme.caution,
            Self.crashesKey: Theme.critical,
        ])
        .chartLegend(position: .top, alignment: .leading, spacing: 6)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisGridLine().foregroundStyle(Theme.gridLine)
                AxisValueLabel(format: Self.dayAxisFormat, centered: false)
                    .font(.system(size: 8))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Theme.gridLine)
                AxisValueLabel {
                    if let count = value.as(Int.self) {
                        Text(NumberFormat.compact(count)).font(.system(size: 8))
                    }
                }
            }
        }
    }

    /// 固定 POSIX locale，避免中文系统把刻度渲染成「3月5日」挤占横向空间。
    private static var dayAxisFormat: Date.FormatStyle {
        .dateTime.locale(Locale(identifier: "en_US_POSIX")).month(.defaultDigits).day()
    }
}

private extension LogFileRole {
    /// 仅在日志页内使用的角色配色，不进 Theme.swift。
    var logsTint: Color {
        switch self {
        case .crash: return Theme.critical
        case .error: return Theme.danger
        case .build: return Theme.caution
        case .system: return Theme.accent
        case .application: return Theme.healthy
        }
    }
}
