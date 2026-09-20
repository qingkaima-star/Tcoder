import Foundation

// OWNER: Workstream A (静态代码分析) —— ComplexitySanitizer
//
// 从 ComplexityEngine.swift 拆出，只为守住本工作流的红线（800 行以上的文件不得增加）：
// 语义、阈值、判定顺序一字未改。原先的 `private` 跨文件后必须放宽到模块内可见（internal），
// 除可见性外没有任何变化；ComplexityEngine 本身仍是唯一的入口。
//
// 复杂度前置清洗：剥掉注释与字符串字面量，同时产出花括号增量与「深度是否可信」标记。

extension ComplexityEngine {
    // MARK: Sanitizer (strings + comments stripped, brace deltas)

    struct SanitizedSource {
        var cleaned: [String]
        var opens: [Int]
        var closes: [Int]
        var prefix: [Int]
        var balancedBefore: [Bool]
    }

    struct LexState {
        var blockDepth = 0
        var stringDelim: [Character]?
        var stringIsTemplate = false
        var inTemplateExpression = false
        var templateBraceDepth = 0
    }

    static func sanitize(_ lines: [String], _ profile: LangProfile) -> SanitizedSource {
        var cleaned = [String]()
        cleaned.reserveCapacity(lines.count)
        var opens = [Int]()
        opens.reserveCapacity(lines.count)
        var closes = [Int]()
        closes.reserveCapacity(lines.count)
        var state = LexState()

        var prefix = [Int](repeating: 0, count: lines.count + 1)
        for (index, line) in lines.enumerated() {
            let out = sanitizeLine(line, profile, &state)
            cleaned.append(out.text)
            opens.append(out.opens)
            closes.append(out.closes)
            prefix[index + 1] = prefix[index] + out.opens - out.closes
        }

        // balancedBefore[i]：第 i 行之前累计花括号从未跌破 -3。跌破说明有字符串/注释被误判
        // 导致深度错位（heredoc、正则字面量里的 `}`），此后的函数边界不可信，直接放弃候选，
        // 免得 curlyEnd 在错位的深度上扫到文件尾。容忍 3 层是为了放过零星噪声。
        var balanced = [Bool](repeating: true, count: lines.count)
        var lowest = 0
        for index in 0..<lines.count {
            if prefix[index] < lowest { lowest = prefix[index] }
            balanced[index] = lowest > -3
        }
        return SanitizedSource(cleaned: cleaned, opens: opens, closes: closes, prefix: prefix, balancedBefore: balanced)
    }

    struct LineOutput {
        var text = ""
        var opens = 0
        var closes = 0
    }

    /// 一行清洗里「一个字符处理完」的两种结局，逐字对应原 `sanitizeLine` 的 `return out` / `continue`。
    enum SanitizeLineStep {
        /// 本行到此为止（进了行注释、或跨行构造到这行没闭合）——原实现在这里 `return out`。
        case lineDone
        /// index 已推进，回到 while 顶部重新看当前字符——原实现在这里 `continue`。
        case keepGoing
    }

    static func sanitizeLine(_ raw: String, _ profile: LangProfile, _ state: inout LexState) -> LineOutput {
        var out = LineOutput()
        guard !raw.isEmpty else { return out }
        let chars = Array(raw)
        var i = 0

        // 续行：仍在跨行字符串里
        if let delim = state.stringDelim, state.inTemplateExpression == false {
            if scanString(chars, &i, delim, state.stringIsTemplate, profile, &state, &out) == false {
                return out
            }
        }

        while i < chars.count {
            if advanceSanitizedLine(chars, &i, profile, &state, &out) == .lineDone { return out }
        }
        return out
    }

    /// 原先 79 行、CC 21 的那个 while 循环体，逐段搬到下面的小函数里；
    /// **判定顺序一个字没改**（块注释 → 新开块注释 → 行注释 → 跨行引号 → 单行引号 → 模板插值 → 普通字符），
    /// 每一段该 `continue` 的返回 `.keepGoing`，该 `return out` 的返回 `.lineDone`。
    static func advanceSanitizedLine(_ chars: [Character], _ i: inout Int, _ profile: LangProfile,
                                     _ state: inout LexState, _ out: inout LineOutput) -> SanitizeLineStep {
        if state.blockDepth > 0 {
            return scanBlockComment(chars, &i, profile, &state) ? .keepGoing : .lineDone
        }
        if let start = profile.blockStart, startsHere(chars, start, at: i) {
            state.blockDepth = 1
            i += start.count
            return scanBlockComment(chars, &i, profile, &state) ? .keepGoing : .lineDone
        }
        if matchesAnyPrefix(chars, at: i, profile.lineComments) != nil {
            return .lineDone
        }
        if let delim = matchMultiLineQuote(chars, at: i, profile) {
            return openMultiLineQuote(chars, &i, delim, profile, &state, &out)
        }
        if profile.quotes.contains(chars[i]), let close = closingQuote(chars, chars[i], from: i + 1) {
            i = close + 1
            return .keepGoing
        }
        // 本行没有闭合引号（Rust 生命周期、英文撇号）→ 当普通字符处理

        let c = chars[i]
        if state.inTemplateExpression,
           handleTemplateExpressionCharacter(c, chars, &i, &state, &out) {
            return .keepGoing
        }
        recordPlainCharacter(c, &i, &out)
        return .keepGoing
    }

    /// 进入 JS/TS/Vue 模板串或 Python docstring：置状态、吃掉定界符，再看这行内能不能闭合。
    static func openMultiLineQuote(_ chars: [Character], _ i: inout Int, _ delim: [Character],
                                   _ profile: LangProfile, _ state: inout LexState,
                                   _ out: inout LineOutput) -> SanitizeLineStep {
        state.stringDelim = delim
        state.stringIsTemplate = delim.first == "`" && profile.backtickInterpolates
        state.inTemplateExpression = false
        i += delim.count
        guard scanString(chars, &i, delim, state.stringIsTemplate, profile, &state, &out) else {
            return .lineDone
        }
        return .keepGoing
    }

    /// 反引号模板串 `${ … }` 内部的 `{` / `}` 要自己配平，配平完就退出表达式态。
    /// 返回 false 表示当前字符既不是 `{` 也不是 `}`，交给普通字符分支处理。
    static func handleTemplateExpressionCharacter(_ c: Character, _ chars: [Character], _ i: inout Int,
                                                  _ state: inout LexState,
                                                  _ out: inout LineOutput) -> Bool {
        if c == "{" {
            state.templateBraceDepth += 1
            out.text.append(c)
            out.opens += 1
            i += 1
            return true
        }
        guard c == "}" else { return false }
        if state.templateBraceDepth == 0 {
            state.inTemplateExpression = false
            i += 1
            return true
        }
        state.templateBraceDepth -= 1
        out.text.append(c)
        out.closes += 1
        i += 1
        return true
    }

    /// 留在 cleaned 里的普通字符：只有真正的花括号才计进深度增量。
    static func recordPlainCharacter(_ c: Character, _ i: inout Int, _ out: inout LineOutput) {
        if c == "{" {
            out.opens += 1
        } else if c == "}" {
            out.closes += 1
        }
        out.text.append(c)
        i += 1
    }

    /// 返回 false 表示该行结束时仍在字符串内。
    static func scanString(
        _ chars: [Character], _ i: inout Int, _ delim: [Character], _ isTemplate: Bool,
        _ profile: LangProfile, _ state: inout LexState, _ out: inout LineOutput
    ) -> Bool {
        let n = chars.count
        // Go 的反引号原始字符串里反斜杠不是转义符（`\` 就是两个字符），
        // 这里若照 JS 的方式跳两步，会把收尾的反引号一起吃掉，从此整文件被当成在字符串里。
        let honorsEscapes = delim.first != "`" || profile.backtickInterpolates
        while i < n {
            if isTemplate, chars[i] == "$", i + 1 < n, chars[i + 1] == "{" {
                state.inTemplateExpression = true
                state.templateBraceDepth = 0
                i += 2
                return true
            }
            if honorsEscapes, chars[i] == "\\" {
                i += 2
                continue
            }
            if startsHere(chars, delim, at: i) {
                state.stringDelim = nil
                state.stringIsTemplate = false
                i += delim.count
                return true
            }
            i += 1
        }
        return false
    }

    /// 返回 false 表示该行结束时块注释仍未闭合。
    static func scanBlockComment(
        _ chars: [Character], _ i: inout Int, _ profile: LangProfile, _ state: inout LexState
    ) -> Bool {
        guard let start = profile.blockStart, let end = profile.blockEnd else {
            state.blockDepth = 0
            return true
        }
        let n = chars.count
        while i < n {
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
