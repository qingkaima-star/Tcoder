import SwiftUI

/// OWNER: WS-L / WS-P —— 「复杂度风险」页。
///
/// 2026-09-20 无界化（WS-P，本轮）：
/// - **主角换人**。旧页把 56pt 涂在 `code.overallRisk.rawValue` 上，那是个**中文词**
///   （「高」「严重」）。spec §7 风险 4 明写「`heroMetric` 只用于纯数字读数，
///   含中文标签的标题一律 ≤ 20pt」—— 56pt 的汉字既笨重又把结论读成了装饰。
///   现在主角是**重复代码率**（纯数字百分比），风险等级由 section 标题右侧的
///   `RiskBadge` 承载（色 + 文字 + 图标三通道，本来就该是它干的活）。
/// - **两个读数井拆成两个组**。旧「风险总览」一个组里塞了 8 格读数 + 主角 + 口径句，
///   超过「一组 ≤6 行同类条目」；现在 4+4 拆到总览段与高复杂度段。
/// - **`role: .info` 删掉**：平均圈复杂度是测得值不是状态，蓝是交互色。
///   `danger`（高/严重复杂度 >0）与 `role(for: overallRisk)` 留着，那是真状态。
/// - 两张榜单进井，默认 8 行 + 展开；所有 `.tertiary` 改脚注档。
///
/// 只读 `report?.code`：所有数字来自扫描结果本身，改进建议必须由这些数字派生，
/// 数据缺失时显示空态而不是 0。
struct CodeRiskView: View {
    var report: ProjectReport?

    var body: some View {
        Theme.Page.Scaffold {
            Theme.Page.Header(title: "复杂度风险", icon: .complexity)
            if let code = CodeDataGate.metrics(of: report?.code) {
                GroupStack {
                    CodeRiskOverviewSection(code: code)
                    CodeDuplicationSection(code: code, root: projectRoot)
                }
                GroupStack {
                    CodeComplexitySection(code: code, root: projectRoot)
                    CodeSuggestionSection(code: code)
                }
            } else if let copy = CodeDataGate.emptyCopy(for: report?.code,
                                                       page: "复杂度、重复率与改进建议") {
                EmptyStateView(icon: copy.icon, title: copy.title, message: copy.message)
            }
        }
    }

    private var projectRoot: String { report?.project.path ?? "" }
}

// MARK: - 风险总览

struct CodeRiskOverviewSection: View {
    let code: CodeMetrics

    var body: some View {
        GlassSection(
            "风险总览",
            subtitle: Self.subtitle(code),
            icon: .riskWarning,
            trailing: AnyView(RiskBadge(risk: code.overallRisk))
        ) {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                // 盘点表 C1（hero note，留短藏长 ●）：屏上留「的代码行落在重复块内」——
                // 它就是原句的头，也是这条主角读数的分母说法；「—— 综合风险 X，明细见下方」
                // 那半句连同**完整整句**一起进 ⓘ（ⓘ 里不劈半句，英文态才不会语序错）。
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xxs) {
                    DataHeroReadout(value: NumberFormat.percent(code.duplicationRatio, precision: 1),
                                    note: "的代码行落在重复块内")
                    CopyHelpBadge(localizedFormat("的代码行落在重复块内 —— 综合风险 %1$@，明细见下方「重复代码率」",
                                                  code.overallRisk.rawValue))
                }

                // 盘点表 C2（DataCaption 口径，留短藏长 ●）：屏上留三个数本身（口径的**内容**
                // 必须常驻，不然"这个比例的分母是谁"只剩 hover），
                // 「口径：」这句完整说法进 ⓘ，与短句同一行、紧跟其后。
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xxs) {
                    DataCaption(text: Self.scopeCounts(code))
                    CopyHelpBadge(localizedFormat("口径：%1$@ 个文件 · %2$@ 行有效代码 · 主语言 %3$@",
                                                  NumberFormat.grouped(code.totalFiles),
                                                  NumberFormat.grouped(code.codeLines),
                                                  code.primaryLanguage))
                    Spacer(minLength: 0)
                }

                ReadoutStrip {
                    DataReadout(label: "最大文件",
                                value: NumberFormat.grouped(code.largestFileLineCount),
                                caption: "单文件行数峰值", unit: "行")
                    DataBandSeparator()
                    DataReadout(label: "超长函数", value: NumberFormat.grouped(code.longFunctions),
                                unit: "个")
                    DataBandSeparator()
                    DataReadout(label: "平均函数长度",
                                value: NumberFormat.grouped(code.averageFunctionLength),
                                caption: "仅 ≥2 行的函数",
                                unit: "行")
                    DataBandSeparator()
                    // 真总数，不是榜长：`hugeFiles` 被 `prefix(20)` 截过，读它会把 552 个显示成 20 个。
                    DataReadout(label: "巨大文件", value: NumberFormat.grouped(code.reportedHugeFileCount),
                                unit: "个")
                }
            }
        }
    }

    static func subtitle(_ code: CodeMetrics) -> String {
        localizedFormat("最近扫描 %1$@ · 耗时 %2$@",
                        DateFormat.sinceDescription(code.scannedAt),
                        CodeViewFormat.duration(code.durationMs))
    }

    /// 盘点表 C2 的**屏上那一半**：口径里的三个数，去掉「口径：」抬头与「主语言」尾巴。
    /// 走 `localizedFormat` 的整句模板而不是裸插值：裸插值出来的串不是键，
    /// 英文态永远命中不了（双语方案 §7.1，同文件 `CodeDataGate` 顶部记过这个坑）。
    static func scopeCounts(_ code: CodeMetrics) -> String {
        localizedFormat("%1$@ 个文件 · %2$@ 行有效代码",
                        NumberFormat.grouped(code.totalFiles),
                        NumberFormat.grouped(code.codeLines))
    }
}

// MARK: - 重复代码率

struct CodeDuplicationSection: View {
    let code: CodeMetrics
    let root: String

    static let rowLimit = 8

    @State private var expanded = false

    var body: some View {
        let ratio = CodeRiskAnalysis.ratioRole(code.duplicationRatio)
        // 盘点表 C3（subtitle，留短藏长 ●）：分母这三个字必须常驻（它决定这个百分比怎么读），
        // 「不含空行与注释」与「分子是什么」那半句进 ⓘ。
        GlassSection(
            "重复代码率",
            subtitle: "分母是有效代码行数",
            icon: .duplicate,
            trailing: AnyView(CopyHelpBadge("分母是有效代码行数（不含空行与注释）· 分子是落在重复块内的代码行"))
        ) {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                // 条 + 它自己的口径说明同一行（守卫 `CaliberBadgePlacementGuardTests`）：
                // 独立成行的 ⓘ 会在卡片左下角长出一枚没邻居的灰点。
                HStack(alignment: .center, spacing: Theme.Spacing.xxs) {
                    MiniBarGauge(fraction: code.duplicationRatio, tint: ratio.graphicColor,
                                 height: DataGaugeHeight.metric)
                        .frame(maxWidth: .infinity)
                    // 盘点表 C4（判「删」：这条 caption 与上一行的读数带同屏两遍）。
                    // 本轮 B 守恒线不许删，整条进 ⓘ；串仍由 `duplicationCaption` 单点产出。
                    CopyHelpBadge(CodeRiskAnalysis.duplicationCaption(code))
                }

                if code.duplicatedBlocks.isEmpty {
                    EmptyStateView(
                        icon: .noRisk,
                        title: "已完成扫描，未发现重复块",
                        message: "扫描了 \(NumberFormat.grouped(code.totalFiles)) 个文件 / "
                            + "\(NumberFormat.grouped(code.codeLines)) 行有效代码，"
                            + "重复率为 \(NumberFormat.percent(code.duplicationRatio, precision: 1))。"
                    )
                } else {
                    let rows = visibleRows
                    DataTableWell {
                        DataTableHeader(columns: DataColumns.duplicationBlocks)
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, block in
                            CodeDuplicationBlockRow(block: block, root: root)
                            if index < rows.count - 1 {
                                DataRowSeparator()
                            }
                        }
                    }
                    if code.duplicatedBlocks.count > Self.rowLimit {
                        DataDisclosureButton(expanded: expanded,
                                             hiddenCount: CodeBoardTruth.duplicationBoardCount(code) - Self.rowLimit,
                                             noun: CodeBoardTruth.duplicationHiddenRowsNoun(code)) {
                            expanded.toggle()
                        }
                    }
                    DataFootnote(text: CodeBoardTruth.duplicationTruncationNote(code, shown: rows.count))
                }
            }
        }
    }

    private var visibleRows: [DuplicatedBlock] {
        expanded ? code.duplicatedBlocks : Array(code.duplicatedBlocks.prefix(Self.rowLimit))
    }

    /// 页尾那句已搬到 `CodeBoardTruth.duplicationTruncationNote`（RD-17）：
    /// 「重复块」这一格在两页都有，被截断时的说法必须同源，不许各写一份判据。
    /// 与 `CodeHotspotSection.truncationNote` 同一判断：**未列出的条数由展开按钮说一次**，
    /// 本行只补按钮没有的「列出多少 / 一共多少」。
}

// MARK: - 高复杂度函数

struct CodeComplexitySection: View {
    let code: CodeMetrics
    let root: String

    static let rowLimit = 8

    @State private var expanded = false

    var body: some View {
        GlassSection(
            "高复杂度函数",
            subtitle: CodeRiskAnalysis.complexitySubtitle(code),
            icon: .complexity
        ) {
            if code.topComplexFunctions.isEmpty {
                EmptyStateView(
                    icon: .noRisk,
                    title: "已完成扫描，没有函数上榜",
                    message: "本次扫描没有函数达到引擎给出的复杂度上榜条件。参考数字：超长函数 "
                        + "\(NumberFormat.grouped(code.longFunctions)) 个 · 平均函数长度 "
                        + "\(NumberFormat.grouped(code.averageFunctionLength)) 行。"
                )
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    ReadoutStrip {
                        DataReadout(label: "高/严重复杂度",
                                    value: NumberFormat.grouped(CodeRiskAnalysis.highRiskFunctionCount(code)),
                                    unit: "个",
                                    role: CodeRiskAnalysis.highRiskFunctionCount(code) > 0
                                        ? Theme.Semantic.danger : Theme.Semantic.neutral)
                        DataBandSeparator()
                        // 没有 role：平均圈复杂度是测得值，不是状态结论。
                        // 旧代码给它涂了 info 蓝，而蓝在本 App 里同时是链接与选中色。
                        DataReadout(label: "平均圈复杂度",
                                    value: CodeRiskAnalysis.averageComplexityValue(code),
                                    caption: CodeRiskAnalysis.averageComplexityCaption(code))
                        DataBandSeparator()
                        DataReadout(label: "复杂度上榜",
                                    value: NumberFormat.grouped(code.topComplexFunctions.count),
                                    unit: "个")
                        DataBandSeparator()
                        // 标签里的「榜内」不是修饰词：`duplicatedBlocks` 被
                        // `DuplicationEngine.maxBlocks` 截过，这个数**就是**榜长（RD-17）。
                        DataReadout(label: CodeBoardTruth.duplicationSlotLabel(code),
                                    value: NumberFormat.grouped(CodeBoardTruth.duplicationBoardCount(code)),
                                    unit: "个",
                                    role: Theme.Semantic.role(for: code.overallRisk))
                    }

                    let rows = visibleRows
                    DataTableWell {
                        DataTableHeader(columns: DataColumns.complexityFunctions)
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, hotspot in
                            CodeComplexityRow(hotspot: hotspot, root: root)
                            if index < rows.count - 1 {
                                DataRowSeparator()
                            }
                        }
                    }
                    // 独立成行的 ⓘ 会在卡片左下角长出一枚没有邻居的灰点
                    // （页尾实拍 `.scratch/evidence-8de2d17/light-tail/复杂度风险.png`）。
                    // 规则：说明句必须挂在**它解释的那一行的行尾** —— 这里挂在展开按钮同一行，
                    // 没有按钮时靠 `Spacer` 退到行尾，仍然是一行的尾部而不是独占一行。
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                        if code.topComplexFunctions.count > Self.rowLimit {
                            DataDisclosureButton(expanded: expanded,
                                                 hiddenCount: code.topComplexFunctions.count - Self.rowLimit,
                                                 noun: "个函数") {
                                expanded.toggle()
                            }
                        }
                        Spacer(minLength: Theme.Spacing.xs)
                        // 盘点表 C8（判「藏」的操作提示）：整句进 ⓘ，屏上只多一枚问号。
                        // 两个动作本身在各自行里已经各带一份 `.help`，这句只是"怎么用这张表"。
                        CopyHelpBadge("点击行在 Finder 中定位源文件，行尾图标用默认应用打开。")
                    }
                }
            }
        }
    }

    private var visibleRows: [FunctionHotspot] {
        expanded ? code.topComplexFunctions
            : Array(code.topComplexFunctions.prefix(Self.rowLimit))
    }
}

// MARK: - 改进建议

struct CodeSuggestionSection: View {
    let code: CodeMetrics

    var body: some View {
        // 盘点表 C9（判「藏」）：这句是对我们工作方式的自述（"无数字支撑的不写"），
        // 不改变任何一条读法，所以整句进 ⓘ，挂在卡名右侧那行 —— 它原来就在卡名下面。
        GlassSection(
            "改进建议",
            icon: .info,
            trailing: AnyView(CopyHelpBadge("逐条对应本次扫描的真实数字，无数字支撑的不写"))
        ) {
            let items = CodeRiskAnalysis.suggestions(for: code)
            if items.isEmpty {
                DataNotice(text: CodeRiskAnalysis.noRiskNote(code),
                           role: Theme.Semantic.neutral, icon: .noRisk, iconLabel: "本次无结构性风险")
            } else {
                VStack(spacing: DataRowMetrics.rowGap) {
                    ForEach(items) { item in
                        DataNotice(text: item.text, role: item.role, icon: item.icon,
                                   symbol: item.symbol, iconLabel: item.label)
                    }
                }
            }
        }
    }
}
