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
    static let moduleRoot: URL = URL(fileURLWithPath: #filePath)
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

    struct Line { var number: Int; var text: String }
    struct Doc { var file: String; var lines: [Line] }

    /// 整行注释（含 `///` 文档注释）豁免——说明文里必须提到被禁的写法本身。
    static func codeLines(of text: String) -> [Line] {
        text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            .map { Line(number: $0.offset + 1, text: String($0.element)) }
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    /// 返回 `文件:行号 命中行` 的清单。喂合成字符串与喂真仓库走的是同一个函数。
    /// 行号按**原文**报（注释行只是不参与匹配），否则报错信息会把人带到别的行上去。
    static func scanHits(pattern: String, in docs: [Doc]) throws -> [String] {
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

    func scannedConsumerDocs() throws -> [Doc] {
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
