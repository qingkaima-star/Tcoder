import AppKit
import SwiftUI

// MARK: - 复杂度风险页的行件与判据（WS-L）
//
// 页面上每一条结论都要能回指到一个真实数字，所以判据全部收在 `CodeRiskAnalysis` 这组
// 纯函数里（含阈值），由 `CodeRiskAnalysisTests` 直接钉住——避免出现"测的是一套、
// 渲染的是另一套"。

// MARK: 判据

enum CodeRiskAnalysis {
    /// 重复率的两个观感档位：值得动手抽取 / 已属高风险。
    static let duplicationNotableRatio = 0.08
    static let duplicationHighRatio = 0.15
    /// 建议区块用到的判断条件（不是指标值）。
    static let manyParameterCount = 6
    static let longAverageFunctionLines = 25
    static let lowCommentRatio: Double = 0.05
    /// 全仓均值与热点榜均值背离到几倍才值得单独提一条建议。
    static let hotspotDivergenceFactor = 3.0

    /// 重复率分档。低于「值得动手」线才允许给 success（绿）——绿色是结论，不是默认值。
    static func ratioRole(_ ratio: Double) -> Theme.SemanticRole {
        if ratio >= duplicationHighRatio { return Theme.Semantic.danger }
        if ratio >= duplicationNotableRatio { return Theme.Semantic.warning }
        return Theme.Semantic.success
    }

    static func duplicationCaption(_ code: CodeMetrics) -> String {
        let duplicatedLines = Int((code.duplicationRatio * Double(code.codeLines)).rounded())
        return "约 \(NumberFormat.grouped(duplicatedLines)) 行 / 有效代码 "
            + "\(NumberFormat.grouped(code.codeLines)) 行 · 重复块 "
            + "\(NumberFormat.grouped(code.duplicatedBlocks.count)) 个"
    }

    static func highRiskFunctionCount(_ code: CodeMetrics) -> Int {
        code.topComplexFunctions.filter { $0.risk.rank >= RiskLevel.high.rank }.count
    }

    /// 一个函数都没识别出来时不能显示 0（那是「极简」的意思），也不能显示 `--`
    /// （那是「没扫」的意思）：扫描做过了、函数集合是空的，这个平均值的分母为 0，
    /// 属于「算不出」。见 `DataAbsence.indeterminate` 与《42》§14.3 第 1 条。
    static func averageComplexityValue(_ code: CodeMetrics) -> String {
        guard let average = code.averageCyclomaticComplexity else {
            return DataAbsence.indeterminate.display
        }
        return String(format: "%.2f", average)
    }

    static func averageComplexityCaption(_ code: CodeMetrics) -> String {
        guard code.averageCyclomaticComplexity != nil else { return "未识别到函数" }
        return "\(NumberFormat.grouped(code.analyzedFunctionCount)) 个函数平均"
    }

    static func complexitySubtitle(_ code: CodeMetrics) -> String {
        guard !code.topComplexFunctions.isEmpty else { return "按圈复杂度降序" }
        let complexities = code.topComplexFunctions.map(\.cyclomaticComplexity)
        return "按圈复杂度降序 · 上榜 \(NumberFormat.grouped(code.topComplexFunctions.count)) 个 · CC 区间 "
            + "\(NumberFormat.grouped(complexities.min() ?? 0))~\(NumberFormat.grouped(complexities.max() ?? 0))"
            + " · 颜色取自引擎给出的风险分档"
    }

    static func noRiskNote(_ code: CodeMetrics) -> String {
        "已完成扫描，本次未见结构性风险：重复代码率 "
            + NumberFormat.percent(code.duplicationRatio, precision: 1)
            + "、超长函数 \(NumberFormat.grouped(code.longFunctions)) 个、最大文件 "
            + "\(NumberFormat.grouped(code.largestFileLineCount)) 行。保持现状即可。"
    }

    // MARK: 建议条目

    struct Item: Identifiable, Equatable {
        let id: String
        let label: String
        let icon: IconName
        let symbol: String?
        let role: Theme.SemanticRole
        let text: String

        init(id: String, label: String, icon: IconName = .info, symbol: String? = nil,
             role: Theme.SemanticRole, text: String) {
            self.id = id
            self.label = label
            self.icon = icon
            self.symbol = symbol
            self.role = role
            self.text = text
        }
    }

    static func suggestions(for code: CodeMetrics) -> [Item] {
        duplicationAdvice(code) + complexityAdvice(code) + scaleAdvice(code)
    }

    static func longestBlockReference(_ code: CodeMetrics) -> DuplicatedBlock? {
        code.duplicatedBlocks.max(by: { $0.lineCount < $1.lineCount })
    }

    /// 建议文案里点名重复块出现的文件（最多 2 个，剩下的用处数说明）。
    static func occurrenceFileSummary(_ block: DuplicatedBlock, root: String = "") -> String {
        let names = Array(block.occurrences.prefix(2))
            .map { "\(CodeViewFormat.fileName($0.path)):\(NumberFormat.grouped($0.startLine))" }
        let rest = block.occurrences.count - names.count
        let joined = names.joined(separator: "、")
        return rest > 0 ? "\(joined) 等文件" : joined
    }

    static func relativeComplexitySuggestion(_ code: CodeMetrics) -> String? {
        guard let average = code.averageCyclomaticComplexity, average > 0 else { return nil }
        let hotspots = code.topComplexFunctions.map(\.cyclomaticComplexity)
        guard hotspots.count >= 5 else { return nil }
        let hotspotAverage = Double(hotspots.reduce(0, +)) / Double(hotspots.count)
        guard hotspotAverage >= average * hotspotDivergenceFactor else { return nil }
        return "全仓 \(String(format: "%.2f", average))，但热点榜平均 "
            + "\(String(format: "%.2f", hotspotAverage))：平均值被少数巨型函数拉高（超长函数 "
            + "\(NumberFormat.grouped(code.longFunctions)) 个），优先拆这几个而不是整体重构："
            + hotspots.prefix(3).map(String.init).joined(separator: " / ") + "。"
    }
}

// MARK: - 重复块行

struct CodeDuplicationBlockRow: View {
    let block: DuplicatedBlock
    let root: String

    private var columns: [DataGridColumn] { DataColumns.duplicationBlocks }

    var body: some View {
        HStack(alignment: .center, spacing: DataRowMetrics.cellGap) {
            Button {
                reveal(block.occurrences.first?.path)
            } label: {
                HStack(alignment: .center, spacing: DataRowMetrics.cellGap) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text(Self.occurrenceTitles(block, root: root))
                            .font(CodeGitType.tableIdentifier)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .tableCell(DataColumns.column(columns, 0))

                    Text(NumberFormat.grouped(block.lineCount))
                        .font(CodeGitType.number(Theme.Typo.monoSmall))
                        .tableCell(DataColumns.column(columns, 1))

                    Text(NumberFormat.grouped(block.occurrences.count))
                        .font(CodeGitType.number(Theme.Typo.monoSmall))
                        .foregroundStyle(.secondary)
                        .tableCell(DataColumns.column(columns, 2))

                    Text(NumberFormat.percent(block.similarity, precision: 1))
                        .font(CodeGitType.number(Theme.Typo.microLabel))
                        .foregroundStyle(.secondary)
                        .tableCell(DataColumns.column(columns, 3))
                }
                .dataTableRow()
                .padding(.horizontal, Theme.Spacing.xs)
                .background(CodeGitRowTint.fill(Theme.Semantic.neutral),
                            in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Self.hint(block, root: root))

            if let first = block.occurrences.first {
                CodeOpenFileButton(path: first.path, root: root)
                    .tableCell(DataColumns.column(columns, 4))
            }
        }
    }

    private func reveal(_ path: String?) {
        guard let path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([CodeViewFormat.resolvedURL(path, root: root)])
    }

    /// 最多列 4 个 occurrence，其余如实汇总为「另有 N 处」。
    static func occurrenceTitles(_ block: DuplicatedBlock, root: String, limit: Int = 4) -> String {
        let shown = block.occurrences.prefix(limit)
            .map { "\(CodeViewFormat.pathTail($0.path, root: root)):\(NumberFormat.grouped($0.startLine))" }
        let joined = shown.joined(separator: "   ")
        let rest = block.occurrences.count - shown.count
        return rest > 0 ? "\(joined)   （另有 \(NumberFormat.grouped(rest)) 处）" : joined
    }

    static func hint(_ block: DuplicatedBlock, root: String) -> String {
        "相似度 \(NumberFormat.percent(block.similarity, precision: 1)) · "
            + "\(NumberFormat.grouped(block.lineCount)) 行 · 出现 "
            + "\(NumberFormat.grouped(block.occurrences.count)) 处\n"
            + occurrenceTitles(block, root: root, limit: block.occurrences.count)
    }
}

// MARK: - 复杂度行

struct CodeComplexityRow: View {
    let hotspot: FunctionHotspot
    let root: String

    private var columns: [DataGridColumn] { DataColumns.complexityFunctions }
    private var role: Theme.SemanticRole { Theme.Semantic.role(for: hotspot.risk) }

    var body: some View {
        HStack(alignment: .center, spacing: DataRowMetrics.cellGap) {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [CodeViewFormat.resolvedURL(hotspot.filePath, root: root)])
            } label: {
                HStack(alignment: .center, spacing: DataRowMetrics.cellGap) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text(hotspot.name)
                            .font(CodeGitType.tableIdentifier)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(CodeViewFormat.pathTail(hotspot.filePath, root: root))
                            .font(CodeGitType.path)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tableCell(DataColumns.column(columns, 0))

                    Text(NumberFormat.grouped(hotspot.startLine))
                        .font(CodeGitType.number(Theme.Typo.monoSmall))
                        .foregroundStyle(.secondary)
                        .tableCell(DataColumns.column(columns, 1))
                    Text(NumberFormat.grouped(hotspot.lineCount))
                        .font(CodeGitType.number(Theme.Typo.monoSmall))
                        .foregroundStyle(.secondary)
                        .tableCell(DataColumns.column(columns, 2))
                    Text(NumberFormat.grouped(hotspot.cyclomaticComplexity))
                        .font(CodeGitType.metric)
                        .foregroundStyle(role.textColor)
                        .tableCell(DataColumns.column(columns, 3))
                    Text(NumberFormat.grouped(hotspot.parameterCount))
                        .font(CodeGitType.number(Theme.Typo.monoSmall))
                        .foregroundStyle(.secondary)
                        .tableCell(DataColumns.column(columns, 4))
                    RiskBadge(risk: hotspot.risk, showIcon: false)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .tableCell(DataColumns.column(columns, 5))
                }
                .dataTableRow()
                .padding(.horizontal, Theme.Spacing.xs)
                .background(CodeGitRowTint.fill(role),
                            in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(hotspot.filePath):\(hotspot.startLine) · 点击在 Finder 中显示")

            CodeOpenFileButton(path: hotspot.filePath, root: root)
                .tableCell(DataColumns.column(columns, 6))
        }
    }
}
