import SwiftUI

/// OWNER: WS-L / WS-P —— 「代码规模」页。
///
/// 2026-09-20 无界化（WS-P，本轮）：
/// - **一个主角**：56pt 的总行数，从 `accent` 蓝改回纯墨 `Surface.ink`。
///   （旧页同屏还有一枚 34pt 重复率当第二主角，现降到 22pt 读数带。）
/// - **面全部去掉**，只留井：三处 `DataReadoutBar`（它给聚合数字画了一层井）改
///   `DataReadoutBand`；语言榜与巨大文件榜改嵌 `DataTableWell`。井是内容层唯一
///   允许的底（风格契约 3），只给有行列结构的东西。
/// - **颜色只承载语义**（契约 5）：四枚 tile 的 `tint: accent/success/warning/neutral`
///   全部删掉 —— 那是给数据上色，不是状态。不变式行「空行+注释+代码=总计」同理，
///   它是结构，改灰阶。真正该留色的两处留着：不变式不成立的 `DataNotice(.warning)`、
///   风险量表 `MiniBarGauge`。
/// - **节奏**：页边距 24 / 段落 40 / 分组 32 / 组内 16。此前五页这三档全部零引用，
///   组间(16)与组内(12)几乎同数，这就是「拥挤」的机械成因。
/// - **信息一条没减**：`CodeDataGate` 三态、`mergedNote` 合并口径、`markerNote`
///   「扫过、没找到」的措辞、巨大文件阈值说明全部原文保留，只降排版层级。
///
/// 唯一数据来源是 `report?.code`；三态判定收在 `CodeDataGate`，绝不把「未扫描」渲染成 0。
struct CodeMetricsView: View {
    var report: ProjectReport?

    /// 语言占比至少展示前 8 项，其余如实合并为「其他」；巨大文件折叠态 8 行，
    /// 展开后不再截断（`hotspotRowLimit` 从 20 收到 8 是为了组内不堆叠，
    /// 「另有 N 个未展示」那句必须跟着一起在场，否则截断就成了静默丢数据）。
    static let languageHeadCount = 8
    static let hotspotRowLimit = 8

    var body: some View {
        Theme.Page.Scaffold {
            if let code = CodeDataGate.metrics(of: report?.code) {
                GroupStack {
                    CodeScaleSection(code: code, root: projectRoot)
                    CodeMetricsSummaryGrid(code: code)
                }
                GroupStack {
                    CodeMarkersSection(code: code)
                    CodeHotspotSection(code: code, root: projectRoot)
                    CodeDuplicationSummarySection(code: code)
                }
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

/// 总量构成四读数。**无面**，横向一条读数带，列间竖发丝线。
/// 旧形态是 `LazyVGrid` 里四块 `.contentInset` 灰盒，各带一份投影。
struct CodeMetricsSummaryGrid: View {
    let code: CodeMetrics

    var body: some View {
        GlassSection("总量构成", subtitle: "代码 / 注释 / 空行共同构成总行数", icon: .code) {
            ReadoutStrip {
                MetricTile(
                    label: "代码文件",
                    value: NumberFormat.grouped(code.totalFiles),
                    unit: "个",
                    caption: "主语言 \(code.primaryLanguage) · 扫描于 "
                        + DateFormat.sinceDescription(code.scannedAt)
                )
                DataBandSeparator()
                MetricTile(
                    label: "代码行数",
                    value: NumberFormat.grouped(code.codeLines),
                    unit: "行",
                    caption: "总行数 \(NumberFormat.grouped(code.totalLines)) · 代码占 "
                        + Self.shareOf(code.codeLines, code)
                )
                DataBandSeparator()
                MetricTile(
                    label: "注释行数",
                    value: NumberFormat.grouped(code.commentLines),
                    unit: "行",
                    caption: "注释率 " + NumberFormat.percent(code.commentRatio)
                        + "（分母为总行数 \(NumberFormat.grouped(code.totalLines)) 行）"
                )
                DataBandSeparator()
                MetricTile(
                    label: "空行数",
                    value: NumberFormat.grouped(code.blankLines),
                    unit: "行",
                    caption: "空行占 " + Self.shareOf(code.blankLines, code)
                        + " · 与注释、代码共同构成总行数"
                )
            }
        }
    }

    /// 分母为 0 时给「算不出」而不是 `--`，也不是 `0%`：
    /// 扫描做过、总行数确实是 0，于是「占比」这个比值没有定义。
    /// 它与「没扫」（`DataAbsence.notAnalysed` → `--`）必须分得开——《42》§14.3 第 1 条。
    static func shareOf(_ lines: Int, _ code: CodeMetrics) -> String {
        guard code.totalLines > 0 else { return DataAbsence.indeterminate.display }
        return NumberFormat.percent(Double(lines) / Double(code.totalLines), precision: 0)
    }
}

// MARK: - 总行数与语言构成

struct CodeScaleSection: View {
    let code: CodeMetrics
    let root: String

    var body: some View {
        GroupStack {
            GlassSection(
                "代码规模",
                subtitle: "主语言 \(code.primaryLanguage) · 共 "
                    + "\(NumberFormat.grouped(code.totalFiles)) 个文件",
                icon: .code
            ) {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    DataHeroReadout(value: NumberFormat.grouped(code.totalLines),
                                    unit: "行",
                                    note: "总行数（= 空行 + 注释 + 代码）")
                    CodeInvariantRow(code: code)
                }
            }

            GlassSection("语言构成", subtitle: Self.subtitle(code), icon: .chartLine) {
                languageBlock
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
            DataTableWell {
                DataTableHeader(columns: DataColumns.shareBar)
                ForEach(rows) { share in
                    CodeLanguageShareRow(share: share, onOpenHint: CodeLanguageShareRow.hint(share))
                }
            }
            if let note = CodeMetricsView.mergedNote(code, head: CodeMetricsView.languageHeadCount) {
                DataFootnote(text: note)
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

    /// 平均文件行数 = 总行数 / 文件数。两个分母任期为 0 都是「算不出」，
    /// 不是「没扫」（`--`）：扫过了，只是这个除法没有定义。
    static func averageFileLines(_ code: CodeMetrics) -> String {
        guard code.totalLines > 0, code.totalFiles > 0 else {
            return DataAbsence.indeterminate.display
        }
        return String(format: "%.1f", Double(code.totalLines) / Double(code.totalFiles))
    }
}

/// 空行 + 注释 + 代码 = 总行数 的不变式核对；对不上时如实说明差值，不静默吞掉。
///
/// 这一行**不再四色**：以前空行 neutral / 注释 warning / 代码 success / 总计 accent，
/// 把「结构等式」读成了四个状态结论。契约 5 是结构去色 —— 等式靠 `+` `=` 与
/// 基线对齐说话，颜色在这里不携带任何信息。
struct CodeInvariantRow: View {
    let code: CodeMetrics

    private var sum: Int { code.blankLines + code.commentLines + code.codeLines }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            HStack(spacing: Theme.Spacing.xs) {
                term("空行", code.blankLines)
                sign("+")
                term("注释", code.commentLines)
                sign("+")
                term("代码", code.codeLines)
                sign("=")
                term("总计", code.totalLines)
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
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }

    private func term(_ label: String, _ value: Int) -> some View {
        HStack(spacing: Theme.Spacing.xxs) {
            Text(label)
                .font(CodeGitType.prose(Theme.Typo.label))
                .foregroundStyle(.secondary)
            Text(NumberFormat.grouped(value))
                .font(CodeGitType.metric)
                .foregroundStyle(Theme.Palette.Surface.ink)
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
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                DataReadoutBand {
                    DataReadout(label: "TODO", value: NumberFormat.grouped(code.todoCount),
                                caption: "处")
                    DataBandSeparator()
                    DataReadout(label: "FIXME", value: NumberFormat.grouped(code.fixmeCount),
                                caption: "处",
                                role: code.fixmeCount > 0 ? Theme.Semantic.warning : nil)
                    DataBandSeparator()
                    DataReadout(label: "标记合计",
                                value: NumberFormat.grouped(code.todoCount + code.fixmeCount),
                                caption: "处")
                    DataBandSeparator()
                    DataReadout(label: "每千行标记",
                                value: String(format: "%.2f", Self.markerDensityPerKilo(code)),
                                caption: "条 / 千行有效代码")
                }

                VStack(spacing: DataRowMetrics.rowGap) {
                    DataFieldRow(label: "扫描耗时", value: CodeViewFormat.duration(code.durationMs),
                                 style: .number)
                    DataRowSeparator()
                    DataFieldRow(label: "扫描时间",
                                 value: DateFormat.full.string(from: code.scannedAt), style: .number)
                    DataRowSeparator()
                    DataFieldRow(label: "距今", value: DateFormat.sinceDescription(code.scannedAt),
                                 style: .number)
                }

                DataCaption(text: Self.markerNote(code))
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

    @State private var expanded = false

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
                let rows = visibleRows
                DataTableWell {
                    DataTableHeader(columns: DataColumns.hugeFiles)
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, hotspot in
                        CodeHotspotRow(hotspot: hotspot, root: root,
                                       largestLineCount: Self.largestLineCount(code))
                        if index < rows.count - 1 {
                            DataRowSeparator()
                        }
                    }
                }
                if code.hugeFiles.count > rowLimit {
                    DataDisclosureButton(expanded: expanded,
                                        hiddenCount: code.hugeFiles.count - rowLimit,
                                        noun: "个未展示") {
                        expanded.toggle()
                    }
                }
                DataFootnote(text: Self.truncationNote(code, shown: rows.count))
            }
        }
    }

    private var visibleRows: [FileHotspot] {
        expanded ? code.hugeFiles : Array(code.hugeFiles.prefix(rowLimit))
    }

    /// 折叠状态必须自己交代，不然「8 行」会被读成「一共只有 8 个」。
    static func truncationNote(_ code: CodeMetrics, shown: Int) -> String {
        let total = code.hugeFiles.count
        guard total > shown else {
            return "共 \(NumberFormat.grouped(total)) 个，已全部展示。"
        }
        return "另有 \(NumberFormat.grouped(total - shown)) 个未展示 · 当前列出 "
            + "\(NumberFormat.grouped(shown)) / \(NumberFormat.grouped(total)) 个。"
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

/// 概览段。**这一页已有 56pt 主角，所以重复率从 34pt 降到 22pt 读数带**
/// ——「两个 28pt 以上数字争位」就是旧页「没有主次」的定量形态。
struct CodeDuplicationSummarySection: View {
    let code: CodeMetrics

    var body: some View {
        GlassSection(
            "重复与复杂度概览",
            subtitle: "仅概览数字，明细见「复杂度风险」页",
            icon: .complexity,
            trailing: AnyView(RiskBadge(risk: code.overallRisk))
        ) {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                DataReadoutBand {
                    DataReadout(label: "重复代码率",
                                value: NumberFormat.percent(code.duplicationRatio, precision: 1),
                                caption: "的代码行落在重复块内",
                                role: Theme.Semantic.role(for: code.overallRisk))
                    DataBandSeparator()
                    DataReadout(label: "重复块", value: NumberFormat.grouped(code.duplicatedBlocks.count),
                                caption: "个")
                    DataBandSeparator()
                    DataReadout(label: "超长函数", value: NumberFormat.grouped(code.longFunctions),
                                caption: "个")
                    DataBandSeparator()
                    DataReadout(label: "平均函数长度", value: "\(NumberFormat.grouped(code.averageFunctionLength)) 行",
                                caption: "仅统计 ≥2 行的函数")
                }

                MiniBarGauge(fraction: code.duplicationRatio,
                             tint: Theme.Semantic.role(for: code.overallRisk).graphicColor,
                             height: DataGaugeHeight.metric)
                DataFootnote(text: "重复块 \(NumberFormat.grouped(code.duplicatedBlocks.count)) 个 · "
                             + "复杂度上榜 \(NumberFormat.grouped(code.topComplexFunctions.count)) 个函数")
            }
        }
    }
}
