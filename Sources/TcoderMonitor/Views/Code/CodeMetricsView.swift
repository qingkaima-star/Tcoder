import SwiftUI
import AppKit

struct CodeMetricsView: View {
    var report: ProjectReport?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let code = report?.code, code.totalFiles > 0 {
                    metricGrid(code)
                    scaleCard(code)
                    markersCard(code)
                    hotspotCard(code)
                    complexityCard(code)
                } else {
                    EmptyStateView(
                        icon: "curlybraces",
                        title: report?.code == nil ? "尚未扫描代码" : "没有可识别的源码文件",
                        message: report?.code == nil
                            ? "该目录尚未扫描或没有可识别的源码文件。点击右上角「重新分析」后这里有真实数据。"
                            : "扫描完成，但目录内没有命中受支持语言后缀的源码文件（构建产物与依赖目录会被跳过）。"
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 48)
                }
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: Metric tiles

    private func metricGrid(_ code: CodeMetrics) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
            MetricTile(
                label: "代码文件",
                value: NumberFormat.grouped(code.totalFiles),
                unit: "个",
                caption: "扫描于 \(DateFormat.sinceDescription(code.scannedAt))",
                tint: Theme.accent,
                systemImage: "doc.text"
            )
            MetricTile(
                label: "代码行数",
                value: NumberFormat.compact(code.codeLines),
                caption: "精确值 \(NumberFormat.grouped(code.codeLines)) 行",
                tint: Theme.healthy,
                systemImage: "text.alignleft"
            )
            MetricTile(
                label: "注释行",
                value: NumberFormat.compact(code.commentLines),
                caption: "注释率 \(NumberFormat.percent(code.commentRatio)) · \(NumberFormat.grouped(code.commentLines)) 行",
                tint: Theme.caution,
                systemImage: "text.bubble"
            )
            MetricTile(
                label: "空行",
                value: NumberFormat.compact(code.blankLines),
                caption: "占比 \(NumberFormat.percent(blankRatio(code))) · \(NumberFormat.grouped(code.blankLines)) 行",
                tint: Theme.neutral,
                systemImage: "rectangle.dashed"
            )
        }
    }

    private func blankRatio(_ code: CodeMetrics) -> Double {
        guard code.totalLines > 0 else { return 0 }
        return Double(code.blankLines) / Double(code.totalLines)
    }

    // MARK: Totals & languages

    private func scaleCard(_ code: CodeMetrics) -> some View {
        SectionCard(
            "总行数与语言构成",
            subtitle: code.languages.isEmpty ? nil : "\(code.languages.count) 种可识别语言",
            icon: IconName.code.rawValue
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(NumberFormat.grouped(code.totalLines))
                        .font(Theme.heroNumber)
                        .foregroundStyle(Theme.accent)
                    Text("总行数（含空行与注释）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                CodeMetricsInvariantRow(code: code)

                Divider().opacity(0.4)

                if visibleShares(code).isEmpty {
                    Text("未识别到语言占比大于 0 的文件。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(visibleShares(code)) { share in
                        LanguageBar(share: share)
                    }
                }

                Divider().opacity(0.4)

                HStack(spacing: 14) {
                    StatLine(label: "主要语言", value: code.primaryLanguage)
                    StatLine(label: "平均文件行数", value: averageFileLines(code))
                    StatLine(label: "扫描耗时", value: "\(code.durationMs) ms")
                }
                .font(.caption)
            }
        }
    }

    private func visibleShares(_ code: CodeMetrics) -> [LanguageShare] {
        Array(code.languages.filter { $0.share > 0 }.prefix(10))
    }

    private func averageFileLines(_ code: CodeMetrics) -> String {
        String(format: "%.1f", Double(code.codeLines) / Double(max(1, code.totalFiles)))
    }

    // MARK: Markers

    private func markersCard(_ code: CodeMetrics) -> some View {
        SectionCard("标记事项", subtitle: "源码注释里留下的待办标记", icon: "flag") {
            HStack(spacing: 12) {
                MetricTile(
                    label: "TODO",
                    value: NumberFormat.grouped(code.todoCount),
                    unit: "处",
                    caption: "历史待办，不代表当前问题",
                    tint: Theme.accent,
                    systemImage: "bookmark"
                )
                MetricTile(
                    label: "FIXME",
                    value: NumberFormat.grouped(code.fixmeCount),
                    unit: "处",
                    caption: "合计 \(NumberFormat.grouped(code.todoCount + code.fixmeCount)) 处标记",
                    tint: Theme.caution,
                    systemImage: "exclamationmark.bubble"
                )
            }
        }
    }

    // MARK: Huge files

    private func hotspotCard(_ code: CodeMetrics) -> some View {
        SectionCard(
            "巨大文件（按行数降序）",
            subtitle: hotspotSubtitle(code),
            icon: "doc.on.doc"
        ) {
            if code.hugeFiles.isEmpty {
                Text("未发现超过行数阈值的文件。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                hotspotList(code)
            }
        }
    }

    private func hotspotList(_ code: CodeMetrics) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(code.hugeFiles.prefix(20).enumerated()), id: \.element.id) { index, hotspot in
                CodeMetricsHotspotRow(
                    hotspot: hotspot,
                    largestLineCount: largestLineCount(code),
                    url: resolvedURL(for: hotspot)
                )
                if index < hotspotRowCount(code) - 1 {
                    Divider().opacity(0.35)
                }
            }
        }
    }

    private func hotspotRowCount(_ code: CodeMetrics) -> Int {
        min(20, code.hugeFiles.count)
    }

    private func hotspotSubtitle(_ code: CodeMetrics) -> String {
        if code.hugeFiles.isEmpty { return "点击任意条目可在 Finder 中显示" }
        return "共 \(NumberFormat.grouped(code.hugeFiles.count)) 个 · 最大 \(NumberFormat.grouped(largestLineCount(code))) 行 · 点击条目在 Finder 中显示"
    }

    private func largestLineCount(_ code: CodeMetrics) -> Int {
        max(code.largestFileLineCount, code.hugeFiles.map(\.lineCount).max() ?? 0)
    }

    private func resolvedURL(for hotspot: FileHotspot) -> URL {
        if hotspot.path.hasPrefix("/") {
            return URL(fileURLWithPath: hotspot.path)
        }
        if let base = report?.project.path, !base.isEmpty {
            return URL(fileURLWithPath: base).appendingPathComponent(hotspot.path)
        }
        return URL(fileURLWithPath: hotspot.path)
    }

    // MARK: Duplication & complexity summary

    private func complexityCard(_ code: CodeMetrics) -> some View {
        SectionCard("重复与复杂度概览", subtitle: "仅概览数字，明细不在此页", icon: "scale.3d") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(NumberFormat.percent(code.duplicationRatio))
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
                    StatLine(label: "超长函数", value: NumberFormat.grouped(code.longFunctions))
                    StatLine(label: "复杂度上榜函数", value: NumberFormat.grouped(code.topComplexFunctions.count))
                    StatLine(label: "平均函数长度", value: "\(code.averageFunctionLength) 行")
                    StatLine(label: "重复块", value: NumberFormat.grouped(code.duplicatedBlocks.count))
                }
                .font(.caption)

                Text("详细风险清单见「复杂度风险」页。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Local building blocks

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

private struct CodeMetricsHotspotRow: View {
    var hotspot: FileHotspot
    var largestLineCount: Int
    var url: URL

    var body: some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } label: {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(hotspot.path)
                    Text(hotspot.suggestion)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 6)
                MiniBarGauge(
                    fraction: fraction,
                    tint: Theme.color(for: hotspot.risk),
                    height: 4
                )
                .frame(width: 52)
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
    }

    private var fraction: Double {
        guard largestLineCount > 0 else { return 0 }
        return min(1, max(0, Double(hotspot.lineCount) / Double(largestLineCount)))
    }
}
