import Foundation

// OWNER: Workstream A (静态代码分析) —— DuplicationScan
//
// 从 DuplicationEngine.swift 拆出，只为守住本工作流的红线（巨大文件不得增加、
// 单函数不超过约 50 行 / CC 16）：`analyze` 原来 181 行 / CC 36，是本次自扫点名最高的
// 代码包热点。**四个阶段的先后顺序、每个阶段的判据与推进步长一字未改**，
// 只是把「一次调用干完所有事」切成四个各自小于 50 行的阶段函数。
//
// 状态与克隆认领的字段级实现留在 `DuplicationScanState.swift`。

/// 全库重复检测的四个阶段：分母 → 建指纹与配对索引 → 锚点展开成块 → 明细榜单与覆盖并集。
enum DuplicationScan {

    // MARK: - 阶段 1：分母

    /// 全部文件里 `kind == .code` 的行数之和，逐行等价于 `Σ file.codeLineCount`。
    static func countCodeLines(_ files: [ScannedSourceFile]) -> Int {
        var totalCodeLines = 0
        for file in files {
            for line in file.lines where line.kind == .code { totalCodeLines += 1 }
        }
        return totalCodeLines
    }

    // MARK: - 阶段 2：逐文件建指纹与配对索引

    /// 一个文件归一化之后的滑窗原料。
    struct NormalizedFile {
        var numbers: [Int] = []
        var starts: [Int] = []
        var lengths: [Int] = []
        var chunks: [UInt8] = []
        /// 归一化行数触到 `maxWindowedLines` 而被丢弃后半部分
        var hitCap = false
    }

    /// 逐文件顺序建索引：先归一化出窗口指纹，再把每个窗口登记进配对索引。
    static func buildIndex(files: [ScannedSourceFile], totalCodeLines: Int)
        -> (scan: DuplicationScanState, filesHittingLineCap: Int) {
        var scan = DuplicationScanState(fileCount: files.count, windowBudget: totalCodeLines)
        var syntaxCache = [String: DupLex.LineSyntax]()
        var filesHittingLineCap = 0

        for (fileIndex, file) in files.enumerated() {
            let normalized = normalizedLines(of: file, syntax: lineSyntax(of: file, cache: &syntaxCache))
            if normalized.hitCap { filesHittingLineCap += 1 }
            let hashes = windowHashes(of: normalized)
            scan.beginFile(numbers: normalized.numbers, hashes: hashes)
            registerAllWindows(scan: &scan, hashes: hashes, fileIndex: fileIndex)
        }
        return (scan, filesHittingLineCap)
    }

    static func lineSyntax(of file: ScannedSourceFile,
                           cache: inout [String: DupLex.LineSyntax]) -> DupLex.LineSyntax {
        if let cached = cache[file.language] { return cached }
        let made = DupLex.buildLineSyntax(language: file.language)
        cache[file.language] = made
        return made
    }

    /// 逐行归一化。**先判 `.code`、再判行数上限、最后才付归一化的代价**，顺序与原实现一致：
    /// 上限判定在归一化之前，所以「触顶」的位置只取决于代码行数，与能否归一化无关。
    static func normalizedLines(of file: ScannedSourceFile,
                                syntax: DupLex.LineSyntax) -> NormalizedFile {
        var out = NormalizedFile()
        out.numbers.reserveCapacity(min(file.lines.count, DuplicationEngine.maxWindowedLines))
        out.chunks.reserveCapacity(min(file.lines.count, DuplicationEngine.maxWindowedLines) * 24)
        for line in file.lines {
            guard line.kind == .code else { continue }
            guard out.numbers.count < DuplicationEngine.maxWindowedLines else { out.hitCap = true; break }
            guard let bytes = DupLex.normalizeBytes(line.text, syntax: syntax) else { continue }
            out.starts.append(out.chunks.count)
            out.lengths.append(bytes.count)
            out.chunks.append(contentsOf: bytes)
            out.numbers.append(line.number)
        }
        return out
    }

    /// 长度恰好 `windowSize` 行的滑动窗口指纹序列。
    static func windowHashes(of normalized: NormalizedFile) -> [UInt64] {
        let lineCount = normalized.numbers.count
        guard lineCount >= DuplicationEngine.windowSize else { return [] }
        var hashes = [UInt64]()
        hashes.reserveCapacity(lineCount - DuplicationEngine.windowSize + 1)
        var windowStart = 0
        while windowStart + DuplicationEngine.windowSize <= lineCount {
            hashes.append(windowFingerprint(chunks: normalized.chunks,
                                            starts: normalized.starts,
                                            lengths: normalized.lengths,
                                            from: windowStart,
                                            size: DuplicationEngine.windowSize))
            windowStart += 1
        }
        return hashes
    }

    /// 每个窗口都登记指纹（带每指纹/每文件预算），只作为「这 6 行别处也出现过」的配对索引；
    /// 别处包括**同一文件的另一处**（内部粘贴）。长克隆靠 hashesByFile 现场延长，
    /// 不为同一克隆重复存多条记录。
    static func registerAllWindows(scan: inout DuplicationScanState, hashes: [UInt64], fileIndex: Int) {
        var windowStart = 0
        while windowStart < hashes.count {
            scan.register(hash: hashes[windowStart], fileIndex: fileIndex, windowStart: windowStart)
            windowStart += 1
        }
    }

    static func windowFingerprint(chunks: [UInt8], starts: [Int], lengths: [Int],
                                  from: Int, size: Int) -> UInt64 {
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
}

// MARK: - 阶段 3：锚点展开成克隆块

extension DuplicationScan {

    /// 配对择优结果：候选片段本身，加上它能把克隆再往后延长几个窗口。
    struct Partner {
        var fileIndex: Int
        var windowStart: Int
        var extent: Int
    }

    /// 逐文件顺序扫窗口：碰到一个尚未归入任何克隆、且在别处（别的文件，或同一文件的另一段）
    /// 也出现过的指纹，就以它为锚点，挑「可信且延长得最长」的配对把整段克隆吃掉 ——
    /// 相邻/重叠窗口由此合并成一个长块，每个克隆只展开一次，整体代价与窗口数线性。
    /// 同文件配对额外要求两段窗口不重叠（`candidate.windowStart >= windowStart + windowSize`）：
    /// 否则相邻窗口永远互为克隆，整段代码会被自己「复制」成无限长。
    /// 已知盲区（刻意接受）：一个文件里**每一行归一化后都长成同一个形状**的表（如
    /// `let rowN = fetch(N) * k` 连排几百行）内部再粘贴一份时，同指纹组里能记下的同文件
    /// 偏移全是最贴近的 1~预算数行（原始文本并不相同），真正的「整段抄了一份」那个偏移
    /// 挤不进预算，于是这段自拷贝不进 ratio；实测这种合成文件（100 行 × 2 份）报 0%。
    /// 跨文件同形状拷贝不受影响（别的文件的片段占独立配额），实测 Homebrew 只损失 1% 以内的
    /// 相对量；把预算开大并不能补这个洞（要补得给每文件建 hash→偏移全量索引，代价是内存）。
    static func collectBlocks(files: [ScannedSourceFile], scan: inout DuplicationScanState)
        -> [DuplicatedBlock] {
        var blocks: [DuplicatedBlock] = []
        blocks.reserveCapacity(DuplicationEngine.maxBlocks)

        for fileIndex in 0..<files.count {
            let hashes = scan.hashesByFile[fileIndex]
            var windowStart = 0
            while windowStart < hashes.count {
                defer { windowStart += 1 }
                if scan.isConsumed(fileIndex: fileIndex, windowStart: windowStart) { continue }
                guard let group = scan.registered[hashes[windowStart]] else { continue }
                let anchor = DuplicationScanState.Fragment(fileIndex: fileIndex, windowStart: windowStart)
                guard let partner = bestPartner(anchor: anchor, group: group, files: files, scan: scan)
                else { continue }
                let members = scan.extraMembers(of: hashes[windowStart], anchor: anchor, extent: partner.extent)
                if let block = scan.commitClone(anchor: anchor,
                                                partner: DuplicationScanState.Fragment(
                                                    fileIndex: partner.fileIndex, windowStart: partner.windowStart),
                                                members: members,
                                                extent: partner.extent,
                                                files: files) {
                    blocks.append(block)
                }
                // 锚点一侧的整段窗口已被消费，直接跳到克隆之后继续
                windowStart += partner.extent
            }
        }
        return blocks
    }

    /// 配对择优顺序：**先要求这一对过相似度门槛，再比谁延长得更长**。
    /// 只按「最长」选的话，形状统一的区域里相邻窗口互为最长配对（原始文本一行都不重），
    /// 整块会被 `DupLex.minCloneSimilarity` 否掉并顺手消费掉窗口，反而把可达的真拷贝陪葬；
    /// 改成可信优先后 Homebrew 多检出 215 行（22082 → 22297，+1.0% 相对），
    /// 代价是重复检测阶段 105 → 130ms（每个可达锚点多算几次逐行比对）。
    static func bestPartner(anchor: DuplicationScanState.Fragment, group: [DuplicationScanState.Occurrence],
                            files: [ScannedSourceFile], scan: DuplicationScanState) -> Partner? {
        let fileIndex = anchor.fileIndex
        let windowStart = anchor.windowStart
        var best: DuplicationScanState.Occurrence?
        var bestExtent = -1
        var bestSimilar = false

        for candidate in group where candidate.fileIndex != fileIndex
            || candidate.windowStart >= windowStart + DuplicationEngine.windowSize {
            let extra = scan.growClone(from: windowStart, in: fileIndex,
                                       to: candidate.windowStart, in: candidate.fileIndex)
            // 已经拿到过可信配对，落后于它的候选不必再付相似度的代价
            if extra <= bestExtent, bestSimilar { continue }
            let similar = rawTextMatchRatio(files: files,
                                            anchor: anchor,
                                            anchorNumbers: scan.numbersByFile[fileIndex],
                                            other: candidate.fragment,
                                            otherNumbers: scan.numbersByFile[candidate.fileIndex],
                                            lineCount: extra + DuplicationEngine.windowSize)
                >= DupLex.minCloneSimilarity
            let wins = (similar && (!bestSimilar || extra > bestExtent))
                || (!similar && !bestSimilar && extra > bestExtent)
            guard wins else { continue }
            best = candidate
            bestExtent = extra
            bestSimilar = similar
        }
        // 原实现是 `guard let partner = best, bestExtent >= 0`：best 与 bestExtent 同时置位，
        // 所以「没挑到配对」等价于返回 nil。
        guard let partner = best else { return nil }
        return Partner(fileIndex: partner.fileIndex, windowStart: partner.windowStart, extent: bestExtent)
    }
}

// MARK: - 阶段 4：明细榜单与覆盖行并集

extension DuplicationScan {

    /// 覆盖行并集：同一行被多个块覆盖只计一次，因此恒有 `duplicatedCodeLines <= totalCodeLines`。
    static func duplicatedCodeLines(scan: DuplicationScanState) -> Int {
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
        return duplicatedCodeLines
    }

    /// 明细榜单收尾：按行数降序、按 id 去重、截断到 `maxBlocks`。
    /// 冻结的 `DuplicatedBlock.id` 只由「出现文件集合 + lineCount」拼成，两个长度相同的
    /// 不同克隆会撞同一个 id（SwiftUI ForEach 会报 duplicate identifiers 并错乱 diff）。
    /// 契约缺口不能改 Models，这里按 id 去重后再截断到 20：**只削明细榜单，不动 ratio**。
    ///
    /// 榜外坐标（返回值的第四项）**就是 `id` 本身**，一个字都不再加工：
    /// RD-52 那一半曾在这里补过一次「按根剥前缀」（`relativeCoordinates`），
    /// 因为当时生产点给的是绝对路径。RD-61 第二半把坐标在唯一生产点
    /// （`DuplicationScanState.fragmentOf`）就定成相对被扫根，那层加工于是变成
    /// 第二次猜前缀 —— 已删除。保留的边界：它当时撑住的那条 ≤1,200 字符的门禁
    /// 判据一字未动，改由 `OutsideBoardCoordinatesTests` 与
    /// `DuplicateCoordinatePortabilityTests` 两把尺子共同盯（后者量两棵不同深度的根）。
    static func rankedBlocks(_ input: [DuplicatedBlock])
        -> (blocks: [DuplicatedBlock], droppedByCap: Int, linesOutsideReportedBlocks: Int,
                 outsideBoardCoordinates: [String]) {
        var blocks = input
        if blocks.count > 1 {
            blocks.sort { lhs, rhs in
                if lhs.lineCount != rhs.lineCount { return lhs.lineCount > rhs.lineCount }
                return lhs.id < rhs.id
            }
        }
        var seenIDs = Set<String>()
        blocks = blocks.filter { seenIDs.insert($0.id).inserted }
        guard blocks.count > DuplicationEngine.maxBlocks else { return (blocks, 0, 0, []) }
        let dropped = blocks[DuplicationEngine.maxBlocks...]
        return (Array(blocks.prefix(DuplicationEngine.maxBlocks)),
                dropped.count,
                dropped.map(\.lineCount).reduce(0, +),   // 明细外的行数（ratio 已含，只是不列明细）
                // 榜外块的稳定坐标：`id` 由「涉及路径排序拼接 + 行数」构成，与榜单同一把排序键，
                // 所以同一份输入永远给出同一串（RD-17：不许只留一个总数）。
                dropped.prefix(DuplicationScan.outsideBoardSampleLimit).map(\.id))
    }

    /// 榜外坐标最多点这几个名字。再多就把一行限制说明撑成一段散文；
    /// 未点名的数量仍在 `droppedByCap` 里，不会因此消失。
    static let outsideBoardSampleLimit = 6

    /// 相似度口径：归一化后同一指纹的行，其**原始文本**（忽略缩进）有多少是一样的 ——
    /// 逐字拷贝得 1.0，改名拷贝得 0.x，视图上的「相似度」因此不会永远显示 100%。
    static func rawTextMatchRatio(files: [ScannedSourceFile],
                                  anchor: DuplicationScanState.Fragment, anchorNumbers: [Int],
                                  other: DuplicationScanState.Fragment, otherNumbers: [Int],
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

    static func rawText(_ file: ScannedSourceFile, _ numbers: [Int], _ keptIndex: Int) -> Substring? {
        guard keptIndex >= 0, keptIndex < numbers.count else { return nil }
        let lineNumber = numbers[keptIndex]
        guard lineNumber >= 1, lineNumber <= file.lines.count else { return nil }
        return file.lines[lineNumber - 1].text.drop { $0 == " " || $0 == "\t" }
    }
}
