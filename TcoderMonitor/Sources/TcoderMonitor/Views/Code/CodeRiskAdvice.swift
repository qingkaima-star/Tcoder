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

    /// 建议行的左线只回答一个问题：**这条要不要现在动手**。
    ///
    /// `Theme.Semantic.role(for:)` 是**状态**口径，里面 `.low → success`（绿）。
    /// 而绿在这套语言里的意思是"查过了、没问题"——把它贴在一条"按领域或路由拆成多个文件"
    /// 的动手建议上，同一屏就一边写着"改一下"一边涂成"不用管"，且与同列里
    /// 低档重复率那行的灰**自相矛盾**（乱清单 §4，复杂度风险页尾人眼复核抓到）。
    /// 所以只有低档被改走 `neutral`；中/高/严重三档仍取状态口径——
    /// **急不急是真分档，不是把它抹平。**
    static func adviceRole(for risk: RiskLevel) -> Theme.SemanticRole {
        switch risk {
        case .none, .low: return Theme.Semantic.neutral
        default: return Theme.Semantic.role(for: risk)
        }
    }

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
                // 「榜内 %4$@ 个」是刻意写出来的限定词：这一串是**封顶榜的条数**，
                // 不是"这个仓库有这么多重复块"（RD-17）。
                text: localizedFormat("重复率 %1$@（约 %2$@ / %3$@ 行）仍在低档：榜内 %4$@ 个重复块中最长 %5$@ 行，暂不需要专门重构，改到相关代码时顺带去重即可。",
                                      NumberFormat.percent(code.duplicationRatio, precision: 1),
                                      NumberFormat.grouped(duplicatedLines),
                                      NumberFormat.grouped(code.codeLines),
                                      NumberFormat.grouped(CodeBoardTruth.duplicationBoardCount(code)),
                                      NumberFormat.grouped(longestBlock))
            ))
        }

        return items
    }

    static func complexityAdvice(_ code: CodeMetrics) -> [Item] {
        criticalComplexityItem(code) + highComplexityItem(code) + manyParameterItem(code)
    }

    /// 2) 圈复杂度严重档：CC 数字与函数名逐条点名。
    ///
    /// 整句走 `localizedFormat`（批次 P69a）：这一句原本是四段字面量 `+` 起来的，
    /// 拼完那一串（里面嵌着测得值）不是任何语言目录里的键 ⇒ 英文态整行铺中文。
    /// 现在键 = 中文整句，中文侧逐字回填、屏上一个字都没变。
    /// ⚠ 句首那个「N 个函数」在英语里有单复数，而一句里另有三个槽 ⇒
    /// `localizedCount`（只收一个 `Int`）装不下 —— 缺口按契约上报，见交回汇报。
    private static func criticalComplexityItem(_ code: CodeMetrics) -> [Item] {
        let critical = code.topComplexFunctions.filter { $0.risk == .critical }
        guard !critical.isEmpty else { return [] }
        let named = critical.prefix(3).map {
            localizedFormat("%1$@（CC %2$@ · %3$@ 行 · %4$@:%5$@）",
                            $0.name,
                            NumberFormat.grouped($0.cyclomaticComplexity),
                            NumberFormat.grouped($0.lineCount),
                            CodeViewFormat.fileName($0.filePath),
                            NumberFormat.grouped($0.startLine))
        }
        let highest = critical.map(\.cyclomaticComplexity).max() ?? 0
        return [Item(
            id: "complexity-critical", label: "严重复杂度", icon: .riskSevere, role: Theme.Semantic.critical,
            text: localizedFormat("%1$@ 个函数被判为严重复杂度，最高圈复杂度 %2$@：%3$@。先去掉嵌套：校验与异常分支改成提前返回，再把成组的分支换成策略表/多态；先把分支数压到 CC %4$@ 以下（那是本工具判「高」的那条线，与榜位无关）。",
                                  NumberFormat.grouped(critical.count),
                                  NumberFormat.grouped(highest),
                                  // 「、」是中文顿号，英文态该是「, 」—— 分隔符随语言这件事
                                  // 现有三个查表出口都表达不了，同样记进契约缺口。
                                  named.joined(separator: "、"),
                                  // 「压到上榜函数的最低水位以下」是一枚**从榜里长出来的目标**：榜只留前 20 条，
                                  // 第 20 名在大仓库上可能是 CC 40 —— 照它做既出不了榜也没修掉任何东西。
                                  // 换成引擎判档的那条线（冻结常量，本处**只读不改**）：低于它就是离开高档。
                                  NumberFormat.grouped(FileSystemCodeAnalyzer.highFunctionComplexity))
        )]
    }

    /// 3) 高档复杂度聚集。
    private static func highComplexityItem(_ code: CodeMetrics) -> [Item] {
        let high = code.topComplexFunctions.filter { $0.risk == .high }
        guard high.count >= 3 else { return [] }
        return [Item(
            id: "complexity-high-cluster", label: "高复杂度聚集", icon: .complexity, role: Theme.Semantic.warning,
            text: localizedFormat("同时有 %1$@ 个函数处于高复杂度档（CC %2$@~%3$@）：先给它们补单元测试，再把分支下沉成命名清晰的小函数。",
                                  NumberFormat.grouped(high.count),
                                  NumberFormat.grouped(high.map(\.cyclomaticComplexity).min() ?? 0),
                                  NumberFormat.grouped(high.map(\.cyclomaticComplexity).max() ?? 0))
        )]
    }

    /// 4) 参数过多的函数（真实计数）。
    private static func manyParameterItem(_ code: CodeMetrics) -> [Item] {
        let manyParams = code.topComplexFunctions.filter { $0.parameterCount >= manyParameterCount }
        guard let worst = manyParams.max(by: { $0.parameterCount < $1.parameterCount }) else { return [] }
        return [Item(
            id: "parameters", label: "参数过多", symbol: CodeGitSymbol.parameters,
            role: Theme.Semantic.warning,
            text: localizedFormat("%1$@ 个上榜函数的参数达到或超过 %2$@ 个，最多的是%3$@（%4$@ 个参数 · %5$@:%6$@）：把成组参数收进一个配置或值类型，调用点会同步变短。",
                                  NumberFormat.grouped(manyParams.count),
                                  NumberFormat.grouped(manyParameterCount),
                                  worst.name,
                                  NumberFormat.grouped(worst.parameterCount),
                                  CodeViewFormat.fileName(worst.filePath),
                                  NumberFormat.grouped(worst.startLine))
        )]
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
                role: Self.adviceRole(for: largest.risk),
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
        //    整句键（P69a）：四个槽先各自格式化成字符串再填，中文侧回填后与旧拼接逐字相同。
        //    ⚠ 值里的百分号是**实参**带进来的（`NumberFormat.percent` 产出 "16.3%"），
        //    键与译文里都不写裸 `%`，所以 `String(format:)` 没有可吃尾巴的地方。
        if code.totalLines > 0, code.commentRatio < lowCommentRatio {
            items.append(Item(
                id: "comments", label: "注释率", symbol: CodeGitSymbol.comments, role: Theme.Semantic.neutral,
                text: localizedFormat("注释率 %1$@（%2$@ / %3$@ 行）低于本页 %4$@ 的提示线：优先给对外接口和圈复杂度最高的那批函数写意图说明，直白代码不必加注释。",
                                      NumberFormat.percent(code.commentRatio),
                                      NumberFormat.grouped(code.commentLines),
                                      NumberFormat.grouped(code.totalLines),
                                      NumberFormat.percent(lowCommentRatio, precision: 0))
            ))
        }

        return items
    }
}
