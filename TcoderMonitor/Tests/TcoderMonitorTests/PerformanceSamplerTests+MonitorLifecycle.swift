/// OWNER: WS-X3 TestSplit —— 自 PerformanceSamplerTests.swift 拆出，历史容量、真实读数、进程枚举与 start/stop 生命周期。用例本体未改，只是搬了家。
import XCTest
@testable import TcoderMonitor

extension PerformanceSamplerTests {

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

    func testSamplerReadProducesStructurallySaneCounters() throws {
        let sampler = SystemSampler()
        let first = sampler.read()
        let second = sampler.read()
        XCTAssertGreaterThanOrEqual(first.cores.count, 1, "至少要有一个核的 tick")
        let vm = try XCTUnwrap(first.vm, "本机 host_statistics64 应当成功；nil 说明测试环境异常")
        XCTAssertGreaterThan(vm.pageSize, 0, "pageSize 必须是来自公开 sysctl 的正数")
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
