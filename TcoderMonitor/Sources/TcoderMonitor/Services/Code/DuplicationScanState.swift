import Foundation

// OWNER: Workstream A (静态代码分析) —— DuplicationScanState
//
// 从 DuplicationEngine.swift 拆出，只为守住本工作流的红线（巨大文件不得增加、
// 单函数不超过约 50 行 / CC 16）：**配对预算、窗口推进步长、相似度门槛、消费标记的
// 打点顺序一字未改**。
// 原先 `ScanState` / `Occurrence` / `CloneFragment` 是本文件 fileprivate 顶层符号，
// 直接放宽成 internal 会往模块里丢一批通用名（本仓为 `ScanState` 专门立过这条规矩，
// 见 CodeLineNormalization.swift 顶部说明），所以收进 `DuplicationScanState` 之下当嵌套类型。
//
// `commitClone` 原来是 63 行 / CC 14 的一整段，这里按「挑候选 → 过相似度 → 记账产块」
// 三段切开，产物与原来逐字段等价。

/// 全库重复检测的扫描态：指纹配对索引 + 每文件的窗口/行号 + 消费与覆盖标记。
struct DuplicationScanState {

    struct Fragment {
        var fileIndex: Int
        var windowStart: Int
    }

    struct Occurrence {
        var fileIndex: Int
        var windowStart: Int

        /// 配对登记只是「位置」，进块时要当片段用。
        var fragment: Fragment { Fragment(fileIndex: fileIndex, windowStart: windowStart) }
    }

    /// 锚点指纹 → 该 6 行窗口内容在各文件里的出现位置（每指纹预算封顶，内存换精度）。
    /// 只用于「这个窗口在别的文件也出现过吗」的配对；把相邻窗口合并成长块由
    /// `growClone` 直接在 `hashesByFile` 上向前延长，不依赖这里的多条记录。
    var registered: [UInt64: [Occurrence]]
    var numbersByFile: [[Int]]
    var hashesByFile: [[UInt64]]
    var covered: [[Bool]]
    var consumed: [[Bool]]

    /// 因预算被拒登记的窗口数（配对用不上，明细也就看不见它们）
    var droppedFragments = 0

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
        guard group.count < DupLex.maxOccurrencesPerHash, sameFile < DupLex.maxRunsPerFileAndHash else {
            droppedFragments += 1
            return
        }
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
    func extraMembers(of hash: UInt64, anchor: Fragment, extent: Int) -> [Fragment] {
        guard let group = registered[hash] else { return [] }
        guard anchor.fileIndex >= 0, anchor.fileIndex < hashesByFile.count else { return [] }
        let anchorHashes = hashesByFile[anchor.fileIndex]
        guard anchor.windowStart >= 0, anchor.windowStart + extent < anchorHashes.count else { return [] }
        var result: [Fragment] = []
        result.reserveCapacity(DupLex.maxFragmentsPerBlock)
        for item in group {
            // 与锚点循环同样的「同文件必须不重叠」约束，否则会把相邻窗口当成第二份拷贝。
            if item.fileIndex == anchor.fileIndex,
               item.windowStart < anchor.windowStart + DuplicationEngine.windowSize { continue }
            guard result.count < DupLex.maxFragmentsPerBlock else { break }
            guard item.fileIndex >= 0, item.fileIndex < hashesByFile.count else { continue }
            let other = hashesByFile[item.fileIndex]
            guard item.windowStart >= 0, item.windowStart + extent < other.count else { continue }
            if windowSeriesMatches(anchorHashes, anchor: anchor.windowStart,
                                   other, otherStart: item.windowStart, extent: extent) {
                result.append(Fragment(fileIndex: item.fileIndex, windowStart: item.windowStart))
            }
        }
        return result
    }

    /// 两侧从各自起点起的 `extent + 1` 个窗口指纹是否逐格相同（原实现内联在 extraMembers 里）。
    func windowSeriesMatches(_ left: [UInt64], anchor: Int,
                             _ right: [UInt64], otherStart: Int, extent: Int) -> Bool {
        var offset = 0
        while offset <= extent {
            if right[otherStart + offset] != left[anchor + offset] { return false }
            offset += 1
        }
        return true
    }
}

// MARK: - 认领克隆并产出明细块

extension DuplicationScanState {

    /// 认领整段克隆：挑候选片段、按相似度门槛留人、打窗口消费标记 + 行覆盖，最后产出明细块。
    ///
    /// 三条早退分支的位置与原来一致：候选不足两处不算块；过完门槛不足两处、或整段
    /// 零新增覆盖时，**照例把锚点/kept 的窗口吃掉**再返回 nil —— 否则同一个形状会被
    /// 逐窗口重试一遍（O(N²)）。
    mutating func commitClone(anchor: Fragment, partner: Fragment, members: [Fragment],
                              extent: Int, files: [ScannedSourceFile]) -> DuplicatedBlock? {
        let picked = candidateFragments(anchor: anchor, partner: partner, members: members, files: files)
        guard picked.count >= 2 else { return nil }
        let lineCount = extent + DuplicationEngine.windowSize
        let scored = retainedFragments(picked: picked, anchor: anchor, lineCount: lineCount, files: files)

        guard scored.kept.count >= 2, scored.occurrences.count >= 2 else {
            // 整块作废也要把锚点这一侧的窗口吃掉，否则同一个形状会被逐窗口重试一遍（O(N²)）
            markConsumed(anchor, extent: extent)
            return nil
        }
        // 「零新增覆盖」的块直接丢掉（但窗口照例消费掉）：同一族克隆常常被不同锚点各报一次，
        // 长的先上榜、短的后上榜，短块的所有行早已被长块覆盖。留着它既不改变 ratio，
        // 又白占 20 个明细位里的一格，榜单里还会出现两个几乎一样的块。
        if scored.kept.allSatisfy({ fragment in addsNoCoverage(fragment, extent: extent) }) {
            for fragment in scored.kept { markConsumed(fragment, extent: extent) }
            return nil
        }
        for fragment in scored.kept {
            markConsumed(fragment, extent: extent)
            markCoverage(fragment, extent: extent)
        }
        return DuplicatedBlock(occurrences: scored.occurrences,
                               lineCount: lineCount,
                               similarity: min(max(scored.similarity, 0), 1))
    }

    /// 同一份克隆里的候选片段：锚点 + 配对 + 同指纹别处出现的位置。
    /// 明细硬上限：一个块最多列 `DupLex.maxFragmentsPerBlock` 处（冻结单测钉着「occurrences ≤ 6」）。
    /// 配对的指纹预算（`DupLex.maxOccurrencesPerHash`）比它大，所以这里必须再截一次；
    /// 被截掉的那几处不会漏进 ratio —— 锚点循环走到它自己的窗口时会另立一块。
    func candidateFragments(anchor: Fragment, partner: Fragment, members: [Fragment],
                            files: [ScannedSourceFile]) -> [Fragment] {
        var picked: [Fragment] = [anchor]
        var seenFragments = Set<String>(["\(anchor.fileIndex):\(anchor.windowStart)"])
        for candidate in [partner] + members {
            guard candidate.fileIndex >= 0, candidate.fileIndex < files.count else { continue }
            guard candidate.windowStart >= 0,
                  candidate.windowStart < numbersByFile[candidate.fileIndex].count else { continue }
            // 同一文件里的不同片段是合法的第二次拷贝，只按「文件 + 起点窗口」去重。
            guard seenFragments.insert("\(candidate.fileIndex):\(candidate.windowStart)").inserted else { continue }
            picked.append(candidate)
        }
        if picked.count > DupLex.maxFragmentsPerBlock { picked.removeSubrange(DupLex.maxFragmentsPerBlock...) }
        return picked
    }

    /// 相似度门槛：归一化后同指纹但**原始文本一行都不重**的，只是形状巧合（例如两份
    /// 结构相同的 switch 表），不是用户眼里的「拷贝粘贴」，不进榜也不算重复行。
    func retainedFragments(picked: [Fragment], anchor: Fragment, lineCount: Int,
                           files: [ScannedSourceFile])
        -> (kept: [Fragment], occurrences: [DuplicatedFragment], similarity: Double) {
        var kept: [Fragment] = []
        var occurrences: [DuplicatedFragment] = []
        var similarity = 1.0
        for fragment in picked {
            if fragment.fileIndex == anchor.fileIndex, fragment.windowStart == anchor.windowStart {
                kept.append(fragment)
                occurrences.append(fragmentOf(anchor, files: files))
                continue
            }
            let ratio = DuplicationScan.rawTextMatchRatio(files: files,
                                                          anchor: anchor, anchorNumbers: numbersByFile[anchor.fileIndex],
                                                          other: fragment, otherNumbers: numbersByFile[fragment.fileIndex],
                                                          lineCount: lineCount)
            guard ratio >= DupLex.minCloneSimilarity else { continue }
            similarity = min(similarity, ratio)
            kept.append(fragment)
            occurrences.append(fragmentOf(fragment, files: files))
        }
        return (kept, occurrences, similarity)
    }

    /// 这段片段覆盖的窗口是不是**全部**已经被别的块覆盖过（用于丢掉零新增覆盖的冗余块）。
    private func addsNoCoverage(_ fragment: Fragment, extent: Int) -> Bool {
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

    /// 块坐标的**唯一生产点**（RD-61 第二半）。给的是 `duplicationCoordinate`
    /// （相对被扫根），不是 `url.path`（绝对）：`DuplicatedBlock.id` 由这里的路径拼成，
    /// 绝对形状等于把检出目录写进块身份，同一段克隆在两台机器上就变成两个块。
    /// 屏上（`CodeDuplicationBlockRow`）、落盘（`occurrences` 与
    /// `CodeMetrics.duplicateBlockCoordinatesOutsideBoard`）、句子（`boardCaliberNote`）
    /// 三处读者因此拿到同一个形状，谁都不许再剥一遍前缀；要把坐标还原成绝对路径，
    /// 只有 `CodeViewFormat.resolvedURL(_:root:)` 那一个入口。
    private func fragmentOf(_ fragment: Fragment, files: [ScannedSourceFile]) -> DuplicatedFragment {
        DuplicatedFragment(path: files[fragment.fileIndex].duplicationCoordinate,
                           startLine: numbersByFile[fragment.fileIndex][fragment.windowStart])
    }

    private mutating func markConsumed(_ fragment: Fragment, extent: Int) {
        guard fragment.fileIndex < consumed.count else { return }
        var index = max(fragment.windowStart, 0)
        let stop = min(fragment.windowStart + extent + 1, consumed[fragment.fileIndex].count)
        while index < stop {
            consumed[fragment.fileIndex][index] = true
            index += 1
        }
    }

    private mutating func markCoverage(_ fragment: Fragment, extent: Int) {
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
