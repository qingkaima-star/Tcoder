import SwiftUI

/// OWNER: WS-L —— 「代码规模」页。
///
/// 2026-09-19 重样（WS-L）：卡片改走 `GlassSection`（内容层标准材质、圆角 16、内边距 20、
/// 不再叠 1px 描边），键值行与读数条改走 `Views/CodeGit` 基座，语言占比行不再用冻结的
/// `LanguageBar`（裸 RGB + 每进程随机 `hashValue` 取色）。数字一律等宽。
///
/// 唯一数据来源是 `report?.code`；三态判定收在 `CodeDataGate`，绝不把「未扫描」渲染成 0。
struct CodeMetricsView: View {
    var report: ProjectReport?

    /// 语言占比至少展示前 8 项，其余如实合并为「其他」；巨大文件最多渲染 20 行。
    static let languageHeadCount = 8
    static let hotspotRowLimit = 20

    var body: some View {
        DataPageScaffold {
            if let code = CodeDataGate.metrics(of: report?.code) {
                CodeMetricsSummaryGrid(code: code)
                CodeScaleSection(code: code, root: projectRoot)
                CodeMarkersSection(code: code)
                CodeHotspotSection(code: code, root: projectRoot)
                CodeDuplicationSummarySection(code: code)
            } else if let copy = CodeDataGate.emptyCopy(for: report?.code,
                                                       page: "语言占比与重复、复杂度概览") {
                EmptyStateView(icon: copy.icon, title: copy.title, message: copy.message)
            }
        }
    }

    private var projectRoot: String { report?.project.path ?? "" }

    /// 降序取前 N 项，剩余语言合并成「其他」，行数/文件数/占比如实求和。
    static func visibleShares(_ code: CodeMetrics, head: Int) -> [LanguageShare] {
        let sorted = code.languages
            .filter { $0.share > 0 }
            .sorted { lhs, rhs in
                if lhs.share != rhs.share { return lhs.share > rhs.share }
                if lhs.lineCount != rhs.lineCount { return lhs.lineCount > rhs.lineCount }
                return lhs.language < rhs.language
            }
        guard sorted.count > head else { return sorted }

        let tail = Array(sorted.dropFirst(head))
        let merged = LanguageShare(
            language: "其他",
            fileCount: tail.reduce(0) { $0 + $1.fileCount },
            lineCount: tail.reduce(0) { $0 + $1.lineCount },
            share: tail.reduce(0) { $0 + $1.share }
        )
        return Array(sorted.prefix(head)) + [merged]
    }

    static func mergedNote(_ code: CodeMetrics, head: Int) -> String? {
        let sorted = code.languages.filter { $0.share > 0 }
        guard sorted.count > head else { return nil }
        let tail = Array(sorted.dropFirst(head))
        let lines = tail.reduce(0) { $0 + $1.lineCount }
        let share = tail.reduce(0.0) { $0 + $1.share }
        return "「其他」合并了占比最低的 \(NumberFormat.grouped(tail.count)) 种语言，合计 "
            + "\(NumberFormat.grouped(lines)) 行 · \(NumberFormat.percent(share, precision: 1))。"
    }
}

// MARK: - 指标条

struct CodeMetricsSummaryGrid: View {
    let code: CodeMetrics

    private static let columns = [GridItem(.adaptive(minimum: Theme.Layout.tileMinWidth),
                                           spacing: Theme.Spacing.gutter)]

    var body: some View {
        LazyVGrid(columns: Self.columns, spacing: Theme.Spacing.gutter) {
            MetricTile(
                label: "代码文件",
                value: NumberFormat.grouped(code.totalFiles),
                unit: "个",
                caption: "主语言 \(code.primaryLanguage) · 扫描于 "
                    + DateFormat.sinceDescription(code.scannedAt),
                tint: Theme.Semantic.accent.textColor
            )
            MetricTile(
                label: "代码行数",
                value: NumberFormat.grouped(code.codeLines),
                unit: "行",
                caption: "总行数 \(NumberFormat.grouped(code.totalLines)) · 代码占 "
                    + Self.shareOf(code.codeLines, code),
                tint: Theme.Semantic.success.textColor
            )
            MetricTile(
                label: "注释行数",
                value: NumberFormat.grouped(code.commentLines),
                unit: "行",
                caption: "注释率 " + NumberFormat.percent(code.commentRatio)
                    + "（分母为总行数 \(NumberFormat.grouped(code.totalLines)) 行）",
                tint: Theme.Semantic.warning.textColor
            )
            MetricTile(
                label: "空行数",
                value: NumberFormat.grouped(code.blankLines),
                unit: "行",
                caption: "空行占 " + Self.shareOf(code.blankLines, code)
                    + " · 与注释、代码共同构成总行数",
                tint: Theme.Semantic.neutral.textColor
            )
        }
    }

    /// 分母为 0 时返回占位而不是 `0%`：没有总行数就没有"占比"这个结论。
    static func shareOf(_ lines: Int, _ code: CodeMetrics) -> String {
        guard code.totalLines > 0 else { return Theme.Placeholder.missingValue }
        return NumberFormat.percent(Double(lines) / Double(code.totalLines), precision: 0)
    }
}

// MARK: - 总行数与语言构成

struct CodeScaleSection: View {
    let code: CodeMetrics
    let root: String

    var body: some View {
        GlassSection(
            "总行数与语言构成",
            subtitle: Self.subtitle(code),
            icon: .code
        ) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                    Text(NumberFormat.grouped(code.totalLines))
                        .font(Theme.Typo.heroMetric.font)
                        .foregroundStyle(Theme.Semantic.accent.textColor)
                    Text("总行数（= 空行 + 注释 + 代码）")
                        .font(Theme.Typo.label.font)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: Theme.Spacing.xs)
                }

                CodeInvariantRow(code: code)

                DataRowSeparator()

                languageBlock

                DataReadoutBar {
                    DataReadout(label: "主要语言", value: code.primaryLanguage,
                                caption: "按有效代码行")
                    DataReadout(label: "平均文件行数", value: Self.averageFileLines(code),
                                caption: "总行数 ÷ 文件数")
                    DataReadout(label: "最大文件", value: "\(NumberFormat.grouped(code.largestFileLineCount)) 行",
                                caption: "单文件行数峰值")
                }
                .padding(.top, Theme.Spacing.xxs)
            }
        }
    }

    @ViewBuilder
    private var languageBlock: some View {
        let rows = CodeMetricsView.visibleShares(code, head: CodeMetricsView.languageHeadCount)
        if rows.isEmpty {
            EmptyStateView(
                icon: .chartLine,
                title: "无语言占比数据",
                message: "扫描到 \(NumberFormat.grouped(code.totalFiles)) 个文件，"
                    + "但没有任何语言的有效代码行占比大于 0。"
            )
        } else {
            VStack(spacing: Theme.Spacing.xs) {
                DataTableHeader(columns: DataColumns.shareBar)
                ForEach(rows) { share in
                    CodeLanguageShareRow(share: share, onOpenHint: CodeLanguageShareRow.hint(share))
                }
            }
            if let note = CodeMetricsView.mergedNote(code, head: CodeMetricsView.languageHeadCount) {
                Text(note)
                    .font(Theme.Typo.microLabel.font)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func subtitle(_ code: CodeMetrics) -> String {
        let counted = code.languages.filter { $0.share > 0 }.count
        guard counted > 0 else { return "尚无语言占比" }
        let head = min(CodeMetricsView.languageHeadCount, counted)
        return "按有效代码行计，共 \(NumberFormat.grouped(code.languages.count)) 种语言，"
            + "展示前 \(NumberFormat.grouped(head)) 种"
    }

    static func averageFileLines(_ code: CodeMetrics) -> String {
        guard code.totalLines > 0, code.totalFiles > 0 else { return Theme.Placeholder.missingValue }
        return String(format: "%.1f", Double(code.totalLines) / Double(code.totalFiles))
    }
}

/// 空行 + 注释 + 代码 = 总行数 的不变式核对；对不上时如实说明差值，不静默吞掉。
struct CodeInvariantRow: View {
    let code: CodeMetrics

    private var sum: Int { code.blankLines + code.commentLines + code.codeLines }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            HStack(spacing: Theme.Spacing.xs) {
                term("空行", code.blankLines, Theme.Semantic.neutral)
                sign("+")
                term("注释", code.commentLines, Theme.Semantic.warning)
                sign("+")
                term("代码", code.codeLines, Theme.Semantic.success)
                sign("=")
                term("总计", code.totalLines, Theme.Semantic.accent)
                Spacer(minLength: 0)
            }
            if sum != code.totalLines {
                DataNotice(
                    text: "分项之和 \(NumberFormat.grouped(sum)) 与总行数相差 "
                        + "\(NumberFormat.grouped(abs(sum - code.totalLines))) 行，以扫描器输出为准。",
                    role: Theme.Semantic.warning, icon: .riskWarning, iconLabel: "行数不变式不成立")
            }
        }
    }

    private func sign(_ text: String) -> some View {
        Text(text)
            .font(CodeGitType.number(Theme.Typo.label))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }

    private func term(_ label: String, _ value: Int, _ role: Theme.SemanticRole) -> some View {
        HStack(spacing: Theme.Spacing.xxs) {
            Text(label)
                .font(Theme.Typo.microLabel.font)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(NumberFormat.grouped(value))
                .font(CodeGitType.metric)
                .foregroundStyle(role.textColor)
        }
    }
}

// MARK: - 标记事项与扫描信息

struct CodeMarkersSection: View {
    let code: CodeMetrics

    var body: some View {
        GlassSection(
            "标记事项与扫描信息",
            subtitle: "源码里留下的待办标记，只代表历史备注，不代表当前缺陷",
            icon: .info
        ) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                DataReadoutBar {
                    DataReadout(label: "TODO", value: NumberFormat.grouped(code.todoCount),
                                caption: "处")
                    DataReadout(label: "FIXME", value: NumberFormat.grouped(code.fixmeCount),
                                caption: "处",
                                role: code.fixmeCount > 0 ? Theme.Semantic.warning : nil)
                    DataReadout(label: "标记合计",
                                value: NumberFormat.grouped(code.todoCount + code.fixmeCount),
                                caption: "处")
                    DataReadout(label: "每千行标记",
                                value: String(format: "%.2f", Self.markerDensityPerKilo(code)),
                                caption: "条 / 千行有效代码")
                }

                DataRowSeparator()

                VStack(spacing: Theme.Spacing.xs) {
                    DataFieldRow(label: "扫描耗时", value: CodeViewFormat.duration(code.durationMs),
                                 style: .number)
                    DataRowSeparator()
                    DataFieldRow(label: "扫描时间",
                                 value: DateFormat.full.string(from: code.scannedAt), style: .number)
                    DataRowSeparator()
                    DataFieldRow(label: "距今", value: DateFormat.sinceDescription(code.scannedAt),
                                 style: .number)
                }

                Text(Self.markerNote(code))
                    .font(Theme.Typo.narrative.font)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineSpacing(Theme.Typo.narrative.lineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func markerDensityPerKilo(_ code: CodeMetrics) -> Double {
        guard code.codeLines > 0 else { return 0 }
        return Double(code.todoCount + code.fixmeCount) * 1_000 / Double(code.codeLines)
    }

    /// 零标记要写成"扫过、没找到"，而不是留一片空白让人以为没扫。
    static func markerNote(_ code: CodeMetrics) -> String {
        if code.todoCount + code.fixmeCount == 0 {
            return "已完成扫描：\(NumberFormat.grouped(code.totalFiles)) 个文件里没有 TODO / FIXME 标记。"
        }
        return "FIXME \(NumberFormat.grouped(code.fixmeCount)) 处通常表示已知缺陷，"
            + "建议优先在对应文件里核对。"
    }
}

// MARK: - 巨大文件

struct CodeHotspotSection: View {
    let code: CodeMetrics
    let root: String
    var rowLimit: Int = CodeMetricsView.hotspotRowLimit

    var body: some View {
        GlassSection(
            "巨大文件（按行数降序）",
            subtitle: Self.subtitle(code),
            icon: .duplicate
        ) {
            if code.hugeFiles.isEmpty {
                EmptyStateView(
                    icon: .noRisk,
                    title: "本次扫描未发现巨大文件",
                    message: "已完成扫描，单文件行数峰值为 \(NumberFormat.grouped(code.largestFileLineCount)) 行，"
                        + "未超过阈值。这是测得的结果，不是没扫。"
                )
            } else {
                VStack(spacing: Theme.Spacing.xs) {
                    DataTableHeader(columns: DataColumns.hugeFiles)
                    let rows = Array(code.hugeFiles.prefix(rowLimit))
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, hotspot in
                        CodeHotspotRow(hotspot: hotspot, root: root,
                                       largestLineCount: Self.largestLineCount(code))
                        if index < rows.count - 1 {
                            DataRowSeparator()
                        }
                    }
                    if code.hugeFiles.count > rows.count {
                        Text("另有 \(NumberFormat.grouped(code.hugeFiles.count - rows.count)) 个未展示")
                            .font(Theme.Typo.microLabel.font)
                            .monospacedDigit()
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    static func largestLineCount(_ code: CodeMetrics) -> Int {
        max(code.largestFileLineCount, code.hugeFiles.map(\.lineCount).max() ?? 0)
    }

    static func subtitle(_ code: CodeMetrics) -> String {
        if code.hugeFiles.isEmpty { return "行数是单文件总行数（含空行与注释）" }
        return "共 \(NumberFormat.grouped(code.hugeFiles.count)) 个 · 最大 "
            + "\(NumberFormat.grouped(largestLineCount(code))) 行 · 点击条目在 Finder 中显示"
    }
}

// MARK: - 重复与复杂度概览（明细在「复杂度风险」页）

struct CodeDuplicationSummarySection: View {
    let code: CodeMetrics

    var body: some View {
        GlassSection(
            "重复与复杂度概览",
            subtitle: "仅概览数字，明细见「复杂度风险」页",
            icon: .complexity,
            trailing: AnyView(RiskBadge(risk: code.overallRisk))
        ) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                    Text(NumberFormat.percent(code.duplicationRatio, precision: 1))
                        .font(Theme.Typo.metricNumber.font)
                        .foregroundStyle(Theme.Semantic.role(for: code.overallRisk).textColor)
                    Text("代码行落在重复块内")
                        .font(Theme.Typo.label.font)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: Theme.Spacing.xs)
                }

                MiniBarGauge(fraction: code.duplicationRatio,
                             tint: Theme.Semantic.role(for: code.overallRisk).graphicColor,
                             height: DataGaugeHeight.metric)

                DataReadoutBar {
                    DataReadout(label: "重复块", value: NumberFormat.grouped(code.duplicatedBlocks.count),
                                caption: "个")
                    DataReadout(label: "超长函数", value: NumberFormat.grouped(code.longFunctions),
                                caption: "个")
                    DataReadout(label: "平均函数长度", value: "\(NumberFormat.grouped(code.averageFunctionLength)) 行",
                                caption: "仅统计 ≥2 行的函数")
                    DataReadout(label: "复杂度上榜", value: NumberFormat.grouped(code.topComplexFunctions.count),
                                caption: "个函数")
                }
                .padding(.top, Theme.Spacing.xxs)
            }
        }
    }
}
