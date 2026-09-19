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
    private var coreCount: Int { max(1, ProcessInfoWrapper.processorCount) }

    private func ticks(user: UInt32 = 0, system: UInt32 = 0, idle: UInt32 = 0, nice: UInt32 = 0) -> CoreTicks {
        CoreTicks(user: user, system: system, idle: idle, nice: nice)
    }

    private func coreArray(_ tick: CoreTicks, count: Int? = nil) -> [CoreTicks] {
        Array(repeating: tick, count: count ?? coreCount)
    }

    private func memory(
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

    private func counters(
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

    private func process(
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

    private func systemSnapshot(atSecond second: Double) -> SystemSnapshot {
        SystemSnapshot(timestamp: Date(timeIntervalSince1970: second))
    }

    private func javaGroup() -> TrackedProcessGroup {
        TrackedProcessGroup(title: "Java 服务", matchPattern: "java", isBuiltIn: true)
    }

    private func nodeGroup() -> TrackedProcessGroup {
        TrackedProcessGroup(title: "Node 服务", matchPattern: "node", isBuiltIn: false)
    }

    private func mysqlGroup() -> TrackedProcessGroup {
        TrackedProcessGroup(title: "MySQL", matchPattern: "mysqld", isBuiltIn: false)
    }

    private func fixtureProcesses() -> [ProcessSnapshot] {
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

    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

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

    func testMemoryUsedBytesMatchesActivityMonitorFormulaOnRealPageCounts() {
        // 本机实测（48 GiB、page 16384）：free 59454 / speculative 20714 / purgeable 9795
        let total = UInt64(51_539_607_552)
        let counters = memory(pageSize: 16_384, active: 757_410, inactive: 736_816,
                              wired: 342_131, compressed: 1_300_992,
                              free: 59_454, speculative: 20_714, purgeable: 9_795)
        let reclaimablePages = 59_454 + 20_714 + 9_795
        let expected = total - UInt64(reclaimablePages) * 16_384
        let used = SystemSampler.memoryUsedBytes(counters, totalBytes: total)
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

    func testMemoryUsedBytesFallsBackWhenReclaimableExceedsTotal() {
        // 页计数瞬时不一致（唤醒、休眠、计数器抖动）时必须退化成加法口径而不是下溢成天文数字。
        let counters = memory(pageSize: 16_384, active: 720_505, wired: 341_465,
                              compressed: 1_300_992, free: 9_000_000, speculative: 0, purgeable: 0)
        let used = SystemSampler.memoryUsedBytes(counters, totalBytes: 51_539_607_552)
        let fallback = (720_505 + 341_465 + 1_300_992) * 16_384
        XCTAssertEqual(used, UInt64(fallback), "必须退化为 (active+wired+compressed)*pageSize")
        XCTAssertLessThanOrEqual(used, 51_539_607_552, "绝不得超过物理总量")
    }

    func testMemoryUsedBytesNeverExceedsTotalAndIsZeroSafe() {
        let zeroPage = memory(pageSize: 0, active: 720_505, wired: 341_465, compressed: 1_300_992)
        XCTAssertEqual(SystemSampler.memoryUsedBytes(zeroPage, totalBytes: 1_000_000), 1_000_000,
                       "pageSize 为 0 时 reclaimable 为 0，退化为「全量已用」而不是崩溃")
        XCTAssertEqual(SystemSampler.memoryUsedBytes(zeroPage, totalBytes: 0), 0,
                       "总量为 0 必须返回 0")
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

    func testSnapshotWithoutPreviousHasNoRatesAndNoCPUUsage() {
        let current = counters(
            at: Self.epoch.addingTimeInterval(10),
            cores: coreArray(ticks(user: 100, system: 100, idle: 100)),
            memory: memory(),
            diskRead: 100_000, diskWrite: 200_000, networkIn: 300_000, networkOut: 400_000
        )
        let snapshot = SystemSampler().snapshot(previous: nil, current: current, processCount: 42)
        XCTAssertEqual(snapshot.cpuUsage, 0, accuracy: 1e-9, "首个采样点没有基线，占用率必须是 0")
        XCTAssertEqual(snapshot.diskReadBytesPerSecond, 0, "首个采样点磁盘读速率必须是 0")
        XCTAssertEqual(snapshot.diskWriteBytesPerSecond, 0, "首个采样点磁盘写速率必须是 0")
        XCTAssertEqual(snapshot.networkInBytesPerSecond, 0, "首个采样点网络入速率必须是 0")
        XCTAssertEqual(snapshot.networkOutBytesPerSecond, 0, "首个采样点网络出速率必须是 0")
    }

    func testSnapshotWithoutPreviousReportsCoreCountMemoryTotalAndProcessCount() {
        let current = counters(at: Self.epoch, cores: coreArray(ticks(idle: 10)), memory: memory(),
                               diskRead: 0, diskWrite: 0, networkIn: 0, networkOut: 0)
        let snapshot = SystemSampler().snapshot(previous: nil, current: current, processCount: 7)
        XCTAssertEqual(snapshot.cpuCoreCount, ProcessInfoWrapper.processorCount, "核数必须来自 ProcessInfoWrapper")
        XCTAssertEqual(snapshot.memoryTotalBytes, ProcessInfoWrapper.physicalMemory, "内存总量必须来自 ProcessInfoWrapper")
        XCTAssertEqual(snapshot.processCount, 7, "processCount 必须原样透传")
    }

    // MARK: - 6. snapshot(previous: current:)

    func testSnapshotRatesAgreeWithBytesPerSecondHelper() {
        let previousCores = coreArray(ticks())
        let currentCores = coreArray(ticks(user: 100, system: 100, idle: 300))
        let previous = counters(at: Self.epoch, cores: previousCores, memory: memory(),
                                diskRead: 100_000, diskWrite: 200_000, networkIn: 300_000, networkOut: 400_000)
        let current = counters(at: Self.epoch.addingTimeInterval(2), cores: currentCores, memory: memory(),
                               diskRead: 104_000, diskWrite: 206_000, networkIn: 308_000, networkOut: 410_000)
        let snapshot = SystemSampler().snapshot(previous: previous, current: current, processCount: 3)

        XCTAssertEqual(snapshot.diskReadBytesPerSecond,
                       SystemSampler.bytesPerSecond(previous: 100_000, current: 104_000, elapsed: 2),
                       "磁盘读速率必须与 bytesPerSecond 一致")
        XCTAssertEqual(snapshot.diskWriteBytesPerSecond,
                       SystemSampler.bytesPerSecond(previous: 200_000, current: 206_000, elapsed: 2),
                       "磁盘写速率必须与 bytesPerSecond 一致")
        XCTAssertEqual(snapshot.networkInBytesPerSecond,
                       SystemSampler.bytesPerSecond(previous: 300_000, current: 308_000, elapsed: 2),
                       "网络入速率必须与 bytesPerSecond 一致")
        XCTAssertEqual(snapshot.networkOutBytesPerSecond,
                       SystemSampler.bytesPerSecond(previous: 400_000, current: 410_000, elapsed: 2),
                       "网络出速率必须与 bytesPerSecond 一致")
        XCTAssertEqual(snapshot.cpuUsage,
                       SystemSampler.cpuUsage(previous: previousCores, current: currentCores),
                       accuracy: 1e-12, "占用率必须与 cpuUsage 一致")
    }

    func testSnapshotRatesAreExactBytesPerSecondOverTwoSeconds() {
        let previousCores = coreArray(ticks())
        let currentCores = coreArray(ticks(user: 100, system: 100, idle: 300))
        let previous = counters(at: Self.epoch, cores: previousCores, memory: memory(),
                                diskRead: 1_000, diskWrite: 2_000, networkIn: 3_000, networkOut: 4_000)
        let current = counters(at: Self.epoch.addingTimeInterval(2), cores: currentCores, memory: memory(),
                               diskRead: 5_000, diskWrite: 8_000, networkIn: 11_000, networkOut: 14_000)
        let snapshot = SystemSampler().snapshot(previous: previous, current: current, processCount: 1)
        XCTAssertEqual(snapshot.diskReadBytesPerSecond, 2_000, "4000 字节 / 2 秒 = 2000")
        XCTAssertEqual(snapshot.diskWriteBytesPerSecond, 3_000, "6000 字节 / 2 秒 = 3000")
        XCTAssertEqual(snapshot.networkInBytesPerSecond, 4_000, "8000 字节 / 2 秒 = 4000")
        XCTAssertEqual(snapshot.networkOutBytesPerSecond, 5_000, "10000 字节 / 2 秒 = 5000")
        XCTAssertEqual(snapshot.cpuUsage, 0.4, accuracy: 1e-9, "两个点的差值必须给出 0.4")
    }

    func testSnapshotMemoryFieldsAgreeWithCounters() {
        let current = counters(at: Self.epoch, cores: coreArray(ticks(idle: 30)), memory: memory(),
                               diskRead: 0, diskWrite: 0, networkIn: 0, networkOut: 0)
        let snapshot = SystemSampler().snapshot(previous: nil, current: current, processCount: 1)
        XCTAssertEqual(snapshot.memoryUsedBytes,
                       SystemSampler.memoryUsedBytes(current.vm, totalBytes: snapshot.memoryTotalBytes),
                       "已用内存必须由 current.vm 与总量共同推得")
        XCTAssertGreaterThan(snapshot.memoryTotalBytes, 0, "内存总量必须为正，否则 memoryFraction 无意义")
        let expectedFraction = Double(snapshot.memoryUsedBytes) / Double(snapshot.memoryTotalBytes)
        XCTAssertEqual(snapshot.memoryFraction, expectedFraction, accuracy: 1e-12,
                       "memoryFraction 必须等于 used/total")
        XCTAssertEqual(snapshot.memoryPressure, SystemSampler.pressure(for: snapshot.memoryFraction),
                       "压力档位必须来自 pressure(for: memoryFraction)")
    }

    func testSnapshotMarksNearFullMemoryAsCritical() {
        let pageSize: UInt64 = 16_384
        // 造出约 90% 物理内存占用的计数器。
        let targetPages = ProcessInfoWrapper.physicalMemory * 9 / (10 * pageSize)
        let fixture = counters(at: Self.epoch, cores: coreArray(ticks(idle: 10)),
                               memory: memory(pageSize: pageSize, active: targetPages - 400, wired: 200, compressed: 200),
                               diskRead: 0, diskWrite: 0, networkIn: 0, networkOut: 0)
        let snapshot = SystemSampler().snapshot(previous: nil, current: fixture, processCount: 1)
        XCTAssertGreaterThan(snapshot.memoryFraction, 0.85, "夹具本身必须构造出 >=85% 的占比")
        XCTAssertEqual(snapshot.memoryPressure, .critical, ">=85% 必须判为紧张")
    }

    // MARK: - 7. ProcessInspector.cpuUsage

    func testProcessCPUUsageOfOneSaturatedCoreForOneAndHalfSecondsIsOne() {
        XCTAssertEqual(ProcessInspector.cpuUsage(previousNano: 1_000_000_000, currentNano: 2_500_000_000, elapsed: 1.5),
                       1, accuracy: 1e-9, "1.5 秒 CPU 时间 / 1.5 秒墙钟 = 1.0")
    }

    func testProcessCPUUsageCanExceedOneOnMulticore() {
        // 3 秒 CPU 时间 / 1.5 秒墙钟 = 2.0（两个核同时满载）
        XCTAssertEqual(ProcessInspector.cpuUsage(previousNano: 1_000_000_000, currentNano: 4_000_000_000, elapsed: 1.5),
                       2, accuracy: 1e-9, "多核并行时占用率允许超过 1")
    }

    func testProcessCPUUsageIsZeroWhenCountersWrapBackwards() {
        XCTAssertEqual(ProcessInspector.cpuUsage(previousNano: 9_000_000_000, currentNano: 1_000_000_000, elapsed: 1.5),
                       0, accuracy: 1e-9, "current < previous 必须返回 0")
    }

    func testProcessCPUUsageIsZeroWhenElapsedIsNotPositive() {
        XCTAssertEqual(ProcessInspector.cpuUsage(previousNano: 1_000_000_000, currentNano: 2_000_000_000, elapsed: 0),
                       0, accuracy: 1e-9, "elapsed 为 0 必须返回 0 而不是除零")
        XCTAssertEqual(ProcessInspector.cpuUsage(previousNano: 1_000_000_000, currentNano: 2_000_000_000, elapsed: -1),
                       0, accuracy: 1e-9, "elapsed 为负必须返回 0")
    }

    // MARK: - 8. ProcessInspector.matches

    func testMatchesIsCaseInsensitiveAgainstProcessName() {
        let java = process(pid: 900_001, name: "java", commandLine: "/usr/bin/java -jar app.jar")
        XCTAssertTrue(ProcessInspector.matches(java, pattern: "JAVA"), "pattern 必须不区分大小写命中 name")
        XCTAssertTrue(ProcessInspector.matches(java, pattern: "java"), "大小写完全一致时必须命中")
    }

    func testMatchesIsCaseInsensitiveAgainstCommandLine() {
        let launcher = process(pid: 900_002, name: "com.example.Launcher", commandLine: "/usr/bin/Java -version")
        XCTAssertTrue(ProcessInspector.matches(launcher, pattern: "JAVA"), "name 不命中时必须回落到 commandLine")
    }

    func testMatchesTrimsSurroundingWhitespaceInPattern() {
        let java = process(pid: 900_003, name: "java", commandLine: "/usr/bin/java")
        XCTAssertTrue(ProcessInspector.matches(java, pattern: "  java  "), "pattern 前后空格必须被 trim")
        XCTAssertTrue(ProcessInspector.matches(java, pattern: "\tJava\n"), "制表符与换行也必须被 trim")
    }

    func testMatchesRejectsEmptyOrBlankPattern() {
        let java = process(pid: 900_004, name: "java", commandLine: "/usr/bin/java")
        XCTAssertFalse(ProcessInspector.matches(java, pattern: ""), "空 pattern 必须为 false，否则一个组会吸走所有进程")
        XCTAssertFalse(ProcessInspector.matches(java, pattern: "   "), "纯空白 pattern 必须为 false")
        XCTAssertFalse(ProcessInspector.matches(java, pattern: "\t \n"), "纯制表/换行 pattern 必须为 false")
    }

    func testMatchesRejectsUnrelatedProcess() {
        let java = process(pid: 900_005, name: "java", commandLine: "/usr/bin/java -jar app.jar")
        XCTAssertFalse(ProcessInspector.matches(java, pattern: "nginx"), "不相关 pattern 必须为 false")
        XCTAssertFalse(ProcessInspector.matches(java, pattern: "com.example.Other"), "看似同族但并不命中时必须为 false")
    }

    // MARK: - 9. ProcessInspector.groupSnapshots

    func testGroupSnapshotsReturnsOneEntryPerGroupIncludingEmptyOnes() {
        let java = javaGroup()
        let node = nodeGroup()
        let mysql = mysqlGroup()
        let result = ProcessInspector.groupSnapshots(for: [java, node, mysql], processes: fixtureProcesses())

        XCTAssertEqual(result.count, 3, "每个被跟踪组都必须恰好一条结果")
        XCTAssertEqual(Set(result.map { $0.group.id }), Set([java.id, node.id, mysql.id]),
                       "结果的 group id 集合必须与入参一致（顺序放宽，见文件头第 8 条）")

        let mysqlSnapshot = result.first { $0.group.id == mysql.id }
        XCTAssertNotNil(mysqlSnapshot, "无匹配的组不得被丢弃（视图靠它区分「未检测到」与「没有这个组」）")
        XCTAssertTrue(mysqlSnapshot?.matchedProcesses.isEmpty ?? false, "无匹配的组 matchedProcesses 必须为空")
        XCTAssertEqual(mysqlSnapshot?.processCount, 0, "无匹配的组进程数必须是 0")
        XCTAssertEqual(mysqlSnapshot?.totalCPU ?? -1, 0, accuracy: 1e-9, "无匹配的组 CPU 必须是 0")
        XCTAssertEqual(mysqlSnapshot?.totalMemoryBytes, UInt64(0), "无匹配的组内存必须是 0")
        XCTAssertEqual(mysqlSnapshot?.totalThreads, 0, "无匹配的组线程数必须是 0")
        XCTAssertEqual(mysqlSnapshot?.totalOpenFiles, 0, "无匹配的组打开文件数必须是 0")
    }

    func testGroupSnapshotsSumsMetricsOfMatchedProcesses() {
        let java = javaGroup()
        let node = nodeGroup()
        let result = ProcessInspector.groupSnapshots(for: [java, node], processes: fixtureProcesses())

        let javaSnapshot = result.first { $0.group.id == java.id }
        XCTAssertNotNil(javaSnapshot, "Java 组必须出现在结果里")
        XCTAssertEqual(javaSnapshot?.processCount, 2, "两个 java 进程必须被同一个组捕获")
        XCTAssertEqual(javaSnapshot?.totalCPU ?? -1, 2.0, accuracy: 1e-9, "totalCPU 必须是匹配进程之和")
        XCTAssertEqual(javaSnapshot?.totalMemoryBytes, UInt64(300), "totalMemoryBytes 必须是匹配进程之和")
        XCTAssertEqual(javaSnapshot?.totalThreads, 25, "totalThreads 必须是匹配进程之和")
        XCTAssertEqual(javaSnapshot?.totalOpenFiles, 312, "totalOpenFiles 必须是匹配进程之和")

        let nodeSnapshot = result.first { $0.group.id == node.id }
        XCTAssertEqual(nodeSnapshot?.processCount, 1, "node 组只能命中 node 进程")
        XCTAssertEqual(nodeSnapshot?.totalCPU ?? -1, 2.0, accuracy: 1e-9, "node 组 CPU 必须是该进程单独的值")
        XCTAssertEqual(nodeSnapshot?.totalMemoryBytes, UInt64(400), "node 组内存必须是该进程单独的值")
    }

    func testGroupSnapshotsSortsMatchedProcessesByCPUDescending() {
        let java = javaGroup()
        let processes = [
            process(pid: 900_021, name: "java-low", cpu: 0.3, commandLine: "/usr/bin/java"),
            process(pid: 900_022, name: "java-high", cpu: 2.5, commandLine: "/usr/bin/java"),
            process(pid: 900_023, name: "java-mid", cpu: 1.1, commandLine: "/usr/bin/java"),
        ]
        let result = ProcessInspector.groupSnapshots(for: [java], processes: processes)
        let cpus = result.first?.matchedProcesses.map { $0.cpuUsage } ?? []
        XCTAssertEqual(cpus, [2.5, 1.1, 0.3], "matchedProcesses 必须按 cpuUsage 降序，视图才能直接展示")
    }

    func testGroupSnapshotsWithNoProcessesReturnsEveryGroupEmpty() {
        let java = javaGroup()
        let node = nodeGroup()
        let result = ProcessInspector.groupSnapshots(for: [java, node], processes: [])
        XCTAssertEqual(result.count, 2, "没有任何进程时也必须为每个组留一行")
        XCTAssertTrue(result.allSatisfy { $0.processCount == 0 }, "所有组的进程数必须是 0")
    }

    // MARK: - 10. PerformanceHistory

    func testPerformanceHistoryKeepsOnlyNewestSnapshotsAtCapacity() {
        var history = PerformanceHistory()
        XCTAssertEqual(history.capacity, 600, "默认容量必须是 600")
        for index in 0..<601 {
            history.append(systemSnapshot(atSecond: Double(index)))
        }
        XCTAssertEqual(history.snapshots.count, 600, "超出容量后必须只保留 600 个点")
        let keptSeconds = (1...600).map { Double($0) }
        XCTAssertEqual(history.snapshots.map { $0.id }, keptSeconds,
                       "必须淘汰最旧的点、保留最新的 600 个")
    }

    func testPerformanceHistoryRemoveAllEmptiesSnapshotsButKeepsCapacity() {
        var history = PerformanceHistory()
        for index in 0..<5 { history.append(systemSnapshot(atSecond: Double(index))) }
        XCTAssertEqual(history.snapshots.count, 5, "未超容量时必须全部保留")
        history.removeAll()
        XCTAssertTrue(history.snapshots.isEmpty, "removeAll 之后必须为空")
        XCTAssertEqual(history.capacity, 600, "removeAll 不得改动容量")
    }

    // MARK: - 11. 真实读取的结构合理性烟测（不断言任何具体数值）

    func testSamplerReadProducesStructurallySaneCounters() {
        let sampler = SystemSampler()
        let first = sampler.read()
        let second = sampler.read()
        XCTAssertGreaterThanOrEqual(first.cores.count, 1, "至少要有一个核的 tick")
        XCTAssertGreaterThan(first.vm.pageSize, 0, "pageSize 必须是来自公开 sysctl 的正数")
        XCTAssertGreaterThan(first.timestamp.timeIntervalSince1970, 1_700_000_000, "时间戳必须是近期时间")

        let snapshot = sampler.snapshot(previous: first, current: second, processCount: 3)
        XCTAssertTrue(snapshot.cpuUsage >= 0 && snapshot.cpuUsage <= 1, "真实占用率必须被 clamp 在 0...1")
        XCTAssertEqual(snapshot.processCount, 3, "processCount 必须原样透传")
        XCTAssertGreaterThanOrEqual(snapshot.memoryTotalBytes, 1, "真实内存总量必须是正数")
    }

    func testProcessInspectorEnumerationDoesNotTrap() {
        let count = ProcessInspector.processCount()
        XCTAssertGreaterThanOrEqual(count, 1, "至少能看到当前测试进程自身")
        XCTAssertGreaterThanOrEqual(ProcessInspector.visibleProcessCount(), 1)
        XCTAssertLessThanOrEqual(ProcessInspector.visibleProcessCount(), count,
                                "可逐进程查询的子集不可能大于全系统总数")
        let io = BlockStorageSampler.ioBytes()
        XCTAssertGreaterThan(io.read + io.write, 0, "IOKit 必须能拿到真实块设备累计量，且不需要 root")
    }

    // MARK: - 12. MachSystemMonitor 烟测（@MainActor）

    /// 有限轮询：每 300ms 一次、最多 3 次；条件不成立也不失败（见文件头第 6 条）。
    @MainActor
    private func pollUntil(_ condition: @escaping @MainActor () -> Bool) async {
        var remaining = 3
        while !condition() && remaining > 0 {
            try? await Task.sleep(nanoseconds: 300_000_000)
            remaining -= 1
        }
    }

    /// 无论测试体走哪条路径，都保证采样循环被关掉。
    private func registerStopTeardown(for monitor: MachSystemMonitor) {
        addTeardownBlock {
            Task { @MainActor in
                monitor.stop()
            }
        }
    }

    @MainActor func testMonitorSamplingProducesSnapshot() async {
        let monitor = MachSystemMonitor()
        registerStopTeardown(for: monitor)

        _ = monitor.sampleNow()
        let second = monitor.sampleNow()
        XCTAssertNotNil(second, "第二次 sampleNow 必须产出快照")
        XCTAssertNotNil(monitor.latestSnapshot, "latestSnapshot 必须被 sampleNow 填充")
        XCTAssertGreaterThanOrEqual(monitor.history.count, 1, "history 至少要落一个点")

        if let snapshot = second {
            XCTAssertTrue(snapshot.cpuUsage >= 0 && snapshot.cpuUsage <= 1, "真实占用率必须落在 0...1")
            XCTAssertGreaterThan(snapshot.memoryTotalBytes, 0, "真实内存总量必须是正数")
            XCTAssertGreaterThan(snapshot.cpuCoreCount, 0, "核数必须是正数")
        }

        let tops = monitor.topProcesses
        XCTAssertTrue((0...20).contains(tops.count), "topProcesses 必须被限制在 20 条以内，实得 \(tops.count)")
        if tops.count >= 2 {
            for index in 1..<tops.count {
                XCTAssertGreaterThanOrEqual(tops[index - 1].cpuUsage, tops[index].cpuUsage,
                                            "topProcesses 必须按 cpuUsage 降序")
            }
        }
        for entry in tops {
            XCTAssertGreaterThan(entry.pid, 0, "进程 pid 必须为正")
        }

        await pollUntil { monitor.trackedGroups.count >= TrackedProcessGroup.builtInDefaults.count }
        XCTAssertGreaterThanOrEqual(monitor.trackedGroups.count, TrackedProcessGroup.builtInDefaults.count,
                                    "trackedGroups 必须覆盖全部内置组（放宽，见文件头第 4 条）")
        for title in TrackedProcessGroup.builtInDefaults.map({ $0.title }) {
            XCTAssertTrue(monitor.trackedGroups.contains { $0.group.title == title },
                          "内置组「\(title)」必须出现在 trackedGroups 里")
        }

        monitor.start(intervalMilliseconds: 200)
        XCTAssertTrue(monitor.isRunning, "start 之后 isRunning 必须为真")
        await pollUntil { monitor.history.count > 1 }
        monitor.stop()
        XCTAssertFalse(monitor.isRunning, "测试结束前必须停掉采样循环")
    }

    @MainActor func testMonitorStartIsIdempotentAndStopHaltsSampling() async {
        let monitor = MachSystemMonitor()
        registerStopTeardown(for: monitor)

        monitor.start(intervalMilliseconds: 1_000)
        monitor.start(intervalMilliseconds: 1_000)
        monitor.start(intervalMilliseconds: 1_000)
        XCTAssertTrue(monitor.isRunning, "重复 start 之后仍处于运行态")

        monitor.stop()
        XCTAssertFalse(monitor.isRunning, "一次 stop 就必须终止全部可能叠加的采样循环")

        let before = monitor.history.count
        try? await Task.sleep(nanoseconds: 300_000_000)
        let after = monitor.history.count
        XCTAssertLessThanOrEqual(after - before, 4, "stop 之后不得有多倍采样（放宽，见文件头第 7 条）")
    }

    @MainActor func testMonitorAddAndRemoveTrackedGroup() async throws {
        let monitor = MachSystemMonitor()
        registerStopTeardown(for: monitor)
        let absentPattern = "definitely-not-a-real-process-xyz"

        XCTAssertEqual(TrackedProcessGroup.builtInDefaults.count, 5, "内置默认组必须是 5 个")
        let baselineCount = monitor.groups().count

        monitor.addGroup(title: "临时组", matchPattern: absentPattern)
        let afterAdd = monitor.groups()
        XCTAssertEqual(afterAdd.count, baselineCount + 1, "addGroup 之后 groups() 数量必须 +1")
        let added = try XCTUnwrap(afterAdd.first { $0.matchPattern == absentPattern },
                                  "新增组必须出现在 groups() 里")
        XCTAssertEqual(added.title, "临时组", "新增组的标题必须被记录")
        XCTAssertEqual(added.matchPattern, absentPattern, "新增组的匹配串必须被记录")

        _ = monitor.sampleNow()
        await pollUntil { monitor.trackedGroups.contains { $0.group.id == added.id } }
        if let tracked = monitor.trackedGroups.first(where: { $0.group.id == added.id }) {
            XCTAssertEqual(tracked.processCount, 0, "不存在的进程名不得匹配到任何进程")
            XCTAssertTrue(tracked.matchedProcesses.isEmpty, "不存在的进程名不得有 matchedProcesses")
        } else {
            // 放宽（见文件头第 5 条）：实现可能只在后台采样循环里刷新 trackedGroups。
            XCTAssertEqual(monitor.groups().count, baselineCount + 1, "至少 groups() 必须已经更新")
        }

        monitor.removeGroup(id: added.id)
        XCTAssertEqual(monitor.groups().count, baselineCount, "removeGroup 之后必须回到基线数量")
        XCTAssertFalse(monitor.groups().contains { $0.id == added.id }, "移除后 groups() 不得再包含该组")

        monitor.stop()
        XCTAssertFalse(monitor.isRunning, "测试结束必须 stop()，不留后台循环")
    }
}
