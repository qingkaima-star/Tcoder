import Foundation

// OWNER: Workstream A (静态代码分析) —— ComplexityCounting
//
// 从 ComplexityEngine.swift 拆出，只为守住本工作流的红线（800 行以上的文件不得增加）：
// 语义、阈值、判定顺序一字未改。原先的 `private` 跨文件后必须放宽到模块内可见（internal），
// 除可见性外没有任何变化；ComplexityEngine 本身仍是唯一的入口。
//
// 圈复杂度计算：分支关键字与 && / || / 三元 / ?? 的逐字符计数。

extension ComplexityEngine {
    // MARK: Complexity

    /// 所有可能出现在关键字正则里的词；具体语言再按 branchKeywords 取子集。
    /// 注意 `require` 不在列：它在任何受支持语言里都不是判定构造
    /// （JS/TS 的 `require("x")` 是模块导入、PHP/Ruby 的是 include），
    /// 早先收进关键字会让每个 `const fs = require("fs")` 凭空 +1 复杂度。
    static let allBranchKeywords: Set<String> = [
        "else if", "if", "elif", "elseif", "foreach", "for", "while", "until",
        "case", "when", "catch", "except", "rescue", "guard",
        "loop", "match", "repeat", "and", "or",
    ]

    /// 单一关键字正则：一次匹配 + 关键字集合过滤，比按语言现编译正则快得多。
    static let branchKeywordExpression = try? NSRegularExpression(
        pattern: "\\b(?:else[ \\t]+if|elseif|elif|foreach|for|while|until|case|when|catch|except"
            + "|rescue|guard|loop|match|repeat|and|or|if)\\b",
        options: []
    )

    static func complexity(ofCleanedLines lines: [String], profile: LangProfile) -> Int {
        var total = 1
        let keywords = profile.branchKeywords.isEmpty ? allBranchKeywords : profile.branchKeywords
        for rawLine in lines {
            // 预处理指令行（#if DEBUG / #include）不计入，避免平台分支被当成逻辑分支。
            // 必须跳过行首空白再判断：真实代码里的 `#if` 绝大多数带缩进
            // （Swift 的 #if os(...) 在函数体里、ObjC 的 #ifdef 在方法里），
            // 只看 first 的话 `    #if A && B` 会凭空给函数加一次 if。
            guard let head = rawLine.firstIndex(where: { $0 != " " && $0 != "\t" }) else { continue }
            if rawLine[head] == "#" { continue }
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
    static func branchSymbols(in rawLine: String, profile: LangProfile) -> Int {
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
    static func isKeywordAt(_ chars: [Character], _ at: Int, _ keyword: String) -> Bool {
        let letters = Array(keyword)
        guard !letters.isEmpty, at + letters.count <= chars.count else { return false }
        guard chars[at...].prefix(letters.count).elementsEqual(letters) else { return false }
        if at > 0, isIdentifierCharacter(chars[at - 1]) { return false }
        let next = at + letters.count
        if next < chars.count, isIdentifierCharacter(chars[next]) { return false }
        return true
    }

    static func isIdentifierCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }
}
