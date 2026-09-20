import Foundation
import XCTest
@testable import TcoderMonitor

/// §5.4 那两笔"没有毫秒数就不许动"的欠账，这里**只量、不设阈值**。
///
/// 【为什么必须有一个数】`ProjectStore` 是 `@MainActor`：`init()` 里同步 `load()` 解码，
/// `upsertReport` 里同步 `encode(.prettyPrinted + .sortedKeys)` + `.atomic` 写报告 + 写注册表，
/// 三笔全在主线程。而 T2 要的是"1.5 s 心跳期间主线程占用 ≤ 4.0 ms"——
/// 如果一次扫描收尾的持久化自己就有十几毫秒，这笔账必须先算进预算，
/// 不能因为它不发生在 tick 上就当它不存在。规范 §5.4 写的是"缺绝对值先不动持久化"，
/// 这一条就是去把那个绝对值拿回来。
///
/// 【为什么不做成阈值断言】计时断言在并发编译的机器上必然漂，
/// 而漂的后果是有人去把阈值调松——那正是本仓明令禁止的"为了让它过而放宽"。
/// 所以这个测试**永远不因慢而红**，它只负责产出可复现的量级读数。
///
/// 【夹具必须是真报告】尺寸直接决定结论：spec 里"单报告 29–43 KB"就是取证沙箱落盘的真报告。
/// 拿几 KB 的合成对象来量会得到"很便宜"的假安心，所以找不到真夹具时**跳过并说明找过哪里**。
@MainActor
final class PerfMainThreadBudgetTests: XCTestCase {

    private var isoEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]   // 与 ProjectStore 同配置
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private var isoDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// 单调毫秒（与 `FramePulse.monotonicSeconds` 同域：系统启动时钟，不受墙钟调整影响）。
    private func nowMs() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000.0 }

    private func timed(_ body: () throws -> Void) rethrows -> Double {
        let t0 = nowMs()
        try body()
        return nowMs() - t0
    }

    /// 取证沙箱里落盘的真实报告（`capture_pages_isolated.sh` 每跑一次留一份）。
    private func realReportURL() -> URL? {
        let sandboxes = ((try? FileManager.default.contentsOfDirectory(atPath: "/tmp")) ?? [])
            .filter { $0.hasPrefix("tcoder-capture-sandbox-") }
            .map { "/tmp/\($0)/reports" }
        for dir in sandboxes.sorted().reversed() {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for name in files where name.hasSuffix(".json") {
                let url = URL(fileURLWithPath: "\(dir)/\(name)")
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                if size >= 20_000 { return url }
            }
        }
        return nil
    }

    private func isolatedDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tcoder-perf-store-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertTrue(dir.path.hasPrefix(FileManager.default.temporaryDirectory.path),
                      "隔离目录必须落在临时目录下，否则会把读数写进用户真实状态")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func stats(_ values: [Double]) -> String {
        let s = values.sorted()
        let pct: (Double) -> Double = { s[min(s.count - 1, Int(Double(s.count) * $0))] }
        return "n=\(s.count) min=\(String(format: "%.2f", s.first ?? 0))"
            + " 中位=\(String(format: "%.2f", pct(0.5)))"
            + " p95=\(String(format: "%.2f", pct(0.95)))"
            + " max=\(String(format: "%.2f", s.last ?? 0)) ms"
    }

    // MARK: - 心跳那一拍的两半：后台派生 vs 主线程 publish（归因用，脱离 UI 也能测）
    //
    // T2 的判据是"1.5 s 心跳期间主线程占用 ≤ 4.0 ms"。xctrace 那把尺子要等安静窗口，
    // 但**归因的一半现在就能钉死**：一次心跳的成本 = 后台的 `PerfLeads.derive`（排序/切片/组匹配）
    // + 主线程的 publish（九格各写一次）。两半都能脱离 UI 单独计时。
    // 若 publish 只要零点几毫秒，4.0 ms 的预算就不可能被采集侧撑爆，
    // 剩下的唯一嫌疑人只能是**视图图重算**——即工单 §0.4 第 1 步那 16 处粗读点。
    func testHeartbeatSplitIsMeasuredNotGuessed() throws {
        let sweep = realisticSweep(900)          // 实测全机 sweep 260~920 进程，取上沿
        let snapshot = SystemSnapshot()
        let previous = SystemCounters()            // 有上一帧 ⇒ 差分量在场，走的才是真实分支
        let groups = (0..<12).map { TrackedProcessGroup(title: "服务 \($0)", matchPattern: "p\($0)") }
        let probe = ProcessCountProbe(count: 900, isSystemWide: true)

        var deriveCosts: [Double] = []
        for _ in 0..<15 {
            deriveCosts.append(timed({
                _ = PerfLeads.derive(previous: previous, snapshot: snapshot, sweep: sweep,
                                     totalProbe: probe, groups: groups, topLimit: 20)
            }))
        }

        // publish 半：九格各写一次**真的变了**的值（"同值不写"另有用例钉）。
        // 载荷取真实形状：两张 20 条榜单、一条 90 点曲线、一张组表、若干标量格。
        let leads = PerfLeads.derive(previous: previous, snapshot: snapshot, sweep: sweep,
                                     totalProbe: probe, groups: groups, topLimit: 20)
        let cpuCell = PerfCell<PerfCPULead>(.empty)
        let memoryCell = PerfCell<PerfMemoryLead>(.empty)
        let ratesCell = PerfCell<PerfRateLead>(.empty)
        let ledgerCell = PerfCell<PerfProcessLedger>(.empty)
        let pulseCell = PerfCell<PerfPulse>(.empty)
        let cpuRankCell = PerfCell<[ProcessSnapshot]>([])
        let memRankCell = PerfCell<[ProcessSnapshot]>([])
        let groupRankCell = PerfCell<[ProcessGroupSnapshot]>([])
        let curveCell = PerfCell<[SystemSnapshot]>([])
        var publishCosts: [Double] = []
        for round in 0..<15 {
            var shifted = snapshot
            shifted.cpuUsage = Double(round) / 100.0
            let curve = Array(repeating: shifted, count: 90)
            let groupsNow = leads.groups
            let cpuRank = leads.cpuRanking
            let memRank = leads.memoryRanking
            publishCosts.append(timed({
                cpuCell.apply(leads.cpu)
                memoryCell.apply(leads.memory)
                ratesCell.apply(leads.rates)
                ledgerCell.apply(leads.ledger)
                pulseCell.apply(PerfPulse(sampleAt: Date(), historyCount: round))
                cpuRankCell.apply(cpuRank)
                memRankCell.apply(memRank)
                groupRankCell.apply(groupsNow)
                curveCell.apply(curve)
            }))
        }

        let lines = [
            "sweep 规模 \(sweep.processes.count) 进程 / 分组 \(groups.count) 条（实测全机 sweep 260~920，取上沿）",
            "后台派生 derive()   \(stats(deriveCosts))   ← 不在主线程",
            "主线程 publish 九格 \(stats(publishCosts))   ← 这才是 T2 预算里的固定开销",
            "对照：spec T2 心跳期主线程占用 ≤ 4.0 ms",
            "口径：publish 若远小于 4 ms，则超预算的部分只能来自视图图重算（工单 §0.4 第 1 步）。"
                + "本测试不设阈值，只出归因用的量级。",
        ]
        let text = lines.joined(separator: "\n")
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("tcoder-perf-heartbeat-split.txt")
        try text.write(to: out, atomically: true, encoding: .utf8)
        print("【心跳归因】derive 中位 \(String(format: "%.2f", deriveCosts.sorted()[deriveCosts.count / 2])) ms（后台）"
            + " / publish 中位 \(String(format: "%.2f", publishCosts.sorted()[publishCosts.count / 2])) ms（主线程）"
            + "（完整读数落 \(out.path)）")
        XCTAssertEqual(deriveCosts.count, 15)
        XCTAssertEqual(publishCosts.count, 15)
        XCTAssertEqual(leads.cpuRanking.count, 20, "榜单必须是 20 条，否则 publish 是对空数组做无用功")
        XCTAssertFalse(leads.memoryRanking.isEmpty, "派生没产出榜单 = 夹具退化，读数无意义")
    }

    /// 真实形状的 sweep：PID / 名字 / 命令行 / 内存都不同，排序与组匹配才不会走在空集上。
    /// 写成显式循环 + 先算好各分量：`(0..<n).map { ProcessSnapshot(9 个带插值的实参) }`
    /// 会让类型检查器超时（实测报 "unable to type-check this expression in reasonable time"）。
    private func realisticSweep(_ count: Int) -> ProcessSweep {
        var processes: [ProcessSnapshot] = []
        processes.reserveCapacity(count)
        for i in 0..<count {
            let pid = Int32(1000 + i)
            let name = "proc-" + String(i % 97)
            let cpu = Double(i) * 0.37
            let memory = UInt64(i) * 4_096_000
            let start = Date(timeIntervalSince1970: 1_790_000_000 + Double(i))
            let command = "/usr/bin/proc-" + String(i) + " --flag " + String(i)
            processes.append(ProcessSnapshot(pid: pid, name: name, cpuUsage: cpu, memoryBytes: memory,
                                             threadCount: 1 + (i % 64), openFileCount: i % 256,
                                             startTime: start, commandLine: command, parentPID: 1))
        }
        return ProcessSweep(processes: processes, states: [:], elapsed: 1.5,
                            truncated: false, visiblePIDCount: count)
    }

    // MARK: - 主读数：持久化在主线程上花多少毫秒

    func testPersistenceMainThreadCostIsMeasuredNotGuessed() throws {
        guard let fixture = realReportURL() else {
            throw XCTSkip("找不到 ≥20 KB 的真报告夹具（找过 /tmp/tcoder-capture-sandbox-*/reports）"
                + "——先跑一次 scripts/capture_pages_isolated.sh 再来量；不用合成数据凑数")
        }
        let data = try Data(contentsOf: fixture)
        let report = try isoDecoder.decode(ProjectReport.self, from: data)
        XCTAssertNotNil(report.code, "夹具里没有 code 段，量的会是空报告，读数无意义")
        XCTAssertGreaterThanOrEqual(data.count, 20_000, "夹具太小（\(data.count) 字节），尺寸不真实")

        var encodeOnly: [Double] = []
        var writeOnly: [Double] = []
        var upsertFull: [Double] = []
        var decodeOne: [Double] = []
        let dir = try isolatedDirectory()

        for round in 0..<15 {
            encodeOnly.append(try timed({ _ = try self.isoEncoder.encode(report) }))
            let payload = try isoEncoder.encode(report)
            writeOnly.append(try timed({
                try payload.write(to: dir.appendingPathComponent("r-\(round).json"), options: .atomic)
            }))
            decodeOne.append(try timed({ _ = try self.isoDecoder.decode(ProjectReport.self, from: payload) }))

            // 产品自己的路径：写报告 + 写注册表（`upsertReport` 里两步都是主线程同步）
            let store = ProjectStore()
            store.storageDirectory = dir.appendingPathComponent("store-\(round)", isDirectory: true)
            try FileManager.default.createDirectory(at: store.storageDirectory, withIntermediateDirectories: true)
            let project = store.add(path: "/tmp/perf-budget-\(round)", name: "持久化量级", isDemo: false)
            var fresh = report
            fresh.project = project
            upsertFull.append(timed({ store.upsertReport(fresh) }))
        }

        /// 启动那一笔：`load()` 干的活就是"逐个读文件 + 解码"，这里同形状量，
        /// 不去动 `ProjectStore()` 的 init（它会读用户真实目录，读数会随机器状态漂）。
        let bootDir = dir.appendingPathComponent("boot", isDirectory: true)
        try FileManager.default.createDirectory(at: bootDir.appendingPathComponent("reports"),
                                               withIntermediateDirectories: true)
        var four: [URL] = []
        for i in 0..<4 {
            var one = report
            one.project = MonitoredProject(name: "启动第\(i)个", path: "/tmp/boot-\(i)", isDemo: false)
            let url = bootDir.appendingPathComponent("reports/\(one.project.id.uuidString).json")
            try isoEncoder.encode(one).write(to: url, options: .atomic)
            four.append(url)
        }
        var bootLoads: [Double] = []
        for _ in 0..<7 {
            bootLoads.append(try timed({
                for url in four {
                    let blob = try Data(contentsOf: url)
                    _ = try self.isoDecoder.decode(ProjectReport.self, from: blob)
                }
            }))
        }

        let lines = [
            "夹具 \(fixture.path)",
            "单报告字节数 \(data.count)",
            "encode only       \(stats(encodeOnly))",
            "atomic write      \(stats(writeOnly))",
            "upsertReport 全程 \(stats(upsertFull))  （写报告 + 写注册表，两步都在主线程）",
            "decode 单份       \(stats(decodeOne))",
            "启动 load(4 份)   \(stats(bootLoads))",
            "对照：spec T2 心跳期主线程占用预算 ≤ 4.0 ms；spec T4 冷启动 ≤ 1.0 s",
            "说明：本测试**不设阈值**（计时断言会逼人放宽阈值），只出量级读数。",
        ]
        let text = lines.joined(separator: "\n")
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("tcoder-perf-persistence.txt")
        try text.write(to: out, atomically: true, encoding: .utf8)
        print("【持久化主线程量级】upsert 中位 \(String(format: "%.2f", upsertFull.sorted()[upsertFull.count / 2])) ms"
            + " / 启动 4 份 中位 \(String(format: "%.2f", bootLoads.sorted()[bootLoads.count / 2])) ms"
            + "（完整读数落 \(out.path)）")
        XCTAssertFalse(encodeOnly.isEmpty, "一个样本都没量到 = 计时没跑起来")
        XCTAssertEqual(encodeOnly.count, 15)
        XCTAssertEqual(bootLoads.count, 7)
    }
}
