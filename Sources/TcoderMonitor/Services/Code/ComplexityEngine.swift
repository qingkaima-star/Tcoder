import Foundation

// MARK: - Public model

struct FunctionCandidate: Sendable {
    var name: String
    var startLine: Int      // 1-based，函数签名所在行
    var lineCount: Int      // 函数总行数（签名行到闭合行）
    var parameterCount: Int
    var complexity: Int     // 圈复杂度，>= 1
}

// MARK: - Engine

enum ComplexityEngine {

    // MARK: Tunables

    private static let minFunctionLines = 2
    private static let maxFunctionLines = 20_000
    private static let maxCandidatesPerFile = 20_000
    /// 多行签名时向后找第一个 `{` 的最大跨度
    private static let maxSignatureLookahead = 8
    /// 超过该长度的行视为压缩产物/数据行，不做签名匹配
    private static let maxLineLengthForMatch = 4_000
    /// 无括号语言的函数体最大跨度
    private static let maxBodyLookahead = 4_000

    // MARK: API

    /// 从单个文件识别函数并算复杂度；无法识别的语言返回 []。
    static func functions(in file: ScannedSourceFile) -> [FunctionCandidate] {
        let profile = profile(for: file.language)
        guard profile.family != .none, !profile.patterns.isEmpty else { return [] }
        let raw = file.lines.map { $0.text }
        guard !raw.isEmpty else { return [] }

        let src = sanitize(raw, profile)
        var scriptMask: [Bool]?
        if profile.scriptRegionOnly {
            scriptMask = computeScriptMask(src.cleaned)
        }

        var result: [FunctionCandidate] = []
        var line = 0
        while line < src.cleaned.count {
            if result.count >= maxCandidatesPerFile { break }
            if line > 0, !src.balancedBefore[line - 1] { line += 1; continue }
            if let mask = scriptMask, !mask[line] { line += 1; continue }
            let cleanedLine = src.cleaned[line]
            // utf8.count 对原生 Swift String 是 O(1)，utf16.count 会触发转码；这里只是长度门槛
            guard !cleanedLine.isEmpty, cleanedLine.utf8.count <= maxLineLengthForMatch else {
                line += 1
                continue
            }
            // 廉价预筛：绝大多数语言的签名都必须带 `(`，先挡掉就不必为每行进 NSString/正则循环
            if profile.parenOnEveryPattern, cleanedLine.contains("(") == false { line += 1; continue }
            guard let name = matchSignature(cleanedLine, profile) else { line += 1; continue }

            var closing: Int?
            var signatureEnd = line
            switch profile.family {
            case .curly, .shell:
                if let span = curlyEnd(start: line, src, profile) {
                    closing = span.closing
                    signatureEnd = span.brace
                }
            case .indentation:
                closing = indentedEnd(start: line, src.cleaned)
            case .rubyEnd:
                closing = rubyEnd(start: line, src.cleaned)
            case .none:
                break
            }
            guard let endLine = closing else { line += 1; continue }

            let count = endLine - line + 1
            if count >= minFunctionLines, count <= maxFunctionLines {
                let signature = src.cleaned[line...signatureEnd].joined(separator: " ")
                result.append(FunctionCandidate(
                    name: name,
                    startLine: line + 1,
                    lineCount: count,
                    parameterCount: parameterCount(from: signature),
                    complexity: complexity(ofCleanedLines: Array(src.cleaned[line...endLine]), profile: profile)
                ))
            }
            line = endLine + 1
        }
        return result
    }

    /// 对给定文本行序列计算圈复杂度（>=1）。
    static func complexity(forLines lines: [String], language: String) -> Int {
        guard !lines.isEmpty else { return 1 }
        let profile = profile(for: language)
        let cleaned = sanitize(lines, profile).cleaned
        return complexity(ofCleanedLines: cleaned, profile: profile)
    }

    /// 从签名里括号内的参数列表推断参数个数。
    static func parameterCount(from signature: String) -> Int {
        let chars = Array(signature)
        guard let open = chars.firstIndex(of: "(") else { return 0 }
        var depth = 0
        var angle = 0
        var commas = 0
        var hasContent = false
        var quote: Character?
        var index = open
        while index < chars.count {
            let c = chars[index]
            if let q = quote {
                if c == "\\" { index += 2; continue }
                if c == q { quote = nil }
                index += 1
                continue
            }
            switch c {
            case "\"", "'":
                quote = c
                hasContent = true
            case "(", "[", "{":
                depth += 1
                if depth > 1 { hasContent = true }
            case ")", "]", "}":
                depth -= 1
                if depth <= 0 { return parameterSegmentCount(commas: commas, hasContent: hasContent) }
            case "<":
                if depth <= 1, angle == 0, index > open { angle += 1 }
                hasContent = true
            case ">":
                if angle > 0 { angle -= 1 }
                hasContent = true
            case ",":
                if depth == 1 && angle == 0 { commas += 1 }
            default:
                if !c.isWhitespace { hasContent = true }
            }
            index += 1
        }
        return parameterSegmentCount(commas: commas, hasContent: hasContent)
    }

    private static func parameterSegmentCount(commas: Int, hasContent: Bool) -> Int {
        guard hasContent else { return 0 }
        return commas + 1
    }

    // MARK: Complexity

    /// 所有可能出现在关键字正则里的词；具体语言再按 branchKeywords 取子集。
    private static let allBranchKeywords: Set<String> = [
        "else if", "if", "elif", "elseif", "foreach", "for", "while", "until",
        "case", "when", "catch", "except", "rescue", "guard", "require",
        "loop", "match", "repeat", "and", "or",
    ]

    /// 单一关键字正则：一次匹配 + 关键字集合过滤，比按语言现编译正则快得多。
    private static let branchKeywordExpression = try? NSRegularExpression(
        pattern: "\\b(?:else[ \\t]+if|elseif|elif|foreach|for|while|until|case|when|catch|except"
            + "|rescue|guard|require|loop|match|repeat|and|or|if)\\b",
        options: []
    )

    private static func complexity(ofCleanedLines lines: [String], profile: LangProfile) -> Int {
        var total = 1
        let keywords = profile.branchKeywords.isEmpty ? allBranchKeywords : profile.branchKeywords
        for rawLine in lines {
            // 预处理指令行（#if DEBUG / #include）不计入，避免平台分支被当成逻辑分支
            if rawLine.isEmpty || rawLine.first == "#" { continue }
            if let re = branchKeywordExpression {
                let text = rawLine as NSString
                let matches = re.matches(in: rawLine, options: [], range: NSRange(location: 0, length: text.length))
                for match in matches {
                    var word = text.substring(with: match.range)
                    // `else   if`（多个空白）也要落到 "else if" 这个关键字上
                    if word.hasPrefix("else") { word = "else if" }
                    if keywords.contains(word) { total += 1 }
                }
            }
            total += branchSymbols(in: rawLine, profile: profile)
        }
        return max(1, total)
    }

    // 三元 `?` 的判定是纯启发式：Swift/Kotlin/Dart 里 `Int?` 满天飞，所以额外要求
    // 「冒号出现在该 ? 之后」，否则 `let x: Int? = 5` 会被误计一次。
    private static func branchSymbols(in rawLine: String, profile: LangProfile) -> Int {
        // 绝大多数代码行既没有 && / || 也没有 ?，先零成本过一遍再决定要不要转 [Character]
        guard rawLine.contains(where: { $0 == "?" || $0 == "&" || $0 == "|" }) else { return 0 }
        let chars = Array(rawLine)
        guard !chars.isEmpty else { return 0 }
        var lastColon = -1
        for (offset, c) in chars.enumerated() where c == ":" { lastColon = offset }
        var hasAssignment = false
        var hasParen = false
        var hasReturn = false
        for c in chars {
            if c == "=" { hasAssignment = true }
            else if c == "(" { hasParen = true }
        }
        let n = chars.count
        var index = 0
        var count = 0
        while index < n {
            let c = chars[index]
            if c == "&", profile.countsLogicalSymbols, index + 1 < n, chars[index + 1] == "&" {
                count += 1; index += 2; continue
            }
            if c == "|", profile.countsLogicalSymbols, index + 1 < n, chars[index + 1] == "|" {
                count += 1; index += 2; continue
            }
            if c == "?" {
                if profile.countsNullCoalescing, index + 1 < n, chars[index + 1] == "?" { count += 1; index += 2; continue }
                // `?.` 可选链本身就是一次判定分支
                if profile.countsOptionalChaining, index + 1 < n, chars[index + 1] == "." { count += 1; index += 2; continue }
                if index + 1 < n, chars[index + 1] == "." { index += 1; continue }
                if index > 0, chars[index - 1] == "?" { index += 1; continue }
                let followedByWhitespace = index + 1 < n && (chars[index + 1] == " " || chars[index + 1] == "\t")
                if profile.countsTernary, followedByWhitespace, lastColon > index,
                   hasAssignment || hasReturn || hasParen {
                    count += 1
                }
                index += 1
                continue
            }
            if c == "r", hasReturn == false, isKeywordAt(chars, index, "return") {
                hasReturn = true
            }
            index += 1
        }
        return count
    }

    /// chars[at...] 是否以 keyword 开头且前后不是标识符字符（避免 returnValue 触发 return）。
    private static func isKeywordAt(_ chars: [Character], _ at: Int, _ keyword: String) -> Bool {
        let letters = Array(keyword)
        guard !letters.isEmpty, at + letters.count <= chars.count else { return false }
        guard chars[at...].prefix(letters.count).elementsEqual(letters) else { return false }
        if at > 0, isIdentifierCharacter(chars[at - 1]) { return false }
        let next = at + letters.count
        if next < chars.count, isIdentifierCharacter(chars[next]) { return false }
        return true
    }

    private static func isIdentifierCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }

#if CE_DEBUG
    static func ceDebug(_ line: String, language: String) -> String {
        let profile = profile(for: language)
        var out = "patterns=\(profile.patterns.count) family=\(profile.family) paren=\(profile.parenOnEveryPattern)\n"
        for (i, pattern) in profile.patterns.enumerated() {
            let text = line as NSString
            let range = NSRange(location: 0, length: text.length)
            let m = pattern.expression.firstMatch(in: line, options: [], range: range)
            let g1 = m.flatMap { $0.range(at: 1).location == NSNotFound ? nil : text.substring(with: $0.range(at: 1)) } ?? "nil"
            out += "  [\(i)] groups=\(pattern.expression.numberOfCaptureGroups) match=\(m != nil) g1=\(g1) pat=\(pattern.expression.pattern)\n"
        }
        out += "  name=\(matchSignature(line, profile) ?? "nil")"
        return out
    }
#endif

    // MARK: Signature matching

    private static func matchSignature(_ line: String, _ profile: LangProfile) -> String? {
        let text = line as NSString
        let range = NSRange(location: 0, length: text.length)
        for pattern in profile.patterns {
            guard pattern.needsParen ? line.contains("(") : true else { continue }
            guard let match = pattern.expression.firstMatch(in: line, options: [], range: range) else { continue }
            // 可选捕获组没参与匹配时 range(at:) 返回 {NSNotFound, 0}，直接喂给 substring 会抛
            // NSInvalidArgumentException（真实崩过），一律走安全取值；没命名就是匿名函数。
            let raw = trimQuotes(groupText(text, match, 1) ?? "")
            let name: String
            if let prefix = pattern.namePrefix {
                guard !raw.isEmpty else { continue }
                name = prefix + raw
            } else {
                name = raw.isEmpty ? "<anonymous>" : raw
            }
            if isReservedName(name) { continue }
            // 名字之前必须真的有什么：注解、修饰符或返回类型。
            // cStyle 的返回类型组是 (?:…) 非捕获的，拿不到「组 2」，所以这里直接用
            // 「组 1 之前的前缀」判定：前缀为空说明这是 `foo(bar)` 之类的裸调用行。
            let headText = (groupText(text, match, 1, prefixOnly: true) ?? "").trimmingCharacters(in: .whitespaces)
            if pattern.requiresTypeToken {
                let typeToken = (groupText(text, match, 2) ?? "").trimmingCharacters(in: .whitespaces)
                if typeToken.isEmpty { continue }
            } else if pattern.requiresModifierWhenNoType {
                if headText.isEmpty, name.contains("::") == false { continue }
            }
            return name
        }
        return nil
    }

    /// prefixOnly = true 时取「捕获组 1 之前的那段文本」，用于检查行首有没有修饰符。
    private static func groupText(
        _ text: NSString, _ match: NSTextCheckingResult, _ index: Int, prefixOnly: Bool = false
    ) -> String? {
        guard index < match.numberOfRanges else { return nil }
        let target = match.range(at: index)
        guard target.location != NSNotFound else { return nil }
        if prefixOnly { return text.substring(to: target.location) }
        guard NSMaxRange(target) <= text.length else { return nil }
        return text.substring(with: target)
    }

    /// `'onClick'` / `"onClick"` 这类带引号的对象键，名字里去掉引号。
    private static func trimQuotes(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, trimmed.count >= 2 else { return trimmed }
        if first == "\"" || first == "'" {
            guard trimmed.hasSuffix(String(first)) else { return trimmed }
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    /// 名字命中这些词就不是函数：控制流关键字（`if (x) {`）、类型说明符与 C/C++ 属性式关键字
    /// （`alignas(64) struct Foo {` 会被 cStyle 误读成 `alignas(...)` 函数）。
    private static func isReservedName(_ name: String) -> Bool {
        switch name {
        case "if", "else", "for", "foreach", "while", "until", "repeat", "do", "switch", "case",
             "catch", "try", "finally", "when", "guard", "require", "return", "yield", "await",
             "throw", "defer", "deinit", "in", "is", "as", "then", "where", "let", "var", "const",
             "func", "function", "fun", "sub", "end", "def", "fn", "and", "or", "not", "new",
             "delete", "typeof", "instanceof", "void", "this", "super", "self", "Self", "nil",
             "true", "false", "null", "undefined", "elif", "begin", "rescue", "ensure", "class",
             "struct", "enum", "protocol", "extension", "interface", "object", "module", "namespace",
             "operator", "get", "set", "init", "next", "print", "raise", "assert", "match", "with",
             "alignas", "alignof", "decltype", "sizeof", "static_assert", "static_cast",
             "reinterpret_cast", "const_cast", "dynamic_cast", "noexcept", "typeid", "explicit",
             "friend", "template", "typename", "using", "union", "mutable", "constexpr",
             "consteval", "constinit", "co_await", "co_return", "co_yield", "typedef", "typeof_unqual":
            return true
        default:
            return false
        }
    }

    // MARK: Function boundaries

    private static func curlyEnd(start: Int, _ src: SanitizedSource, _ profile: LangProfile) -> (closing: Int, brace: Int)? {
        let n = src.cleaned.count
        let base = src.prefix[start]
        var cursor = start
        var braceLine = -1
        while cursor < n {
            // 未闭合的候选必须硬收敛：单次扫描不超过 maxFunctionLines，避免整文件退化成 O(N²)
            if cursor - start > maxFunctionLines { return nil }
            if cursor > start, !src.balancedBefore[cursor - 1] { return nil }
            if braceLine < 0 {
                if profile.allowTrailingSemicolonEnd == false, src.cleaned[cursor].contains(";") { return nil }
                // 向后找 `{` 的窗口里又出现一条新签名，说明本行只是无函数体的声明
                // （Swift 协议要求、@objc 声明、C 原型），不能把下一个函数的 `{` 当成自己的边界
                if cursor > start, matchSignature(src.cleaned[cursor], profile) != nil { return nil }
                if src.opens[cursor] > 0 {
                    braceLine = cursor
                    if src.prefix[cursor + 1] <= base { return (cursor, cursor) }
                } else if cursor - start >= maxSignatureLookahead {
                    return nil
                }
            } else if src.prefix[cursor + 1] <= base {
                return (cursor, braceLine)
            }
            cursor += 1
        }
        return nil
    }

    private static func indentedEnd(start: Int, _ cleaned: [String]) -> Int? {
        let indent = indentation(of: cleaned[start])
        var lastBody = start
        var cursor = start + 1
        while cursor < cleaned.count, cursor - start <= maxBodyLookahead {
            let line = cleaned[cursor]
            if line.first == nil { cursor += 1; continue }
            if indentation(of: line) <= indent { break }
            lastBody = cursor
            cursor += 1
        }
        return lastBody == start ? nil : lastBody
    }

    /// Ruby：只有和 `def` 同级（或更靠外）的 `end` 才是函数收尾。
    /// 更深一层的 `end` 关的是更深的块，与本函数边界无关，不需要计数；
    /// 同级又开出 def/class/module 说明上一个 end 被漏掉了，直接放弃候选而不是把后面全吞进来。
    private static func rubyEnd(start: Int, _ cleaned: [String]) -> Int? {
        let indent = indentation(of: cleaned[start])
        var cursor = start + 1
        while cursor < cleaned.count, cursor - start <= maxBodyLookahead {
            let line = cleaned[cursor]
            if line.first != nil, indentation(of: line) <= indent {
                if line.isRubyBlockEnd { return cursor }
                if line.isRubySiblingBlockStart { return nil }
            }
            cursor += 1
        }
        return nil
    }

    private static func indentation(of line: String) -> Int {
        var width = 0
        for c in line {
            if c == " " { width += 1 }
            else if c == "\t" { width += 4 }
            else { break }
        }
        return width
    }

    private static func computeScriptMask(_ cleaned: [String]) -> [Bool] {
        var mask = [Bool](repeating: false, count: cleaned.count)
        var inside = false
        for (index, line) in cleaned.enumerated() {
            let lower = line.lowercased()
            if lower.contains("</script") {
                inside = false
            } else if lower.contains("<script") {
                inside = true
            }
            mask[index] = inside
        }
        return mask
    }

    // MARK: Sanitizer (strings + comments stripped, brace deltas)

    private struct SanitizedSource {
        var cleaned: [String]
        var opens: [Int]
        var closes: [Int]
        var prefix: [Int]
        var balancedBefore: [Bool]
    }

    private struct LexState {
        var blockDepth = 0
        var stringDelim: [Character]?
        var stringIsTemplate = false
        var inTemplateExpression = false
        var templateBraceDepth = 0
    }

    private static func sanitize(_ lines: [String], _ profile: LangProfile) -> SanitizedSource {
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

    private struct LineOutput {
        var text = ""
        var opens = 0
        var closes = 0
    }

    private static func sanitizeLine(_ raw: String, _ profile: LangProfile, _ state: inout LexState) -> LineOutput {
        var out = LineOutput()
        guard !raw.isEmpty else { return out }
        let chars = Array(raw)
        let n = chars.count
        var i = 0

        // 续行：仍在跨行字符串里
        if let delim = state.stringDelim, state.inTemplateExpression == false {
            if scanString(chars, &i, delim, state.stringIsTemplate, profile, &state, &out) == false {
                return out
            }
        }

        while i < n {
            if state.blockDepth > 0 {
                if scanBlockComment(chars, &i, profile, &state) == false { return out }
                continue
            }
            if let start = profile.blockStart, startsHere(chars, start, at: i) {
                state.blockDepth = 1
                i += start.count
                if scanBlockComment(chars, &i, profile, &state) == false { return out }
                continue
            }
            if matchesAnyPrefix(chars, at: i, profile.lineComments) != nil {
                return out
            }
            if let delim = matchMultiLineQuote(chars, at: i, profile) {
                state.stringDelim = delim
                state.stringIsTemplate = delim.first == "`" && profile.backtickInterpolates
                state.inTemplateExpression = false
                i += delim.count
                if scanString(chars, &i, delim, state.stringIsTemplate, profile, &state, &out) == false {
                    return out
                }
                continue
            }
            if profile.quotes.contains(chars[i]) {
                let quote = chars[i]
                if let close = closingQuote(chars, quote, from: i + 1) {
                    i = close + 1
                    continue
                }
                // 本行没有闭合引号（Rust 生命周期、英文撇号）→ 当普通字符处理
            }

            let c = chars[i]
            if state.inTemplateExpression {
                if c == "{" {
                    state.templateBraceDepth += 1
                    out.text.append(c)
                    out.opens += 1
                    i += 1
                    continue
                }
                if c == "}" {
                    if state.templateBraceDepth == 0 {
                        state.inTemplateExpression = false
                        i += 1
                        continue
                    }
                    state.templateBraceDepth -= 1
                    out.text.append(c)
                    out.closes += 1
                    i += 1
                    continue
                }
            }
            if c == "{" {
                out.opens += 1
            } else if c == "}" {
                out.closes += 1
            }
            out.text.append(c)
            i += 1
        }
        return out
    }

    /// 返回 false 表示该行结束时仍在字符串内。
    private static func scanString(
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
    private static func scanBlockComment(
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

    private static func matchMultiLineQuote(_ chars: [Character], at i: Int, _ profile: LangProfile) -> [Character]? {
        for delim in profile.multiLineQuotes where startsHere(chars, delim, at: i) {
            return delim
        }
        return nil
    }

    private static func closingQuote(_ chars: [Character], _ quote: Character, from: Int) -> Int? {
        var i = from
        while i < chars.count {
            if chars[i] == "\\" { i += 2; continue }
            if chars[i] == quote { return i }
            i += 1
        }
        return nil
    }

    private static func matchesAnyPrefix(_ chars: [Character], at i: Int, _ prefixes: [[Character]]) -> [Character]? {
        for prefix in prefixes where startsHere(chars, prefix, at: i) {
            return prefix
        }
        return nil
    }

    private static func startsHere(_ chars: [Character], _ needle: [Character], at i: Int) -> Bool {
        guard !needle.isEmpty, i + needle.count <= chars.count else { return false }
        for offset in 0..<needle.count where chars[i + offset] != needle[offset] {
            return false
        }
        return true
    }

    // MARK: Language profiles

    private enum BodyFamily {
        case curly
        case indentation
        case rubyEnd
        case shell
        case none
    }

    private struct SignaturePattern {
        var expression: NSRegularExpression
        var namePrefix: String? = nil
        var requiresTypeToken = false
        var requiresModifierWhenNoType = false
        var needsParen = true

        init(_ pattern: String, namePrefix: String? = nil, requiresTypeToken: Bool = false,
             requiresModifierWhenNoType: Bool = false, needsParen: Bool = true) {
            self.namePrefix = namePrefix
            self.requiresTypeToken = requiresTypeToken
            self.requiresModifierWhenNoType = requiresModifierWhenNoType
            self.needsParen = needsParen
            // 嵌套类型里的 Self 指的是 SignaturePattern，必须显式回到 ComplexityEngine 才拿到缓存函数
            self.expression = ComplexityEngine.cache(pattern)
        }
    }

    private struct LangProfile {
        var family: BodyFamily = .none
        var patterns: [SignaturePattern] = []
        var lineComments: [[Character]] = []
        var blockStart: [Character]?
        var blockEnd: [Character]?
        var nestedBlockComments = false
        var multiLineQuotes: [[Character]] = []
        var quotes: Set<Character> = ["\"", "'"]
        var allowTrailingSemicolonEnd = true
        var scriptRegionOnly = false
        // 圈复杂度按语言取子集：关键字集合 + 参与判定的符号种类
        var branchKeywords: Set<String> = []
        var countsLogicalSymbols = true
        var countsTernary = true
        var countsNullCoalescing = false
        var countsOptionalChaining = false
        var parenOnEveryPattern = true
        /// 只有 JS/TS/Vue 的反引号模板串会做 `${}` 插值；Go 的反引号原始串是纯字面量，
        /// 若也按模板处理，串里的 `${` 会让状态机卡在「表达式内」，把原始串当代码统计花括号。
        var backtickInterpolates = false
    }

    /// 正则编译缓存。签名 pattern 是热点：每个文件都要走一遍 profile → 每条 pattern 建一个
    /// NSRegularExpression，绝不能反复编译。NSCache 本身线程安全，跨 Task.detached 并发读写
    /// 没有数据竞争；两个线程同时 miss 只会各编译一次、后写覆盖，结果等价。
    nonisolated(unsafe) private static let patternCache = NSCache<NSString, NSRegularExpression>()

    private static func cache(_ pattern: String) -> NSRegularExpression {
        if let hit = patternCache.object(forKey: pattern as NSString) { return hit }
        // 编译失败就退回「永不匹配」的表达式：单个语言规则坏了不该让整条链路崩溃
        let made = (try? NSRegularExpression(pattern: pattern, options: []))
            ?? (try? NSRegularExpression(pattern: "(?!x)x", options: []))!
        patternCache.setObject(made, forKey: pattern as NSString)
        return made
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private static func profile(for language: String) -> LangProfile {
        let canonical = canonicalLanguage(language)
        var profile = LangProfile()
        profile.family = family(of: canonical)
        profile.patterns = patterns(of: canonical)
        profile.parenOnEveryPattern = profile.patterns.allSatisfy { $0.needsParen }
        profile.lineComments = charactersList(primaryLineComments(for: canonical))
        if let pair = blockPair(for: canonical) {
            profile.blockStart = Array(pair.start)
            profile.blockEnd = Array(pair.end)
            profile.nestedBlockComments = canonical == "Swift"
        }
        profile.multiLineQuotes = charactersList(multiLineQuotes(for: canonical))
        profile.allowTrailingSemicolonEnd = profile.family == .curly
        profile.scriptRegionOnly = canonical == "Vue"
        profile.backtickInterpolates = canonical == "TypeScript" || canonical == "JavaScript" || canonical == "Vue"
        profile.branchKeywords = branchKeywords(for: canonical)
        profile.countsLogicalSymbols = canonical != "Python" && canonical != "HTML"
        profile.countsTernary = canonical != "Python" && canonical != "Go"
        profile.countsNullCoalescing = nullCoalescingLanguages.contains(canonical)
        profile.countsOptionalChaining = optionalChainingLanguages.contains(canonical)
        return profile
    }

    private static let nullCoalescingLanguages: Set<String> = [
        "Swift", "Kotlin", "TypeScript", "JavaScript", "Vue", "Dart", "PHP", "Objective-C", "Scala",
    ]

    private static let optionalChainingLanguages: Set<String> = [
        "Swift", "Kotlin", "TypeScript", "JavaScript", "Vue", "Dart",
    ]

    /// 每种语言只统计它真正存在的判定关键字，避免 `require`/`when`/`match` 在别的语言里凑数。
    private static func branchKeywords(for language: String) -> Set<String> {
        let common: Set<String> = ["if", "else if", "for", "while", "until", "case", "catch", "require"]
        switch language {
        case "Swift":
            return ["if", "else if", "for", "while", "case", "catch", "guard"]
        case "Java", "Kotlin", "TypeScript", "JavaScript", "Vue", "Dart", "Gradle":
            return common.union(["foreach", "when"])
        case "C", "C++", "Objective-C":
            return common
        case "Go":
            return ["if", "else if", "for", "case"]
        case "Rust":
            return common.union(["loop", "match"])
        case "Python":
            return ["if", "elif", "for", "while", "case", "when", "except", "and", "or"]
        case "Ruby":
            return ["if", "elsif", "for", "while", "until", "case", "when", "rescue", "and", "or"]
        case "PHP":
            return ["if", "elseif", "foreach", "for", "while", "until", "case", "catch", "require"]
        case "Shell":
            return ["if", "elif", "for", "while", "until", "case"]
        case "Scala":
            return ["if", "for", "while", "until", "case", "when", "catch"]
        default:
            return allBranchKeywords
        }
    }

    private static func canonicalLanguage(_ language: String) -> String {
        let key = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let hit = languageAliases[key] { return hit }
        return language
    }

    private static let languageAliases: [String: String] = [
        "swift": "Swift",
        "java": "Java",
        "kotlin": "Kotlin",
        "typescript": "TypeScript",
        "javascript": "JavaScript",
        "ts": "TypeScript",
        "js": "JavaScript",
        "jsx": "JavaScript",
        "tsx": "TypeScript",
        "python": "Python",
        "go": "Go",
        "golang": "Go",
        "rust": "Rust",
        "c": "C",
        "c++": "C++",
        "cpp": "C++",
        "objective-c": "Objective-C",
        "objectivec": "Objective-C",
        "ruby": "Ruby",
        "php": "PHP",
        "dart": "Dart",
        "scala": "Scala",
        "vue": "Vue",
        "html": "HTML",
        "css": "CSS",
        "scss": "SCSS",
        "sql": "SQL",
        "shell": "Shell",
        "bash": "Shell",
        "zsh": "Shell",
        "yaml": "YAML",
        "yml": "YAML",
        "toml": "TOML",
        "xml": "XML",
        "json": "JSON",
        "markdown": "Markdown",
        "md": "Markdown",
        "gradle": "Gradle",
        "groovy": "Gradle",
        "c#": "Java",
        "csharp": "Java",
    ]

    private static func family(of language: String) -> BodyFamily {
        switch language {
        case "Swift", "Java", "Kotlin", "TypeScript", "JavaScript", "C", "C++", "Objective-C",
             "Go", "Rust", "Scala", "Dart", "PHP", "Gradle", "Vue":
            return .curly
        case "Python":
            return .indentation
        case "Ruby":
            return .rubyEnd
        case "Shell":
            return .shell
        default:
            return .none
        }
    }

    private static let curlyLanguages: Set<String> = [
        "Swift", "Java", "Kotlin", "TypeScript", "JavaScript", "C", "C++", "Objective-C",
        "Go", "Rust", "Scala", "Dart", "PHP", "Gradle", "Vue", "CSS", "SCSS",
    ]

    private static func primaryLineComments(for language: String) -> [String] {
        var prefixes = SourceLanguageCatalog.lineCommentPrefixes(for: language)
        if prefixes.isEmpty, curlyLanguages.contains(language) { prefixes = ["//"] }
        // Ruby 等语言的 `'` 既是字符串引号；当作行注释前缀会把 `:'sym'` 之后的代码吃光
        prefixes.removeAll { $0 == "'" }
        return prefixes
    }

    private static func blockPair(for language: String) -> (start: String, end: String)? {
        if let pair = SourceLanguageCatalog.blockCommentDelimiters(for: language) { return pair }
        if curlyLanguages.contains(language) { return (start: "/*", end: "*/") }
        return nil
    }

    /// 跨行字符串的定界符（Python 的 `"""`、JS 的模板串），交给 charactersList 变成 [[Character]]。
    private static func multiLineQuotes(for language: String) -> [String] {
        var delimiters = SourceLanguageCatalog.docStringDelimiters(for: language)
        if language == "TypeScript" || language == "JavaScript" || language == "Vue" || language == "Go" {
            // Go 的反引号原始字符串可以跨行，里面什么都有（花括号、引号、`//`）；
            // 不当成字符串处理的话花括号深度就会被带偏，函数边界整段错位。
            delimiters = delimiters.filter { $0 != "`" } + ["`"]
        }
        return delimiters
    }

    private static func charactersList(_ strings: [String]) -> [[Character]] {
        strings.filter { !$0.isEmpty }.map { Array($0) }
    }

    // MARK: Patterns

    private static func patterns(of language: String) -> [SignaturePattern] {
        switch language {
        case "Swift":
            return [swiftFunction, swiftInitSubscript]
        case "Kotlin":
            return [kotlinFunction, cStyleFunction]
        case "Java":
            return [cStyleFunction]
        case "Scala":
            return [scalaFunction, cStyleFunction]
        case "TypeScript", "JavaScript":
            return [jsFunction, jsVariableArrow, jsMethod, jsObjectMethod]
        case "Vue":
            return [jsFunction, jsVariableArrow, jsMethod, jsObjectMethod]
        case "C", "C++":
            return [cStyleFunction]
        case "Objective-C":
            return [objectiveCMethod, cStyleFunction]
        case "Go":
            return [goFunction]
        case "Rust":
            return [rustFunction]
        case "Python":
            return [pythonFunction]
        case "Ruby":
            return [rubyFunction]
        case "PHP":
            return [phpFunction]
        case "Dart":
            return [cStyleFunction]
        case "Gradle":
            return [jsFunction, cStyleFunction]
        case "Shell":
            return [shellBrace, shellNameParen]
        default:
            return []
        }
    }

    // 以下全部正则一律用 Swift 原始字符串 #"…"#：
    // 原始串里 `\(` 就是字面的「反斜杠 + 左括号」（正则的转义括号），只有 `\#(x)` 才是插值。
    // 普通字符串里单反斜杠 `\(` 会被 Swift 当成插值起点，这正是本文件此前一批编译错误的根因。

    private static let annotationPrefix = #"\s*@\w+(?:\.\w+)*(?:\([^()]*\))?"#

    private static let modifierGroup =
        #"(?:(?:public|private(?:\(\))?|protected|internal|fileprivate|open|static|class|final|"#
        + #"abstract|override|sealed|data|value|inline|noinline|crossinline|tailrec|operator|infix|"#
        + #"external|constexpr|volatile|register|restrict|synchronized|throws|rethrows|async|await|suspend|"#
        + #"lazy|mutating|nonisolated|isolated|weak|strong|autoclosure|composable|virtual|readonly|"#
        + #"native|strictfp|default)[ \t]+)"#

    /// 「缩进 + 注解/修饰符（可重复，彼此之间允许空白）」前缀。
    /// 两处细节都是踩出来的：
    /// 1) 行首空白必须放在重复组之前，否则 `    suspend fun foo()` 这类带缩进的修饰符签名匹配不上；
    /// 2) 组内还要留一个 `[ \t]*`，否则 `@MainActor private func` 这种「注解 + 修饰符」会断在空格上。
    private static var head: String { #"[ \t]*(?:(?:\#(annotationPrefix)|\#(modifierGroup))[ \t]*)*"# }

    /// 单层参数列表（不含嵌套花括号，遇分号/换行即止）。
    private static let params = #"\((?:[^;{}\n]*)\)"#

    private static var swiftFunction: SignaturePattern {
        let modifiers = #"(?:(?:public|private|internal|fileprivate|open|static|class|final|override|"#
            + #"mutating|nonmutating|nonisolated|isolated|async|throws|rethrows|lazy|@\w+(?:\([^()]*\))?)[ \t]+)*"#
        // 覆盖：func name(_ a: Int, b: String) throws -> Foo {
        //       func name() { … / 泛型 func name<T: P>(…) where T: Q { …
        //       多行签名（`(` 之后换行，`{` 落在后面几行）→ 只要求匹配到 `(` 即可，
        //       函数体边界由 curlyEnd 向后找第一个 `{`。
        return SignaturePattern(
            #"^\#(head)\#(modifiers)func[ \t]+([A-Za-z_]\w*)[ \t]*(?:<[^<>()]*>)?[ \t]*\((?:[^;{}\n]*\))?(?:[^{;\n]*)?(?:\{|$)"#
        )
    }

    private static var swiftInitSubscript: SignaturePattern {
        SignaturePattern(
            #"^\#(head)(?:[A-Za-z_][\w.]*[ \t]+)*((?:init|subscript)(?:\p{Hiragana}\p{Katakana}\w*)?)"#
                + #"[ \t]*(?:<[^<>()]*>)?[ \t]*\("#,
            namePrefix: "@"
        )
    }

    private static var kotlinFunction: SignaturePattern {
        SignaturePattern(#"^\#(head)(?:fun|operator)[ \t]+(?:<[^<>]*>[ \t]*)?([A-Za-z_]\w*)[ \t]*\("#)
    }

    private static var scalaFunction: SignaturePattern {
        SignaturePattern(#"^\#(head)def[ \t]+([A-Za-z_]\w*)[ \t]*(?:\(|:)"#)
    }

    private static var cStyleFunction: SignaturePattern {
        let type = #"(?:[A-Za-z_$][\w$]*(?:\.\w+|::\w+)*(?:<[^<>{}();]*>)?(?:[ \t]*\[[ \t]*\])*[ \t*&]+)+"#
        // 组 1 必须是「函数名」本身；C++ 的 Foo::bar / Foo::~Foo 要整体算名字。
        // 参数表之后到 `{` 之间允许任意限定串：throws / noexcept / const / override / -> Ret / where…
        // （只排除分号和换行，所以 `foo(bar);` 这种调用行依然不会被误判成定义。）
        return SignaturePattern(
            #"^\#(head)(?:\#(type))?((?:[A-Za-z_$][\w$]*::)*~?[A-Za-z_$][\w$]*)[ \t]*\#(params)[^{;\n]*(?:\{|$)"#,
            requiresModifierWhenNoType: true
        )
    }

    private static var objectiveCMethod: SignaturePattern {
        SignaturePattern(#"^[ \t]*[-+][ \t]*\([^()]*\)[ \t]*([A-Za-z_]\w*)"#)
    }

    private static var jsFunction: SignaturePattern {
        // 允许赋值型函数表达式：`module.exports = function main(cb) {`、`handlers.save = function () {`
        let target = #"(?:[A-Za-z_$][\w$]*(?:\.?\[[^\]\n]{1,60}\]|\.[A-Za-z_$][\w$]*)*)[ \t]*=[ \t]*"#
        return SignaturePattern(
            #"^\#(head)(?:\#(target))?(?:export[ \t]+)?(?:default[ \t]+)?function[ \t]*\*?[ \t]*([A-Za-z_$][\w$]*)?[ \t]*\("#
        )
    }

    private static var jsVariableArrow: SignaturePattern {
        let name = #"([A-Za-z_$][\w$]*)"#
        let typeAnn = #"(?:[ \t]*:[ \t]*[^=;{}()]*?)?"#
        return SignaturePattern(
            #"^\#(head)(?:const|let|var)[ \t]+\#(name)[ \t]*=[ \t]*(?:async[ \t]+)?"#
                + #"(?:function[ \t]*\*?[ \t]*(?:[A-Za-z_$][\w$]*)?[ \t]*)?\#(typeAnn)\("#
        )
    }

    private static var jsMethod: SignaturePattern {
        // 整个成员名必须是捕获组 1：namePrefix "." 与 groupText(_,1) 都靠它（漏掉捕获会当场崩）
        let member = #"([A-Za-z_$][\w$]*|\[[^\]\n]{1,60}\]|"[^"\n]{1,60}"|'[^'\n]{1,60}')"#
        return SignaturePattern(
            #"^\#(head)(?:get[ \t]+|set[ \t]+)?\#(member)[ \t]*\.?[ \t]*\#(params)"#
                + #"(?:[ \t]*:[ \t]*[^;{}\n=]+)?[ \t]*\{"#,
            namePrefix: "."
        )
    }

    private static var jsObjectMethod: SignaturePattern {
        SignaturePattern(
            #"^\#(head)("[^"\n]{1,60}"|'[^'\n]{1,60}'|[A-Za-z_$][\w$]*)[ \t]*:[ \t]*(?:async[ \t]+)?"#
                + #"(?:function[ \t]*\*?[ \t]*(?:[A-Za-z_$][\w$]*)?[ \t]*)?(?:\#(params)|[A-Za-z_$][\w$]*)"#
                + #"(?:[ \t]*:[ \t]*[^;{}\n=]+)?[ \t]*(?:=>|\{)"#,
            namePrefix: "."
        )
    }

    private static var goFunction: SignaturePattern {
        // Go 1.18+ 泛型：`func Map[K comparable, V any](...)` 的类型参数表夹在名字和 `(` 之间
        SignaturePattern(#"^func[ \t]*(?:\([^()]*\)[ \t]*)?([A-Za-z_]\w*)[ \t]*(?:\[[^\]\n]*\))?[ \t]*\("#)
    }

    private static var rustFunction: SignaturePattern {
        SignaturePattern(
            #"^[ \t]*(?:pub(?:\([^()]*\))?[ \t]+)?(?:(?:default|async|unsafe|extern|const)[ \t]+)*"#
                + #"fn[ \t]+([A-Za-z_]\w*)[ \t]*(?:<[^<>()]*>)?[ \t]*\("#
        )
    }

    private static var pythonFunction: SignaturePattern {
        SignaturePattern(#"^[ \t]*(?:async[ \t]+)?def[ \t]+([A-Za-z_]\w*)[ \t]*\("#)
    }

    private static var rubyFunction: SignaturePattern {
        SignaturePattern(
            #"^[ \t]*def[ \t]+([A-Za-z_]\w*[?!=]?|\[\]=[\]]?|[!~<>=+\-*/%|&^]+)[ \t]*(?:\(|$|;)"#,
            needsParen: false
        )
    }

    private static var phpFunction: SignaturePattern {
        SignaturePattern(#"^\#(head)function[ \t]+&?([A-Za-z_][\w]*)[ \t]*\("#)
    }

    private static var shellBrace: SignaturePattern {
        SignaturePattern(#"^[ \t]*([A-Za-z_]\w*)[ \t]*\([ \t]*\)[ \t]*(?:\{|$)"#)
    }

    private static var shellNameParen: SignaturePattern {
        SignaturePattern(
            #"^[ \t]*(?:function[ \t]+|source[ \t]+)([A-Za-z_]\w*)[ \t]*(?:\([^()]*\))?[ \t]*(?:\{|$)"#,
            needsParen: false
        )
    }

    // MARK: Ruby block helpers

    /// 与 def 同级出现就意味着上一个块没闭合（rescue/ensure 不在此列，它们属于 def 自己）
    fileprivate static let rubySiblingBlockWords = ["def", "class", "module", "begin"]
}

// MARK: - Small text helpers (file private)

private extension String {

    /// 只有 `end` 能收尾 Ruby 函数；`rescue`/`ensure`/`when` 是同一个块内部的分支。
    var isRubyBlockEnd: Bool { rubyFirstWord == "end" }

    var isRubySiblingBlockStart: Bool {
        ComplexityEngine.rubySiblingBlockWords.contains(rubyFirstWord)
    }

    /// 行首第一个标识符。必须先跳过缩进——Ruby 方法全都带缩进，
    /// 不跳就永远取到空串，`  end` 会被判成「不是闭合」，函数边界一路跑到文件尾。
    var rubyFirstWord: String {
        var word = ""
        for c in self {
            if word.isEmpty, c == " " || c == "\t" { continue }
            if c.isLetter || c == "_" { word.append(c) }
            else { break }
        }
        return word
    }
}
