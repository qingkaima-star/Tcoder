import XCTest
@testable import TcoderMonitor

/// 「GUI 侧那份重演装配只许有一个入口」的守卫（RD-31 × RD-60 跨支对表抓出来的那条）。
///
/// 成因不是读码猜的，是真子进程量出来的：交付二进制 `scan --out` 落的 JSON 里
/// `provenance.sourceDriftDuringScan` **在场**且为 `false`（两枚指纹都量到了），
/// 缺席的是测试里那份自带的 GUI 装配副本 —— 同一件事两个入口时，契约每加一格
/// 只有被点名的那份会补上，另一份静默落后（R10 漏过 `provenance`、这次漏两枚指纹）。
///
/// 所以这条守的是**形状**，不是读数：对表红的时候它先点名是哪一个入口漏了装配，
/// 而不是让人从一条判败去猜方向。「两侧读数相等」仍归 `CrashEvidenceParityTests` 与
/// `scripts/report_parity.py` 那把尺子管，这条不重复实现（第三把尺子）。
final class GuiSideReplayEntryPointTests: XCTestCase {

    /// 唯一那个入口的文件名。新增第二个 GUI 侧重演 ⇒ 这条先红（红得比对表早、也说得出是谁）。
    private static let soleEntryPoint = "GuiSideReportReplay.swift"

    /// 五路扇出的位置标记：开工那枚指纹必须采在**这些之前**、收工那枚在之后。
    /// 两枚采在同一个瞬间，比出来的永远"一致" —— 那是把"没量"包装成"没变化"。
    private static let fanOutMarkers = ["AnalyzerLedger.timed", "fiveSections(root:"]

    private struct Replay: Equatable {
        var path: String
        var probeCount: Int
        var recordsDrift: Bool
        var probesBracketFanOut: Bool
    }

    // MARK: - 判据

    /// GUI 侧重演的入口**只有一个**，且那一个真的采了两枚指纹、把五路夹在中间、比完落进溯源块。
    func testGuiSideReplayHasExactlyOneEntryPointAndItProbesTwice() throws {
        let replays = Self.replays(in: try Self.testCodeFiles())
        XCTAssertEqual(replays.map(\.path), [Self.soleEntryPoint],
                       "GUI 侧「重演装配」出现了第二个入口（或唯一入口改名了）⇒ 契约再加一格时"
                       + "只会补上被点名的那份，另一份整键缺席、对表判红。并进来，别另写一份。")
        for replay in replays {
            XCTAssertEqual(replay.probeCount, 2,
                           "\(replay.path) 采了 \(replay.probeCount) 枚指纹：不足两枚就没法比"
                           + "「开工 vs 收工」，产出的报告里 `sourceDriftDuringScan` 只会是 nil")
            XCTAssertTrue(replay.recordsDrift,
                          "\(replay.path) 装配了溯源块却没记漂移 ⇒ 这条路产出的报告永远读成「未量到」")
            XCTAssertTrue(replay.probesBracketFanOut,
                          "\(replay.path) 的两枚指纹没有把五路扇出夹在中间 ⇒ 比的是同一个瞬间，"
                          + "扫描期间真改了源码也判不出来")
        }
    }

    /// 元测试：这条尺子必须抓得住三种坏形状，也不误伤正确写法。
    func test_meta_replayRulerBitesBothWays() {
        let wired = (path: "GuiSideReportReplay.swift", code: """
         let start = SourceTreeFingerprint.probe(root: directory)
         let sections = await fiveSections(root: directory)
         provenance.recordDrift(startingFrom: start,
                                endingAt: SourceTreeFingerprint.probe(root: directory))
         let p = ScanProvenance(report: report, scannedRoot: path, producedBy: \"gui\")
         """)
        XCTAssertEqual(Self.replays(in: [wired]).map(\.path), [Self.soleEntryPoint], "正确写法判不出来")
        XCTAssertEqual(Self.replays(in: [wired]).first?.probeCount, 2)
        XCTAssertTrue(Self.replays(in: [wired]).first?.probesBracketFanOut == true)

        // ① 只写溯源、不采指纹的副本（本次真红的那个形状）⇒ 第二份入口要被点名
        let silent = (path: "SecondCopy.swift",
                      code: "report.provenance = ScanProvenance(report: r, scannedRoot: p, "
                             + "producedBy: \"gui\")\nlet x = await AnalyzerLedger.timed(label) { try await go() }")
        let both = Self.replays(in: [wired, silent])
        XCTAssertEqual(both.map(\.path).sorted(), ["GuiSideReportReplay.swift", "SecondCopy.swift"],
                       "第二份 GUI 重演没被抓到")
        XCTAssertEqual(both.last?.probeCount, 0, "那份副本一枚指纹都没采")
        XCTAssertEqual(both.last?.recordsDrift, false)

        // ② 两枚都采在五路**之后**：比的是同一个瞬间，永远"一致"
        let late = (path: "LateProbes.swift", code: """
         let sections = await fiveSections(root: directory)
         let start = SourceTreeFingerprint.probe(root: directory)
         provenance.recordDrift(startingFrom: start,
                                endingAt: SourceTreeFingerprint.probe(root: directory))
         let p = ScanProvenance(report: report, scannedRoot: path, producedBy: \"gui\")
         """)
        XCTAssertEqual(Self.replays(in: [late]).first?.probesBracketFanOut, false,
                       "两枚采在同一个瞬间的写法被判成了合规")
    }

    /// 元测试的另一半：**这条守卫自己**不许被认成入口 —— 坏样例一律写成 `\"gui\"`（源码文本上
    /// 不成对、运行时才成对）或留在注释里（判之前已剥）。实测第一版就是被自己判红的，钉住它。
    func test_meta_theGuardFileItselfIsNotCountedAsAnEntryPoint() throws {
        let mine = "GuiSideReplayEntryPointTests.swift"
        let files = try Self.testCodeFiles().filter { $0.path == mine }
        XCTAssertEqual(files.count, 1, "守卫文件不在扫描面上 ⇒ 这条元测试是永真绿")
        XCTAssertEqual(Self.replays(in: files).map(\.path), [],
                       "守卫带着坏样例却被认成第二个入口 —— 判之前没剥注释，或样例漏了转义")
    }

    // MARK: - 尺子

    /// 认「GUI 侧重演装配」的两枚印记：既写了 `producedBy: "gui"` 的溯源块，
    /// 又自己跑五路扇出（标记与下面量次序用的是**同一份**清单，不另写一把尺子）。
    /// 少了后一条就会把 `ScanProvenanceTests` 那种纯契约单测误伤。
    /// ⚠️ 判之前先剥注释：本仓的红过的那类事故是"注释里交代为什么不这么写的那一句把自己判红"，
    ///    而这条守卫文件正是全站写坏样例最多的地方 —— 不剥就每跑必假报"第二个入口"。
    private static func replays(in files: [(path: String, code: String)]) -> [Replay] {
        files.map { (path: $0.path, lines: codeLines($0.code)) }
            .filter { file in
                let code = file.lines.joined(separator: "\n")
                return code.contains("producedBy: \"gui\"")
                    && Self.fanOutMarkers.contains { marker in code.contains(marker) }
            }
            .map { file in
                Replay(path: file.path,
                       probeCount: file.lines.filter { $0.contains("SourceTreeFingerprint.probe") }.count,
                       recordsDrift: file.lines.joined(separator: "\n").contains("recordDrift"),
                       probesBracketFanOut: brackets(file.lines))
            }
            .sorted { $0.path < $1.path }
    }

    /// 第一枚探针在五路扇出之前、最后一枚在它之后（两枚采在同一个瞬间 = 不成立）。
    private static func brackets(_ lines: [String]) -> Bool {
        let probe = lines.indices.filter { lines[$0].contains("SourceTreeFingerprint.probe") }
        let fanOut = lines.indices.filter { i in Self.fanOutMarkers.contains { lines[i].contains($0) } }
        guard let firstProbe = probe.first, let lastProbe = probe.last, let firstFanOut = fanOut.first else {
            return false
        }
        return firstProbe < firstFanOut && firstFanOut < lastProbe
    }

    private static func codeLines(_ code: String) -> [String] {
        // 剥注释**复用** `ScanSourceDriftTests` 那把既有尺子（同一件事只许一个入口）：
        // 注释里"交代为什么不这么写"的那一句不得把自己判红（本仓为这件事红过不止一次）。
        ScanSourceDriftTests.dropCommentLines(from: code)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// 扫 `Tests/TcoderMonitorTests/**` 的 Swift 文件（剥注释后的代码文本）。
    private static func testCodeFiles() throws -> [(path: String, code: String)] {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Tests/TcoderMonitorTests
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".swift") }
        return names.map { name in
            let text = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            return (name, text ?? "")   // 剥注释交给尺子自己做，这里不预先加工
        }
    }
}
