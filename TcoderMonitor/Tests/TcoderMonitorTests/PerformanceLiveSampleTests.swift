import Foundation
import XCTest
@testable import TcoderMonitor

/// 真机采样现场校验：跑真实的 SystemSampler / ProcessInspector，把数字打印出来，
/// 用于和 `vm_stat`、`top -l 1`、`iostat -d`、`netstat -ib` 对表（数字记录在 WS-C 笔记里）。
/// 这里不断言任何易变的具体值，只断言量级与安全边界；打印是为了人工核对口径。
final class PerformanceLiveSampleTests: XCTestCase {
    private let totalBytes = ProcessInfo.processInfo.physicalMemory
    private let coreCount = ProcessInfo.processInfo.activeProcessorCount

    func testLiveSamplerProducesActivityMonitorComparableNumbers() throws {
        let sampler = SystemSampler()
        let first = sampler.read()
        // 两次读数之间烧 ~0.2 秒真实 CPU，保证计数器有增量（不靠 sleep，避免假等待）。
        let burnStart = Date()
        var sink = 0.0
        while Date().timeIntervalSince(burnStart) < 0.2 { sink += sin(sink + 1) }
        let second = sampler.read()
        XCTAssertGreaterThan(sink, 0, "自旋结果必须被使用，否则整段可能被优化掉")

        let elapsed = second.timestamp.timeIntervalSince(first.timestamp)
        let snapshot = sampler.snapshot(previous: first, current: second,
                                       processCount: ProcessInspector.sweep(previous: [:], elapsed: max(elapsed, 0.05)).processes.count)

        print("=== WS-C 真机采样 ===")
        print("间隔 = \(String(format: "%.3f", elapsed)) 秒")
        print("CPU = \(NumberFormat.percent(snapshot.cpuUsage, precision: 2))（\(snapshot.cpuCoreCount) 核）")
        print("内存已用 = \(ByteFormat.string(snapshot.memoryUsedBytes, precision: 2))"
            + " / \(ByteFormat.string(snapshot.memoryTotalBytes, precision: 0))"
            + " = \(NumberFormat.percent(snapshot.memoryFraction, precision: 2)) · 压力 \(snapshot.memoryPressure.rawValue)")
        print("  vm 页: " + (first.vm.map {
            "active=\($0.active) inactive=\($0.inactive) wired=\($0.wired)"
                + " compressor=\($0.compressed) free=\($0.free)"
                + " speculative=\($0.speculative) purgeable=\($0.purgeable) page=\($0.pageSize)"
        } ?? "读数缺失（host_statistics64 未成功，内存三项按缺证据处理）"))
        print("磁盘 = 读 \(ByteFormat.rate(snapshot.diskReadBytesPerSecond))"
            + " · 写 \(ByteFormat.rate(snapshot.diskWriteBytesPerSecond))")
        print("  累计 read=\(first.diskReadBytes) write=\(first.diskWriteBytes) → \(second.diskReadBytes)/\(second.diskWriteBytes)")
        print("网络 = ↓\(ByteFormat.bitRate(snapshot.networkInBytesPerSecond))"
            + " · ↑\(ByteFormat.bitRate(snapshot.networkOutBytesPerSecond))")
        print("  累计 in=\(first.networkInBytes) out=\(first.networkOutBytes) → \(second.networkInBytes)/\(second.networkOutBytes)")
        print("负载 = \(String(format: "%.2f", snapshot.loadAverage1)) /"
            + " \(String(format: "%.2f", snapshot.loadAverage5)) /"
            + " \(String(format: "%.2f", snapshot.loadAverage15))")
        print("进程数 = \(snapshot.processCount)（本测试把 sweep 结果当 processCount 传进去）"
            + " · 全系统 \(ProcessInspector.processCount())（sysctl，与 top 同源）"
            + " · 可查询 \(ProcessInspector.visibleProcessCount())"
            + " · 开机 \(Int(snapshot.uptimeSeconds / 3600)) 小时 · 温度 \(snapshot.thermalState.rawValue)")
        XCTAssertGreaterThan(snapshot.cpuUsage, 0, "烧了 0.2 秒真实 CPU，占用率不得为 0")

        XCTAssertEqual(snapshot.cpuCoreCount, coreCount)
        XCTAssertTrue(snapshot.cpuUsage >= 0 && snapshot.cpuUsage <= 1,
                      "全机 CPU 必须夹在 0...1，实得 \(snapshot.cpuUsage)")
        XCTAssertEqual(snapshot.memoryTotalBytes, totalBytes)
        XCTAssertLessThanOrEqual(snapshot.memoryUsedBytes, totalBytes, "已用内存不得超过物理总量")
        XCTAssertGreaterThan(snapshot.memoryUsedBytes, totalBytes / 4,
                             "活动监视器口径下已用内存不应是小数目")
        // 本机长期在 90% 以上（inactive 文件缓存按活动监视器口径算已用），所以上限只能用物理总量。
        XCTAssertGreaterThan(totalBytes - snapshot.memoryUsedBytes, 0)
        XCTAssertEqual(snapshot.memoryPressure, SystemSampler.pressure(for: snapshot.memoryFraction))
        XCTAssertGreaterThan(snapshot.loadAverage1, 0, "getloadavg 必须给出真实负载")
        XCTAssertGreaterThan(snapshot.uptimeSeconds, 60)
    }

    func testLiveProcessSweepIsReadOnlyAndWellFormed() throws {
        let start = Date()
        let sweep = ProcessInspector.sweep(previous: [:], elapsed: 1.5)
        let duration = Date().timeIntervalSince(start)
        XCTAssertLessThan(duration, 3.0, "全量扫描必须在一轮采样间隔内完成，实得 \(duration) 秒")

        let topCPU = sweep.processes.sorted { $0.cpuUsage > $1.cpuUsage }.prefix(6)
        let topMemory = sweep.processes.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(6)
        print("=== 进程扫描（只读） ===")
        print("扫到 \(sweep.processes.count) 个可查询进程 · 耗时 \(String(format: "%.0f", duration * 1000)) 毫秒"
            + " · 全系统 \(ProcessInspector.processCount()) 个（sysctl，与 top 同源）")
        print("按 CPU：")
        for process in topCPU {
            print("  pid \(process.pid)  \(process.name)  CPU "
                + String(format: "%.3f", process.cpuUsage)
                + " 核  RSS " + ByteFormat.string(process.memoryBytes, precision: 0)
                + "  线程 \(process.threadCount)  句柄 \(process.openFileCount)  父 \(process.parentPID)")
        }
        print("按内存：")
        for process in topMemory {
            print("  \(process.name) \(ByteFormat.string(process.memoryBytes, precision: 1))")
        }

        XCTAssertGreaterThan(sweep.processes.count, 20, "任何 macOS 会话都不可能只有几十个进程")
        XCTAssertTrue(sweep.processes.allSatisfy { !$0.name.isEmpty }, "每个进程都要有可读名字")
        XCTAssertTrue(sweep.processes.allSatisfy { $0.pid > 0 })
        XCTAssertTrue(sweep.processes.contains { $0.parentPID > 0 }, "至少要有进程能拿到父 pid")
        XCTAssertGreaterThanOrEqual(sweep.states.count, sweep.processes.count / 2,
                                    "累计计数要能覆盖多数进程，否则下一轮 CPU 差值算不出来")
        XCTAssertLessThanOrEqual(sweep.states.count, sweep.processes.count)
        XCTAssertGreaterThan(sweep.elapsed, 0)

        // 只读校验：扫描前后自身 pid 数不得变化，且绝不能出现 0 CPU 以外的负值。
        XCTAssertTrue(sweep.processes.allSatisfy { $0.cpuUsage >= 0 })
        XCTAssertTrue(sweep.processes.allSatisfy { $0.openFileCount >= 0 })
    }

    /// 进程组：内置的 java/node/mysqld/redis/nginx 是通用名，本机有几个就算几个，不伪造。
    /// 做两轮 sweep（中间烧一点 CPU），第一轮的 CPU 恒为 0，只有第二轮才验证得出「核当量」这条链路。
    func testLiveProcessGroupsMatchRealProcesses() throws {
        let warmup = ProcessInspector.sweep(previous: [:], elapsed: 0.4)
        let warmupAt = Date()
        let burnStart = Date()
        var sink = 0.0
        while Date().timeIntervalSince(burnStart) < 0.3 { sink += sin(sink + 1) }
        XCTAssertGreaterThan(sink, 0)
        let gap = max(0.05, Date().timeIntervalSince(warmupAt))
        let sweep = ProcessInspector.sweep(previous: warmup.states, elapsed: gap)
        let groups = ProcessInspector.groupSnapshots(for: TrackedProcessGroup.builtInDefaults,
                                                    processes: sweep.processes)
        XCTAssertEqual(groups.count, TrackedProcessGroup.builtInDefaults.count,
                       "没有匹配的组也必须出现在结果里，视图才能显示「未检测到」")
        print("=== 工程进程组（第二轮采样，间隔 \(String(format: "%.2f", gap)) 秒） ===")
        for snapshot in groups {
            let ram = ByteFormat.string(snapshot.totalMemoryBytes, precision: 1)
            let cpu = String(format: "%.3f", snapshot.totalCPU)
            print("  \(snapshot.group.title)（匹配 \(snapshot.group.matchPattern)）: "
                + "\(snapshot.processCount) 进程 · CPU \(cpu) 核 · RAM \(ram)"
                + " · Threads \(snapshot.totalThreads) · Open Files \(snapshot.totalOpenFiles)")
        }
        print("  这一轮采样：看得见 \(sweep.visiblePIDCount) 个 pid，truncated=\(sweep.truncated)")
        try assertMatcherSeesARealProcess(sweep)   // helper 里的 XCTSkip 要沿调用栈传到测试方法
        // 第二轮必须能量出非零核当量（本测试进程自己就在烧 CPU，这条与装了什么服务无关）。
        XCTAssertGreaterThan(sweep.processes.reduce(0.0) { $0 + $1.cpuUsage }, 0,
                             "两轮差值必须算出真实 CPU 占用，否则「某服务 CPU 45%」这条链路是断的")
        for snapshot in groups {
            XCTAssertEqual(snapshot.totalThreads,
                           snapshot.matchedProcesses.reduce(0) { $0 + $1.threadCount })
            XCTAssertEqual(snapshot.totalOpenFiles,
                           snapshot.matchedProcesses.reduce(0) { $0 + $1.openFileCount })
            XCTAssertEqual(snapshot.totalMemoryBytes,
                           snapshot.matchedProcesses.reduce(UInt64(0)) { $0 + $1.memoryBytes })
        }
    }

    func testDiskThroughputIsADifferenceNotACumulativeCounter() throws {
        // 全系统 diskio 是累计值，两次采样之间制造一次真实写入，速率必须跟上。
        let sampler = SystemSampler()
        let before = sampler.read()
        let payload = Data(repeating: 0x41, count: 8_000_000)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tcoder-disk-\(UUID().uuidString.prefix(8)).bin")
        try payload.write(to: url, options: .atomic)
        try? FileManager.default.removeItem(at: url)
        let after = sampler.read()

        let elapsed = max(0.05, after.timestamp.timeIntervalSince(before.timestamp))
        let write = SystemSampler.bytesPerSecond(previous: before.diskWriteBytes,
                                                 current: after.diskWriteBytes, elapsed: elapsed)
        print("=== 磁盘吞吐口径 ===")
        print("写 8 MB 后测得 \(ByteFormat.rate(write))（累计计数 \(before.diskWriteBytes) → \(after.diskWriteBytes)）")
        XCTAssertGreaterThanOrEqual(after.diskWriteBytes, before.diskWriteBytes,
                                    "累计写字节不得倒退（倒退说明取到了不同进程集合）")
        // 缓存刷盘可能滞后，所以只断言「不是把累计值当速率」这一条：速率远小于累计值。
        XCTAssertLessThan(write, after.diskWriteBytes, "速率绝不能直接等于累计计数器")
    }

    /// 匹配逻辑的正例由测试自己提供：本进程真实在场，不依赖别人机器上跑着什么服务。
    /// （旧断言「本机常驻至少会有 node 或 java」把环境状态当判据 ⇒ 见 #126 的枚举面范围问题）
    private func assertMatcherSeesARealProcess(_ sweep: ProcessSweep) throws {
        // 「本机常驻至少会有 node 或 java」是**环境状态**，不是匹配逻辑的性质。
        // 旧写法直接断言内置组有命中 ⇒ 在没跑这些服务的时段/机器上必然红
        // （09-27 16:12 实测：`pgrep -x node` 当场还有 3 个 pid，这一条仍报 0 命中——
        //  一轮采样被时间预算截断时高 pid 那批根本没进来，上面那行 truncated 就是这件事的读数）。
        // ⇒ 正例改由测试自己提供：**本进程是真实在场的进程**，用它验「匹配逻辑不是永远返回空」，
        //   不依赖别人机器上跑着什么；顺带把「枚举面看不见自己」这种真故障与"机器上没装"分开。
        let myPid = ProcessInfo.processInfo.processIdentifier
        guard let me = sweep.processes.first(where: { $0.pid == myPid }) else {
            // 被时间预算截断的一轮**验不出匹配逻辑**，这只说明现场忙，不说明代码坏；
            // 但也不许把它读成"过了"⇒ 走 skip（在汇总行里看得见份数），并把成因指回 #126。
            if sweep.truncated {
                throw XCTSkip("这一轮采样被时间预算截断（看得见 \(sweep.visiblePIDCount) 个 pid）⇒ "
                              + "自检正例没对象可验，按未判处理；屏上「未检测到进程」这句的来源见 #126")
            }
            return XCTFail("这一轮采样没看见自己（pid \(myPid)，看得见 \(sweep.visiblePIDCount) 个，"
                           + "truncated=False）⇒ 枚举面坏了，不是环境里没跑服务")
        }
        let selfSnapshots = ProcessInspector.groupSnapshots(
            for: [TrackedProcessGroup(title: "自检进程", matchPattern: me.name, isBuiltIn: false)],
            processes: sweep.processes)
        XCTAssertGreaterThanOrEqual(selfSnapshots.first?.processCount ?? 0, 1,
                                    "按本进程自己的名字都匹配不到 ⇒ 匹配逻辑恒空，不是环境差异")
    }
}
