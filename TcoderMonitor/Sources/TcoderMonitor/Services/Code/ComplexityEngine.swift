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
        functionsWithIntegrity(in: file).candidates
    }

    /// 与 `functions(in:)` 同一次扫描，额外带回完整性读数。**这是 R2 之后的唯一真入口**，
    /// `functions(in:)` 只是它的投影（既有条目与既有单测都还在按老形状调它）。
    static func functionsWithIntegrity(in file: ScannedSourceFile) -> FunctionScanOutcome {
        let profile = profile(for: file.language)
        guard profile.family != .none, !profile.patterns.isEmpty else { return FunctionScanOutcome() }
        let raw = file.lines.map { $0.text }
        guard !raw.isEmpty else { return FunctionScanOutcome() }

        // RD-07：`.vue` 一份文件住着三种语言。逐行给档案 —— 脚本区按它自己声明的 lang 清洗，
        // 模板 / 样式区整行不进代码统计（内联箭头因此进不了榜，也不再能污染词法状态机）。
        var profiles = Array<LangProfile?>(repeating: profile, count: raw.count)
        var scanProfile = profile
        var mask: [Bool]?
        var outcome = FunctionScanOutcome(codeRegionLineCount: raw.count)
        if profile.scriptRegionOnly, let map = detectVueRegions(raw) {
            let scriptProfile = ComplexityEngine.profile(for: map.scriptLanguage)
            for index in raw.indices {
                let isScript = map.regions[index] == .script
                profiles[index] = isScript ? scriptProfile : nil
            }
            scanProfile = scriptProfile
            mask = map.scriptMask
            outcome.codeRegionLineCount = map.scriptLineCount()
        } else if profile.scriptRegionOnly {
            // 分区认不出来：退回 HEAD 的 `<script` 粗判，**并且把这一格如实说出来**，
            // 而不是悄悄按「没有模板区」处理。
            outcome.vueRegionFallback = true
            mask = computeScriptMask(raw)
        }

        let src = sanitize(raw, profiles: profiles)
        var integrity = src.integrity
        if outcome.vueRegionFallback { integrity.regionFallback = true }
        var scan = Scan(src: src, profile: scanProfile, scriptMask: mask)
        outcome.candidates = scan.run()
        outcome.unboundedSignatureCount = scan.unboundedCount
        outcome.integrity = integrity
        return outcome
    }

    /// 逐行「找签名 → 定边界 → 产出候选」的扫描。原先这 66 行 / CC 20 就是 `functions(in:)` 的整个函数体。
    ///
    /// `line` 的两条推进路经刻意保住：命中签名（哪怕最后因为太短/太长没成候选）就跳到闭合行的
    /// 下一行，其余一切情况只前进一行；命中数达到 `maxCandidatesPerFile` 就地收工。
    struct Scan {
        let src: SanitizedSource
        let profile: LangProfile
        let scriptMask: [Bool]?
        var result: [FunctionCandidate] = []
        var line = 0
        /// 命中签名但边界推不出来的次数（出声用；见 `FunctionScanOutcome.unboundedSignatureCount`）
        var unboundedCount = 0

        mutating func run() -> [FunctionCandidate] {
            while line < src.cleaned.count {
                if result.count >= ComplexityEngine.maxCandidatesPerFile { break }
                if let matched = functionStartingHere() {
                    if let candidate = matched.candidate { result.append(candidate) }
                    line = matched.endLine + 1
                } else {
                    line += 1
                }
            }
            return result
        }

        /// 本行是不是一个函数签名的开头；是的话给出闭合行与（可能不合格的）候选。
        mutating func functionStartingHere() -> (endLine: Int, candidate: FunctionCandidate?)? {
            guard let name = signatureNameHere() else { return nil }
            let boundary = bodyBoundary()
            guard let endLine = boundary.closing else {
                // **放弃了要留名**：以前这里只是 return nil，扫描线前进一行继续，
                // 于是一个边界推不出来的函数在报告里与「这行不是函数」完全一样。
                unboundedCount += 1
                return nil
            }
            // 防御：签名行绝不能越过闭合行，否则下面的 line...signatureEnd 区间会当场 trap
            var signatureEnd = boundary.signatureEnd
            if signatureEnd > endLine { signatureEnd = endLine }

            let count = endLine - line + 1
            guard count >= ComplexityEngine.minFunctionLines, count <= ComplexityEngine.maxFunctionLines
            else { return (endLine, nil) }
            let signature = src.cleaned[line...signatureEnd].joined(separator: " ")
            return (endLine, FunctionCandidate(
                name: name,
                startLine: line + 1,
                lineCount: count,
                parameterCount: ComplexityEngine.parameterCount(from: signature),
                complexity: ComplexityEngine.complexity(ofCleanedLines: Array(src.cleaned[line...endLine]),
                                                        profile: profile)
            ))
        }

        /// 四道廉价闸门 + 签名正则，先便宜后贵，顺序与原实现一致。
        func signatureNameHere() -> String? {
            if line > 0, !src.balancedBefore[line - 1] { return nil }
            if let mask = scriptMask, !mask[line] { return nil }
            let cleanedLine = src.cleaned[line]
            // utf8.count 对原生 Swift String 是 O(1)，utf16.count 会触发转码；这里只是长度门槛
            guard !cleanedLine.isEmpty, cleanedLine.utf8.count <= ComplexityEngine.maxLineLengthForMatch else {
                return nil
            }
            // 廉价预筛：绝大多数语言的签名都必须带 `(`，先挡掉就不必为每行进 NSString/正则循环
            if profile.parenOnEveryPattern, cleanedLine.contains("(") == false { return nil }
            return ComplexityEngine.matchSignature(cleanedLine, profile)
        }

        /// 签名命中之后定函数边界：花括号族 / 缩进族 / Ruby `end` 族各走各的。
        func bodyBoundary() -> (closing: Int?, signatureEnd: Int) {
            switch profile.family {
            case .curly, .shell:
                guard let span = ComplexityEngine.curlyEnd(start: line, src, profile) else { return (nil, line) }
                return (span.closing, span.brace)
            case .indentation:
                let signatureEnd = ComplexityEngine.multiLineSignatureEnd(start: line, src.cleaned,
                                                                         closingChars: [":"])
                return (ComplexityEngine.indentedEnd(start: line, signatureEnd: signatureEnd,
                                                     cleaned: src.cleaned), signatureEnd)
            case .rubyEnd:
                // Ruby 的边界靠同级 `end` 判定，不受跨行签名影响；这里只把签名行对齐，
                // 好让 `def foo(\n a,\n b\n)` 这种跨行参数表也数得出参数。
                let signatureEnd = ComplexityEngine.multiLineSignatureEnd(start: line, src.cleaned,
                                                                          closingChars: [")"])
                return (ComplexityEngine.rubyEnd(start: line, src.cleaned), signatureEnd)
            case .none:
                return (nil, line)
            }
        }
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
        var scan = ParameterListScan(chars: chars, open: open)
        return scan.run()
    }

    /// 三类括号字符的归组。原先这里是 7 个 `case`（每个 `case` 在工具的 CC 口径里都算一次分支），
    /// 换成集合成员判定之后**字符集合一字未改**，只是分支从 21 降到 8。
    static let parameterQuoteStarters: Set<Character> = ["\"", "'"]
    static let parameterOpeners: Set<Character> = ["(", "[", "{"]
    static let parameterClosers: Set<Character> = [")", "]", "}"]

    /// 参数表逐字符扫描：顶层逗号计数，括号 / 尖括号 / 字符串各自配平。
    struct ParameterListScan {
        let chars: [Character]
        let open: Int
        var index: Int
        var depth = 0
        var angle = 0
        var commas = 0
        var hasContent = false
        var quote: Character?

        init(chars: [Character], open: Int) {
            self.chars = chars
            self.open = open
            index = open
        }

        mutating func run() -> Int {
            while index < chars.count {
                if let closed = step() { return closed }
            }
            return ComplexityEngine.parameterSegmentCount(commas: commas, hasContent: hasContent)
        }

        /// 返回非 nil 表示参数表在这个字符上闭合（原实现就地 `return parameterSegmentCount`）。
        mutating func step() -> Int? {
            let c = chars[index]
            if let q = quote { return insideQuote(c, q) }
            index += 1
            if ComplexityEngine.parameterQuoteStarters.contains(c) {
                quote = c
                hasContent = true
            } else if ComplexityEngine.parameterOpeners.contains(c) {
                return openBracket()
            } else if ComplexityEngine.parameterClosers.contains(c) {
                return closeBracket()
            } else if c == "<" {
                return openAngle()
            } else if c == ">" {
                return closeAngle()
            } else if c == "," {
                countTopLevelComma()
            } else if !c.isWhitespace {
                hasContent = true
            }
            return nil
        }

        /// 字符串字面量内部：转义一次跳两格。
        mutating func insideQuote(_ c: Character, _ q: Character) -> Int? {
            if c == "\\" { index += 2; return nil }
            if c == q { quote = nil }
            index += 1
            return nil
        }

        mutating func openBracket() -> Int? {
            depth += 1
            if depth > 1 { hasContent = true }
            return nil
        }

        mutating func closeBracket() -> Int? {
            depth -= 1
            guard depth <= 0 else { return nil }
            return ComplexityEngine.parameterSegmentCount(commas: commas, hasContent: hasContent)
        }

        mutating func openAngle() -> Int? {
            if depth <= 1, angle == 0, index > open { angle += 1 }
            hasContent = true
            return nil
        }

        mutating func closeAngle() -> Int? {
            if angle > 0 { angle -= 1 }
            hasContent = true
            return nil
        }

        mutating func countTopLevelComma() {
            guard depth == 1 && angle == 0 else { return }
            commas += 1
        }
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
        guard let start = objectiveCSelectorStart(chars) else { return nil }
        return countSelectorColons(chars, from: start)
    }

    /// 形状判定：`-`/`+` 开头、紧跟返回类型括号、再跟标识符。不是这个形状返回 nil 走通用逻辑。
    static func objectiveCSelectorStart(_ chars: [Character]) -> Int? {
        var index = skipSpaces(chars, from: 0)
        guard index < chars.count, chars[index] == "-" || chars[index] == "+" else { return nil }
        index = skipSpaces(chars, from: index + 1)
        guard index < chars.count, chars[index] == "(" else { return nil }
        guard let close = matchingClose(chars, open: index) else { return nil }
        index = skipSpaces(chars, from: close + 1)
        // 选择器必须以标识符开头（`- (void)foo:`）；`- (int)a - (int)b` 这类表达式不是签名
        guard index < chars.count, chars[index].isLetter || chars[index] == "_" else { return nil }
        return index
    }

    /// 顶层 `:` 的个数就是关键字选择器的参数个数（嵌套括号里的冒号不算）。
    static func countSelectorColons(_ chars: [Character], from start: Int) -> Int {
        var depth = 0
        var colons = 0
        var index = start
        while index < chars.count {
            let c = chars[index]
            if parameterOpeners.contains(c) {
                depth += 1
            } else if parameterClosers.contains(c) {
                if depth > 0 { depth -= 1 }
            } else if c == ":", depth == 0 {
                colons += 1
            }
            index += 1
        }
        return colons
    }
}
