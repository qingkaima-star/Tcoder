import Foundation

struct DuplicationResult: Sendable {
    var ratio: Double
    var duplicatedCodeLines: Int
    var totalCodeLines: Int
    var blocks: [DuplicatedBlock]
}

enum DuplicationEngine {

    static let windowSize: Int = 6

    /// 归一化后长度低于此值（UTF-8 字节，见 `normalizeBytes` 末尾阈值注释）的行一律丢弃。
    /// 取 4 的依据：标识符已折成 `I`，4 字节刚好放过 `i = N`、`I ( I )` 这类最短有效语句，
    /// 而 `}`、`);`、`})`、`I I`（`return keep`）这些 1~3 字节样板行全部落榜。
    static let minSignificantRunes: Int = 4

    /// 单文件参与滑窗的归一化行数上限：超长文件（生成的/打包的）会吃掉整轮预算，硬截断。
    private static let maxWindowedLines = 20_000
    private static let maxBlocks = 20

    // MARK: - Normalization

    /// 归一化一行：折叠空白、丢弃注释、数字/字符串/标识符分别换成 `N` / `S` / `I` 占位符。
    /// 返回 nil 表示该行丢弃（空行、注释行、纯标点、以及撑不起指纹的短样板行）。
    static func normalize(_ text: String, language: String) -> String? {
        guard let bytes = normalizeBytes(text, syntax: buildLineSyntax(language: language)) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Analysis

    /// 全库重复检测。
    /// - `ratio` = 被重复片段覆盖的代码行数 / 全部代码行数（同一行只算一次，注释行与空行不进分母）。
    /// - `blocks` 按覆盖行数降序取前 20 个，是 ratio 的**明细样本**；ratio 统计的是全部命中，
    ///   不受 20 个上限约束（否则大仓库的重复率会被榜单截断人为压低）。
    static func analyze(_ files: [ScannedSourceFile]) -> DuplicationResult {
        var totalCodeLines = 0
        for file in files {
            for line in file.lines where line.kind == .code { totalCodeLines += 1 }
        }
        guard files.count >= 2, totalCodeLines >= windowSize * 2 else {
            return DuplicationResult(ratio: 0, duplicatedCodeLines: 0, totalCodeLines: totalCodeLines, blocks: [])
        }

        var scan = ScanState(fileCount: files.count, windowBudget: totalCodeLines)
        var syntaxCache = [String: LineSyntax]()

        for (fileIndex, file) in files.enumerated() {
            let syntax: LineSyntax
            if let cached = syntaxCache[file.language] {
                syntax = cached
            } else {
                syntax = buildLineSyntax(language: file.language)
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
                guard let bytes = normalizeBytes(line.text, syntax: syntax) else { continue }
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

            // 只登记「该窗口在跨文件处第一次出现」的指纹：同文件相邻窗口靠 hashes 向前延长，
            // 不需要为每个窗口都留一条记录，窗口级内存因此与文件数线性而非与拷贝次数相关。
            var windowStart = 0
            while windowStart < hashes.count {
                scan.register(hash: hashes[windowStart], fileIndex: fileIndex, windowStart: windowStart)
                windowStart += 1
            }
        }

        // 逐文件顺序扫窗口：碰到一个尚未归入任何克隆、且在别的文件里也出现过的指纹，
        // 就以它为锚点，挑延长得最长的配对把整段克隆吃掉 —— 相邻/重叠窗口由此合并成一个长块，
        // 每个克隆只展开一次，整体代价与窗口数线性。
        var blocks: [DuplicatedBlock] = []
        blocks.reserveCapacity(maxBlocks)

        for fileIndex in 0..<files.count {
            let hashes = scan.hashesByFile[fileIndex]
            var windowStart = 0
            while windowStart < hashes.count {
                defer { windowStart += 1 }
                if scan.isConsumed(fileIndex: fileIndex, windowStart: windowStart) { continue }
                guard let group = scan.registered[hashes[windowStart]] else { continue }

                var best: Occurrence?
                var bestExtent = -1
                for candidate in group where candidate.fileIndex != fileIndex {
                    let extra = scan.growClone(from: windowStart, in: fileIndex,
                                               to: candidate.windowStart, in: candidate.fileIndex)
                    if extra > bestExtent {
                        bestExtent = extra
                        best = candidate
                    }
                }
                guard let partner = best, bestExtent >= 0 else { continue }

                let anchor = CloneFragment(fileIndex: fileIndex, windowStart: windowStart)
                let partnerFragment = CloneFragment(fileIndex: partner.fileIndex, windowStart: partner.windowStart)
                let members = scan.extraMembers(of: hashes[windowStart], anchor: anchor, extent: bestExtent)
                if let block = scan.commitClone(anchor: anchor, partner: partnerFragment, members: members,
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

// MARK: - Tuning thresholds

/// 归一化后最短行长见 `DuplicationEngine.minSignificantRunes`
/// 单词元行（`} catch {` 这类）至少要 8 字节才值得进窗口
fileprivate let minSignificantBytes = 8
/// 纯标点行（0 词元）必丢；1~2 词元的短行由上面 `minSignificantBytes` 那条规则处理，
/// 这样 `import Foundation`（`I I`）之类的两词一行不会被整片当成噪声误伤。
fileprivate let minTokenCount = 1
/// 单个指纹最多记录多少个片段（跨文件 + 同文件内部重复共用同一预算），超出即丢弃，内存换精度。
/// 与 `maxFragmentsPerBlock` 取同值：记下的片段都会出现在明细里，榜单与统计不打架。
fileprivate let maxOccurrencesPerHash = 6
/// 同一份指纹在单个文件里最多记几个片段（再多就是同一次拷贝的重复展开）
fileprivate let maxRunsPerFileAndHash = 2
/// 一个块至少要有一到二成行逐字一致才算「拷贝粘贴」（6 行的最小块 = ≥2 行原文相同）。
/// 低于此值说明两边只是 token 形状相同，视图上会显示成「相似度 0% 的 35 行重复」这种没意义的答案。
fileprivate let minCloneSimilarity = 0.2
fileprivate let maxFragmentsPerBlock = 6
fileprivate let runsCapacityCap = 300_000

// MARK: - Byte helpers

private let spaceByte: UInt8 = 0x20
private let tabByte: UInt8 = 0x09
private let newlineByte: UInt8 = 0x0A
private let carriageByte: UInt8 = 0x0D
private let verticalByte: UInt8 = 0x0B
private let formByte: UInt8 = 0x0C
private let dotByte: UInt8 = 0x2E
private let zeroByte: UInt8 = 0x30
private let nineByte: UInt8 = 0x39
private let underscoreByte: UInt8 = 0x5F
private let backslashByte: UInt8 = 0x5C
private let letterNByte: UInt8 = 0x4E
private let letterSByte: UInt8 = 0x53
/// 标识符（变量名 / 函数名 / 类型名）整体折成一个 `I` 占位符，于是 type-2 克隆
/// （复制后改名的代码）也能命中同一指纹；字面量另有 `N` / `S` 占位。
private let letterIByte: UInt8 = 0x49
private let exponentLowerByte: UInt8 = 0x65
private let exponentUpperByte: UInt8 = 0x45
private let plusByte: UInt8 = 0x2B
private let minusByte: UInt8 = 0x2D
private let lowerFByte: UInt8 = 0x66
private let upperFByte: UInt8 = 0x46

private let fnvOffsetBase: UInt64 = 0xcbf2_9ce4_8422_2325
private let fnvPrime: UInt64 = 0x100_0000_01b3

private func isSpaceByte(_ b: UInt8) -> Bool {
    b == spaceByte || b == tabByte || b == newlineByte || b == carriageByte || b == verticalByte || b == formByte
}

private func isDigitByte(_ b: UInt8) -> Bool { b >= zeroByte && b <= nineByte }

private func isLetterByte(_ b: UInt8) -> Bool {
    (b >= 0x61 && b <= 0x7A) || (b >= 0x41 && b <= 0x5A)
}

private func isHexLetterByte(_ b: UInt8) -> Bool {
    (b >= 0x61 && b <= lowerFByte) || (b >= 0x41 && b <= upperFByte)
}

private func isHexDigitByte(_ b: UInt8) -> Bool { isDigitByte(b) || isHexLetterByte(b) }

/// 非 ASCII 字节一律视作标识符字符（中文标识符/全角符号不该被拆成数字边界）。
private func isIdentByte(_ b: UInt8) -> Bool {
    b >= 0x80 || isLetterByte(b) || isDigitByte(b) || b == underscoreByte || b == 0x24 || b == 0x40
}

private func isRadixMarker(_ b: UInt8) -> Bool {
    b == 0x78 || b == 0x58 || b == 0x62 || b == 0x42 || b == 0x6F || b == 0x4F
}

private func hasPrefix(_ seq: [UInt8], at index: Int, in src: [UInt8]) -> Bool {
    guard index + seq.count <= src.count else { return false }
    var offset = 0
    while offset < seq.count {
        if src[index + offset] != seq[offset] { return false }
        offset += 1
    }
    return true
}

private func closingQuoteResume(_ quote: UInt8, in src: [UInt8], from: Int) -> Int? {
    var i = from
    while i < src.count {
        let b = src[i]
        if b == backslashByte { i += 2; continue }
        if b == quote { return i + 1 }
        i += 1
    }
    return nil
}

private func closingSequenceResume(_ seq: [UInt8], in src: [UInt8], from: Int) -> Int? {
    var i = from
    while i + seq.count <= src.count {
        if src[i] == seq[0], hasPrefix(seq, at: i, in: src) { return i + seq.count }
        i += 1
    }
    return nil
}

private func radixNumberResume(_ src: [UInt8], from start: Int) -> Int {
    let count = src.count
    var i = start + 2
    while i < count, isHexDigitByte(src[i]) || src[i] == underscoreByte { i += 1 }
    return i
}

private func numberResume(_ src: [UInt8], from start: Int) -> Int {
    let count = src.count
    var i = start
    if src[i] == zeroByte, i + 1 < count, isRadixMarker(src[i + 1]) { return radixNumberResume(src, from: i) }
    while i < count, isDigitByte(src[i]) || src[i] == underscoreByte { i += 1 }
    if i + 1 < count, src[i] == dotByte, isDigitByte(src[i + 1]) {
        i += 1
        while i < count, isDigitByte(src[i]) || src[i] == underscoreByte { i += 1 }
    }
    if i + 1 < count, src[i] == exponentLowerByte || src[i] == exponentUpperByte {
        var probe = i + 1
        if probe < count, src[probe] == plusByte || src[probe] == minusByte { probe += 1 }
        if probe < count, isDigitByte(src[probe]) {
            i = probe
            while i < count, isDigitByte(src[i]) || src[i] == underscoreByte { i += 1 }
        }
    }
    return i
}

// MARK: - Per-language syntax

fileprivate struct LineSyntax {
    var stringDelimiters: [[UInt8]] = []
    var lineCommentPrefixes: [[UInt8]] = []
    var blockStart: [UInt8]?
    var blockEnd: [UInt8]?
}

private let singleQuoteDelimiters: [[UInt8]] = [[0x22], [0x27], [0x60]]

fileprivate func buildLineSyntax(language: String) -> LineSyntax {
    var delimiters: [[UInt8]] = []
    for raw in SourceLanguageCatalog.docStringDelimiters(for: language) {
        let bytes = Array(raw.utf8)
        if bytes.count >= 2 { delimiters.append(bytes) }
    }
    for bytes in singleQuoteDelimiters where !delimiters.contains(bytes) { delimiters.append(bytes) }
    delimiters.sort { $0.count > $1.count }

    var prefixes: [[UInt8]] = []
    var seenPrefixes = Set<String>()
    for raw in SourceLanguageCatalog.lineCommentPrefixes(for: language)
    where !raw.isEmpty && seenPrefixes.insert(raw).inserted {
        prefixes.append(Array(raw.utf8))
    }
    prefixes.sort { $0.count > $1.count }

    var start: [UInt8]?
    var end: [UInt8]?
    if let block = SourceLanguageCatalog.blockCommentDelimiters(for: language) {
        let s = Array(block.start.utf8)
        let e = Array(block.end.utf8)
        if s.count >= 2, e.count >= 2 { start = s; end = e }
    }
    return LineSyntax(stringDelimiters: delimiters,
                      lineCommentPrefixes: prefixes,
                      blockStart: start,
                      blockEnd: end)
}

// MARK: - Line normalization

/// 行归一化：折叠空白、丢弃注释、数字/字符串/标识符换成占位符，输出可直接进指纹的字节序列。
/// 返回 nil 表示这一行不进滑窗（空行、注释行、纯标点、单词元短样板行）。
fileprivate func normalizeBytes(_ text: String, syntax: LineSyntax) -> [UInt8]? {
    let src = Array(text.utf8)
    let count = src.count
    var out = [UInt8]()
    out.reserveCapacity(count + 2)
    var pendingSpace = false
    var tokenRuns = 0
    var inIdentRun = false
    var i = 0

    while i < count {
        let b = src[i]

        if isSpaceByte(b) {
            pendingSpace = !out.isEmpty
            // 空白同样终结标识符词元：`for row in rows` 是 4 个词元，不是 1 个
            inIdentRun = false
            i += 1
            continue
        }

        let lastByte: UInt8 = out.isEmpty ? spaceByte : out[out.count - 1]

        // 行注释从它在行内出现的位置起整段截断（含第 0 列，注释行因此归一化为 nil）。
        // 之所以不用担心 `#include`：C 系语言的行注释前缀是 `//`，目录里没有任何语言把 `#` 之外的
        // 预处理符号列为前缀；只有 PHP 的 `#[属性]` 会被当注释丢掉，属于已知精度损失。
        if !isIdentByte(lastByte),
           syntax.lineCommentPrefixes.contains(where: { hasPrefix($0, at: i, in: src) }) {
            break
        }

        if let blockStart = syntax.blockStart, let blockEnd = syntax.blockEnd,
           hasPrefix(blockStart, at: i, in: src) {
            if let resume = closingSequenceResume(blockEnd, in: src, from: i + blockStart.count) {
                pendingSpace = !out.isEmpty
                i = resume
                continue
            }
            break
        }

        if let slot = syntax.stringDelimiters.firstIndex(where: { hasPrefix($0, at: i, in: src) }) {
            let delimiter = syntax.stringDelimiters[slot]
            // 单字符引号要跳过 `\` 转义；多行串定界符按整段定界符配对（未闭合则吃到行尾）。
            let resume: Int?
            if delimiter.count == 1 {
                resume = closingQuoteResume(delimiter[0], in: src, from: i + 1)
            } else {
                resume = closingSequenceResume(delimiter, in: src, from: i + delimiter.count)
            }
            i = resume ?? count
            if pendingSpace { out.append(spaceByte) }
            pendingSpace = false
            out.append(letterSByte)
            if !inIdentRun { tokenRuns += 1; inIdentRun = true }
            continue
        }

        let startsNumber = !isIdentByte(lastByte)
            && (isDigitByte(b) || (b == dotByte && i + 1 < count && isDigitByte(src[i + 1])))
        if startsNumber {
            if pendingSpace { out.append(spaceByte) }
            pendingSpace = false
            out.append(letterNByte)
            if !inIdentRun { tokenRuns += 1; inIdentRun = true }
            i = numberResume(src, from: i)
            continue
        }

        if pendingSpace { out.append(spaceByte) }
        pendingSpace = false
        if isIdentByte(b) {
            // 标识符词元只落一个 `I`，后面的字母直接吃掉：`revenueByCategory` -> `I`。
            // 长度不再随标识符命名波动，改名后的拷贝才能落到同一个指纹上。
            if !inIdentRun {
                out.append(letterIByte)
                tokenRuns += 1
                inIdentRun = true
            }
        } else {
            out.append(b)
            inIdentRun = false
        }
        i += 1
    }

    // 阈值（全部只看归一化后的产物，因此与标识符长短无关）：
    // 1. 长度 < `minSignificantRunes`(4) 的行一律丢弃：`}`、`);`、`})`、`return keep`(`I I`)；
    // 2. 纯标点（0 词元）丢弃：`}) {`、`];`；
    // 3. 只有 1 个词元且长度 < `minSignificantBytes`(8) 的行丢弃：`} catch {`、`} else {`、`foo();`。
    //    这类样板行若进窗口，任何两个文件都会撞出海量伪重复。
    if out.count < DuplicationEngine.minSignificantRunes { return nil }
    if tokenRuns < minTokenCount { return nil }
    if tokenRuns < 2 && out.count < minSignificantBytes { return nil }
    return out
}

// MARK: - Window fingerprint

private func windowFingerprint(chunks: [UInt8], starts: [Int], lengths: [Int], from: Int, size: Int) -> UInt64 {
    var hash = fnvOffsetBase
    var index = from
    let end = from + size
    while index < end {
        if index > from { hash = (hash ^ UInt64(newlineByte)) &* fnvPrime }
        let stop = starts[index] + lengths[index]
        var cursor = starts[index]
        while cursor < stop {
            hash = (hash ^ UInt64(chunks[cursor])) &* fnvPrime
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
        registered.reserveCapacity(min(windowBudget, runsCapacityCap))
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
        var sameFile = 0
        for item in group where item.fileIndex == fileIndex { sameFile += 1 }
        // 每个指纹最多留 `maxOccurrencesPerHash` 处、单个文件最多留 `maxRunsPerFileAndHash` 处，
        // 再多的拷贝仍然会被 ratio 覆盖到（它们与已存锚点同一段克隆），只是不再展开。
        guard group.count < maxOccurrencesPerHash, sameFile < maxRunsPerFileAndHash else { return }
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

    /// 同一锚点指纹在其它文件里的出现位置，只要整段窗口序列都对得上，就并进同一个块。
    func extraMembers(of hash: UInt64, anchor: CloneFragment, extent: Int) -> [CloneFragment] {
        guard let group = registered[hash] else { return [] }
        guard anchor.fileIndex >= 0, anchor.fileIndex < hashesByFile.count else { return [] }
        let anchorHashes = hashesByFile[anchor.fileIndex]
        guard anchor.windowStart >= 0, anchor.windowStart + extent < anchorHashes.count else { return [] }
        var result: [CloneFragment] = []
        result.reserveCapacity(maxFragmentsPerBlock)
        for item in group {
            guard item.fileIndex != anchor.fileIndex else { continue }
            guard result.count < maxFragmentsPerBlock else { break }
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
        var seenFiles = [anchor.fileIndex]
        for candidate in [partner] + members {
            guard candidate.fileIndex >= 0, candidate.fileIndex < files.count else { continue }
            guard seenFiles.contains(candidate.fileIndex) == false else { continue }
            guard candidate.windowStart >= 0,
                  candidate.windowStart < numbersByFile[candidate.fileIndex].count else { continue }
            seenFiles.append(candidate.fileIndex)
            picked.append(candidate)
        }
        // 块必须跨文件命中（验收口径 + 冻结单测断言）：只在一个文件里自我重复的片段不成块，
        // 也不计入 ratio，否则「一个文件抄了自己三遍」会被当成拷贝粘贴上报。
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
            guard ratio >= minCloneSimilarity else { continue }
            similarity = min(similarity, ratio)
            kept.append(fragment)
            occurrences.append(fragmentOf(fragment, files: files))
        }
        guard kept.count >= 2, occurrences.count >= 2 else {
            // 整块作废也要把锚点这一侧的窗口吃掉，否则同一个形状会被逐窗口重试一遍（O(N²)）
            markConsumed(anchor, extent: extent)
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
