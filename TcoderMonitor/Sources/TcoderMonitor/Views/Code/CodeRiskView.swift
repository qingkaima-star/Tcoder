import SwiftUI

/// OWNER: WS-L —— 「复杂度风险」页。
///
/// 2026-09-19 重样（WS-L）：三张明细表全部改走 `Views/CodeGit` 的列宽单一来源，
/// 数字列尾对齐 + 等宽；行底色从 `opacity(0.07)` 杂值并进 `Opacity.badgeFill / 2`；
/// 字号、圆角、间距、图标全部取自 `Design/` 令牌。
///
/// 只读 `report?.code`：所有数字来自扫描结果本身，改进建议必须由这些数字派生，
/// 数据缺失时显示空态而不是 0。
struct CodeRiskView: View {
    var report: ProjectReport?

    var body: some View {
        DataPageScaffold {
            if let code = CodeDataGate.metrics(of: report?.code) {
                CodeRiskOverviewSection(code: code)
                CodeDuplicationSection(code: code, root: projectRoot)
                CodeComplexitySection(code: code, root: projectRoot)
                CodeSuggestionSection(code: code)
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
        let role = Theme.Semantic.role(for: code.overallRisk)
        GlassSection(
            "风险总览",
            subtitle: Self.subtitle(code),
            icon: .riskWarning,
            trailing: AnyView(RiskBadge(risk: code.overallRisk))
        ) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                    Text(code.overallRisk.rawValue)
                        .font(Theme.Typo.heroMetric.font)
                        .foregroundStyle(role.textColor)
                    Text("综合风险等级")
                        .font(Theme.Typo.label.font)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: Theme.Spacing.xs)
                }

                Text("口径：\(NumberFormat.grouped(code.totalFiles)) 个文件 · "
                    + "\(NumberFormat.grouped(code.codeLines)) 行有效代码 · 主语言 \(code.primaryLanguage)")
                    .font(Theme.Typo.narrative.font)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineSpacing(Theme.Typo.narrative.lineSpacing)

                DataReadoutBar {
                    DataReadout(label: "最大文件",
                                value: "\(NumberFormat.grouped(code.largestFileLineCount)) 行",
                                caption: "单文件行数峰值")
                    DataReadout(label: "超长函数", value: NumberFormat.grouped(code.longFunctions),
                                caption: "个")
                    DataReadout(label: "平均函数长度",
                                value: "\(NumberFormat.grouped(code.averageFunctionLength)) 行",
                                caption: "仅 ≥2 行的函数")
                    DataReadout(label: "巨大文件", value: NumberFormat.grouped(code.hugeFiles.count),
                                caption: "个")
                }
                DataReadoutBar {
                    DataReadout(label: "高/严重复杂度",
                                value: NumberFormat.grouped(CodeRiskAnalysis.highRiskFunctionCount(code)),
                                caption: "个函数",
                                role: CodeRiskAnalysis.highRiskFunctionCount(code) > 0
                                    ? Theme.Semantic.danger : Theme.Semantic.neutral)
                    DataReadout(label: "平均圈复杂度",
                                value: CodeRiskAnalysis.averageComplexityValue(code),
                                caption: CodeRiskAnalysis.averageComplexityCaption(code),
                                role: Theme.Semantic.info)
                    DataReadout(label: "复杂度上榜",
                                value: NumberFormat.grouped(code.topComplexFunctions.count),
                                caption: "个函数")
                    DataReadout(label: "重复块",
                                value: NumberFormat.grouped(code.duplicatedBlocks.count),
                                caption: "个",
                                role: Theme.Semantic.role(for: code.overallRisk))
                }
            }
        }
    }

    static func subtitle(_ code: CodeMetrics) -> String {
        "最近扫描 " + DateFormat.sinceDescription(code.scannedAt)
            + " · 耗时 " + CodeViewFormat.duration(code.durationMs)
    }
}

// MARK: - 重复代码率

struct CodeDuplicationSection: View {
    let code: CodeMetrics
    let root: String

    static let rowLimit = 12

    var body: some View {
        let ratio = CodeRiskAnalysis.ratioRole(code.duplicationRatio)
        GlassSection(
            "重复代码率",
            subtitle: "分母是有效代码行数（不含空行与注释）· 分子是落在重复块内的代码行",
            icon: .duplicate
        ) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                    Text(NumberFormat.percent(code.duplicationRatio, precision: 1))
                        .font(Theme.Typo.metricNumber.font)
                        .foregroundStyle(ratio.textColor)
                    Text("的代码行落在重复块内")
                        .font(Theme.Typo.label.font)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: Theme.Spacing.xs)
                }

                MiniBarGauge(fraction: code.duplicationRatio, tint: ratio.graphicColor, height: DataGaugeHeight.metric)

                Text(CodeRiskAnalysis.duplicationCaption(code))
                    .font(Theme.Typo.microLabel.font)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                DataRowSeparator()

                if code.duplicatedBlocks.isEmpty {
                    EmptyStateView(
                        icon: .noRisk,
                        title: "已完成扫描，未发现重复块",
                        message: "扫描了 \(NumberFormat.grouped(code.totalFiles)) 个文件 / "
                            + "\(NumberFormat.grouped(code.codeLines)) 行有效代码，"
                            + "重复率为 \(NumberFormat.percent(code.duplicationRatio, precision: 1))。"
                    )
                } else {
                    VStack(spacing: Theme.Spacing.xs) {
                        DataTableHeader(columns: DataColumns.duplicationBlocks)
                        let rows = Array(code.duplicatedBlocks.prefix(Self.rowLimit))
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, block in
                            CodeDuplicationBlockRow(block: block, root: root)
                            if index < rows.count - 1 {
                                DataRowSeparator()
                            }
                        }
                    }
                    if code.duplicatedBlocks.count > shownCount {
                        Text("另有 \(NumberFormat.grouped(code.duplicatedBlocks.count - shownCount)) 个重复块未列出。")
                            .font(Theme.Typo.microLabel.font)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var shownCount: Int { min(Self.rowLimit, code.duplicatedBlocks.count) }
}

// MARK: - 高复杂度函数

struct CodeComplexitySection: View {
    let code: CodeMetrics
    let root: String

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
                VStack(spacing: Theme.Spacing.xs) {
                    DataTableHeader(columns: DataColumns.complexityFunctions)
                    let rows = code.topComplexFunctions
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, hotspot in
                        CodeComplexityRow(hotspot: hotspot, root: root)
                        if index < rows.count - 1 {
                            DataRowSeparator()
                        }
                    }
                }
                Text("点击行在 Finder 中定位源文件，行尾图标用默认应用打开。")
                    .font(Theme.Typo.microLabel.font)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .padding(.top, Theme.Spacing.xxs)
            }
        }
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
                VStack(spacing: Theme.Spacing.xs) {
                    ForEach(items) { item in
                        DataNotice(text: item.text, role: item.role, icon: item.icon,
                                   symbol: item.symbol, iconLabel: item.label)
                    }
                }
            }
        }
    }
}
