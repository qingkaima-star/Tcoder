import Foundation

struct DuplicationResult: Sendable {
    var ratio: Double
    var duplicatedCodeLines: Int
    var totalCodeLines: Int
    var blocks: [DuplicatedBlock]
}

enum DuplicationEngine {

    static let windowSize: Int = 6

    /// 单文件参与滑窗的归一化行数上限：超长文件（生成的/打包的）会吃掉整轮预算，硬截断。
    private static let maxWindowedLines = 20_000
    private static let maxBlocks = 20

    // MARK: - Normalization

    /// 归一化一行；返回 nil 表示该行丢弃（不进窗口）
    static func normalize(_ text: String, language: String) -> String? {
        guard let bytes = normalizeBytes(text, syntax: buildLineSyntax(language: language)) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Analysis

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

            scan.beginFile(numbers: numbers)
            let lineCount = numbers.count
            guard lineCount >= windowSize else { continue }

            var windowStart = 0
            while windowStart + windowSize <= lineCount {
                let hash = windowFingerprint(chunks: chunks, starts: starts, lengths: lengths,
                                             from: windowStart, size: windowSize)
                scan.consume(hash: hash, fileIndex: fileIndex, windowStart: windowStart)
                windowStart += 1
            }
        }

        var blocks: [DuplicatedBlock] = []
        blocks.reserveCapacity(maxBlocks)
        var fragmentCache = [Int: CachedFragments]()
        fragmentCache.reserveCapacity(min(scan.duplicatedRuns.count, 4096))

        for (hash, extras) in scan.duplicatedRuns {
            guard let first = scan.firstSeen[hash] else { continue }
            if first.fileIndex < scan.covered.count {
                markCoverage(first, flags: &scan.covered[first.fileIndex])
            }
            for run in extras where run.fileIndex < scan.covered.count {
                markCoverage(run, flags: &scan.covered[run.fileIndex])
            }

            var runs: [Occurrence] = [first]
            runs.append(contentsOf: extras)
            runs.sort { $0.fileIndex < $1.fileIndex }

            var lineCount = 0
            var dominantIndex = 0
            for (offset, run) in runs.enumerated() where run.codeLineCount > lineCount {
                lineCount = run.codeLineCount
                dominantIndex = offset
            }
            guard lineCount >= windowSize else { continue }

            let dominant = runs[dominantIndex]
            let occurrences: [DuplicatedFragment]
            if let cached = fragmentCache[dominant.fileIndex], cached.lineCount == lineCount {
                occurrences = cached.fragments
            } else {
                occurrences = fragmentsOfRuns(runs, files: files)
                fragmentCache[dominant.fileIndex] = CachedFragments(lineCount: lineCount, fragments: occurrences)
            }
            // 每个 occurrence 来自不同文件，故 count >= 2 恒成立；空数组只可能是路径越界。
            guard occurrences.count >= 2 else { continue }

            blocks.append(DuplicatedBlock(occurrences: occurrences, lineCount: lineCount, similarity: 1))
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

fileprivate let minNormalizedLength = 4
fileprivate let minSignificantBytes = 8
fileprivate let minTokenCount = 2
fileprivate let maxFilesPerHash = 6
fileprivate let maxFragmentsPerBlock = 6
fileprivate let firstSeenCapacityCap = 300_000

fileprivate struct CachedFragments {
    var lineCount: Int
    var fragments: [DuplicatedFragment]
}

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

fileprivate func normalizeBytes(_ text: String, syntax: LineSyntax) -> [UInt8]? {
    let src = Array(text.utf8)
    let count = src.count
    var out = [UInt8]()
    out.reserveCapacity(count + 2)
    var pendingSpace = false
    var tokenRuns = 0
    var significant = 0
    var inIdentRun = false
    var i = 0

    while i < count {
        let b = src[i]

        if isSpaceByte(b) {
            pendingSpace = !out.isEmpty
            i += 1
            continue
        }

        let lastByte: UInt8 = out.isEmpty ? spaceByte : out[out.count - 1]

        // 行注释只在行中出现时截断：第 0 列的注释已由分类器标成 comment，
        // 这里若也截断会误伤 `#include`（C 系前缀就是 `#`）。
        if i > 0, !isIdentByte(lastByte),
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
            significant += 1
            if !inIdentRun { tokenRuns += 1; inIdentRun = true }
            continue
        }

        let startsNumber = !isIdentByte(lastByte)
            && (isDigitByte(b) || (b == dotByte && i + 1 < count && isDigitByte(src[i + 1])))
        if startsNumber {
            if pendingSpace { out.append(spaceByte) }
            pendingSpace = false
            out.append(letterNByte)
            significant += 1
            if !inIdentRun { tokenRuns += 1; inIdentRun = true }
            i = numberResume(src, from: i)
            continue
        }

        if pendingSpace { out.append(spaceByte) }
        pendingSpace = false
        if isIdentByte(b) {
            significant += 1
            if !inIdentRun { tokenRuns += 1; inIdentRun = true }
        } else {
            inIdentRun = false
        }
        out.append(b)
        i += 1
    }

    // 阈值：归一化后长度 < 4、纯标点（0 词元），或「只有 1 个词元且有效字符 < 8」的行一律丢弃。
    // `}`、`);`、`})`、`else {`、`} catch {` 这类样板行若进窗口，任何两个文件都会撞出海量伪重复。
    if out.count < DuplicationEngine.minSignificantRunes { return nil }
    if tokenRuns < minTokenCount { return nil }
    if tokenRuns < 3 && significant < minSignificantBytes { return nil }
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

// MARK: - Occurrence accumulation

fileprivate struct Occurrence {
    var fileIndex: Int
    var firstWindowStart: Int
    var lastWindowStart: Int
    var startLine: Int
    var endLine: Int

    init(fileIndex: Int, windowStart: Int, startLine: Int, endLine: Int) {
        self.fileIndex = fileIndex
        firstWindowStart = windowStart
        lastWindowStart = windowStart
        self.startLine = startLine
        self.endLine = endLine
    }

    var codeLineCount: Int { lastWindowStart + DuplicationEngine.windowSize - firstWindowStart }
}

fileprivate struct ScanState {
    var firstSeen: [UInt64: Occurrence]
    var duplicatedRuns: [UInt64: [Occurrence]]
    var numbersByFile: [[Int]]
    var covered: [[Bool]]

    init(fileCount: Int, windowBudget: Int) {
        firstSeen = [UInt64: Occurrence]()
        firstSeen.reserveCapacity(min(windowBudget, firstSeenCapacityCap))
        duplicatedRuns = [UInt64: [Occurrence]]()
        numbersByFile = [[Int]]()
        numbersByFile.reserveCapacity(fileCount)
        covered = [[Bool]]()
        covered.reserveCapacity(fileCount)
    }

    mutating func beginFile(numbers: [Int]) {
        numbersByFile.append(numbers)
        covered.append([Bool](repeating: false, count: numbers.count))
    }

    mutating func consume(hash: UInt64, fileIndex: Int, windowStart: Int) {
        let size = DuplicationEngine.windowSize
        let numbers = numbersByFile[fileIndex]

        if var stored = firstSeen[hash] {
            if stored.fileIndex == fileIndex {
                // 同文件相邻窗口：链式延长已存位置，不额外占内存；同文件自我重复不计入 ratio（产品口径）。
                if windowStart == stored.lastWindowStart + 1 {
                    stored.lastWindowStart = windowStart
                    stored.endLine = numbers[windowStart + size - 1]
                    firstSeen[hash] = stored
                }
                return
            }
            if duplicatedRuns[hash] == nil { duplicatedRuns[hash] = [] }
            appendRun(hash: hash, fileIndex: fileIndex, windowStart: windowStart)
            return
        }

        firstSeen[hash] = Occurrence(fileIndex: fileIndex,
                                     windowStart: windowStart,
                                     startLine: numbers[windowStart],
                                     endLine: numbers[windowStart + size - 1])
    }

    private mutating func appendRun(hash: UInt64, fileIndex: Int, windowStart: Int) {
        let size = DuplicationEngine.windowSize
        guard var runs = duplicatedRuns[hash] else { return }
        let numbers = numbersByFile[fileIndex]

        for index in runs.indices where runs[index].fileIndex == fileIndex {
            // 同文件里非相邻的第二个重复块不再记录，内存换精度。
            guard windowStart == runs[index].lastWindowStart + 1 else { return }
            runs[index].lastWindowStart = windowStart
            runs[index].endLine = numbers[windowStart + size - 1]
            duplicatedRuns[hash] = runs
            return
        }

        guard runs.count < maxFilesPerHash else { return }
        runs.append(Occurrence(fileIndex: fileIndex,
                               windowStart: windowStart,
                               startLine: numbers[windowStart],
                               endLine: numbers[windowStart + size - 1]))
        duplicatedRuns[hash] = runs
    }
}

private func markCoverage(_ run: Occurrence, flags: inout [Bool]) {
    let size = DuplicationEngine.windowSize
    var index = run.firstWindowStart
    let stop = min(run.lastWindowStart + size, flags.count)
    while index < stop {
        flags[index] = true
        index += 1
    }
}

private func fragmentsOfRuns(_ runs: [Occurrence], files: [ScannedSourceFile]) -> [DuplicatedFragment] {
    var fragments: [DuplicatedFragment] = []
    fragments.reserveCapacity(maxFragmentsPerBlock)
    for run in runs {
        guard fragments.count < maxFragmentsPerBlock else { break }
        guard run.fileIndex >= 0, run.fileIndex < files.count else { continue }
        let fragment = DuplicatedFragment(path: files[run.fileIndex].url.path, startLine: run.startLine)
        if !fragments.contains(fragment) { fragments.append(fragment) }
    }
    return fragments
}
