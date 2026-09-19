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

// MARK: - Language catalog

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
        var truncatedToLineCap = false
        if segments.count > Self.maximumLineCount {
            segments = Array(segments[0..<Self.maximumLineCount])
            truncatedToLineCap = true
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
            fixmeCount: fixme,
            lineCountTruncated: truncatedToLineCap
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
        var forms: [String] = []
        func add(_ candidate: String) { if forms.contains(candidate) == false { forms.append(candidate) } }
        add(url.path)
        if let canonical = canonicalPath(of: url) { add(canonical) }
        add(url.resolvingSymlinksInPath().path)
        // 文件系统派生的形态只对**存在**的路径有效，最后再补一遍不 stat 的字面别名，
        // 否则路径里有任何一层还没被创建，`/tmp/...` 与 `/private/tmp/...` 就判不到同一个根。
        for base in Array(forms) {
            for alias in lexicalAliasForms(ofPath: base) { add(alias) }
        }
        return forms
    }

    /// macOS 上 `/tmp`、`/var`、`/etc`、`/tftpboot` 都是 `/private/…` 的别名，这层关系由系统固定，
    /// 按字面展开两种形态即可，不需要（也不应该依赖）stat —— 单测里根路径常常并不存在。
    private static let privateAliasDirectories: Set<String> = ["tmp", "var", "etc", "tftpboot"]

    static func lexicalAliasForms(ofPath path: String) -> [String] {
        guard path.hasPrefix("/") else { return [path] }
        if path.hasPrefix("/private/") {
            let rest = String(path.dropFirst("/private/".count))
            let head = rest.split(separator: "/", maxSplits: 1).first.map(String.init)
            if let head, privateAliasDirectories.contains(head) { return [path, "/" + rest] }
            return [path]
        }
        let head = path.dropFirst().split(separator: "/", maxSplits: 1).first.map(String.init)
        if let head, privateAliasDirectories.contains(head) { return [path, "/private" + path] }
        return [path]
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
    /// 有多少个文件因为超过 20 万行上限只统计了前 20 万行（`CodeMetrics.totalLines` 因此不是全量）。
    var lineTruncatedFileCount: Int = 0
    /// 「为什么丢了这个文件」的台账；见 `SourceSkipLedger`。
    var skipLedger: SourceSkipLedger = SourceSkipLedger()
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

    /// 该路径落在哪个被剔除目录之下，取**最顶层**那个作为根因（`vendor` 而不是 `vendor/portable-ruby/4.0.5_1`）。
    /// 台账要回答的就是「vendor/ 一共丢了多少行」，归到叶子目录上就没法看了。
    func excludedAnchor(for path: String) -> String? {
        let hits = excludedDirectories.filter { path.hasPrefix($0 + "/") }
        guard let top = hits.min(by: { $0.count < $1.count }) else { return nil }
        let name = (top as NSString).lastPathComponent
        return name.isEmpty ? top : name
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
    /// > 0 时进入「剔除台账审计模式」：会把被剔除文件的真实行数也数出来（要读文件），
    /// 并在审计模式下对被剔除目录**不掐子树**，以便逐文件归因。产品路径恒为 0。
    private let auditLineBudget: Int64
    private static let concurrencyLimit = 16
    private static let batchSize = 256

    init(options: ScanOptions, auditLineBudget: Int64 = 0) {
        self.options = options
        self.auditLineBudget = auditLineBudget
        binaryExtensions = Set(options.binaryExtensions.map { $0.lowercased() })
    }

    private var auditing: Bool { auditLineBudget > 0 }

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
        // 隐藏项**不用** `.skipsHiddenFiles`：那样枚举器根本不会交出这些条目，剔除台账就无从统计。
        // 改为在循环里按 `name` 判定并记账，纳入/排除的结果与原来完全一致。
        let enumerationOptions: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]

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
            let bytes = Int64(values?.fileSize ?? 0)
            let entryName = values?.name ?? url.lastPathComponent

            // 隐藏项：includeHidden = false 时目录连带掐掉子树。只进台账，不进 visited/skipped 计数，
            // 以保持与改用 .skipsHiddenFiles 之前的既有计数完全一致。
            if options.includeHidden == false, entryName.hasPrefix(".") {
                if values?.isDirectory == true {
                    enumerator.skipDescendants()
                    // 隐藏子树在审计模式下要能报「剪掉了多少文件」，否则台账有洞；
                    // 但**绝不读内容** —— 隐藏目录里常有 .ssh / .env / 密钥。
                    auditPrunedSubtree(of: url, into: &result.skipLedger, reason: .prunedHiddenContents,
                                        readLines: false)
                }
                result.skipLedger.record(.hiddenEntry, path: url.path, bytes: values?.isDirectory == true ? 0 : bytes,
                                         rule: entryName)
                continue
            }

            // 符号链接：目录链接先掐掉子树再跳过（不跟随 = 不逃逸、不死循环），文件链接直接跳过。
            if values?.isSymbolicLink == true {
                if values?.isDirectory == true { enumerator.skipDescendants() }
                result.skipLedger.record(.symbolicLink, path: url.path, bytes: bytes, rule: nil)
                continue
            }

            if values?.isDirectory == true, isPackageDirectory(entryName) {
                // `.skipsPackageDescendants` 会让枚举器交出这个目录、但不进入其内容 ——
                // 不记一笔就是台账解释不掉的黑洞（Homebrew 实测 NewApp.app + 4 个 .dSYM 共 9 个文件）。
                result.skipLedger.record(.prunedPackageDir, path: url.path, bytes: 0,
                                         rule: (entryName as NSString).pathExtension.lowercased())
                auditPrunedSubtree(of: url, into: &result.skipLedger, reason: .prunedPackageContents,
                                   readLines: true)
                continue
            }
            if values?.isDirectory == true {
                // 先问「是不是已经在被剔除的子树里」，再让 consume 登记：否则 vendor 之下每一层
                // 目录都会被当成一次独立的 skipDirectories 命中，台账的根因就散了。
                let nested = plan.isInsideExcluded(url.path)
                // Darwin Foundation 的枚举器只有 skipDescendants()（skipSubtree 是 corelibs-foundation 独有）
                if plan.consume(url) {
                    result.skipLedger.record(nested ? .excludedDirectoryNested : .skippedDirectory,
                                             path: url.path, bytes: 0,
                                             rule: nested ? nil : entryName)
                    // 审计模式要逐文件归因子树内容，所以不掐子树；正常扫描必须掐（性能 + 逃逸防线）
                    if auditing == false { enumerator.skipDescendants() }
                }
                continue
            }

            if values?.isRegularFile == false {
                result.skipLedger.record(.notARegularFile, path: url.path, bytes: bytes, rule: nil)
                continue
            }
            if let anchor = plan.excludedAnchor(for: url.path) {
                result.skipLedger.record(.excludedDirectoryContent, path: url.path, bytes: bytes, rule: anchor)
                auditLines(of: url, bytes: bytes, reason: .excludedDirectoryContent,
                           into: &result.skipLedger, anchor: anchor)
                continue
            }

            let rejection = candidateRejection(url, values: values)

            // 探测模式：这些文件没有被读、也没有被计入任何计数，只用来判断「还有没有候选文件」。
            // 一发现确实还有未处理的候选文件，就确认「真的截断了」并立即收工。
            if probingForRemainingCandidates {
                if rejection == nil {
                    result.truncatedByMaxFiles = true
                    result.skipLedger.cappedRemaining = true
                    break
                }
                continue
            }

            result.visitedFileCount += 1
            guard let rejection else {
                candidateCount += 1
                batch.append(url)
                if batch.count >= Self.batchSize {
                    let urls = batch
                    batch.removeAll(keepingCapacity: true)
                    let files = await Self.classifyConcurrently(urls: urls, root: scanRoot, options: options)
                    merge(files, attempted: urls, into: &result)
                }
                // `candidateCount == maxFiles` 本身不代表丢过文件：恰好等于上限的目录一个文件都不该少。
                // 因此命中上限时先不置位，只继续廉价探测是否有下一个候选文件。
                if candidateCount >= options.maxFiles { probingForRemainingCandidates = true }
                continue
            }

            result.skippedFileCount += 1
            result.skipLedger.record(rejection.reason, path: url.path, bytes: bytes, rule: rejection.rule)
            auditLines(of: url, bytes: bytes, reason: rejection.reason, into: &result.skipLedger)
        }

        let files = await Self.classifyConcurrently(urls: batch, root: scanRoot, options: options)
        merge(files, attempted: batch, into: &result)
        return result
    }

    /// 判定一个文件条目是不是候选；返回 nil 表示候选。同时给出命中的具体规则项，供台账归因。
    /// 判定顺序与内容必须与 `ScanOptions` 的语义一致：无后缀 → 二进制后缀 → 语言表没有 → 超字节上限。
    private func candidateRejection(_ url: URL, values: URLResourceValues?)
        -> (reason: SourceSkipReason, rule: String?)? {
        let ext = url.pathExtension.lowercased()
        if ext.isEmpty { return (reason: .missingExtension, rule: nil) }
        if binaryExtensions.contains(ext) { return (reason: .binaryExtension, rule: ext) }
        if SourceLanguageCatalog.language(forExtension: ext) == nil {
            return (reason: .unsupportedExtension, rule: ext)
        }
        if let size = values?.fileSize, size > options.maxFileBytes {
            return (reason: .oversize, rule: ByteFormat.string(UInt64(size)))
        }
        return nil
    }

    /// 包状目录：macOS 的 bundle 后缀。`FileManager` 的 `.skipsPackageDescendants` 按这套规则剪枝，
    /// 这里必须用同一套名单，否则台账归因和枚举器实际行为不一致。
    private static let packageExtensions: Set<String> = [
        "app", "framework", "bundle", "xcodeproj", "xcworkspace", "lproj", "xcassets",
        "dsym", "playbook", "kext", "component", "plugin", "pkg", "prefpane",
        "colorpicker", "imgblock", "qd", "rule", "stage", "workflow", "mdimporter",
        "qlgenerator", "sdef", "spotlightizer", "termext", "webplugin", "internetplug-in",
    ]

    private func isPackageDirectory(_ name: String) -> Bool {
        Self.packageExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// 审计模式：展开被枚举器剪掉的子树，把「剪掉了几个文件、多少行」归因清楚。
    /// `readLines = false` 时只记条数与字节（隐藏子树走这条路，绝不读内容）。
    private func auditPrunedSubtree(of url: URL, into ledger: inout SourceSkipLedger,
                                    reason: SourceSkipReason, readLines: Bool) {
        guard auditing else { return }
        var fileCount = 0
        var totalBytes: Int64 = 0
        var totalLines = 0
        let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [], errorHandler: { _, _ in false }
        )
        while let item = walker?.nextObject() as? URL {
            guard (try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]))?
                .isRegularFile != false else { continue }
            let values = try? item.resourceValues(forKeys: [.fileSizeKey])
            let size = Int64(values?.fileSize ?? 0)
            fileCount += 1
            totalBytes += max(0, size)
            if readLines, size > 0, size <= ledger.remainingAuditBytes(within: auditLineBudget),
               let data = try? Data(contentsOf: item) {
                var lines = 0
                for byte in data where byte == 0x0A { lines += 1 }
                totalLines += lines
                ledger.auditedBytes += Int64(data.count)
            } else if readLines, size > 0 {
                ledger.linesBudgetExhausted = true
            }
        }
        guard fileCount > 0 else { return }
        var bucket = ledger.buckets[reason] ?? SourceSkipLedger.Bucket()
        bucket.files += fileCount
        bucket.bytes += totalBytes
        bucket.lines += totalLines
        // 没有后缀的包状目录（如 `.bundle`）用目录名当键，否则台账会出现空键、读不出根因。
        let ext = (url.lastPathComponent as NSString).pathExtension.lowercased()
        let key = ext.isEmpty ? url.lastPathComponent : ext
        bucket.rules[key, default: 0] += 1
        bucket.lineRules[key, default: 0] += totalLines
        if bucket.samples.count < SourceSkipLedger.sampleLimit { bucket.samples.append(url.path) }
        ledger.buckets[reason] = bucket
    }

    /// 审计模式专用：把被剔除文件的真实行数读出来。非审计模式（预算 0）直接返回，零额外 I/O。
    private func auditLines(of url: URL, bytes: Int64, reason: SourceSkipReason,
                            into ledger: inout SourceSkipLedger, anchor: String? = nil) {
        guard auditing else { return }
        guard bytes > 0 else { return }
        let remaining = ledger.remainingAuditBytes(within: auditLineBudget)
        guard bytes <= remaining else {
            ledger.linesBudgetExhausted = true
            return
        }
        guard let data = try? Data(contentsOf: url) else { return }
        var lines = 0
        for byte in data where byte == 0x0A { lines += 1 }
        ledger.recordAuditedLines(reason, lines: lines, bytes: Int64(data.count), anchor: anchor)
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

    private func merge(_ files: [ScannedSourceFile], attempted urls: [URL], into result: inout SourceScanResult) {
        result.files.append(contentsOf: files)
        result.scannedFileCount += files.count
        result.lineTruncatedFileCount += files.filter { $0.lineCountTruncated }.count
        // 候选名单里但最终没出结果的 = 分类阶段读不出内容（权限 / IO / 非目录），逐条记进台账。
        let accepted = Set(files.map { $0.url.path })
        for url in urls where accepted.contains(url.path) == false {
            result.skippedFileCount += 1
            result.skipLedger.record(.unreadable, path: url.path, bytes: 0, rule: nil)
        }
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
