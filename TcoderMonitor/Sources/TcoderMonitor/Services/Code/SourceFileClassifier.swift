import Foundation

// MARK: - Line model

enum SourceLineKind: String, Sendable {
    case blank
    case comment
    case code
}

struct SourceLine: Sendable {
    var number: Int
    var text: String
    var kind: SourceLineKind
}

struct ScannedSourceFile: Sendable {
    var url: URL
    var relativePath: String
    var language: String
    var lines: [SourceLine]
    var blankLineCount: Int
    var commentLineCount: Int
    var codeLineCount: Int
    var todoCount: Int
    var fixmeCount: Int

    var totalLineCount: Int { lines.count }
}

// MARK: - Language catalog

fileprivate struct LanguageRule {
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

fileprivate struct SourceSyntaxProfile: Sendable {
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

fileprivate enum SourceCommentMode {
    case plain
    case block
    case docString([Character])
    case lineComment
    case stringLiteral(Character)
}

/// 单行一次线性扫描。行内一旦出现非注释 token 就判为 code，
/// 于是 `int x = 1; // foo`、`/* a */ code` 归代码，`/* a */`、纯注释行归注释。
fileprivate struct SourceLineWalker {
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
        while index < count {
            if isWhitespace(chars[index]) == false { break }
            index += 1
        }
        if index == count { return .blank }

        var sawCode = false
        while index < count {
            switch mode {
            case .plain:
                let character = chars[index]
                // docstring 定界符必须先于普通字符串判定，否则 Python 的 `"""` 会被拆成三个空串
                if let doc = matched(profile.docDelimiters, at: index, in: chars) {
                    mode = .docString(doc)
                    index += doc.count
                } else if character == "\"" || character == "'" {
                    mode = .stringLiteral(character)
                    sawCode = true
                    index += 1
                } else if let token = matched(profile.linePrefixes, at: index, in: chars) {
                    mode = .lineComment
                    index += token.count
                } else if let start = profile.blockStart, matches(start, at: index, in: chars) {
                    mode = .block
                    index += start.count
                } else {
                    sawCode = true
                    index += 1
                }

            case .block:
                if let end = profile.blockEnd, matches(end, at: index, in: chars) {
                    mode = .plain
                    index += end.count
                } else {
                    index += 1
                }

            case .docString(let delimiter):
                if matches(delimiter, at: index, in: chars) {
                    mode = .plain
                    index += delimiter.count
                } else {
                    index += 1
                }

            case .lineComment:
                index = count

            case .stringLiteral(let quote):
                if chars[index] == "\\", index + 1 < count {
                    index += 2
                } else if chars[index] == quote {
                    mode = .plain
                    index += 1
                } else {
                    index += 1
                }
            }
        }
        return sawCode ? .code : .comment
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

/// 单文件分类器。不变式：
/// 1. `totalLines == blankLines + commentLines + codeLines`（每行只落一个桶，行号从 1 连续）；
/// 2. 任何 IO / 解码失败都以 `nil` 返回，绝不抛异常打断整次扫描；
/// 3. 符号链接文件一律不读（见 `SourceTreeScanner.scan`），因此这里读到的字节必然在仓库树内。
final class SourceFileClassifier {
    private let options: ScanOptions
    private static let maximumLineCount = 200_000

    init(options: ScanOptions) {
        self.options = options
    }

    func classify(url: URL, root: URL) -> ScannedSourceFile? {
        let ext = url.pathExtension.lowercased()
        guard let language = SourceLanguageCatalog.language(forExtension: ext) else { return nil }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        // 双保险：调用方已经过滤过符号链接，这里再拦一次，保证不存在
        // “通过符号链接读到仓库树之外的文件” 这条路径。
        if values?.isSymbolicLink == true { return nil }
        if values?.isRegularFile == false { return nil }
        if let size = values?.fileSize, size > options.maxFileBytes { return nil }
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }

        let content: String
        if let utf8 = String(data: data, encoding: .utf8) {
            content = utf8
        } else {
            content = String(decoding: [UInt8](data), as: UTF8.self)
        }

        // `"\r\n"` is a single Character (one grapheme cluster) in Swift, so a
        // `$0 == "\n"` predicate never fires on CRLF files and the whole file
        // collapses into one "line". Accept all three line terminators.
        var segments = content.split(omittingEmptySubsequences: false) {
            $0 == "\n" || $0 == "\r\n" || $0 == "\r"
        }
        if segments.last?.isEmpty == true { segments.removeLast() }
        // 病态大文件只保留前 20 万行，其后的行不进入任何统计
        if segments.count > Self.maximumLineCount {
            segments = Array(segments[0..<Self.maximumLineCount])
        }

        var walker = SourceLineWalker(language: language)
        var lines: [SourceLine] = []
        lines.reserveCapacity(segments.count)
        var blank = 0
        var comment = 0
        var code = 0
        var todo = 0
        var fixme = 0

        for (offset, segment) in segments.enumerated() {
            var text = String(segment)
            if text.hasSuffix("\r") { text.removeLast() }
            var characters = Array(text)
            let kind = walker.kind(for: &characters)
            switch kind {
            case .blank: blank += 1
            case .comment: comment += 1
            case .code: code += 1
            }
            // TODO/FIXME 只在代码行与注释行里数（空行不可能含标记，顺带省掉一次 uppercased）；
            // 大小写不敏感按子串计次。`FIXME` 不含 `TODO` 子串，因此不会被算成 TODO。
            if kind != .blank {
                let uppercased = text.uppercased()
                todo += sourceMarkerOccurrences(of: "TODO", in: uppercased)
                fixme += sourceMarkerOccurrences(of: "FIXME", in: uppercased)
            }
            lines.append(SourceLine(number: offset + 1, text: text, kind: kind))
        }

        return ScannedSourceFile(
            url: url,
            relativePath: Self.relativePath(for: url, root: root),
            language: language,
            lines: lines,
            blankLineCount: blank,
            commentLineCount: comment,
            codeLineCount: code,
            todoCount: todo,
            fixmeCount: fixme
        )
    }

    /// 以 root 为基准算相对路径。
    ///
    /// 不变式（三条同时成立）：
    /// 1. 返回值里**绝不含 `..` 路径段**，也不含前导 `/`；
    /// 2. 只要 url 落在 root 之下（原始路径前缀成立，或两者各自解析符号链接后的
    ///    canonical / 完全解析路径前缀成立），返回值就是那段相对路径；
    /// 3. 所有形态的前缀判定都不成立（url 真的在 root 之外）才退化为 `lastPathComponent`。
    ///
    /// 纯函数：不读写任何可变全局状态，同一对输入在同一进程内输出稳定（形态顺序固定）。
    static func relativePath(for url: URL, root: URL) -> String {
        // 第一步用原始路径：绝大多数调用（枚举器给出的路径与调用方 root 同前缀）在这里就命中，
        // 一次系统调用都不多做。
        if let relative = relativePath(urlPath: url.path, rootPath: root.path) { return relative }

        // 第二步按归一化形态交叉再试。Darwin 的 `FileManager` 目录枚举器返回的是**已解析符号链接**
        // 的路径（`/tmp/...` → `/private/tmp/...`、`/var/...` → `/private/var/...`），而调用方传进来的
        // root 往往是原始路径；不归一化就会让前缀匹配整体失败、相对路径退化成裸文件名，进而：
        // (a) 依赖相对路径的 `skipDirectories` 带斜杠项（默认名单里的 `Resources/raw`）永远命不中；
        // (b) UI 上不同目录的同名文件显示成同一条路径。
        let urlForms = pathForms(of: url)
        let rootForms = pathForms(of: root)
        for urlForm in urlForms {
            for rootForm in rootForms {
                if let relative = relativePath(urlPath: urlForm, rootPath: rootForm) { return relative }
            }
        }
        return url.lastPathComponent
    }

    /// 一个 URL 的路径形态（原始路径在前，去重后依序尝试，保证输出稳定）：
    /// - `URL.path` 原始形态；
    /// - `URLResourceKey.canonicalPathKey`：解析 `/var → /private/var`、`/tmp → /private/tmp` 这类
    ///   **前缀**软链接（注意本 SDK 只有 `canonicalPathKey`，没有 `canonicalItemPathKey`；
    ///   路径不存在时 Foundation 返回 nil，于是自然落回原始形态）；
    /// - `resolvingSymlinksInPath()`：`canonicalPathKey` 不解析**末段**组件，root 自身就是目录
    ///   软链接时只有它能对齐（实测 `/tmp/x/repoclink` → canonical 仍是 repoclink、resolved 才是真实仓库）。
    /// 只在原始前缀判定失败后才走到这里，实测每次查询约 1.6 µs。
    private static func pathForms(of url: URL) -> [String] {
        var forms = [url.path]
        if let canonical = canonicalPath(of: url), forms.contains(canonical) == false { forms.append(canonical) }
        let resolved = url.resolvingSymlinksInPath().path
        if forms.contains(resolved) == false { forms.append(resolved) }
        return forms
    }

    /// 纯字符串前缀剥离；不成立（含 `..` 逃逸、剥完为空）返回 nil 交给调用方继续判定。
    private static func relativePath(urlPath: String, rootPath: String) -> String? {
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard urlPath.hasPrefix(prefix) else { return nil }
        let trimmed = String(urlPath.dropFirst(prefix.count))
        guard trimmed.isEmpty == false else { return nil }
        // 只挡真正的 `..` 路径段，不误伤 `a..b.swift` 这类合法文件名。
        guard trimmed.hasPrefix("../") == false, trimmed.hasSuffix("/..") == false,
              trimmed.contains("/../") == false else { return nil }
        return trimmed
    }

    /// 本 SDK 只有 `URLResourceKey.canonicalPathKey`（没有 `canonicalItemPathKey`）。
    private static func canonicalPath(of url: URL) -> String? {
        guard let path = try? url.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath,
              path.isEmpty == false else { return nil }
        return path
    }
}

private func sourceMarkerOccurrences(of marker: String, in uppercasedText: String) -> Int {
    var count = 0
    var searchStart = uppercasedText.startIndex
    while searchStart < uppercasedText.endIndex {
        guard let found = uppercasedText.range(of: marker, range: searchStart..<uppercasedText.endIndex) else { break }
        // 词边界：`todoCount` / `fixmeCount` 这类标识符不是待办标记
        if hasMarkerBoundary(text: uppercasedText, lower: found.lowerBound, upper: found.upperBound) {
            count += 1
        }
        searchStart = found.upperBound
    }
    return count
}

private func hasMarkerBoundary(text: String, lower: String.Index, upper: String.Index) -> Bool {
    if lower != text.startIndex, isMarkerByte(text[text.index(before: lower)]) { return false }
    if upper != text.endIndex, isMarkerByte(text[upper]) { return false }
    return true
}

private func isMarkerByte(_ character: Character) -> Bool {
    guard let scalar = character.asciiValue else { return character.isLetter || character.isNumber }
    switch scalar {
    case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x5F: return true
    default: return false
    }
}

// MARK: - Tree scanner

struct SourceScanResult: Sendable {
    var files: [ScannedSourceFile] = []
    var visitedFileCount: Int = 0
    var skippedFileCount: Int = 0
    var scannedFileCount: Int = 0
    var truncatedByMaxFiles: Bool = false
}

/// 跳过目录判定 + 已剔除目录的绝对路径集合（符号链接与 skipDirectories 的兜底防线）
fileprivate struct SourceSkipPlan {
    let root: URL
    let names: Set<String>
    let relativePaths: [String]
    var excludedDirectories: Set<String> = []

    init(root: URL, options: ScanOptions) {
        self.root = root
        names = Set(options.skipDirectories.filter { $0.contains("/") == false })
        relativePaths = options.skipDirectories.filter { $0.contains("/") }
    }

    func isInsideExcluded(_ path: String) -> Bool {
        excludedDirectories.contains { path.hasPrefix($0 + "/") }
    }

    /// 返回 true 表示该目录整体剔除；由调用方执行 skipDescendants，避免在此处写死枚举器类型
    mutating func consume(_ url: URL) -> Bool {
        let relative = SourceFileClassifier.relativePath(for: url, root: root)
        let excluded = isInsideExcluded(url.path)
            || names.contains(url.lastPathComponent)
            || relativePaths.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") })
        guard excluded else { return false }
        excludedDirectories.insert(url.path)
        return true
    }
}

/// 目录树遍历 + 文件级并发分类。
///
/// 遍历不变式（验收口径）：
/// - **绝不读取任何符号链接**（目录链接不进入、文件链接不读）。这样返回的每个 path 都由
///   root 之下的真实目录项拼成，不可能逃逸到仓库树之外，也不可能踩到自环目录。
///   代价：以符号链接形式引入的源码文件不计入统计——刻意选择「跳过」而不是「按真实文件读」，
///   因为后者需要对每个文件做 realpath 包含性判定，且本机存在指向仓库外大资产目录的 symlink。
/// - `skipDirectories`（纯目录名 / 含斜杠的相对路径 / 已剔除目录的子树）整棵子树被跳过，不计入 visited。
/// - 达到 `maxFiles` 立即停止收集；`truncatedByMaxFiles` **只在其后确实还有候选文件未处理**时才置位，
///   因此「候选数恰好等于 maxFiles」不会被误报成截断。
/// - 不可读、超限、非候选文件计入 `skippedFileCount`；任何错误都不抛异常。
final class SourceTreeScanner {
    private let options: ScanOptions
    // ScanOptions.defaultBinaryExtensions 里有 `dSYM` 这类混合大小写，比较前先统一小写
    private let binaryExtensions: Set<String>
    private static let concurrencyLimit = 16
    private static let batchSize = 256

    init(options: ScanOptions) {
        self.options = options
        binaryExtensions = Set(options.binaryExtensions.map { $0.lowercased() })
    }

    func scan(root: URL) async -> SourceScanResult {
        var result = SourceScanResult()
        // root 自身可能是目录符号链接，而 Darwin 的 `enumerator(at:)` **不跟随作为根的软链接**
        // （实测：/tmp 下软链接指向本仓库 → 枚举 0 项，`atPath:` 变体同样 0 项），
        // 那样整次扫描会静默返回空结果、UI 显示成「空项目」。这里把枚举基准换成解析后的根；
        // 解析失败或不是目录时原样退回，行为与改动前一致。
        let scanRoot = Self.enumerationRoot(for: root)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: scanRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return result }

        // `.isDirectoryKey` 必须在列：URLResourceValues 只回填请求过的键，
        // 漏掉它会让目录判定恒为 nil，skipDirectories / 符号链接兜底全部失效。
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey, .nameKey]
        var enumerationOptions: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if options.includeHidden == false { enumerationOptions.insert(.skipsHiddenFiles) }

        guard let enumerator = FileManager.default.enumerator(
            at: scanRoot,
            includingPropertiesForKeys: keys,
            options: enumerationOptions,
            errorHandler: { _, _ in true }
        ) else { return result }

        var plan = SourceSkipPlan(root: scanRoot, options: options)
        var batch: [URL] = []
        var candidateCount = 0
        // 达到上限后进入「探测模式」：只判断后面是否还有候选文件，用来如实置 truncatedByMaxFiles。
        var probingForRemainingCandidates = false

        while let url = enumerator.nextObject() as? URL {
            if Task.isCancelled { break }
            let values = try? url.resourceValues(forKeys: Set(keys))

            // 符号链接：目录链接先掐掉子树再跳过（不跟随 = 不逃逸、不死循环），文件链接直接跳过。
            if values?.isSymbolicLink == true {
                if values?.isDirectory == true { enumerator.skipDescendants() }
                continue
            }

            if values?.isDirectory == true {
                // Darwin Foundation 的枚举器只有 skipDescendants()（skipSubtree 是 corelibs-foundation 独有）
                if plan.consume(url) { enumerator.skipDescendants() }
                continue
            }

            if values?.isRegularFile == false { continue }
            if plan.isInsideExcluded(url.path) { continue }

            // 探测模式：这些文件没有被读、也没有被计入任何计数，只用来判断「还有没有候选文件」。
            // 一发现确实还有未处理的候选文件，就确认「真的截断了」并立即收工。
            if probingForRemainingCandidates {
                if isCandidate(url, values: values) {
                    result.truncatedByMaxFiles = true
                    break
                }
                continue
            }

            result.visitedFileCount += 1
            guard isCandidate(url, values: values) else {
                result.skippedFileCount += 1
                continue
            }

            candidateCount += 1
            batch.append(url)
            if batch.count >= Self.batchSize {
                let urls = batch
                batch.removeAll(keepingCapacity: true)
                let files = await Self.classifyConcurrently(urls: urls, root: scanRoot, options: options)
                merge(files, attempted: urls.count, into: &result)
            }
            // `candidateCount == maxFiles` 本身不代表丢过文件：恰好等于上限的目录一个文件都不该少。
            // 因此命中上限时先不置位，只继续廉价探测是否有下一个候选文件。
            if candidateCount >= options.maxFiles { probingForRemainingCandidates = true }
        }

        let files = await Self.classifyConcurrently(urls: batch, root: scanRoot, options: options)
        merge(files, attempted: batch.count, into: &result)
        return result
    }

    /// 枚举用的根：把「自身是目录符号链接」的 root 换成解析后的真实目录（见 `scan(root:)` 的说明）。
    /// 非软链接、解析结果与原路径相同、或解析后不是目录时一律原样返回，保证行为不回退。
    private static func enumerationRoot(for root: URL) -> URL {
        let resolved = root.resolvingSymlinksInPath()
        guard resolved.path != root.path else { return root }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return root }
        return resolved
    }

    private func merge(_ files: [ScannedSourceFile], attempted urlCount: Int, into result: inout SourceScanResult) {
        result.files.append(contentsOf: files)
        result.scannedFileCount += files.count
        result.skippedFileCount += urlCount - files.count
    }

    private func isCandidate(_ url: URL, values: URLResourceValues?) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard ext.isEmpty == false else { return false }
        if binaryExtensions.contains(ext) { return false }
        if SourceLanguageCatalog.language(forExtension: ext) == nil { return false }
        if let size = values?.fileSize, size > options.maxFileBytes { return false }
        return true
    }

    private static func classifyConcurrently(urls: [URL], root: URL, options: ScanOptions) async -> [ScannedSourceFile] {
        await withTaskGroup(of: ScannedSourceFile?.self, returning: [ScannedSourceFile].self) { group in
            var output: [ScannedSourceFile] = []
            output.reserveCapacity(urls.count)
            var index = 0
            let running = min(concurrencyLimit, urls.count)
            while index < running {
                let url = urls[index]
                group.addTask { SourceFileClassifier(options: options).classify(url: url, root: root) }
                index += 1
            }
            while let item = await group.next() {
                if let item { output.append(item) }
                if index < urls.count {
                    let url = urls[index]
                    group.addTask { SourceFileClassifier(options: options).classify(url: url, root: root) }
                    index += 1
                }
            }
            return output
        }
    }
}
