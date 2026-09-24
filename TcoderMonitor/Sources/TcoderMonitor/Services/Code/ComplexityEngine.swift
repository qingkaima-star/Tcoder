import Foundation

// MARK: - Public model

struct FunctionCandidate: Sendable {
    var name: String
    var startLine: Int      // 1-based，函数签名所在行
    var lineCount: Int      // 函数跨度（签名行到闭合行，**含**嵌套函数体）
    var parameterCount: Int
    /// 圈复杂度，>= 1。口径见 `ComplexityEngine.Scan`（RD-08）：
    /// **只算本函数自己那部分体**，直接嵌套的具名函数体已按行挖掉、各自单列一条。
    var complexity: Int
    /// 本函数体内单列出去的嵌套具名函数个数（0 = 这条的数字就是它自己的全部）
    var nestedFunctionCount: Int = 0
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
    /// RD-79：判断「本条语句到哪一行说完」最多往后看多少行。
    /// 比 `maxSignatureLookahead` 宽，因为铺开的花式写法（点号链、三元、逐行参数表）
    /// 天然就是好几行；超出这个窗口一律不判（宁缺毋滥，交回「边界推不出来」那句出声）。
    static let maxStatementLookahead = 16
    /// 嵌套具名函数下钻的最大深度：超过就不再展开，其判定并入直接外层，
    /// 并通过 `FunctionScanOutcome.nestedDepthTruncatedCount` 出声（R2 / RD-08）。
    /// 为什么要有上限：每下一层就要把上一层的体再扫一遍，深度无界时病态夹具会打成 N×深度。
    static let maxNestedFunctionScanDepth = 8
    /// 缩进签名的跨行窗口：只在「括号还没配平」时往后走，配平即停，放大窗口没有误并风险
    static let maxSignatureContinuationLines = 64
    /// 超过该长度的行视为压缩产物/数据行，不做签名匹配
    static let maxLineLengthForMatch = 4_000
    /// 无括号语言的函数体最大跨度
    static let maxBodyLookahead = 4_000


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

