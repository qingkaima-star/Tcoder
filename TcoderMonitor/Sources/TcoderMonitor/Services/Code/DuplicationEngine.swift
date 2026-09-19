import Foundation

struct DuplicationResult: Sendable {
    var ratio: Double
    var duplicatedCodeLines: Int
    var totalCodeLines: Int
    var blocks: [DuplicatedBlock]
}

enum DuplicationEngine {

    static let windowSize: Int = 6

    /// 归一化后长度低于此值的行一律丢弃。**单位是 UTF-8 字节**（`normalizeBytes` 走字节管线，
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
        guard let bytes = normalizeBytes(text, syntax: buildLineSyntax(language: language)) else { return nil }
        let result = String(decoding: bytes, as: UTF8.self)
        // 对外的「这一行算不算有效代码行」判据，比指纹通道更严一档：
        // 指纹通道只要行长/词元数达标（`normalizeBytes` 末尾四条），这里再要求 ≥3 个
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
                // 整块会被 `minCloneSimilarity` 否掉并顺手消费掉窗口，反而把可达的真拷贝陪葬；
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
                                                    lineCount: extra + windowSize) >= minCloneSimilarity
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

// MARK: - Tuning thresholds

/// 指纹通道的最短归一化行长见 `DuplicationEngine.minNormalizedBytes`（当前 4 字节）：
/// 单词元行（`} catch {`、`foo();` 这类）至少要 8 字节才值得进窗口 —— 这类样板行若进窗口，
/// 任何两个文件都会撞出海量伪重复。实测敏感度（Homebrew，基线 22297 行）：
/// 抬到 14 字节只少 20 行（0.1%，说明真拷贝不靠这条），但 4 字节这条本身极脆：
/// 门槛取 6 / 8 字节时重复行直接掉到 12003 / 7015（-46% / -69%），故 4 不能再动。
fileprivate let minBytesForSingleTokenLine = 8
/// 纯标点行（0 词元：`}) {`、`];`）必丢。实测把这条抬到「至少 2 词元」只影响 20 行（0.1%），
/// 因为 1 词元的短行已经被上面的 `minBytesForSingleTokenLine` 挡住了 —— 这条留着是为了兜住
/// `}` 连排那种超长单词元行（例如 10 个空花括号 `}}}}}}}}}}`）。
fileprivate let minTokenCount = 1
/// 单个指纹最多记录多少个片段（跨文件 + 同文件内部重复共用同一预算），超出即丢弃，内存换精度。
/// 这是**配对索引**的预算，不是榜单预算（榜单上限是下面 `maxFragmentsPerBlock`）：
/// 一个片段被记下来，只保证「它能当锚点的配对候选」，能不能进某个块另说。
/// 取 24 / 每文件 8 的实测依据（Homebrew，20.38 万代码行，含同文件粘贴的口径）：
/// ratio 6/2=9.94%、12/4=10.71%、24/8=10.94%、64/16=11.14%、512/128=12.97%（近似放开预算），
/// 即上一轮的 6/2 低估 23%（相对）、现预算仍低估 15.7%，但再往上是明显的收益递减；
/// 而 24/8 与 12/4 的耗时/峰值内存实测持平（Homebrew 重复检测 ~130ms、62MB；
/// 9.1 万行全等文件的极端树 115ms、29MB），512/128 在重复密度高的树上要慢 45~50%
/// （锚点候选循环与每组预算成正比），故停在 24/8。
fileprivate let maxOccurrencesPerHash = 24
/// 同一份指纹在单个文件里最多记几个片段：内部粘贴 2 处以上时要留够互配余地
/// （同文件配对要求两段不重叠，见 `analyze` 的锚点循环），否则第三次以后的拷贝会被挤掉。
fileprivate let maxRunsPerFileAndHash = 8
/// 一个块至少要有一到二成行逐字一致才算「拷贝粘贴」（6 行的最小块 = ≥2 行原文相同）。
/// 低于此值说明两边只是 token 形状相同，视图上会显示成「相似度 0% 的 35 行重复」这种没意义的答案。
/// Homebrew 实测（含同文件粘贴的口径，20.38 万代码行）：取 0 时 32812 行重复、取 0.2 时 22297、
/// 取 0.4 时 18221 —— 不设门槛会多算 47% 的「只是 token 形状相同」的行，
/// 0.2 砍掉这批量又基本不伤逐字改名的拷贝（0.4 才开始掉），故维持 0.2。
fileprivate let minCloneSimilarity = 0.2
/// 一个块最多列几处出现（明细上限，冻结单测要求 ≤6，UI 也只画前 4 处 + 「另有 N 处」）。
/// 与 `maxOccurrencesPerHash` 解耦：后者是配对索引预算（更大），这里只决定一个块展示/覆盖几处。
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
    /// 没有任何行注释前缀的语言（Markdown / HTML / XML / Vue / CSS / JSON）都是
    /// 「正文型」文件：这种语言里一行纯散文（只有词元、没有代码结构符）不该被当成代码参与指纹。
    var needsStructureByte = false
}

/// 「代码结构符」：出现其一才算结构/语句行，而不是自然语言句子。
/// 刻意不含 `,` `.` `'` `-` —— 散文里满地都是。
private let structureBytes: Set<UInt8> = [
    0x3D,                                     // =
    0x28, 0x29,                               // ( )
    0x7B, 0x7D,                               // { }
    0x5B, 0x5D,                               // [ ]
    0x3C, 0x3E,                               // < >
    0x3A, 0x3B,                               // : ;
    0x7C, 0x26, 0x2F,                         // | & /
]

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
                      blockEnd: end,
                      needsStructureByte: prefixes.isEmpty)
}

// MARK: - Line normalization

/// 行归一化：折叠空白、丢弃注释、数字/字符串/标识符换成占位符，输出可直接进指纹的字节序列。
/// 返回 nil 表示这一行不进滑窗（空行、注释行、纯标点、单词元短样板行、正文型语言里的散文行）。
/// 这里是**指纹通道**的判据；对外的 `normalize(_:language:)` 在此之上还更严一档，见该方法注释。
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

        // 「是不是又一个词元的开头」只能看**源码里的前一个字节**：归一化输出会折叠空白，
        // 于是 `x = 1 // note` 里 `//` 的前一个输出字节是 `N`（标识符字符），按输出口径判定
        // 就会漏掉行内注释、把注释文字折成 `// I` 留在指纹里（两份逐字相同的代码只要注释
        // 不同就撞不上，是 type-1 漏报）。第 0 列视作空白，因此整行注释照样归 nil。
        let prevByte: UInt8 = i == 0 ? spaceByte : src[i - 1]

        // 行注释从它在行内出现的位置起整段截断（含第 0 列，注释行因此归一化为 nil）。
        // 之所以不用担心 `#include`：C 系语言的行注释前缀是 `//`，目录里没有任何语言把 `#` 之外的
        // 预处理符号列为前缀。已知精度损失：PHP 的 `#[属性]` 会被当注释丢掉 —— 而且它在更上游的
        // `SourceFileClassifier` 里就已经判成注释行（既不进分母、也进不到这里），要修得动语言目录表。
        if !isIdentByte(prevByte),
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

        // 数字的开头同样按源码上下文判定：`foo bar 123` 里的 `123` 前一个是空白，
        // 就该折成 `N` 而不是被当成标识符续字符折成 `I`（否则「数字」与「标识符」在指纹里
        // 撞成同一个词元，会造出「形状恰好相同」的伪克隆）。
        let startsNumber = !isIdentByte(prevByte)
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
    // 1. 长度 < `minNormalizedBytes`(4) 的行一律丢弃：`}`、`);`、`})`、`return keep`(`I I`)；
    // 2. 纯标点（0 词元）丢弃：`}) {`、`];`；
    // 3. 只有 1 个词元且长度 < `minBytesForSingleTokenLine`(8) 的行丢弃：`} catch {`、`} else {`、`foo();`。
    // 4. 正文型语言（没有行注释前缀：Markdown / HTML / XML / Vue / CSS / JSON）里，一行必须
    //    带个代码结构符才算数，否则 README 里抄来的一段散文会被当成「重复代码」上报
    //    （实测：两份 README 共用一段正文，改前 ratio 81.8%、9 行「重复块」；改后 0%）。
    // 对外的 `normalize` 在此之上还叠一条「≥3 个含字母数字的词元」，两档差别的说明见那里。
    if out.count < DuplicationEngine.minNormalizedBytes { return nil }
    if tokenRuns < minTokenCount { return nil }
    if tokenRuns < 2 && out.count < minBytesForSingleTokenLine { return nil }
    if syntax.needsStructureByte, !out.contains(where: { structureBytes.contains($0) }) { return nil }
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
        // 同一文件的片段在组里一定是连续的一段、并且总在尾部（登记按「逐文件、文件内逐窗口」
        // 的顺序进行），所以从尾部往回数就能拿到本文件已记的条数：代价只跟这个数有关，
        // 跟每组预算 `maxOccurrencesPerHash` 无关 —— 预算调大时这里不会跟着变慢。
        var sameFile = 0
        var cursor = group.count
        while cursor > 0 {
            cursor -= 1
            guard group[cursor].fileIndex == fileIndex else { break }
            sameFile += 1
        }
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

    /// 同一锚点指纹在**别处**的出现位置（别的文件，或同一文件里不重叠的另一段），
    /// 只要整段窗口序列都对得上，就并进同一个块。
    func extraMembers(of hash: UInt64, anchor: CloneFragment, extent: Int) -> [CloneFragment] {
        guard let group = registered[hash] else { return [] }
        guard anchor.fileIndex >= 0, anchor.fileIndex < hashesByFile.count else { return [] }
        let anchorHashes = hashesByFile[anchor.fileIndex]
        guard anchor.windowStart >= 0, anchor.windowStart + extent < anchorHashes.count else { return [] }
        var result: [CloneFragment] = []
        result.reserveCapacity(maxFragmentsPerBlock)
        for item in group {
            // 与锚点循环同样的「同文件必须不重叠」约束，否则会把相邻窗口当成第二份拷贝。
            if item.fileIndex == anchor.fileIndex,
               item.windowStart < anchor.windowStart + DuplicationEngine.windowSize { continue }
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
        var seenFragments = Set<String>(["\(anchor.fileIndex):\(anchor.windowStart)"])
        for candidate in [partner] + members {
            guard candidate.fileIndex >= 0, candidate.fileIndex < files.count else { continue }
            guard candidate.windowStart >= 0,
                  candidate.windowStart < numbersByFile[candidate.fileIndex].count else { continue }
            // 同一文件里的不同片段是合法的第二次拷贝，只按「文件 + 起点窗口」去重。
            guard seenFragments.insert("\(candidate.fileIndex):\(candidate.windowStart)").inserted else { continue }
            picked.append(candidate)
        }
        // 明细硬上限：一个块最多列 `maxFragmentsPerBlock` 处（冻结单测钉着「occurrences ≤ 6」）。
        // 配对的指纹预算（`maxOccurrencesPerHash`）比它大，所以这里必须再截一次；
        // 被截掉的那几处不会漏进 ratio —— 锚点循环走到它自己的窗口时会另立一块。
        if picked.count > maxFragmentsPerBlock { picked.removeSubrange(maxFragmentsPerBlock...) }
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
