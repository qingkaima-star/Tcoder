import Foundation
import XCTest
@testable import TcoderMonitor

/// **一次性探针**（不是长期测试，跑完就删）：把真实支持目录整份拷进沙箱，
/// 量 `ProjectStore` 的**主线程持久化成本**到底是多少毫秒。
///
/// 为什么用真数据而不是合成对象：`ProjectReport` 里字段上百，手搓一份"看起来像"的
/// 报告本身就是一次猜测；而这件事的判据只有一个数 —— "扫描完成那一刻，主线程被
/// 编码 + 原子写占掉多少毫秒"。所以直接把真实 `reports/*.json`（最大 105 KB）搬进
/// `TCODER_SUPPORT_DIR` 沙箱，跑生产代码路径本身。
///
/// 三条红线：只复制不读内容；不碰真实目录（全部写在临时沙箱里）；
/// **这里不断言时间**（时间断言在 CI 上必然 flaky）—— 只把数打出来给人读。
///
/// `@MainActor` 不是妥协，是**这道题的题面**：编译器在报
/// "call to main actor-isolated initializer `init()` in a synchronous nonisolated context"
/// ⇒ 这些编码与原子写**本来就只能在主线程上跑**，所以"在别的线程上量"会量到一个不存在的路径。
@MainActor
final class ProjectStoreCostProbeTests: XCTestCase {

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

    /// 读数**必须落文件**，不能只 print：`swift test` 会丢子进程 stdout 的后半段
    /// （本仓记过，2026-09-20 的 premerge 日志里就没有那行 print）。
    /// 同一条规矩也是渲染路径台账落 `.scratch/` 的理由 —— 写不出去就判红，
    /// 因为"没读数"和"读数是 0"在下游是同一个形状。
    private func reportPath() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".scratch/tcoder-store-cost.txt")
    }

    func testMeasureProjectStoreMainThreadPersistenceCost() throws {
        let fm = FileManager.default
        let real = try XCTUnwrap(fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
            .appendingPathComponent("TcoderMonitor", isDirectory: true)
        try XCTSkipUnless(fm.fileExists(atPath: real.path),
                          "本机没有 \(real.path)：这台机器没跑过真实扫描，探针换不了数")

        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tcoder-store-cost-\(UUID().uuidString)", isDirectory: true)
        try copyTree(real, sandbox)
        setenv("TCODER_SUPPORT_DIR", sandbox.path, 1)
        defer { unsetenv("TCODER_SUPPORT_DIR"); try? fm.removeItem(at: sandbox) }

        // 每行都立刻落盘：中途崩溃也留得下已经量到的部分
        let path = reportPath()
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        var lines: [String] = ["HEAD=\(Date()) 沙箱=\(sandbox.lastPathComponent)"]
        func say(_ s: String) { lines.append(s); print(s); try? lines.joined(separator: "\n").write(to: path, atomically: true, encoding: .utf8) }
        func timed(_ label: String, _ body: () -> Void) {
            let t0 = DispatchTime.now()
            body()
            let us = DispatchTime.now().uptimeNanoseconds &- t0.uptimeNanoseconds
            say(String(format: "%-30@ %8.2f ms", label as NSString, Double(us) / 1_000_000))
        }

        var totalBytes = 0
        var biggest = 0
        var files = 0
        let reportsDir = sandbox.appendingPathComponent("reports", isDirectory: true)
        for u in (try? fm.contentsOfDirectory(at: reportsDir, includingPropertiesForKeys: nil)) ?? [] {
            let s = size(u); files += 1; totalBytes += s; biggest = max(biggest, s)
        }
        say("【ProjectStore 主线程持久化成本】真实沙箱：reports \(files) 个 / 共 \(totalBytes) B / 最大 \(biggest) B")

        var store: ProjectStore?
        timed("init()（含 load 解码）") { store = ProjectStore() }
        guard let s = store else { return }

        let projects = s.projects
        say("载入后 projects=\(projects.count) 个")
        guard let first = projects.first, let report = s.report(for: first) else {
            say("沙箱里没有可读报告 ⇒ 只量到 load 那一行"); return
        }

        // ① 一次"扫描完成"的落盘：save(report) + persist()（全注册表 prettyPrinted+sortedKeys）
        timed("upsertReport（save+persist）") { s.upsertReport(report) }
        say("  ↑ 写入的报告文件 = \(size(reportsDir.appendingPathComponent(first.id.uuidString + ".json"))) B")

        // ①′ **按最大的那份报告再量一次**——不许拿"42 KB 花 1.93 ms"线性外推到 105 KB：
        //     外推会藏住 prettyPrinted/sortedKeys 与写盘的非线性部分，而那正好跨过 4.0 ms 这条线，
        //     是本探针唯一会让人做出"要不要异步化持久化"决定的数。
        if let biggestID = (try? fm.contentsOfDirectory(at: reportsDir, includingPropertiesForKeys: nil))?
            .map({ (url: $0, bytes: size($0)) }).max(by: { $0.bytes < $1.bytes })?.url
            .deletingPathExtension().lastPathComponent,
           let bigProject = projects.first(where: { $0.id.uuidString == biggestID }),
           let bigReport = s.report(for: bigProject) {
            say("  最大报告 \(size(reportsDir.appendingPathComponent(biggestID + ".json"))) B 的那一路：")
            timed("upsertReport（最大那份）") { s.upsertReport(bigReport) }
        }
        // ② 切项目（用户交互）：只写注册表（1 KB 级）
        timed("setSelectedProject（persist）") { s.setSelectedProject(projects.last?.id) }
        // ③ 记分：写**全部项目**的历史缓存（不是只写增量）
        timed("recordScore（persistHistory 全量）") { s.recordScore(88, for: first.id, projectName: first.name) }
        // ④ 重复 ①×5：看连续扫描时的累积（每份都在主线程上）
        timed("upsertReport ×5（累积）") { for _ in 0..<5 { s.upsertReport(report) } }
        say("（时间断言故意没有：这里只要数，不要一条会在 CI 上 flaky 的阈值）")
    }
}
