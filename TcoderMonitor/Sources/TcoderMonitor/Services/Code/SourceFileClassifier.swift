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
    /// 文件行数超过 `maximumLineCount` 时为 true：该文件只有前 20 万行进入统计。
    /// 没有这个标志，`totalLines` 会看起来像全量（WS-D 诚实性审计 P1 #7 的一条）。
    var lineCountTruncated: Bool = false

    var totalLineCount: Int { lines.count }
}

/// 单文件分类器。不变式：
/// 1. `totalLines == blankLines + commentLines + codeLines`（每行只落一个桶，行号从 1 连续）；
/// 2. 任何 IO / 解码失败都以 `nil` 返回，绝不抛异常打断整次扫描；
/// 3. 符号链接文件一律不读（见 `SourceTreeScanner.scan`），因此这里读到的字节必然在仓库树内。
///
/// 相对路径那套判定拆在 `SourceRelativePath.swift`（同一个类型的 extension），
/// 遍历与批次分类拆在 `SourceScanTrail.swift`。
final class SourceFileClassifier {
    let options: ScanOptions
    private static let maximumLineCount = 200_000

    init(options: ScanOptions) {
        self.options = options
    }

    /// 读一个文件并逐行落桶。读不动 / 不是普通文件 / 是符号链接 / 超体积上限一律返回 nil。
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

        let split = contentSegments(of: data)
        var tally = LineTally(walker: SourceLineWalker(language: language))
        tally.lines.reserveCapacity(split.segments.count)
        for (offset, segment) in split.segments.enumerated() {
            tally.add(segment, at: offset)
        }

        return ScannedSourceFile(
            url: url,
            relativePath: Self.relativePath(for: url, root: root),
            language: language,
            lines: tally.lines,
            blankLineCount: tally.blank,
            commentLineCount: tally.comment,
            codeLineCount: tally.code,
            todoCount: tally.todo,
            fixmeCount: tally.fixme,
            lineCountTruncated: split.truncated
        )
    }

    /// 把整份字节流切成行。三种行终止符都接受，末尾不成行的一段算一行，
    /// 病态大文件只保留前 `maximumLineCount` 行（其后的行不进入任何统计）。
    private func contentSegments(of data: Data) -> (segments: [Substring], truncated: Bool) {
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
        guard segments.count > Self.maximumLineCount else { return (segments, false) }
        return (Array(segments[0..<Self.maximumLineCount]), true)
    }

    /// 逐行落桶：`kind` 判定 + 三个计数 + TODO/FIXME 计次。
    /// 原先这几段直接摊在 `classify` 里（那个函数因此 74 行 / CC 25），搬出来之后
    /// 每行该进哪个桶、行号怎么算，都只有一处可读的地方。
    private struct LineTally {
        var lines: [SourceLine] = []
        var blank = 0
        var comment = 0
        var code = 0
        var todo = 0
        var fixme = 0
        /// 跨行的块注释 / docstring 状态挂在这里，必须逐行传递。
        var walker: SourceLineWalker

        mutating func add(_ segment: Substring, at offset: Int) {
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
            if kind == .comment {
                // 只有**注释行**里的标记形状才算一笔欠账。子串口径曾经把
                // `Text("FIXME 45 处")` 这类界面文案、讲 FIXME 用法的测试说明、
                // 文档正文里的词全数计成待办 —— 一个把 FIXME 计数做进界面的工具，
                // 界面上那三个字自己也在喂计数（本 App 扫自己实测：45 个 FIXME 里
                // 真正的标记只有 2 个）。判据收紧的代价是真标记漏计，所以
                // `SourceMarkerPrecisionTests` 双向钉：真标记必计、字符串与散文里的提及必不计。
                let uppercased = text.uppercased()
                todo += sourceMarkerOccurrences(of: "TODO", in: text, uppercased: uppercased)
                fixme += sourceMarkerOccurrences(of: "FIXME", in: text, uppercased: uppercased)
            }
            lines.append(SourceLine(number: offset + 1, text: text, kind: kind))
        }
    }
}

/// 一行注释里有几个**待办标记**。三道判据，缺一不算：
/// ① 词边界（`todoCount` / `fixmeCount` 是标识符，不是欠账）；
/// ② 标记紧跟 `:`（`TODO:` / `FIXME:` 是无歧义写法），**或**标记之前只有注释引导符
///    （`//`、`/*`、`*`、`#`、`- [ ]`、空白等）——「见 TODO 列表」这种句子中段因此不计；
/// ③ 调用方已保证只在注释行调用（见 `LineTally.add`）。
func sourceMarkerOccurrences(of marker: String, in text: String, uppercased uppercasedText: String) -> Int {
    var count = 0
    var searchStart = uppercasedText.startIndex
    while searchStart < uppercasedText.endIndex {
        guard let found = uppercasedText.range(of: marker, range: searchStart..<uppercasedText.endIndex) else { break }
        if hasMarkerBoundary(text: uppercasedText, lower: found.lowerBound, upper: found.upperBound),
           isDebtMarker(uppercased: uppercasedText, text: text, lower: found.lowerBound, upper: found.upperBound) {
            count += 1
        }
        searchStart = found.upperBound
    }
    return count
}

/// ② 号判据：`TODO:` 写法，或标记位于注释开头。
func isDebtMarker(uppercased: String, text: String, lower: String.Index, upper: String.Index) -> Bool {
    if upper < uppercased.endIndex, uppercased[upper] == ":" { return true }
    let before = text[text.startIndex..<lower]
    return before.allSatisfy { $0 == " " || $0 == "\t" || $0 == "/" || $0 == "*" || $0 == "#"
        || $0 == "-" || $0 == ">" || $0 == "[" || $0 == "]" || $0 == "x" || $0 == "X" || $0 == "!"
        || $0 == "<" || $0 == "%" }
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
    /// 有多少个文件因为超过 20 万行上限只统计了前 20 万行（`CodeMetrics.totalLines` 因此不是全量）。
    var lineTruncatedFileCount: Int = 0
    /// 「为什么丢了这个文件」的台账；见 `SourceSkipLedger`。
    var skipLedger: SourceSkipLedger = SourceSkipLedger()
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
///
/// 单个条目怎么归类、批次怎么分类、台账怎么归因，全在 `SourceScanTrail.swift`
/// （同一个类型的 extension）；这里只留「拿到枚举器 + 逐条交出去」。
///
/// 可见性说明（2026-09-20 拆分所致，**不要改回 private**）：`options` / `binaryExtensions` /
/// `auditLineBudget` / `auditing` 原先是 `private`，跨文件的 extension 分片看不见，
/// 已放宽到模块内可见。**除可见性外没有任何变化**，`SourceTreeScanner` 仍是唯一入口。
final class SourceTreeScanner {
    let options: ScanOptions
    // ScanOptions.defaultBinaryExtensions 里有 `dSYM` 这类混合大小写，比较前先统一小写
    let binaryExtensions: Set<String>
    /// > 0 时进入「剔除台账审计模式」：会把被剔除文件的真实行数也数出来（要读文件），
    /// 并在审计模式下对被剔除目录**不掐子树**，以便逐文件归因。产品路径恒为 0。
    let auditLineBudget: Int64

    init(options: ScanOptions, auditLineBudget: Int64 = 0) {
        self.options = options
        self.auditLineBudget = auditLineBudget
        binaryExtensions = Set(options.binaryExtensions.map { $0.lowercased() })
    }

    var auditing: Bool { auditLineBudget > 0 }

    func scan(root: URL) async -> SourceScanResult {
        // root 自身可能是目录符号链接，而 Darwin 的 `enumerator(at:)` **不跟随作为根的软链接**
        // （实测：/tmp 下软链接指向本仓库 → 枚举 0 项，`atPath:` 变体同样 0 项），
        // 那样整次扫描会静默返回空结果、UI 显示成「空项目」。这里把枚举基准换成解析后的根；
        // 解析失败或不是目录时原样退回，行为与改动前一致。
        let scanRoot = Self.enumerationRoot(for: root)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: scanRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return SourceScanResult() }

        guard let enumerator = FileManager.default.enumerator(
            at: scanRoot,
            includingPropertiesForKeys: Self.resourceKeys,
            options: Self.enumerationOptions,
            errorHandler: { _, _ in true }
        ) else { return SourceScanResult() }

        var progress = SourceScanProgress(root: scanRoot, options: options)
        // 台账要先声明本轮到底数不数行数：审计模式之外一律是 false，
        // `clearing(linesCounted:)` 靠它区分「这些条目真的 0 行」与「没去数」。
        progress.result.skipLedger.linesCounted = auditing
        while let url = enumerator.nextObject() as? URL {
            if Task.isCancelled { break }
            if await consume(url, enumerator: enumerator, into: &progress) == false { break }
        }
        await flush(&progress)
        return progress.result
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
}
