import Foundation

// OWNER: Workstream A (静态代码分析) —— SourceScanTrail
//
// 从 SourceFileClassifier.swift 拆出，只为守住本工作流的红线（巨大文件不得增加、
// 单函数不超过约 50 行 / CC 16）。原先 `SourceTreeScanner.scan` 是 134 行 / CC 36 的一整段，
// 这里按**原来那一条判定链的书写顺序**把每个条目切成一小段：隐藏项 → 符号链接 → 包状目录 →
// 普通目录 → 非普通文件 → 被剔除子树里的文件 → 候选 / 剔除。
//
// 计数口径（visited / skipped / scanned 三个数各自的归属）、台账归因键、`skipDescendants()`
// 的位置、探测模式「恰好等于上限不算截断」的语义，全部一字未改。
// 可见性：原先的 `private` 跨文件后放宽到模块内可见（同 FunctionRecognition.swift 顶部的说明），
// 除可见性外没有任何变化；`SourceTreeScanner` 本身仍是唯一入口。

/// 一次目录遍历的累加器：结果 + 待分类批次 + 「是否已进入探测模式」。
/// 原先这些都是 `scan(root:)` 里的局部量，拆成条目处理器之后需要一个能整体传下去的家。
struct SourceScanProgress {
    /// 本次遍历实际使用的根（可能是解析过目录软链接的形态，见 `enumerationRoot(for:)`）。
    let root: URL
    var result = SourceScanResult()
    var plan: SourceSkipPlan
    var batch: [URL] = []
    var candidateCount = 0
    /// 达到上限后进入「探测模式」：只判断后面是否还有候选文件，用来如实置 truncatedByMaxFiles。
    var probingForRemainingCandidates = false

    init(root: URL, options: ScanOptions) {
        self.root = root
        plan = SourceSkipPlan(root: root, options: options)
    }
}

extension SourceTreeScanner {

    /// `.isDirectoryKey` 必须在列：URLResourceValues 只回填请求过的键，
    /// 漏掉它会让目录判定恒为 nil，skipDirectories / 符号链接兜底全部失效。
    /// 本 SDK 没有 `URLResourceKey.isDirectoryPackageKey`（与 `canonicalItemPathKey` 同一类坑，
    /// 见 `SourceRelativePath.pathForms` 的说明），所以"枚举器会不会把这个目录当 bundle 剪掉"
    /// 只能由 `enumeratorPrunesDirectory(_:)` 自己复刻判据 —— 它多问一次 `Info.plist` 是否存在，
    /// 不走资源键。
    static let resourceKeys: [URLResourceKey] = [
        .isRegularFileKey, .isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey, .nameKey,
    ]

    /// 隐藏项**不用** `.skipsHiddenFiles`：那样枚举器根本不会交出这些条目，剔除台账就无从统计。
    /// 改为在循环里按 `name` 判定并记账，纳入/排除的结果与原来完全一致。
    static let enumerationOptions: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]

    /// 文件级并发的两个上限（从 SourceTreeScanner 一起搬来，数值未变）：
    /// 一批最多攒 `batchSize` 个 url 再分类，同时在飞的分类任务不超过 `concurrencyLimit`。
    static let concurrencyLimit = 16
    static let batchSize = 256

    /// 处理一个条目。返回 false 表示遍历该就地收工（原实现里探测模式命中的那处 `break`）。
    /// **分支顺序即原 scan 循环体的书写顺序**，谁命中谁记账并结束本条目。
    func consume(_ url: URL, enumerator: FileManager.DirectoryEnumerator,
                 into progress: inout SourceScanProgress) async -> Bool {
        let values = try? url.resourceValues(forKeys: Set(Self.resourceKeys))
        let bytes = Int64(values?.fileSize ?? 0)
        let entryName = values?.name ?? url.lastPathComponent
        // 先观察树形（只加计数、不改任何归类判定），再交给下面那条既有判定链。
        observeRepositoryMarker(url, values: values, entryName: entryName, progress: &progress)

        if consumeHiddenEntry(url, values: values, bytes: bytes, entryName: entryName,
                              enumerator: enumerator, progress: &progress) { return true }
        if consumeSymbolicLinkEntry(url, values: values, bytes: bytes, enumerator: enumerator,
                                    progress: &progress) { return true }
        if consumeDirectoryEntry(url, values: values, entryName: entryName,
                                 enumerator: enumerator, progress: &progress) { return true }
        if consumeNonRegularFile(url, values: values, bytes: bytes, progress: &progress) { return true }
        if consumeFileInsideExcludedDirectory(url, bytes: bytes, progress: &progress) { return true }

        let rejection = candidateRejection(url, values: values)
        // 探测模式：这些文件没有被读、也没有被计入任何计数，只用来判断「还有没有候选文件」。
        // 一发现确实还有未处理的候选文件，就确认「真的截断了」并立即收工。
        if progress.probingForRemainingCandidates { return probingOutcome(for: rejection, progress: &progress) }
        await consumeVisitedEntry(url, values: values, bytes: bytes, rejection: rejection, progress: &progress)
        return true
    }

    /// 达到上限之后的探测：命中候选就确认截断，其余条目一律不动任何计数。
    private func probingOutcome(for rejection: (reason: SourceSkipReason, rule: String?)?,
                                progress: inout SourceScanProgress) -> Bool {
        guard rejection == nil else { return true }
        progress.result.truncatedByMaxFiles = true
        progress.result.skipLedger.cappedRemaining = true
        return false
    }

    /// 记一个版本库标记（`.git` / `.hg` / `.svn` / `.bzr`）。**只观察不判定**：
    /// 谁被剪掉、谁进统计，全由下面那条既有链决定，这里只留「看到过几个仓库」。
    /// `.git` 既可能是目录（嵌套仓库）也可能是文件（submodule 的 `gitdir:` 指针），两种都算一个。
    private func observeRepositoryMarker(_ url: URL, values: URLResourceValues?, entryName: String,
                                         progress: inout SourceScanProgress) {
        guard SourceTreeFollowingLedger.repositoryMarkerNames.contains(entryName) else { return }
        // 「是不是根自己那一个」按**相对路径深度**判，不按父路径字符串相等判：
        // 枚举器交出的目录 URL 可能带尾斜杠，两种写法比出来永远不相等（实测把根自己的
        // `.git` 数成了嵌套仓库）。相对路径复用 `SourceFileClassifier.relativePath`，
        // 它已经把 /tmp→/private/tmp 那套形态差异处理掉了。
        let relative = SourceFileClassifier.relativePath(for: url, root: progress.root)
        progress.result.treeFollowing.observeRepositoryMarker(
            isDirectory: values?.isDirectory == true,
            isAtScanRoot: relative.contains("/") == false)
    }

    // MARK: - 逐类条目

    /// 隐藏项：includeHidden = false 时目录连带掐掉子树。只进台账，不进 visited/skipped 计数，
    /// 以保持与改用 .skipsHiddenFiles 之前的既有计数完全一致。
    private func consumeHiddenEntry(_ url: URL, values: URLResourceValues?, bytes: Int64,
                                    entryName: String, enumerator: FileManager.DirectoryEnumerator,
                                    progress: inout SourceScanProgress) -> Bool {
        guard options.includeHidden == false, entryName.hasPrefix(".") else { return false }
        if values?.isDirectory == true {
            enumerator.skipDescendants()
            // 隐藏子树在审计模式下要能报「剪掉了多少文件」，否则台账有洞；
            // 但**绝不读内容** —— 隐藏目录里常有 .ssh / .env / 密钥。
            auditPrunedSubtree(of: url, into: &progress.result.skipLedger,
                               reason: .prunedHiddenContents, readLines: false)
        }
        progress.result.skipLedger.record(.hiddenEntry, path: url.path,
                                          bytes: values?.isDirectory == true ? 0 : bytes, rule: entryName)
        return true
    }

    /// 符号链接：目录链接先掐掉子树再跳过（不跟随 = 不逃逸、不死循环），文件链接直接跳过。
    private func consumeSymbolicLinkEntry(_ url: URL, values: URLResourceValues?, bytes: Int64,
                                          enumerator: FileManager.DirectoryEnumerator,
                                          progress: inout SourceScanProgress) -> Bool {
        guard values?.isSymbolicLink == true else { return false }
        if values?.isDirectory == true { enumerator.skipDescendants() }
        // 目标只 stat 一次、绝不读内容：跟随软链接去数目标子树正是本流刻意不做的事。
        let resolved = url.resolvingSymlinksInPath()
        let targetKind = (try? FileManager.default.attributesOfItem(atPath: resolved.path))?[.type]
            as? FileAttributeType
        progress.result.treeFollowing.observeSymbolicLink(
            isDirectory: targetKind == .typeDirectory,
            // `fileExists` 会**穿过**软链接去 stat 目标，悬空链接因此返回 false；
            // `attributesOfItem` 用的是 lstat（拿到的是链接自己），判存在性会永远为真。
            targetResolvable: FileManager.default.fileExists(atPath: url.path))
        progress.result.skipLedger.record(.symbolicLink, path: url.path, bytes: bytes, rule: nil)
        return true
    }

    private func consumeDirectoryEntry(_ url: URL, values: URLResourceValues?, entryName: String,
                                       enumerator: FileManager.DirectoryEnumerator,
                                       progress: inout SourceScanProgress) -> Bool {
        guard values?.isDirectory == true else { return false }
        // 两条剪枝判据都要落账：**我们的后缀名单**，以及枚举器自己的 bundle 判定。
        // 只认名单的话，名单外被剪掉的目录（`*.xcarchive` 这类）就成了台账解释不掉的黑洞。
        let listed = isPackageDirectory(entryName)
        if listed || enumeratorPrunesDirectory(url) {
            progress.result.treeFollowing.observePackageDirectory(listed: listed, name: entryName)
            // `.skipsPackageDescendants` 会让枚举器交出这个目录、但不进入其内容 ——
            // 不记一笔就是台账解释不掉的黑洞（Homebrew 实测 NewApp.app + 4 个 .dSYM 共 9 个文件）。
            progress.result.skipLedger.record(.prunedPackageDir, path: url.path, bytes: 0,
                                              rule: packageRuleKey(entryName, listed: listed))
            auditPrunedSubtree(of: url, into: &progress.result.skipLedger,
                               reason: .prunedPackageContents, readLines: true)
            return true
        }
        // 先问「是不是已经在被剔除的子树里」，再让 consume 登记：否则 vendor 之下每一层
        // 目录都会被当成一次独立的 skipDirectories 命中，台账的根因就散了。
        let nested = progress.plan.isInsideExcluded(url.path)
        // Darwin Foundation 的枚举器只有 skipDescendants()（skipSubtree 是 corelibs-foundation 独有）
        if progress.plan.consume(url) {
            progress.result.skipLedger.record(nested ? .excludedDirectoryNested : .skippedDirectory,
                                              path: url.path, bytes: 0,
                                              rule: nested ? nil : entryName)
            // 审计模式要逐文件归因子树内容，所以不掐子树；正常扫描必须掐（性能 + 逃逸防线）
            if auditing == false { enumerator.skipDescendants() }
        }
        return true
    }

    private func consumeNonRegularFile(_ url: URL, values: URLResourceValues?, bytes: Int64,
                                       progress: inout SourceScanProgress) -> Bool {
        guard values?.isRegularFile == false else { return false }
        progress.result.skipLedger.record(.notARegularFile, path: url.path, bytes: bytes, rule: nil)
        return true
    }

    private func consumeFileInsideExcludedDirectory(_ url: URL, bytes: Int64,
                                                    progress: inout SourceScanProgress) -> Bool {
        guard let anchor = progress.plan.excludedAnchor(for: url.path) else { return false }
        progress.result.skipLedger.record(.excludedDirectoryContent, path: url.path, bytes: bytes, rule: anchor)
        auditLines(of: url, bytes: bytes, reason: .excludedDirectoryContent,
                   into: &progress.result.skipLedger, anchor: anchor)
        return true
    }

    /// 已确定进入统计视野的条目：要么是可分析候选（进批次），要么被规则剔除（进台账）。
    private func consumeVisitedEntry(_ url: URL, values: URLResourceValues?, bytes: Int64,
                                     rejection: (reason: SourceSkipReason, rule: String?)?,
                                     progress: inout SourceScanProgress) async {
        progress.result.visitedFileCount += 1
        guard let rejection else {
            await acceptCandidate(url, progress: &progress)
            return
        }
        progress.result.skippedFileCount += 1
        progress.result.skipLedger.record(rejection.reason, path: url.path, bytes: bytes, rule: rejection.rule)
        auditLines(of: url, bytes: bytes, reason: rejection.reason, into: &progress.result.skipLedger,
                   anchor: skipAnchor(reason: rejection.reason, rule: rejection.rule))
    }

    private func acceptCandidate(_ url: URL, progress: inout SourceScanProgress) async {
        progress.candidateCount += 1
        progress.batch.append(url)
        if progress.batch.count >= Self.batchSize {
            let urls = progress.batch
            progress.batch.removeAll(keepingCapacity: true)
            let files = await classify(urls: urls, root: progress.root)
            merge(files, attempted: urls, into: &progress.result)
        }
        // `candidateCount == maxFiles` 本身不代表丢过文件：恰好等于上限的目录一个文件都不该少。
        // 因此命中上限时先不置位，只继续廉价探测是否有下一个候选文件。
        if progress.candidateCount >= options.maxFiles { progress.probingForRemainingCandidates = true }
    }

    /// 收尾：把最后一个不满一批的候选名单分类掉（原实现里 scan 的最后一行）。
    func flush(_ progress: inout SourceScanProgress) async {
        let urls = progress.batch
        let files = await classify(urls: urls, root: progress.root)
        merge(files, attempted: urls, into: &progress.result)
    }

    // MARK: - 候选判定与包状目录

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

    /// 台账的行数归因键：后缀类规则用后缀本身，「无后缀」「超体积上限」这类没有名字可指的给一个稳定标签。
    private func skipAnchor(reason: SourceSkipReason, rule: String?) -> String? {
        switch reason {
        case .missingExtension: return "（无后缀）"
        case .oversize: return "体积超单文件上限"
        case .unsupportedExtension, .binaryExtension: return rule
        default: return rule
        }
    }


    // MARK: - 批次分类与结果合并

    private func classify(urls: [URL], root: URL) async -> [ScannedSourceFile] {
        let options = self.options
        return await withTaskGroup(of: ScannedSourceFile?.self, returning: [ScannedSourceFile].self) { group in
            var output: [ScannedSourceFile] = []
            output.reserveCapacity(urls.count)
            var index = 0
            let running = min(Self.concurrencyLimit, urls.count)
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

    private func merge(_ files: [ScannedSourceFile], attempted urls: [URL],
                       into result: inout SourceScanResult) {
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

    // MARK: - 审计模式：被剔除条目的行数归因

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
        ledger.recordAuditedLines(reason, lines: newlineCount(in: data),
                                  bytes: Int64(data.count), anchor: anchor)
    }

    /// 审计模式：展开被枚举器剪掉的子树，把「剪掉了几个文件、多少行」归因清楚。
    /// `readLines = false` 时只记条数与字节（隐藏子树走这条路，绝不读内容）。
    private func auditPrunedSubtree(of url: URL, into ledger: inout SourceSkipLedger,
                                    reason: SourceSkipReason, readLines: Bool) {
        guard auditing else { return }
        let tally = walkPrunedSubtree(of: url, readLines: readLines, into: &ledger)
        guard tally.files > 0 else { return }
        recordPrunedSubtree(tally, of: url, reason: reason, into: &ledger)
    }

    /// 子树走一遍的累计结果。
    private struct SubtreeTally {
        var files = 0
        var bytes: Int64 = 0
        var lines = 0
    }

    private func walkPrunedSubtree(of url: URL, readLines: Bool,
                                   into ledger: inout SourceSkipLedger) -> SubtreeTally {
        var tally = SubtreeTally()
        let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [], errorHandler: { _, _ in false }
        )
        while let item = walker?.nextObject() as? URL {
            guard (try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]))?
                .isRegularFile != false else { continue }
            let values = try? item.resourceValues(forKeys: [.fileSizeKey])
            let size = Int64(values?.fileSize ?? 0)
            tally.files += 1
            tally.bytes += max(0, size)
            readPrunedSubtreeLines(of: item, size: size, readLines: readLines, into: &ledger, tally: &tally)
        }
        return tally
    }

    /// 「读了就计入行数、读不动就如实标预算耗尽」这两支保持原来的 `if / else if` 判据。
    private func readPrunedSubtreeLines(of item: URL, size: Int64, readLines: Bool,
                                        into ledger: inout SourceSkipLedger,
                                        tally: inout SubtreeTally) {
        guard readLines, size > 0 else { return }
        guard size <= ledger.remainingAuditBytes(within: auditLineBudget),
              let data = try? Data(contentsOf: item) else {
            ledger.linesBudgetExhausted = true
            return
        }
        tally.lines += newlineCount(in: data)
        ledger.auditedBytes += Int64(data.count)
    }

    private func recordPrunedSubtree(_ tally: SubtreeTally, of url: URL, reason: SourceSkipReason,
                                     into ledger: inout SourceSkipLedger) {
        var bucket = ledger.buckets[reason] ?? SourceSkipLedger.Bucket()
        bucket.files += tally.files
        bucket.bytes += tally.bytes
        bucket.lines += tally.lines
        // 没有后缀的包状目录（如 `.bundle`）用目录名当键，否则台账会出现空键、读不出根因。
        let ext = (url.lastPathComponent as NSString).pathExtension.lowercased()
        let key = ext.isEmpty ? url.lastPathComponent : ext
        bucket.rules[key, default: 0] += 1
        bucket.lineRules[key, default: 0] += tally.lines
        if bucket.samples.count < SourceSkipLedger.sampleLimit { bucket.samples.append(url.path) }
        ledger.buckets[reason] = bucket
    }

    /// 按换行字节数行数（与分析器其余处 `wc -l` 的口径一致）。
    private func newlineCount(in data: Data) -> Int {
        var lines = 0
        for byte in data where byte == 0x0A { lines += 1 }
        return lines
    }
}
