/// OWNER: WS-X3 TestSplit —— 自 PerformanceSamplerTests.swift 拆出，快照派生字段、进程 CPU、进程名匹配与分组聚合。用例本体未改，只是搬了家。
import XCTest
@testable import TcoderMonitor

extension PerformanceSamplerTests {

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

}
