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

    /// 重复率那一格的口径说明。**分子分母是全仓，块数只是榜内条数**——两件事必须分开说
    /// （RD-17）：`duplicationRatio` 按全量命中算，而 `duplicatedBlocks` 被
    /// `DuplicationEngine.maxBlocks` 截过；榜满了就不许再把它的条数念成"这个仓库有多少重复块"。
    static func duplicationCaption(_ code: CodeMetrics) -> String {
        let duplicatedLines = Int((code.duplicationRatio * Double(code.codeLines)).rounded())
        return "约 \(NumberFormat.grouped(duplicatedLines)) 行 / 有效代码 "
            + "\(NumberFormat.grouped(code.codeLines)) 行 · "
            + CodeBoardTruth.duplicationBlockWord(code) + " "
            + "\(NumberFormat.grouped(CodeBoardTruth.duplicationBoardCount(code))) 个"
    }

    static func highRiskFunctionCount(_ code: CodeMetrics) -> Int {
        // 走契约里那一格，不在**榜**上 filter：榜只留前 20，热点 38 个的仓库会把高档个数
        // 截成 ≤20，于是"高复杂度函数 N 个"越大的项目越显健康（与"榜长冒充总数"同一条病）。
        // 旧报告没有这一格时，`reportedHighRiskHotspotCount` 才退回榜内算法（偏松，但可用）。
        code.reportedHighRiskHotspotCount
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
        return localizedFormat("%1$@ 个函数平均", NumberFormat.grouped(code.analyzedFunctionCount))
    }

    static func complexitySubtitle(_ code: CodeMetrics) -> String {
        guard !code.topComplexFunctions.isEmpty else { return "按圈复杂度降序" }
        let complexities = code.topComplexFunctions.map(\.cyclomaticComplexity)
        return localizedFormat("按圈复杂度降序 · 上榜 %1$@ 个 · CC 区间 %2$@~%3$@ · 颜色取自引擎给出的风险分档",
                                NumberFormat.grouped(code.topComplexFunctions.count),
                                NumberFormat.grouped(complexities.min() ?? 0),
                                NumberFormat.grouped(complexities.max() ?? 0))
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
        let joined = names.joined(separator: localizedListSeparator())
        return rest > 0 ? "\(joined) 等文件" : joined
    }

    static func relativeComplexitySuggestion(_ code: CodeMetrics) -> String? {
        guard let average = code.averageCyclomaticComplexity, average > 0 else { return nil }
        let hotspots = code.topComplexFunctions.map(\.cyclomaticComplexity)
        guard hotspots.count >= 5 else { return nil }
        let hotspotAverage = Double(hotspots.reduce(0, +)) / Double(hotspots.count)
        guard hotspotAverage >= average * hotspotDivergenceFactor else { return nil }
        return localizedFormat("全仓 %1$@，但热点榜平均 %2$@：平均值被少数巨型函数拉高（超长函数 %3$@ 个），优先拆这几个而不是整体重构：%4$@。",
                                String(format: "%.2f", average),
                                String(format: "%.2f", hotspotAverage),
                                NumberFormat.grouped(code.longFunctions),
                                hotspots.prefix(3).map(String.init).joined(separator: " / "))
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
                            Text(localizedCount("另有 %lld 处", rest))
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

    /// 在 Finder 中显示。坐标是**相对被扫根**的（RD-61 第二半），root 由页面从
    /// `report.project.path` 传进来，与装配 `provenance.scannedRoot` 同一个串；
    /// 拼回去这件事只发生在 `CodeViewFormat.resolvedURL` 那一个入口（行尾那个
    /// 「用默认应用打开」按钮走的是同一个函数），这里不另写一份拼接。
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
        /// 中间截断后的回读出口：整条坐标（相对被扫根，RD-61 第二半之后不再带机器前缀）。
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
        return joined + (rest > 0 ? "   " + localizedFormat("（另有 %1$@ 处）", NumberFormat.grouped(rest)) : "")
    }

    static func hint(_ block: DuplicatedBlock, root: String) -> String {
        // **整句一条键**，不拆成三段各自做键：拆开运行时查得到，可按字面量比对键的
        // 守卫会判"目录里有死键"，而英文态语序也必坏（双语方案 §9）。
        // 后面的 occurrence 标题是用户自己的文件路径，属于数据，不翻。
        localizedFormat("相似度 %1$@ · %2$@ 行 · 出现 %3$@ 处",
                        NumberFormat.percent(block.similarity, precision: 1),
                        NumberFormat.grouped(block.lineCount),
                        NumberFormat.grouped(block.occurrences.count))
            + "\n" + occurrenceTitles(block, root: root, limit: block.occurrences.count)
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
            .help(localizedFormat("%1$@ · 点击在 Finder 中显示", "\(hotspot.filePath):\(hotspot.startLine)"))

            CodeOpenFileButton(path: hotspot.filePath, root: root)
                .tableCell(DataColumns.column(columns, 6))
        }
    }
}
