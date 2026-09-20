/// OWNER: WS-X3 TestSplit —— 自 PerfHitchGuardTests.swift 整块拆出：渲染路径禁则的扫描器本体（正则、掩码、判定）。用例本体一字未改，只是搬了家。
import Foundation
import XCTest
@testable import TcoderMonitor

/// T5 禁则的扫描器：脱敏 → 找渲染路径跨度 → 在跨度里数禁用形状。
///
/// **全程用 UTF-16 码元下标**（`String.utf16`），因为 `NSRegularExpression` 的 `range`
/// 本来就是 UTF-16 偏移；用 `Array<Character>` 的下标去配它，非 ASCII 一多跨度就整体漂移。
/// 脱敏只判 ASCII 字符（`/`、`*`、`"`、`\`、括号、`\n`），在 UTF-16 上做是安全的。
///
/// **口径三件事，少任何一件都会得出错误结论**：
/// 1. **脱敏**：注释与字符串字面量先抹成等长空格（插值 `\(...)` 里的表达式按代码保留），
///    否则一句 `// 这里曾有 stat()` 就把守卫点红，而守卫一被点红就有人删。
/// 2. **跨度**：只算 `var body: some View { … }` 与 `Chart { … }` 的花括号配平区间。
///    把整个文件当渲染路径，等于把启动期/扫描期的合法 I/O 也算成违规，这条守卫立刻失去公信力。
/// 3. **跳展开**：`body` 里调到的同文件计算属性/函数（如 `LogsView.attachedItems`
///    → `fileSize(of:)`）也在渲染路径上，所以按"名字被当前跨度整词提到"递归展开
///    `helperHopDepth` 跳。不展开就会把最常见的"包装一层再 I/O"洗成合规。
enum PerfHitchScan {

    struct Census {
        var swiftFiles = 0
        var inScopeSpans = 0
        var totalLines = 0
    }

    struct ScanResult {
        var counts: [String: Int]
        var hits: [String: [String]]
        var census: Census
    }

    /// 禁用形状。`syncFileIO` 的词表按 AGENTS.md 第四轮红线 6 覆盖
    /// `fileExists` / `attributesOfItem` / `contentsOfDirectory` / `Data(contentsOf:` /
    /// `String(contentsOf:` / `stat(` / `lstat(` / `FileManager`——
    /// **只匹配 `stat(` 会得到一条永真绿守卫**（本仓实际写法是 `attributesOfItem(atPath:)`）。
    static let rules: [(name: String, pattern: String)] = [
        ("directFormatters", #"(?<![\w.])(?:NSColor|DateFormatter|NumberFormatter)\s*\("#),
        ("dynamicNSColor", #"\.(?:textColor|graphicColor|badgeFill|onFillColor)\b"#),
        // 尾随闭包 `.sorted { … }` 与带参 `.sorted(by:)` 都是全量排序，两个形状都要抓：
        // 只写 `\.sorted\s*\(` 会漏掉尾随闭包那种写法，而 `badSamples` 里用的正是它——
        // 元测试 `testScannerFiresOnBadSamples` 就是靠这个把"规则过窄"照出来的。
        ("fullSort", #"\.sorted\s*(?:\(|\{)"#),
        ("syncFileIO", #"(?<![\w.])(?:l?stat)\s*\(|(?:Data|String)\(contentsOf:|contents\(ofDirectory|contents\(ofPath:|attributesOfItem\(|fileExists\(|FileManager"#),
    ]

    /// 正则必须能编译（`matches` 对编不过的模式只返回空并报警，那条规则就静默失效了，
    /// 所以单列一条守卫钉住它）。
    static func assertableRulePatternsCompile() -> [String] {
        rules.compactMap { rule in (try? NSRegularExpression(pattern: rule.pattern)) == nil ? rule.name : nil }
    }

    /// 每条规则的坏样例（元测试用）。I/O 那条特意用**仓库里真实存在的形状**
    /// `attributesOfItem(atPath:)`，而不是 `stat(`。
    static let badSamples: [(String, [String])] = [
        ("directFormatters", [#"let c = NSColor(name: nil) { _ in .black }"#,
                              "let formatter = DateFormatter()",
                              "let nf = NumberFormatter()"]),
        ("dynamicNSColor", ["Text(\"x\").foregroundStyle(role.textColor)",
                            "LineMark(x: .value(\"t\", p.t)).foregroundStyle(series.graphicColor)",
                            "RoundedRectangle().fill(state.badgeFill)",
                            "Image(systemName: \"x\").foregroundStyle(colorSet.onFillColor)"]),
        ("fullSort", ["let rows = allRows.sorted { $0.name < $1.name }",
                      "let names = allNames.sorted(by: { $0.count > $1.count })"]),
        ("syncFileIO", ["guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }",
                        "if FileManager.default.fileExists(atPath: project.path) {",
                        "let kids = try FileManager.default.contentsOfDirectory(atPath: root)",
                        "let raw = try Data(contentsOf: url)",
                        "let text = try String(contentsOf: url, encoding: .utf8)",
                        "var st = stat(); stat(path, &st)"]),
    ]

    // MARK: 脱敏

    /// 与参考实现 `scan_ref.py` 的 `mask()` 同语义的等长脱敏。
    /// UTF-16 码点常量（与 `scan_ref.py` 的 `mask()` 同一套）。
    private static let unitSlash: UInt16 = 47, unitStar: UInt16 = 42, unitQuote: UInt16 = 34
    private static let unitColon: UInt16 = 58, unitBackslash: UInt16 = 92
    private static let unitOpenParen: UInt16 = 40, unitCloseParen: UInt16 = 41, unitNewline: UInt16 = 10
    private static let unitSpace: UInt16 = 32

    /// 与参考实现 `scan_ref.py` 的 `mask()` 同语义的等长脱敏。
    ///
    /// WS-X3 拆分：本函数原判 **CC 26 / 69 行**（嵌套的 `isUnit` / `literal` / `blank` 与被
    /// 内联的三段状态机全算在宿主函数头上）。三段各成一个 `mask…` 步骤、三个小工具挂到游标上，
    /// **判定条件与涂白范围逐字照搬**；判据本身一个字没改（它扫的是 `Views/**` 的写法，
    /// 与本文件住在哪个文件无关）。
    static func mask(_ source: String) -> [UInt16] {
        var cursor = MaskCursor(src: Array(source.utf16))
        while cursor.i < cursor.count {
            if let next = maskLineComment(&cursor) { cursor.i = next; continue }
            if let next = maskBlockComment(&cursor) { cursor.i = next; continue }
            if let next = maskStringLiteral(&cursor) { cursor.i = next; continue }
            cursor.i += 1
        }
        return cursor.out
    }

    /// 脱敏游标：原文 `src` 只读，产物 `out` 等长涂白，`i` 是当前码点下标。
    struct MaskCursor {
        let src: [UInt16]
        var out: [UInt16]
        var i: Int = 0

        init(src: [UInt16]) {
            self.src = src
            self.out = src
        }

        var count: Int { src.count }

        func unit(_ i: Int, _ u: UInt16) -> Bool { i < src.count && src[i] == u }

        func literal(_ at: Int, _ text: String) -> Bool {
            let chars = Array(text.utf16)
            guard at + chars.count <= src.count else { return false }
            for k in 0..<chars.count where src[at + k] != chars[k] { return false }
            return true
        }

        /// 把 [from, to) 涂成空格，换行原样保留（行号与列宽都不能漂）。
        mutating func blank(_ from: Int, _ to: Int) {
            var k = max(from, 0)
            while k < min(to, src.count) { if out[k] != Self.newline { out[k] = Self.space }; k += 1 }
        }

        static let newline: UInt16 = 10
        static let space: UInt16 = 32
    }

    /// 行注释：`//` 起头、前面不是 `:`（避开 `https://` 这类字面量里的双斜杠）。
    static func maskLineComment(_ c: inout MaskCursor) -> Int? {
        guard c.unit(c.i, unitSlash), c.literal(c.i, "//"), c.i > 0,
              c.src[c.i - 1] != unitColon else { return nil }
        var j = c.i
        while j < c.count, c.src[j] != unitNewline { j += 1 }
        c.blank(c.i, j)
        return j
    }

    /// 块注释：支持嵌套 `/* /* */ */`，靠 depth 计数。
    static func maskBlockComment(_ c: inout MaskCursor) -> Int? {
        guard c.unit(c.i, unitSlash), c.literal(c.i, "/*") else { return nil }
        var depth = 1
        var j = c.i + 2
        while j < c.count, depth > 0 {
            if c.literal(j, "/*") { depth += 1; j += 2 }
            else if c.literal(j, "*/") { depth -= 1; j += 2 }
            else { if c.out[j] != unitNewline { c.out[j] = unitSpace }; j += 1 }
        }
        c.blank(c.i, c.i + 2)
        c.blank(max(j - 2, 0), j)
        return j
    }

    /// 字符串字面量：整体涂白，但 `\(…)` 插值里的代码要**留下**（那是真的引用证据）。
    static func maskStringLiteral(_ c: inout MaskCursor) -> Int? {
        guard c.unit(c.i, unitQuote) else { return nil }
        let triple = c.literal(c.i, "\"\"\"")
        let quoteLen = triple ? 3 : 1
        let start = c.i + quoteLen
        var j = start
        var kept: [(Int, Int)] = []
        while j < c.count {
            if let end = maskInterpolation(c, at: j) {
                kept.append((j, end)); j = end; continue
            }
            if c.src[j] == unitBackslash { j += 2; continue }
            if c.literal(j, triple ? "\"\"\"" : "\"") { break }
            j += 1
        }
        let end = min(j, c.count)
        c.blank(start, end)
        for (a, b) in kept {
            var k = a
            while k < b { c.out[k] = c.src[k]; k += 1 }
        }
        return min(end + quoteLen, c.count)
    }

    /// 插值 `\(` … `)` 的括号配平跨度；不是插值就返回 nil。
    static func maskInterpolation(_ c: MaskCursor, at j: Int) -> Int? {
        guard c.literal(j, "\\(") else { return nil }
        var depth = 1
        var k = j + 2
        while k < c.count, depth > 0 {
            if c.src[k] == unitOpenParen { depth += 1 }
            else if c.src[k] == unitCloseParen { depth -= 1 }
            k += 1
        }
        return k
    }

    static func string(_ units: [UInt16], _ from: Int, _ to: Int) -> String {
        let lo = max(0, min(from, units.count)), hi = max(lo, min(to, units.count))
        return String(decoding: Array(units[lo..<hi]), as: UTF16.self)
    }

    // MARK: 跨度

    /// 从 `from` 起第一个 `{` 开始配平，返回闭括号之后的下标。
    static func braceEnd(_ units: [UInt16], from: Int) -> Int? {
        let open: UInt16 = 123, close: UInt16 = 125
        var i = max(0, from)
        while i < units.count, units[i] != open { i += 1 }
        guard i < units.count else { return nil }
        var depth = 0
        var j = i
        while j < units.count {
            if units[j] == open { depth += 1 }
            else if units[j] == close { depth -= 1; if depth == 0 { return j + 1 } }
            j += 1
        }
        return nil
    }

    /// 渲染路径种子跨度：`var|let NAME: some View { … }` 与 `Chart { … }`。
    static func seedSpans(_ units: [UInt16]) -> [(start: Int, end: Int, kind: String)] {
        let s = string(units, 0, units.count)
        var out: [(Int, Int, String)] = []
        for (pattern, kind) in [(#"\b(?:var|let)\s+\w+\s*:\s*some\s+View\b"#, "body"),
                                (#"(?<![\w.])Chart\b\s*(?:\([^;{]*\))?\s*\{"#, "chart")] {
            for range in nsRanges(pattern, in: s) {
                let from = kind == "chart" ? range.lowerBound : range.upperBound
                if let close = braceEnd(units, from: from) { out.append((range.lowerBound, close, kind)) }
            }
        }
        return out
    }

    /// 同文件里可被展开的声明跨度：`var NAME … {`（含计算属性）与 `func NAME(`。
    static func declSpans(_ units: [UInt16]) -> [(name: String, start: Int, end: Int)] {
        let s = string(units, 0, units.count)
        var out: [(String, Int, Int)] = []
        for (pattern, isFunc) in [(#"\bvar\s+(\w+)\s*(?::[^={;]{0,120}?)?\s*\{"#, false),
                                  (#"\bfunc\s+(\w+)\s*\("#, true)] {
            let regex = try! NSRegularExpression(pattern: pattern)
            for m in regex.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length)) {
                let name = (s as NSString).substring(with: m.range(at: 1))
                let tail = utf16(of: s, m.range.location + m.range.length)
                let from = isFunc ? tail : tail - 1
                if let close = braceEnd(units, from: from) {
                    out.append((name, utf16(of: s, m.range.location), close))
                }
            }
        }
        return out
    }

    /// NSRange 本身就是 UTF-16 偏移，这里只做一次防御性换算，避免以后有人改成 Character。
    static func utf16(of text: String, _ nsLocation: Int) -> Int { nsLocation }

    static func nsRanges(_ pattern: String, in text: String) -> [Range<Int>] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var out: [Range<Int>] = []
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m, m.range.location != NSNotFound else { return }
            out.append(m.range.location..<(m.range.location + m.range.length))
        }
        return out
    }

    /// 当前跨度里"整词提到"的声明，其跨度并入下一轮（`Self.` / `x.` 前缀也算引用）。
    static func expand(_ units: [UInt16], covered: [(start: Int, end: Int)],
                       decls: [(name: String, start: Int, end: Int)]) -> [(Int, Int)] {
        let joined = covered.map { string(units, $0.start, $0.end) }.joined(separator: "\n")
        var added: [(Int, Int)] = []
        for name in Set(decls.map(\.name)).sorted() {
            guard !nsRanges("(?<![\\w])" + name + "\\b", in: joined).isEmpty else { continue }
            for decl in decls where decl.name == name {
                if !covered.contains(where: { decl.start >= $0.start && decl.end <= $0.end }) {
                    added.append((decl.start, decl.end))
                }
            }
        }
        return added
    }

    // MARK: 命中

    static func matches(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var out: [String] = []
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m, m.range.location != NSNotFound else { return }
            out.append(ns.substring(with: m.range))
        }
        return out
    }

    /// 单文件扫描，返回跨度数；命中写进 counts / hits（同一行同一规则只算一次）。
    @discardableResult
    static func scanFile(source: String, relativePath: String, helperHopDepth: Int,
                         into counts: inout [String: Int], hits: inout [String: [String]]) -> Int {
        let units = mask(source)
        let rawLines = source.components(separatedBy: "\n")
        var covered = seedSpans(units).map { ($0.start, $0.end) }
        let decls = declSpans(units)
        for _ in 0..<max(0, helperHopDepth) {
            let added = expand(units, covered: covered, decls: decls)
            if added.isEmpty { break }
            covered += added
        }
        var found = Set<String>()
        for span in covered {
            let segment = string(units, span.0, span.1)
            let leadingLines = string(units, 0, span.0).components(separatedBy: "\n").count - 1
            for rule in rules {
                let regex = try? NSRegularExpression(pattern: rule.pattern)
                guard let regex else { continue }
                let ns = segment as NSString
                regex.enumerateMatches(in: segment, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                    guard let m, m.range.location != NSNotFound else { return }
                    // 行号 = 命中点之前的换行总数 + 1。
                    // `leadingLines` 是跨度起点的换行数；第二项是「跨度起点 → 命中点」这段前缀
                    // 按 `\n` 切出来的段数，等于该前缀内部换行数 **+ 1**。两项相加已含那个 +1，
                    // 所以这里**不再减一**——改前多减了一次，报出的行号整体小 1，
                    // `rawLines[line - 1]` 于是取到命中行的**上一行**，元测试
                    // `testScannerFindsTheKnownRealOccurrences` 就是靠这个发现的。
                    let line = leadingLines + ns.substring(to: m.range.location).components(separatedBy: "\n").count
                    let key = "\(rule.name):\(line)"
                    if found.contains(key) { return }
                    found.insert(key)
                    counts[rule.name, default: 0] += 1
                    let snippet = line - 1 < rawLines.count && line >= 1
                        ? rawLines[line - 1].trimmingCharacters(in: .whitespaces) : ""
                    hits[rule.name, default: []].append("\(relativePath):\(line) \(snippet)")
                }
            }
        }
        return covered.count
    }

    // MARK: 入口

    /// 单串扫描（元测试用）。
    static func scan(source: String, helperHopDepth: Int = 2) -> [String: Int] {
        var counts = rules.reduce(into: [String: Int]()) { $0[$1.name] = 0 }
        var hits = [String: [String]]()
        _ = scanFile(source: source, relativePath: "<synthetic>", helperHopDepth: helperHopDepth,
                     into: &counts, hits: &hits)
        return counts
    }

    static func scanDirectory(_ root: URL, helperHopDepth: Int) throws -> ScanResult {
        var counts = rules.reduce(into: [String: Int]()) { $0[$1.name] = 0 }
        var hits = [String: [String]]()
        var census = Census()
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw NSError(domain: "PerfHitchGuard", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "扫不到目录 \(root.path)：路径口径变了"])
        }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" { files.append(url) }
        files.sort { $0.path < $1.path }
        for url in files {
            let source = try String(contentsOf: url, encoding: .utf8)
            census.swiftFiles += 1
            census.totalLines += source.components(separatedBy: "\n").count
            let relative = url.path.hasPrefix(root.path)
                ? String(url.path.dropFirst(root.path.count + 1)) : url.lastPathComponent
            census.inScopeSpans += scanFile(source: source, relativePath: relative,
                                            helperHopDepth: helperHopDepth, into: &counts, hits: &hits)
        }
        for key in hits.keys { hits[key]?.sort() }
        return ScanResult(counts: counts, hits: hits, census: census)
    }
}
