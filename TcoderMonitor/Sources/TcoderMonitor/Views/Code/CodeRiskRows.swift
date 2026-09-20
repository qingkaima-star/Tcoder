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
        var items: [Item] = []

        // 1) 重复代码：分档措辞，数字取自 ratio / blocks。
        let duplicatedLines = Int((code.duplicationRatio * Double(code.codeLines)).rounded())
        let longestBlock = code.duplicatedBlocks.map(\.lineCount).max() ?? 0
        if code.duplicationRatio >= duplicationHighRatio, let block = longestBlockReference(code) {
            items.append(Item(
                id: "duplication-high", label: "重复代码", icon: .duplicate, role: Theme.Semantic.danger,
                text: "重复率 \(NumberFormat.percent(code.duplicationRatio, precision: 1))"
                    + "（约 \(NumberFormat.grouped(duplicatedLines)) / "
                    + "\(NumberFormat.grouped(code.codeLines)) 行）已达高风险档：最长一处 "
                    + "\(NumberFormat.grouped(block.lineCount)) 行，出现在 "
                    + occurrenceFileSummary(block) + "（共 "
                    + "\(NumberFormat.grouped(block.occurrences.count)) 处）。"
                    + "把这类块抽成公共工具函数或模板方法，差异部分用参数/闭包传入，只保留一份实现。"
            ))
        } else if code.duplicationRatio >= duplicationNotableRatio, let block = longestBlockReference(code) {
            items.append(Item(
                id: "duplication-notable", label: "重复代码", icon: .duplicate, role: Theme.Semantic.warning,
                text: "重复率 \(NumberFormat.percent(code.duplicationRatio, precision: 1))"
                    + "（约 \(NumberFormat.grouped(duplicatedLines)) / "
                    + "\(NumberFormat.grouped(code.codeLines)) 行）：最长重复块 "
                    + "\(NumberFormat.grouped(block.lineCount)) 行、出现在 "
                    + occurrenceFileSummary(block) + "。改动这些文件时顺手合并成一处实现，"
                    + "可把重复率压到 \(NumberFormat.percent(duplicationNotableRatio, precision: 0)) 以下。"
            ))
        } else if code.duplicationRatio > 0 {
            items.append(Item(
                id: "duplication-low", label: "重复代码", icon: .duplicate, role: Theme.Semantic.neutral,
                text: "重复率 \(NumberFormat.percent(code.duplicationRatio, precision: 1))"
                    + "（约 \(NumberFormat.grouped(duplicatedLines)) / "
                    + "\(NumberFormat.grouped(code.codeLines)) 行）仍在低档："
                    + "\(NumberFormat.grouped(code.duplicatedBlocks.count)) 个重复块中最长 "
                    + "\(NumberFormat.grouped(longestBlock)) 行，暂不需要专门重构，"
                    + "改到相关代码时顺带去重即可。"
            ))
        }

        // 2) 圈复杂度严重档：CC 数字与函数名逐条点名。
        let critical = code.topComplexFunctions.filter { $0.risk == .critical }
        if !critical.isEmpty {
            let named = critical.prefix(3).map {
                "\($0.name)（CC \(NumberFormat.grouped($0.cyclomaticComplexity)) · "
                    + "\(NumberFormat.grouped($0.lineCount)) 行 · "
                    + "\(CodeViewFormat.fileName($0.filePath)):\(NumberFormat.grouped($0.startLine))）"
            }
            let highest = critical.map(\.cyclomaticComplexity).max() ?? 0
            let lowestOnBoard = code.topComplexFunctions.map(\.cyclomaticComplexity).min() ?? 0
            items.append(Item(
                id: "complexity-critical", label: "严重复杂度", icon: .riskSevere, role: Theme.Semantic.critical,
                text: "\(NumberFormat.grouped(critical.count)) 个函数被判为严重复杂度，"
                    + "最高圈复杂度 \(NumberFormat.grouped(highest))：" + named.joined(separator: "、")
                    + "。先去掉嵌套：校验与异常分支改成提前返回，再把成组的分支换成策略表/多态；"
                    + "先把分支数压到上榜函数的最低水位 CC \(NumberFormat.grouped(lowestOnBoard)) 以下。"
            ))
        }

        // 3) 高档复杂度聚集。
        let high = code.topComplexFunctions.filter { $0.risk == .high }
        if high.count >= 3 {
            items.append(Item(
                id: "complexity-high-cluster", label: "高复杂度聚集", icon: .complexity, role: Theme.Semantic.warning,
                text: "同时有 \(NumberFormat.grouped(high.count)) 个函数处于高复杂度档（CC "
                    + "\(NumberFormat.grouped(high.map(\.cyclomaticComplexity).min() ?? 0))~"
                    + "\(NumberFormat.grouped(high.map(\.cyclomaticComplexity).max() ?? 0))）："
                    + "先给它们补单元测试，再把分支下沉成命名清晰的小函数。"
            ))
        }

        // 4) 参数过多的函数（真实计数）。
        let manyParams = code.topComplexFunctions.filter { $0.parameterCount >= manyParameterCount }
        if let worst = manyParams.max(by: { $0.parameterCount < $1.parameterCount }) {
            items.append(Item(
                id: "parameters", label: "参数过多", symbol: CodeGitSymbol.parameters,
                role: Theme.Semantic.warning,
                text: "\(NumberFormat.grouped(manyParams.count)) 个上榜函数的参数达到或超过 "
                    + "\(NumberFormat.grouped(manyParameterCount)) 个，最多的是 \(worst.name)"
                    + "（\(NumberFormat.grouped(worst.parameterCount)) 个参数 · "
                    + "\(CodeViewFormat.fileName(worst.filePath)):\(NumberFormat.grouped(worst.startLine))）："
                    + "把成组参数收进一个配置或值类型，调用点会同步变短。"
            ))
        }

        // 5) 函数整体长度。
        if code.longFunctions > 0 {
            items.append(Item(
                id: "long-functions", label: "函数长度", symbol: CodeGitSymbol.longFunction,
                role: code.averageFunctionLength > longAverageFunctionLines
                    ? Theme.Semantic.warning : Theme.Semantic.neutral,
                text: "识别到 \(NumberFormat.grouped(code.longFunctions)) 个超长函数，"
                    + "平均函数长度 \(NumberFormat.grouped(code.averageFunctionLength)) 行："
                    + "按段落把函数拆成职责单一的私有方法，一个函数只做一件事。"
            ))
        }

        // 6) 全仓均值与热点榜均值背离——平均值被少数巨型函数拉高时，建议按函数处理而不是整体重构。
        if let divergence = relativeComplexitySuggestion(code) {
            items.append(Item(id: "complexity-divergence", label: "复杂度分布", icon: .chartLine,
                              role: Theme.Semantic.neutral, text: divergence))
        }

        // 7) 巨大文件：给出真实行数与扫描器自己的建议原文。
        if let largest = code.hugeFiles.max(by: { $0.lineCount < $1.lineCount }) {
            items.append(Item(
                id: "huge-file", label: "巨大文件", icon: .duplicate,
                role: Theme.Semantic.role(for: largest.risk),
                text: "最大文件 \(CodeViewFormat.fileName(largest.path)) 共 "
                    + "\(NumberFormat.grouped(largest.lineCount)) 行（项目行数峰值 "
                    + "\(NumberFormat.grouped(code.largestFileLineCount)) 行）：\(largest.suggestion)"
            ))
        }

        // 8) FIXME / TODO：按真实条数提示。
        if code.fixmeCount > 0 {
            let perKilo = Double(code.fixmeCount + code.todoCount) * 1_000 / Double(max(1, code.codeLines))
            items.append(Item(
                id: "markers", label: "待办标记", symbol: CodeGitSymbol.marker, role: Theme.Semantic.warning,
                text: "源码里留着 \(NumberFormat.grouped(code.fixmeCount)) 处 FIXME（另有 "
                    + "\(NumberFormat.grouped(code.todoCount)) 处 TODO），平均每千行有效代码 "
                    + String(format: "%.2f", perKilo) + " 条：逐条确认是修掉还是删注释，避免长期失真。"
            ))
        }

        // 9) 注释率：只在确实偏低时提，数字来自 commentLines / totalLines。
        if code.totalLines > 0, code.commentRatio < lowCommentRatio {
            items.append(Item(
                id: "comments", label: "注释率", symbol: CodeGitSymbol.comments, role: Theme.Semantic.neutral,
                text: "注释率 \(NumberFormat.percent(code.commentRatio))"
                    + "（\(NumberFormat.grouped(code.commentLines)) / "
                    + "\(NumberFormat.grouped(code.totalLines)) 行）低于本页 "
                    + "\(NumberFormat.percent(lowCommentRatio, precision: 0)) 的提示线："
                    + "优先给对外接口和圈复杂度最高的那批函数写意图说明，直白代码不必加注释。"
            ))
        }

        return items
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
                        // **每个 occurrence 一行、每行单段中间省略**，不再把 4 条路径
                        // 用三个空格粘成一个长串去自动换行。原来的后果（实拍可见）：
                        // 两条长路径在单元格里挤成一团、第二行直接顶到「行数」列跟前，
                        // 列与列之间只剩"空格"当分隔 —— 表就没有表了。
                        ForEach(Array(Self.occurrenceLines(block, root: root).enumerated()),
                                id: \.offset) { _, line in
                            Text(line.text)
                                .font(CodeGitType.tableIdentifier)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                // 中间截断必须可回读全路径，否则"看得见一半"比看不见更难查
                                .themeHelp(line.help)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        let rest = Self.occurrenceRestCount(block)
                        if rest > 0 {
                            // 汇总行写成 `Text(字面量)`：拼成 String 再交给 Text(variable)
                            // 就永远不查表（双语方案 §7），这里没有理由留新债。
                            Text("另有 \(NumberFormat.grouped(rest)) 处")
                                .font(CodeGitType.tableIdentifier)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .themeHelp(Self.occurrenceTitles(block, root: root))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
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
                // 行与行之间只留发丝线，**不铺行底**。原来每行是一块 7.5% 中性灰圆角面，
                // 二十行叠起来 = 本页 36% 的像素落在灰带里（`pixel_audit` 实测），
                // 用户判词「不要用灰色底显脏」在这一页指的就是它。
                // 可点性不靠底色交代：行尾本来就有打开文件的按钮 + `help` + 指针光标。
                .overlay(alignment: .bottom) { DataRowSeparator() }
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

    /// 一格里最多摊开两条路径，第三条起收成「另有 N 处」。
    /// 上限取 2 是因为整行高度由「行数/出现/相似度」三个单行数字决定，
    /// 路径格超过两行就会把这一行拉高、五列基线断开。
    static let occurrenceLineLimit = 2

    struct OccurrenceLine {
        let text: String
        /// 中间截断后的回读出口：完整路径。
        let help: String?
    }

    static func occurrenceLines(_ block: DuplicatedBlock, root: String,
                                limit: Int = occurrenceLineLimit) -> [OccurrenceLine] {
        block.occurrences.prefix(limit).map { occurrence in
            OccurrenceLine(
                text: "\(CodeViewFormat.pathTail(occurrence.path, root: root)):"
                    + "\(NumberFormat.grouped(occurrence.startLine))",
                help: occurrence.path)
        }
    }

    /// 被折进「另有 N 处」的条数；算术只在这一处，视图与测试共用。
    static func occurrenceRestCount(_ block: DuplicatedBlock,
                                    limit: Int = occurrenceLineLimit) -> Int {
        max(0, block.occurrences.count - limit)
    }

    /// 保留：完整拼接串。只给 tooltip（`.help` / 「另有 N 处」悬浮）与旧断言用。
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
                // 同上：热点行也不铺行底（`role` 那一份是按风险档着色，
                // 一屏十行就是十条彩带，比灰带更抢主读数）。
                .overlay(alignment: .bottom) { DataRowSeparator() }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(hotspot.filePath):\(hotspot.startLine) · 点击在 Finder 中显示")

            CodeOpenFileButton(path: hotspot.filePath, root: root)
                .tableCell(DataColumns.column(columns, 6))
        }
    }
}
