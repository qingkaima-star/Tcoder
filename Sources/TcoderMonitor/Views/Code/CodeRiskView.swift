import SwiftUI
import AppKit

/// OWNER: Workstream A.
struct CodeRiskView: View {
    var report: ProjectReport?

    private static let lineWidth: CGFloat = 40
    private static let lengthWidth: CGFloat = 44
    private static let complexityWidth: CGFloat = 34
    private static let parameterWidth: CGFloat = 34
    private static let badgeWidth: CGFloat = 78

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private var content: some View {
        if let code = report?.code {
            if code.totalFiles == 0 {
                EmptyStateView(
                    icon: "tray.full",
                    title: "没有可分析的文件",
                    message: "该目录未识别到可分析的源码文件。请选择包含源码的工程目录，或点击右上角「重新分析」。"
                )
            } else {
                riskOverviewCard(code)
                duplicationCard(code)
                complexityCard(code)
                suggestionCard(code)
            }
        } else {
            EmptyStateView(
                icon: "exclamationmark.triangle",
                title: "尚无风险数据",
                message: "该目录尚未扫描或无源码文件。点击右上角「重新分析」后，这里会显示真实的复杂度与重复率。"
            )
        }
    }

    // MARK: Overview

    private func riskOverviewCard(_ code: CodeMetrics) -> some View {
        SectionCard(
            "风险总览",
            subtitle: "最近扫描 \(DateFormat.sinceDescription(code.scannedAt)) · 耗时 \(code.durationMs) ms",
            icon: "exclamationmark.triangle",
            trailing: AnyView(RiskBadge(risk: code.overallRisk))
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("综合风险 \(code.overallRisk.rawValue)")
                        .font(Theme.metricNumber)
                        .foregroundStyle(Theme.color(for: code.overallRisk))
                    Spacer(minLength: 4)
                }
                Text("覆盖 \(NumberFormat.grouped(code.totalFiles)) 个文件 · \(NumberFormat.grouped(code.codeLines)) 行有效代码 · 主语言 \(code.primaryLanguage)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    StatLine(label: "高复杂度函数", value: NumberFormat.grouped(highRiskFunctionCount(code)))
                    StatLine(label: "超长函数", value: NumberFormat.grouped(code.longFunctions))
                    StatLine(label: "重复块", value: NumberFormat.grouped(code.duplicatedBlocks.count))
                    StatLine(label: "巨大文件", value: NumberFormat.grouped(code.hugeFiles.count))
                }
                .font(.caption)
            }
        }
    }

    // MARK: Duplication

    private func duplicationCard(_ code: CodeMetrics) -> some View {
        SectionCard(
            "重复代码",
            subtitle: "按 6 行归一化窗口在跨文件范围精确匹配",
            icon: "doc.on.doc"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(NumberFormat.percent(code.duplicationRatio))
                        .font(Theme.metricNumber)
                        .foregroundStyle(duplicationTint(code.duplicationRatio))
                    Text("代码行落在重复块内").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                }
                MiniBarGauge(
                    fraction: code.duplicationRatio,
                    tint: duplicationTint(code.duplicationRatio),
                    height: 6
                )

                if code.duplicatedBlocks.isEmpty {
                    Text("未发现跨文件重复代码。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 6) {
                        ForEach(code.duplicatedBlocks.prefix(12)) { block in
                            duplicationRow(block)
                        }
                    }
                }
            }
        }
    }

    private func duplicationRow(_ block: DuplicatedBlock) -> some View {
        Button {
            if let path = block.occurrences.first?.path {
                reveal(path)
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
                    Text("相似度 \(NumberFormat.percent(block.similarity, precision: 0))")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                Text(fragmentTitles(block))
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
    }

    // MARK: Complexity

    private func complexityCard(_ code: CodeMetrics) -> some View {
        SectionCard(
            "高复杂度函数 Top 20",
            subtitle: "圈复杂度阈值：11 中 · 21 高 · 31 严重",
            icon: "function"
        ) {
            if code.topComplexFunctions.isEmpty {
                Text("未发现圈复杂度达到 11 的函数。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 3) {
                    complexityHeader
                    ForEach(code.topComplexFunctions) { hotspot in
                        complexityRow(hotspot)
                    }
                    Text("点击任意一行在 Finder 中定位源文件。")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                }
            }
        }
    }

    @ViewBuilder
    private var complexityHeader: some View {
        HStack(spacing: 8) {
            Text("函数")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("行号").frame(width: Self.lineWidth, alignment: .trailing)
            Text("长度").frame(width: Self.lengthWidth, alignment: .trailing)
            Text("CC").frame(width: Self.complexityWidth, alignment: .trailing)
            Text("参数").frame(width: Self.parameterWidth, alignment: .trailing)
            Text("风险").frame(width: Self.badgeWidth, alignment: .trailing)
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 6)
        .padding(.bottom, 2)
        Divider().opacity(0.4)
    }

    private func complexityRow(_ hotspot: FunctionHotspot) -> some View {
        Button {
            reveal(hotspot.filePath)
        } label: {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(hotspot.name)
                        .font(Theme.monoSmall)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(relativePath(hotspot.filePath))
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
    }

    // MARK: Suggestions

    private func suggestionCard(_ code: CodeMetrics) -> some View {
        SectionCard("改进建议", subtitle: "仅由本次扫描的真实数字推导", icon: "lightbulb") {
            let items = suggestions(code)
            if items.isEmpty {
                Text("当前未发现结构性风险，保持现状。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(items, id: \.text) { item in
                        Label(item.text, systemImage: item.icon)
                            .font(.caption)
                            .foregroundStyle(item.tint)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func suggestions(_ code: CodeMetrics) -> [CodeRiskSuggestion] {
        var items: [CodeRiskSuggestion] = []

        if code.duplicationRatio >= 0.08, !code.duplicatedBlocks.isEmpty {
            let maxLines = code.duplicatedBlocks.map(\.lineCount).max() ?? 0
            items.append(CodeRiskSuggestion(
                icon: "scissors",
                tint: Theme.danger,
                text: "重复率 \(NumberFormat.percent(code.duplicationRatio))，\(NumberFormat.grouped(code.duplicatedBlocks.count)) 个跨文件重复块中最长一处 \(NumberFormat.grouped(maxLines)) 行：把列出的重复块抽成公共函数或协议扩展，只保留一份实现。"
            ))
        }

        let critical = code.topComplexFunctions.filter { $0.risk == .critical }
        if !critical.isEmpty {
            let named = critical.prefix(2).map { "\($0.name)（CC \(NumberFormat.grouped($0.cyclomaticComplexity)) · \(fileName($0.filePath))）" }
            items.append(CodeRiskSuggestion(
                icon: "exclamationmark.triangle.fill",
                tint: Theme.critical,
                text: "\(NumberFormat.grouped(critical.count)) 个函数圈复杂度已达严重档（≥ 31），最高的是 " + named.joined(separator: "、") + "。按「提前返回拆分支 / 抽策略表 / 拆分职责」的手法逐个拆解，先让单函数分支数降到 21 以下。"
            ))
        }

        let high = code.topComplexFunctions.filter { $0.risk == .high }
        if high.count >= 3 {
            items.append(CodeRiskSuggestion(
                icon: "arrow.triangle.branch",
                tint: Theme.caution,
                text: "另有 \(NumberFormat.grouped(high.count)) 个函数处于高复杂度档（CC 21~30），可配合新增单元测试逐步下沉分支。"
            ))
        }

        if code.longFunctions > 0 && code.averageFunctionLength > 25 {
            items.append(CodeRiskSuggestion(
                icon: "arrow.triangle.2.circlepath",
                tint: Theme.caution,
                text: "平均函数长度 \(NumberFormat.grouped(code.averageFunctionLength)) 行，同时有 \(NumberFormat.grouped(code.longFunctions)) 个超长函数：按段落把函数拆成职责单一的私有方法，让每个函数只做一件事。"
            ))
        }

        if let largest = code.hugeFiles.max(by: { $0.lineCount < $1.lineCount }) {
            items.append(CodeRiskSuggestion(
                icon: "doc.on.doc",
                tint: Theme.color(for: largest.risk),
                text: "最大文件 \(fileName(largest.path)) 有 \(NumberFormat.grouped(largest.lineCount)) 行：\(largest.suggestion)"
            ))
        }

        return items
    }

    // MARK: Helpers

    private func highRiskFunctionCount(_ code: CodeMetrics) -> Int {
        code.topComplexFunctions.filter { $0.risk == .high || $0.risk == .critical }.count
    }

    private func duplicationTint(_ ratio: Double) -> Color {
        if ratio >= 0.15 { return Theme.danger }
        if ratio >= 0.08 { return Theme.caution }
        return Theme.healthy
    }

    private func fileName(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    private func relativePath(_ path: String) -> String {
        let root = report?.project.path ?? ""
        if !root.isEmpty, path.hasPrefix(root) {
            var rest = String(path.dropFirst(root.count))
            if rest.hasPrefix("/") { rest.removeFirst() }
            if !rest.isEmpty { return rest }
        }
        return fileName(path)
    }

    private func fragmentTitles(_ block: DuplicatedBlock) -> String {
        let shown = block.occurrences.prefix(4).map { "\(fileName($0.path)):\(NumberFormat.grouped($0.startLine))" }
        let joined = shown.joined(separator: "  ·  ")
        return block.occurrences.count > shown.count ? "\(joined)  等 \(NumberFormat.grouped(block.occurrences.count)) 处" : joined
    }

    private func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

private struct CodeRiskSuggestion {
    var icon: String
    var tint: Color
    var text: String
}
