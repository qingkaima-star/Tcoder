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
    ///
    /// **编不出来必须留名**（批次 P7-B 2-7）：下面 `complexity(ofCleanedLines:)` 里的
    /// `if let` 一旦走 else，全仓的分支关键字就一条都不计 —— 圈复杂度全线偏低、
    /// 风险页变绿、复杂度分量趋满分，而界面上一句提示都没有。
    /// 这条模式是编译期字面量，坏掉属于编程错误，不许伪装成"这个项目就是没分支"。
    static let branchKeywordExpression: NSRegularExpression? = {
        let pattern = "\\b(?:else[ \\t]+if|elseif|elif|foreach|for|while|until|case|when|catch|except"
            + "|rescue|guard|loop|match|repeat|and|or|if)\\b"
        guard let made = try? NSRegularExpression(pattern: pattern, options: []) else {
            ComplexityEngine.RuleDegradeLedger.record("分支关键字规则未能编译")
            return nil
        }
        return made
    }()

    static func complexity(ofCleanedLines lines: [String], profile: LangProfile) -> Int {
        var total = 1
        var awaitingTernaryColon = false
        for rawLine in lines {
            // 预处理指令行（#if DEBUG / #include）不计入，避免平台分支被当成逻辑分支。
            // 必须跳过行首空白再判断：真实代码里的 `#if` 绝大多数带缩进
            // （Swift 的 #if os(...) 在函数体里、ObjC 的 #ifdef 在方法里），
            // 只看 first 的话 `    #if A && B` 会凭空给函数加一次 if。
            guard let head = rawLine.firstIndex(where: { $0 != " " && $0 != "\t" }) else { continue }
            if rawLine[head] == "#" { continue }
            total += keywordBranchCount(in: rawLine, profile: profile)
            let scan = branchSymbolScan(in: rawLine, profile: profile)
            // RD-80：上一行留下一枚"在等冒号的 `?`"，而这一行正是以 `:` 开头 ⇒ 补那一分。
            // 空行与预处理行不撤销这个待配对状态（清洗后的 `? a` / 空行 / `: b` 是同一句话）。
            if awaitingTernaryColon, rawLine[head] == ":" { total += 1 }
            total += scan.count
            awaitingTernaryColon = scan.awaitingTernaryColon
        }
        return max(1, total)
    }

    /// 关键字那一半（`if` / `else if` / `for` / `case`…）。RD-09 的两道语法位置判据原样保留。
    static func keywordBranchCount(in rawLine: String, profile: LangProfile) -> Int {
        guard let re = branchKeywordExpression else { return 0 }
        let keywords = profile.branchKeywords.isEmpty ? allBranchKeywords : profile.branchKeywords
        let text = rawLine as NSString
        let matches = re.matches(in: rawLine, options: [],
                                 range: NSRange(location: 0, length: text.length))
        var hit = 0
        for match in matches {
            var word = text.substring(with: match.range)
            // `else   if`（多个空白）也要落到 "else if" 这个关键字上
            if word.hasPrefix("else") { word = "else if" }
            guard keywords.contains(word) else { continue }
            // 反向也要守住：`ifLet(` / `.ifLet(` / `switchMap(` 这些**名字里含关键字前缀**的
            // 写法本来就命不中 `\b…\b`，这里不新增任何"整行不数"的口子。
            guard isControlFlowPosition(text, match.range) else { continue }
            hit += 1
        }
        return hit
    }

    /// 关键字命中处**是不是真的在写判定**。两条判据，各对应一种被误算成控制流的形状：
    /// 1. **成员访问位**：`box.if` / `x.else` / `list.case` —— 点号后面那个词是属性名 / 方法名。
    ///    正则的 `\b` 管不住点号（`.` 不是标识符字符），所以 `.if` 以前白送一次复杂度。
    /// 2. **标签位**：`guardElse(if: x)` / `{ if: true }` —— 关键字之后紧跟冒号（中间只允许空白）
    ///    就是参数标签 / 对象键名，不是判定。真的 `if` / `case` 后面跟的是条件表达式，
    ///    冒号要么没有要么隔着一整个条件（`if (a): ` 里冒号前还有 `)`，判据 2 命不中）。
    static func isControlFlowPosition(_ text: NSString, _ range: NSRange) -> Bool {
        if range.location > 0, text.character(at: range.location - 1) == Self.dotUnichar { return false }
        var index = NSMaxRange(range)
        while index < text.length {
            let c = text.character(at: index)
            if c == Self.spaceUnichar || c == Self.tabUnichar { index += 1; continue }
            return c != Self.colonUnichar
        }
        return true
    }

    static let dotUnichar: unichar = 0x2E      // "."
    static let colonUnichar: unichar = 0x3A    // ":"
    static let spaceUnichar: unichar = 0x20
    static let tabUnichar: unichar = 0x09

    /// 三元 `?` 的判定是纯启发式：Swift/Kotlin/Dart 里 `Int?` 满天飞，所以**同一行内**额外要求
    /// 「冒号出现在该 `?` 之后」，否则 `let x: Int? = 5` 会被误计一次。
    /// 跨行写法（RD-80）靠的是**另一条证据**：整行一个冒号都没有，且紧接的下一行以 `:` 开头
    /// ——由 `complexity(ofCleanedLines:profile:)` 那对相邻行配对，这一行只负责出声说"我在等冒号"。
    static func branchSymbolScan(in rawLine: String, profile: LangProfile) -> BranchSymbolScan {
        // 绝大多数代码行既没有 && / || 也没有 ?，先零成本过一遍再决定要不要转 [Character]
        guard rawLine.contains(where: { $0 == "?" || $0 == "&" || $0 == "|" }) else {
            return BranchSymbolScan(chars: [], profile: profile)   // 空扫描：0 分、不等冒号
        }
        var scan = BranchSymbolScan(chars: Array(rawLine), profile: profile)
        _ = scan.run()
        return scan
    }

    /// `branchSymbols` 的逐字符扫描。原先是一个 46 行、CC 23 的 while，
    /// 现在按职责拆成 `step` / `eatLogicalOperatorPair` / `questionMarkGain` / `noteReturnKeyword`。
    ///
    /// **顺序敏感的语义全部保留**，逐条对着原实现核过：
    /// - `&&` / `||` 的短路 `index += 2` 之后不再走后面的分支（原 `continue`）；
    /// - `?` 命中 `??` / `?.` 时也是 `index += 2`，其余 `?` 形态只前进 1；
    /// - `hasAssignment` / `hasParen` / `lastColon` 是**整行前缀无关**的量（原实现在主循环之前
    ///   先整行扫一遍算出来的），放进 `init` 保持同一口径；
    /// - `hasReturn` 则**相反**，是前缀量：原实现在主循环里就地置位，所以 `return` 写在 `?`
    ///   后面时撑不起三元判定。这里仍然由 `step` 每走一格更新一次，行为一字不差。
    struct BranchSymbolScan {
        let chars: [Character]
        let profile: LangProfile
        var index = 0
        var count = 0
        var lastColon = -1
        var hasAssignment = false
        var hasParen = false
        var hasReturn = false
        /// RD-80：这一行有一枚 `?` 除"本行没有冒号可配"之外全部满足三元形状 ⇒ 交给调用方去配下一行。
        var awaitingTernaryColon = false

        init(chars: [Character], profile: LangProfile) {
            self.chars = chars
            self.profile = profile
            for (offset, c) in chars.enumerated() where c == ":" { lastColon = offset }
            for c in chars {
                if c == "=" { hasAssignment = true }
                else if c == "(" { hasParen = true }
            }
        }

        /// 行内还有下一个字符吗（`??` / `?.` / `&&` 这类都要看后面一格）。
        func hasSecondCharacter(after offset: Int) -> Bool { offset + 1 < chars.count }

        /// 逐字符扫完整行，返回判定符号总数。
        mutating func run() -> Int {
            while index < chars.count {
                step()
            }
            return count
        }

        /// 原来 while 的循环体：三件事按原顺序各成一格，谁命中谁负责推进 index。
        mutating func step() {
            let c = chars[index]
            if eatLogicalOperatorPair(c) { return }
            if c == "?" {
                index += questionMarkAdvance()
                return
            }
            noteReturnKeyword(c)
            index += 1
        }

        /// `&&` / `||`：命中记 1 分并吃掉两个字符。返回 false 表示这里不是逻辑运算符。
        mutating func eatLogicalOperatorPair(_ c: Character) -> Bool {
            guard profile.countsLogicalSymbols, c == "&" || c == "|",
                  hasSecondCharacter(after: index), chars[index + 1] == c else { return false }
            count += 1
            index += 2
            return true
        }

        /// `?` 的四种形态（`??` / `?.` / 被前一个 `?` 吃掉 / 三元），返回本次推进的字符数。
        mutating func questionMarkAdvance() -> Int {
            if profile.countsNullCoalescing, hasSecondCharacter(after: index),
               chars[index + 1] == "?" {
                count += 1
                return 2
            }
            // `?.` 可选链本身就是一次判定分支
            if profile.countsOptionalChaining, hasSecondCharacter(after: index),
               chars[index + 1] == "." {
                count += 1
                return 2
            }
            if hasSecondCharacter(after: index), chars[index + 1] == "." { return 1 }
            if index > 0, chars[index - 1] == "?" { return 1 }
            if countsAsTernary() { count += 1 }
            else if ternaryAwaitsNextLine() { awaitingTernaryColon = true }
            return 1
        }

        /// 三元判定：`?` 后要有空白、该行后面还有冒号、且行里出现过赋值 / 括号 / return。
        func countsAsTernary() -> Bool {
            guard hasSecondCharacter(after: index),
                  chars[index + 1] == " " || chars[index + 1] == "\t" else { return false }
            guard profile.countsTernary, lastColon > index else { return false }
            return hasAssignment || hasReturn || hasParen
        }

        /// RD-80：同一行配不到冒号，不等于这句话没有判定——`? a` 换行 `: b` 是同一个三元。
        /// 这里的证据与 `countsAsTernary` **不是同一条**：要求整行一个冒号都没有（`lastColon < 0`，
        /// 所以 `let x: Int? = 5` 那种可空类型不会被算成"在等冒号"），且这枚 `?` 后面是空白
        /// 或者它就在行尾。真正加那一分由调用方在下一行以 `:` 开头时做（见 `complexity(ofCleanedLines:profile:)`）。
        /// 已知限度：只配**紧接的下一行**，`? a` 与 `: b` 之间隔了别的语句就放弃——
        /// 要按语法真找配对得先做表达式解析，那是另一个量级的活儿。
        func ternaryAwaitsNextLine() -> Bool {
            guard profile.countsTernary, lastColon < 0 else { return false }
            if index + 1 == chars.count { return true }
            return chars[index + 1] == " " || chars[index + 1] == "\t"
        }

        /// 只在还没见过 return 时探测一次，避免每格都跑一遍标识符边界检查（原实现同一条短路）。
        mutating func noteReturnKeyword(_ c: Character) {
            guard c == "r", hasReturn == false, isKeywordAt(chars, index, "return") else { return }
            hasReturn = true
        }
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
