import XCTest
@testable import TcoderMonitor

/// `FramePulse` 产数 ↔ `scripts/perf_framepulse.py` 读数的**跨语言格式对账**。
///
/// 【为什么要这条】spec §4 要求常驻门禁（`FramePulse`）与外部尺子（xctrace）互相校验，
/// 而两把尺子之间最容易断的不是数值是**格式**：Swift 侧改了字段名，Python 侧只是解析不到，
/// 最坏的结果不是报错而是把「没数」读成「0 hitch = 达标」。本文件拿**产品真实产出的那一行**
/// 喂解析器，格式一断立刻红，且三种失效方向（坏格式 / 样本不足 / 未确认交互）互不混淆。
///
/// 【元测试方向】合成样例只做**数值替换**、不改形状（形状取自产品那一行），
/// 所以不会出现"夹具自己写规范、解析器照夹具写"的互相迁就。
final class PerfFramePulseRulerTests: XCTestCase {

    /// `.../TcoderMonitor/Tests/TcoderMonitorTests/本文件` → 上溯三级 = `TcoderMonitor/`
    private static let moduleRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static var ruler: URL { moduleRoot.appendingPathComponent("scripts/perf_framepulse.py") }

    /// 产品自己产出的摘要行。探针关着也有这一行：它只是计数器汇总，不依赖 CVDisplayLink 真的跑起来。
    private var productLine: String { FramePulse.shared.summaryLine }

    // MARK: - 跑解析器

    private func runRuler(on file: URL, interaction: Bool) throws -> (out: String, code: Int32) {
        XCTAssertTrue(FileManager.default.fileExists(atPath: Self.ruler.path),
                      "解析器 \(Self.ruler.path) 不在了——T1 的交互期读数就没有工具能判")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var arguments = ["python3", Self.ruler.path, file.path]
        if interaction { arguments.append("--interaction") }
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw XCTSkip("本机起不了 python3（\(error.localizedDescription)）——"
                          + "尺子的跨语言对账没跑成，**这不是通过**，看输出里的 skipped 行")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "", process.terminationStatus)
    }

    /// 写一个脉冲文件到临时目录（内容就是几条摘要行 + 相位账本）。
    private func writeFixture(_ name: String, _ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 只换数值、不换形状：字段名、顺序、分隔符全部来自产品那一行。
    /// 键是**正则**（不是字面量），因为产品行里的数值随真机变（Hz、期望间隔、已有帧数），
    /// 用字面量匹配的替身在别的机器上会**静默不生效**——那才是这条测试最坏的失效方式。
    private func substitute(_ fields: [(String, String)]) -> String {
        var line = productLine
        for (pattern, value) in fields {
            line = line.replacingOccurrences(of: pattern, with: value, options: .regularExpression)
        }
        XCTAssertNotEqual(line, productLine, "整批替身一个字段都没换上，产品那一行的形状变了：\(productLine)")
        return line
    }

    /// 一组合成读数：`frames` 帧、p95 = `p95`、hitch = `hitch`，其余保持产品那行的样子。
    private func synth(frames: Int, p50: Double, p95: Double, p99: Double, max: Double,
                       hz: Double, hitch: Int) -> String {
        let expected = 1000.0 / hz
        return substitute([
            ( #"hz=[\d.]+"#, String(format: "hz=%.1f", hz)),
            (#"期望间隔=[\d.]+ms"#, String(format: "期望间隔=%.2fms", expected)),
            (#"帧数=\d+"#, "帧数=\(frames)"),
            (#"帧间隔p50=[\d.]+ p95=[\d.]+ p99=[\d.]+ max=[\d.]+ms"#,
             String(format: "帧间隔p50=%.2f p95=%.2f p99=%.2f max=%.2fms", p50, p95, p99, max)),
            (#"hitch\(>1\.5x\)=[\d]+"#, "hitch(>1.5x)=\(hitch)"),
            (#"hitch/s=[\d.]+"#, String(format: "hitch/s=%.2f", Double(hitch) / 20.0)),
            (#"心跳拍数=\d+"#, "心跳拍数=10"),
            (#"带hitch的拍=\d+/\d+"#, "带hitch的拍=\(hitch > 0 ? 1 : 0)/10"),
        ])
    }

    // MARK: - 1. 产品那一行必须能被解析器读懂

    func testProductSummaryLineIsParseableByTheRuler() throws {
        let raw = productLine
        XCTAssertTrue(raw.hasPrefix("hz="), "产品摘要行连前缀都变了，先修这里：\(raw.prefix(60))")
        let file = try writeFixture("tcoder-pulse-real.txt", raw + "\n")
        let (out, code) = try runRuler(on: file, interaction: false)
        XCTAssertFalse(out.contains("没有可解析"),
                       "解析器判定产品自己产出的行「无可解析摘要」= 两把尺子的格式已经脱钩：\n\(out)")
        XCTAssertTrue(out.contains("帧数 "),
                      "摘要行解析成功却没读出帧数字段（正则少了个组？）：\n\(out)")
        XCTAssertNotEqual(code, 0,
                          "没带 --interaction 的任何真机读数都不许判达标（0 帧应拒判=1，有帧应=2）。实得 \(code)")
        print("【FramePulse 对账】产品行：\(raw.prefix(120))… → 解析通过，退出码 \(code)")
    }

    // MARK: - 2. 三种失效方向必须给出三种可区分的退出码

    func testHealthyReadingCannotClaimPassWithoutConfirmingInteraction() throws {
        let healthy = synth(frames: 5000, p50: 8.33, p95: 8.40, p99: 8.50, max: 9.00,
                            hz: 120.0, hitch: 0)
        let file = try writeFixture("tcoder-pulse-healthy.txt", healthy + "\n")

        let (idleOut, idleCode) = try runRuler(on: file, interaction: false)
        XCTAssertEqual(idleCode, 2, "读数正常但没声明交互，必须给第 3 种退出码（0/1/2 各一义）：\n\(idleOut)")
        XCTAssertTrue(idleOut.contains("只算 idle 读数"),
                      "拒判理由必须写明「没确认交互」，否则下次就有人拿它当达标：\n\(idleOut)")

        let (liveOut, liveCode) = try runRuler(on: file, interaction: true)
        XCTAssertEqual(liveCode, 0, "同一批数，确认在交互后应判达标：\n\(liveOut)")
        XCTAssertTrue(liveOut.contains("判定：达标"), "输出要能自证判的是 T1：\n\(liveOut)")
    }

    func testHitchReadingFailsEvenWithInteractionConfirmed() throws {
        let dirty = synth(frames: 5000, p50: 8.33, p95: 25.10, p99: 33.00, max: 41.00,
                          hz: 120.0, hitch: 3)
            + "\ntick=4 frames=170 hitch=3 maxGapMs=25.10\n"
        let file = try writeFixture("tcoder-pulse-dirty.txt", dirty)
        let (out, code) = try runRuler(on: file, interaction: true)
        XCTAssertEqual(code, 1, "有 hitch 又超预算，确认交互也绝不许判 0：\n\(out)")
        XCTAssertTrue(out.contains("tick4"), "必须点名是哪一拍掉的帧：\n\(out)")
    }

    func testUnparseableFileIsNeverReadAsZeroHitches() throws {
        let file = try writeFixture("tcoder-pulse-garbage.txt", "# 探针没开\n随便一行\n")
        let (out, code) = try runRuler(on: file, interaction: true)
        XCTAssertEqual(code, 1, "坏数据必须非零退出，否则一次失败的测量会伪装成「0 hitch，完美」：\n\(out)")
        XCTAssertTrue(out.contains("没有可解析"), "要明说「没数」而不是「没 hitch」：\n\(out)")
    }

    // MARK: - 3. 阈值方向：不许为了变绿而把预算放宽

    func testBudgetFollowsMeasuredRefreshRateNotHardcoded120() throws {
        // 外接 60 Hz 屏：期望间隔 16.67 ms，帧间隔 16.70 ms 是正常节拍，不该按 8.4 判死。
        let sixty = synth(frames: 3000, p50: 16.67, p95: 16.70, p99: 16.90, max: 17.20,
                          hz: 60.0, hitch: 0)
        let file = try writeFixture("tcoder-pulse-60hz.txt", sixty + "\n")
        let (out, code) = try runRuler(on: file, interaction: true)
        XCTAssertEqual(code, 0, "60 Hz 屏的正常节拍被判未达标 = 预算被硬编码成 120 了：\n\(out)")
    }

    // MARK: - 4. 语义边界必须跟着读数走（不许被当成"顺便的注释"删掉）

    /// 纯函数：读数文本里缺哪几条语义提醒。抽出来是为了能被合成样例正反两头钉
    /// （本仓规矩：扫描型守卫必须配元测试，否则分不清"工具坏了"与"债还上了"）。
    static func missingPulseCaveats(_ text: String) -> [String] {
        var missing: [String] = []
        let required: [(label: String, needle: String)] = [
            ("心跳间隔不是主线程占用时长", "不是主线程占用时长"),
            ("T2 只认 xctrace 的 app-update 相位", "app-update 相位"),
        ]
        for item in required where !text.contains(item.needle) {
            missing.append(item.label)
        }
        return missing
    }

    private func pulseSourceText() throws -> (text: String, files: Int) {
        let dir = Self.moduleRoot.appendingPathComponent("Sources/TcoderMonitor/Services/Performance")
        let urls = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        let joined = try urls.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        return (joined, urls.count)
    }

    func testPulseArtifactHeaderKeepsItsSemanticCaveats() throws {
        // 为什么要有这条：`心跳最大间隔` 被读成"主线程卡了 1.5 秒"是我自己真犯过的错，
        // 纠正它的两行只活在 `writeHeaderLocked()` 里。待并的 x6 分支正在重写同一段
        // （它的行号已经和我这边错开了），**删掉那两行不会有任何测试红**。
        let (text, files) = try pulseSourceText()
        XCTAssertGreaterThanOrEqual(files, 3, "扫描面只有 \(files) 个文件——目录被动过，这条已经看不清现场")
        XCTAssertTrue(text.contains("writeHeaderLocked"), "脉冲产物的表头函数不见了")
        XCTAssertEqual(Self.missingPulseCaveats(text), [],
                       "读数旁边少了语义边界说明：产物文件头会重新让人把「唤醒间隔」读成「占用时长」")
    }

    func testPulseCaveatScannerCatchesBadAndSparesGood() {
        let good = "# 语义提醒：= runloop 唤醒之间的间隔，不是主线程占用时长\n"
            + "# 要量主线程占用，用 xctrace 的 app-update 相位\n"
        XCTAssertEqual(Self.missingPulseCaveats(good), [], "合规写法被误伤")
        XCTAssertEqual(Self.missingPulseCaveats("").count, 2, "全删了还不报——这条守卫是永真绿")
        XCTAssertEqual(Self.missingPulseCaveats(good.replacingOccurrences(of: "app-update 相位", with: "别的相位")),
                       ["T2 只认 xctrace 的 app-update 相位"], "只删一条时没点名那一条")
    }
}
