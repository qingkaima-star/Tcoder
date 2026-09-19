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

fileprivate struct SourceSyntaxProfile {
    var linePrefixes: [[Character]] = []
    var blockStart: [Character]?
    var blockEnd: [Character]?
    var docDelimiters: [[Character]] = []
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
        var built = SourceSyntaxProfile()
        built.linePrefixes = SourceLanguageCatalog.lineCommentPrefixes(for: language).map { Array($0) }
        if let (start, end) = SourceLanguageCatalog.blockCommentDelimiters(for: language) {
            built.blockStart = Array(start)
            built.blockEnd = Array(end)
        }
        built.docDelimiters = SourceLanguageCatalog.docStringDelimiters(for: language).map { Array($0) }
        profile = built
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

final class SourceFileClassifier {
    private let options: ScanOptions
    private static let maximumLineCount = 200_000

    init(options: ScanOptions) {
        self.options = options
    }

    func classify(url: URL, root: URL) -> ScannedSourceFile? {
        let ext = url.pathExtension.lowercased()
        guard let language = SourceLanguageCatalog.language(forExtension: ext) else { return nil }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        if values?.isRegularFile == false { return nil }
        if let size = values?.fileSize, size > options.maxFileBytes { return nil }
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }

        let content: String
        if let utf8 = String(data: data, encoding: .utf8) {
            content = utf8
        } else {
            content = String(decoding: [UInt8](data), as: UTF8.self)
        }

        var segments = content.split(omittingEmptySubsequences: false) { $0 == "\n" }
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
            let uppercased = text.uppercased()
            todo += sourceMarkerOccurrences(of: "TODO", in: uppercased)
            fixme += sourceMarkerOccurrences(of: "FIXME", in: uppercased)
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

    static func relativePath(for url: URL, root: URL) -> String {
        let rootPath = root.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let filePath = url.path
        guard filePath.hasPrefix(prefix) else { return url.lastPathComponent }
        let trimmed = String(filePath.dropFirst(prefix.count))
        return trimmed.isEmpty ? url.lastPathComponent : trimmed
    }
}

private func sourceMarkerOccurrences(of marker: String, in uppercasedText: String) -> Int {
    var count = 0
    var searchStart = uppercasedText.startIndex
    while searchStart < uppercasedText.endIndex {
        guard let found = uppercasedText.range(of: marker, range: searchStart..<uppercasedText.endIndex) else { break }
        count += 1
        searchStart = found.upperBound
    }
    return count
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
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return result }

        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey, .nameKey]
        var enumerationOptions: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if options.includeHidden == false { enumerationOptions.insert(.skipsHiddenFiles) }

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: enumerationOptions,
            errorHandler: { _, _ in true }
        ) else { return result }

        var plan = SourceSkipPlan(root: root, options: options)
        var batch: [URL] = []
        var candidateCount = 0

        while let url = enumerator.nextObject() as? URL {
            if Task.isCancelled { break }
            let values = try? url.resourceValues(forKeys: Set(keys))

            // 符号链接一律跳过：本机有指向仓库外大资产目录的 symlink，跟随就是事故
            if values?.isSymbolicLink == true { continue }

            if values?.isDirectory == true {
                // Darwin Foundation 的枚举器只有 skipDescendants()（skipSubdirectoryDescendants 是 corelibs 独有）
                if plan.consume(url) { enumerator.skipDescendants() }
                continue
            }

            if values?.isRegularFile == false { continue }
            if plan.isInsideExcluded(url.path) { continue }

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
                let files = await Self.classifyConcurrently(urls: urls, root: root, options: options)
                merge(files, attempted: urls.count, into: &result)
            }
            if candidateCount >= options.maxFiles {
                result.truncatedByMaxFiles = true
                break
            }
        }

        let files = await Self.classifyConcurrently(urls: batch, root: root, options: options)
        merge(files, attempted: batch.count, into: &result)
        return result
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
