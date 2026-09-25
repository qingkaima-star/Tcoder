import Foundation

// OWNER: Workstream A (静态代码分析) —— LanguageProfiles
//
// 从 ComplexityEngine.swift 拆出，只为守住本工作流的红线（800 行以上的文件不得增加）：
// 语义、阈值、判定顺序一字未改。原先的 `private` 跨文件后必须放宽到模块内可见（internal），
// 除可见性外没有任何变化；ComplexityEngine 本身仍是唯一的入口。
//
// 语言档案：家族、注释定界符、分支关键字子集，以及签名正则的编译缓存。

extension ComplexityEngine {
    // MARK: Language profiles

    enum BodyFamily {
        case curly
        case indentation
        case rubyEnd
        case shell
        case none
    }

    struct SignaturePattern {
        var expression: NSRegularExpression?
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

    struct LangProfile {
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
        /// 归一化之后的语言名。**逐行换档案时要靠它判断"是不是换了语言"**：
        /// Vue 的 `<script>` / `<template>` / `<style>` 三个区域各有各的词法，
        /// 跨区域时必须把上一层未闭合的定界符结算掉（R2，RD-07）。
        var languageKey = ""
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
        /// 只有 JS/TS/Vue 有正则字面量这一档（R2，RD-06 夹具 4）：
        /// `/`.*\$\{(/` 里的反引号与 `${` 都是正则内容，不是模板串开头。
        /// 判定保守 —— 本行内配不上对就退回普通字符，绝不吞行。
        var regexLiterals = false
        /// 只有 JS/TS/Vue 的箭头函数可以**不带花括号**（`const f = (x) => x + 1`，RD-79）。
        /// 这一档决定：签名命中而本条语句里没有 `{` 时，是去接它的表达式体，还是照旧判"边界推不出来"。
        var arrowExpressionBody = false
    }

    /// 正则编译缓存。签名 pattern 是热点：每个文件都要走一遍 profile → 每条 pattern 建一个
    /// NSRegularExpression，绝不能反复编译。NSCache 本身线程安全，跨 Task.detached 并发读写
    /// 没有数据竞争；两个线程同时 miss 只会各编译一次、后写覆盖，结果等价。
    nonisolated(unsafe) private static let patternCache = NSCache<NSString, NSRegularExpression>()

    /// 识别规则没能编译的台账。
    ///
    /// 存在理由（批次 P7-B 2-6/2-7，用户口径「不能有假数据」）：正则坏了时，
    /// 下面的 `cache` 原本退回一个"永不匹配"的表达式、`branchKeywordExpression` 退回 nil，
    /// 于是函数数算成 0、分支一条不计。**0 在界面上读起来就是"这个仓库没有函数"**，
    /// 而真话是"我们的规则没跑起来"。缺证据不得冒充结论，所以：
    /// ① 那个"永不匹配"的字面量已从仓里绝迹（`cache` 现在返回 Optional）；
    /// ② 每次降级都记进这本台账，由 `FileSystemCodeAnalyzer` 随报告落盘，
    ///    代码规模页如实显示"哪几条规则没跑起来"。
    enum RuleDegradeLedger {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var failures: [String] = []

        static func record(_ what: String) {
            lock.lock()
            if !failures.contains(what) { failures.append(what) }
            lock.unlock()
        }

        static var all: [String] {
            lock.lock()
            defer { lock.unlock() }
            return failures
        }
    }

    /// 编译并缓存一条模式。**返回 Optional 是判据不是妥协**：
    /// 编不出来就没有"匹配结果"这回事，调用方必须显式跳过，
    /// 而不是拿一个永不命中的替身去产出"0 个函数"这个假结论。
    static func cache(_ pattern: String) -> NSRegularExpression? {
        if let hit = patternCache.object(forKey: pattern as NSString) { return hit }
        guard let made = try? NSRegularExpression(pattern: pattern, options: []) else {
            RuleDegradeLedger.record("语言规则未能编译：\(Self.patternSummary(pattern))")
            return nil
        }
        patternCache.setObject(made, forKey: pattern as NSString)
        return made
    }

    /// 台账里要放**认得出来**的片段：整条正则最长能到几百字符，会把提示条撑爆。
    static func patternSummary(_ pattern: String) -> String {
        pattern.count <= 48 ? pattern : String(pattern.prefix(48)) + "…"
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    static func profile(for language: String) -> LangProfile {
        let canonical = canonicalLanguage(language)
        var profile = LangProfile()
        profile.languageKey = canonical
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
        // 正则字面量这一档只给有它的那三家（R2 / RD-06 夹具 4）。
        // 不给 Go/Rust/C：它们的 `/` 后面跟的多半是除法或路径，白担一份误吞风险。
        profile.regexLiterals = canonical == "TypeScript" || canonical == "JavaScript" || canonical == "Vue"
        // 无花括号的箭头体同样只给这三家（RD-79）。Swift/Rust/Kotlin 的闭包体一律带 `{`，
        // 给它们开这一档等于凭空多一条「语句收尾」判据要去复核。
        profile.arrowExpressionBody = canonical == "TypeScript" || canonical == "JavaScript" || canonical == "Vue"
        profile.branchKeywords = branchKeywords(for: canonical)
        profile.countsLogicalSymbols = canonical != "Python" && canonical != "HTML"
        profile.countsTernary = canonical != "Python" && canonical != "Go"
        profile.countsNullCoalescing = nullCoalescingLanguages.contains(canonical)
        profile.countsOptionalChaining = optionalChainingLanguages.contains(canonical)
        return profile
    }

    static let nullCoalescingLanguages: Set<String> = [
        "Swift", "Kotlin", "TypeScript", "JavaScript", "Vue", "Dart", "PHP", "Objective-C", "Scala",
    ]

    static let optionalChainingLanguages: Set<String> = [
        "Swift", "Kotlin", "TypeScript", "JavaScript", "Vue", "Dart",
    ]

    /// 每种语言只统计它真正存在的判定关键字，避免 `when`/`match`/`until` 在别的语言里凑数。
    /// `require` 已被整体移出关键字（见 allBranchKeywords），CommonJS 导入行不再算分支。
    static func branchKeywords(for language: String) -> Set<String> {
        let common: Set<String> = ["if", "else if", "for", "while", "until", "case", "catch"]
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
            return ["if", "elseif", "foreach", "for", "while", "until", "case", "catch"]
        case "Shell":
            return ["if", "elif", "for", "while", "until", "case"]
        case "Scala":
            return ["if", "for", "while", "until", "case", "when", "catch"]
        default:
            return allBranchKeywords
        }
    }

    static func canonicalLanguage(_ language: String) -> String {
        let key = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let hit = languageAliases[key] { return hit }
        return language
    }

    static let languageAliases: [String: String] = [
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

    static func family(of language: String) -> BodyFamily {
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

    static let curlyLanguages: Set<String> = [
        "Swift", "Java", "Kotlin", "TypeScript", "JavaScript", "C", "C++", "Objective-C",
        "Go", "Rust", "Scala", "Dart", "PHP", "Gradle", "Vue", "CSS", "SCSS",
    ]

    static func primaryLineComments(for language: String) -> [String] {
        var prefixes = SourceLanguageCatalog.lineCommentPrefixes(for: language)
        if prefixes.isEmpty, curlyLanguages.contains(language) { prefixes = ["//"] }
        // Ruby 等语言的 `'` 既是字符串引号；当作行注释前缀会把 `:'sym'` 之后的代码吃光
        prefixes.removeAll { $0 == "'" }
        return prefixes
    }

    static func blockPair(for language: String) -> (start: String, end: String)? {
        if let pair = SourceLanguageCatalog.blockCommentDelimiters(for: language) { return pair }
        if curlyLanguages.contains(language) { return (start: "/*", end: "*/") }
        return nil
    }

    /// 跨行字符串的定界符（Python 的 `"""`、JS 的模板串），交给 charactersList 变成 [[Character]]。
    static func multiLineQuotes(for language: String) -> [String] {
        var delimiters = SourceLanguageCatalog.docStringDelimiters(for: language)
        if language == "TypeScript" || language == "JavaScript" || language == "Vue" || language == "Go" {
            // Go 的反引号原始字符串可以跨行，里面什么都有（花括号、引号、`//`）；
            // 不当成字符串处理的话花括号深度就会被带偏，函数边界整段错位。
            delimiters = delimiters.filter { $0 != "`" } + ["`"]
        }
        return delimiters
    }

    static func charactersList(_ strings: [String]) -> [[Character]] {
        strings.filter { !$0.isEmpty }.map { Array($0) }
    }
}
