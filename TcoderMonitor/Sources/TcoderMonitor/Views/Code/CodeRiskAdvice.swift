import SwiftUI

// MARK: - 风险建议卡片（WS-X0 自 CodeRiskRows.swift 机械搬出，文案一字未改）
//
// 搬的理由是机械的：`CodeRiskRows.suggestions` 原本一个函数 138 行，被本 App 自扫
// 同时点名 CC 17 与「超长函数 >50 行」。九类建议共用一份 items，按类拆成三组各攒各的；
// 拆完 CodeRiskRows.swift 自己又越过 400 行的「巨大文件」线，所以整组搬到这份文件。
// 阈值常量（duplicationHighRatio 等）仍留在 CodeRiskRows 里，数值与语义一字未动，
// 只把访问级别从 private 放宽到模块内可见（含这三个构建器）——本仓已有同样先例：
// ComplexityCounting.swift 顶部记过这条。

extension CodeRiskAnalysis {

    /// 「这一维该怎么改」的建议卡片。原本是一个 138 行的函数（被本 App 自扫同时点名
    /// CC 17 与「超长函数 >50 行」），九类建议共用一份 items；按类分成三组，各攒各的卡片。

    static func duplicationAdvice(_ code: CodeMetrics) -> [Item] {
        var items: [Item] = []
        // 1) 重复代码：分档措辞，数字取自 ratio / blocks。
        let duplicatedLines = Int((code.duplicationRatio * Double(code.codeLines)).rounded())
        let longestBlock = code.duplicatedBlocks.map(\.lineCount).max() ?? 0
        if code.duplicationRatio >= duplicationHighRatio, let block = longestBlockReference(code) {
            items.append(Item(
                id: "duplication-high", label: "重复代码", icon: .duplicate, role: Theme.Semantic.danger,
                text: localizedFormat("重复率 %1$@（约 %2$@ / %3$@ 行）已达高风险档：最长一处 %4$@ 行，出现在 %5$@（共 %6$@ 处）。把这类块抽成公共工具函数或模板方法，差异部分用参数/闭包传入，只保留一份实现。",
                                      NumberFormat.percent(code.duplicationRatio, precision: 1),
                                      NumberFormat.grouped(duplicatedLines),
                                      NumberFormat.grouped(code.codeLines),
                                      NumberFormat.grouped(block.lineCount),
                                      occurrenceFileSummary(block),
                                      NumberFormat.grouped(block.occurrences.count))
            ))
        } else if code.duplicationRatio >= duplicationNotableRatio, let block = longestBlockReference(code) {
            items.append(Item(
                id: "duplication-notable", label: "重复代码", icon: .duplicate, role: Theme.Semantic.warning,
                text: localizedFormat("重复率 %1$@（约 %2$@ / %3$@ 行）：最长重复块 %4$@ 行、出现在 %5$@。改动这些文件时顺手合并成一处实现，可把重复率压到 %6$@ 以下。",
                                      NumberFormat.percent(code.duplicationRatio, precision: 1),
                                      NumberFormat.grouped(duplicatedLines),
                                      NumberFormat.grouped(code.codeLines),
                                      NumberFormat.grouped(block.lineCount),
                                      occurrenceFileSummary(block),
                                      NumberFormat.percent(duplicationNotableRatio, precision: 0))
            ))
        } else if code.duplicationRatio > 0 {
            items.append(Item(
                id: "duplication-low", label: "重复代码", icon: .duplicate, role: Theme.Semantic.neutral,
                text: localizedFormat("重复率 %1$@（约 %2$@ / %3$@ 行）仍在低档：%4$@ 个重复块中最长 %5$@ 行，暂不需要专门重构，改到相关代码时顺带去重即可。",
                                      NumberFormat.percent(code.duplicationRatio, precision: 1),
                                      NumberFormat.grouped(duplicatedLines),
                                      NumberFormat.grouped(code.codeLines),
                                      NumberFormat.grouped(code.duplicatedBlocks.count),
                                      NumberFormat.grouped(longestBlock))
            ))
        }

        return items
    }

    static func complexityAdvice(_ code: CodeMetrics) -> [Item] {
        var items: [Item] = []
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
                    + "\(NumberFormat.grouped(manyParameterCount)) 个，最多的是\(worst.name)"
                    + "（\(NumberFormat.grouped(worst.parameterCount)) 个参数 · "
                    + "\(CodeViewFormat.fileName(worst.filePath)):\(NumberFormat.grouped(worst.startLine))）："
                    + "把成组参数收进一个配置或值类型，调用点会同步变短。"
            ))
        }

        return items
    }

    static func scaleAdvice(_ code: CodeMetrics) -> [Item] {
        markerAdvice(code) + proseAdvice(code)
    }

    private static func markerAdvice(_ code: CodeMetrics) -> [Item] {
        var items: [Item] = []
        // 5) 函数整体长度。
        if code.longFunctions > 0 {
            items.append(Item(
                id: "long-functions", label: "函数长度", symbol: CodeGitSymbol.longFunction,
                role: code.averageFunctionLength > longAverageFunctionLines
                    ? Theme.Semantic.warning : Theme.Semantic.neutral,
                text: localizedFormat("识别到 %1$@ 个超长函数，平均函数长度 %2$@ 行：按段落把函数拆成职责单一的私有方法，一个函数只做一件事。",
                                      NumberFormat.grouped(code.longFunctions),
                                      NumberFormat.grouped(code.averageFunctionLength))
            ))
        }

        // 6) 全仓均值与热点榜均值背离——平均值被少数巨型函数拉高时，建议按函数处理而不是整体重构。
        if let divergence = relativeComplexitySuggestion(code) {
            items.append(Item(id: "complexity-divergence", label: "复杂度分布", icon: .chartLine,
                              role: Theme.Semantic.neutral, text: divergence))
        }

        return items
    }

    private static func proseAdvice(_ code: CodeMetrics) -> [Item] {
        var items: [Item] = []
        // 7) 巨大文件：给出真实行数与扫描器自己的建议原文。
        if let largest = code.hugeFiles.max(by: { $0.lineCount < $1.lineCount }) {
            items.append(Item(
                id: "huge-file", label: "巨大文件", icon: .duplicate,
                role: Theme.Semantic.role(for: largest.risk),
                text: localizedFormat("最大文件 %1$@ 共 %2$@ 行（项目行数峰值 %3$@ 行）：%4$@",
                                      CodeViewFormat.fileName(largest.path),
                                      NumberFormat.grouped(largest.lineCount),
                                      NumberFormat.grouped(code.largestFileLineCount),
                                      localizedCopy(largest.suggestion))
            ))
        }

        // 8) FIXME / TODO：按真实条数提示。
        if code.fixmeCount > 0 {
            let perKilo = Double(code.fixmeCount + code.todoCount) * 1_000 / Double(max(1, code.codeLines))
            items.append(Item(
                id: "markers", label: "待办标记", symbol: CodeGitSymbol.marker, role: Theme.Semantic.warning,
                text: localizedFormat("源码里留着 %1$@ 处 FIXME（另有 %2$@ 处 TODO），平均每千行有效代码 %3$@ 条：逐条确认是修掉还是删注释，避免长期失真。",
                                      NumberFormat.grouped(code.fixmeCount),
                                      NumberFormat.grouped(code.todoCount),
                                      String(format: "%.2f", perKilo))
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
        return items
    }
}
