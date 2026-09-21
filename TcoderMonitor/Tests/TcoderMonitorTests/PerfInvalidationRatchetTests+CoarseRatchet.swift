/// OWNER: WS-X3 TestSplit —— 自 PerfInvalidationRatchetTests.swift 拆出，粗读调用点只减不增 + 扫描器反例 + 消费闸门的诚实态。用例本体未改，只是搬了家。
import Foundation
import Observation
import XCTest
@testable import TcoderMonitor

extension PerfInvalidationRatchetTests {

    func testCoarseReadoutCallSitesDoNotIncrease() throws {

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
}
