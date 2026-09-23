import Foundation

// OWNER: Workstream A (静态代码分析) —— ComplexitySanitizer
//
// 从 ComplexityEngine.swift 拆出，只为守住本工作流的红线（800 行以上的文件不得增加）。
//
// 复杂度前置清洗：剥掉注释与字符串字面量，同时产出花括号增量与「深度是否可信」标记。
//
// **R2 改动留痕（RD-06 / RD-07）**：原先这一层的词法状态是 `LexState` 里四个平铺字段
// （`stringDelim` / `stringIsTemplate` / `inTemplateExpression` / `templateBraceDepth`），
// 配套静态函数 `sanitizeLine(_:profile:state:)` / `advanceSanitizedLine` / `openMultiLineQuote` /
// `handleTemplateExpressionCharacter` / `recordPlainCharacter` / `scanString`。
// 现在字符级判定整体搬到 `ComplexityLexMachine.swift` 的**帧栈**（`ComplexityEngine.LexState.line(_:_:)`），
// 本文件只留「按行驱动 + 逐行语言档案 + 前缀和 + 完整性结算」。
// `scanBlockComment` / `matchMultiLineQuote` / `closingQuote` / `matchesAnyPrefix` / `startsHere`
// 五条小工具留在下面，帧栈要用；除可见性外判定一字未改。

extension ComplexityEngine {
    // MARK: Sanitizer (strings + comments stripped, brace deltas)

    struct SanitizedSource {
        var cleaned: [String]
        var opens: [Int]
        var closes: [Int]
        var prefix: [Int]
        var balancedBefore: [Bool]
        /// 配不平的读数。**以前没有这一格**：深度跌破容忍线只有 `balancedBefore` 一道静默闸门，
        /// 被放弃的候选与被吞掉的行一个都不报，于是「没识别出来」在界面上长成「这仓库没函数」。
        var integrity: LexIntegrity
    }

    /// 一份源码清洗完之后的**词法完整性**读数。非空 = 这份数字是在「边界不可信」的范围里量出来的，
    /// 界面与 CLI 必须把它当部分测量说，不许当全量。
    struct LexIntegrity: Sendable, Equatable {
        /// 文件读完仍在串 / 模板串里的定界符个数（未闭合）
        var endsInsideString = 0
        /// 文件读完仍在 `${ … }` 插值表达式里（表达式帧未弹出）
        var endsInsideExpression = 0
        /// 文件读完块注释仍未闭合
        var endsInsideBlockComment = false
        /// 插值表达式 `${ … }` 里还剩未配平的 `{` 或 `(`
        var unbalancedExpressions = 0
        /// 插值表达式里出现多余闭括号（配平跌破 0）
        var expressionUnderflow = 0
        /// 像正则起点但本行内找不到收尾 `/`（按普通字符处理、不吞行；留名是因为它确实判不准）
        var regexLikeUnterminated = 0
        /// 全文件最低的花括号前缀深度（跌破 -3 之后函数边界不可信）
        var lowestBracePrefix = 0
        /// 有多少行处在「深度已不可信」的区间里（`balancedBefore` 为 false 的行数）
        var untrustedDepthLineCount = 0
        /// 定界符 / 注释**成对**出现在别的语言区域里（Vue 的 template / style），
        /// 按分区归位后不进入代码统计的行数。0 = 该文件没有需要分区的区域。
        ///
        /// RD-42（本条原本是"有写无读"）：这一格是**口径**不是"没量准" ⇒ 刻意**不进**
        /// `limitations` / `hasAnomaly`（那两条走 `scanLimitations`，在 CLI 被打成「未量准 N 条」）。
        /// 唯一出口是 `FileSystemCodeAnalyzer.analyzeWithCoverage` 把它**直传**进
        /// `CodeMetrics.nonCodeRegionLineCount`，再由 `MixedLanguageRegionCaliber.note(_:)`
        /// 装配成一句中文给界面与 CLI；这里再算第二遍就是第二把尺子。
        var nonCodeRegionLineCount = 0
        /// 混合语言文件的分区没认出来，退回旧的粗判掩码（未知态，必须说出来）
        var regionFallback = false

        /// 有没有需要向用户出声的东西。
        var hasAnomaly: Bool {
            endsInsideString > 0 || endsInsideExpression > 0 || endsInsideBlockComment
                || unbalancedExpressions > 0 || expressionUnderflow > 0
                || lowestBracePrefix < -3 || untrustedDepthLineCount > 0 || regionFallback
        }

        /// 一行一条中文说明（带真实数字），交给 `CodeScanCoverage.limitationSummary` 落盘。
        var limitations: [String] {
            var lines: [String] = []
            if endsInsideString > 0 {
                lines.append("\(endsInsideString) 处字符串 / 模板串到文件末尾仍未闭合，"
                    + "其后的代码没有进入函数识别与复杂度统计 —— 这一份是**部分测量**。")
            }
            if endsInsideExpression > 0 {
                lines.append("\(endsInsideExpression) 处模板插值 `${…}` 到文件末尾仍未闭合。")
            }
            if endsInsideBlockComment {
                lines.append("块注释到文件末尾仍未闭合，其后的代码没有进入统计。")
            }
            if unbalancedExpressions > 0 || expressionUnderflow > 0 {
                lines.append("\(unbalancedExpressions + expressionUnderflow) 处模板插值 `${…}` 的 "
                    + "`{}` / `()` 配不平，这些行上的函数边界不可信。")
            }
            if untrustedDepthLineCount > 0 {
                lines.append("\(untrustedDepthLineCount) 行处在花括号深度跌破 -3 的区间"
                    + "（最低 \(lowestBracePrefix) 层）：这些行上的签名一律放弃，不做边界推断。")
            }
            if regexLikeUnterminated > 0 {
                lines.append("\(regexLikeUnterminated) 处形似正则字面量的 `/` 在本行内找不到收尾，"
                    + "已按普通字符处理（不吞行，但该行的字符串边界判不准）。")
            }
            return lines
        }

        /// 区域之间的台账要合并：`<script>` 里没闭合的模板串不许因为切到 `<style>` 就悄悄归零。
        static func merged(_ first: LexIntegrity, _ second: LexIntegrity) -> LexIntegrity {
            var out = first
            out.endsInsideString += second.endsInsideString
            out.endsInsideExpression += second.endsInsideExpression
            out.endsInsideBlockComment = out.endsInsideBlockComment || second.endsInsideBlockComment
            out.unbalancedExpressions += second.unbalancedExpressions
            out.expressionUnderflow += second.expressionUnderflow
            out.regexLikeUnterminated += second.regexLikeUnterminated
            out.lowestBracePrefix = min(out.lowestBracePrefix, second.lowestBracePrefix)
            out.untrustedDepthLineCount += second.untrustedDepthLineCount
            out.nonCodeRegionLineCount += second.nonCodeRegionLineCount
            out.regionFallback = out.regionFallback || second.regionFallback
            return out
        }
    }

    /// 既有条目用的单档案入口。**语义与 HEAD 一致**：整份文件按同一种语言清洗。
    static func sanitize(_ lines: [String], _ profile: LangProfile) -> SanitizedSource {
        sanitize(lines, profiles: Array(repeating: profile, count: lines.count))
    }

    /// 逐行给档案：`profiles[index] == nil` 表示该行**不属于任何代码区域**
    /// （Vue 的 `<template>` / `<style>` 正文），清洗成空行、不产出花括号增量、
    /// 也不把定界符状态带过去 —— RD-07 要的「按分区归位」，函数识别这一条走这里。
    static func sanitize(_ lines: [String], profiles: [LangProfile?]) -> SanitizedSource {
        var cleaned = [String]()
        var opens = [Int]()
        var closes = [Int]()
        cleaned.reserveCapacity(lines.count)
        opens.reserveCapacity(lines.count)
        closes.reserveCapacity(lines.count)

        var state = LexState()
        var ledger = LexIntegrity()
        var nonCodeLines = 0
        var lastProfile: LangProfile?

        for index in 0..<lines.count {
            let profile = index < profiles.count ? profiles[index] : nil
            guard let profile else {
                // 非代码区域：整行进「已知不统计」账，不留任何词法状态
                nonCodeLines += 1
                ledger = LexIntegrity.merged(ledger, state.seal())
                state = LexState()
                lastProfile = nil
                cleaned.append("")
                opens.append(0)
                closes.append(0)
                continue
            }
            if let last = lastProfile, last.languageKey != profile.languageKey {
                // 跨语言区域（Vue 的 script(lang=ts) ↔ template ↔ style）：
                // 上一层区域里未闭合的定界符必须结算并归零，不许继续吃下一区域的代码
                ledger = LexIntegrity.merged(ledger, state.seal())
                state = LexState()
            }
            lastProfile = profile
            let out = state.line(lines[index], profile)
            cleaned.append(out.text)
            opens.append(out.opens)
            closes.append(out.closes)
        }
        ledger = LexIntegrity.merged(ledger, state.seal())
        ledger.nonCodeRegionLineCount = nonCodeLines
        return finishSanitizedSource(cleaned: cleaned, opens: opens, closes: closes, integrity: ledger)
    }

    /// 前缀和与「深度是否可信」。
    ///
    /// `balancedBefore[i]`：第 i 行之前累计花括号从未跌破 -3。跌破说明有字符串 / 注释被误判
    /// 导致深度错位（heredoc、正则字面量里的 `}`），此后的函数边界不可信，直接放弃候选，
    /// 免得 `curlyEnd` 在错位的深度上扫到文件尾。容忍 3 层是为了放过零星噪声。
    /// R2 补的是那半句：**放弃了必须留名**（`untrustedDepthLineCount`），不许静默丢行继续算。
    static func finishSanitizedSource(cleaned: [String], opens: [Int], closes: [Int],
                                      integrity: LexIntegrity) -> SanitizedSource {
        var prefix = [Int](repeating: 0, count: cleaned.count + 1)
        for index in 0..<cleaned.count {
            prefix[index + 1] = prefix[index] + opens[index] - closes[index]
        }
        var balanced = [Bool](repeating: true, count: cleaned.count)
        var lowest = 0
        var untrusted = 0
        for index in 0..<cleaned.count {
            if prefix[index] < lowest { lowest = prefix[index] }
            balanced[index] = lowest > -3
            if !balanced[index] { untrusted += 1 }
        }
        var settled = integrity
        settled.lowestBracePrefix = lowest
        settled.untrustedDepthLineCount += untrusted
        return SanitizedSource(cleaned: cleaned, opens: opens, closes: closes, prefix: prefix,
                               balancedBefore: balanced, integrity: settled)
    }

    // MARK: 帧栈要用的五条小工具（搬自 HEAD，判定一字未改）

    /// 返回 false 表示该行结束时块注释仍未闭合。嵌套块注释（Swift）按 `blockDepth` 配平。
    static func scanBlockComment(
        _ chars: [Character], _ i: inout Int, _ profile: LangProfile, _ state: inout LexState
    ) -> Bool {
        guard let start = profile.blockStart, let end = profile.blockEnd else {
            state.blockDepth = 0
            return true
        }
        let count = chars.count
        while i < count {
            if profile.nestedBlockComments, startsHere(chars, start, at: i) {
                state.blockDepth += 1
                i += start.count
                continue
            }
            if startsHere(chars, end, at: i) {
                state.blockDepth -= 1
                i += end.count
                if state.blockDepth == 0 { return true }
                continue
            }
            i += 1
        }
        return false
    }

    static func matchMultiLineQuote(_ chars: [Character], at i: Int, _ profile: LangProfile) -> [Character]? {
        for delim in profile.multiLineQuotes where startsHere(chars, delim, at: i) {
            return delim
        }
        return nil
    }

    /// 单行引号串里的闭合位置（`\` 转义跳两格）。
    static func closingQuote(_ chars: [Character], _ quote: Character, from: Int) -> Int? {
        var i = from
        while i < chars.count {
            if chars[i] == "\\" { i += 2; continue }
            if chars[i] == quote { return i }
            i += 1
        }
        return nil
    }

    static func matchesAnyPrefix(_ chars: [Character], at i: Int, _ prefixes: [[Character]]) -> [Character]? {
        for prefix in prefixes where startsHere(chars, prefix, at: i) {
            return prefix
        }
        return nil
    }

    static func startsHere(_ chars: [Character], _ needle: [Character], at i: Int) -> Bool {
        guard !needle.isEmpty, i + needle.count <= chars.count else { return false }
        for offset in 0..<needle.count where chars[i + offset] != needle[offset] {
            return false
        }
        return true
    }
}
