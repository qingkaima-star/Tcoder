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
    /// R2（RD-07 / RD-20 的相关半边）：混合语言文件**按区域归位**后的行读数。
    /// 只有真认出 SFC 分区的文件才有值；`nil` = 该文件不是（认得出的）混合语言文件。
    /// 存在理由：`commentRatio` 只有一个全文件分母，把模板注释、样式注释与脚本注释混进
    /// 同一个分母读出来的「注释率」没有意义；分区归位后每一区要有自己的分子分母。
    /// 契约缺口：`CodeMetrics`（冻结区）没有承接字段，所以这个数目前只能到单测与 CLI 内部，
    /// 界面上看不到 —— 已列进 R2 交回汇报的「契约缺口」。
    var vueRegionTally: ComplexityEngine.VueRegionTally? = nil

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
        var texts = [String]()
        texts.reserveCapacity(split.segments.count)
        for segment in split.segments {
            var text = String(segment)
            if text.hasSuffix("\r") { text.removeLast() }
            texts.append(text)
        }
        // RD-07：`.vue` 一份文件住着三种语言。逐行按所在区域换词法档案，
        // 于是脚本区的 `//`、样式区的 `/* */` 各按自己的语言判注释，
        // 而不是整份文件套 Vue 那一条 `linePrefixes: [] / blockStart: "<!--"`。
        let regionLanguages = Self.regionLanguagesForClassification(fileLanguage: language, lines: texts)
        var tally = LineTally(walker: SourceLineWalker(language: language),
                              regionLanguages: regionLanguages, fileLanguage: language)
        for (offset, text) in texts.enumerated() {
            tally.add(text, at: offset, fileLanguage: language)
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
            lineCountTruncated: split.truncated,
            vueRegionTally: tally.regionTally
        )
    }

    /// 逐行该按哪种语言的词法判注释 / 代码。认不出分区时返回 nil（退回整份文件一种语言）。
    static func regionLanguagesForClassification(fileLanguage: String,
                                                  lines: [String]) -> [String]? {
        guard fileLanguage == "Vue", let map = ComplexityEngine.detectVueRegions(lines) else { return nil }
        return map.regions.map { region in
            switch region {
            case .script: return map.scriptLanguage
            case .template: return "HTML"
            case .style: return "CSS"
            case .structure, .other: return "Vue"
            }
        }
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
    ///
    /// R2（RD-07）加的两件事：
    /// 1. **逐行换词法档案**：混合语言文件按所在区域换语言，每个区域自己一套
    ///    `SourceLineWalker`（块注释状态各归各的，脚本区没闭合的 `/*` 不许去吃模板区）；
    /// 2. **按区域归位的行读数** `regionTally`：注释率要有自己的分母，
    ///    不能把模板注释、样式注释与脚本注释混进同一个全文件分母里读出一个没意义的数。
    private struct LineTally {
        var lines: [SourceLine] = []
        var blank = 0
        var comment = 0
        var code = 0
        var todo = 0
        var fixme = 0
        /// 跨行的块注释 / docstring 状态挂在这里，必须逐行传递；
        /// 混合语言文件按区域各存一份（每种语言一个 walker）。
        private var walkers: [String: SourceLineWalker]
        private let regionLanguages: [String]?
        var regionTally: ComplexityEngine.VueRegionTally?

        init(walker: SourceLineWalker, regionLanguages: [String]?, fileLanguage: String) {
            self.regionLanguages = regionLanguages
            walkers = [fileLanguage: walker]
            regionTally = regionLanguages == nil ? nil : ComplexityEngine.VueRegionTally()
            lines.reserveCapacity(regionLanguages?.count ?? 0)
        }

        /// 这一行按哪种语言的词法判：分区表有值就走分区，否则退回整份文件一种语言。
        func languageAt(_ offset: Int, fallback: String) -> String {
            guard let regionLanguages, offset < regionLanguages.count else { return fallback }
            return regionLanguages[offset]
        }

        mutating func add(_ text: String, at offset: Int, fileLanguage: String) {
            let language = languageAt(offset, fallback: fileLanguage)
            var walker = walkers[language] ?? SourceLineWalker(language: language)
            var characters = Array(text)
            let kind = walker.kind(for: &characters)
            walkers[language] = walker
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
            recordRegionLine(language: language, kind: kind)
        }

        /// 按区域再记一本账：脚本 / 模板 / 样式 / 结构行各自的代码行数与注释行数。
        /// 分区口径下 `language` 就是区域名（TypeScript↔script、HTML↔template、CSS↔style、Vue↔结构行）。
        mutating func recordRegionLine(language: String, kind: SourceLineKind) {
            guard var tally = regionTally else { return }
            let isComment = kind == .comment
            switch language {
            case "HTML":
                if isComment { tally.templateCommentLines += 1 } else { tally.templateCodeLines += 1 }
            case "CSS", "SCSS":
                if isComment { tally.styleCommentLines += 1 } else { tally.styleCodeLines += 1 }
            case "Vue":
                if isComment { tally.structureCommentLines += 1 } else { tally.structureCodeLines += 1 }
            default:
                if isComment { tally.scriptCommentLines += 1 } else { tally.scriptCodeLines += 1 }
            }
            regionTally = tally
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
    /// 遍历「跟不跟」的现场计数（软链接 / 嵌套版本库 / 包状目录 / 名单外被剪掉的目录）。
    /// 判据与句子在 `SourceScanScopeReadout.swift`（RD-15）；这里只是它的落点。
    var treeFollowing = SourceTreeFollowingLedger()
    /// 遍历中**读不动的目录数**（权限不够、竞态中消失、悬空软链接的目标目录）。
    ///
    /// 存在理由（F12 的另一半）：`enumerator` 的 `errorHandler` 原本 `{ _, _ in true }`
    /// —— 一直"继续"，于是每个读不动的子树都等同于"那个子树里没有源码"。
    /// 一个 0 文件的仓库和一个没被看过的仓库，在界面上必须是两句话。
    var unreadableDirectoryCount: Int = 0
}

/// 一个只能"加一"的计数盒。`FileManager.enumerator` 的 `errorHandler` 是
/// `@Sendable` 闭包，碰不到外层局部 `var`，所以错误计数必须住在一个引用类型里。
/// 与 `ComplexityEngine.RuleDegradeLedger` 同一形状（NSLock，只加不减）。
final class ScanErrorTally: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func addOne() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
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

        // 计数盒是因为 `errorHandler` 是 `@Sendable` 闭包、碰不到局部 var：
        // 与 `ComplexityEngine.RuleDegradeLedger` 同一形状（NSLock + 只加不减）。
        let unreadable = ScanErrorTally()
        guard let enumerator = FileManager.default.enumerator(
            at: scanRoot,
            includingPropertiesForKeys: Self.resourceKeys,
            options: Self.enumerationOptions,
            errorHandler: { _, _ in
                unreadable.addOne()
                return true        // 继续遍历：一个目录读不动不该让整次扫描中断
            }
        ) else {
            return SourceScanResult(unreadableDirectoryCount: 1)
        }

        var progress = SourceScanProgress(root: scanRoot, options: options)
        // 台账要先声明本轮到底数不数行数：审计模式之外一律是 false，
        // `clearing(linesCounted:)` 靠它区分「这些条目真的 0 行」与「没去数」。
        progress.result.skipLedger.linesCounted = auditing
        while let url = enumerator.nextObject() as? URL {
            if Task.isCancelled { break }
            if await consume(url, enumerator: enumerator, into: &progress) == false { break }
        }
        await flush(&progress)
        progress.result.unreadableDirectoryCount = unreadable.count
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
