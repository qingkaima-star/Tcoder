import Foundation

struct DuplicationResult: Sendable {
    var ratio: Double
    var duplicatedCodeLines: Int
    var totalCodeLines: Int
    var blocks: [DuplicatedBlock]
}

enum DuplicationEngine {

    static let windowSize: Int = 6

    /// 归一化后长度低于此值的行一律丢弃。**单位是 UTF-8 字节**（`DupLex.normalizeBytes` 走字节管线，
    /// 折出来的占位符全是 ASCII，所以按字节量最贴近指纹的真实成本）。
    /// 取 4 的依据：标识符已折成 `I`，4 字节刚好放过 `i = N`、`I ( I )` 这类最短有效语句，
    /// 而 `}`、`);`、`})`、`I I`（`return keep`）这些 1~3 字节样板行全部落榜。
    /// 注意：这条只是**指纹通道**的入门门槛；对外的 `normalize(_:language:)` 还额外要求
    /// ≥3 个含字母/数字的词元（见下面 `normalize` 的注释），所以 `normalize("i = N")` 是 nil。
    static let minNormalizedBytes: Int = 4

    /// 单文件参与滑窗的归一化行数上限：超长文件（生成的/打包的）会吃掉整轮预算，硬截断。
    private static let maxWindowedLines = 20_000
    private static let maxBlocks = 20

    // MARK: - Normalization

    /// 归一化一行：折叠空白、丢弃注释、数字/字符串/标识符分别换成 `N` / `S` / `I` 占位符。
    /// 返回 nil 表示该行丢弃（空行、注释行、纯标点、以及撑不起指纹的短样板行）。
    static func normalize(_ text: String, language: String) -> String? {
        guard let bytes = DupLex.normalizeBytes(text, syntax: DupLex.buildLineSyntax(language: language)) else { return nil }
        let result = String(decoding: bytes, as: UTF8.self)
        // 对外的「这一行算不算有效代码行」判据，比指纹通道更严一档：
        // 指纹通道只要行长/词元数达标（`DupLex.normalizeBytes` 末尾四条），这里再要求 ≥3 个
        // 含字母或数字的词元，`a + b`（`I + I`，2 个）与 `return totalPayable`（`I I`）
        // 因此对外为 nil。两档不一致是刻意的：把这条 3 词元规则并回指纹通道，实测
        // Homebrew 的可检出重复行从 22297 掉到 5019（-77%），召回损失远大于噪声收益。
        let informativeTokens = result.split(separator: " ").filter { token in
            token.contains { $0.isLetter || $0.isNumber }
        }.count
        return informativeTokens >= 3 ? result : nil
    }

    // MARK: - Analysis

    /// 全库重复检测。**统计口径（与 `CodeMetrics.codeLines` 对齐）：**
    /// - 分母 `totalCodeLines` = 全部文件里 `kind == .code` 的行数之和，逐行等价于
    ///   `Σ file.codeLineCount`（注释行与空行不进分母；归一化丢掉的样板行**仍算分母**，
    ///   否则「全仓库都是 `}` 和空行」会被算成 0 行代码而虚报重复率）。
    /// - 分子 `duplicatedCodeLines` = 所有命中克隆覆盖到的代码行的**并集**大小：
    ///   同一行被多个块覆盖只计一次，因此恒有 `duplicatedCodeLines <= totalCodeLines`，
    ///   且 `ratio == Double(duplicatedCodeLines) / Double(totalCodeLines)`（不做二次截断）。
    /// - 克隆**包括同一文件内部的粘贴拷贝**（同一路径、不同 `startLine` 的两个片段），
    ///   与 jscpd / PMD-CPD 的常规口径一致：文件内部复制粘贴同样是维护风险。
    /// - `blocks` 是 ratio 的**明细样本**（按 `lineCount` 降序取前 20，且只收「至少新增一行
    ///   未被覆盖的重复行」的块），ratio 统计全部命中、不受 20 上限约束，否则大仓库的
    ///   重复率会被榜单截断人为压低。
    /// - `block.lineCount` 是**归一化后的代码行数**（滑窗只吃代码行），不是源码首末行跨度：
    ///   中间夹了注释/空行时，`startLine + lineCount` 会越过克隆的真实末行。
    ///   冻结的 `DuplicatedFragment` 只有 `startLine`、没有终点行，这是契约缺口（要精确跨度得给
    ///   `DuplicatedFragment` 加 `endLine`，由总工裁决；本文件不动 Models）。
    static func analyze(_ files: [ScannedSourceFile]) -> DuplicationResult {
        // 扫描器并发分类，`files` 的到达顺序每次运行都可能不同，而这里的贪婪锚点式扫描
        // 结果依赖处理顺序（同一棵树的 ratio 会在 ±0.2% 之间抖）。先按路径规范化排序，
        // 保证同一输入永远给出同样的 ratio / 同样的榜单，也让指纹预算留下「哪几个文件」是确定的。
        let files = files.sorted { lhs, rhs in
            if lhs.relativePath != rhs.relativePath { return lhs.relativePath < rhs.relativePath }
            return lhs.url.path < rhs.url.path
        }

        var totalCodeLines = 0
        for file in files {
            for line in file.lines where line.kind == .code { totalCodeLines += 1 }
        }
        // 只有一个文件时整体不参评：冻结单测把「单文件 → ratio 0」写成了验收口径
        // （`testUnrelatedFilesReportNoDuplication`），因此纯单文件项目的内部粘贴不计。
        guard files.count >= 2, totalCodeLines >= windowSize * 2 else {
            return DuplicationResult(ratio: 0, duplicatedCodeLines: 0, totalCodeLines: totalCodeLines, blocks: [])
        }

        var scan = ScanState(fileCount: files.count, windowBudget: totalCodeLines)
        var syntaxCache = [String: DupLex.LineSyntax]()

        for (fileIndex, file) in files.enumerated() {
            let syntax: DupLex.LineSyntax
            if let cached = syntaxCache[file.language] {
                syntax = cached
            } else {
                syntax = DupLex.buildLineSyntax(language: file.language)
                syntaxCache[file.language] = syntax
            }

            var numbers = [Int]()
            numbers.reserveCapacity(min(file.lines.count, maxWindowedLines))
            var starts = [Int]()
            var lengths = [Int]()
            var chunks = [UInt8]()
            chunks.reserveCapacity(min(file.lines.count, maxWindowedLines) * 24)

            for line in file.lines {
                guard line.kind == .code else { continue }
                guard numbers.count < maxWindowedLines else { break }
                guard let bytes = DupLex.normalizeBytes(line.text, syntax: syntax) else { continue }
                starts.append(chunks.count)
                lengths.append(bytes.count)
                chunks.append(contentsOf: bytes)
                numbers.append(line.number)
            }

            let lineCount = numbers.count
            var hashes = [UInt64]()
            if lineCount >= windowSize {
                hashes.reserveCapacity(lineCount - windowSize + 1)
                var windowStart = 0
                while windowStart + windowSize <= lineCount {
                    hashes.append(windowFingerprint(chunks: chunks, starts: starts, lengths: lengths,
                                                    from: windowStart, size: windowSize))
                    windowStart += 1
                }
            }
            scan.beginFile(numbers: numbers, hashes: hashes)

            // 每个窗口都登记指纹（带每指纹/每文件预算），只作为「这 6 行别处也出现过」的配对索引；
            // 别处包括**同一文件的另一处**（内部粘贴）。长克隆靠 hashesByFile 现场延长，
            // 不为同一克隆重复存多条记录。
            var windowStart = 0
            while windowStart < hashes.count {
                scan.register(hash: hashes[windowStart], fileIndex: fileIndex, windowStart: windowStart)
                windowStart += 1
            }
        }

        // 逐文件顺序扫窗口：碰到一个尚未归入任何克隆、且在别处（别的文件，或同一文件的另一段）
        // 也出现过的指纹，就以它为锚点，挑「可信且延长得最长」的配对把整段克隆吃掉 ——
        // 相邻/重叠窗口由此合并成一个长块，每个克隆只展开一次，整体代价与窗口数线性。
        // 同文件配对额外要求两段窗口不重叠（`candidate.windowStart >= windowStart + windowSize`）：
        // 否则相邻窗口永远互为克隆，整段代码会被自己「复制」成无限长。
        // 已知盲区（刻意接受）：一个文件里**每一行归一化后都长成同一个形状**的表（如
        // `let rowN = fetch(N) * k` 连排几百行）内部再粘贴一份时，同指纹组里能记下的同文件
        // 偏移全是最贴近的 1~预算数行（原始文本并不相同），真正的「整段抄了一份」那个偏移
        // 挤不进预算，于是这段自拷贝不进 ratio；实测这种合成文件（100 行 × 2 份）报 0%。
        // 跨文件同形状拷贝不受影响（别的文件的片段占独立配额），实测 Homebrew 只损失 1% 以内的
        // 相对量；把预算开大并不能补这个洞（要补得给每文件建 hash→偏移全量索引，代价是内存）。
        var blocks: [DuplicatedBlock] = []
        blocks.reserveCapacity(maxBlocks)

        for fileIndex in 0..<files.count {
            let hashes = scan.hashesByFile[fileIndex]
            var windowStart = 0
            while windowStart < hashes.count {
                defer { windowStart += 1 }
                if scan.isConsumed(fileIndex: fileIndex, windowStart: windowStart) { continue }
                guard let group = scan.registered[hashes[windowStart]] else { continue }

                // 配对择优顺序：**先要求这一对过相似度门槛，再比谁延长得更长**。
                // 只按「最长」选的话，形状统一的区域里相邻窗口互为最长配对（原始文本一行都不重），
                // 整块会被 `DupLex.minCloneSimilarity` 否掉并顺手消费掉窗口，反而把可达的真拷贝陪葬；
                // 改成可信优先后 Homebrew 多检出 215 行（22082 → 22297，+1.0% 相对），
                // 代价是重复检测阶段 105 → 130ms（每个可达锚点多算几次逐行比对）。
                var best: Occurrence?
                var bestExtent = -1
                var bestSimilar = false

                let anchorFragment = CloneFragment(fileIndex: fileIndex, windowStart: windowStart)
                for candidate in group where candidate.fileIndex != fileIndex
                    || candidate.windowStart >= windowStart + windowSize {
                    let extra = scan.growClone(from: windowStart, in: fileIndex,
                                               to: candidate.windowStart, in: candidate.fileIndex)
                    // 已经拿到过可信配对，落后于它的候选不必再付相似度的代价
                    if extra <= bestExtent, bestSimilar { continue }
                    let similar = rawTextMatchRatio(files: files,
                                                    anchor: anchorFragment,
                                                    anchorNumbers: scan.numbersByFile[fileIndex],
                                                    other: candidate.fragment,
                                                    otherNumbers: scan.numbersByFile[candidate.fileIndex],
                                                    lineCount: extra + windowSize) >= DupLex.minCloneSimilarity
                    let wins = (similar && (!bestSimilar || extra > bestExtent))
                        || (!similar && !bestSimilar && extra > bestExtent)
                    guard wins else { continue }
                    best = candidate
                    bestExtent = extra
                    bestSimilar = similar
                }
                guard let partner = best, bestExtent >= 0 else { continue }

                let partnerFragment = CloneFragment(fileIndex: partner.fileIndex, windowStart: partner.windowStart)
                let members = scan.extraMembers(of: hashes[windowStart], anchor: anchorFragment, extent: bestExtent)
                if let block = scan.commitClone(anchor: anchorFragment, partner: partnerFragment, members: members,
                                                extent: bestExtent, files: files) {
                    blocks.append(block)
                }
                // 锚点一侧的整段窗口已被消费，直接跳到克隆之后继续
                windowStart += bestExtent
            }
        }

        var duplicatedCodeLines = 0
        for fileIndex in scan.covered.indices {
            let flags = scan.covered[fileIndex]
            let numbers = scan.numbersByFile[fileIndex]
            var union = IndexSet()
            for index in flags.indices where flags[index] && index < numbers.count {
                union.insert(numbers[index])
            }
            duplicatedCodeLines += union.count
        }

        if blocks.count > 1 {
            blocks.sort { lhs, rhs in
                if lhs.lineCount != rhs.lineCount { return lhs.lineCount > rhs.lineCount }
                return lhs.id < rhs.id
            }
        }
        // 冻结的 `DuplicatedBlock.id` 只由「出现文件集合 + lineCount」拼成，两个长度相同的
        // 不同克隆会撞同一个 id（SwiftUI ForEach 会报 duplicate identifiers 并错乱 diff）。
        // 契约缺口不能改 Models，这里按 id 去重后再截断到 20：**只削明细榜单，不动 ratio**。
        var seenIDs = Set<String>()
        blocks = blocks.filter { seenIDs.insert($0.id).inserted }
        if blocks.count > maxBlocks { blocks.removeSubrange(maxBlocks...) }

        let ratio = totalCodeLines == 0
            ? 0
            : min(max(Double(duplicatedCodeLines) / Double(totalCodeLines), 0), 1)
        return DuplicationResult(ratio: ratio,
                                 duplicatedCodeLines: duplicatedCodeLines,
                                 totalCodeLines: totalCodeLines,
                                 blocks: blocks)
    }
}

// MARK: - Window fingerprint

private func windowFingerprint(chunks: [UInt8], starts: [Int], lengths: [Int], from: Int, size: Int) -> UInt64 {
    var hash = DupLex.fnvOffsetBase
    var index = from
    let end = from + size
    while index < end {
        if index > from { hash = (hash ^ UInt64(DupLex.newlineByte)) &* DupLex.fnvPrime }
        let stop = starts[index] + lengths[index]
        var cursor = starts[index]
        while cursor < stop {
            hash = (hash ^ UInt64(chunks[cursor])) &* DupLex.fnvPrime
            cursor += 1
        }
        index += 1
    }
    return hash
}

// MARK: - Clone accumulation

fileprivate struct Occurrence {
    var fileIndex: Int
    var windowStart: Int

    /// 配对登记只是「位置」，进块时要当片段用。
    var fragment: CloneFragment { CloneFragment(fileIndex: fileIndex, windowStart: windowStart) }
}

fileprivate struct CloneFragment {
    var fileIndex: Int
    var windowStart: Int
}

fileprivate struct ScanState {
    /// 锚点指纹 → 该 6 行窗口内容在各文件里的出现位置（每指纹预算封顶，内存换精度）。
    /// 只用于「这个窗口在别的文件也出现过吗」的配对；把相邻窗口合并成长块由
    /// `growClone` 直接在 `hashesByFile` 上向前延长，不依赖这里的多条记录。
    var registered: [UInt64: [Occurrence]]
    var numbersByFile: [[Int]]
    var hashesByFile: [[UInt64]]
    var covered: [[Bool]]
    var consumed: [[Bool]]

    init(fileCount: Int, windowBudget: Int) {
        registered = [UInt64: [Occurrence]]()
        registered.reserveCapacity(min(windowBudget, DupLex.runsCapacityCap))
        numbersByFile = [[Int]]()
        numbersByFile.reserveCapacity(fileCount)
        hashesByFile = [[UInt64]]()
        hashesByFile.reserveCapacity(fileCount)
        covered = [[Bool]]()
        covered.reserveCapacity(fileCount)
        consumed = [[Bool]]()
        consumed.reserveCapacity(fileCount)
    }

    mutating func beginFile(numbers: [Int], hashes: [UInt64]) {
        numbersByFile.append(numbers)
        hashesByFile.append(hashes)
        covered.append([Bool](repeating: false, count: numbers.count))
        consumed.append([Bool](repeating: false, count: hashes.count))
    }

    mutating func register(hash: UInt64, fileIndex: Int, windowStart: Int) {
        var group = registered[hash] ?? []
        // 同一文件的片段在组里一定是连续的一段、并且总在尾部（登记按「逐文件、文件内逐窗口」
        // 的顺序进行），所以从尾部往回数就能拿到本文件已记的条数：代价只跟这个数有关，
        // 跟每组预算 `DupLex.maxOccurrencesPerHash` 无关 —— 预算调大时这里不会跟着变慢。
        var sameFile = 0
        var cursor = group.count
        while cursor > 0 {
            cursor -= 1
            guard group[cursor].fileIndex == fileIndex else { break }
            sameFile += 1
        }
        // 每个指纹最多留 `DupLex.maxOccurrencesPerHash` 处、单个文件最多留 `DupLex.maxRunsPerFileAndHash` 处，
        // 再多的拷贝仍然会被 ratio 覆盖到（它们与已存锚点同一段克隆），只是不再展开。
        guard group.count < DupLex.maxOccurrencesPerHash, sameFile < DupLex.maxRunsPerFileAndHash else { return }
        group.append(Occurrence(fileIndex: fileIndex, windowStart: windowStart))
        registered[hash] = group
    }

    func isConsumed(fileIndex: Int, windowStart: Int) -> Bool {
        guard fileIndex >= 0, fileIndex < consumed.count else { return true }
        let flags = consumed[fileIndex]
        guard windowStart >= 0, windowStart < flags.count else { return true }
        return flags[windowStart]
    }

    /// 两边窗口指纹连续一致的长度（不含锚点窗口本身），即克隆还能向后延长几个窗口。
    func growClone(from anchor: Int, in anchorFile: Int, to other: Int, in otherFile: Int) -> Int {
        guard anchorFile >= 0, anchorFile < hashesByFile.count,
              otherFile >= 0, otherFile < hashesByFile.count else { return 0 }
        let left = hashesByFile[anchorFile]
        let right = hashesByFile[otherFile]
        var extra = 0
        while anchor + extra + 1 < left.count, other + extra + 1 < right.count,
              left[anchor + extra + 1] == right[other + extra + 1] {
            extra += 1
        }
        return extra
    }

    /// 同一锚点指纹在**别处**的出现位置（别的文件，或同一文件里不重叠的另一段），
    /// 只要整段窗口序列都对得上，就并进同一个块。
    func extraMembers(of hash: UInt64, anchor: CloneFragment, extent: Int) -> [CloneFragment] {
        guard let group = registered[hash] else { return [] }
        guard anchor.fileIndex >= 0, anchor.fileIndex < hashesByFile.count else { return [] }
        let anchorHashes = hashesByFile[anchor.fileIndex]
        guard anchor.windowStart >= 0, anchor.windowStart + extent < anchorHashes.count else { return [] }
        var result: [CloneFragment] = []
        result.reserveCapacity(DupLex.maxFragmentsPerBlock)
        for item in group {
            // 与锚点循环同样的「同文件必须不重叠」约束，否则会把相邻窗口当成第二份拷贝。
            if item.fileIndex == anchor.fileIndex,
               item.windowStart < anchor.windowStart + DuplicationEngine.windowSize { continue }
            guard result.count < DupLex.maxFragmentsPerBlock else { break }
            guard item.fileIndex >= 0, item.fileIndex < hashesByFile.count else { continue }
            let other = hashesByFile[item.fileIndex]
            guard item.windowStart >= 0, item.windowStart + extent < other.count else { continue }
            var offset = 0
            var matches = true
            while offset <= extent {
                if other[item.windowStart + offset] != anchorHashes[anchor.windowStart + offset] {
                    matches = false
                    break
                }
                offset += 1
            }
            if matches { result.append(CloneFragment(fileIndex: item.fileIndex, windowStart: item.windowStart)) }
        }
        return result
    }

    /// 认领整段克隆：算相似度、打窗口消费标记 + 行覆盖，然后产出明细块。
    mutating func commitClone(anchor: CloneFragment, partner: CloneFragment, members: [CloneFragment],
                              extent: Int, files: [ScannedSourceFile]) -> DuplicatedBlock? {
        var picked: [CloneFragment] = [anchor]
        var seenFragments = Set<String>(["\(anchor.fileIndex):\(anchor.windowStart)"])
        for candidate in [partner] + members {
            guard candidate.fileIndex >= 0, candidate.fileIndex < files.count else { continue }
            guard candidate.windowStart >= 0,
                  candidate.windowStart < numbersByFile[candidate.fileIndex].count else { continue }
            // 同一文件里的不同片段是合法的第二次拷贝，只按「文件 + 起点窗口」去重。
            guard seenFragments.insert("\(candidate.fileIndex):\(candidate.windowStart)").inserted else { continue }
            picked.append(candidate)
        }
        // 明细硬上限：一个块最多列 `DupLex.maxFragmentsPerBlock` 处（冻结单测钉着「occurrences ≤ 6」）。
        // 配对的指纹预算（`DupLex.maxOccurrencesPerHash`）比它大，所以这里必须再截一次；
        // 被截掉的那几处不会漏进 ratio —— 锚点循环走到它自己的窗口时会另立一块。
        if picked.count > DupLex.maxFragmentsPerBlock { picked.removeSubrange(DupLex.maxFragmentsPerBlock...) }
        guard picked.count >= 2 else { return nil }

        let size = DuplicationEngine.windowSize
        let lineCount = extent + size

        // 相似度门槛：归一化后同指纹但**原始文本一行都不重**的，只是形状巧合（例如两份
        // 结构相同的 switch 表），不是用户眼里的「拷贝粘贴」，不进榜也不算重复行。
        var kept: [CloneFragment] = []
        var occurrences: [DuplicatedFragment] = []
        var similarity = 1.0
        for fragment in picked {
            if fragment.fileIndex == anchor.fileIndex, fragment.windowStart == anchor.windowStart {
                kept.append(fragment)
                occurrences.append(fragmentOf(anchor, files: files))
                continue
            }
            let ratio = rawTextMatchRatio(files: files,
                                          anchor: anchor, anchorNumbers: numbersByFile[anchor.fileIndex],
                                          other: fragment, otherNumbers: numbersByFile[fragment.fileIndex],
                                          lineCount: lineCount)
            guard ratio >= DupLex.minCloneSimilarity else { continue }
            similarity = min(similarity, ratio)
            kept.append(fragment)
            occurrences.append(fragmentOf(fragment, files: files))
        }
        guard kept.count >= 2, occurrences.count >= 2 else {
            // 整块作废也要把锚点这一侧的窗口吃掉，否则同一个形状会被逐窗口重试一遍（O(N²)）
            markConsumed(anchor, extent: extent)
            return nil
        }

        // 「零新增覆盖」的块直接丢掉（但窗口照例消费掉）：同一族克隆常常被不同锚点各报一次，
        // 长的先上榜、短的后上榜，短块的所有行早已被长块覆盖。留着它既不改变 ratio，
        // 又白占 20 个明细位里的一格，榜单里还会出现两个几乎一样的块。
        if kept.allSatisfy({ fragment in addsNoCoverage(fragment, extent: extent) }) {
            for fragment in kept { markConsumed(fragment, extent: extent) }
            return nil
        }

        for fragment in kept {
            markConsumed(fragment, extent: extent)
            markCoverage(fragment, extent: extent)
        }
        return DuplicatedBlock(occurrences: occurrences,
                               lineCount: lineCount,
                               similarity: min(max(similarity, 0), 1))
    }

    /// 这段片段覆盖的窗口是不是**全部**已经被别的块覆盖过（用于丢掉零新增覆盖的冗余块）。
    private func addsNoCoverage(_ fragment: CloneFragment, extent: Int) -> Bool {
        guard fragment.fileIndex >= 0, fragment.fileIndex < covered.count else { return false }
        let flags = covered[fragment.fileIndex]
        var index = max(fragment.windowStart, 0)
        let stop = min(fragment.windowStart + extent + DuplicationEngine.windowSize, flags.count)
        guard index < stop else { return false }
        while index < stop {
            if flags[index] == false { return false }
            index += 1
        }
        return true
    }

    private func fragmentOf(_ fragment: CloneFragment, files: [ScannedSourceFile]) -> DuplicatedFragment {
        DuplicatedFragment(path: files[fragment.fileIndex].url.path,
                           startLine: numbersByFile[fragment.fileIndex][fragment.windowStart])
    }

    private mutating func markConsumed(_ fragment: CloneFragment, extent: Int) {
        guard fragment.fileIndex < consumed.count else { return }
        var index = max(fragment.windowStart, 0)
        let stop = min(fragment.windowStart + extent + 1, consumed[fragment.fileIndex].count)
        while index < stop {
            consumed[fragment.fileIndex][index] = true
            index += 1
        }
    }

    private mutating func markCoverage(_ fragment: CloneFragment, extent: Int) {
        guard fragment.fileIndex < covered.count else { return }
        var index = max(fragment.windowStart, 0)
        let stop = min(fragment.windowStart + extent + DuplicationEngine.windowSize,
                       covered[fragment.fileIndex].count)
        while index < stop {
            covered[fragment.fileIndex][index] = true
            index += 1
        }
    }
}

/// 相似度口径：归一化后同一指纹的行，其**原始文本**（忽略缩进）有多少是一样的 ——
/// 逐字拷贝得 1.0，改名拷贝得 0.x，视图上的「相似度」因此不会永远显示 100%。
private func rawTextMatchRatio(files: [ScannedSourceFile],
                               anchor: CloneFragment, anchorNumbers: [Int],
                               other: CloneFragment, otherNumbers: [Int],
                               lineCount: Int) -> Double {
    guard lineCount > 0, anchor.fileIndex < files.count, other.fileIndex < files.count else { return 1 }
    var same = 0
    for offset in 0..<lineCount {
        guard let left = rawText(files[anchor.fileIndex], anchorNumbers, anchor.windowStart + offset),
              let right = rawText(files[other.fileIndex], otherNumbers, other.windowStart + offset) else { continue }
        if left == right { same += 1 }
    }
    return Double(same) / Double(lineCount)
}

private func rawText(_ file: ScannedSourceFile, _ numbers: [Int], _ keptIndex: Int) -> Substring? {
    guard keptIndex >= 0, keptIndex < numbers.count else { return nil }
    let lineNumber = numbers[keptIndex]
    guard lineNumber >= 1, lineNumber <= file.lines.count else { return nil }
    return file.lines[lineNumber - 1].text.drop { $0 == " " || $0 == "\t" }
}
