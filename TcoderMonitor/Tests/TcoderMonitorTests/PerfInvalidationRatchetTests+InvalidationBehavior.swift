/// OWNER: WS-X3 TestSplit —— 自 PerfInvalidationRatchetTests.swift 拆出，publish 之后的失效面行为：缓存窄化、逐格唤醒、暂停计数、导数与窗口。用例本体未改，只是搬了家。
import Foundation
import Observation
import XCTest
@testable import TcoderMonitor

extension PerfInvalidationRatchetTests {

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

    func testLeadsGiveNoDerivativeWithoutPreviousFrame() {
        var snapshot = SystemSnapshot()
        snapshot.cpuUsage = 0.55
        snapshot.diskReadBytesPerSecond = 1_000
        snapshot.diskWriteBytesPerSecond = 2_000
        snapshot.networkInBytesPerSecond = 3_000
        snapshot.networkOutBytesPerSecond = 4_000
        let processes = [ProcessSnapshot(pid: 11, name: "a", cpuUsage: 0.5, memoryBytes: 100,
                                         threadCount: 2, openFileCount: 3, startTime: nil,
                                         executablePath: "/bin/a", parentPID: 1),
                         ProcessSnapshot(pid: 12, name: "b", cpuUsage: 1.5, memoryBytes: 900,
                                         threadCount: 4, openFileCount: 6, startTime: nil,
                                         executablePath: "/bin/b", parentPID: 1)]
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
                            threadCount: 1, openFileCount: 1, startTime: nil, executablePath: "/bin/p", parentPID: 1)
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
