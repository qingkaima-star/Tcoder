import Foundation
import Observation
import XCTest
@testable import TcoderMonitor

/// P 心跳链路包名下的**粗 API 只减不增棘轮** + 细粒度失效面的行为守卫。
///
/// 【这条尺子量的是什么】xctrace 在产物 `465f5a6` 上量到 1.5 秒一次心跳引起
/// app-update 10.8~24.8 ms（预算 8.33 ms）、主线程 64.3% 样本落在
/// `AG::Graph::UpdateStack::update()`。病因是一次 publish 写 9~10 个 `@Observable`
/// 属性、外加`processesByMemory` 这类**每次访问现算全量排序**的计算属性，
/// 把总览页、侧栏、性能页整棵 body 拖进每 tick 重算。
///
/// P 包已经把采集侧改完（细粒度格、派生缓存在后台算一次），但**页面不许我碰**
/// （`Views/**` 归三家）。所以这里钉一条只减不增的棘轮，防止"新旧两套口径并存"——
/// 本仓教训：两套口径并存时，错的那套常在喂数据。基线取本文件写作时实测的调用点数，
/// 目标 0 由三家在 M1 清零；谁新增一处粗粒度读点，这里就红。
///
/// 【「完成」由 §3 的 `consumptionGateOpen` 定义】只减不增挡不住「原地踏步还宣布达标」：
/// 16 处一处不迁，那两条断言照样绿。所以达标与否看闸门，不看棘轮。
///
/// 【元测试】扫描型守卫最坏的失效不是报错而是**正则写坏 → 永远 0 命中还常绿**。
/// 所以每条扫描都配一个故意造的坏样例（必须被看见）与一个合规样例（不得被误伤），
/// 并要求分母（扫到的文件数 / 行数）足够大，"没扫到东西"一律判失败。
final class PerfInvalidationRatchetTests: XCTestCase {

    // MARK: - 路径口径

    /// `.../TcoderMonitor/Tests/TcoderMonitorTests/本文件` → 上溯三级 = `TcoderMonitor/`
    private static let moduleRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // TcoderMonitorTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // TcoderMonitor

    /// 粗粒度读点只算**消费方**：页面 + 编排器。服务内部（采集侧自己写这些属性）不算。
    private static let consumerDirectories = ["Sources/TcoderMonitor/Views", "Sources/TcoderMonitor/App"]
    private static let serviceDirectory = "Sources/TcoderMonitor/Services/Performance"

    // MARK: - 口径（唯一一处定义，扫描与元测试共用）

    /// 旧粗粒度入口：整 `SystemSnapshot`、整条 `history`、整张榜单。
    /// 读它们 = 每次心跳都要重算读它的那棵 body。
    static let coarsePattern = #"monitor\s*\.\s*(latestSnapshot|history|topProcesses|trackedGroups|allProcesses|processesByMemory|measuredProcessCount|processMetricsTruncated|lastSampleAt)\b"#

    /// 新细粒度入口（P 包给三家的契约）。这里只用来证明"合规写法不会误伤"。
    static let finePattern = #"monitor\s*\.\s*(cpu|memory|rates|ledger|pulse|cpuRanking|memoryRanking|groupRanking|curve|isCollectingForDisplay)\s*\.\s*value\b"#

    /// **迁移期的专属失效**：采集侧已经把窗口切好、把榜单排好，页面拿到之后**又再切一次 / 再排一次**。
    /// 这种写法编译通过、画面也对，收益却原地消失（每 tick 仍然在 body 里做 O(n log n)），
    /// 而且不会被粗 API 棘轮抓到——因为它读的就是细格。所以单独一条，**基线 0，一处都不许有**。
    static let reslicePattern = #"\.(curve|cpuRanking|memoryRanking|groupRanking)\s*\.\s*value\s*\.\s*(sorted|suffix|prefix|dropFirst|dropLast|reversed|filter|shuffled)\b"#

    /// 回归守卫：采集侧不许再把这些退回去。
    /// 1) `processesByMemory` 不许再是计算属性（每次访问全量排序）；
    /// 2) `allProcesses` 必须留在观察图外；
    /// 3) 一 tick 不许再无条件写历史数组以外的粗属性（用等值闸门 `publishValue` / `write`）。
    static let computedMemoryRankingPattern = #"var\s+processesByMemory\s*:\s*\[ProcessSnapshot\]\s*\{"#
    static let unguardedAllProcessesPattern = #"(^|\n)\s*(private\(set\) )?var allProcesses\b"#

    // MARK: - 基线（本文件写作时实测；只减不增）

    /// 实测：`Views/**` + `App/**` 里共 16 处粗粒度读点。
    /// 迁移清单见 P 包报告；**目标 0**，清零后由总工把这个数往下拧。
    static let coarseCallSiteCeiling = 16

    /// 分母闸：扫不到足够文件与行数，任何「0 违规」都是假的。
    private static let minimumConsumerFiles = 20
    private static let minimumConsumerLines = 3_000

    // MARK: - 扫描器（纯函数：真文件与合成夹具走的是同一份代码）

    private struct Line { var number: Int; var text: String }
    private struct Doc { var file: String; var lines: [Line] }

    /// 整行注释（含 `///` 文档注释）豁免——说明文里必须提到被禁的写法本身。
    private static func codeLines(of text: String) -> [Line] {
        text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            .map { Line(number: $0.offset + 1, text: String($0.element)) }
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    /// 返回 `文件:行号 命中行` 的清单。喂合成字符串与喂真仓库走的是同一个函数。
    /// 行号按**原文**报（注释行只是不参与匹配），否则报错信息会把人带到别的行上去。
    private static func scanHits(pattern: String, in docs: [Doc]) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern, options: [])
        var hits: [String] = []
        for doc in docs {
            for line in doc.lines {
                let range = NSRange(line.text.startIndex..., in: line.text)
                // 一行里可能并排两处读点，按**调用点**计数而不是按行数。
                for match in regex.matches(in: line.text, options: [], range: range) {
                    let matched = Range(match.range, in: line.text).flatMap { String(line.text[$0]) } ?? line.text
                    hits.append("\(doc.file):\(line.number) \(matched.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        return hits
    }

    /// 合成一段文本当作夹具（行号从 1 起，与真文件同形状）。
    private static func syntheticDoc(_ file: String, _ text: String) -> Doc {
        Doc(file: file, lines: codeLines(of: text))
    }

    private static func documents(under directory: String) throws -> [Doc] {
        let root = moduleRoot.appendingPathComponent(directory)
        var collected: [Doc] = []
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            collected.append(Doc(file: url.path.replacingOccurrences(of: moduleRoot.path + "/", with: ""),
                                 lines: codeLines(of: text)))
        }
        return collected.sorted { $0.file < $1.file }
    }

    private func scannedConsumerDocs() throws -> [Doc] {
        var docs: [Doc] = []
        for directory in Self.consumerDirectories { docs.append(contentsOf: try Self.documents(under: directory)) }
        return docs
    }

    private func scannedServiceDocs() throws -> [Doc] {
        try Self.documents(under: Self.serviceDirectory)
    }

    // MARK: - 1. 粗 API 只减不增

    func testCoarseReadoutCallSitesDoNotIncrease() throws {
        let docs = try scannedConsumerDocs()
        let lines = docs.reduce(0) { $0 + $1.lines.count }
        XCTAssertGreaterThanOrEqual(docs.count, Self.minimumConsumerFiles,
                                    "只扫到 \(docs.count) 个消费方文件，路径口径坏了——下面那条上限断言就是永真绿")
        XCTAssertGreaterThanOrEqual(lines, Self.minimumConsumerLines,
                                    "只扫到 \(lines) 行，分母太小，0 命中不代表干净")

        let hits = try Self.scanHits(pattern: Self.coarsePattern, in: docs)
        XCTAssertLessThanOrEqual(hits.count, Self.coarseCallSiteCeiling,
                                 """
                                 粗粒度读点从基线 \(Self.coarseCallSiteCeiling) 处涨到 \(hits.count) 处。
                                 每多一处，就多一棵 body 跟着 1.5 秒一次心跳整棵重算
                                 （实测 app-update 10.8~24.8 ms / 预算 8.33 ms）。
                                 改读细粒度格：`monitor.cpu.value` / `.memory.value` / `.rates.value` /
                                 `.ledger.value` / `.pulse.value` / `.cpuRanking.value` /
                                 `.memoryRanking.value` / `.groupRanking.value` / `.curve.value`。
                                 清单：
                                 \(hits.joined(separator: "\n"))
                                 """)
        print("【粗 API 棘轮】消费方文件 \(docs.count) 个 / \(lines) 行，粗粒度读点 \(hits.count) 处"
            + "（上限 \(Self.coarseCallSiteCeiling)，目标 0），细粒度读点 "
            + "\(try Self.scanHits(pattern: Self.finePattern, in: docs).count) 处")
        // 同一行数落一份文件：`swift test` 会丢子进程 stdout 的后半段，
        // 只靠 print 的话"还剩几处"就进不了机器（迁移验收要的正是这个数）。
        let fineCount = try Self.scanHits(pattern: Self.finePattern, in: docs).count
        let ledger = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tcoder-perf-migration-debt.txt")
        let ledgerText = "coarse=\(hits.count) ceiling=\(Self.coarseCallSiteCeiling) "
            + "fine=\(fineCount) files=\(docs.count) lines=\(lines)\n"
        try? ledgerText.write(to: ledger, atomically: true, encoding: .utf8)
    }

    /// 基线本身不许是"假零"：只要上限还大于 0，今天就必须真扫得到东西。
    /// （上限拧成 0 之后这条自动让路，不会因为"债还上了"而反过来判红。）
    func testCoarseBaselineIsNotAFakeZero() throws {
        let hits = try Self.scanHits(pattern: Self.coarsePattern, in: try scannedConsumerDocs())
        if Self.coarseCallSiteCeiling > 0 {
            XCTAssertGreaterThan(hits.count, 0,
                                 "上限登记为 \(Self.coarseCallSiteCeiling) 处却扫到 0 处：要么正则坏了（永真绿），"
                                     + "要么三家已清零——那就该由总工把上限拧成 0，而不是让这条测试假绿。")
        }
        XCTAssertLessThanOrEqual(hits.count, Self.coarseCallSiteCeiling)
        print("【粗 API 棘轮】现量 \(hits.count) 处 / 上限 \(Self.coarseCallSiteCeiling) 处 / 距目标 0 还差 \(hits.count) 处")
    }

    // MARK: - 2. 元测试：证明上面那把尺子抓得住坏样例

    private static let migratedSamples = [
        "Text(Live.percent(monitor.cpu.value.usage))",
        "PerformanceLiveCharts(points: monitor.curve.value, context: context)",
        "ForEach(monitor.memoryRanking.value) { row in ProcessRow(process: row) }",
        "Theme.Readout.Field(\"采样点\", NumberFormat.grouped(monitor.pulse.value.historyCount))",
    ]

    private static let dirtySamples: [(name: String, sample: String, pattern: String)] = [
        ("整帧快照又回来了", "private var snapshot: SystemSnapshot? { state.monitor.latestSnapshot }", coarsePattern),
        ("body 里现切曲线窗口", "CPUHistoryChart(snapshots: Array(state.monitor.history.suffix(90)))", coarsePattern),
        ("按内存榜每次访问现排", "let top = monitor.processesByMemory", coarsePattern),
        ("把全量进程数组留在观察图里", "private(set) var allProcesses: [ProcessSnapshot] = []", unguardedAllProcessesPattern),
        ("内存榜退回计算属性", "var processesByMemory: [ProcessSnapshot] { allProcesses.sorted { $0.memoryBytes > $1.memoryBytes } }",
         computedMemoryRankingPattern),
    ]

    func testCoarseScannerCatchesSyntheticBadCallSites() throws {
        for dirty in Self.dirtySamples {
            let hits = try Self.scanHits(pattern: dirty.pattern, in: [Self.syntheticDoc("合成夹具", dirty.sample)])
            XCTAssertFalse(hits.isEmpty, "规则「\(dirty.name)」命中不了坏样例，说明它已经废了：\(dirty.pattern)")
        }
    }

    /// 反向：合规写法不得被误伤，否则这条棘轮会变成"谁迁完谁红"。
    func testCoarseScannerDoesNotFireOnMigratedReadouts() throws {
        let docs = [Self.syntheticDoc("合成夹具", Self.migratedSamples.joined(separator: "\n"))]
        let coarse = try Self.scanHits(pattern: Self.coarsePattern, in: docs)
        XCTAssertTrue(coarse.isEmpty, "细粒度写法被粗粒度正则误伤了：\n\(coarse.joined(separator: "\n"))")
        let fine = try Self.scanHits(pattern: Self.finePattern, in: docs)
        XCTAssertEqual(fine.count, Self.migratedSamples.count,
                       "细粒度正则本该认出全部 \(Self.migratedSamples.count) 条合规写法，实得 \(fine.count) 条")
    }

    // MARK: - 3. 「完成」的机器定义：细粒度消费闸门

    /// **M1 迁移闸门**。16 处粗粒度读点全部迁完、并且把 `coarseCallSiteCeiling` 一起拧成 0
    /// 之后，由总工翻成 `true`。
    ///
    /// 【为什么非要有这条】这轮的收益全部长在**消费侧**：采集侧改成细粒度格只是必要条件，
    /// 页面继续读 `monitor.latestSnapshot` 的话，每 tick 重算的还是那几整棵 body。
    /// 实测细粒度读点 = 0 处，也就是这轮在页面上**一点都没落地**。
    /// 而现有断言全是"只减不增"——16 处原封不动也能常绿，我随时可以在这个状态下宣布
    /// "120Hz 达标"。闸门把"完成"写死成机器可判的四态，见 `ConsumptionState`。
    ///
    /// 与 `BorderlessSurfaceGuardTests.m2WiringComplete` 同一套路子：测试在场、
    /// 当前不拦路、但**除了真完成之外没有一个状态可以静默绿**。
    private static let consumptionGateOpen = false

    enum ConsumptionState: Equatable {
        /// 债还在（粗读点或上限任一未归零）。今天真状态。
        case debtOutstanding(coarse: Int, ceiling: Int)
        /// 债清完了却没人翻闸门——本文件该被撤除，不能一直挂着当"永远欠着"。
        case debtRepaidButGateShut(fine: Int)
        /// 唯一的"完成"。
        case done(fine: Int)
        /// 提前翻闸门：拿一个还没落地的状态去报成功。
        case openedTooEarly(coarse: Int, ceiling: Int, fine: Int)
    }

    /// 状态机本身是纯函数：元测试用合成数字直接验它，不必改动真仓库就能证明它不是摆设。
    static func consumptionState(coarse: Int, fine: Int, ceiling: Int, gateOpen: Bool) -> ConsumptionState {
        if gateOpen {
            return ceiling == 0 && coarse == 0 && fine > 0
                ? .done(fine: fine)
                : .openedTooEarly(coarse: coarse, ceiling: ceiling, fine: fine)
        }
        if coarse > 0 || ceiling > 0 { return .debtOutstanding(coarse: coarse, ceiling: ceiling) }
        return .debtRepaidButGateShut(fine: fine)
    }

    func testConsumptionGateIsHonestAboutItsState() throws {
        let docs = try scannedConsumerDocs()
        let coarse = try Self.scanHits(pattern: Self.coarsePattern, in: docs).count
        let fine = try Self.scanHits(pattern: Self.finePattern, in: docs).count
        let state = Self.consumptionState(coarse: coarse, fine: fine,
                                          ceiling: Self.coarseCallSiteCeiling,
                                          gateOpen: Self.consumptionGateOpen)
        switch state {
        case .debtOutstanding(let c, let ceiling):
            print("【消费闸门】关。粗读点 \(c) 处 / 上限 \(ceiling) 处 / 细读点 \(fine) 处"
                + " —— 这轮的收益还没在页面上落地，任何「T1/T2 达标」的结论都不成立。")
        case .debtRepaidButGateShut(let fine):
            XCTFail("粗读点与上限都已归零（细读点 \(fine) 处），闸门却还关着："
                  + "由总工把 consumptionGateOpen 翻成 true，或干脆撤除本文件，别让它长期挂着。")
        case .openedTooEarly(let c, let ceiling, let fine):
            XCTFail("闸门被翻成 true，但消费侧没完成：粗读点 \(c) 处 / 上限 \(ceiling) 处 / 细读点 \(fine) 处。"
                  + "这正是「拿没落地的状态报 120Hz 达标」的形状。")
        case .done(let fine):
            print("【消费闸门】开。粗读点 0 处，细读点 \(fine) 处 —— 可以按帧率复测判 T1/T2。")
        }
    }

    func testConsumptionGateCatchesSyntheticStates() {
        let cases: [(name: String, coarse: Int, fine: Int, ceiling: Int, open: Bool,
                     expect: ConsumptionState)] = [
            ("今天的真状态：16 处粗读、0 处细读、闸门关", 16, 0, 16, false, .debtOutstanding(coarse: 16, ceiling: 16)),
            ("粗读清了但上限没拧（回归还能藏进去）", 0, 12, 16, false, .debtOutstanding(coarse: 0, ceiling: 16)),
            ("债清完却忘了翻闸门", 0, 12, 0, false, .debtRepaidButGateShut(fine: 12)),
            ("提前翻闸门：还有粗读点", 3, 12, 0, true, .openedTooEarly(coarse: 3, ceiling: 0, fine: 12)),
            ("提前翻闸门：细读点为 0（迁了但没人读，或正则坏了）", 0, 0, 0, true,
             .openedTooEarly(coarse: 0, ceiling: 0, fine: 0)),
            ("真完成", 0, 12, 0, true, .done(fine: 12)),
        ]
        for item in cases {
            let got = Self.consumptionState(coarse: item.coarse, fine: item.fine,
                                            ceiling: item.ceiling, gateOpen: item.open)
            XCTAssertEqual(got, item.expect, "状态机认错了：\(item.name)")
        }
    }

    // MARK: - 3.5 迁移期专属失效：切好的窗又切一次、排好的榜又排一次

    /// 这条**不报现量也不会有余量问题**，因为基线从一开始就是 0：
    /// 今天还没有人迁，所以命中数必然是 0；等迁移开始后它才是防止"迁了个假迁移"的闸。
    func testPreparedCellsAreNeverReslicedOrResorted() throws {
        let docs = try scannedConsumerDocs()
        XCTAssertGreaterThanOrEqual(docs.count, Self.minimumConsumerFiles,
                                    "只扫到 \(docs.count) 个文件，路径口径坏了——下面那条 0 命中就是永真绿")
        let hits = try Self.scanHits(pattern: Self.reslicePattern, in: docs)
        XCTAssertTrue(hits.isEmpty, """
        页面把采集侧**已经算好**的结果又切了一遍/又排了一遍：
        \(hits.joined(separator: "\n"))
        `curve.value` 已经是切好窗口的 90 点、`cpuRanking/memoryRanking` 已经是排好序的榜单
        （都在后台各算一次）。再 `suffix`/`sorted` 一次，等于把收益留在原地还多拷一份数组——
        粗 API 棘轮抓不到这种写法（它读的是细格），所以由这条管。
        """)
    }

    /// 元测试（双向）：坏样例必须三种形状都被抓到，合规写法一条都不许被误伤。
    /// 没这一条，"0 命中"到底是"没人这么写"还是"正则坏了"就分不出来——本仓的老坑。
    func testResliceScannerCatchesBadAndSparesGood() throws {
        let bad: [(String, String)] = [
            ("已切窗的曲线又 suffix", "PerformanceLiveCharts(points: Array(monitor.curve.value.suffix(30)))"),
            ("已排序的榜单又 sorted", "ForEach(monitor.cpuRanking.value.sorted { $0.cpuUsage > $1.cpuUsage })"),
            ("内存榜倒序现算", "let rows = monitor.memoryRanking.value.reversed()"),
        ]
        for (name, sample) in bad {
            let hits = try Self.scanHits(pattern: Self.reslicePattern,
                                        in: [Self.syntheticDoc("合成夹具", sample)])
            XCTAssertFalse(hits.isEmpty, "规则抓不住「\(name)」，它就是条废守卫：\(sample)")
        }
        let good = """
        PerformanceLiveCharts(points: monitor.curve.value, context: context)
        if monitor.curve.value.isEmpty { EmptyState() }
        Text("采样点 \\(monitor.pulse.value.historyCount)")
        ProcessRow(process: monitor.memoryRanking.value.first)
        // 注释里写 monitor.curve.value.suffix(90) 不算调用点
        """
        let spared = try Self.scanHits(pattern: Self.reslicePattern,
                                       in: [Self.syntheticDoc("合规夹具", good)])
        XCTAssertTrue(spared.isEmpty, "合规写法被误伤，逼人家写绕路代码：\n\(spared.joined(separator: "\n"))")
    }

    // MARK: - 3.6 粗读点的**收益分级**：从 `publish()` 现读，不是一份手抄名单

    /// 派单时最容易撒错的地方：「16 处」看着像 16 份等价收益，其实**只有两处粗属性是无闸门写**。
    /// 所以这条不描述源码，它**读源码**：谁给 `latestSnapshot` 补了闸门、或新加了一处裸赋值，
    /// 这里会红，逼他回来改口径——而不是留下一份和代码不符的名单（本仓 #44 那类事故的形状）。
    static let ungatedCoarseSymbols: Set<String> = ["latestSnapshot", "history"]
    static let gatedCoarseSymbols: Set<String> = ["topProcesses", "processesByMemory", "trackedGroups",
                                                  "measuredProcessCount", "processMetricsTruncated"]
    /// 声明就带 `@ObservationIgnored`：压根不在观察图里，读它不产生失效面。
    static let unobservedCoarseSymbols: Set<String> = ["allProcesses"]
    /// 计算属性别名：自己不写，但 getter 读别的粗属性 → 付的是**它所别名那一处**的代价。
    static let aliasCoarseSymbols: Set<String> = ["lastSampleAt"]

    /// 符号名单只有一处真相：从 `coarsePattern` 的交替组里现取。
    static func coarseSymbols(fromPattern pattern: String) -> [String] {
        guard let open = pattern.firstIndex(of: "("),
              let close = pattern.firstIndex(of: ")"), open < close else { return [] }
        return pattern[pattern.index(after: open)..<close].split(separator: "|").map(String.init)
    }

    private static func matches(_ line: String, _ pattern: String) -> Bool {
        line.range(of: pattern, options: .regularExpression) != nil
    }

    /// 抽 `publish(_:)` 的函数体。**每 tick 的写法只由这一个函数决定**：
    /// `refreshGroups()` 里那句 `trackedGroups = next` 是"用户改了组"才跑的一次性裸写，
    /// 拿它去判"每 tick 成本"会把一处顺手写读成承重写（第一次跑这条就被它抓到了）。
    /// 边界用「下一行正好是四个空格 + `}`」——本仓 Swift 缩进风格；故意不用括号计数：
    /// 在字符串/注释里数括号越界过一次，教训见《开缺陷单前先对齐口径》。
    /// 锚点写 `func publish(` 而不是 `private func publish(`：改可见性、加 `@MainActor`
    /// 都是常见动作，锚点越具体越容易在没人注意时悄悄抽不到东西（这条是刚才两轮破坏性试验换来的）。
    static func publishBody(of text: String) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: { $0.contains("func publish(") }) else { return [] }
        var body: [String] = []
        for line in lines[(start + 1)...] {
            if line == "    }" { return body }
            body.append(line)
        }
        return body          // 找不到收尾 → 交给下面那道分母闸判红，不在这里猜
    }

    /// 分母闸（纯函数，好被双向钉住）：抽出来的行数够不够撑起"这就是整段写界面的地方"。
    /// 真值现在是 33 行；门槛取 12——远低于真值（正常改动不会误报），远高于"锚点没匹配上"的 0。
    static let minimumPublishBodyLines = 12

    static func tickBodyIsUsable(_ body: [String]) -> Bool {
        body.count >= minimumPublishBodyLines
    }

    /// 纯函数：返回「符号 → 归类」。判定只看三件事——
    /// 声明上有没有 `@ObservationIgnored`、是不是读别的粗属性的别名、**每 tick 那一写**是裸赋值还是过闸门。
    /// 顺序是有意的：`allProcesses` 既被裸写又不在观察图里，而"不在图里"才是结论
    /// （裸写一个不参与观察的属性不产生失效面）。
    /// 同一个属性在一 tick 之内既裸写又闸门写 = `"冲突"`：那是"闸门只加了一半"的形状，宁可问人也不要自己挑一个。
    static func classifyCoarseWrites(declarations: [String], tickBody: [String],
                                     symbols: [String]) -> [String: String] {
        let decls = declarations.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        let code = tickBody.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        var result: [String: String] = [:]
        for symbol in symbols {
            let isUnobserved = decls.contains { $0.contains("@ObservationIgnored") && $0.contains("var \(symbol)") }
            let otherSymbols = symbols.filter { $0 != symbol }
            let isAlias = decls.contains { line in
                guard Self.matches(line, #"var \#(symbol)\b[^={]*\{\s*\S"#) else { return false }
                return otherSymbols.contains { Self.matches(line, #"\b\#($0)\b"#) }
            }
            let isUngated = code.contains { Self.matches($0, #"^\s*(?:self\.)?\#(symbol)\s*=[^=]"#) }
            let isGated = code.contains { Self.matches($0, #"write\(\s*\\\.\#(symbol)\b"#) }
            switch (isUnobserved, isAlias, isUngated, isGated) {
            case (true, _, _, _): result[symbol] = "unobserved"
            case (_, true, _, _): result[symbol] = "alias"
            case (_, _, true, true): result[symbol] = "冲突"
            case (_, _, true, _): result[symbol] = "ungated"
            case (_, _, _, true): result[symbol] = "gated"
            default: result[symbol] = "未归类"
            }
        }
        return result
    }

    private func monitorSourceText() throws -> String {
        let url = Self.moduleRoot.appendingPathComponent(
            "Sources/TcoderMonitor/Services/Performance/MachSystemMonitor.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// 真文件 + 真口径：分类必须和源码一致。
    private func classifiedCoarseWrites() throws -> (classified: [String: String],
                                                     tickBodyLines: Int,
                                                     offTickBareWrites: [String]) {
        let text = try monitorSourceText()
        let body = Self.publishBody(of: text)
        // 分母闸：提取器坏了会让"没人裸写粗属性"变成假绿，所以先量它抽到了多少行。
        XCTAssertTrue(Self.tickBodyIsUsable(body),
                      "只从 `publish()` 抽到 \(body.count) 行（门槛 \(Self.minimumPublishBodyLines)），"
                    + "边界判定坏了 → 下面的分级不可信")
        let symbols = Self.coarseSymbols(fromPattern: Self.coarsePattern)
        let classified = Self.classifyCoarseWrites(declarations: Self.codeLines(of: text).map(\.text),
                                                  tickBody: body, symbols: symbols)
        // 「tick 之外还有谁裸写粗属性」是**披露**不是判红：一次性写不是每 tick 成本，
        // 但也不能当它不存在——迁移完成后整个兼容层要删，这些点得跟着一起消失。
        let inBody = Set(body)
        let offTick = Self.codeLines(of: text).filter { line in
            guard !inBody.contains(line.text) else { return false }
            return symbols.contains { Self.matches(line.text, #"^\s*(?:self\.)?\#($0)\s*=[^=]"#) }
        }.map { "MachSystemMonitor.swift:\($0.number) \($0.text.trimmingCharacters(in: .whitespaces))" }
        return (classified, body.count, offTick)
    }

    func testCoarseWriteCostClassMatchesPublishSource() throws {
        let symbols = Self.coarseSymbols(fromPattern: Self.coarsePattern)
        XCTAssertEqual(Set(symbols), Self.ungatedCoarseSymbols.union(Self.gatedCoarseSymbols)
                       .union(Self.unobservedCoarseSymbols).union(Self.aliasCoarseSymbols),
                       "`coarsePattern` 的禁则名单与收益分级的名单不是同一批符号了：\(symbols)")
        let probe = try classifiedCoarseWrites()
        let classified = probe.classified
        XCTAssertEqual(classified.values.filter { $0 == "冲突" || $0 == "未归类" }, [],
                       "有粗属性在同一个 tick 内既被裸写又被闸门写（或谁都没写），收益分级无法成立：\(classified)")
        func bucket(_ name: String) -> Set<String> {
            Set(classified.filter { $0.value == name }.map { $0.key })
        }
        XCTAssertEqual(bucket("ungated"), Self.ungatedCoarseSymbols, "无闸门写的粗属性变了")
        XCTAssertEqual(bucket("gated"), Self.gatedCoarseSymbols, "走等值闸门的粗属性变了")
        XCTAssertEqual(bucket("unobserved"), Self.unobservedCoarseSymbols)
        XCTAssertEqual(bucket("alias"), Self.aliasCoarseSymbols)
        let offTick = probe.offTickBareWrites.joined(separator: " | ")
        print("【收益分级的依据】`publish()` 抽到 \(probe.tickBodyLines) 行；"
            + "无闸门写 \(Self.ungatedCoarseSymbols.count) 处 / 已走闸门 \(Self.gatedCoarseSymbols.count) 处"
            + " / 不在观察图 \(Self.unobservedCoarseSymbols.count) 处 / 别名 \(Self.aliasCoarseSymbols.count) 处"
            + "；tick 之外另有 \(probe.offTickBareWrites.count) 处裸写（一次性路径，随兼容层一起删）"
            + (offTick.isEmpty ? "" : "：" + offTick))
    }

    /// 元测试（双向）：分级必须真能把「裸写」和「闸门写」区分开，否则上面那条等于没测。
    /// 反向用例特意放了 `x == y` 比较、注释行（都不是写点），以及一处"同一 tick 里闸门只加了一半"的写点。
    func testCoarseWriteClassifierSeparatesGatedFromUngated() {
        let fixture = [
            "@ObservationIgnored private(set) var allProcesses: [ProcessSnapshot] = []",
            "private(set) var latestSnapshot: SystemSnapshot?",
            "private(set) var topProcesses: [ProcessSnapshot] = []",
            "var lastSampleAt: Date? { latestSnapshot?.timestamp }",
            "// latestSnapshot = 注释里提到写点，不算",
            "latestSnapshot = batch.snapshot",
            "history = frames",
            "write(\\.topProcesses, leads.cpuRanking, &stats)",
            "halfGated = batch.leads.something",
            "write(\\.halfGated, batch.leads.something, &stats)",
            "if latestSnapshot == batch.snapshot { return }",
        ]
        let symbols = ["latestSnapshot", "history", "topProcesses", "allProcesses", "lastSampleAt", "halfGated"]
        let classified = Self.classifyCoarseWrites(declarations: fixture, tickBody: fixture, symbols: symbols)
        XCTAssertEqual(classified["latestSnapshot"], "ungated", "裸赋值没被判成无闸门写 → 承重的会被漏掉")
        XCTAssertEqual(classified["history"], "ungated")
        XCTAssertEqual(classified["topProcesses"], "gated", "闸门写没被判出来 → 顺手的会被错当成收益")
        XCTAssertEqual(classified["allProcesses"], "unobserved",
                       "裸写一个 `@ObservationIgnored` 属性不该算成本：它压根不在观察图里")
        XCTAssertEqual(classified["lastSampleAt"], "alias",
                       "别名没认出来 → 会误判成「没人写它」，而它其实每 tick 都在付 latestSnapshot 的账")
        XCTAssertEqual(classified["halfGated"], "冲突",
                       "「同一 tick 既裸写又闸门写」必须判冲突——那正是闸门只加了一半、读数看着对其实白加的形状")
    }

    /// `publishBody` 是这套分级的**唯一取数口**，它自己也得双向钉：
    /// 抽少了（没找到）要走分母闸判红，抽多了（越界到下一个函数）会把一次性写当成每 tick 成本。
    func testPublishBodyExtractorStopsAtTheFunctionBoundary() {
        let source = """
        final class MachSystemMonitor {
            private(set) var latestSnapshot: SystemSnapshot?

            private func publish(_ batch: SampleBatch) {
                latestSnapshot = batch.snapshot
                write(\\.topProcesses, leads.cpuRanking, &stats)
            }

            private func refreshGroups() {
                trackedGroups = next
            }
        }
        """
        let body = Self.publishBody(of: source)
        XCTAssertEqual(body.filter { $0.contains("latestSnapshot =") }.count, 1,
                       "publish 体内那一处裸写没抽到 → 承重的会被漏判：\(body)")
        XCTAssertFalse(body.contains { $0.contains("trackedGroups") },
                       "越界到下一个函数了 → tick 外的一次性裸写会被读成每 tick 成本：\(body)")

        // 锚点不能比代码更挑剔：改可见性 / 加属性之后必须照样抽得到（刚才两轮破坏性试验换来的）。
        for variant in ["    func publish(_ batch: SampleBatch) {",
                        "    @MainActor func publish(_ batch: SampleBatch) {",
                        "    internal func publish(_ batch: SampleBatch) {"] {
            let rewritten = source.replacingOccurrences(
                of: "    private func publish(_ batch: SampleBatch) {", with: variant)
            XCTAssertEqual(Self.publishBody(of: rewritten).count, body.count,
                           "声明形式一改成「\(variant.trimmingCharacters(in: .whitespaces))」就抽不到东西了")
        }

        // 分母闸双向：没有 publish 必须返回空、空的必须被判不可用。
        // 少了这两条，"抽不到 → 零处裸写 → 全走闸门 → 收益分级看起来很好" 就是一条假绿的路径。
        let empty = Self.publishBody(of: "final class Nope { }")
        XCTAssertTrue(empty.isEmpty, "没有 `publish` 时不该硬猜出一个函数体")
        XCTAssertFalse(Self.tickBodyIsUsable(empty), "空体必须判不可用，否则分母闸是摆设")
        XCTAssertFalse(Self.tickBodyIsUsable(["        latestSnapshot = batch.snapshot"]),
                       "只抽到一行也必须是红的：那说明边界判定烂了")
        XCTAssertTrue(Self.tickBodyIsUsable(Array(repeating: "        x += 1",
                                                 count: Self.minimumPublishBodyLines)),
                      "刚好到门槛就该放行——门槛不该高到让正常改动天天误报")
    }

    /// 把分级落到**调用点计数**上：这一条打印的就是派单该看的两个数。
    /// 只断言"两者相加等于总命中"（分类完备），不断言各占几处——那是随迁移变的量。
    func testCoarseReadoutSitesSplitIntoLoadBearingAndIncidental() throws {
        let docs = try scannedConsumerDocs()
        let hits = try Self.scanHits(pattern: Self.coarsePattern, in: docs)
        let classified = try classifiedCoarseWrites().classified
        func symbol(of hit: String) -> String? {
            let token = hit.split(separator: " ").last.map(String.init) ?? hit
            return Self.coarseSymbols(fromPattern: Self.coarsePattern)
                .first { token.hasSuffix(".\($0)") || token == $0 }
        }
        var loadBearing = 0, incidental = 0, outOfGraph = 0, unknown = 0
        for hit in hits {
            switch classified[symbol(of: hit) ?? ""] {
            case "ungated", "alias": loadBearing += 1
            case "gated": incidental += 1
            case "unobserved": outOfGraph += 1
            default: unknown += 1
            }
        }
        XCTAssertEqual(unknown, 0, "有调用点落在分级之外 = 名单与禁则又各说各话了")
        XCTAssertEqual(outOfGraph, 0,
                       "有页面在读 `@ObservationIgnored` 的粗属性：不产生失效面，但那条属性的契约是「零读点」，"
                     + "由 testServiceSideKeepsDerivedValuesCachedAndNarrow 一起管")
        let line = "loadBearing=\(loadBearing) incidental=\(incidental) total=\(hits.count)\n"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tcoder-perf-migration-weighting.txt")
        try line.write(to: url, atomically: true, encoding: .utf8)
        print("【粗读点收益分级】承重（无闸门写/别名，每 tick 必重算）\(loadBearing) 处"
            + " / 顺手（已走等值闸门，单独迁它测不出差异）\(incidental) 处"
            + " / 合计 \(hits.count)（台账 \(url.lastPathComponent)）")
    }

    // MARK: - 4. 采集侧不许退回旧形状

    func testServiceSideKeepsDerivedValuesCachedAndNarrow() throws {
        let docs = try scannedServiceDocs()
        XCTAssertGreaterThanOrEqual(docs.count, 3, "只扫到 \(docs.count) 个采集侧文件，路径口径坏了")
        let regressions = try Self.scanHits(pattern: Self.computedMemoryRankingPattern, in: docs)
            + Self.scanHits(pattern: Self.unguardedAllProcessesPattern, in: docs)
        XCTAssertTrue(regressions.isEmpty,
                      "采集侧退回了「每次访问现算 / 把大数组留在观察图里」的旧形状：\n"
                        + regressions.joined(separator: "\n"))
        let source = docs.map { $0.lines.map(\.text).joined(separator: "\n") }.joined(separator: "\n")
        XCTAssertTrue(source.contains("@ObservationIgnored private(set) var allProcesses"),
                      "`allProcesses` 必须留在观察图外（视图零读点），否则每 tick 白搭一次整片失效")
    }

    // MARK: - 5. 失效面真的收窄了（运行期行为，不是 grep 出来的）

    @MainActor
    func testWritingOneCellDoesNotWakeReadersOfAnother() {
        let cpu = PerfCell<Double>(0)
        let memory = PerfCell<Double>(0)
        var wokeForCPU = 0
        withObservationTracking { _ = cpu.value } onChange: { wokeForCPU += 1 }
        XCTAssertTrue(memory.apply(42), "另一格的值真的变了，必须写出去")
        XCTAssertEqual(wokeForCPU, 0, "写 memory 格却唤醒了只读 cpu 格的观察者 → 细粒度是假的")
        XCTAssertTrue(cpu.apply(7))
        XCTAssertEqual(wokeForCPU, 1, "本格写入必须唤醒本格读者")
        XCTAssertFalse(cpu.apply(7), "同值写入不得换引用")
        XCTAssertEqual(wokeForCPU, 1, "同值写入又唤醒了一次 → 等值闸门没生效")
    }

    /// 反向对照：收窄失效面**不等于**把兼容层写成死值。
    /// 粗属性照旧一 publish 就唤醒整帧读者；而暂停入口自己不该惊动任何人。
    @MainActor
    func testCoarseSurfaceStillWakesReadersButPauseEntryDoesNot() {
        let monitor = MachSystemMonitor()
        var woke = 0
        withObservationTracking { _ = monitor.latestSnapshot } onChange: { woke += 1 }
        XCTAssertEqual(woke, 0, "还没落帧就被告知变更，说明观察记账有问题")
        monitor.beginInteractionPause(.pageTransition)
        XCTAssertEqual(woke, 0, "暂停入口自己不许惊动整帧读者")
        monitor.endInteractionPause(.pageTransition)
        XCTAssertEqual(woke, 0, "没攒到帧的恢复不该凭空写一次界面")
        _ = monitor.sampleNow()
        XCTAssertEqual(woke, 1, "落了一帧就必须唤醒整帧读者——兼容层不能变成死值")
    }

    // MARK: - 6. T3 暂停：引用计数 + 暂停期的帧不丢、不补 0

    @MainActor
    func testPauseIsReferenceCountedAcrossCallers() {
        let monitor = MachSystemMonitor()
        XCTAssertFalse(monitor.isInteractionPaused)
        monitor.beginInteractionPause(.pointerStream)
        monitor.beginInteractionPause(.pageTransition)
        monitor.beginInteractionPause(.pointerStream)          // 同一来源重复 begin 只算一票
        monitor.endInteractionPause(.pageTransition)
        XCTAssertTrue(monitor.isInteractionPaused, "滚动还按着，切页结束不许提前解冻")
        monitor.endInteractionPause(.windowDrag)               // 没 begin 过的 end 不许把状态往反里带
        XCTAssertTrue(monitor.isInteractionPaused, "凭空 end 不许解冻别人")
        monitor.endInteractionPause(.pointerStream)            // 还完最后一票
        XCTAssertFalse(monitor.isInteractionPaused, "全部归还后必须恢复")
    }

    /// 暂停期写的这一帧：界面一格都不动，但帧本身进了历史；恢复后是**真实末值 + 真实轨迹**，
    /// 既没有被画成 0，也没有留成空白（规范红线四条）。
    @MainActor
    func testPausedFrameIsBufferedNotDroppedAndNotZeroFilled() {
        let monitor = MachSystemMonitor()
        monitor.beginInteractionPause(.pageTransition)
        _ = monitor.sampleNow()
        XCTAssertNil(monitor.latestSnapshot, "暂停期间不许往界面写新帧")
        XCTAssertTrue(monitor.history.isEmpty)
        XCTAssertTrue(monitor.curve.value.isEmpty)

        monitor.endInteractionPause(.pageTransition)
        XCTAssertNotNil(monitor.latestSnapshot, "恢复后必须把暂停期攒下的真实帧补上")
        XCTAssertEqual(monitor.history.count, 1, "暂停期那一帧必须还在历史里，一帧都没丢")
        XCTAssertEqual(monitor.curve.value.count, 1)
        XCTAssertEqual(monitor.pulse.value.historyCount, 1)
        XCTAssertEqual(monitor.curve.value.first?.timestamp, monitor.latestSnapshot?.timestamp,
                       "补进曲线的必须是那一帧的真实读数，不能是补出来的 0")
    }

    /// 恢复之后读数与粗属性同值：两套口径不许在恢复的那一刻分叉。
    @MainActor
    func testFineCellsAgreeWithCoarseSurfacesAfterPublish() {
        let monitor = MachSystemMonitor()
        _ = monitor.sampleNow()
        guard let snapshot = monitor.latestSnapshot else { return XCTFail("sampleNow 必须产出真实一帧") }
        XCTAssertEqual(monitor.memory.value.usedBytes, snapshot.memoryUsedBytes)
        XCTAssertEqual(monitor.memory.value.totalBytes, snapshot.memoryTotalBytes)
        XCTAssertEqual(monitor.memory.value.pressure, snapshot.memoryPressure)
        XCTAssertEqual(monitor.ledger.value.measuredCount, monitor.measuredProcessCount)
        XCTAssertEqual(monitor.ledger.value.metricsTruncated, monitor.processMetricsTruncated)
        XCTAssertEqual(monitor.cpuRanking.value.count, monitor.topProcesses.count)
        XCTAssertEqual(monitor.groupRanking.value, monitor.trackedGroups)
        XCTAssertEqual(monitor.pulse.value.historyCount, monitor.history.count)
        XCTAssertEqual(monitor.cpu.value.coreCount, snapshot.cpuCoreCount)
    }

    // MARK: - 7. T8 诚实性：细粒度格不得比粗粒度层更 loose

    func testLeadsGiveNoDerivativeWithoutPreviousFrame() {
        var snapshot = SystemSnapshot()
        snapshot.cpuUsage = 0.55
        snapshot.diskReadBytesPerSecond = 1_000
        snapshot.diskWriteBytesPerSecond = 2_000
        snapshot.networkInBytesPerSecond = 3_000
        snapshot.networkOutBytesPerSecond = 4_000
        let processes = [ProcessSnapshot(pid: 11, name: "a", cpuUsage: 0.5, memoryBytes: 100,
                                         threadCount: 2, openFileCount: 3, startTime: nil,
                                         commandLine: "/bin/a", parentPID: 1),
                         ProcessSnapshot(pid: 12, name: "b", cpuUsage: 1.5, memoryBytes: 900,
                                         threadCount: 4, openFileCount: 6, startTime: nil,
                                         commandLine: "/bin/b", parentPID: 1)]
        let sweep = ProcessSweep(processes: processes, states: [:], elapsed: 1.5,
                                 truncated: true, visiblePIDCount: 2)
        let groups = [TrackedProcessGroup(title: "A 服务", matchPattern: "a")]

        // 没有上一帧 → CPU 与四项速率一律 nil（无 previous 不得给速率与 CPU）。
        let cold = PerfLeads.derive(previous: nil, snapshot: snapshot, sweep: sweep,
                                    totalProbe: ProcessCountProbe(count: 2, isSystemWide: false),
                                    groups: groups, topLimit: 20)
        XCTAssertNil(cold.cpu.usage, "只有一帧时 CPU 是差分量，给 nil 而不是把 0 当成空转")
        XCTAssertNil(cold.rates.diskReadBytesPerSecond)
        XCTAssertNil(cold.rates.diskWriteBytesPerSecond)
        XCTAssertNil(cold.rates.networkInBytesPerSecond)
        XCTAssertNil(cold.rates.networkOutBytesPerSecond)
        XCTAssertFalse(cold.ledger.countIsSystemWide, "sysctl 没问到时必须如实标「只是本用户可见子集」")

        let warm = PerfLeads.derive(previous: SystemCounters(), snapshot: snapshot, sweep: sweep,
                                   totalProbe: ProcessCountProbe(count: 999, isSystemWide: true),
                                   groups: groups, topLimit: 20)
        XCTAssertEqual(warm.cpu.usage, 0.55)
        XCTAssertEqual(warm.rates.networkOutBytesPerSecond, 4_000)
        XCTAssertEqual(warm.ledger.systemWideCount, 999)
        XCTAssertTrue(warm.ledger.countIsSystemWide)

        // 榜单：排序方向、截断上限、组匹配"没命中也要有一行"。
        XCTAssertEqual(warm.cpuRanking.map(\.pid), [12, 11], "CPU 榜必须降序，视图才能直接展示")
        XCTAssertEqual(warm.memoryRanking.map(\.pid), [12, 11], "内存榜必须按 RSS 降序")
        XCTAssertEqual(warm.groups.count, groups.count, "没有匹配的组也必须出现在结果里")
        XCTAssertEqual(warm.ledger.measuredCount, 2)
        XCTAssertTrue(warm.ledger.metricsTruncated)
    }

    /// 上限：榜单条数与曲线窗口点数都是既有口径，P 包一个都没为了少画点而放宽。
    @MainActor
    func testRankingAndCurveWindowSizesAreUnchanged() {
        let processes = (0..<40).map {
            ProcessSnapshot(pid: Int32($0), name: "p\($0)", cpuUsage: Double($0), memoryBytes: UInt64($0),
                            threadCount: 1, openFileCount: 1, startTime: nil, commandLine: "/bin/p", parentPID: 1)
        }
        let sweep = ProcessSweep(processes: processes, states: [:], elapsed: 1.5, truncated: false,
                                 visiblePIDCount: processes.count)
        let leads = PerfLeads.derive(previous: SystemCounters(), snapshot: SystemSnapshot(), sweep: sweep,
                                     totalProbe: ProcessCountProbe(count: 40, isSystemWide: true),
                                     groups: [], topLimit: 20)
        XCTAssertEqual(leads.cpuRanking.count, 20, "CPU 榜上限仍是 20")
        XCTAssertEqual(leads.memoryRanking.count, 20, "内存榜上限仍是 20")
        XCTAssertEqual(MachSystemMonitor.curveWindowPoints, 90, "曲线窗口仍是 90 点（≈135 秒），没为省时间改窗口")
        XCTAssertEqual(leads.cpuRanking.first?.cpuUsage, 39)
    }

    /// 首帧之前：每一格都是"没有证据"，而不是 0。
    @MainActor
    func testCellsStartEmptyRatherThanZeroFilled() {
        let monitor = MachSystemMonitor()
        XCTAssertNil(monitor.cpu.value.usage)
        XCTAssertNil(monitor.rates.value.diskReadBytesPerSecond)
        XCTAssertNil(monitor.pulse.value.sampleAt)
        XCTAssertEqual(monitor.pulse.value.historyCount, 0)
        XCTAssertEqual(monitor.memory.value.pressure, MemoryPressure.unknown, "没读过页计数就是 unknown，不是正常")
        XCTAssertTrue(monitor.cpuRanking.value.isEmpty)
        XCTAssertTrue(monitor.curve.value.isEmpty)
    }

    // MARK: - 8. 契约面存在性（名字要稳：三家照这个名字迁，名字没了必须红）

    func testFineGrainedContractSurfaceStillExists() throws {
        let docs = try scannedServiceDocs()
        let source = docs.map { $0.lines.map(\.text).joined(separator: "\n") }.joined(separator: "\n")
        let promised = ["let cpu = PerfCell<PerfCPULead>", "let memory = PerfCell<PerfMemoryLead>",
                        "let rates = PerfCell<PerfRateLead>", "let ledger = PerfCell<PerfProcessLedger>",
                        "let pulse = PerfCell<PerfPulse>", "let cpuRanking = PerfCell<[ProcessSnapshot]>",
                        "let memoryRanking = PerfCell<[ProcessSnapshot]>",
                        "let groupRanking = PerfCell<[ProcessGroupSnapshot]>",
                        "let curve = PerfCell<[SystemSnapshot]>",
                        "func beginInteractionPause(", "func endInteractionPause("]
        let missing = promised.filter { !source.contains($0) }
        XCTAssertTrue(missing.isEmpty,
                      "P 包给三家的细粒度契约被删了：\(missing)。页面还在照这些名字迁移，删名字等于制造编译灾难。")
    }

    /// T3 的接线必须在编排器里（规范红线四条：页面零改动、不用 macOS 15+ 的 scroll phase API）。
    func testInteractionGatingLivesInAppState() throws {
        let docs = try Self.documents(under: "Sources/TcoderMonitor/App")
        let source = docs.map { $0.lines.map(\.text).joined(separator: "\n") }.joined(separator: "\n")
        XCTAssertTrue(source.contains("addLocalMonitorForEvents"),
                      "滚动/拖拽的暂停接线必须留在 AppState 的 NSEvent 本地监视器里")
        XCTAssertTrue(source.contains("willStartLiveResizeNotification"),
                      "拖窗 / live resize 必须有暂停来源，否则 T3 只覆盖了一半")
        XCTAssertFalse(source.contains("onScrollPhaseChange"),
                       "`onScrollPhaseChange` 是 macOS 15+，部署下限是 14，禁止使用")
        let pageDocs = try Self.documents(under: "Sources/TcoderMonitor/Views")
        let pageHits = try Self.scanHits(pattern: "beginInteractionPause|endInteractionPause", in: pageDocs)
        XCTAssertTrue(pageHits.isEmpty, "页面这轮零改动：暂停入口不许散写进 \(pageHits.count) 处视图")
    }
}
