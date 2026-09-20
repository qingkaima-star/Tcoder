/// OWNER: WS-X3 TestSplit —— 自 PerfHitchGuardTests.swift 拆出，FramePulse 默认惰性、输出路径回退、已接进产品代码。用例本体未改，只是搬了家。
import Foundation
import XCTest
@testable import TcoderMonitor

extension PerfHitchGuardTests {

    /// 探针关闭时 `startIfNeeded()` 必须直接返回 false，且**不留下任何副作用**
    /// （连输出文件都不该被创建，更不该有 `CVDisplayLink`）。
    func testFramePulseStaysInertWithoutProbeFlag() throws {
        XCTAssertFalse(FramePulse.isProbeEnabled,
                       "测试环境里 TCODER_PERF_PROBE 必须不为 1，否则这条测的就不是默认路径")
        let path = FramePulse.outputPath
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "探针未开却已有 \(path)")
        XCTAssertFalse(FramePulse.shared.startIfNeeded(), "默认路径竟然启动了探针")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path),
                       "探针未开却创建了读数文件：零开销承诺破了")
    }

    func testFramePulseOutputPathFallsBackToPidFile() throws {
        let fromEnv = ProcessInfo.processInfo.environment["TCODER_PERF_OUT"]
        if let fromEnv, !fromEnv.isEmpty {
            XCTAssertEqual(FramePulse.outputPath, fromEnv, "TCODER_PERF_OUT 没被采用")
        } else {
            XCTAssertTrue(FramePulse.outputPath.hasPrefix("/tmp/tcoder-framepulse-"),
                          "缺省路径形状不对：\(FramePulse.outputPath)")
            XCTAssertTrue(FramePulse.outputPath.contains("\(getpid())"), "缺省路径要按 pid 分文件")
        }
    }

    /// **接线守卫：`FramePulse` 必须在产品代码里真有调用点。**
    ///
    /// 为什么这条必须存在（2026-09-20 实测漏过一次）：`FramePulse.swift` 曾被留在
    /// **产品代码零调用**的状态，而 `AGENTS.md` 第四轮红线 8 明写「必须接线进产品代码后
    /// 才允许合入（零调用的实现文件会被第 7 条拦下）」。它当时之所以没被拦下，是因为
    /// `SourceFileReachabilityTests` 的 `④static 简写` 证据只按**裸成员名**建键，
    /// 5 处无关的 `NSWorkspace.shared` 给成员名 `shared` 投了票，等于白送它一条证据。
    /// （那条假证据的洞已在同轮修掉，并配了元测试 `testStaticShorthandNeedsTheOwnerInScope`；
    /// 这里再钉住"接线点本身不许消失"，否则下一次重构把它删掉，可达性守卫又会走回老路。）
    ///
    /// 口径：**剥掉注释再查**。不然一句解释「为什么要接线」的注释就能骗过这条守卫——
    /// 本仓记过同类死法（守卫只匹配注释里的字符串，于是永远绿）。
    func testFramePulseIsWiredIntoProductCode() throws {
        let appState = Self.packageRoot.appendingPathComponent("Sources/TcoderMonitor/App/AppState.swift")
        let raw = try String(contentsOf: appState, encoding: .utf8)
        let stripped = Self.strippingLineComments(raw)
        XCTAssertTrue(stripped.contains("FramePulse.shared.startIfNeeded()"),
                      "AppState 里没有 FramePulse 的接线点 → FramePulse 成了零调用实现文件，"
                        + "违反第四轮红线 8（探针会变成一把空尺子：验收项 T1/T2 的内建读数来源就没接上）")
        // 反向夹具：同一句话放进注释里必须**不**算数（证明上面的剥离真的生效）。
        let commentOnly = "// FramePulse.shared.startIfNeeded()\nlet x = 1\n"
        XCTAssertFalse(Self.strippingLineComments(commentOnly).contains("FramePulse.shared.startIfNeeded()"),
                       "剥离器失灵：注释里的调用被当成真调用，这条守卫生效面变成零")
    }

    /// 逐行去掉 `//` 之后的部分（`///` 文档注释同样被去掉）。
    /// 刻意不做字符串感知的复杂脱敏：这里只查一个固定调用串，够用且不会被反例绕。
    static func strippingLineComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let r = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<r.lowerBound])
            }
            .joined(separator: "\n")
    }

    /// 两把尺子的分位定义必须一字对齐（`scripts/trace_report.py` 的 `percentile()`）。
    func testPercentileMatchesTheExternalRuler() {
        let values = (1...2340).map { Double($0) / 100.0 }   // 0.01ms ~ 23.40ms
        XCTAssertEqual(percentile(values, 0.50), 11.71, accuracy: 0.001)
        XCTAssertEqual(percentile(values, 0.95), 22.24, accuracy: 0.001)
        XCTAssertEqual(percentile(values, 0.99), 23.17, accuracy: 0.001)
        XCTAssertEqual(percentile([Double](), 0.5), 0, "空样本要如实给 0，不能崩")
    }

    func testFrameIntervalDistributionCountsHitchesAgainstRealHz() {
        var dist = FrameIntervalDistribution()
        for _ in 0..<99 { dist.record(8.0) }     // 120 Hz 正常帧
        dist.record(20.0)                        // 2.4× 期望间隔 = hitch
        dist.record(12.4)                        // 1.49× —— 未过 1.5× 线，不算
        XCTAssertEqual(dist.hitchCount(expectedIntervalMs: 8.333), 1)
        XCTAssertEqual(dist.maximum, 20.0, accuracy: 0.001)
        dist.record(-1)                          // 非正数样本按定义丢弃
        XCTAssertEqual(dist.values.count, 101)
    }

    func testHeartbeatGapDistributionExposesOccupiedTime() {
        var gaps = HeartbeatGapDistribution()
        XCTAssertTrue(gaps.isEmpty)
        [1.5, 2.0, 43.0, 3.0].forEach { gaps.record(gapMs: $0) }
        XCTAssertEqual(gaps.maximum, 43.0, accuracy: 0.001, "43ms = 主线程被占住多久，这条看门狗的存在理由")
        XCTAssertGreaterThan(gaps.p50, 1.4)
        XCTAssertLessThan(gaps.p50, 3.1)
    }

    /// 真实 Hz 必须运行时读出来（不许有人日后把它写死成 120）。
    func testRefreshRateIsReadAtRuntimeNotHardcoded() {
        let (hz, source) = FramePulse.readRefreshRate()
        XCTAssertFalse(source.isEmpty, "刷新率来源没标注，读数就没法解释")
        if hz > 0 {
            XCTAssertGreaterThanOrEqual(hz, 30)
            XCTAssertLessThanOrEqual(hz, 250)
            XCTAssertNotEqual(hz.rounded(), 0, "读回来的 Hz 不像真数：\(hz)")
        } else {
            XCTAssertTrue(source.contains("兜底"), "读不到 Hz 时必须如实标注兜底：\(source)")
        }
    }

    static func makeFormatter() -> DateFormatter { DateFormatter() }

}
