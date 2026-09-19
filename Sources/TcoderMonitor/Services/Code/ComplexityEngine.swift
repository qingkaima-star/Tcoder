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
            guard !cleanedLine.isEmpty, cleanedLine.utf16.count <= maxLineLengthForMatch else {
                line += 1
                continue
            }
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
                for match in matches where keywords.contains(text.substring(with: match.range)) {
                    total += 1
                }
            }
            total += branchSymbols(in: Array(rawLine), profile: profile)
        }
        return max(1, total)
    }

    // 三元 `?` 的判定是纯启发式：Swift/Kotlin/Dart 里 `Int?` 满天飞，所以额外要求
    // 「冒号出现在该 ? 之后」，否则 `let x: Int? = 5` 会被误计一次。
    private static func branchSymbols(in chars: [Character], profile: LangProfile) -> Int {
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

    // MARK: Signature matching

    private static func matchSignature(_ line: String, _ profile: LangProfile) -> String? {
        let text = line as NSString
        let range = NSRange(location: 0, length: text.length)
        for pattern in profile.patterns {
            guard pattern.needsParen ? line.contains("(") : true else { continue }
            guard let match = pattern.expression.firstMatch(in: line, options: [], range: range) else { continue }
            let raw = text.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let name: String
            if let prefix = pattern.namePrefix {
                guard !raw.isEmpty else { continue }
                name = prefix + raw
            } else {
                name = raw.isEmpty ? "<anonymous>" : raw
            }
            if isReservedName(name) { continue }
            if pattern.requiresTypeToken || pattern.requiresModifierWhenNoType {
                let typeToken = match.numberOfRanges > 2
                    ? text.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
                    : ""
                if typeToken.isEmpty {
                    if pattern.requiresTypeToken { continue }
                    let head = text.substring(with: NSRange(location: 0, length: match.range(at: 1).location))
                    if head.rangeOfAny(modifierWords) == nil { continue }
                }
            }
            return name
        }
        return nil
    }

    private static let modifierWords = [
        "public", "private", "protected", "internal", "fileprivate", "open", "static", "class",
        "final", "abstract", "override", "mutating", "nonisolated", "async", "suspend", "inline",
        "native", "synchronized", "strictfp", "default", "readonly", "virtual", "extern", "fun",
    ]

    private static func isReservedName(_ name: String) -> Bool {
        switch name {
        case "if", "else", "for", "foreach", "while", "until", "repeat", "do", "switch", "case",
             "catch", "try", "finally", "when", "guard", "require", "return", "yield", "await",
             "throw", "defer", "deinit", "in", "is", "as", "then", "where", "let", "var", "const",
             "func", "function", "fun", "sub", "end", "def", "fn", "and", "or", "not", "new",
             "delete", "typeof", "instanceof", "void", "this", "super", "self", "Self", "nil",
             "true", "false", "null", "undefined", "elif", "begin", "rescue", "ensure", "class",
             "struct", "enum", "protocol", "extension", "interface", "object", "module", "namespace",
             "operator", "get", "set", "init", "next", "print", "raise", "assert", "match", "with":
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

    private static func rubyEnd(start: Int, _ cleaned: [String]) -> Int? {
        let indent = indentation(of: cleaned[start])
        var cursor = start + 1
        var nested = 0
        while cursor < cleaned.count, cursor - start <= maxBodyLookahead {
            let line = cleaned[cursor]
            if line.first != nil {
                let lineIndent = indentation(of: line)
                if lineIndent <= indent, line.isRubyBlockCloser {
                    if nested == 0 { return cursor }
                    nested -= 1
                } else if lineIndent > indent, line.isRubyBlockOpener {
                    nested += 1
                }
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
                state.stringIsTemplate = delim.first == "`"
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
        while i < n {
            if isTemplate, chars[i] == "$", i + 1 < n, chars[i + 1] == "{" {
                state.inTemplateExpression = true
                state.templateBraceDepth = 0
                i += 2
                return true
            }
            if chars[i] == "\\" {
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
            self.expression = Self.cache(pattern)
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
    }

    private static let patternCache = NSCache<NSString, NSRegularExpression>()

    private static func cache(_ pattern: String) -> NSRegularExpression {
        if let hit = patternCache.object(forKey: pattern as NSString) { return hit }
        let made = (try? NSRegularExpression(pattern: pattern, options: []))
            ?? (try? NSRegularExpression(pattern: "\\u{0}\\u{1}", options: []))!
        patternCache.setObject(made, forKey: pattern as NSString)
        return made
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private static func profile(for language: String) -> LangProfile {
        let canonical = canonicalLanguage(language)
        var profile = LangProfile()
        profile.family = family(of: canonical)
        profile.patterns = patterns(of: canonical)
        profile.lineComments = charactersList(primaryLineComments(for: canonical))
        if let pair = blockPair(for: canonical) {
            profile.blockStart = Array(pair.start)
            profile.blockEnd = Array(pair.end)
            profile.nestedBlockComments = canonical == "Swift"
        }
        profile.multiLineQuotes = charactersList(multiLineQuotes(for: canonical))
        profile.allowTrailingSemicolonEnd = profile.family == .curly
        profile.scriptRegionOnly = canonical == "Vue"
        return profile
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

    private static func multiLineQuotes(for language: String) -> [[String]] {
        var delimiters = SourceLanguageCatalog.docStringDelimiters(for: language)
        if language == "TypeScript" || language == "JavaScript" || language == "Vue" {
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

    private static let annotationPrefix = "\\s*@\\w+(?:\\.\\w+)*(?:\\([^()]*\\))?"
    private static let modifierGroup = """
    (?:(?:public|private(?:\\(\\))?|protected|internal|fileprivate|open|static|class|final|abstract\\\
    |override|sealed|data|value|inline|noinline|crossinline|tailrec|operator|infix|external|constextri\\\
    f|constexpr|volatile|register|restrict|synchronized|throws|rethrows|async|await|lazy|mutating|noni\\\
    solated|isolated|weak|strong|autoclosure|composable|virtual|override|readonly|native|strictfp|defa\\\
    ult|abstract)[ \\t]+)
    """

    private static var head: String { "(?:\(annotationPrefix)|\(modifierGroup))*[ \\t]*" }

    private static let params = "\\((?:[^;{}\\n]*)\\)"

    private static var swiftFunction: SignaturePattern {
        let modifiers = "(?:(?:public|private|internal|fileprivate|open|static|class|final|override|"
            + "mutating|nonmutating|nonisolated|isolated|async|throws|rethrows|lazy|@\\w+(?:\\([^()]*\\))?)[ \\t]+)*"
        return SignaturePattern(
            "^\(head)\(modifiers)func[ \\t]+([A-Za-z_]\\w*)[ \\t]*(?:<[^<>()]*>)?[ \\t]*\\("
        )
    }

    private static var swiftInitSubscript: SignaturePattern {
        SignaturePattern(
            "^\(head)(?:[A-Za-z_][\\w.]*[ \\t]+)*((?:init|subscript)(?:\\p{Hiragana}\\p{Katakana}\\w*)?)"
                + "[ \\t]*(?:<[^<>()]*>)?[ \\t]*\\(",
            namePrefix: "@"
        )
    }

    private static var kotlinFunction: SignaturePattern {
        SignaturePattern("^\(head)(?:fun|operator)[ \\t]+(?:<[^<>]*>[ \\t]*)?([A-Za-z_]\\w*)[ \\t]*\\(")
    }

    private static var scalaFunction: SignaturePattern {
        SignaturePattern("^\(head)def[ \\t]+([A-Za-z_]\\w*)[ \\t]*(?:\\(|:)")
    }

    private static var cStyleFunction: SignaturePattern {
        let type = "(?:[A-Za-z_$][\\w$]*(?:\\.\\w+)*(?:<[^<>{}();]*>)?(?:[ \\t]*\\[[ \\t]*\\])*[ \\t*&]+)+"
        return SignaturePattern(
            "^\(head)(?:\(type))?([A-Za-z_$][\\w$]*)[ \\t]*\((?:[^;{}\\n]*)\\)"
                + "(?:[ \\t]+throws[ \\t]+[\\w.,$ \\t]+)?[ \\t]*(?:\\{|$)",
            requiresModifierWhenNoType: true
        )
    }

    private static var objectiveCMethod: SignaturePattern {
        SignaturePattern("^[ \\t]*[-+][ \\t]*\\([^()]*\\)[ \\t]*([A-Za-z_]\\w*)")
    }

    private static var jsFunction: SignaturePattern {
        SignaturePattern(
            "^\(head)(?:export[ \\t]+)?(?:default[ \\t]+)?function[ \\t]*\\*?[ \\t]*([A-Za-z_$][\\w$]*)?[ \\t]*\\("
        )
    }

    private static var jsVariableArrow: SignaturePattern {
        let name = "([A-Za-z_$][\\w$]*)"
        let typeAnn = "(?:[ \\t]*:[ \\t]*[^=;{}()]*?)?"
        return SignaturePattern(
            "^\(head)(?:const|let|var)[ \\t]+\(name)[ \\t]*=[ \\t]*(?:async[ \\t]+)?"
                + "(?:function[ \\t]*\\*?[ \\t]*(?:[A-Za-z_$][\\w$]*)?[ \\t]*)?\(typeAnn)\\("
        )
    }

    private static var jsMethod: SignaturePattern {
        let member = "(?:[A-Za-z_$][\\w$]*|\\[[^\\]\\n]{1,60}\\]|\"[^\"\\n]{1,60}\"|'[^'\\n]{1,60}')"
        return SignaturePattern(
            "^\(head)(?:get[ \\t]+|set[ \\t]+)?\(member)[ \\t]*\\.?[ \\t]*\((?:[^;{}\\n]*)\\)"
                + "(?:[ \\t]*:[ \\t]*[^;{}\\n=]+)?[ \\t]*\\{",
            namePrefix: "."
        )
    }

    private static var jsObjectMethod: SignaturePattern {
        SignaturePattern(
            "^\(head)(?:\"[^\\"\\n]{1,60}\"|'[^'\\n]{1,60}'|[A-Za-z_$][\\w$]*)[ \\t]*:[ \\t]*(?:async[ \\t]+)?"
                + "(?:function[ \\t]*\\*?[ \\t]*(?:[A-Za-z_$][\\w$]*)?[ \\t]*)?(?:\\((?:[^;{}\\n]*)\\)|"
                + "[A-Za-z_$][\\w$]*)(?:[ \\t]*:[ \\t]*[^;{}\\n=]+)?[ \\t]*(?:=>|\\{)",
            namePrefix: "."
        )
    }

    private static var goFunction: SignaturePattern {
        SignaturePattern("^func[ \\t]*(?:\\([^()]*\\)[ \\t]*)?([A-Za-z_]\\w*)[ \\t]*\\(")
    }

    private static var rustFunction: SignaturePattern {
        SignaturePattern(
            "^[ \\t]*(?:pub(?:\\([^()]*\\))?[ \\t]+)?(?:(?:default|async|unsafe|extern|const)[ \\t]+)*"
                + "fn[ \\t]+([A-Za-z_]\\w*)[ \\t]*(?:<[^<>()]*>)?[ \\t]*\\("
        )
    }

    private static var pythonFunction: SignaturePattern {
        SignaturePattern("^[ \\t]*(?:async[ \\t]+)?def[ \\t]+([A-Za-z_]\\w*)[ \\t]*\\(")
    }

    private static var rubyFunction: SignaturePattern {
        SignaturePattern(
            "^[ \\t]*def[ \\t]+([A-Za-z_]\\w*[?!=]?|\\[\\]=[\\]]?|[!~<>=+\\-*/%|&^]+)[ \\t]*(?:\\(|$|;)",
            needsParen: false
        )
    }

    private static var phpFunction: SignaturePattern {
        SignaturePattern(
            "^\(head)function[ \\t]+&?([A-Za-z_][\\w]*)[ \\t]*\\("
        )
    }

    private static var shellBrace: SignaturePattern {
        SignaturePattern("^[ \\t]*([A-Za-z_]\\w*)[ \\t]*\\([ \\t]*\\)[ \\t]*(?:\\{|$)")
    }

    private static var shellNameParen: SignaturePattern {
        SignaturePattern("^[ \\t]*(?:function[ \\t]+|source[ \\t]+)([A-Za-z_]\\w*)[ \\t]*(?:\\([^()]*\\))?[ \\t]*(?:\\{|$)")
    }

    // MARK: Ruby block helpers

    private static let rubyCloserWords = ["end", "class", "module", "begin", "rescue", "ensure"]

    private static let rubyOpenerWords = [
        "def", "class", "module", "do", "begin", "if", "unless", "while", "until", "case",
    ]
}

// MARK: - Small text helpers (file private)

extension ComplexityEngine {

    fileprivate static var StringExtensionHooks: Void { () }
}

private extension String {

    var isRubyBlockCloser: Bool {
        let head = rubyFirstWord
        return ComplexityEngine_rubyCloserWords.contains(head)
    }

    var isRubyBlockOpener: Bool {
        let head = rubyFirstWord
        return ComplexityEngine_rubyOpenerWords.contains(head)
    }

    private var rubyFirstWord: String {
        var word = ""
        for c in self {
            if c.isLetter || c == "_" { word.append(c) }
            else { break }
        }
        return word
    }

    func rangeOfAny(_ words: [String]) -> String? {
        for word in words where contains(word) {
            return word
        }
        return nil
    }
}

private let ComplexityEngine_rubyCloserWords = ["end", "class", "module", "begin", "rescue", "ensure"]
private let ComplexityEngine_rubyOpenerWords = ["def", "class", "module", "do", "begin", "if", "unless", "while", "until", "case"]
