import Foundation

// OWNER: Workstream A (静态代码分析). 语言目录表 + 行分类状态机；调用方是 SourceFileClassifier.swift。
//
// 拆出来是为了守住本工作流的红线（800 行以上的文件不得增加），顺带把两件事分开：
// 这里回答「某后缀属于哪种语言、某种语言的注释定界符是什么、一行是代码还是注释」，
// 扫描与文件读取留在 SourceFileClassifier.swift。
//
// 下面的 internal 而非 fileprivate：跨文件后仍需互相可见，但都只在本 target 内使用。

internal struct LanguageRule {
    var language: String
    var extensions: [String]
    var linePrefixes: [String]
    var blockStart: String?
    var blockEnd: String?
    var docDelimiters: [String]
}

enum SourceLanguageCatalog {

    static func language(forExtension ext: String) -> String? {
        guard ext.isEmpty == false else { return nil }
        return sourceLanguageByFileExtension[ext.lowercased()]
    }

    static func lineCommentPrefixes(for language: String) -> [String] {
        sourceLanguageRuleByName[language]?.linePrefixes ?? []
    }

    static func blockCommentDelimiters(for language: String) -> (start: String, end: String)? {
        guard let rule = sourceLanguageRuleByName[language],
              let start = rule.blockStart,
              let end = rule.blockEnd else { return nil }
        return (start, end)
    }

    static func docStringDelimiters(for language: String) -> [String] {
        sourceLanguageRuleByName[language]?.docDelimiters ?? []
    }

    static var supportedLanguages: [String] { rules.map { $0.language } }

    fileprivate static let rules: [LanguageRule] = [
        LanguageRule(language: "Swift", extensions: ["swift"], linePrefixes: ["//"],
                     blockStart: "/*", blockEnd: "*/", docDelimiters: []),
        LanguageRule(language: "Java", extensions: ["java"], linePrefixes: ["//"],
                     blockStart: "/*", blockEnd: "*/", docDelimiters: []),
        LanguageRule(language: "Kotlin", extensions: ["kt", "kts"], linePrefixes: ["//"],
                     blockStart: "/*", blockEnd: "*/", docDelimiters: []),
        LanguageRule(language: "TypeScript", extensions: ["ts", "mts", "cts", "tsx"], linePrefixes: ["//"],
                     blockStart: "/*", blockEnd: "*/", docDelimiters: []),
        LanguageRule(language: "JavaScript", extensions: ["js", "mjs", "cjs", "jsx"], linePrefixes: ["//"],
                     blockStart: "/*", blockEnd: "*/", docDelimiters: []),
        LanguageRule(language: "Python", extensions: ["py", "pyi"], linePrefixes: ["#"],
                     blockStart: nil, blockEnd: nil, docDelimiters: ["\"\"\"", "'''"]),
        LanguageRule(language: "Go", extensions: ["go"], linePrefixes: ["//"],
                     blockStart: "/*", blockEnd: "*/", docDelimiters: []),
        LanguageRule(language: "Rust", extensions: ["rs"], linePrefixes: ["//"],
                     blockStart: "/*", blockEnd: "*/", docDelimiters: []),
        LanguageRule(language: "C", extensions: ["c", "h"], linePrefixes: ["//"],
                     blockStart: "/*", blockEnd: "*/", docDelimiters: []),
        LanguageRule(language: "C++", extensions: ["cpp", "cc", "cxx", "c++", "hpp", "hh", "hxx", "h++"],
                     linePrefixes: ["//"], blockStart: "/*", blockEnd: "*/", docDelimiters: []),
        LanguageRule(language: "Objective-C", extensions: ["m", "mm"], linePrefixes: ["//"],
                     blockStart: "/*", blockEnd: "*/", docDelimiters: []),
        LanguageRule(language: "C#", extensions: ["cs"], linePrefixes: ["//"],
                     blockStart: "/*", blockEnd: "*/", docDelimiters: []),
        LanguageRule(language: "Ruby", extensions: ["rb", "rake", "gemspec"], linePrefixes: ["#"],
                     blockStart: nil, blockEnd: nil, docDelimiters: []),
        LanguageRule(language: "PHP", extensions: ["php", "phtml"], linePrefixes: ["//", "#"],
                     blockStart: "/*", blockEnd: "*/", docDelimiters: []),
        LanguageRule(language: "Dart", extensions: ["dart"], linePrefixes: ["//"],
                     blockStart: "/*", blockEnd: "*/", docDelimiters: []),
        LanguageRule(language: "Scala", extensions: ["scala", "sc"], linePrefixes: ["//"],
                     blockStart: "/*", blockEnd: "*/", docDelimiters: []),
        LanguageRule(language: "Vue", extensions: ["vue"], linePrefixes: [],
                     blockStart: "<!--", blockEnd: "-->", docDelimiters: []),
        LanguageRule(language: "HTML", extensions: ["html", "htm"], linePrefixes: [],
                     blockStart: "<!--", blockEnd: "-->", docDelimiters: []),
        LanguageRule(language: "CSS", extensions: ["css"], linePrefixes: [],
                     blockStart: "/*", blockEnd: "*/", docDelimiters: []),
        LanguageRule(language: "SCSS", extensions: ["scss", "sass", "less"], linePrefixes: ["//"],
                     blockStart: "/*", blockEnd: "*/", docDelimiters: []),
        LanguageRule(language: "SQL", extensions: ["sql"], linePrefixes: ["--"],
                     blockStart: "/*", blockEnd: "*/", docDelimiters: []),
        LanguageRule(language: "Shell", extensions: ["sh", "bash", "zsh"], linePrefixes: ["#"],
                     blockStart: nil, blockEnd: nil, docDelimiters: []),
        LanguageRule(language: "YAML", extensions: ["yml", "yaml"], linePrefixes: ["#"],
                     blockStart: nil, blockEnd: nil, docDelimiters: []),
        LanguageRule(language: "TOML", extensions: ["toml"], linePrefixes: ["#"],
                     blockStart: nil, blockEnd: nil, docDelimiters: []),
        LanguageRule(language: "XML", extensions: ["xml", "plist", "xib"], linePrefixes: [],
                     blockStart: "<!--", blockEnd: "-->", docDelimiters: []),
        LanguageRule(language: "JSON", extensions: ["json", "jsonc"], linePrefixes: [],
                     blockStart: nil, blockEnd: nil, docDelimiters: []),
        LanguageRule(language: "Markdown", extensions: ["md", "markdown"], linePrefixes: [],
                     blockStart: "<!--", blockEnd: "-->", docDelimiters: []),
        LanguageRule(language: "Gradle", extensions: ["gradle", "groovy"], linePrefixes: ["//"],
                     blockStart: "/*", blockEnd: "*/", docDelimiters: []),
        // protobuf 只有 `//` 行注释，没有块注释语法；语言名保持与其余条目同样的英文专名写法
        // （`LanguageShare.language` 是直接展示的字段，口径与 DemoData 一致）。
        LanguageRule(language: "Protocol Buffers", extensions: ["proto"], linePrefixes: ["//"],
                     blockStart: nil, blockEnd: nil, docDelimiters: []),
        LanguageRule(language: "Properties", extensions: ["properties"], linePrefixes: ["#", "!"],
                     blockStart: nil, blockEnd: nil, docDelimiters: []),
        LanguageRule(language: "Perl", extensions: ["pl", "pm"], linePrefixes: ["#"],
                     blockStart: nil, blockEnd: nil, docDelimiters: []),
        LanguageRule(language: "Lua", extensions: ["lua"], linePrefixes: ["--"],
                     blockStart: "--[[", blockEnd: "]]", docDelimiters: []),
        LanguageRule(language: "Haskell", extensions: ["hs"], linePrefixes: ["--"],
                     blockStart: "{-", blockEnd: "-}", docDelimiters: []),
        LanguageRule(language: "Elixir", extensions: ["ex", "exs"], linePrefixes: ["#"],
                     blockStart: nil, blockEnd: nil, docDelimiters: []),
        LanguageRule(language: "R", extensions: ["r"], linePrefixes: ["#"],
                     blockStart: nil, blockEnd: nil, docDelimiters: []),
        LanguageRule(language: "INI", extensions: ["ini", "cfg", "conf"], linePrefixes: ["#", ";"],
                     blockStart: nil, blockEnd: nil, docDelimiters: []),
        LanguageRule(language: "Dockerfile", extensions: ["dockerfile"], linePrefixes: ["#"],
                     blockStart: nil, blockEnd: nil, docDelimiters: []),
        LanguageRule(language: "Makefile", extensions: ["mk", "mak"], linePrefixes: ["#"],
                     blockStart: nil, blockEnd: nil, docDelimiters: []),
    ]
}

// 扩展名映射唯一：同一扩展名只归属一种语言（`.h` 归 C，不纠结 C++）
fileprivate let sourceLanguageByFileExtension: [String: String] = {
    var index: [String: String] = [:]
    for rule in SourceLanguageCatalog.rules {
        for ext in rule.extensions where index[ext] == nil {
            index[ext] = rule.language
        }
    }
    return index
}()

fileprivate let sourceLanguageRuleByName: [String: LanguageRule] = {
    var index: [String: LanguageRule] = [:]
    for rule in SourceLanguageCatalog.rules where index[rule.language] == nil {
        index[rule.language] = rule
    }
    return index
}()

// MARK: - Line classification state machine

internal struct SourceSyntaxProfile: Sendable {
    var linePrefixes: [[Character]] = []
    var blockStart: [Character]?
    var blockEnd: [Character]?
    var docDelimiters: [[Character]] = []

    init(language: String) {
        linePrefixes = SourceLanguageCatalog.lineCommentPrefixes(for: language).map { Array($0) }
        if let (start, end) = SourceLanguageCatalog.blockCommentDelimiters(for: language) {
            blockStart = Array(start)
            blockEnd = Array(end)
        }
        docDelimiters = SourceLanguageCatalog.docStringDelimiters(for: language).map { Array($0) }
    }
}

/// 语言 → Character 规则表，进程内构造一次。
/// maxFiles 默认 6 万，逐文件重建这张表（Array(Character) 拆分 + 目录查表）就是纯浪费。
fileprivate let sourceSyntaxProfileByLanguage: [String: SourceSyntaxProfile] = {
    let languages = SourceLanguageCatalog.supportedLanguages
    var index: [String: SourceSyntaxProfile] = [:]
    index.reserveCapacity(languages.count + 8)
    for language in languages where index[language] == nil {
        index[language] = SourceSyntaxProfile(language: language)
    }
    return index
}()

fileprivate func sourceSyntaxProfile(for language: String) -> SourceSyntaxProfile {
    sourceSyntaxProfileByLanguage[language] ?? SourceSyntaxProfile(language: language)
}

internal enum SourceCommentMode {
    case plain
    case block
    case docString([Character])
    case lineComment
    case stringLiteral(Character)
}

/// 单行一次线性扫描。行内一旦出现非注释 token 就判为 code，
/// 于是 `int x = 1; // foo`、`/* a */ code` 归代码，`/* a */`、纯注释行归注释。
internal struct SourceLineWalker {
    private let profile: SourceSyntaxProfile
    private var mode: SourceCommentMode = .plain

    init(language: String) {
        profile = sourceSyntaxProfile(for: language)
    }

    mutating func kind(for chars: inout [Character]) -> SourceLineKind {
        // 行注释与单引号字符串不可能跨行，进入新行前先归零，只保留块注释/docstring 状态
        switch mode {
        case .lineComment, .stringLiteral: mode = .plain
        case .plain, .block, .docString: break
        }

        let count = chars.count
        var index = 0
        while index < count, isWhitespace(chars[index]) { index += 1 }
        if index == count { return .blank }

        var sawCode = false
        while index < count {
            index = advance(chars: chars, from: index, count: count, sawCode: &sawCode)
        }
        return sawCode ? .code : .comment
    }

    /// 按当前词法模式前进一段，返回新的列位置。
    ///
    /// 原先这是 `kind(for:)` 里的一个 71 行大 switch（自扫报告点名 CC=23）；现在每个模式
    /// 各自成一个 `advance*` 小函数，**判定顺序、推进步长、`sawCode` 置位点全部一字未改**，
    /// 变的只是「分支从 23 降到 7」。
    private mutating func advance(chars: [Character], from index: Int, count: Int,
                                  sawCode: inout Bool) -> Int {
        switch mode {
        case .plain:
            return advancePlain(chars, from: index, count: count, sawCode: &sawCode)
        case .block:
            return advanceBlock(chars, from: index)
        case .docString(let delimiter):
            return advanceDocString(delimiter, chars, from: index)
        case .lineComment:
            return count
        case .stringLiteral(let quote):
            return advanceStringLiteral(quote, chars, from: index, count: count)
        }
    }

    /// 行首：docstring 定界符必须先于普通字符串判定，否则 Python 的 `"""` 会被拆成三个空串。
    private mutating func advancePlain(_ chars: [Character], from index: Int, count: Int,
                                       sawCode: inout Bool) -> Int {
        let character = chars[index]
        if let doc = matched(profile.docDelimiters, at: index, in: chars) {
            mode = .docString(doc)
            return index + doc.count
        } else if character == "\"" || character == "'" {
            mode = .stringLiteral(character)
            sawCode = true
            return index + 1
        } else if let token = matched(profile.linePrefixes, at: index, in: chars) {
            mode = .lineComment
            return index + token.count
        } else if let start = profile.blockStart, matches(start, at: index, in: chars) {
            mode = .block
            return index + start.count
        }
        sawCode = true
        return index + 1
    }

    private mutating func advanceBlock(_ chars: [Character], from index: Int) -> Int {
        guard let end = profile.blockEnd, matches(end, at: index, in: chars) else { return index + 1 }
        mode = .plain
        return index + end.count
    }

    private mutating func advanceDocString(_ delimiter: [Character], _ chars: [Character],
                                           from index: Int) -> Int {
        guard matches(delimiter, at: index, in: chars) else { return index + 1 }
        mode = .plain
        return index + delimiter.count
    }

    private mutating func advanceStringLiteral(_ quote: Character, _ chars: [Character],
                                               from index: Int, count: Int) -> Int {
        if chars[index] == "\\", index + 1 < count { return index + 2 }
        if chars[index] == quote {
            mode = .plain
            return index + 1
        }
        return index + 1
    }

    private func matched(_ tokens: [[Character]], at index: Int, in chars: [Character]) -> [Character]? {
        for token in tokens where matches(token, at: index, in: chars) {
            return token
        }
        return nil
    }

    private func matches(_ token: [Character], at index: Int, in chars: [Character]) -> Bool {
        guard token.isEmpty == false, index + token.count <= chars.count else { return false }
        for offset in 0..<token.count where chars[index + offset] != token[offset] {
            return false
        }
        return true
    }

    private func isWhitespace(_ character: Character) -> Bool {
        character == " " || character == "\t" || character == "\r" || character == "\n"
            || character == "\u{0B}" || character == "\u{0C}"
    }
}

// MARK: - Classifier
