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
            Theme.Page.Header(title: "代码规模", icon: .code)
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
                    caption: localizedFormat("主语言 %1$@ · 扫描于 %2$@",
                                             code.primaryLanguage,
                                             DateFormat.sinceDescription(code.scannedAt))
                )
                DataBandSeparator()
                MetricTile(
                    label: "代码行数",
                    value: NumberFormat.grouped(code.codeLines),
                    unit: "行",
                    caption: localizedFormat("总行数 %1$@ · 代码占 %2$@",
                                             NumberFormat.grouped(code.totalLines),
                                             Self.shareOf(code.codeLines, code))
                )
                DataBandSeparator()
                MetricTile(
                    label: "注释行数",
                    value: NumberFormat.grouped(code.commentLines),
                    unit: "行",
                    caption: localizedFormat("注释率 %1$@（分母为总行数 %2$@ 行）",
                                             NumberFormat.percent(code.commentRatio),
                                             NumberFormat.grouped(code.totalLines))
                )
                DataBandSeparator()
                MetricTile(
                    label: "空行数",
                    value: NumberFormat.grouped(code.blankLines),
                    unit: "行",
                    caption: localizedFormat("空行占 %@ · 与注释、代码共同构成总行数",
                                             Self.shareOf(code.blankLines, code))
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
            // 卡名不叫「代码规模」——那是**这一页的 H1**。同一屏两个一模一样的标题
            // 读起来像页面渲染了两遍（参考图的卡名各自具体："24 小时活动""Agent 时长占比"）。
            // 这张卡实际说的是"总行数 + 它由哪三项相加"，所以卡名就叫总行数。
            GlassSection(
                "总行数",
                subtitle: localizedFormat("主语言 %1$@ · 共 %2$@ 个文件",
                                          code.primaryLanguage,
                                          NumberFormat.grouped(code.totalFiles)),
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
                message: localizedFormat("扫描到 %1$@ 个文件，但没有任何语言的有效代码行占比大于 0。",
                                         NumberFormat.grouped(code.totalFiles))
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
        return localizedFormat("按有效代码行计，共 %1$@ 种语言，展示前 %2$@ 种",
                                NumberFormat.grouped(code.languages.count),
                                NumberFormat.grouped(head))
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
                    text: localizedFormat("分项之和 %1$@ 与总行数相差 %2$@ 行，以扫描器输出为准。",
                                          NumberFormat.grouped(sum),
                                          NumberFormat.grouped(abs(sum - code.totalLines))),
                    role: Theme.Semantic.warning, icon: .riskWarning, iconLabel: "行数不变式不成立")
            }
            // 识别规则降级（批次 P7-B 2-6/2-7）：没有这句提示时，一个坏掉的正则
            // 会在界面上长成"这个仓库 0 个函数"，而那是关于我们的事实、不是关于仓库的。
            if let failures = code.analyzerRuleFailures, !failures.isEmpty {
                DataNotice(
                    // 整句一条字面量。**不能拆成两段再 `+`**：那样运行时查得到、
                    // 而按字面量比对键的守卫会把它判成"目录里有死键"（本仓既有判据）。
                    text: localizedFormat("识别规则降级：%1$@ 条正则没能编译，函数数与圈复杂度会偏低。这一屏的 0 读作「我们的规则没跑起来」，不读作「这个仓库没有函数」。",
                                          NumberFormat.grouped(failures.count)),
                    role: Theme.Semantic.warning, icon: .riskWarning, iconLabel: "分析器降级")
                    // 台账内容是"规则片段"，不是文案：不进查表，免得运行时漏翻台账
                    // 记进一条永远不可能登记的键。
                    .help(failures.joined(separator: "\n"))
            }
        }
    }

    // 两处都必须 `localizedCopy` 之后再进 `Text`：`Text(String)` 走的是 verbatim 初始化、
    // **不查表**。英文态里「空行/注释/代码/总计」一直是中文，就是这两处漏的
    // （2026-09-21 英文九页实拍抓到；同一族坑本仓已记过九次）。
    private func sign(_ text: String) -> some View {
        Text(localizedCopy(text))
            .font(CodeGitType.number(Theme.Typo.label))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }

    private func term(_ label: String, _ value: Int) -> some View {
        HStack(spacing: Theme.Spacing.xxs) {
            Text(localizedCopy(label))
                .font(CodeGitType.prose(Theme.Typo.label))
                .foregroundStyle(.secondary)
            Text(NumberFormat.grouped(value))
                .font(CodeGitType.metric)
                .foregroundStyle(Theme.Palette.Surface.ink)
        }
    }
}
