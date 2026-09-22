import Foundation

// OWNER: R2 (Vue / TS 识别与模板字符串) —— 词法帧栈状态机与「配不平要出声」的字符级判定。
//
// 为什么单起一个文件：本仓 `Sources/**` 400 行闸门（`SourcesSizeAuditTests`，超限名额 0），
// 而这块判定比 `ComplexitySanitizer.swift` 里原来的四个平铺字段大一号。
//
// 与 HEAD 4dc417b 的 `LexState`（`stringDelim` / `stringIsTemplate` / `inTemplateExpression` /
// `templateBraceDepth` 四个平铺字段）相比，实质改动就三条，正好是 RD-06 的根因：
//
// 1. **串与插值改成栈**。`${ … }` 闭合之后回到**外层模板串**继续找收尾反引号，
//    而不是回到代码态。旧实现回到代码态之后，收尾反引号被 `openMultiLineQuote` 当成
//    **新开一个串**，于是那一行行尾 `stringDelim` 挂着不放，其后每一行的清洗结果都是空串
//    —— 这就是「模板字符串结束反引号被重新当成开始反引号，后续代码被整段吞掉」，
//    也是 RD-05「Vue/TS 大量函数声明未被识别」的真实机制
//    （实测：一行以反引号收尾的模板串，能让其后所有函数的识别条数掉到 0）。
// 2. **嵌套一层以上要能配平**：插值里再开模板串、插值里放对象字面量 `{…}`，
//    都要按各自的花括号 / 圆括号计数弹回正确的层（旧实现只有一层 `stringDelim`，
//    第二层反引号会直接覆盖掉外层）。
// 3. **配不平必须出声**：文件末尾仍在串里 / 块注释里 / 插值里、花括号深度跌破容忍线，
//    全部记进 `LexIntegrity`（`ComplexitySanitizer.swift`）交给调用方。
//    旧实现只有 `balancedBefore` 一道**静默**闸门。
//
// 另补 RD-06 夹具 4 的形状：JS/TS/Vue 的**正则字面量**里可以合法地出现反引号与 `${`，
// 旧状态机没有这一档，直接把反引号当模板串开头。判定保守到「本行内闭合才算正则」，
// 认不准就退回普通字符一格一格走 —— 宁可判漏，不许吞行。

extension ComplexityEngine {

    /// 一次函数识别的完整产物：候选清单 **+ 这份数字是在什么可信范围内量出来的**。
    ///
    /// 为什么不能只交候选清单（R2 / RD-06）：词法状态配不平的时候，`balancedBefore` 会放弃候选、
    /// 未闭合的串会把后面整段吃掉 —— 这两种情况在界面上都长成「这个文件没有函数」。
    /// HEAD 只有前者那道**静默**闸门，后者连计数都没有。这里把读数带出来给聚合方落盘。
    struct FunctionScanOutcome: Sendable {
        var candidates: [FunctionCandidate] = []
        var integrity: LexIntegrity = LexIntegrity()
        /// 命中了签名、但边界推不出来（花括号配不平 / 未闭合）而放弃的候选数
        var unboundedSignatureCount: Int = 0
        /// 参与代码统计的行数（Vue 分区之后 = 脚本区行数；非 Vue = 全文件行数）
        var codeRegionLineCount: Int = 0
        /// SFC 分区识别失败、退回旧的 `<script` 粗判掩码（RD-07 的未知态）
        var vueRegionFallback: Bool = false
        /// 嵌套超过 `maxNestedFunctionScanDepth` 而没继续下钻的函数体数（RD-08 的边界）
        var nestedDepthTruncatedCount: Int = 0

        /// 单文件口径的限制说明（聚合口径见 `CodeScanCoverage.limitationSummary`）。
        var limitations: [String] {
            var lines = integrity.limitations
            if unboundedSignatureCount > 0 {
                lines.append("\(unboundedSignatureCount) 处函数签名命中后边界推不出来"
                    + "（花括号配不平或未闭合），这些函数没有进入统计。")
            }
            if vueRegionFallback {
                lines.append("有 .vue 文件没被识别出任何顶格 SFC 区块（`<script` 不顶格？），"
                    + "函数识别退回旧的 `<script` 粗判掩码 —— 该文件的模板区可能混进了代码统计。")
            }
            if nestedDepthTruncatedCount > 0 {
                lines.append("\(nestedDepthTruncatedCount) 处函数体的嵌套深度超过 "
                    + "\(ComplexityEngine.maxNestedFunctionScanDepth) 层，更里层的具名函数不再单列，"
                    + "其判定并入直接外层（口径：外层那条的 CC 因此是**含嵌套累计**）。")
            }
            return lines
        }
    }

    /// 一次扫描里所有文件的词法读数之和。
    ///
    /// 为什么要「相加 + 文件数」两把账：只报第一处异常会把其余文件藏起来，
    /// 而只报总处数又看不出它集中在一个文件还是散在一千个文件上。
    struct LexAggregate: Sendable {
        var integrity = LexIntegrity()
        var anomalousFileCount = 0
        var unboundedSignatureCount = 0
        var vueRegionFallbackFileCount = 0

        static func accumulate(_ outcomes: [FunctionScanOutcome]) -> LexAggregate {
            var sum = LexAggregate()
            for outcome in outcomes {
                sum.integrity = LexIntegrity.merged(sum.integrity, outcome.integrity)
                if outcome.integrity.hasAnomaly { sum.anomalousFileCount += 1 }
                sum.unboundedSignatureCount += outcome.unboundedSignatureCount
                if outcome.vueRegionFallback { sum.vueRegionFallbackFileCount += 1 }
            }
            return sum
        }
    }

    /// 一行清洗的产物：留在 cleaned 里的代码文本 + 本行花括号增量。
    struct LineOutput {
        var text = ""
        var opens = 0
        var closes = 0
    }

    /// 一个字符处理完的两种结局：本行到此为止（进行注释、或跨行构造到这行没闭合）/ 继续看下一格。
    enum LexStep {
        case lineDone
        case keepGoing
    }

    /// 帧栈上的一层。`quoted` 是「在字符串里面」（串文字不进代码统计），
    /// `expression` 是「在模板插值 `${ … }` 里面」（里面是**代码**，照常参与统计）。
    enum LexFrame {
        /// - `interpolates`: 只有 JS/TS/Vue 的反引号模板串认 `${`；Go 的反引号原始串是纯字面量。
        /// - `honorsEscapes`: Go 原始串里 `\` 不是转义符，照 JS 跳两步会把收尾反引号一起吃掉。
        case quoted(delim: [Character], interpolates: Bool, honorsEscapes: Bool)
        /// 模板插值内部。`braceDepth` 是表达式里**额外**的 `{`（对象字面量、块）计数，
        /// `parenDepth` 是未闭合的 `(` `[` 计数 —— 两者都只用于「配不平要出声」；
        /// 花括号增量本身仍按代码正常记（`${` 那格与配平的收尾 `}` 一样都不记，净增量为 0）。
        case expression(braceDepth: Int, parenDepth: Int)
    }

    /// 逐行传递的词法状态。`frames` 取代旧的 `stringDelim` 单字段。
    struct LexState {
        var blockDepth = 0
        var frames: [LexFrame] = []
        var integrity = LexIntegrity()

        /// 清洗一行。
        mutating func line(_ raw: String, _ profile: LangProfile) -> LineOutput {
            var out = LineOutput()
            guard raw.isEmpty == false else { return out }
            let chars = Array(raw)
            var index = 0
            while index < chars.count {
                if step(chars, &index, profile, &out) == .lineDone { return out }
            }
            return out
        }

        /// 状态分派：块注释 > 串内部 > 代码态。
        /// 与旧 `advanceSanitizedLine` 的判定顺序一致（块注释 → 新开块注释 → 行注释 →
        /// 跨行引号 → 单行引号 → 普通字符），只多出「正则字面量」一档。
        mutating func step(_ chars: [Character], _ i: inout Int, _ profile: LangProfile,
                           _ out: inout LineOutput) -> LexStep {
            if blockDepth > 0 {
                return ComplexityEngine.scanBlockComment(chars, &i, profile, &self) ? .keepGoing : .lineDone
            }
            if case .quoted = frames.last {
                return stepQuoted(chars, &i)
            }
            return stepCode(chars, &i, profile, &out)
        }

        /// 串内部：只找闭合定界符与 `${`，串文字不进 cleaned、不计花括号。
        mutating func stepQuoted(_ chars: [Character], _ i: inout Int) -> LexStep {
            guard case .quoted(let delim, let interpolates, let honorsEscapes) = frames.last else {
                return .keepGoing
            }
            let count = chars.count
            while i < count {
                if interpolates, chars[i] == "$", i + 1 < count, chars[i + 1] == "{" {
                    frames.append(.expression(braceDepth: 0, parenDepth: 0))
                    i += 2
                    return .keepGoing
                }
                if honorsEscapes, chars[i] == "\\" { i += 2; continue }
                if ComplexityEngine.startsHere(chars, delim, at: i) {
                    frames.removeLast()
                    i += delim.count
                    return .keepGoing      // 关键：弹回上一层（外层模板串 / 代码），本行继续扫
                }
                i += 1
            }
            return .lineDone               // 跨行串合法；到文件尾仍没闭合由 seal() 出声
        }

        /// 代码态（空栈，或在插值表达式里）。
        mutating func stepCode(_ chars: [Character], _ i: inout Int, _ profile: LangProfile,
                               _ out: inout LineOutput) -> LexStep {
            if let start = profile.blockStart, ComplexityEngine.startsHere(chars, start, at: i) {
                blockDepth = 1
                i += start.count
                return ComplexityEngine.scanBlockComment(chars, &i, profile, &self) ? .keepGoing : .lineDone
            }
            if ComplexityEngine.matchesAnyPrefix(chars, at: i, profile.lineComments) != nil { return .lineDone }
            if let delim = ComplexityEngine.matchMultiLineQuote(chars, at: i, profile) {
                frames.append(LexFrame.quoted(delim: delim,
                                              interpolates: delim.first == "`" && profile.backtickInterpolates,
                                              honorsEscapes: delim.first != "`" || profile.backtickInterpolates))
                i += delim.count
                return .keepGoing
            }
            let c = chars[i]
            // 本行内没有闭合引号的单引号一律当普通字符（Rust 生命周期、英文撇号）——与旧实现同口径
            if profile.quotes.contains(c), let close = ComplexityEngine.closingQuote(chars, c, from: i + 1) {
                i = close + 1
                return .keepGoing
            }
            if profile.regexLiterals, c == "/" {
                if let resume = ComplexityEngine.regexLiteralEnd(chars, from: i) {
                    i = resume
                    return .keepGoing
                }
                if ComplexityEngine.looksLikeRegexStart(chars, i) { integrity.regexLikeUnterminated += 1 }
            }
            return recordCodeCharacter(c, &i, &out)
        }

        /// 代码字符落进 cleaned；插值帧里的 `{` `}` `(` `[` 另记一层配平。
        mutating func recordCodeCharacter(_ c: Character, _ i: inout Int,
                                          _ out: inout LineOutput) -> LexStep {
            switch c {
            case "{":
                bumpExpression(.brace, by: 1)
                out.opens += 1
            case "}":
                if case .expression(let brace, _) = frames.last, brace == 0 {
                    frames.removeLast()       // 插值收尾：`${` 那格没记 opens，这里也不记 closes
                    i += 1
                    return .keepGoing
                }
                bumpExpression(.brace, by: -1)
                out.closes += 1
            case "(", "[":
                bumpExpression(.paren, by: 1)
            case ")", "]":
                bumpExpression(.paren, by: -1)
            default:
                break
            }
            out.text.append(c)
            i += 1
            return .keepGoing
        }

        enum DepthKind { case brace, paren }

        mutating func bumpExpression(_ kind: DepthKind, by delta: Int) {
            guard case .expression(let brace, let paren) = frames.last else { return }
            var nextBrace = brace
            var nextParen = paren
            if kind == .brace { nextBrace += delta } else { nextParen += delta }
            // 跌破 0 说明这里有个配不上的闭括号（多半是定界符被误判）——夹住并出声
            if nextBrace < 0 || nextParen < 0 { integrity.expressionUnderflow += 1 }
            frames[frames.count - 1] = .expression(braceDepth: max(0, nextBrace), parenDepth: max(0, nextParen))
        }

        /// 文件读完之后结算：帧栈没空 / 块注释没闭合 / 插值里还剩未配的括号，全部留名。
        mutating func seal() -> LexIntegrity {
            var settled = integrity
            if blockDepth > 0 { settled.endsInsideBlockComment = true }
            for frame in frames {
                switch frame {
                case .quoted:
                    settled.endsInsideString += 1
                case .expression(let brace, let paren):
                    settled.endsInsideExpression += 1
                    if brace > 0 || paren > 0 { settled.unbalancedExpressions += 1 }
                }
            }
            integrity = LexIntegrity()
            frames = []
            blockDepth = 0
            return settled
        }
    }

    // MARK: - 正则字面量（RD-06 夹具 4：正则里含反引号与 `${`）

    /// 正则字面量的起点候选：只有「这个 `/` 位置本来不可能是值」才算。
    /// 刻意**不**把 `<` `>` `]` `}` 列进来：TSX 的 `</div>` 会以「运算符之后」的身份混进来，
    /// 而一个认错起点的后果是把整行吃进假串里 —— 那正是本条目要修的病。
    static let regexStartPreceders: Set<Character> = ["(", ",", "=", ":", "[", "!", "&", "|", "?", "{",
                                                      ";", "+", "-", "*", "%", "~", "^"]

    static func previousSignificant(_ chars: [Character], _ at: Int) -> Character? {
        var index = at - 1
        while index >= 0 {
            let c = chars[index]
            if c == " " || c == "\t" { index -= 1; continue }
            return c
        }
        return nil
    }

    static func looksLikeRegexStart(_ chars: [Character], _ at: Int) -> Bool {
        guard let previous = previousSignificant(chars, at) else { return true }   // 行首
        return regexStartPreceders.contains(previous)
    }

    /// 返回正则字面量的**下一格**列位；不像正则、或本行内不闭合就返回 nil
    /// （调用方退回普通字符，一格一格走，绝不吞行）。字面量里含 `<` 也按「不是正则」处理，理由同上。
    static func regexLiteralEnd(_ chars: [Character], from: Int) -> Int? {
        guard from + 1 < chars.count, looksLikeRegexStart(chars, from) else { return nil }
        let count = chars.count
        var index = from + 1
        var inClass = false
        while index < count {
            let c = chars[index]
            if c == "\\", index + 1 < count { index += 2; continue }
            if c == "<" { return nil }
            if inClass {
                if c == "]" { inClass = false }
                index += 1
                continue
            }
            if c == "[" { inClass = true; index += 1; continue }
            if c == "/" { return index > from + 1 ? index + 1 : nil }
            if c == "\n" { return nil }
            index += 1
        }
        return nil
    }
}
