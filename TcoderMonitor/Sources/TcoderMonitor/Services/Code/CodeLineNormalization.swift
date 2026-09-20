import Foundation

// OWNER: Workstream A (静态代码分析) —— 重复代码检测的「行归一化」层。
//
// 从 DuplicationEngine.swift 拆出，只为守住本工作流的红线（800 行以上的文件不得增加）：
// 归一化规则、阈值、字节判定一字未改。原先这些是文件内 fileprivate/private 顶层符号，
// 直接放宽成 internal 会往模块里丢一批通用名（hasPrefix、isDigitByte、ScanState…），
// 六条工作流并发写同一个 target 时迟早撞名，所以统一收进 DupLex 命名空间。
enum DupLex {
    // MARK: - Tuning thresholds

    /// 指纹通道的最短归一化行长见 `DuplicationEngine.minNormalizedBytes`（当前 4 字节）：
    /// 单词元行（`} catch {`、`foo();` 这类）至少要 8 字节才值得进窗口 —— 这类样板行若进窗口，
    /// 任何两个文件都会撞出海量伪重复。实测敏感度（Homebrew，基线 22297 行）：
    /// 抬到 14 字节只少 20 行（0.1%，说明真拷贝不靠这条），但 4 字节这条本身极脆：
    /// 门槛取 6 / 8 字节时重复行直接掉到 12003 / 7015（-46% / -69%），故 4 不能再动。
    static let minBytesForSingleTokenLine = 8
    /// 纯标点行（0 词元：`}) {`、`];`）必丢。实测把这条抬到「至少 2 词元」只影响 20 行（0.1%），
    /// 因为 1 词元的短行已经被上面的 `minBytesForSingleTokenLine` 挡住了 —— 这条留着是为了兜住
    /// `}` 连排那种超长单词元行（例如 10 个空花括号 `}}}}}}}}}}`）。
    static let minTokenCount = 1
    /// 单个指纹最多记录多少个片段（跨文件 + 同文件内部重复共用同一预算），超出即丢弃，内存换精度。
    /// 这是**配对索引**的预算，不是榜单预算（榜单上限是下面 `maxFragmentsPerBlock`）：
    /// 一个片段被记下来，只保证「它能当锚点的配对候选」，能不能进某个块另说。
    /// 取 24 / 每文件 8 的实测依据（Homebrew，20.38 万代码行，含同文件粘贴的口径）：
    /// ratio 6/2=9.94%、12/4=10.71%、24/8=10.94%、64/16=11.14%、512/128=12.97%（近似放开预算），
    /// 即上一轮的 6/2 低估 23%（相对）、现预算仍低估 15.7%，但再往上是明显的收益递减；
    /// 而 24/8 与 12/4 的耗时/峰值内存实测持平（Homebrew 重复检测 ~130ms、62MB；
    /// 9.1 万行全等文件的极端树 115ms、29MB），512/128 在重复密度高的树上要慢 45~50%
    /// （锚点候选循环与每组预算成正比），故停在 24/8。
    static let maxOccurrencesPerHash = 24
    /// 同一份指纹在单个文件里最多记几个片段：内部粘贴 2 处以上时要留够互配余地
    /// （同文件配对要求两段不重叠，见 `analyze` 的锚点循环），否则第三次以后的拷贝会被挤掉。
    static let maxRunsPerFileAndHash = 8
    /// 一个块至少要有一到二成行逐字一致才算「拷贝粘贴」（6 行的最小块 = ≥2 行原文相同）。
    /// 低于此值说明两边只是 token 形状相同，视图上会显示成「相似度 0% 的 35 行重复」这种没意义的答案。
    /// Homebrew 实测（含同文件粘贴的口径，20.38 万代码行）：取 0 时 32812 行重复、取 0.2 时 22297、
    /// 取 0.4 时 18221 —— 不设门槛会多算 47% 的「只是 token 形状相同」的行，
    /// 0.2 砍掉这批量又基本不伤逐字改名的拷贝（0.4 才开始掉），故维持 0.2。
    static let minCloneSimilarity = 0.2
    /// 一个块最多列几处出现（明细上限，冻结单测要求 ≤6，UI 也只画前 4 处 + 「另有 N 处」）。
    /// 与 `maxOccurrencesPerHash` 解耦：后者是配对索引预算（更大），这里只决定一个块展示/覆盖几处。
    static let maxFragmentsPerBlock = 6
    static let runsCapacityCap = 300_000

    // MARK: - Byte helpers

    static let spaceByte: UInt8 = 0x20
    static let tabByte: UInt8 = 0x09
    static let newlineByte: UInt8 = 0x0A
    static let carriageByte: UInt8 = 0x0D
    static let verticalByte: UInt8 = 0x0B
    static let formByte: UInt8 = 0x0C
    static let dotByte: UInt8 = 0x2E
    static let zeroByte: UInt8 = 0x30
    static let nineByte: UInt8 = 0x39
    static let underscoreByte: UInt8 = 0x5F
    static let backslashByte: UInt8 = 0x5C
    static let letterNByte: UInt8 = 0x4E
    static let letterSByte: UInt8 = 0x53
    /// 标识符（变量名 / 函数名 / 类型名）整体折成一个 `I` 占位符，于是 type-2 克隆
    /// （复制后改名的代码）也能命中同一指纹；字面量另有 `N` / `S` 占位。
    static let letterIByte: UInt8 = 0x49
    static let exponentLowerByte: UInt8 = 0x65
    static let exponentUpperByte: UInt8 = 0x45
    static let plusByte: UInt8 = 0x2B
    static let minusByte: UInt8 = 0x2D
    static let lowerFByte: UInt8 = 0x66
    static let upperFByte: UInt8 = 0x46

    static let fnvOffsetBase: UInt64 = 0xcbf2_9ce4_8422_2325
    static let fnvPrime: UInt64 = 0x100_0000_01b3

    static func isSpaceByte(_ b: UInt8) -> Bool {
    b == spaceByte || b == tabByte || b == newlineByte || b == carriageByte || b == verticalByte || b == formByte
    }

    static func isDigitByte(_ b: UInt8) -> Bool { b >= zeroByte && b <= nineByte }

    static func isLetterByte(_ b: UInt8) -> Bool {
    (b >= 0x61 && b <= 0x7A) || (b >= 0x41 && b <= 0x5A)
    }

    static func isHexLetterByte(_ b: UInt8) -> Bool {
    (b >= 0x61 && b <= lowerFByte) || (b >= 0x41 && b <= upperFByte)
    }

    static func isHexDigitByte(_ b: UInt8) -> Bool { isDigitByte(b) || isHexLetterByte(b) }

    /// 非 ASCII 字节一律视作标识符字符（中文标识符/全角符号不该被拆成数字边界）。
    static func isIdentByte(_ b: UInt8) -> Bool {
    b >= 0x80 || isLetterByte(b) || isDigitByte(b) || b == underscoreByte || b == 0x24 || b == 0x40
    }

    static func isRadixMarker(_ b: UInt8) -> Bool {
    b == 0x78 || b == 0x58 || b == 0x62 || b == 0x42 || b == 0x6F || b == 0x4F
    }

    static func hasPrefix(_ seq: [UInt8], at index: Int, in src: [UInt8]) -> Bool {
    guard index + seq.count <= src.count else { return false }
    var offset = 0
    while offset < seq.count {
        if src[index + offset] != seq[offset] { return false }
        offset += 1
    }
    return true
    }

    static func closingQuoteResume(_ quote: UInt8, in src: [UInt8], from: Int) -> Int? {
    var i = from
    while i < src.count {
        let b = src[i]
        if b == backslashByte { i += 2; continue }
        if b == quote { return i + 1 }
        i += 1
    }
    return nil
    }

    static func closingSequenceResume(_ seq: [UInt8], in src: [UInt8], from: Int) -> Int? {
    var i = from
    while i + seq.count <= src.count {
        if src[i] == seq[0], hasPrefix(seq, at: i, in: src) { return i + seq.count }
        i += 1
    }
    return nil
    }

    static func radixNumberResume(_ src: [UInt8], from start: Int) -> Int {
    let count = src.count
    var i = start + 2
    while i < count, isHexDigitByte(src[i]) || src[i] == underscoreByte { i += 1 }
    return i
    }

    static func numberResume(_ src: [UInt8], from start: Int) -> Int {
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

    struct LineSyntax {
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
    static let structureBytes: Set<UInt8> = [
    0x3D,                                     // =
    0x28, 0x29,                               // ( )
    0x7B, 0x7D,                               // { }
    0x5B, 0x5D,                               // [ ]
    0x3C, 0x3E,                               // < >
    0x3A, 0x3B,                               // : ;
    0x7C, 0x26, 0x2F,                         // | & /
    ]

    static let singleQuoteDelimiters: [[UInt8]] = [[0x22], [0x27], [0x60]]

    static func buildLineSyntax(language: String) -> LineSyntax {
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
    static func normalizeBytes(_ text: String, syntax: LineSyntax) -> [UInt8]? {
        var scanner = ByteLineScanner(src: Array(text.utf8), syntax: syntax)
        return scanner.run()
    }

    /// 一行字节的归一化扫描。原先这是 `normalizeBytes` 里 108 行 / CC 27 的一整段，
    /// 现在按**原来的判定顺序**切成一格一小段：
    /// 空白 → 行注释 → 块注释 → 字符串 → 数字 → 标识符 / 符号 → 收尾阈值。
    ///
    /// 三条最容易被「顺手重写」改坏的语义刻意留住了：
    /// 1. 「是不是又一个词元的开头」只看**源码里的前一个字节**（`previousByte`），不看折叠后的输出：
    ///    归一化输出会折叠空白，于是 `x = 1 // note` 里 `//` 的前一个**输出**字节是 `N`（标识符字符），
    ///    按输出口径判定就会漏掉行内注释、把注释文字折成 `// I` 留在指纹里（两份逐字相同的代码只要
    ///    注释不同就撞不上，是 type-1 漏报）。第 0 列视作空白，因此整行注释照样归一化为 nil。
    /// 2. 字符串 / 块注释 / 数字命中后是 `i = resume`（一次跳过整段），普通分支才是 `i += 1`；
    /// 3. `tokenRuns` 与 `inIdentRun` 的「同一段标识符只记一次词元」推进节奏完全照原样。
    struct ByteLineScanner {
        let src: [UInt8]
        let syntax: LineSyntax
        var out: [UInt8] = []
        var pendingSpace = false
        var tokenRuns = 0
        var inIdentRun = false
        var i = 0

        init(src: [UInt8], syntax: LineSyntax) {
            self.src = src
            self.syntax = syntax
            out.reserveCapacity(src.count + 2)
        }

        var count: Int { src.count }

        /// 第 0 列视作空白。
        var previousByte: UInt8 { i == 0 ? DupLex.spaceByte : src[i - 1] }

        /// 主循环：走完一行后交给 `survivingBytes` 判阈值。
        mutating func run() -> [UInt8]? {
            while i < count {
                if DupLex.isSpaceByte(src[i]) {
                    pendingSpace = !out.isEmpty
                    // 空白同样终结标识符词元：`for row in rows` 是 4 个词元，不是 1 个
                    inIdentRun = false
                    i += 1
                    continue
                }
                if tokenStep() == false { break }
            }
            return survivingBytes()
        }

        /// 一个非空白位置上的判定。返回 false 等价于原实现的 `break`（从这里到行尾整段丢掉）。
        mutating func tokenStep() -> Bool {
            let prevByte = previousByte
            // 行注释从它在行内出现的位置起整段截断（含第 0 列，注释行因此归一化为 nil）。
            // 之所以不用担心 `#include`：C 系语言的行注释前缀是 `//`，目录里没有任何语言把 `#` 之外的
            // 预处理符号列为行注释前缀。已知精度损失：PHP 的 `#[属性]` 会被当注释丢掉 —— 而且它在更上游的
            // `SourceFileClassifier` 里就已经判成注释行（既不进分母、也进不到这里），要修得动语言目录表。
            if hitsLineComment(after: prevByte) { return false }
            switch blockCommentStep() {
            case .notACommentStart:
                break
            case .unterminated:
                return false
            case let .skippedTo(resume):
                pendingSpace = !out.isEmpty
                i = resume
                return true
            }
            if consumeStringLiteral() { return true }
            if consumeNumberLiteral(after: prevByte) { return true }
            consumeIdentifierOrSymbol()
            return true
        }

        func hitsLineComment(after prevByte: UInt8) -> Bool {
            guard DupLex.isIdentByte(prevByte) == false else { return false }
            return syntax.lineCommentPrefixes.contains(where: { DupLex.hasPrefix($0, at: i, in: src) })
        }

        /// 块注释的三种结局：不是块注释开头 / 本行内没闭合（原 `break`）/ 吃掉这一段从 resume 继续。
        enum BlockCommentStep {
            case notACommentStart
            case unterminated
            case skippedTo(resume: Int)
        }

        func blockCommentStep() -> BlockCommentStep {
            guard let blockStart = syntax.blockStart, let blockEnd = syntax.blockEnd,
                  DupLex.hasPrefix(blockStart, at: i, in: src) else { return .notACommentStart }
            guard let resume = DupLex.closingSequenceResume(blockEnd, in: src, from: i + blockStart.count)
            else { return .unterminated }
            return .skippedTo(resume: resume)
        }

        /// 字符串字面量整段折成一个 `S` 占位符。
        mutating func consumeStringLiteral() -> Bool {
            guard let slot = syntax.stringDelimiters.firstIndex(where: { DupLex.hasPrefix($0, at: i, in: src) })
            else { return false }
            let delimiter = syntax.stringDelimiters[slot]
            // 单字符引号要跳过 `\` 转义；多行串定界符按整段定界符配对（未闭合则吃到行尾）。
            let resume: Int?
            if delimiter.count == 1 {
                resume = DupLex.closingQuoteResume(delimiter[0], in: src, from: i + 1)
            } else {
                resume = DupLex.closingSequenceResume(delimiter, in: src, from: i + delimiter.count)
            }
            i = resume ?? count
            if pendingSpace { out.append(DupLex.spaceByte) }
            pendingSpace = false
            out.append(DupLex.letterSByte)
            if !inIdentRun { tokenRuns += 1; inIdentRun = true }
            return true
        }

        /// 数字的开头同样按源码上下文判定：`foo bar 123` 里的 `123` 前一个是空白，
        /// 就该折成 `N` 而不是被当成标识符续字符折成 `I`（否则「数字」与「标识符」在指纹里
        /// 撞成同一个词元，会造出「形状恰好相同」的伪克隆）。
        mutating func consumeNumberLiteral(after prevByte: UInt8) -> Bool {
            guard startsNumber(after: prevByte) else { return false }
            if pendingSpace { out.append(DupLex.spaceByte) }
            pendingSpace = false
            out.append(DupLex.letterNByte)
            if !inIdentRun { tokenRuns += 1; inIdentRun = true }
            i = DupLex.numberResume(src, from: i)
            return true
        }

        func startsNumber(after prevByte: UInt8) -> Bool {
            guard DupLex.isIdentByte(prevByte) == false else { return false }
            if DupLex.isDigitByte(src[i]) { return true }
            return src[i] == DupLex.dotByte && i + 1 < count && DupLex.isDigitByte(src[i + 1])
        }

        /// 标识符折成一个 `I`，其余字符原样落进指纹。
        mutating func consumeIdentifierOrSymbol() {
            if pendingSpace { out.append(DupLex.spaceByte) }
            pendingSpace = false
            if DupLex.isIdentByte(src[i]) {
                // 标识符词元只落一个 `I`，后面的字母直接吃掉：`revenueByCategory` -> `I`。
                // 长度不再随标识符命名波动，改名后的拷贝才能落到同一个指纹上。
                if !inIdentRun {
                    out.append(DupLex.letterIByte)
                    tokenRuns += 1
                    inIdentRun = true
                }
            } else {
                out.append(src[i])
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
        func survivingBytes() -> [UInt8]? {
            if out.count < DuplicationEngine.minNormalizedBytes { return nil }
            if tokenRuns < DupLex.minTokenCount { return nil }
            if tokenRuns < 2 && out.count < DupLex.minBytesForSingleTokenLine { return nil }
            if syntax.needsStructureByte, !out.contains(where: { DupLex.structureBytes.contains($0) }) { return nil }
            return out
        }
    }
}
