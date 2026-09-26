import Foundation
import XCTest
@testable import TcoderMonitor

/// OWNER: R 尺子包（性能 spec §4.3、AGENTS.md 第四轮红线 6）。
///
/// T5「主线程禁则」的静态守卫：渲染路径（`Views/**` ∪ `Design/**`）里不许出现
/// ① 每次访问现造的对象（`NSColor(name:` / `Color(nsColor:` / `DateFormatter(` / `NumberFormatter(`）、
/// ② 全量排序 `.sorted(`、③ 同步文件 I/O。
///
/// 【2026-09-22 撤掉一句假话】①以前还写着"以及间接形状 `.textColor`——令牌未缓存时它每次访问
/// 都 new 一个 `NSColor`"。那个前提**在 M0-d′ 令牌缓存落地后就不成立了**：现在 `.textColor`
/// 读的是 init 里算好的 `let`，一次分配都没有。继续把它算成禁则，会得到两个方向的失效：
/// 新写一处**正确**的取色被打红，而真正该拦的 `Color(nsColor:` 因为不在模式里而**一条都不红**。
/// ⇒ 拆成两条各管一件事：`dynamicColorConstruction`（现造＝债，终点 0）与
/// `tokenReference`（引用＝读数，终点不是 0，只许减不许增但不许当还债报数）。
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
    /// `waiving` 默认用名单；**守恒那条元测试会传 `[]` 再扫一遍**——
    /// 传空就是"没有豁免时应该数到几"的那一侧，两次的和必须逐规则相等。
    static func scanRenderSurface(
        waiving exemptions: [PerfHitchScan.Exemption] = PerfHitchGuardTests.eventPathExemptions
    ) throws -> PerfHitchScan.ScanResult {
        var merged = try PerfHitchScan.scanDirectory(viewsRoot, helperHopDepth: helperHopDepth,
                                                     exempt: exemptions)
        let design = try PerfHitchScan.scanDirectory(designRoot, helperHopDepth: helperHopDepth,
                                                     exempt: exemptions)
        XCTAssertGreaterThanOrEqual(design.census.swiftFiles, 10,
                                    "Design/ 只扫到 \(design.census.swiftFiles) 个文件：这棵根失效了，合并读数会假绿")
        // 两棵根的命中路径都是**相对各自根**的，直接并起来会出现两个 `ChartTokens.swift:185`
        // 分不清谁是谁——而"每条存量必须可点名"是这条守卫存在的理由之一。
        for (rule, n) in design.counts {
            merged.counts[rule, default: 0] += n
            merged.hits[rule, default: []] += (design.hits[rule] ?? []).map { "Design/\($0)" }
            // 豁免那一栏同样要带根前缀：否则"哪个文件被免了"在两棵根之间分不清，
            // 而死条目检查恰恰是按文件路径去读源码的（#72 的口子必须由名单自己管住）。
            merged.exempted[rule, default: []] += (design.exempted[rule] ?? []).map { "Design/\($0)" }
        }
        for rule in merged.hits.keys where merged.hits[rule] != nil {
            merged.hits[rule] = merged.hits[rule]?.map { $0.hasPrefix("Design/") ? $0 : "Views/\($0)" }
        }
        // 豁免栏同样补根前缀——**名单里写的 `file` 是"相对各自根"的路径**（匹配发生在扫描器内部），
        // 而台账与死条目检查看到的是带前缀的路径。这两种写法差一层前缀，
        // 不写出来下一次一定有人改错（#72 的口子只能由名单自己管住）。
        for rule in merged.exempted.keys {
            merged.exempted[rule] = merged.exempted[rule]?.map {
                $0.hasPrefix("Design/") ? $0 : "Views/\($0)"
            }
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
    /// - `dynamicNSColor` **88**（现名 `tokenReference`）—— 渲染路径内 `.textColor` 88 处（Views 全目录 91 处，
    ///   差额 3 处在非渲染路径）。注意任务书里提到的"115 处"是**更早一次全 Sources 口径**的数，
    ///   本守卫只认 `Views/**` 渲染路径口径，两边不可混比。
    ///   → 归 **M0 / C 令牌缓存包（总工）**：`ColorToken.swift` 改成缓存后，
    ///     这一条的语义从"每次访问 new NSColor"降级为"引用一个缓存值"，
    ///     届时要由总工把它从禁则表里摘掉或重定基线——**在 C 包落地前它必须 ≤ 88**。
    /// - `fullSort` **8**（2026-09-21 20:40 从 10 拧到 9；2026-09-26 21:40 从 9 拧到 8，见 §170）—— 2026-09-20 17:00 由总工
    ///   **复量校正**（原记 2 是错的）。
    ///   原值 2 是用只认 `.sorted(` 的正则量出来的，而仓库里真实写法以**尾随闭包**
    ///   `.sorted { … }` 为主，于是 8 处漏计（实测清单见 `testRenderPathViolationsDoNotGrowBeyondBaseline`
    ///   的报错体）。这正是本仓反复记的失效模式：**正则过窄 → 分母虚低 → 守卫看着有牙其实是假绿**。
    ///   现在的规则同时认 `.sorted(` 与 `.sorted {`，基线按**今天的真值**重新钉成 10，目标仍是 0。
    ///   （同一次校正里 `fullSort` 的坏样例用的就是尾随闭包写法，元测试当场把它打红——
    ///   规则过窄这件事是被 `testScannerFiresOnBadSamples` 抓出来的。）
    ///   → 归 **M1 / WS-P 与 WS-W**（body 内派生集合缓存），终点 0。
    /// - `syncFileIO` **1 债 + 1 具名豁免** —— `Logs/LogsView.swift` 里两处：
    ///   `attributesOfItem`（经 body 读的计算属性 `attachedItems` → `fileSize(of:)`，**每帧 stat()**）
    ///   是真债，归 **M1 / WS-W**（spec §5 点名"attachedItems 的 body 内 stat() 移出"），终点 0；
    ///   `fileExists`（在 `chooseLogFiles` 里、紧接着 `panel.runModal()`）是**一次点击一次**的事件路径，
    ///   不是每帧求值 ⇒ 记成 `eventPathExemptions` 的逐点豁免，不记成债（#72）。
    static let knownBaseline: [String: Int] = [
        "directFormatters": 1,
        // 【2026-09-22 新增，不是新债】渲染路径里**现造**动态色的地方。
        // 这条才是目标里"body/Mark 内零动态色"那句话的字面判据；过去它根本没有尺子——
        // `directFormatters` 只列 `NSColor|DateFormatter|NumberFormatter` 后跟 `(`，
        // 于是 `Color(nsColor: …)` 这种写法一条都不抓（现扫才看见 2 处，全在 `Views/Shell/`）。
        // 上限 = 2026-09-22 现扫真值，**零余量**；终点 0，归 UI 流（改的是 `Views/**`）。
        "dynamicColorConstruction": 2,
        // ⚠ `tokenReference` **不在这张表里**（2026-09-25 #68）。它待在下面的循环里
        // 就等于被套上零余量上限，于是"新写一处正确的令牌取色"会红——而 #19 那两笔要做的
        // 正是那个方向。它现在住 `PerfHitchGuardTests+Readings.swift`：读数只有**下限**。
        // 为什么这条线要**零余量**：台账"现量/上限"一上线就自己报出过 `58/59（可拧到 58）`——
        // 留 1 处余量等于"新增 1 处照样绿"。方向只有这一个：棘轮**只许变紧**。
        // 留隐形余量的话，下一个人在别处新加一处排序就会显示成 10/10「没涨」，
        // 那正是"每次打现量"这条规矩要防的事（2026-09-21 20:39 台账报 `fullSort 9/10` ⇒ 拧到 9）。
        // 2026-09-26 21:40（台账卷十 §170）：守卫自己报出 `fullSort 8/9（可拧到 8）` ⇒ 按同一条规矩拧到 8。
        // 8 处逐点名单由本守卫落盘（`.scratch/tcoder-perf-renderpath-debt.txt`，每次跑覆写；
        // 拧之前那份快照存的是 HEAD=`2026-09-26T08:52:51Z` 那一次）。终点仍是 0，归 M1 WS-P／WS-W。
        "fullSort": 8,
        // 2026-09-25 #72：`LogsView.chooseLogFiles` 那一格是**一次点击一次、且当场弹模态面板**，
        // 不是每帧求值 ⇒ 从"债"改记成"具名逐点豁免"（`eventPathExemptions`），这里只留真债那一格。
        // ⚠ 台账必须打成 `1 债 + 1 具名豁免`，不许合并成 1 —— 否则"少报一处"与"还掉一处债"同形。
        "syncFileIO": 1,
        // 2026-09-27（#97）：prefs 家族（`UserDefaults`／`CFPreferences`／`PropertyListSerialization`）
        // 从此进词表。上限 = 现量 **0**——三族在 `Sources/**` 各 0 处（18:38 现读），
        // 而 §177 那批 time-profile 也独立给出同一句真话：首帧后 1.12 s 里的 prefs 读
        // 栈根全是 `start`（AppKit 首用同步初始化），**不是**我们自己写的。
        // ⇒ 这条不是"还掉的债"，是"以前看不见"；新增一处即红，零余量。
        "syncPrefs": 0,
    ]


    // 负责人名单（`ownerNotes`）2026-09-27 整块搬进 `PerfHitchGuardTests+Owners.swift`。
    // 为什么搬：#97 那条 prefs 规则的说明一写进来，宿主就过 400 行门（实测 401）。
    // 本仓对这把门只有一句口径：**拆，不抬线**（`FileSystemCodeAnalyzer.mediumFileLines` 是产品侧同一把尺）。

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
        // 【债表 ∪ 读数表 必须等于规则名】`counts[rule] ?? -1` 有个静默失效形状：
        // 表里写了一个**不存在**的规则名（改名时最容易发生），取不到计数就退化成 -1，
        // 而 -1 永远不"超过"上限 ⇒ 那条规则**从闸门上消失**，日志里一个字都不会多。
        // 2026-09-22 改名那次就补了这条等式；2026-09-25 #68 把它从"基线键"改成"两键并集"，
        // 因为 `tokenReference` 已经从债表搬进读数表——只查一张表就会漏掉另一张。
        XCTAssertEqual(Self.ruleNamesCovered, Set(PerfHitchScan.rules.map(\.name)),
                       "债表加读数表与规则名不再一一对应：多出来的键会被当成 -1 处而恒绿，"
                       + "少掉的名字则完全没人管")
        XCTAssertEqual(Set(Self.ownerNotes.keys), Set(PerfHitchScan.rules.map(\.name)),
                       "有规则没写负责人，或负责人讲了一条不存在的规则")
        // 判定**只此一处入口**（`ratchetProblems`）：元测试和被跑的那条走同一段代码，
        // 否则会出现"测试绿着而闸门是另一套逻辑"——本仓为"同一判据两处入口"记过账。
        problems += Self.ratchetProblems(counts: counts, hits: scan.hits)
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
        // 一行字符串同时喂 stdout 与台账文件：**两个地方两个数**是本仓记过的那族缺陷。
        let summary = readoutSummary(counts: counts)
        // 具名豁免必须跟着印出来并点名：只印"1"就把"少报一处"演成"还掉一处债"。
        let waived = scan.exempted.values.reduce(0) { $0 + $1.count }
        let waiverText = waived == 0 ? "" : "　具名豁免 \(waived) 处（逐点：\(scan.exempted.values.flatMap { $0 }.sorted().joined(separator: "、"))）"
        print("【渲染路径禁则】\(summary)\(waiverText)")
        // 台账**不写在 $TMPDIR**：那个目录 2026-09-21 被清过一次，对照组的封存产物就是这么
        // 丢的；而"拧基线前要拿现量、还债人要拿明细"依赖的正是这份文件——
        // 放在会被系统随手清掉的地方，等于一份只在今天可用的台账。
        // 仓库根的求法与本仓其他文档级守卫一致（本文件 → TcoderMonitorTests → Tests → TcoderMonitor → 树根）。
        let scratch = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".scratch")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let ledger = scratch.appendingPathComponent("tcoder-perf-renderpath-debt.txt")
        var detail: [String] = ["HEAD=\(Date()) \(summary)\(waiverText)"]
        // 债与读数**都要留明细**：读数掉破下限时，人要能一眼看出"是引用真少了，还是模式没打中"，
        // 那需要的是同一批命中位置，而不是再来一遍扫描。
        for rule in (Array(knownBaseline.keys) + Array(readings.keys)).sorted() {
            let hits = scan.hits[rule, default: []]
            detail.append("—— \(rule)：\(hits.count) 处")
            detail.append(contentsOf: hits.sorted().map { "   \($0)" })
        }
        let body = detail.joined(separator: "\n") + "\n"
        // 不用 `try?`：写不进去的台账 == 没有台账，而它在链条里是"拧基线/还债"的唯一机器可读依据。
        do { try body.write(to: ledger, atomically: true, encoding: .utf8) }
        catch { XCTFail("渲染路径台账写不出去（\(ledger.path)）：\(error)。"
                            + "宁可红，也不要一份悄悄消失的余量记录。") }
        XCTAssertEqual(try? String(contentsOf: ledger, encoding: .utf8), body,
                       "台账写完读回来的不是同一份内容（原子替换没生效？那读余量就是在读上一次的）")
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
        let colors = scan.hits["tokenReference"] ?? []
        XCTAssertTrue(colors.count >= 50, ".textColor 存量应有几十处，只数到 \(colors.count) 处：跨度提取退化了")
        XCTAssertTrue(colors.contains { $0.hasPrefix("Design/") },
                      "Design/ 侧的令牌引用一条都没数到——扫描面又退回只看 Views/ 了")
        // 【新增尺子必须已经咬到真东西】这条的存在理由：`dynamicColorConstruction` 是 2026-09-22
        // 才补的，补之前 `Color(nsColor:` 在渲染路径里**一条都不抓**。钉住现在已知的两处真实构造点，
        // 万一有人把模式改窄（比如只留 `NSColor(name:`），这里当场红，而不是静默降到 0。
        let built = scan.hits["dynamicColorConstruction"] ?? []
        XCTAssertEqual(built.count, 2, "现造动态色的构造点应正好 2 处（变了要同步改上限并写明原因）：\(built)")
        for name in ["Views/Shell/SidebarRows.swift", "Views/Shell/ProjectSidebar.swift"] {
            XCTAssertTrue(built.contains { $0.hasPrefix(name) },
                          "已知的构造点 \(name) 扫不到了——模式退化：\(built)")
        }
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
                let flag = UserDefaults.standard.bool(forKey: "showSplash")
                let prefs = CFPreferencesCopyAppValue("key" as CFString, app as CFString)
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
        XCTAssertEqual(counts["tokenReference"] ?? 0, 0, ".ink 是常量，.textColor 才是令牌引用形状")
        // 反向钉（拆尺子的理由就在这一条）：**引用**缓存令牌不是**构造**动态色。
        // 如果 `dynamicColorConstruction` 的模式宽到把 `.textColor` 也算进去，
        // 它会立刻长出 62 处"新债"，把闸门变成"禁止给东西着色"。
        XCTAssertEqual(counts["dynamicColorConstruction"] ?? 0, 0,
                       "令牌引用被误判成现造动态色——这条尺子开始惩罚正确写法了")
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
