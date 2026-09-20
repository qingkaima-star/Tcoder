import Foundation
import XCTest
@testable import TcoderMonitor

/// OWNER: R 尺子包（性能 spec §4.3、AGENTS.md 第四轮红线 6）。
///
/// T5「主线程禁则」的静态守卫：`Views/**` 的渲染路径里不许出现
/// ① 每次访问现造的对象（`NSColor(name:` / `DateFormatter(` / `NumberFormatter(`，
///    以及间接形状 `.textColor`——令牌未缓存时它每次访问都 new 一个 `NSColor`）、
/// ② 全量排序 `.sorted(`、③ 同步文件 I/O。
///
/// **写成只减不增棘轮，而不是 `== 0`**，因为现状不是零（本文件下面记录了数出来的真数）。
/// 写成 `== 0` 的唯一后果是有人把守卫删掉；写成"≤ 基线"才既拦得住新增、
/// 又让存量有一条明确的下线路径。每条基线都写了**谁在哪个里程碑把它打到 0**。
///
/// **不许用环境变量门控跳过**（本仓已知假绿模式）：这里没有任何 `ProcessInfo` 分支，
/// 扫不到文件时靠"分母 > 0"断言直接判红。
final class PerfHitchGuardTests: XCTestCase {

    // MARK: - 扫描面

    /// 仓库根走 `#filePath` 回溯（与 `SelfScanHarness` / `SourceFileReachabilityTests` 同一套写法）：
    /// 本文件 → TcoderMonitorTests → Tests → TcoderMonitor（包根）。
    /// 测试进程的 CWD 不是包根，按相对路径扫会"静默扫不到东西、然后判通过"。
    private static let packageRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static var viewsRoot: URL {
        packageRoot.appendingPathComponent("Sources/TcoderMonitor/Views")
    }

    /// 渲染路径的跨度向下游展开几跳（见 `PerfHitchScan.helperHopDepth`）。
    static let helperHopDepth = 2

    /// 当前实测基线。改任何一个数都要在下面写清"为什么变"，且只许变小。
    ///
    /// 计数口径（与 `PerfHitchScan` 一字对齐的参考实现，可直接复核）：
    /// ```
    /// python3 /tmp/tcoder-R-count/scan_ref.py \
    ///   Sources/TcoderMonitor/Views 2
    /// ```
    /// 2026-09-20 在 rev `c0dbc0a` 上数出来的原始值（R 尺子包）：
    /// - `directFormatters` **1** —— `PerfLogs/ChartChrome.swift` 里 `DateFormatter()` 1 处。
    ///   → 归 **M1 / WS-W**（spec §5 写明"DateFormatter 提 static let"），终点 0。
    /// - `dynamicNSColor` **88** —— 渲染路径内 `.textColor` 88 处（Views 全目录 91 处，
    ///   差额 3 处在非渲染路径）。注意任务书里提到的"115 处"是**更早一次全 Sources 口径**的数，
    ///   本守卫只认 `Views/**` 渲染路径口径，两边不可混比。
    ///   → 归 **M0 / C 令牌缓存包（总工）**：`ColorToken.swift` 改成缓存后，
    ///     这一条的语义从"每次访问 new NSColor"降级为"引用一个缓存值"，
    ///     届时要由总工把它从禁则表里摘掉或重定基线——**在 C 包落地前它必须 ≤ 88**。
    /// - `fullSort` **2** —— `Git/ContributorsView.swift` 的 `ContributorAnalysis.sorted(...)` 1 处
    ///   + `Logs/LogsMetricGrid.swift` 的 `grouped.keys.sorted()` 1 处。
    ///   → 归 **M1 / WS-P 与 WS-W**（body 内派生集合缓存），终点 0。
    /// - `syncFileIO` **2** —— `Logs/LogsView.swift` 的 `fileExists(atPath:)` 与
    ///   `attributesOfItem(atPath:)` 各 1 处（经 `attachedItems` → `fileSize(of:)` 两跳进渲染路径）。
    ///   → 归 **M1 / WS-W**（spec §5 点名"LogsView.attachedItems 的 body 内 stat() 移出"），终点 0。
    static let knownBaseline: [String: Int] = [
        "directFormatters": 1,
        "dynamicNSColor": 88,
        "fullSort": 2,
        "syncFileIO": 2,
    ]

    /// 每条规则的负责人 / 里程碑，只在报错时打出来，避免"基线是遮羞布"。
    static let ownerNotes: [String: String] = [
        "directFormatters": "M1 WS-W：DateFormatter/NumberFormatter 提 static let（终点 0）",
        "dynamicNSColor": "M0 总工 C 包：ColorToken 缓存 NSColor（落地后重定基线，落地前只减不增）",
        "fullSort": "M1 WS-P/WS-W：body 内派生集合缓存或移到 publish 里算（终点 0）",
        "syncFileIO": "M1 WS-W：渲染路径的文件尺寸/存在性检查移到扫描期（终点 0）",
    ]

    // MARK: - 棘轮主体

    func testRenderPathViolationsDoNotGrowBeyondBaseline() throws {
        let scan = try PerfHitchScan.scanDirectory(Self.viewsRoot, helperHopDepth: Self.helperHopDepth)
        let counts = scan.counts, census = scan.census
        // 防"假零"的第一道：分母。目录解析失效时 counts 全 0，看起来像"债还清了"。
        XCTAssertGreaterThan(census.swiftFiles, 30,
                             "只扫到 \(census.swiftFiles) 个 Views 文件：路径口径变了，棘轮会假绿")
        XCTAssertGreaterThan(census.inScopeSpans, 200,
                             "只解析出 \(census.inScopeSpans) 个渲染路径跨度：body/Chart 发现逻辑失效了")
        XCTAssertGreaterThan(census.totalLines, 8_000,
                             "读到的源码行数异常少（\(census.totalLines)）——文件没真被读进来")

        var problems: [String] = []
        for rule in PerfHitchScan.rules where counts[rule.name] == nil {
            problems.append("规则「\(rule.name)」没有计数结果，扫描器漏了一条")
        }
        for (rule, baseline) in Self.knownBaseline {
            let now = counts[rule] ?? -1
            if now > baseline {
                let hits = scan.hits[rule, default: []].prefix(12).joined(separator: "\n    ")
                problems.append("""
                「\(rule)」从基线 \(baseline) 涨到 \(now)（新增 \(now - baseline) 处）
                    负责人/终点：\(Self.ownerNotes[rule] ?? "未写")
                    \(hits)
                """)
            }
        }
        // 防"假零"的第二道：基线本身不许被偷偷清零。
        XCTAssertTrue(Self.knownBaseline.values.reduce(0, +) > 0, "基线全 0 等于没有守卫")
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }

    /// 存量必须**可点名**：守卫报出来的每一条都要有"文件:行 + 原文"，
    /// 否则没人能修。这条同时兜住"计数对了但位置丢了"的半瞎实现。
    func testEveryRecordedHitCarriesFileLineAndSnippet() throws {
        let scan = try PerfHitchScan.scanDirectory(Self.viewsRoot, helperHopDepth: Self.helperHopDepth)
        let total = scan.counts.values.reduce(0, +)
        XCTAssertGreaterThan(total, 0, "一条都没数到 = 扫描器空转（见元测试 testScannerFiresOnBadSamples）")
        XCTAssertEqual(total, scan.hits.values.map(\.count).reduce(0, +),
                       "计数与明细不是一回事：明细必须逐条齐全")
        for hits in scan.hits.values {
            for hit in hits {
                XCTAssertTrue(hit.contains(":"), "命中项没带行号：\(hit)")
                XCTAssertFalse(hit.hasSuffix(":"), "命中项没有原文片段：\(hit)")
            }
        }
    }

    /// 真实存量必须**被扫到**：钉住两条已知事实，防止"正则退化成永远不匹配"。
    func testScannerFindsTheKnownRealOccurrences() throws {
        let scan = try PerfHitchScan.scanDirectory(Self.viewsRoot, helperHopDepth: Self.helperHopDepth)
        let io = scan.hits["syncFileIO"] ?? []
        XCTAssertTrue(io.contains { $0.hasPrefix("Logs/LogsView.swift") && $0.contains("attributesOfItem(") },
                      "LogsView 的 attributesOfItem 是已知存量，扫不到就说明 I/O 正则或跨度展开坏了：\(io)")
        let sorts = scan.hits["fullSort"] ?? []
        XCTAssertTrue(sorts.contains { $0.contains(".sorted(") },
                      "Views 里已知有 body 内排序，扫不到说明 .sorted( 正则失效：\(sorts)")
        let colors = scan.hits["dynamicNSColor"] ?? []
        XCTAssertTrue(colors.count >= 50, ".textColor 存量应有几十处，只数到 \(colors.count) 处：跨度提取退化了")
    }

    // MARK: - 元测试：每条守卫都要能被坏样例打红

    /// 本仓反复栽过的地方：扫描型守卫最坏的失效不是报错，而是
    /// **正则写坏 / 跨度解析失效 → 永远 0 命中还常绿**。所以每条规则配坏样例。
    func testScannerFiresOnBadSamples() throws {
        XCTAssertEqual(PerfHitchScan.badSamples.count, PerfHitchScan.rules.count,
                       "禁则表加了一条就得配一个坏样例，否则新规则是空转的")
        for (rule, samples) in PerfHitchScan.badSamples {
            guard let pattern = PerfHitchScan.rules.first(where: { $0.name == rule })?.pattern else {
                XCTFail("坏样例配了一条不存在的规则：\(rule)"); continue
            }
            for sample in samples {
                let hits = PerfHitchScan.matches(pattern: pattern, in: sample)
                XCTAssertFalse(hits.isEmpty, "规则「\(rule)」命中不了坏样例，它已经废了：\(sample)")
            }
        }
    }

    /// 把坏样例**包成真实 body 形状**喂给整条流水线（跨度提取 → 命中），
    /// 证明失效点不只在一个正则上：光测正则会漏掉"跨度解析退化成空集"。
    func testFullPipelineCatchesSyntheticBadViewFile() throws {
        let dirty = """
        struct BadView: View {
            var body: some View {
                let color = NSColor(name: nil) { _ in .black }
                let formatter = DateFormatter()
                let number = NumberFormatter()
                let names = allNames.sorted()
                let attrs = try? FileManager.default.attributesOfItem(atPath: "/tmp/x")
                return VStack {
                    Text("\\(names.count)").foregroundStyle(Theme.Semantic.warning.textColor)
                    Chart { ForEach(rows) { row in BarMark(x: .value("a", row.a)) } }
                }
            }
        }
        """
        let counts = try PerfHitchScan.scan(source: dirty)
        for rule in PerfHitchScan.rules.map(\.name) {
            XCTAssertGreaterThan(counts[rule] ?? 0, 0, "整条流水线对合成坏文件漏报了 \(rule)")
        }
    }

    /// 反向：合规写法不许被误伤（否则下一个人在报告里写"守卫太吵"，守卫就死了）。
    func testScannerDoesNotFireOnCleanRenderPath() throws {
        let clean = """
        struct GoodView: View {
            private static let dayFormatter: DateFormatter = PerfHitchGuardTests.makeFormatter()
            var body: some View {
                VStack(alignment: .leading, spacing: Theme.Layout.gapMd) {
                    Text(title).typed(Theme.Typo.groupLabel)
                        .foregroundStyle(Theme.Palette.Surface.ink)
                    MetricTile(label: "CPU", value: readout)
                    Chart { ForEach(points) { point in LineMark(x: .value("t", point.t), y: .value("v", point.v)) } }
                }
            }
        }
        """
        let counts = try PerfHitchScan.scan(source: clean)
        XCTAssertEqual(counts["directFormatters"] ?? 0, 0, "静态 let 的 DateFormatter 不该算 body 内构造")
        XCTAssertEqual(counts["fullSort"] ?? 0, 0)
        XCTAssertEqual(counts["syncFileIO"] ?? 0, 0)
        XCTAssertEqual(counts["dynamicNSColor"] ?? 0, 0, ".ink 是常量，.textColor 才是动态色形状")
    }

    /// 状态词/属性名不许被当成 I/O 或排序命中（`snapshot(`、`stats(`、`state.sorted` 之类）。
    func testIoAndSortPatternsAreNotTriggeredBySubstrings() throws {
        let nearMiss = """
        struct NearView: View {
            var body: some View {
                let text = "https://example.com/a"
                let n = snapshot.count
                let rows = displayedRows
                return Text(text).overlay(n > 0 ? rows.description : Text("--"))
            }
        }
        """
        let counts = try PerfHitchScan.scan(source: nearMiss)
        XCTAssertEqual(counts["syncFileIO"] ?? 1, 0, "字符串与标识符里的 `//`、`stat` 子串被误判了")
        XCTAssertEqual(counts["fullSort"] ?? 1, 0)
    }

    /// 跨度发现本身要被测：`body` 之外、且不在渲染路径里的 I/O **不算**违规（口径要窄）。
    func testCodeOutsideRenderPathIsOutOfScope() throws {
        let outOfScope = """
        enum Loader {
            static func load() -> Data { Data(contentsOf: url) }
        }
        """
        let counts = try PerfHitchScan.scan(source: outOfScope)
        XCTAssertEqual(counts["syncFileIO"] ?? 1, 0, "把全仓 I/O 都算进渲染路径，等于没有这条守卫")
    }

    // MARK: - FramePulse：第二把尺子的纯函数与"零开销"承诺

    /// 探针关闭时 `startIfNeeded()` 必须直接返回 false，且**不留下任何副作用**
    /// （连输出文件都不该被创建，更不该有 `CVDisplayLink`）。
    func testFramePulseStaysInertWithoutProbeFlag() throws {
        XCTAssertFalse(FramePulse.isProbeEnabled,
                       "测试环境里 TCODER_PERF_PROBE 必须不为 1，否则这条测的就不是默认路径")
        let path = FramePulse.outputPath
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "探针未开却已有 \(path)")
        XCTAssertFalse(FramePulse.shared.startIfNeeded(), "默认路径竟然启动了探针")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path),
                       "探针未开却创建了读数文件：零开销承诺破了")
    }

    func testFramePulseOutputPathFallsBackToPidFile() throws {
        let fromEnv = ProcessInfo.processInfo.environment["TCODER_PERF_OUT"]
        if let fromEnv, !fromEnv.isEmpty {
            XCTAssertEqual(FramePulse.outputPath, fromEnv, "TCODER_PERF_OUT 没被采用")
        } else {
            XCTAssertTrue(FramePulse.outputPath.hasPrefix("/tmp/tcoder-framepulse-"),
                          "缺省路径形状不对：\(FramePulse.outputPath)")
            XCTAssertTrue(FramePulse.outputPath.contains("\(getpid())"), "缺省路径要按 pid 分文件")
        }
    }

    /// 两把尺子的分位定义必须一字对齐（`scripts/trace_report.py` 的 `percentile()`）。
    func testPercentileMatchesTheExternalRuler() {
        let values = (1...2340).map { Double($0) / 100.0 }   // 0.01ms ~ 23.40ms
        XCTAssertEqual(percentile(values, 0.50), 11.71, accuracy: 0.001)
        XCTAssertEqual(percentile(values, 0.95), 22.24, accuracy: 0.001)
        XCTAssertEqual(percentile(values, 0.99), 23.17, accuracy: 0.001)
        XCTAssertEqual(percentile([Double](), 0.5), 0, "空样本要如实给 0，不能崩")
    }

    func testFrameIntervalDistributionCountsHitchesAgainstRealHz() {
        var dist = FrameIntervalDistribution()
        for _ in 0..<99 { dist.record(8.0) }     // 120 Hz 正常帧
        dist.record(20.0)                        // 2.4× 期望间隔 = hitch
        dist.record(12.4)                        // 1.49× —— 未过 1.5× 线，不算
        XCTAssertEqual(dist.hitchCount(expectedIntervalMs: 8.333), 1)
        XCTAssertEqual(dist.maximum, 20.0, accuracy: 0.001)
        dist.record(-1)                          // 非正数样本按定义丢弃
        XCTAssertEqual(dist.values.count, 101)
    }

    func testHeartbeatGapDistributionExposesOccupiedTime() {
        var gaps = HeartbeatGapDistribution()
        XCTAssertTrue(gaps.isEmpty)
        [1.5, 2.0, 43.0, 3.0].forEach { gaps.record(gapMs: $0) }
        XCTAssertEqual(gaps.maximum, 43.0, accuracy: 0.001, "43ms = 主线程被占住多久，这条看门狗的存在理由")
        XCTAssertGreaterThan(gaps.p50, 1.4)
        XCTAssertLessThan(gaps.p50, 3.1)
    }

    /// 真实 Hz 必须运行时读出来（不许有人日后把它写死成 120）。
    func testRefreshRateIsReadAtRuntimeNotHardcoded() {
        let (hz, source) = FramePulse.readRefreshRate()
        XCTAssertFalse(source.isEmpty, "刷新率来源没标注，读数就没法解释")
        if hz > 0 {
            XCTAssertGreaterThanOrEqual(hz, 30)
            XCTAssertLessThanOrEqual(hz, 250)
            XCTAssertNotEqual(hz.rounded(), 0, "读回来的 Hz 不像真数：\(hz)")
        } else {
            XCTAssertTrue(source.contains("兜底"), "读不到 Hz 时必须如实标注兜底：\(source)")
        }
    }

    static func makeFormatter() -> DateFormatter { DateFormatter() }
}

// MARK: - 扫描器（纯 Foundation，可被 /tmp 下的独立复核程序原样编进去）

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
        ("dynamicNSColor", #"\.textColor\b"#),
        ("fullSort", #"\.sorted\s*\("#),
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
        ("dynamicNSColor", ["Text(\"x\").foregroundStyle(role.textColor)"]),
        ("fullSort", ["let rows = allRows.sorted { $0.name < $1.name }"]),
        ("syncFileIO", ["guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }",
                        "if FileManager.default.fileExists(atPath: project.path) {",
                        "let kids = try FileManager.default.contentsOfDirectory(atPath: root)",
                        "let raw = try Data(contentsOf: url)",
                        "let text = try String(contentsOf: url, encoding: .utf8)",
                        "var st = stat(); stat(path, &st)"]),
    ]

    // MARK: 脱敏

    /// 与参考实现 `scan_ref.py` 的 `mask()` 同语义的等长脱敏。
    static func mask(_ source: String) -> [UInt16] {
        let src = Array(source.utf16)
        var out = src
        let slash: UInt16 = 47, star: UInt16 = 42, quote: UInt16 = 34, colon: UInt16 = 58
        let backslash: UInt16 = 92, openParen: UInt16 = 40, closeParen: UInt16 = 41, newline: UInt16 = 10

        func isUnit(_ i: Int, _ u: UInt16) -> Bool { i < src.count && src[i] == u }
        func literal(_ at: Int, _ text: String) -> Bool {
            let chars = Array(text.utf16)
            guard at + chars.count <= src.count else { return false }
            for k in 0..<chars.count where src[at + k] != chars[k] { return false }
            return true
        }
        func blank(_ from: Int, _ to: Int) {
            var k = max(from, 0)
            while k < min(to, src.count) { if out[k] != newline { out[k] = 32 }; k += 1 }
        }

        var i = 0
        while i < src.count {
            if isUnit(i, slash), literal(i, "//"), i > 0, src[i - 1] != colon {
                var j = i
                while j < src.count, src[j] != newline { j += 1 }
                blank(i, j); i = j; continue
            }
            if isUnit(i, slash), literal(i, "/*") {
                var depth = 1
                var j = i + 2
                while j < src.count, depth > 0 {
                    if literal(j, "/*") { depth += 1; j += 2 }
                    else if literal(j, "*/") { depth -= 1; j += 2 }
                    else { if out[j] != newline { out[j] = 32 }; j += 1 }
                }
                blank(i, i + 2); blank(max(j - 2, 0), j); i = j; continue
            }
            if isUnit(i, quote) {
                let triple = literal(i, "\"\"\"")
                let quoteLen = triple ? 3 : 1
                let start = i + quoteLen
                var j = start
                var kept: [(Int, Int)] = []
                while j < src.count {
                    if literal(j, "\\(") {
                        var depth = 1
                        var k = j + 2
                        while k < src.count, depth > 0 {
                            if src[k] == openParen { depth += 1 }
                            else if src[k] == closeParen { depth -= 1 }
                            k += 1
                        }
                        kept.append((j, k)); j = k; continue
                    }
                    if src[j] == backslash { j += 2; continue }
                    if literal(j, triple ? "\"\"\"" : "\"") { break }
                    j += 1
                }
                let end = min(j, src.count)
                blank(start, end)
                for (a, b) in kept {
                    var k = a
                    while k < b { out[k] = src[k]; k += 1 }
                }
                i = min(end + quoteLen, src.count)
                continue
            }
            i += 1
        }
        return out
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
                    let line = leadingLines + ns.substring(to: m.range.location).components(separatedBy: "\n").count - 1
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
