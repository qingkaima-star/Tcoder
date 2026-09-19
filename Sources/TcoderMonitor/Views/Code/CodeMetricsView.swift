import SwiftUI
import AppKit

/// OWNER: WS-A / 子代理3 —— 「代码规模」页。
/// 唯一数据来源是 `report?.code`：契约缺失时显示空状态，绝不把「未扫描」渲染成 0。
struct CodeMetricsView: View {
    var report: ProjectReport?

    private static let metricColumns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)
    /// 语言占比至少展示前 8 项，其余如实合并为「其他」。
    private static let languageHeadCount = 8
    /// 巨大文件最多渲染的行数（引擎本身也只返回前 20 个）。
    private static let hotspotRowLimit = 20
    fileprivate static let hotspotGaugeWidth: CGFloat = 52

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: - Data gate

    /// 判定顺序：先 `code == nil`（没扫过 / 扫描失败），再看「全零」
    /// （`totalFiles == 0 && totalLines == 0`）——两种情况都不渲染指标卡。
    private var metrics: CodeMetrics? {
        guard let code = report?.code else { return nil }
        guard code.totalFiles > 0 || code.totalLines > 0 else { return nil }
        return code
    }

    @ViewBuilder
    private var content: some View {
        if let code = metrics {
            metricGrid(code)
            scaleCard(code)
            markersCard(code)
            hotspotCard(code)
            riskSummaryCard(code)
        } else {
            EmptyStateView(
                icon: IconName.code.rawValue,
                title: report?.code == nil ? "尚无代码扫描结果" : "扫描结果为空",
                message: report?.code == nil
                    ? "点击「重新分析」开始扫描该目录，完成后这里会显示真实的文件数、行数与语言占比。"
                    : "扫描已完成，但没有识别到任何源码文件（构建产物、依赖目录与不受支持的后缀会被跳过）。"
            )
            .frame(maxWidth: .infinity)
            .padding(.top, 48)
        }
    }

    // MARK: - Metric tiles

    private func metricGrid(_ code: CodeMetrics) -> some View {
        LazyVGrid(columns: Self.metricColumns, spacing: 12) {
            MetricTile(
                label: "代码文件",
                value: NumberFormat.grouped(code.totalFiles),
                unit: "个",
                caption: fileTileCaption(code),
                tint: Theme.accent,
                systemImage: "doc.text"
            )
            MetricTile(
                label: "代码行数",
                value: NumberFormat.grouped(code.codeLines),
                unit: "行",
                caption: codeTileCaption(code),
                tint: Theme.healthy,
                systemImage: "text.alignleft"
            )
            MetricTile(
                label: "注释行数",
                value: NumberFormat.grouped(code.commentLines),
                unit: "行",
                caption: commentTileCaption(code),
                tint: Theme.caution,
                systemImage: "text.bubble"
            )
            MetricTile(
                label: "空行数",
                value: NumberFormat.grouped(code.blankLines),
                unit: "行",
                caption: blankTileCaption(code),
                tint: Theme.neutral,
                systemImage: "rectangle.dashed"
            )
        }
    }

    // MARK: - Tile captions（拆出来避免多层字符串嵌套）

    private func fileTileCaption(_ code: CodeMetrics) -> String {
        "主语言 " + code.primaryLanguage + " · 扫描于 " + DateFormat.sinceDescription(code.scannedAt)
    }

    private func codeTileCaption(_ code: CodeMetrics) -> String {
        "总行数 " + NumberFormat.grouped(code.totalLines)
            + " · 代码占 " + NumberFormat.percent(shareOf(code.codeLines, code), precision: 0)
    }

    private func commentTileCaption(_ code: CodeMetrics) -> String {
        "注释率 " + NumberFormat.percent(code.commentRatio)
            + "（分母为总行数 " + NumberFormat.grouped(code.totalLines) + " 行）"
    }

    private func blankTileCaption(_ code: CodeMetrics) -> String {
        "空行占 " + NumberFormat.percent(shareOf(code.blankLines, code), precision: 0)
            + " · 注释率 " + NumberFormat.percent(code.commentRatio, precision: 0)
    }

    // MARK: - Totals & language mix

    private func scaleCard(_ code: CodeMetrics) -> some View {
        SectionCard(
            "总行数与语言构成",
            subtitle: languageSubtitle(code),
            icon: IconName.code.rawValue
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(NumberFormat.grouped(code.totalLines))
                        .font(Theme.heroNumber)
                        .foregroundStyle(Theme.accent)
                    Text("总行数（= 空行 + 注释 + 代码）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                CodeMetricsInvariantRow(code: code)

                Divider().opacity(0.4)

                languageRowsView(code)

                Divider().opacity(0.4)

                HStack(spacing: 14) {
                    StatLine(label: "主要语言", value: code.primaryLanguage)
                    StatLine(label: "平均文件行数", value: averageFileLines(code))
                    StatLine(label: "最大文件", value: "\(NumberFormat.grouped(code.largestFileLineCount)) 行")
                }
                .font(.caption)
            }
        }
    }

    @ViewBuilder
    private func languageRowsView(_ code: CodeMetrics) -> some View {
        let rows = visibleShares(code)
        if rows.isEmpty {
            EmptyStateView(
                icon: "chart.bar",
                title: "无语言占比数据",
                message: "扫描到 \(NumberFormat.grouped(code.totalFiles)) 个文件，但没有任何语言的有效代码行占比大于 0。"
            )
            .frame(minHeight: 90)
        } else {
            VStack(spacing: 6) {
                ForEach(rows) { share in
                    LanguageBar(share: share)
                        .help("\(share.language)：\(NumberFormat.grouped(share.fileCount)) 个文件 · \(NumberFormat.grouped(share.lineCount)) 有效代码行 · 占比 \(NumberFormat.percent(share.share, precision: 1))")
                }
            }
            if let note = mergedNote(code) {
                Text(note)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func languageSubtitle(_ code: CodeMetrics) -> String {
        let counted = code.languages.filter { $0.share > 0 }.count
        guard counted > 0 else { return "尚无语言占比" }
        let head = min(Self.languageHeadCount, counted)
        return "按有效代码行计，共 \(NumberFormat.grouped(code.languages.count)) 种语言，展示前 \(NumberFormat.grouped(head)) 种"
    }

    /// 降序取前 N 项，剩余语言合并成「其他」，行数/文件数/占比都如实求和。
    private func visibleShares(_ code: CodeMetrics) -> [LanguageShare] {
        let sorted = code.languages
            .filter { $0.share > 0 }
            .sorted { lhs, rhs in
                if lhs.share != rhs.share { return lhs.share > rhs.share }
                if lhs.lineCount != rhs.lineCount { return lhs.lineCount > rhs.lineCount }
                return lhs.language < rhs.language
            }
        guard sorted.count > Self.languageHeadCount else { return sorted }

        let head = Array(sorted.prefix(Self.languageHeadCount))
        let tail = Array(sorted.dropFirst(Self.languageHeadCount))
        let merged = LanguageShare(
            language: "其他",
            fileCount: tail.reduce(0) { $0 + $1.fileCount },
            lineCount: tail.reduce(0) { $0 + $1.lineCount },
            share: tail.reduce(0) { $0 + $1.share }
        )
        return head + [merged]
    }

    private func mergedNote(_ code: CodeMetrics) -> String? {
        let sorted = code.languages.filter { $0.share > 0 }
        guard sorted.count > Self.languageHeadCount else { return nil }
        let tail = Array(sorted.dropFirst(Self.languageHeadCount))
        let lines = tail.reduce(0) { $0 + $1.lineCount }
        let share = tail.reduce(0.0) { $0 + $1.share }
        return "「其他」合并了占比最低的 \(NumberFormat.grouped(tail.count)) 种语言，合计 \(NumberFormat.grouped(lines)) 行 · \(NumberFormat.percent(share, precision: 1))。"
    }

    private func averageFileLines(_ code: CodeMetrics) -> String {
        guard code.totalFiles > 0 else { return "0" }
        return String(format: "%.1f", Double(code.totalLines) / Double(code.totalFiles))
    }

    // MARK: - Markers & scan info

    private func markersCard(_ code: CodeMetrics) -> some View {
        SectionCard(
            "标记事项与扫描信息",
            subtitle: "源码里留下的待办标记，只代表历史备注，不代表当前缺陷",
            icon: "flag"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 16) {
                    StatLine(label: "TODO", value: NumberFormat.grouped(code.todoCount))
                    StatLine(label: "FIXME", value: NumberFormat.grouped(code.fixmeCount))
                    StatLine(label: "标记合计", value: NumberFormat.grouped(code.todoCount + code.fixmeCount))
                    StatLine(
                        label: "每千行标记",
                        value: String(format: "%.2f", markerDensityPerKilo(code))
                    )
                }
                .font(.caption)

                Divider().opacity(0.4)

                HStack(spacing: 16) {
                    StatLine(label: "扫描耗时", value: durationText(code.durationMs))
                    StatLine(label: "扫描时间", value: DateFormat.full.string(from: code.scannedAt))
                    StatLine(label: "距今", value: DateFormat.sinceDescription(code.scannedAt))
                }
                .font(.caption)

                Text(markerNote(code))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func markerDensityPerKilo(_ code: CodeMetrics) -> Double {
        guard code.codeLines > 0 else { return 0 }
        return Double(code.todoCount + code.fixmeCount) * 1_000 / Double(code.codeLines)
    }

    private func markerNote(_ code: CodeMetrics) -> String {
        if code.todoCount + code.fixmeCount == 0 {
            return "本次扫描在 \(NumberFormat.grouped(code.totalFiles)) 个文件里没有找到 TODO / FIXME 标记。"
        }
        return "FIXME \(NumberFormat.grouped(code.fixmeCount)) 处通常表示已知缺陷，建议优先在对应文件里核对。"
    }

    private func durationText(_ durationMs: Int) -> String {
        if durationMs >= 1_000 {
            return String(format: "%.2f 秒", Double(durationMs) / 1_000)
        }
        return "\(NumberFormat.grouped(durationMs)) 毫秒"
    }

    // MARK: - Huge files

    private func hotspotCard(_ code: CodeMetrics) -> some View {
        SectionCard(
            "巨大文件（按行数降序）",
            subtitle: hotspotSubtitle(code),
            icon: "doc.on.doc"
        ) {
            if code.hugeFiles.isEmpty {
                EmptyStateView(
                    icon: "checkmark.seal",
                    title: "没有巨大文件",
                    message: "本次扫描的单文件行数峰值为 \(NumberFormat.grouped(code.largestFileLineCount)) 行，未超过巨大文件阈值。"
                )
                .frame(minHeight: 90)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(code.hugeFiles.prefix(Self.hotspotRowLimit).enumerated()), id: \.element.id) { index, hotspot in
                        CodeMetricsHotspotRow(
                            hotspot: hotspot,
                            fileName: fileName(hotspot.path),
                            directory: directoryTail(hotspot.path),
                            largestLineCount: largestLineCount(code),
                            url: resolvedURL(for: hotspot)
                        )
                        if index < min(Self.hotspotRowLimit, code.hugeFiles.count) - 1 {
                            Divider().opacity(0.35)
                        }
                    }
                }
            }
        }
    }

    private func hotspotSubtitle(_ code: CodeMetrics) -> String {
        if code.hugeFiles.isEmpty { return "行数是单文件总行数（含空行与注释）" }
        return "共 \(NumberFormat.grouped(code.hugeFiles.count)) 个 · 最大 \(NumberFormat.grouped(largestLineCount(code))) 行 · 点击条目在 Finder 中显示"
    }

    private func largestLineCount(_ code: CodeMetrics) -> Int {
        max(code.largestFileLineCount, code.hugeFiles.map(\.lineCount).max() ?? 0)
    }

    // MARK: - Risk & duplication summary (明细在「复杂度风险」页)

    private func riskSummaryCard(_ code: CodeMetrics) -> some View {
        SectionCard("重复与复杂度概览", subtitle: "仅概览数字，明细见「复杂度风险」页", icon: "scale.3d") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(NumberFormat.percent(code.duplicationRatio, precision: 1))
                        .font(Theme.metricNumber)
                        .foregroundStyle(Theme.color(for: code.overallRisk))
                    Text("代码行落在重复块内")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    RiskBadge(risk: code.overallRisk)
                }

                MiniBarGauge(
                    fraction: code.duplicationRatio,
                    tint: Theme.color(for: code.overallRisk),
                    height: 6
                )

                HStack(spacing: 14) {
                    StatLine(label: "重复块", value: NumberFormat.grouped(code.duplicatedBlocks.count))
                    StatLine(label: "超长函数", value: NumberFormat.grouped(code.longFunctions))
                    StatLine(label: "平均函数长度", value: "\(NumberFormat.grouped(code.averageFunctionLength)) 行")
                    StatLine(label: "复杂度上榜函数", value: NumberFormat.grouped(code.topComplexFunctions.count))
                }
                .font(.caption)
            }
        }
    }

    // MARK: - Path helpers

    private var projectRoot: String { report?.project.path ?? "" }

    private func shareOf(_ lines: Int, _ code: CodeMetrics) -> Double {
        guard code.totalLines > 0 else { return 0 }
        return Double(lines) / Double(code.totalLines)
    }
}

// MARK: - Formatting shared by the two code pages（写在本目录内，不进 Theme.swift）

enum CodeViewFormat {
    static func fileName(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    /// 相对项目根目录的路径；未命中根目录时退回原始路径。
    static func relativePath(_ path: String, root: String) -> String {
        if !root.isEmpty, path.hasPrefix(root) {
            var rest = String(path.dropFirst(root.count))
            if rest.hasPrefix("/") { rest.removeFirst() }
            if !rest.isEmpty { return rest }
        }
        return path
    }

    /// 展示用路径尾部：目录过多时省略中间段，只保留末尾 `keep` 段（含文件名）。
    static func pathTail(_ path: String, root: String, keep: Int = 3) -> String {
        let parts = relativePath(path, root: root).split(separator: "/").map(String.init)
        guard parts.count > keep + 1 else { return relativePath(path, root: root) }
        return "…/" + parts.suffix(keep).joined(separator: "/")
    }

    /// 只取目录部分，同样省略中间段。
    static func directoryTail(_ path: String, root: String, keep: Int = 3) -> String {
        let parts = relativePath(path, root: root).split(separator: "/").map(String.init)
        guard parts.count > 1 else { return "项目根目录" }
        let directories = parts.dropLast()
        if directories.count > keep + 1 {
            return "…/" + directories.suffix(keep).joined(separator: "/")
        }
        return directories.joined(separator: "/")
    }

    /// 扫描器给的是绝对路径；万一是相对路径就按项目根补齐，保证 Finder 动作可用。
    static func resolvedURL(_ path: String, root: String) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        if !root.isEmpty { return URL(fileURLWithPath: root).appendingPathComponent(path) }
        return URL(fileURLWithPath: path)
    }

    static func duration(_ durationMs: Int) -> String {
        guard durationMs >= 1_000 else { return "\(NumberFormat.grouped(durationMs)) 毫秒" }
        return String(format: "%.2f 秒", Double(durationMs) / 1_000)
    }
}

// MARK: - Local building blocks

/// 空行 + 注释 + 代码 = 总行数 的不变式核对：不一致时如实说明差值。
private struct CodeMetricsInvariantRow: View {
    var code: CodeMetrics

    private var sum: Int { code.blankLines + code.commentLines + code.codeLines }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                term("空行", code.blankLines, Theme.neutral)
                sign("+")
                term("注释", code.commentLines, Theme.caution)
                sign("+")
                term("代码", code.codeLines, Theme.healthy)
                sign("=")
                term("总计", code.totalLines, Theme.accent)
                Spacer(minLength: 0)
            }
            if sum != code.totalLines {
                Text("分项之和 \(NumberFormat.grouped(sum)) 与总行数相差 \(NumberFormat.grouped(abs(sum - code.totalLines))) 行，以扫描器输出为准。")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func sign(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.tertiary)
    }

    private func term(_ label: String, _ value: Int, _ tint: Color) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.system(size: 9)).foregroundStyle(.tertiary)
            Text(NumberFormat.grouped(value))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(tint)
        }
    }
}

/// 巨大文件行：点击在 Finder 中显示，次要动作用默认应用打开。
private struct CodeMetricsHotspotRow: View {
    var hotspot: FileHotspot
    var fileName: String
    var directory: String
    var largestLineCount: Int
    var url: URL

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(fileName)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(directory)
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Text(hotspot.suggestion)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 6)
                    MiniBarGauge(
                        fraction: fraction,
                        tint: Theme.color(for: hotspot.risk),
                        height: 4
                    )
                    .frame(width: CodeMetricsView.hotspotGaugeWidth)
                    Text("\(NumberFormat.grouped(hotspot.lineCount)) 行")
                        .font(Theme.monoSmall)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    RiskBadge(risk: hotspot.risk, showIcon: false)
                        .fixedSize()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(url.path) · 点击在 Finder 中显示")

            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            .controlSize(.mini)
            .help("用默认应用打开 \(fileName)")
        }
    }

    private var fraction: Double {
        guard largestLineCount > 0 else { return 0 }
        return min(1, max(0, Double(hotspot.lineCount) / Double(largestLineCount)))
    }
}
