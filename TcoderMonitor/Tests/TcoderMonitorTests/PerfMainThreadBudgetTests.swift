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
