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

    /// 少于 2 行的候选一律丢弃：`func f() { return 1 }` 这类单行函数不可能成为风险热点。
    /// 代价是要在 UI 上说清口径 —— Go/C/Ruby 的生成代码里单行函数占比很高
    /// （实测 `go/ast/ast.go` 174 个 `^func` 里 143 个是单行体，`simd/archsimd/ops_amd64.go`
    /// 的 1597 个 `func` 全是无函数体的生成声明），因此 `averageFunctionLength` 只统计 ≥2 行的函数。
    static let minFunctionLines = 2
    static let maxFunctionLines = 20_000
    static let maxCandidatesPerFile = 20_000
    /// 多行签名时向后找第一个 `{` 的最大跨度
    static let maxSignatureLookahead = 8
    /// 缩进签名的跨行窗口：只在「括号还没配平」时往后走，配平即停，放大窗口没有误并风险
    static let maxSignatureContinuationLines = 64
    /// 超过该长度的行视为压缩产物/数据行，不做签名匹配
    static let maxLineLengthForMatch = 4_000
    /// 无括号语言的函数体最大跨度
    static let maxBodyLookahead = 4_000

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
                signatureEnd = multiLineSignatureEnd(start: line, src.cleaned, closingChars: [":"])
                closing = indentedEnd(start: line, signatureEnd: signatureEnd, cleaned: src.cleaned)
            case .rubyEnd:
                // Ruby 的边界靠同级 `end` 判定，不受跨行签名影响；这里只把签名行对齐，
                // 好让 `def foo(\n a,\n b\n)` 这种跨行参数表也数得出参数。
                signatureEnd = multiLineSignatureEnd(start: line, src.cleaned, closingChars: [")"])
                closing = rubyEnd(start: line, src.cleaned)
            case .none:
                break
            }
            guard let endLine = closing else { line += 1; continue }
            // 防御：签名行绝不能越过闭合行，否则下面的 line...signatureEnd 区间会当场 trap
            if signatureEnd > endLine { signatureEnd = endLine }

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
        // Objective-C 的关键字选择器不是「一个括号里的逗号列表」，先按形状分流
        if let objc = objectiveCSelectorParameterCount(chars) { return objc }
        guard var open = chars.firstIndex(of: "(") else { return 0 }
        // Go 方法的接收者括号排在参数表之前，不跳过的话每个方法都被算成 1 个参数
        if isGoReceiverParen(chars, open: open), let next = nextParenOpen(chars, after: open) {
            open = next
        }
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

    static func parameterSegmentCount(commas: Int, hasContent: Bool) -> Int {
        guard hasContent else { return 0 }
        return commas + 1
    }

    /// `func (recv) name(` —— 只有 Go 方法满足这个形状：左括号之前仅仅是一个 `func`，
    /// 右括号之后紧跟「标识符 + 左括号」。Swift 的 `func f(a: Int) -> (Int, String)`
    /// （返回类型是元组）、C++ 的 `size() const`、JS 的 `function (a)` 都对不上后半截，
    /// 因此不会被误判成接收者。
    static func isGoReceiverParen(_ chars: [Character], open: Int) -> Bool {
        guard open < chars.count else { return false }
        let head = String(chars[0..<open]).trimmingCharacters(in: .whitespaces)
        guard head == "func" else { return false }
        guard let close = matchingClose(chars, open: open) else { return false }
        var index = skipSpaces(chars, from: close + 1)
        guard index < chars.count, isIdentifierCharacter(chars[index]) else { return false }
        while index < chars.count, isIdentifierCharacter(chars[index]) { index += 1 }
        index = skipSpaces(chars, from: index)
        return index < chars.count && chars[index] == "("
    }

    static func nextParenOpen(_ chars: [Character], after: Int) -> Int? {
        guard let close = matchingClose(chars, open: after) else { return nil }
        var index = close + 1
        while index < chars.count {
            if chars[index] == "(" { return index }
            index += 1
        }
        return nil
    }

    static func skipSpaces(_ chars: [Character], from: Int) -> Int {
        var index = from
        while index < chars.count, chars[index] == " " || chars[index] == "\t" { index += 1 }
        return index
    }

    /// 第 open 个左括号配平的右括号位置（括号/方括号/花括号一起算深度，字符串内容跳过）。
    static func matchingClose(_ chars: [Character], open: Int) -> Int? {
        guard open < chars.count, chars[open] == "(" else { return nil }
        var depth = 0
        var index = open
        var quote: Character?
        while index < chars.count {
            let c = chars[index]
            if let q = quote {
                if c == "\\", index + 1 < chars.count { index += 2; continue }
                if c == q { quote = nil }
                index += 1
                continue
            }
            switch c {
            case "\"", "'": quote = c
            case "(", "[", "{": depth += 1
            case ")", "]", "}":
                depth -= 1
                if depth <= 0 { return index }
            default: break
            }
            index += 1
        }
        return nil
    }

    /// Objective-C 方法 `- (instancetype)initWithName:(NSString *)name flag:(BOOL)flag`：
    /// 第一个括号是**返回类型**，参数个数等于关键字选择器里顶层 `:` 的个数。
    /// 只对 `-`/`+` 开头、紧跟返回类型括号、再跟标识符的形状生效，其余返回 nil 走通用逻辑。
    static func objectiveCSelectorParameterCount(_ chars: [Character]) -> Int? {
        var index = skipSpaces(chars, from: 0)
        guard index < chars.count, chars[index] == "-" || chars[index] == "+" else { return nil }
        index = skipSpaces(chars, from: index + 1)
        guard index < chars.count, chars[index] == "(" else { return nil }
        guard let close = matchingClose(chars, open: index) else { return nil }
        index = skipSpaces(chars, from: close + 1)
        // 选择器必须以标识符开头（`- (void)foo:`）；`- (int)a - (int)b` 这类表达式不是签名
        guard index < chars.count, chars[index].isLetter || chars[index] == "_" else { return nil }
        var depth = 0
        var colons = 0
        while index < chars.count {
            let c = chars[index]
            if c == "(" || c == "[" || c == "{" {
                depth += 1
            } else if c == ")" || c == "]" || c == "}" {
                if depth > 0 { depth -= 1 }
            } else if c == ":", depth == 0 {
                colons += 1
            }
            index += 1
        }
        return colons
    }
}
