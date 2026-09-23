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
                EmptyStateView(icon: copy.icon, title: copy.title, message: copy.message,
                               help: copy.help)
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

    /// 盘点表 B5 的**屏上那一半**：`mergedNote` 整句的头，去掉「合计 X 行 · Y%」。
    /// 只在真有「其他」这一行时调用（没超过展示上限就没有可说的）。
    static func mergedNoteHead(_ code: CodeMetrics, head: Int) -> String {
        let tail = code.languages.filter { $0.share > 0 }.count - head
        return localizedFormat("「其他」合并了占比最低的 %1$@ 种语言",
                               NumberFormat.grouped(max(0, tail)))
    }
}

// MARK: - 指标条

/// 总量构成四读数。**无面**，横向一条读数带，列间竖发丝线。
/// 旧形态是 `LazyVGrid` 里四块 `.contentInset` 灰盒，各带一份投影。
///
/// 2026-09-21 工单 S2（盘点表 B1）：卡名那句「代码 / 注释 / 空行共同构成总行数」与
/// `CodeInvariantRow` 画在屏上的等式**逐字同义**，盘点表判的是「删」；
/// B 守恒线本轮不许删，所以整条进 ⓘ —— 卡名右侧只多一枚问号，常驻长句少一条。
struct CodeMetricsSummaryGrid: View {
    let code: CodeMetrics

    var body: some View {
        GlassSection("总量构成", icon: .code,
                     trailing: AnyView(CopyHelpBadge("代码 / 注释 / 空行共同构成总行数"))) {
            ReadoutStrip {
                // 盘点表口径「留短藏长」：屏上留「主语言」这一头（它说明这一格读数的总体是谁），
                // 「扫描于 X」整句进 ⓘ —— 扫描时间/距今在同页「标记事项与扫描信息」卡里
                // 已各占一格（`DataFieldRow`），这一格再念一遍就是主诉⑧点的「同一句念两遍」。
                MetricTile(
                    label: "代码文件",
                    value: NumberFormat.grouped(code.totalFiles),
                    unit: "个",
                    caption: localizedFormat("主语言 %1$@", code.primaryLanguage),
                    captionHelp: localizedFormat("主语言 %1$@ · 扫描于 %2$@",
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
                    // 后半「与注释、代码共同构成总行数」在本卡**同一屏已有两处常驻落点**：
                    // 卡名右侧的 ⓘ（`代码 / 注释 / 空行共同构成总行数`）与下面的
                    // `CodeInvariantRow` 等式（画在屏上的 空行+注释+代码=总计）。
                    // 第三遍不删（B 守恒线不许删），整句收进这一格自己的 ⓘ，屏上留占比。
                    caption: localizedFormat("空行占 %@", Self.shareOf(code.blankLines, code)),
                    captionHelp: localizedFormat("空行占 %@ · 与注释、代码共同构成总行数",
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
                // 盘点表「留短藏长」：屏上留「主语言」——它是这一屏主角读数的总体抬头；
                // 「共 N 个文件」与同卡组里「代码文件 N 个」那一格是**同一个数的第二遍**
                // （值都是 `code.totalFiles`），所以整句进 ⓘ，不删（B 守恒线）。
                subtitle: localizedFormat("主语言 %1$@", code.primaryLanguage),
                subtitleHelp: localizedFormat("主语言 %1$@ · 共 %2$@ 个文件",
                                              code.primaryLanguage,
                                              NumberFormat.grouped(code.totalFiles)),
                icon: .code
            ) {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    // 盘点表 B2（留短藏长 ●）：屏上留一句短口径，完整等式进 ⓘ 与下面的
                    // `CodeInvariantRow`。但屏上那句**不许就是卡名本身**——
                    // 卡名已经叫「总行数」，note 再写「总行数」就是同一屏把一个词念两遍
                    // （上面 162 行刚为「卡名 vs 页名撞车」修过一次，这是同一个问题的下一层）。
                    // 所以 note 说的是卡名没交代的那件事：**这个数含不含空行与注释**。
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xxs) {
                        DataHeroReadout(value: NumberFormat.grouped(code.totalLines),
                                        unit: "行",
                                        note: "含空行与注释")
                        CopyHelpBadge("总行数（= 空行 + 注释 + 代码）")
                    }
                    CodeInvariantRow(code: code)
                }
            }

            // 盘点表 B3（留短藏长 ●）：屏上留原句的头「按有效代码行计」——分母口径必须常驻；
            // 「共 N 种语言、展示前 M 种」那半句连同整句一起进 ⓘ（ⓘ 里必须是完整句，
            // 不能只放后半，否则英文态语序必坏）。
            // 一支例外：一门语言占比都不大于 0 时（B4 那一支），「尚无语言占比」本身就是那条
            // 诚实读数、完整判据句仍在下面的空态里上屏 —— 这一支不再挂 ⓘ，免得同一句两个落点。
            GlassSection("语言构成",
                         subtitle: Self.subtitleHead(code),
                         icon: .chartLine,
                         trailing: code.languages.contains(where: { $0.share > 0 })
                             ? AnyView(CopyHelpBadge(Self.subtitle(code))) : nil) {
                languageBlock
            }
        }
    }

    @ViewBuilder
    private var languageBlock: some View {
        let rows = CodeMetricsView.visibleShares(code, head: CodeMetricsView.languageHeadCount)
        if rows.isEmpty {
            // 盘点表 B4 这一支**保持原样未搬**（详见汇报「未做 + 原因」）：
            // 整句 25 字就是"扫过了、但没有占比数据"的诚实凭据，与上面的「尚无语言占比」
            // 拆成两半后哪一半都不再成立；而本片双语预算只剩 1 条余量，不为一个罕见空态花掉。
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
                // 盘点表 B5（留短藏长 ●）：屏上留「其他」这一行是怎么来的（占比最低的 N 种被合并），
                // 「合计 X 行 · Y%」进 ⓘ —— 那两个数在表格里「其他」那一行本来就各占一格。
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xxs) {
                    DataFootnote(text: CodeMetricsView.mergedNoteHead(code,
                                                                     head: CodeMetricsView.languageHeadCount))
                    CopyHelpBadge(note)
                    Spacer(minLength: 0)
                }
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

    /// `subtitle(_:)` 的**屏上那一半**（盘点表 B3）：原句的头，一字未改。
    /// 「尚无语言占比」那一支整条留在屏上 —— 它是诚实读数，不是口径脚注。
    /// 走 `localizedCopy` 而不是裸字面量：短标签同样是一条要登记的键，
    /// 藏在 `return` 里双语扫描就读不到（同文件 `CodeDataGate` 顶部记过这个坑）。
    static func subtitleHead(_ code: CodeMetrics) -> String {
        guard code.languages.contains(where: { $0.share > 0 }) else { return subtitle(code) }
        return localizedCopy("按有效代码行计")
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
                // 盘点表 B7（留短藏长 ●，62 字）：屏上留「降级了 + 会影响哪两个数」——
                // 认账的那半句必须常驻；「这一屏的 0 该怎么读」那句解释进 ⓘ。
                // ⓘ 里带的是**整句**（与屏上短句同源、含完整句），不是被劈开的后半。
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xxs) {
                    DataNotice(
                        text: localizedFormat("识别规则降级：%1$@ 条正则没能编译，函数数与圈复杂度会偏低。",
                                              NumberFormat.grouped(failures.count)),
                        role: Theme.Semantic.warning, icon: .riskWarning, iconLabel: "分析器降级")
                    CopyHelpBadge(localizedFormat("识别规则降级：%1$@ 条正则没能编译，函数数与圈复杂度会偏低。这一屏的 0 读作「我们的规则没跑起来」，不读作「这个仓库没有函数」。",
                                                  NumberFormat.grouped(failures.count)))
                    // ⓘ 里也是**整句一条字面量**，不拆成两段再 `+`：拆出去的那半句运行时查得到、
                    // 而按字面量比对键的守卫会把它判成"目录里有死键"（本仓既有判据）。
                }
                // 台账内容是"规则片段"，不是文案：不进查表，免得运行时漏翻台账
                // 记进一条永远不可能登记的键。
                .help(failures.joined(separator: "\n"))
            }
            // 扫描边界（批次 P7-C 3-2）：`CodeScanCoverage` 一直算得出"哪几条上限真的生效过"，
            // 但契约里没有承接字段，于是"只读了前 3 个文件"的报告在屏上与全量报告**长得一样**。
            // 屏上只留一句判定，逐条边界（各带真实数字）挂在悬停里。
            if let limits = code.scanLimitations, !limits.isEmpty {
                // 角色一律走 `DataNotice` 的中性默认值：这是一句**范围说明**，不是告警，
                // 更不是 `info` 蓝 —— 那条守卫（`test_infoBlueNeverColorsChrome`）说得很清楚：
                // 蓝同时是链接与选中色，拿它涂说明文字就是一色两义。
                DataNotice(text: localizedFormat(
                               "本次扫描有 %1$@ 条边界生效，这一页的数字是部分测量。",
                               NumberFormat.grouped(limits.count)),
                           iconLabel: "扫描边界")
                    .help(limits.joined(separator: "\n"))
            }
            // RD-42（台账卷二 §23「有写无读」）：混合语言文件里"分区认出来了、N 行归位为非代码"
            // 是一句**口径**、不是"没量准" ⇒ 刻意不进上面那本账（那条在 CLI 被打成「未量准 N 条」）。
            // 数字来自 `CodeMetrics.nonCodeRegionLineCount`（引擎直传），这句只做解释；
            // 一次干净的扫描（纯 Swift/Java 仓库）这里**一个字都不许多**。
            if let regionNote = MixedLanguageRegionCaliber.note(code) {
                DataNotice(text: regionNote, iconLabel: "扫描边界")
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
