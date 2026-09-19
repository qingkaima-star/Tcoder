import SwiftUI
import AppKit

/// OWNER: WS-A / 子代理3 —— 「复杂度风险」页。
/// 只读 `report?.code`：所有数字来自扫描结果本身，改进建议必须由这些数字派生，
/// 数据缺失时显示空状态而不是 0。
struct CodeRiskView: View {
    var report: ProjectReport?

    // 表格列宽（布局常量，不是指标）。
    private static let lineWidth: CGFloat = 46
    private static let lengthWidth: CGFloat = 44
    private static let complexityWidth: CGFloat = 34
    private static let parameterWidth: CGFloat = 34
    private static let badgeWidth: CGFloat = 78
    private static let openWidth: CGFloat = 22
    private static let duplicationRowLimit = 12
    private static let occurrenceLimit = 4

    /// 重复率的两个观感档位：值得动手抽取 / 已属高风险。
    fileprivate static let duplicationNotableRatio = 0.08
    fileprivate static let duplicationHighRatio = 0.15
    /// 建议区块用到的阈值（判断条件，不是指标值）。
    private static let manyParameterCount = 6
    private static let longAverageFunctionLines = 25
    private static let lowCommentRatio: Double = 0.05

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: - Data gate

    /// 判定顺序：先 `code == nil`（未扫描/扫描失败），再看「全零」。
    private var metrics: CodeMetrics? {
        guard let code = report?.code else { return nil }
        guard code.totalFiles > 0 || code.totalLines > 0 else { return nil }
        return code
    }

    @ViewBuilder
    private var content: some View {
        if let code = metrics {
            riskOverviewCard(code)
            duplicationCard(code)
            complexityCard(code)
            suggestionCard(code)
        } else {
            EmptyStateView(
                icon: "exclamationmark.triangle",
                title: report?.code == nil ? "尚无代码扫描结果" : "扫描结果为空",
                message: report?.code == nil
                    ? "点击「重新分析」扫描该目录后，这里会显示真实的复杂度、重复率与改进建议。"
                    : "扫描已完成，但没有识别到任何源码文件，因此没有可评估的风险。"
            )
            .frame(maxWidth: .infinity, minHeight: 280)
        }
    }

    // MARK: - Overview

    private func riskOverviewCard(_ code: CodeMetrics) -> some View {
        SectionCard(
            "风险总览",
            subtitle: "最近扫描 " + DateFormat.sinceDescription(code.scannedAt) + " · 耗时 " + CodeViewFormat.duration(code.durationMs),
            icon: "exclamationmark.triangle",
            trailing: AnyView(RiskBadge(risk: code.overallRisk))
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(code.overallRisk.rawValue)
                        .font(Theme.heroNumber)
                        .foregroundStyle(Theme.color(for: code.overallRisk))
                    Text("综合风险等级")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                }

                Text("口径：\(NumberFormat.grouped(code.totalFiles)) 个文件 · \(NumberFormat.grouped(code.codeLines)) 行有效代码 · 主语言 \(code.primaryLanguage)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 14) {
                    StatLine(label: "最大文件", value: "\(NumberFormat.grouped(code.largestFileLineCount)) 行")
                    StatLine(label: "超长函数", value: NumberFormat.grouped(code.longFunctions))
                    StatLine(label: "平均函数长度（仅 ≥2 行）", value: "\(NumberFormat.grouped(code.averageFunctionLength)) 行")
                }
                .font(.caption)

                HStack(spacing: 14) {
                    StatLine(label: "高/严重复杂度函数", value: NumberFormat.grouped(highRiskFunctionCount(code)))
                    StatLine(label: "平均圈复杂度（全仓）", value: averageComplexityText(code))
                    StatLine(label: "巨大文件", value: NumberFormat.grouped(code.hugeFiles.count))
                    StatLine(label: "重复块", value: NumberFormat.grouped(code.duplicatedBlocks.count))
                }
                .font(.caption)
            }
        }
    }

    // MARK: - Duplication

    private func duplicationCard(_ code: CodeMetrics) -> some View {
        SectionCard(
            "重复代码率",
            subtitle: "分母是有效代码行数（不含空行与注释）· 分子是落在重复块内的代码行",
            icon: "doc.on.doc"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(NumberFormat.percent(code.duplicationRatio, precision: 1))
                        .font(Theme.metricNumber)
                        .foregroundStyle(duplicationTint(code.duplicationRatio))
                    Text("的代码行落在重复块内")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                }

                MiniBarGauge(
                    fraction: code.duplicationRatio,
                    tint: duplicationTint(code.duplicationRatio),
                    height: 6
                )

                Text(duplicationCaption(code))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)

                Divider().opacity(0.4)

                if code.duplicatedBlocks.isEmpty {
                    EmptyStateView(
                        icon: "checkmark.seal",
                        title: "未发现重复块",
                        message: "扫描了 \(NumberFormat.grouped(code.totalFiles)) 个文件 / \(NumberFormat.grouped(code.codeLines)) 行有效代码，重复率为 \(NumberFormat.percent(code.duplicationRatio, precision: 1))。"
                    )
                    .frame(minHeight: 90)
                } else {
                    VStack(spacing: 6) {
                        ForEach(code.duplicatedBlocks.prefix(Self.duplicationRowLimit)) { block in
                            duplicationRow(block)
                        }
                    }
                    if code.duplicatedBlocks.count > Self.duplicationRowLimit {
                        Text("另有 \(NumberFormat.grouped(code.duplicatedBlocks.count - Self.duplicationRowLimit)) 个重复块未列出。")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func duplicationCaption(_ code: CodeMetrics) -> String {
        let duplicatedLines = Int((code.duplicationRatio * Double(code.codeLines)).rounded())
        return "约 \(NumberFormat.grouped(duplicatedLines)) 行 / 有效代码 \(NumberFormat.grouped(code.codeLines)) 行 · 重复块 \(NumberFormat.grouped(code.duplicatedBlocks.count)) 个"
    }

    private func duplicationRow(_ block: DuplicatedBlock) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Button {
                if let first = block.occurrences.first {
                    revealInFinder(first.path)
                }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("\(NumberFormat.grouped(block.lineCount)) 行")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        Text("\(NumberFormat.grouped(block.occurrences.count)) 处出现")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Text("相似度 \(NumberFormat.percent(block.similarity, precision: 1))")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    Text(occurrenceTitles(block))
                        .font(Theme.monoSmall)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.gridLine, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("点击在 Finder 中显示第一个出现的文件")

            if let first = block.occurrences.first {
                Button {
                    openFile(first.path)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
                .help("用默认应用打开 \(CodeViewFormat.fileName(first.path))")
            }
        }
    }

    /// 最多列 4 个 occurrence，其余如实汇总为「另有 N 处」。
    private func occurrenceTitles(_ block: DuplicatedBlock) -> String {
        let shown = block.occurrences.prefix(Self.occurrenceLimit)
            .map { "\(CodeViewFormat.pathTail($0.path, root: projectRoot)):\(NumberFormat.grouped($0.startLine))" }
        let joined = shown.joined(separator: "   ")
        let rest = block.occurrences.count - shown.count
        return rest > 0 ? "\(joined)   （另有 \(NumberFormat.grouped(rest)) 处）" : joined
    }

    // MARK: - Complexity table

    private func complexityCard(_ code: CodeMetrics) -> some View {
        SectionCard(
            "高复杂度函数",
            subtitle: complexitySubtitle(code),
            icon: "function"
        ) {
            if code.topComplexFunctions.isEmpty {
                EmptyStateView(
                    icon: "checkmark.seal",
                    title: "没有上榜函数",
                    message: "本次扫描没有函数达到引擎给出的复杂度上榜条件；参考数字：超长函数 \(NumberFormat.grouped(code.longFunctions)) 个 · 平均函数长度 \(NumberFormat.grouped(code.averageFunctionLength)) 行。"
                )
                .frame(minHeight: 110)
            } else {
                VStack(spacing: 3) {
                    complexityHeader
                    ForEach(code.topComplexFunctions) { hotspot in
                        complexityRow(hotspot)
                    }
                    Text("点击行在 Finder 中定位源文件，行尾图标用默认应用打开。")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                }
            }
        }
    }

    private func complexitySubtitle(_ code: CodeMetrics) -> String {
        guard !code.topComplexFunctions.isEmpty else { return "按圈复杂度降序" }
        let highest = code.topComplexFunctions.map(\.cyclomaticComplexity).max() ?? 0
        let lowest = code.topComplexFunctions.map(\.cyclomaticComplexity).min() ?? 0
        return "按圈复杂度降序 · 上榜 \(NumberFormat.grouped(code.topComplexFunctions.count)) 个 · CC 区间 \(NumberFormat.grouped(lowest))~\(NumberFormat.grouped(highest)) · 颜色取自引擎给出的风险分档"
    }

    private var complexityHeader: some View {
        HStack(spacing: 8) {
            Text("函数")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("起始行").frame(width: Self.lineWidth, alignment: .trailing)
            Text("行数").frame(width: Self.lengthWidth, alignment: .trailing)
            Text("CC").frame(width: Self.complexityWidth, alignment: .trailing)
            Text("参数").frame(width: Self.parameterWidth, alignment: .trailing)
            Text("风险").frame(width: Self.badgeWidth, alignment: .trailing)
            Text(" ").frame(width: Self.openWidth, alignment: .trailing)
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 6)
        .padding(.bottom, 2)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.4)
        }
    }

    private func complexityRow(_ hotspot: FunctionHotspot) -> some View {
        HStack(spacing: 6) {
            Button {
                revealInFinder(hotspot.filePath)
            } label: {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(hotspot.name)
                            .font(Theme.monoSmall)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(CodeViewFormat.pathTail(hotspot.filePath, root: projectRoot))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(NumberFormat.grouped(hotspot.startLine))
                        .font(Theme.monoSmall)
                        .foregroundStyle(.secondary)
                        .frame(width: Self.lineWidth, alignment: .trailing)
                    Text(NumberFormat.grouped(hotspot.lineCount))
                        .font(Theme.monoSmall)
                        .foregroundStyle(.secondary)
                        .frame(width: Self.lengthWidth, alignment: .trailing)
                    Text(NumberFormat.grouped(hotspot.cyclomaticComplexity))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.color(for: hotspot.risk))
                        .frame(width: Self.complexityWidth, alignment: .trailing)
                    Text(NumberFormat.grouped(hotspot.parameterCount))
                        .font(Theme.monoSmall)
                        .foregroundStyle(.secondary)
                        .frame(width: Self.parameterWidth, alignment: .trailing)
                    RiskBadge(risk: hotspot.risk, showIcon: false)
                        .frame(width: Self.badgeWidth, alignment: .trailing)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background(Theme.color(for: hotspot.risk).opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(hotspot.filePath):\(hotspot.startLine) · 点击在 Finder 中显示")

            Button {
                openFile(hotspot.filePath)
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            .controlSize(.mini)
            .frame(width: Self.openWidth, alignment: .trailing)
            .help("用默认应用打开 \(CodeViewFormat.fileName(hotspot.filePath))")
        }
    }

    // MARK: - Suggestions（全部由本次扫描的真实数字推导）

    private func suggestionCard(_ code: CodeMetrics) -> some View {
        SectionCard("改进建议", subtitle: "逐条对应本次扫描的真实数字，无数字支撑的不写", icon: "lightbulb") {
            let items = suggestions(code)
            if items.isEmpty {
                Text("本次扫描未发现结构性风险：重复率 \(NumberFormat.percent(code.duplicationRatio, precision: 1))、超长函数 \(NumberFormat.grouped(code.longFunctions)) 个、最大文件 \(NumberFormat.grouped(code.largestFileLineCount)) 行。保持现状即可。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(items, id: \.text) { item in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: item.icon)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(item.tint)
                            Text(item.text)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(item.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
    }

    private func suggestions(_ code: CodeMetrics) -> [CodeRiskSuggestion] {
        var items: [CodeRiskSuggestion] = []

        // 1) 重复代码：分档措辞，数字取自 ratio / blocks。
        let duplicatedLines = Int((code.duplicationRatio * Double(code.codeLines)).rounded())
        let longestBlock = code.duplicatedBlocks.map(\.lineCount).max() ?? 0
        if code.duplicationRatio >= Self.duplicationHighRatio, let block = longestBlockReference(code) {
            items.append(CodeRiskSuggestion(
                icon: "scissors",
                tint: Theme.danger,
                text: "重复率 \(NumberFormat.percent(code.duplicationRatio, precision: 1))（约 \(NumberFormat.grouped(duplicatedLines)) / \(NumberFormat.grouped(code.codeLines)) 行）已达高风险档：最长一处 \(NumberFormat.grouped(block.lineCount)) 行，出现在 \(occurrenceFileSummary(block))（共 \(NumberFormat.grouped(block.occurrences.count)) 处）。把这类块抽成公共工具函数或模板方法，差异部分用参数/闭包传入，只保留一份实现。"
            ))
        } else if code.duplicationRatio >= Self.duplicationNotableRatio, let block = longestBlockReference(code) {
            items.append(CodeRiskSuggestion(
                icon: "scissors",
                tint: Theme.caution,
                text: "重复率 \(NumberFormat.percent(code.duplicationRatio, precision: 1))（约 \(NumberFormat.grouped(duplicatedLines)) / \(NumberFormat.grouped(code.codeLines)) 行）：最长重复块 \(NumberFormat.grouped(block.lineCount)) 行、出现在 \(occurrenceFileSummary(block))。改动这些文件时顺手合并成一处实现，可把重复率压到 \(NumberFormat.percent(Self.duplicationNotableRatio, precision: 0)) 以下。"
            ))
        } else if code.duplicationRatio > 0 {
            items.append(CodeRiskSuggestion(
                icon: "doc.on.doc",
                tint: Theme.neutral,
                text: "重复率 \(NumberFormat.percent(code.duplicationRatio, precision: 1))（约 \(NumberFormat.grouped(duplicatedLines)) / \(NumberFormat.grouped(code.codeLines)) 行）仍在低档：\(NumberFormat.grouped(code.duplicatedBlocks.count)) 个重复块中最长 \(NumberFormat.grouped(longestBlock)) 行，暂不需要专门重构，改到相关代码时顺带去重即可。"
            ))
        }

        // 2) 圈复杂度严重档：CC 数字与函数名逐条点名。
        let critical = code.topComplexFunctions.filter { $0.risk == .critical }
        if !critical.isEmpty {
            let named = critical.prefix(3).map { "\($0.name)（CC \(NumberFormat.grouped($0.cyclomaticComplexity)) · \(NumberFormat.grouped($0.lineCount)) 行 · \(CodeViewFormat.fileName($0.filePath)):\(NumberFormat.grouped($0.startLine))）" }
            let highest = critical.map(\.cyclomaticComplexity).max() ?? 0
            let lowestOnBoard = code.topComplexFunctions.map(\.cyclomaticComplexity).min() ?? 0
            items.append(CodeRiskSuggestion(
                icon: "exclamationmark.triangle.fill",
                tint: Theme.critical,
                text: "\(NumberFormat.grouped(critical.count)) 个函数被判为严重复杂度，最高圈复杂度 \(NumberFormat.grouped(highest))：" + named.joined(separator: "、") + "。先去掉嵌套：校验与异常分支改成提前返回，再把成组的分支换成策略表/多态；先把分支数压到上榜函数的最低水位 CC \(NumberFormat.grouped(lowestOnBoard)) 以下。"
            ))
        }

        // 3) 高档复杂度聚集。
        let high = code.topComplexFunctions.filter { $0.risk == .high }
        if high.count >= 3 {
            items.append(CodeRiskSuggestion(
                icon: "arrow.triangle.branch",
                tint: Theme.caution,
                text: "同时有 \(NumberFormat.grouped(high.count)) 个函数处于高复杂度档（CC \(NumberFormat.grouped(high.map(\.cyclomaticComplexity).min() ?? 0))~\(NumberFormat.grouped(high.map(\.cyclomaticComplexity).max() ?? 0))）：先给它们补单元测试，再把分支下沉成命名清晰的小函数。"
            ))
        }

        // 4) 参数过多的函数（真实计数）。
        let manyParams = code.topComplexFunctions.filter { $0.parameterCount >= Self.manyParameterCount }
        if !manyParams.isEmpty, let worst = manyParams.max(by: { $0.parameterCount < $1.parameterCount }) {
            items.append(CodeRiskSuggestion(
                icon: "tray.full",
                tint: Theme.caution,
                text: "\(NumberFormat.grouped(manyParams.count)) 个上榜函数的参数达到或超过 \(NumberFormat.grouped(Self.manyParameterCount)) 个，最多的是 \(worst.name)（\(NumberFormat.grouped(worst.parameterCount)) 个参数 · \(CodeViewFormat.fileName(worst.filePath)):\(NumberFormat.grouped(worst.startLine))）：把成组参数收进一个配置或值类型，调用点会同步变短。"
            ))
        }

        // 5) 函数整体长度。
        if code.longFunctions > 0 {
            items.append(CodeRiskSuggestion(
                icon: "arrow.up.left.and.arrow.down.right",
                tint: code.averageFunctionLength > Self.longAverageFunctionLines ? Theme.caution : Theme.neutral,
                text: "识别到 \(NumberFormat.grouped(code.longFunctions)) 个超长函数，平均函数长度 \(NumberFormat.grouped(code.averageFunctionLength)) 行：按段落把函数拆成职责单一的私有方法，一个函数只做一件事。"
            ))
        }

        // 6b) 全仓平均圈复杂度与热点榜均值背离 —— 说明平均值被少数巨型函数拉高。
        if let divergence = relativeComplexitySuggestion(code) {
            items.append(CodeRiskSuggestion(icon: "chart.bar.xaxis", tint: Theme.neutral, text: divergence))
        }

        // 6) 巨大文件：给出真实行数与建议里的真实结构信息。
        if let largest = code.hugeFiles.max(by: { $0.lineCount < $1.lineCount }) {
            items.append(CodeRiskSuggestion(
                icon: "doc.on.doc",
                tint: Theme.color(for: largest.risk),
                text: "最大文件 \(CodeViewFormat.fileName(largest.path)) 共 \(NumberFormat.grouped(largest.lineCount)) 行（项目行数峰值 \(NumberFormat.grouped(code.largestFileLineCount)) 行）：\(largest.suggestion)"
            ))
        }

        // 7) FIXME / TODO：按真实条数提示。
        if code.fixmeCount > 0 {
            items.append(CodeRiskSuggestion(
                icon: "flag",
                tint: Theme.caution,
                text: "源码里留着 \(NumberFormat.grouped(code.fixmeCount)) 处 FIXME（另有 \(NumberFormat.grouped(code.todoCount)) 处 TODO），平均每千行有效代码 \(String(format: "%.2f", Double(code.fixmeCount + code.todoCount) * 1_000 / Double(max(1, code.codeLines)))) 条：逐条确认是修掉还是删注释，避免长期失真。"
            ))
        }

        // 8) 注释率：只在确实偏低时提，数字来自 commentLines / totalLines。
        if code.totalLines > 0, code.commentRatio < Self.lowCommentRatio {
            items.append(CodeRiskSuggestion(
                icon: "text.bubble",
                tint: Theme.neutral,
                text: "注释率 \(NumberFormat.percent(code.commentRatio))（\(NumberFormat.grouped(code.commentLines)) / \(NumberFormat.grouped(code.totalLines)) 行）低于本页 \(NumberFormat.percent(Self.lowCommentRatio, precision: 0)) 的提示线：优先给对外接口和圈复杂度最高的那批函数写意图说明，直白代码不必加注释。"
            ))
        }

        return items
    }

    private func longestBlockReference(_ code: CodeMetrics) -> DuplicatedBlock? {
        code.duplicatedBlocks.max(by: { $0.lineCount < $1.lineCount })
    }

    /// 建议文案里点名重复块出现的文件（最多 2 个，剩下的用处数说明）。
    private func occurrenceFileSummary(_ block: DuplicatedBlock) -> String {
        let names = Array(block.occurrences.prefix(2)).map { "\(CodeViewFormat.fileName($0.path)):\(NumberFormat.grouped($0.startLine))" }
        let rest = block.occurrences.count - names.count
        let joined = names.joined(separator: "、")
        return rest > 0 ? "\(joined) 等文件" : joined
    }

    // MARK: - Formatting & file actions

    private var projectRoot: String { report?.project.path ?? "" }

    /// 一个函数都没识别出来时不能显示 0（那是「极简」的意思），要如实显示未知。
    private func averageComplexityText(_ code: CodeMetrics) -> String {
        guard let average = code.averageCyclomaticComplexity else { return "未识别到函数" }
        return String(format: "%.2f", average) + " · " + NumberFormat.grouped(code.analyzedFunctionCount) + " 个函数"
    }

    /// 全仓均值与热点榜均值是两回事：仓库越大，上榜的越是极端值，热点均值必然偏高。
    /// 两者背离到一定程度就说明「平均分被少数巨型函数拉高」，建议按函数而不是按均值处理。
    private static let hotspotDivergenceFactor = 3.0

    private func relativeComplexitySuggestion(_ code: CodeMetrics) -> String? {
        guard let average = code.averageCyclomaticComplexity, average > 0 else { return nil }
        let hotspots = code.topComplexFunctions.map(\.cyclomaticComplexity)
        guard hotspots.count >= 5 else { return nil }
        let hotspotAverage = Double(hotspots.reduce(0, +)) / Double(hotspots.count)
        guard hotspotAverage >= average * Self.hotspotDivergenceFactor else { return nil }
        return "全仓 \(String(format: "%.2f", average))，但热点榜平均 \(String(format: "%.2f", hotspotAverage))："
            + "平均值被少数巨型函数拉高（超长函数 \(NumberFormat.grouped(code.longFunctions)) 个），"
            + "优先拆这几个而不是整体重构：\(hotspots.prefix(3).map(String.init).joined(separator: " / "))。"
    }

    private func highRiskFunctionCount(_ code: CodeMetrics) -> Int {
        code.topComplexFunctions.filter { $0.risk.rank >= RiskLevel.high.rank }.count
    }

    private func duplicationTint(_ ratio: Double) -> Color {
        if ratio >= Self.duplicationHighRatio { return Theme.danger }
        if ratio >= Self.duplicationNotableRatio { return Theme.caution }
        return Theme.healthy
    }

    /// 点击行：在 Finder 中显示源文件。
    private func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([CodeViewFormat.resolvedURL(path, root: projectRoot)])
    }

    /// 次要动作：用系统默认应用打开源文件。
    private func openFile(_ path: String) {
        NSWorkspace.shared.open(CodeViewFormat.resolvedURL(path, root: projectRoot))
    }
}

private struct CodeRiskSuggestion {
    var icon: String
    var tint: Color
    var text: String
}
