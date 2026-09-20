import XCTest
@testable import TcoderMonitor

// WS-C 子代理「性能采样单测」。
//
// 覆盖：SystemSampler / ProcessInspector 的纯函数、PerformanceHistory 的淘汰语义，
// 以及 MachSystemMonitor 的结构烟测。
//
// 纪律：本文件不断言任何真实 CPU / 内存 / 磁盘数值，不用 sleep 计时做断言，
// 不给任何进程发信号或 kill，只读取当前进程自身与公开 sysctl 值。
//
// 以下断言「因实现细节放宽，见 WS-C 笔记」：
//  1. SystemSampler.cpuUsage：previous/current 核数不一致、或只有一边是空数组时，
//     只断言结果落在 0...1，不断言具体值（截断策略由实现决定）。
//  2. ProcessInspector.cpuUsage：完全不断言「previousNano == 0 的首次采样」，
//     实现可能把首点视为 0，也可能视为整段增量，两者都合理。
//  3. SystemSampler.pressure(for:)：越界（负数 / >1 / NaN）输入只断言「返回合法档位、不崩」。
//  4. MachSystemMonitor.trackedGroups 与内置组的关系：把「数量相等」放宽为
//     「数量 >= 内置组数 且每个内置组标题都被覆盖」，以容忍实现一并回填用户自定义组。
//  5. addGroup 之后 trackedGroups 的刷新时机未知，因此 sampleNow() + 有限轮询；
//     仍拿不到时退化为只断言 groups() 已更新。
//  6. 采样循环用例只轮询 history.count > 1（最多 3 次 × 300ms）而**不**断言它一定增长：
//     Timer 驱动的循环在 XCTest 主队列上的推进时机不受测试控制，硬断言会 flaky。
//  7. 幂等性：stop() 后 300ms 内 history 增量放宽为 <= 4（严格相等需要真实计时，会 flaky）。
//  8. groupSnapshots 只断言「每个 group 恰好一条结果」的集合关系，不断言数组顺序。

final class PerformanceSamplerTests: XCTestCase {

    // MARK: - 夹具

    /// 与真实机器核数对齐，避免 `cpuCoreCount` 的断言在两种合理实现之间产生歧义。
    var coreCount: Int { max(1, ProcessInfoWrapper.processorCount) }

    func ticks(user: UInt32 = 0, system: UInt32 = 0, idle: UInt32 = 0, nice: UInt32 = 0) -> CoreTicks {
        CoreTicks(user: user, system: system, idle: idle, nice: nice)
    }

    func coreArray(_ tick: CoreTicks, count: Int? = nil) -> [CoreTicks] {
        Array(repeating: tick, count: count ?? coreCount)
    }

    func memory(
        pageSize: UInt64 = 16_384,
        active: UInt64 = 1_000,
        inactive: UInt64 = 500,
        wired: UInt64 = 300,
        compressed: UInt64 = 100,
        free: UInt64 = 2_000,
        speculative: UInt64 = 0,
        purgeable: UInt64 = 0
    ) -> VmCounters {
        VmCounters(pageSize: pageSize, active: active, inactive: inactive,
                   wired: wired, compressed: compressed, free: free,
                   speculative: speculative, purgeable: purgeable)
    }

    func counters(
        at date: Date,
        cores tick: [CoreTicks],
        memory vmCounters: VmCounters,
        diskRead: UInt64,
        diskWrite: UInt64,
        networkIn: UInt64,
        networkOut: UInt64
    ) -> SystemCounters {
        SystemCounters(timestamp: date, cores: tick, vm: vmCounters,
                       diskReadBytes: diskRead, diskWriteBytes: diskWrite,
                       networkInBytes: networkIn, networkOutBytes: networkOut)
    }

    func process(
        pid: Int32,
        name: String,
        cpu: Double = 0,
        memory: UInt64 = 0,
        threads: Int = 1,
        openFiles: Int = 1,
        commandLine: String = "",
        parentPID: Int32 = 1
    ) -> ProcessSnapshot {
        ProcessSnapshot(pid: pid, name: name, cpuUsage: cpu, memoryBytes: memory,
                        threadCount: threads, openFileCount: openFiles,
                        startTime: nil, commandLine: commandLine, parentPID: parentPID)
    }

    func systemSnapshot(atSecond second: Double) -> SystemSnapshot {
        SystemSnapshot(timestamp: Date(timeIntervalSince1970: second))
    }

    func javaGroup() -> TrackedProcessGroup {
        TrackedProcessGroup(title: "Java 服务", matchPattern: "java", isBuiltIn: true)
    }

    func nodeGroup() -> TrackedProcessGroup {
        TrackedProcessGroup(title: "Node 服务", matchPattern: "node", isBuiltIn: false)
    }

    func mysqlGroup() -> TrackedProcessGroup {
        TrackedProcessGroup(title: "MySQL", matchPattern: "mysqld", isBuiltIn: false)
    }

    func fixtureProcesses() -> [ProcessSnapshot] {
        [
            process(pid: 900_011, name: "java", cpu: 1.5, memory: 200, threads: 20, openFiles: 300,
                    commandLine: "/usr/bin/java -jar app.jar"),
            process(pid: 900_012, name: "com.example.JavaWrapper", cpu: 0.5, memory: 100, threads: 5, openFiles: 12,
                    commandLine: "/opt/homebrew/bin/java -version"),
            process(pid: 900_013, name: "node", cpu: 2.0, memory: 400, threads: 8, openFiles: 40,
                    commandLine: "/usr/local/bin/node server.js"),
            process(pid: 900_014, name: "nginx", cpu: 0.1, memory: 50, threads: 1, openFiles: 4,
                    commandLine: "/usr/sbin/nginx"),
        ]
    }

    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - 1. SystemSampler.cpuUsage

    func testCPUUsageIsZeroWhenOnlyIdleTicksAdvance() {
        let previous = coreArray(ticks())
        let current = coreArray(ticks(idle: 5_000))
        XCTAssertEqual(SystemSampler.cpuUsage(previous: previous, current: current), 0, accuracy: 1e-9,
                       "只有 idle 增长时占用率必须是 0")
    }

    func testCPUUsageIsOneWhenIdleDoesNotAdvanceAtAll() {
        let previous = coreArray(ticks())
        let current = coreArray(ticks(user: 100, system: 50))
        XCTAssertEqual(SystemSampler.cpuUsage(previous: previous, current: current), 1, accuracy: 1e-9,
                       "idle 增量为 0 且总增量为正时占用率必须是 1")
    }

    func testCPUUsageMatchesHandComputedTwoCoreDelta() {
        // 每核 busy = user 100 + system 100 = 200，总量 = 200 + idle 300 = 500 → 0.4
        let previous = coreArray(ticks(), count: 2)
        let current = coreArray(ticks(user: 100, system: 100, idle: 300), count: 2)
        XCTAssertEqual(SystemSampler.cpuUsage(previous: previous, current: current), 0.4, accuracy: 1e-9,
                       "两核 user/sys 各 100、idle 各 300 必须算出 0.4")
    }

    func testCPUUsageStaysWithinUnitRangeWhenCoreCountsDisagree() {
        let two = coreArray(ticks(user: 40, idle: 60), count: 2)
        let four = coreArray(ticks(user: 40, idle: 60), count: 4)
        let grew = SystemSampler.cpuUsage(previous: two, current: four)
        let shrank = SystemSampler.cpuUsage(previous: four, current: two)
        XCTAssertTrue(grew >= 0 && grew <= 1, "核数变多时必须安全（放宽，见文件头第 1 条），实得 \(grew)")
        XCTAssertTrue(shrank >= 0 && shrank <= 1, "核数变少时必须安全（放宽，见文件头第 1 条），实得 \(shrank)")
    }

    func testCPUUsageIsZeroWhenCurrentCountersAreSmallerThanPrevious() {
        let previous = coreArray(ticks(user: 500, system: 500, idle: 500))
        let current = coreArray(ticks(user: 100, system: 100, idle: 100))
        XCTAssertEqual(SystemSampler.cpuUsage(previous: previous, current: current), 0, accuracy: 1e-9,
                       "计数器回绕（current < previous）必须返回 0 而不是下溢")
    }

    func testCPUUsageIsZeroForEmptyCoreArrays() {
        XCTAssertEqual(SystemSampler.cpuUsage(previous: [], current: []), 0, accuracy: 1e-9,
                       "两侧都是空数组必须返回 0")
        let lone = SystemSampler.cpuUsage(previous: [], current: coreArray(ticks(user: 100, idle: 100)))
        XCTAssertTrue(lone >= 0 && lone <= 1, "单边为空时必须安全（放宽，见文件头第 1 条），实得 \(lone)")
    }

    // MARK: - 2. SystemSampler.memoryUsedBytes
    //
    // 口径为总工实测后的版本：used = total - (free + speculative + purgeable) * pageSize，
    // 与活动监视器一致（inactive 是文件缓存但被算作已用，所以不能只加 active+wired+compressed）。

    func testMemoryUsedBytesMatchesActivityMonitorFormulaOnRealPageCounts() throws {
        // 本机实测（48 GiB、page 16384）：free 59454 / speculative 20714 / purgeable 9795
        let total = UInt64(51_539_607_552)
        let counters = memory(pageSize: 16_384, active: 757_410, inactive: 736_816,
                              wired: 342_131, compressed: 1_300_992,
                              free: 59_454, speculative: 20_714, purgeable: 9_795)
        let reclaimablePages = 59_454 + 20_714 + 9_795
        let expected = total - UInt64(reclaimablePages) * 16_384
        let used = try XCTUnwrap(SystemSampler.memoryUsedBytes(counters, totalBytes: total),
                                 "可用读数必须算得出已用，返回 nil 等于把真数据也判成缺证据")
        XCTAssertEqual(used, expected, "已用内存必须等于 total - (free+speculative+purgeable)*pageSize")
        // 46.62 GiB / 48 GiB —— 与同一时刻 `top` 的 "PhysMem: 44G~47G used" 同量级。
        XCTAssertEqual(Double(used) / Double(total), 0.9714, accuracy: 0.001,
                       "换算成占比必须接近 top 的 PhysMem 口径")
    }

    func testMemoryUsedBytesCountsInactivePagesAsUsed() {
        // 与旧口径的关键差别：inactive 会体现在结果里（因为它是从 total 反减出来的，
        // 改变 inactive 而保持 free/spec/purgeable 不变时，总量假设不变 → 结果不变；
        // 反过来页数总和小于 total 时说明还有 inactive 之外的空间）。
        let total = UInt64(400_000_000)
        let baseline = memory(pageSize: 1_000, active: 100, inactive: 0, wired: 300,
                              compressed: 100, free: 50_000, speculative: 10, purgeable: 5)
        let withInactive = memory(pageSize: 1_000, active: 100, inactive: 715_260, wired: 300,
                                  compressed: 100, free: 50_000, speculative: 10, purgeable: 5)
        XCTAssertEqual(SystemSampler.memoryUsedBytes(baseline, totalBytes: total),
                       SystemSampler.memoryUsedBytes(withInactive, totalBytes: total),
                       "只改变 inactive 不得改变结果：inactive 不是靠加进来的，是靠「不在 free/spec/purgeable 里」算进来的")
        XCTAssertEqual(SystemSampler.memoryUsedBytes(withInactive, totalBytes: total),
                       total - 50_015_000 + 0,
                       "reclaimable = (50000+10+5)*1000")
    }

    func testMemoryUsedBytesFallsBackWhenReclaimableExceedsTotal() throws {
        // 页计数瞬时不一致（唤醒、休眠、计数器抖动）时必须退化成加法口径而不是下溢成天文数字。
        let counters = memory(pageSize: 16_384, active: 720_505, wired: 341_465,
                              compressed: 1_300_992, free: 9_000_000, speculative: 0, purgeable: 0)
        let used = try XCTUnwrap(SystemSampler.memoryUsedBytes(counters, totalBytes: 51_539_607_552),
                                 "可用读数必须算得出已用")
        let fallback = (720_505 + 341_465 + 1_300_992) * 16_384
        XCTAssertEqual(used, UInt64(fallback), "必须退化为 (active+wired+compressed)*pageSize")
        XCTAssertLessThanOrEqual(used, 51_539_607_552, "绝不得超过物理总量")
    }

    /// 这一条原来钉的是缺陷本身：`XCTAssertEqual(memoryUsedBytes(全 0 页计数, total), total)`，
    /// 注释写着「退化为全量已用而不是崩溃」。那次「退化」就是 WS-D 审计 P1 的根因——
    /// 一次内核调用失败被算成内存 100% 占满。现在缺证据由 `nil` 表达，两种不可能输入都判缺失。
    func testUnusablePageCountersYieldNoNumberInsteadOfFullMemory() {
        let total: UInt64 = 1_000_000
        let zeroPageSize = memory(pageSize: 0, active: 720_505, wired: 341_465, compressed: 1_300_992)
        XCTAssertNil(SystemSampler.memoryUsedBytes(zeroPageSize, totalBytes: total),
                     "页大小为 0 时所有字节换算都会塌成 0，绝不能返回「全量已用」")
        XCTAssertNil(SystemSampler.memoryUsedBytes(VmCounters(pageSize: 16_384), totalBytes: total),
                     "页计数全 0 == 没有读数，不是空闲页为 0")
        XCTAssertNil(SystemSampler.memoryUsedBytes(nil, totalBytes: total),
                     "缺读数必须原样传上去，不能在算术里被补成一个数")
        XCTAssertNil(SystemSampler.memoryUsedBytes(VmCounters(pageSize: 16_384, active: 1), totalBytes: 0),
                     "总量为 0 时占比无意义，不得给数")
    }

    // MARK: - 3. SystemSampler.bytesPerSecond

    func testBytesPerSecondDividesDeltaByElapsed() {
        XCTAssertEqual(SystemSampler.bytesPerSecond(previous: 1_000, current: 5_000, elapsed: 2), 2_000,
                       "(5000-1000)/2 必须是 2000")
        XCTAssertEqual(SystemSampler.bytesPerSecond(previous: 0, current: 1_500, elapsed: 1.5), 1_000,
                       "非整数秒同样按秒均分")
    }

    func testBytesPerSecondIsZeroWhenElapsedIsNotPositive() {
        XCTAssertEqual(SystemSampler.bytesPerSecond(previous: 1_000, current: 5_000, elapsed: 0), 0,
                       "elapsed 为 0 必须返回 0 而不是除零")
        XCTAssertEqual(SystemSampler.bytesPerSecond(previous: 1_000, current: 5_000, elapsed: -3), 0,
                       "elapsed 为负必须返回 0")
    }

    func testBytesPerSecondIsZeroWhenCurrentIsSmallerThanPrevious() {
        XCTAssertEqual(SystemSampler.bytesPerSecond(previous: 5_000, current: 1_000, elapsed: 2), 0,
                       "计数器回绕必须返回 0 而不是 UInt64 下溢")
    }

    func testBytesPerSecondIsZeroWhenCountersAreEqual() {
        XCTAssertEqual(SystemSampler.bytesPerSecond(previous: 4_242_424, current: 4_242_424, elapsed: 1.5), 0,
                       "没有增量时必须是 0")
    }

    // MARK: - 3b. 网卡 32 位计数回绕

    func testWrapHandlingRestoresDeltaAcrossThe32BitBoundary() {
        let wrapPoint = UInt64(UInt32.max) + 1
        // 上一帧 4_290_000_000，本帧跨 4 GiB 归零后剩 5_000_000 → 真实增量 = (2^32 - 前) + 后
        let rate = SystemSampler.bytesPerSecondHandling32BitWrap(
            previous: 4_290_000_000, current: 5_000_000, elapsed: 2)
        let expected = Double((wrapPoint - 4_290_000_000) + 5_000_000) / 2
        XCTAssertEqual(Double(rate), expected, accuracy: 1, "跨零点必须补一个 2^32 还原增量，而不是报假 0")
        XCTAssertGreaterThan(rate, 0)
    }

    func testWrapHandlingRejectsImplausibleJumpAndKeepsPlainDifference() {
        // previous 很小却突然归零 → 补 2^32 会得出 4 TB/ms 的假速率，判定为计数器重置，退回 0。
        XCTAssertEqual(
            SystemSampler.bytesPerSecondHandling32BitWrap(
                previous: 1_000, current: 0, elapsed: 0.001),
            0, "还原出的速率不合理时必须退回 0")
        XCTAssertEqual(SystemSampler.bytesPerSecondHandling32BitWrap(previous: 1_000, current: 5_000, elapsed: 2),
                       2_000, "current >= previous 时等价于普通 bytesPerSecond")
        XCTAssertEqual(SystemSampler.bytesPerSecondHandling32BitWrap(previous: 5_000, current: 1_000, elapsed: 0),
                       0, "elapsed 非正一律 0")
        XCTAssertGreaterThan(SystemSampler.plausibleMaxBytesPerSecond, 1_000_000_000,
                             "合理上限至少要高于万兆网卡的字节速率")
    }

    // MARK: - 4. SystemSampler.pressure

    func testPressureBelowWarningThresholdIsNormal() {
        XCTAssertEqual(SystemSampler.pressure(for: 0), .normal, "0 必须是正常")
        XCTAssertEqual(SystemSampler.pressure(for: 0.5), .normal, "0.5 必须是正常")
        XCTAssertEqual(SystemSampler.pressure(for: 0.699), .normal, "0.699 必须仍是正常")
    }

    func testPressureAtOrAboveSeventyPercentIsWarning() {
        XCTAssertEqual(SystemSampler.pressure(for: 0.7), .warning, "0.7 是 warning 闭区间下界")
        XCTAssertEqual(SystemSampler.pressure(for: 0.849), .warning, "0.849 必须仍是 warning")
    }

    func testPressureAtOrAboveEightyFivePercentIsCritical() {
        XCTAssertEqual(SystemSampler.pressure(for: 0.85), .critical, "0.85 是 critical 闭区间下界")
        XCTAssertEqual(SystemSampler.pressure(for: 1.0), .critical, "1.0 必须是紧张")
    }

    func testPressureDoesNotTrapOnOutOfRangeInput() {
        for fraction in [-0.5, -1_000, 1.5, Double.infinity, .nan] {
            let pressure = SystemSampler.pressure(for: fraction)
            XCTAssertTrue(MemoryPressure.allCases.contains(pressure),
                          "越界输入 \(fraction) 必须返回合法档位而不是崩溃（放宽，见文件头第 3 条）")
        }
    }

    // MARK: - 5. snapshot(previous: nil)

    // MARK: - 6. snapshot(previous: current:)

    // MARK: - 7. ProcessInspector.cpuUsage

    // MARK: - 8. ProcessInspector.matches

    // MARK: - 9. ProcessInspector.groupSnapshots

    // MARK: - 10. PerformanceHistory

    // MARK: - 11. 真实读取的结构合理性烟测（不断言任何具体数值）

    // MARK: - 12. MachSystemMonitor 烟测（@MainActor）
}

// MARK: - 9) ~ 12) 快照派生 / 分组聚合 / 历史容量 / MachSystemMonitor 烟测
//
// 这两段已各成一个文件（WS-X3 TestSplit，用例本体一字未改）：
// `PerformanceSamplerTests+SnapshotAndGroups.swift`、`PerformanceSamplerTests+MonitorLifecycle.swift`。
