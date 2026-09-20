import Foundation

// OWNER: Workstream A (静态代码分析) —— FunctionRecognition
//
// 从 ComplexityEngine.swift 拆出，只为守住本工作流的红线（800 行以上的文件不得增加）：
// 语义、阈值、判定顺序一字未改。原先的 `private` 跨文件后必须放宽到模块内可见（internal），
// 除可见性外没有任何变化；ComplexityEngine 本身仍是唯一的入口。
//
// 函数签名匹配与函数边界：大括号族 / 缩进族 / Ruby end 族，以及 Vue <script> 区域掩码。

extension ComplexityEngine {
    // MARK: Signature matching

    static func matchSignature(_ line: String, _ profile: LangProfile) -> String? {
        let text = line as NSString
        let range = NSRange(location: 0, length: text.length)
        for pattern in profile.patterns {
            guard patternApplies(pattern, to: line) else { continue }
            guard let match = pattern.expression.firstMatch(in: line, options: [], range: range) else { continue }
            if let name = signatureName(from: match, text: text, pattern: pattern) { return name }
        }
        return nil
    }

    /// 廉价预筛：只有声明了 `needsParen` 的 pattern 才要求行里有左括号（Ruby / shell 的签名可以不带）。
    static func patternApplies(_ pattern: SignaturePattern, to line: String) -> Bool {
        guard pattern.needsParen else { return true }
        return line.contains("(")
    }

    /// 正则命中之后能不能真的收下这个名字。原先落在各判定上的 `continue`
    /// 一律变成返回 nil —— 调用方拿到 nil 就是「换下一条 pattern 再试」，语义相同。
    static func signatureName(from match: NSTextCheckingResult, text: NSString,
                              pattern: SignaturePattern) -> String? {
        let name = functionName(from: match, text: text, pattern: pattern)
        // 原实现在这里 `continue`：带 namePrefix 的 pattern 捕获组为空就不是命中
        if name.isEmpty { return nil }
        if isReservedName(name) { return nil }
        // 名字之前必须真的有什么：注解、修饰符或返回类型。
        // cStyle 的返回类型组是 (?:…) 非捕获的，拿不到「组 2」，所以这里直接用
        // 「组 1 之前的前缀」判定：前缀为空说明这是 `foo(bar)` 之类的裸调用行。
        let headText = (groupText(text, match, 1, prefixOnly: true) ?? "").trimmingCharacters(in: .whitespaces)
        // 类型声明不是函数。C++ 的 `class PROTOBUF_EXPORT PROTOBUF_ALIGNAS(8)`、Kotlin 的
        // `data class Foo(val x: Int)`、Java 的 `public class Foo(int x)` 都长得像
        // 「返回类型 + 名字 + 括号」，一旦被吃下来，边界会一路走到类体的 `}` ——
        // protobuf 真实语料里实测到一个类声明被记成 626 行 / CC=43 的「超高复杂度函数」。
        if isTypeDeclaration(headText) { return nil }
        guard hasRequiredHead(match, text: text, pattern: pattern, headText: headText, name: name) else { return nil }
        return name
    }

    /// C 系 / Kotlin 那几条 pattern 额外要求「名字之前有类型」或「有修饰符」，缺了就不是定义。
    static func hasRequiredHead(_ match: NSTextCheckingResult, text: NSString,
                                pattern: SignaturePattern, headText: String, name: String) -> Bool {
        if pattern.requiresTypeToken {
            let typeToken = (groupText(text, match, 2) ?? "").trimmingCharacters(in: .whitespaces)
            return typeToken.isEmpty == false
        } else if pattern.requiresModifierWhenNoType {
            return headText.isEmpty == false || name.contains("::")
        }
        return true
    }

    /// 捕获组 1 折成函数名。
    /// 可选捕获组没参与匹配时 range(at:) 返回 {NSNotFound, 0}，直接喂给 substring 会抛
    /// NSInvalidArgumentException（真实崩过），一律走安全取值；没命名就是匿名函数。
    static func functionName(from match: NSTextCheckingResult, text: NSString,
                             pattern: SignaturePattern) -> String {
        let raw = trimQuotes(groupText(text, match, 1) ?? "")
        if let prefix = pattern.namePrefix {
            // 带 namePrefix 的 pattern（ObjC 方法、JS 成员）名字为空就不是命中，交给调用方 continue
            return raw.isEmpty ? "" : prefix + raw
        }
        return raw.isEmpty ? "<anonymous>" : raw
    }

    /// prefixOnly = true 时取「捕获组 1 之前的那段文本」，用于检查行首有没有修饰符。
    static func groupText(
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
    static func trimQuotes(_ raw: String) -> String {
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
    /// 名字之前出现「独立的类型声明关键字」→ 这行是类/结构体/枚举声明，不是函数定义。
    /// 两条必要的豁免，都是从真实语料里来的：
    /// 1) 前缀里有 `func`/`fun`/`def`/`fn`/`sub`/`procedure` 这类定义关键字时一律放行，
    ///    否则 Swift 的 `@objc class func foo()` 会被误杀（`class` 在那里是方法修饰符）；
    /// 2) 前缀里有 `*` 或 `&` 时放行，那是 C/C++ 的返回类型：
    ///    `static struct foo *get(void) {` 是真函数，不是 `struct foo` 声明。
    static let typeDeclarationKeywords: Set<String> = [
        "class", "struct", "enum", "union", "interface", "protocol", "record", "trait",
        "impl", "namespace", "typedef", "annotation", "actor", "object", "module",
    ]
    static let definitionKeywords: Set<String> = [
        "func", "fun", "def", "fn", "sub", "procedure", "lambda",
    ]

    static func isTypeDeclaration(_ textBeforeName: String) -> Bool {
        if textBeforeName.contains("*") || textBeforeName.contains("&") { return false }
        let tokens = textBeforeName.split { !($0.isLetter || $0.isNumber || $0 == "_") }
        var sawDefinition = false
        var sawDeclaration = false
        for token in tokens {
            let word = String(token)
            if definitionKeywords.contains(word) { sawDefinition = true }
            if typeDeclarationKeywords.contains(word) { sawDeclaration = true }
        }
        return sawDeclaration && !sawDefinition
    }

    static func isReservedName(_ name: String) -> Bool {
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

    static func curlyEnd(start: Int, _ src: SanitizedSource, _ profile: LangProfile) -> (closing: Int, brace: Int)? {
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

    /// 多行签名的结束行（缩进族 Python + Ruby 都用到）：
    /// Python `def f(` 之后参数逐行铺开时，收尾的 `):` 往往缩进得和 `def` 同级甚至更靠外，
    /// 按缩进扫块会在签名中间截断（实测 67 行的函数被报成 2 行、CC 从 16 掉到 1、参数从 6 掉到 0）。
    /// 规则：括号配平回到 0 **且**该行以语言的签名收尾符结尾（Python 是 `:`、Ruby 是 `)`）。
    /// 单行签名当场返回 start，行为与修复前完全一致。
    /// 关键约束：这两种语言只在括号没配平时才换行，所以一旦配平而收尾符又不匹配
    /// （`def f(a): return 1` 这种一行式函数）必须立刻退回 start，
    /// 绝不能继续往后找——那会把下一条语句整段并进本函数签名。
    static func multiLineSignatureEnd(start: Int, _ cleaned: [String], closingChars: [Character]) -> Int {
        let upper = min(cleaned.count - 1, start + maxSignatureContinuationLines)
        var depth = 0
        var cursor = start
        while cursor <= upper {
            depth += bracketDelta(cleaned[cursor])
            if depth <= 0 {
                // whitespacesAndNewlines：调用方偶尔会传带 \r 的行（CRLF 直通），
                // 只裁空白的话收尾符判定会被行尾 \r 打断
                guard let last = cleaned[cursor].trimmingCharacters(in: .whitespacesAndNewlines).last,
                      closingChars.contains(last) else { return start }
                return cursor
            }
            cursor += 1
        }
        return start
    }

    static func bracketDelta(_ text: String) -> Int {
        var delta = 0
        for c in text {
            switch c {
            case "(", "[", "{": delta += 1
            case ")", "]", "}": delta -= 1
            default: break
            }
        }
        return delta
    }

    /// 从签名结束行的下一行起，取到「缩进重新回到 def 那一行或更靠外」为止的整块。
    /// signatureEnd 之后一行缩进体都没有（抽象声明 / 误匹配）就不算函数，退回 nil。
    static func indentedEnd(start: Int, signatureEnd: Int, cleaned: [String]) -> Int? {
        let indent = indentation(of: cleaned[start])
        var lastBody = signatureEnd
        var cursor = signatureEnd + 1
        while cursor < cleaned.count, cursor - start <= maxBodyLookahead {
            let line = cleaned[cursor]
            if line.first == nil { cursor += 1; continue }
            if indentation(of: line) <= indent { break }
            lastBody = cursor
            cursor += 1
        }
        return lastBody == signatureEnd ? nil : lastBody
    }

    /// Ruby：只有和 `def` 同级（或更靠外）的 `end` 才是函数收尾。
    /// 更深一层的 `end` 关的是更深的块，与本函数边界无关，不需要计数；
    /// 同级又开出 def/class/module 说明上一个 end 被漏掉了，直接放弃候选而不是把后面全吞进来。
    static func rubyEnd(start: Int, _ cleaned: [String]) -> Int? {
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

    static func indentation(of line: String) -> Int {
        var width = 0
        for c in line {
            if c == " " { width += 1 }
            else if c == "\t" { width += 4 }
            else { break }
        }
        return width
    }

    static func computeScriptMask(_ cleaned: [String]) -> [Bool] {
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

    // MARK: Ruby block helpers

    /// 与 def 同级出现就意味着上一个块没闭合（rescue/ensure 不在此列，它们属于 def 自己）
    static let rubySiblingBlockWords = ["def", "class", "module", "begin"]
}

// MARK: - Ruby 行首词判定（从 ComplexityEngine.swift 一起搬来；原先是本文件 private）

extension String {

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
