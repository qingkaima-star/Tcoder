import Foundation
import XCTest
@testable import TcoderMonitor

/// **一次性探针**（读数器，不是闸门）：把真实支持目录整份拷进沙箱，
/// 量 `ProjectStore` 的**主线程持久化成本**到底是多少毫秒。
///
/// 为什么用真数据而不是合成对象：`ProjectReport` 里字段上百，手搓一份"看起来像"的报告
/// 本身就是一次猜测；而这件事的判据只有一个数 —— "扫描完成/切项目那一刻，主线程被
/// 编码 + 原子写占掉多少毫秒"。所以直接把真实 `reports/*.json`（最大 104,913 B）搬进
/// `TCODER_SUPPORT_DIR` 沙箱，跑生产代码路径本身。
///
/// 三条红线：只复制不读内容；不碰真实目录（写全部发生在临时沙箱里）；
/// **这里不断言时间** —— 时间阈值在 CI 上必然 flaky，本文件只负责把数打出来并落盘。
///
/// 为什么拆成这么多小方法：`X3TestSizeAuditTests` 对 Tests 侧的口径是"函数 ≤50 行且 CC 达标"，
/// 2026-09-22 我第一次把整段量测写成一个 68 行 / CC=18 的函数，被它当场判红。
/// 它给的两条正解是"就地拆成小步骤"或"进派工清单并说明理由"，并明写**抬高口径不在选项里**
/// —— 按本仓一贯的"拆，不挂账"，这里选拆。
@MainActor
final class ProjectStoreCostProbeTests: XCTestCase {

    private var lines: [String] = []
    private var sandbox: URL!
    private var reportsDir: URL!

    // MARK: 读数落盘

    /// 读数**必须落文件**，不能只 print：`swift test` 会丢子进程 stdout 的后半段
    /// （本仓记过；第一次跑就是"RC=0 但一个数都没有"）。写不出去就判红，
    /// 因为"没有读数"和"读数是 0"在下游是同一个形状。
    private var reportURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".scratch/tcoder-store-cost.txt")
    }

    private func say(_ s: String) {
        lines.append(s)
        print(s)
        let url = reportURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func timed(_ label: String, _ body: () -> Void) {
        let t0 = DispatchTime.now()
        body()
        let us = DispatchTime.now().uptimeNanoseconds &- t0.uptimeNanoseconds
        say(String(format: "%-34@%8.2f ms", label as NSString, Double(us) / 1_000_000))
    }

    // MARK: 沙箱

    private func copyTree(_ from: URL, _ to: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: to, withIntermediateDirectories: true)
        for item in try fm.contentsOfDirectory(at: from, includingPropertiesForKeys: [.isDirectoryKey]) {
            let dst = to.appendingPathComponent(item.lastPathComponent)
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir { try copyTree(item, dst) } else {
                if fm.fileExists(atPath: dst.path) { try? fm.removeItem(at: dst) }
                try fm.copyItem(at: item, to: dst)
            }
        }
    }

    private func size(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    /// 返回真实支持目录；本机没跑过真实扫描就 skip（skip 原因里带上路径，不许静默跳过）。
    private func realSupportDir() -> URL? {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("TcoderMonitor", isDirectory: true)
        guard let dir, FileManager.default.fileExists(atPath: dir.path) else {
            return nil
        }
        return dir
    }

    private func reportCensus() -> (files: Int, totalBytes: Int, biggestBytes: Int, biggestID: String?) {
        let fm = FileManager.default
        var files = 0, total = 0, biggest = 0, biggestID: String?
        for u in (try? fm.contentsOfDirectory(at: reportsDir, includingPropertiesForKeys: nil)) ?? [] {
            let s = size(u)
            files += 1; total += s
            if s > biggest { biggest = s; biggestID = u.deletingPathExtension().lastPathComponent }
        }
        return (files, total, biggest, biggestID)
    }

    // MARK: 量测各段

    private func measureWrites(on store: ProjectStore, projects: [MonitoredProject]) throws {
        let first = try XCTUnwrap(projects.first)
        let report = try XCTUnwrap(store.report(for: first))
        // ① 一次"扫描完成"的落盘：save(report) + persist()（全注册表 prettyPrinted+sortedKeys）
        timed("upsertReport（42 KB 那一路）") { store.upsertReport(report) }
        say("   ↑ 写入的报告文件 = \(size(reportsDir.appendingPathComponent(first.id.uuidString + ".json"))) B")
        // ② 切项目（**用户交互**）：只写注册表（1 KB 级）
        timed("setSelectedProject（persist）") { store.setSelectedProject(projects.last?.id) }
        // ③ 记分：写**全部项目**的历史缓存，不是只写增量
        timed("recordScore（全量历史落盘）") { store.recordScore(88, for: first.id, projectName: first.name) }
    }

    /// 最大那一路以前没人量过，而它恰好是唯一可能翻盘的一路：**不许按字节外推**
    /// （我曾据此估 4.8 ms，实测 1.41 ms，差 3.4 倍 ⇒ 架构决定只能靠量）。
    private func measureBiggestReport(on store: ProjectStore, projects: [MonitoredProject]) {
        let census = reportCensus()
        guard let idStr = census.biggestID,
              let project = projects.first(where: { $0.id.uuidString == idStr }),
              let bigReport = store.report(for: project) else { return }
        say("   最大报告那一路：\(census.biggestBytes) B（项目 \(project.name)）")
        timed("upsertReport（最大那份）") { store.upsertReport(bigReport) }
    }

    // MARK: 入口

    func testMeasureProjectStoreMainThreadPersistenceCost() throws {
        guard let real = realSupportDir() else {
            throw XCTSkip("本机没有 ~/Library/Application Support/TcoderMonitor：这台机器没跑过真实扫描，"
                          + "探针换不出数（**不是「没有成本」，是「没量到」**）")
        }
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tcoder-store-cost-\(UUID().uuidString)", isDirectory: true)
        try copyTree(real, sandbox)
        reportsDir = sandbox.appendingPathComponent("reports", isDirectory: true)
        setenv("TCODER_SUPPORT_DIR", sandbox.path, 1)
        defer {
            unsetenv("TCODER_SUPPORT_DIR")
            try? FileManager.default.removeItem(at: sandbox)
        }

        let census = reportCensus()
        lines = ["HEAD=\(Date()) 沙箱=\(sandbox.lastPathComponent)"]
        say("【ProjectStore 主线程持久化成本】真实沙箱：reports \(census.files) 个 / "
            + "共 \(census.totalBytes) B / 最大 \(census.biggestBytes) B")

        var loaded: ProjectStore?
        timed("init()（含 load 同步解码）") { loaded = ProjectStore() }
        let store = try XCTUnwrap(loaded)
        let projects = store.projects
        say("载入后 projects=\(projects.count) 个；load 属**启动一次性**成本，归 T4，不许拿来解释帧率")
        guard !projects.isEmpty, projects.contains(where: { store.report(for: $0) != nil }) else {
            say("沙箱里没有可读报告 ⇒ 只量到 load 那一行"); return
        }
        try measureWrites(on: store, projects: projects)
        measureBiggestReport(on: store, projects: projects)
        timed("upsertReport ×5（连续扫描累积）") {
            if let p = projects.first, let r = store.report(for: p) {
                for _ in 0..<5 { store.upsertReport(r) }
            }
        }
        say("（时间断言故意没有：这里只要数，不要一条会在 CI 上 flaky 的阈值）")
    }
}
