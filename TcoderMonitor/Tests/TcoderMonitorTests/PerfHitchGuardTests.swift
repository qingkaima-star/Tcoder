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
    static let packageRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static var viewsRoot: URL {
        packageRoot.appendingPathComponent("Sources/TcoderMonitor/Views")
    }

    /// 判据写的是"**body/Mark 内**零动态色/零排序/零同步 I/O"，而 `Design/**` 里的
    /// `GlassSection` / `ReadoutKit` / `DataRows` 本身就是视图构造器——只扫 `Views/`
    /// 等于把判据的适用范围偷偷缩小了。2026-09-21 实测到这个盲区真的在长东西：
    /// 新并进来的运行时漏翻台账把 `misses.sorted()` 放在 `Design/ReadoutKit.swift`，
    /// 老扫描面一条都数不到。
    static var designRoot: URL {
        packageRoot.appendingPathComponent("Sources/TcoderMonitor/Design")
    }

    /// 渲染路径 = Views ∪ Design。分母按**每一棵根**分别要求，
    /// 否则哪天某棵根解析失效（路径改名、目录搬走），合并后的总数看着还是"够大"，
    /// 守卫就悄悄退化成半瞎——这正是本文件第 3 条元测试要防的形状。
    static func scanRenderSurface() throws -> PerfHitchScan.ScanResult {
        var merged = try PerfHitchScan.scanDirectory(viewsRoot, helperHopDepth: helperHopDepth)
        let design = try PerfHitchScan.scanDirectory(designRoot, helperHopDepth: helperHopDepth)
        XCTAssertGreaterThanOrEqual(design.census.swiftFiles, 10,
                                    "Design/ 只扫到 \(design.census.swiftFiles) 个文件：这棵根失效了，合并读数会假绿")
        // 两棵根的命中路径都是**相对各自根**的，直接并起来会出现两个 `ChartTokens.swift:185`
        // 分不清谁是谁——而"每条存量必须可点名"是这条守卫存在的理由之一。
        for (rule, n) in design.counts {
            merged.counts[rule, default: 0] += n
            merged.hits[rule, default: []] += (design.hits[rule] ?? []).map { "Design/\($0)" }
        }
        for rule in merged.hits.keys where merged.hits[rule] != nil {
            merged.hits[rule] = merged.hits[rule]?.map { $0.hasPrefix("Design/") ? $0 : "Views/\($0)" }
        }
        merged.census.swiftFiles += design.census.swiftFiles
        merged.census.inScopeSpans += design.census.inScopeSpans
        merged.census.totalLines += design.census.totalLines
        return merged
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
    /// - `fullSort` **10** —— 2026-09-20 17:00 由总工**复量校正**（原记 2 是错的）。
    ///   原值 2 是用只认 `.sorted(` 的正则量出来的，而仓库里真实写法以**尾随闭包**
    ///   `.sorted { … }` 为主，于是 8 处漏计（实测清单见 `testRenderPathViolationsDoNotGrowBeyondBaseline`
    ///   的报错体）。这正是本仓反复记的失效模式：**正则过窄 → 分母虚低 → 守卫看着有牙其实是假绿**。
    ///   现在的规则同时认 `.sorted(` 与 `.sorted {`，基线按**今天的真值**重新钉成 10，目标仍是 0。
    ///   （同一次校正里 `fullSort` 的坏样例用的就是尾随闭包写法，元测试当场把它打红——
    ///   规则过窄这件事是被 `testScannerFiresOnBadSamples` 抓出来的。）
    ///   → 归 **M1 / WS-P 与 WS-W**（body 内派生集合缓存），终点 0。
    /// - `syncFileIO` **2** —— `Logs/LogsView.swift` 的 `fileExists(atPath:)` 与
    ///   `attributesOfItem(atPath:)` 各 1 处（经 `attachedItems` → `fileSize(of:)` 两跳进渲染路径）。
    ///   → 归 **M1 / WS-W**（spec §5 点名"LogsView.attachedItems 的 body 内 stat() 移出"），终点 0。
    static let knownBaseline: [String: Int] = [
        "directFormatters": 1,
        "dynamicNSColor": 64,   // 56→**64 是扩面，不是新增债**：判据写的是"body/Mark 内"，
        // 而 `Design/**`（`GlassComponents`/`ChartTokens`/`HealthAdviceCards` 等）本身就是视图构造器，
        // 旧扫描面只看 `Views/`。多看见的 8 处全部落在 Design/（台账现在带 `Design/` 前缀可逐条复核）。
        // 从 64 起仍只许减不许增；终点 0。历史上这条是 107→86→59→58→56（三次还债）→64（一次扩面）。
        // 为什么又拧：台账"现量/上限"一上线就自己报出 `58/59（可拧到 58）`——
        // 留 1 处余量等于"新增 1 处照样绿"。**只减不增要成立，降下来必须有人拧**。
        // 没点名是哪一笔还掉的：这条不需要知道，扫描器每次跑都会重算。
        "fullSort": 10,
        "syncFileIO": 2,
    ]

    /// 每条规则的负责人 / 里程碑，只在报错时打出来，避免"基线是遮羞布"。
    static let ownerNotes: [String: String] = [
        "directFormatters": "M1 WS-W：DateFormatter/NumberFormatter 提 static let（终点 0）",
        "dynamicNSColor": "语义已变（C 包落地后）：令牌由「每次访问现造」改成缓存之后，本条量的不再是分配次数，"
            + "而是**渲染路径里引用令牌成员的次数**——它仍是重算面的代理指标（引用越多＝每 tick 求值越密），"
            + "但不再等于「每 tick new 多少个 NSColor」。落地前 88（只认 .textColor），"
            + "放宽到四成员后实测 107（+19 处 .graphicColor，全在图表 Mark/循环里）。终点仍由 M1 各流按页面收敛。"
            + "**2026-09-20 拧到 86**：`165faa7`（M1-集成，图表取色上提进 Design/）还掉了 21 处 Views 侧引用，"
            + "**2026-09-21 再拧到 59**：`c60abbd`（观感·批次 ABC 颜色面积收敛）又还掉 27 处。"
            + "两次都是同一条『现量/上限』打印＋$TMPDIR 台账抓出来的——不打印就没人知道基线在漏。"
            + "而这条棘轮当时不报现量、没人看得见那 21 处余量——现在它每次跑都打「现量/上限」。",
        "fullSort": "M1 WS-P/WS-W：body 内派生集合缓存或移到 publish 里算（终点 0）",
        "syncFileIO": "M1 WS-W：渲染路径的文件尺寸/存在性检查移到扫描期（终点 0）",
    ]

    // MARK: - 棘轮主体

    func testRenderPathViolationsDoNotGrowBeyondBaseline() throws {
        let scan = try Self.scanRenderSurface()
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
        Self.recordRenderPathReadout(counts: counts, scan: scan)
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }

    /// 【每次跑都报现量】"只减不增"有两个方向的失效：涨上去必须红（由调用方管），
    /// 而**降下来却没人拧基线**同样坏——余量 60 处的闸门等于没有闸门，
    /// 新债可以悄悄长回来还不红。这里不判红（清零是合法终态），
    /// 但把"现量/上限"打进输出、并**再落一份文件**，让余量在日志里可被机器读：
    /// `swift test` 会丢子进程 stdout 的后半段（本仓记过，2026-09-20 的 premerge 日志里
    /// 就没有这行 print），只靠 print 的话，拧基线的人（包括下一次的我）拿不到余量。
    /// 台账里要**点得到名字**：只有 `fullSort 10/10` 一行的话，还债的人还得自己
    /// 把守卫触发成红才知道现场在哪，所以明细逐条带"文件:行 + 原文"。
    static func recordRenderPathReadout(counts: [String: Int], scan: PerfHitchScan.ScanResult) {
        let debt = knownBaseline.keys.sorted().map { rule -> String in
            let baseline = knownBaseline[rule] ?? 0
            let now = counts[rule] ?? -1
            return now < baseline ? "\(rule) \(now)/\(baseline)（可拧到 \(now)）" : "\(rule) \(now)/\(baseline)"
        }.joined(separator: "  ")
        print("【渲染路径禁则】现量/上限 —— \(debt)")
        let ledger = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tcoder-perf-renderpath-debt.txt")
        var detail: [String] = ["HEAD=\(Date()) \(debt)"]
        for rule in knownBaseline.keys.sorted() {
            let hits = scan.hits[rule, default: []]
            detail.append("—— \(rule)：\(hits.count) 处")
            detail.append(contentsOf: hits.sorted().map { "   \($0)" })
        }
        try? (detail.joined(separator: "\n") + "\n").write(to: ledger, atomically: true, encoding: .utf8)
    }

    /// 存量必须**可点名**：守卫报出来的每一条都要有"文件:行 + 原文"，
    /// 否则没人能修。这条同时兜住"计数对了但位置丢了"的半瞎实现。
    func testEveryRecordedHitCarriesFileLineAndSnippet() throws {
        let scan = try Self.scanRenderSurface()
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
        let scan = try Self.scanRenderSurface()
        let io = scan.hits["syncFileIO"] ?? []
        XCTAssertTrue(io.contains { $0.hasPrefix("Views/Logs/LogsView.swift") && $0.contains("attributesOfItem(") },
                      "LogsView 的 attributesOfItem 是已知存量，扫不到就说明 I/O 正则或跨度展开坏了：\(io)")
        // 命中一律带根前缀（`Views/…` / `Design/…`）：两棵根并起来之后，
        // 没有前缀就会出现两个同名文件分不清谁是谁。
        XCTAssertTrue(io.allSatisfy { $0.hasPrefix("Views/") || $0.hasPrefix("Design/") },
                      "命中路径没带根前缀，两棵根的存量会互相顶名：\(io)")
        let sorts = scan.hits["fullSort"] ?? []
        XCTAssertTrue(sorts.contains { $0.contains(".sorted(") },
                      "Views 里已知有 body 内排序，扫不到说明 .sorted( 正则失效：\(sorts)")
        let colors = scan.hits["dynamicNSColor"] ?? []
        XCTAssertTrue(colors.count >= 50, ".textColor 存量应有几十处，只数到 \(colors.count) 处：跨度提取退化了")
        XCTAssertTrue(colors.contains { $0.hasPrefix("Design/") },
                      "Design/ 侧的令牌引用一条都没数到——扫描面又退回只看 Views/ 了")
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

}

// MARK: - 扫描器（纯 Foundation，可被 /tmp 下的独立复核程序原样编进去）
