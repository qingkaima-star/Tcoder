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
                DataHeroReadout(value: NumberFormat.percent(code.duplicationRatio, precision: 1),
                                note: "的代码行落在重复块内 —— 综合风险 "
                                    + code.overallRisk.rawValue + "，明细见下方「重复代码率」")

                DataCaption(text: "口径：\(NumberFormat.grouped(code.totalFiles)) 个文件 · "
                            + "\(NumberFormat.grouped(code.codeLines)) 行有效代码 · 主语言 \(code.primaryLanguage)")

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
                    DataReadout(label: "巨大文件", value: NumberFormat.grouped(code.hugeFiles.count),
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
}

// MARK: - 重复代码率

struct CodeDuplicationSection: View {
    let code: CodeMetrics
    let root: String

    static let rowLimit = 8

    @State private var expanded = false

    var body: some View {
        let ratio = CodeRiskAnalysis.ratioRole(code.duplicationRatio)
        GlassSection(
            "重复代码率",
            subtitle: "分母是有效代码行数（不含空行与注释）· 分子是落在重复块内的代码行",
            icon: .duplicate
        ) {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                MiniBarGauge(fraction: code.duplicationRatio, tint: ratio.graphicColor,
                             height: DataGaugeHeight.metric)

                DataCaption(text: CodeRiskAnalysis.duplicationCaption(code))

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
                                             hiddenCount: code.duplicatedBlocks.count - Self.rowLimit,
                                             noun: "个重复块") {
                            expanded.toggle()
                        }
                    }
                    DataFootnote(text: Self.truncationNote(code, shown: rows.count))
                }
            }
        }
    }

    private var visibleRows: [DuplicatedBlock] {
        expanded ? code.duplicatedBlocks : Array(code.duplicatedBlocks.prefix(Self.rowLimit))
    }

    /// 「未列出」必须一直说清楚，展开之后改成「已全部列出」，
    /// 免得那行字停在屏幕上变成假话。
    static func truncationNote(_ code: CodeMetrics, shown: Int) -> String {
        let total = code.duplicatedBlocks.count
        guard total > shown else {
            return "共 \(NumberFormat.grouped(total)) 个重复块，已全部列出。"
        }
        return "另有 \(NumberFormat.grouped(total - shown)) 个重复块未列出 · 当前 "
            + "\(NumberFormat.grouped(shown)) / \(NumberFormat.grouped(total)) 个。"
    }
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
                        DataReadout(label: "重复块",
                                    value: NumberFormat.grouped(code.duplicatedBlocks.count),
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
                    if code.topComplexFunctions.count > Self.rowLimit {
                        DataDisclosureButton(expanded: expanded,
                                             hiddenCount: code.topComplexFunctions.count - Self.rowLimit,
                                             noun: "个函数") {
                            expanded.toggle()
                        }
                    }
                    DataFootnote(text: "点击行在 Finder 中定位源文件，行尾图标用默认应用打开。")
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
        GlassSection(
            "改进建议",
            subtitle: "逐条对应本次扫描的真实数字，无数字支撑的不写",
            icon: .info
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
