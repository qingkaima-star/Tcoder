import Foundation
import XCTest
@testable import TcoderMonitor

// MARK: - 图表轴与卡标题口径（自 PerformanceDisplayTests.swift 原样搬出）
//
// 搬的理由是机械的：`X3TestSizeAuditTests` 用与产品「巨大文件」同一口径（400 行）
// 钉着 Tests 目录，而 P21 两条口径守卫把主文件顶到 422 行。
// 判据、断言与话术一字未改，只换了住的地方。
// 为什么按这条线切：主文件留的是**读数显示层**（单位、uptime、瓦片文案），
// 这一片全是**轴与跨度**（台阶、步长档位、"窗口约 N 秒"的口径）。

extension PerformanceDisplayTests {

    // MARK: - 轴：只跳台阶，不逐帧改

    func testAxisIsStableForNearbyPeaks() {
        XCTAssertEqual(ChartScale.axis(peak: 4.0), ChartScale.axis(peak: 4.1),
                       "峰值小幅波动就换轴，曲线会整体上下跳动")
        XCTAssertEqual(ChartScale.axis(peak: 4.0), ChartAxis(step: 2, maxValue: 6))
        XCTAssertEqual(ChartScale.axis(peak: 4.0).ticks, [0, 2, 4, 6],
                       "最后一个刻度必须正好落在轴顶，否则图上会出现悬空的留白")
    }

    /// 步长必须落在 {1,2,2.5,5}×10ⁿ 上，且「只抬不降、抬幅不超过 2 倍」——
    /// 这才是轴不抖的充要条件。上一版把允许集写成字面量表，漏了 1 以下的档位，
    /// 于是一次循环刷出 271 条假红；换成通用判据后同一循环只有一条断言。
    func testNiceStepOnlyUsesTheLadder() {
        for candidate in stride(from: 0.03, through: 600, by: 0.37) {
            let step = ChartScale.niceStep(candidate)
            XCTAssertTrue(isLadderStep(step), "出现了台阶外的步长 \(step)（候选 \(candidate)）")
            XCTAssertGreaterThanOrEqual(step, candidate - 1e-12, "步长不能小于候选，否则轴顶会被数据捅破")
            XCTAssertLessThanOrEqual(step, candidate * 2 + 1e-12, "步长最多抬一档，抬太狠曲线会被压扁")
        }
        XCTAssertEqual(ChartScale.niceStep(0), 1)
        XCTAssertEqual(ChartScale.niceStep(.nan), 1)
    }

    private func isLadderStep(_ value: Double) -> Bool {
        guard value > 0, value.isFinite else { return false }
        let unit = value / pow(10, floor(log10(value)))
        return [1.0, 2.0, 2.5, 5.0, 10.0].contains { abs(unit / $0 - 1) < 1e-6 }
    }

    // MARK: - 计数轴与百分比轴（总工截图复核问题 1 / 3）

    func testCountAxisNeverPrintsFractionalCounts() {
        // 单日 1 条最容易给到 0.5 步长（通用台阶是给字节速率设计的），标签就会打成 0/0/1/1。
        let axis = ChartScale.countAxis(peak: 1)
        XCTAssertEqual(axis.step, 1)
        XCTAssertTrue(axis.ticks.allSatisfy { $0 == $0.rounded() }, "\(axis.ticks)")
        for peak in [0, 1, 3, 7, 250, 10_000] {
            let made = ChartScale.countAxis(peak: Double(peak))
            XCTAssertGreaterThanOrEqual(made.step, 1, "峰值 \(peak) 的步长小于 1")
            XCTAssertTrue(made.ticks.allSatisfy { $0 == $0.rounded() },
                          "峰值 \(peak) 出现小数刻度 \(made.ticks)")
            XCTAssertGreaterThan(made.maxValue, 0, "峰值 \(peak) 的轴没有可画高度")
        }
    }

    func testPercentAxisStaysAtZeroOriginUntilTheCurveIsPinnedHigh() {
        XCTAssertEqual(ChartScale.adaptivePercentAxis(peakPercent: nil), ChartScale.percentAxis)
        XCTAssertEqual(ChartScale.adaptivePercentAxis(peakPercent: 42), ChartScale.percentAxis)
        XCTAssertFalse(ChartScale.percentAxis.isZoomed)

        let mid = ChartScale.adaptivePercentAxis(peakPercent: 72)
        XCTAssertEqual(mid.minValue, 50)
        XCTAssertTrue(mid.isZoomed)

        let high = ChartScale.adaptivePercentAxis(peakPercent: 96)
        XCTAssertEqual(high.minValue, 75)
        XCTAssertEqual(high.maxValue, 100)
        XCTAssertTrue(high.ticks.last == 100)
        XCTAssertTrue(high.domainText.contains("75"), "收窄过就必须把下限写在轴说明里")
    }

    func testRelativeTimeAxisRescuesTheSingleClockLabelCase() {
        // 5 点 × 1.5 秒 = 7.5 秒的窗口里，`22:22` 只会剩下一个刻度。
        XCTAssertTrue(ChartScale.usesRelativeAxis(windowSeconds: 7.5, pointCount: 5))
        XCTAssertFalse(ChartScale.usesRelativeAxis(windowSeconds: 135, pointCount: 90))
        XCTAssertEqual(ChartScale.relativeSecondsText(Date(timeIntervalSince1970: 1_000), reference: Date(timeIntervalSince1970: 1_007)), "-7s")
        XCTAssertEqual(ChartScale.relativeSecondsText(Date(timeIntervalSince1970: 1_007), reference: Date(timeIntervalSince1970: 1_007)), "现在")
    }

    func testAxisGrowsMonotonicallyAndNeverInverts() {
        var previous = 0.0
        for peak in stride(from: 0.5, through: 400, by: 0.5) {
            let axis = ChartScale.axis(peak: peak)
            XCTAssertGreaterThanOrEqual(axis.maxValue, previous, "轴不能随峰值增大而缩回去")
            XCTAssertGreaterThan(axis.maxValue, peak, "峰值必须落在轴内，留白是刻意的")
            XCTAssertGreaterThan(axis.step, 0)
            previous = axis.maxValue
        }
    }

    func testPercentAxisIsFixedAtAHundred() {
        XCTAssertEqual(ChartScale.percentAxis.maxValue, 100)
        XCTAssertEqual(ChartScale.percentAxis.ticks, [0, 25, 50, 75, 100])
    }

    func testStrideComesFromAFixedLadder() {
        XCTAssertEqual(ChartScale.secondsStride(windowSeconds: 135), 30)
        XCTAssertTrue([5, 15, 30, 60, 120, 300, 600, 1800].contains(ChartScale.secondsStride(windowSeconds: 600)))
        XCTAssertEqual(ChartScale.dayStride(spanDays: 7), 2)
        XCTAssertEqual(ChartScale.dayStride(spanDays: 30), 5)
        XCTAssertEqual(ChartScale.dayStride(spanDays: -3), 1)
    }

    /// 短窗口必须**至少落得下两格**。
    /// 档位本身按"窗口 ~135 秒"标定，但候选档之间是 1→2→5→15 的跳变：
    /// 26 秒的窗口会选到 15 秒（比半个窗口还大），左半边就一根刻度都没有
    /// —— 交付头实拍「总览」曲线量到标签中心在 47% 与 92%，正是这个形状。
    func testShortWindowsStillGetAtLeastTwoTicks() {
        XCTAssertEqual(ChartScale.boundedSecondsStride(windowSeconds: 26), 13, "15 秒的档必须被下界压回 13")
        XCTAssertEqual(ChartScale.boundedSecondsStride(windowSeconds: 135), 30, "长窗口不受下界影响")
        XCTAssertEqual(ChartScale.boundedSecondsStride(windowSeconds: 0), 1, "退化窗口也要给得出步长")
        for span in 2...600 {
            let stride = ChartScale.boundedSecondsStride(windowSeconds: Double(span))
            XCTAssertGreaterThanOrEqual(Double(span) / Double(stride), 2.0,
                                        "窗口 \(span) 秒 / 步长 \(stride) 秒 ⇒ 落不下两格")
        }
    }

    /// 抽出 `subtitle` 那一段（**先剥注释**：代码说明里本身就写着 `windowSeconds`，
    /// 不剥会被当成命中 —— 这条守卫第一次跑就差点栽在这里）。
    static func subtitleBody(of content: String) -> String? {
        let lines = SurfaceScanKit.codeLines(content)
        guard let start = lines.firstIndex(where: { $0.contains("private var subtitle") }) else { return nil }
        return lines[start...].prefix(while: {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("}")
        }).joined(separator: "\n")
    }

    /// 交付头 `64f2ed4` 逐张人眼复核抓到两口径同卡：标题写 135 秒，轴上只有「−12s」——
    /// 画的是 `history.suffix(chartPointLimit)` ≈ 19 点 × 1.5 秒 ≈ 28.5 秒，135 秒是缓冲区长度。
    func test_liveChartCaptionQuotesThePlottedSpanNotTheBufferWindow() throws {
        let files = try SurfaceScanKit.sourceFiles(under: "Views/Performance")
        guard let chart = files.first(where: { $0.path.hasSuffix("PerformanceLiveCharts.swift") }) else {
            XCTFail("找不到 PerformanceLiveCharts.swift ⇒ 这条判据在空转"); return
        }
        guard let body = Self.subtitleBody(of: chart.content) else {
            XCTFail("`subtitle` 不在这个文件里了？判据要跟着搬，不许默默失效"); return
        }
        XCTAssertTrue(body.contains("actualSpanSeconds"),
                      "标题里的跨度必须来自实际画出来的那一段：\(body)")
        XCTAssertFalse(body.contains("Int(windowSeconds)"),
                       "标题又去印缓冲区窗口了 ⇒ 同一张卡两个口径")
    }

    /// 上面那条是"扫真文件"型判据 ⇒ 必须配元测试证明它数得出东西。
    func test_captionScannerCatchesBufferWindowAndSparesThePlottedSpan() {
        let bad = Self.subtitleBody(of: """
            private var subtitle: String {
                localizedFormat("最近 %1$@ 点 · 窗口约 %2$@ 秒", a, "\\(Int(windowSeconds))")
            }
            """)
        XCTAssertNotNil(bad, "抽不出 subtitle 那一段 ⇒ 判据空转")
        XCTAssertTrue(bad?.contains("Int(windowSeconds)") == true, "坏样例没被抽出来")
        let good = Self.subtitleBody(of: """
            private var subtitle: String {
                localizedFormat("最近 %1$@ 点 · 窗口约 %2$@ 秒", a, "\\(Int(actualSpanSeconds))")
            }
            """)
        XCTAssertFalse(good?.contains("Int(windowSeconds)") == true, "好样例被误判")
        XCTAssertTrue(good?.contains("actualSpanSeconds") == true, "好样例里没读到 actualSpanSeconds")
    }

    func testDegeneratePeaksStillProduceADrawableAxis() {
        for peak in [0, -5, Double.infinity, Double.nan] {
            let axis = ChartScale.axis(peak: peak)
            XCTAssertGreaterThan(axis.maxValue, 0)
            XCTAssertGreaterThan(axis.step, 0)
            XCTAssertTrue(axis.maxValue.isFinite)
        }
    }

    // MARK: - 批次 P24：秒轴只许有一把尺子

    /// 裸档位 `secondsStride` 与带下界的 `boundedSecondsStride` 是**两把尺子**，
    /// 差别只在"步长不许超过窗口的一半"那一条。总览那张一开始就用带下界的，
    /// 性能页两张用了裸的 —— 复拍 `53f9b1c` 量到性能页横轴各只有 1 枚标签
    /// （27 秒跨度选到 15 秒档，一根刻度落不进左半边）。
    /// 规则收成一条：**档位定义之外，全站调用点一律走带下界的那把**。
    static func unboundedSecondsStrideCalls(in files: [(path: String, content: String)]) -> [String] {
        files.flatMap { file -> [String] in
            guard file.path != "Views/PerfLogs/ChartChrome.swift" else { return [] }   // 定义所在
            return file.content.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .compactMap { index, raw -> String? in
                    let line = String(raw)
                    guard SurfaceScanKit.isCode(line),
                          line.contains("secondsStride("),
                          !line.contains("boundedSecondsStride(") else { return nil }
                    return "\(file.path):\(index + 1)"
                }
        }
    }

    func test_noCallSiteUsesTheUnboundedSecondsStride() throws {
        let offenders = Self.unboundedSecondsStrideCalls(
            in: try SurfaceScanKit.sourceFiles(under: "Views") + SurfaceScanKit.sourceFiles(under: "Design"))
        XCTAssertTrue(offenders.isEmpty,
                      "这些调用点用的是裸档位，短窗口下横轴会只剩一两枚标签：\(offenders)")
    }

    /// 元测试：该抓的抓到、带下界的不误伤、定义文件本身不算调用点。
    func test_strideScannerSeparatesBoundedFromUnbounded() {
        let bare = [(path: "Views/Fake.swift", content: "TimeAxis.seconds(ChartScale.secondsStride(windowSeconds: 27))")]
        XCTAssertEqual(Self.unboundedSecondsStrideCalls(in: bare), ["Views/Fake.swift:1"],
                       "裸档位没被抓到 ⇒ 这条守卫数不出东西")
        let bounded = [(path: "Views/Fake.swift",
                        content: "TimeAxis.seconds(ChartScale.boundedSecondsStride(windowSeconds: 27))")]
        XCTAssertTrue(Self.unboundedSecondsStrideCalls(in: bounded).isEmpty, "走了带下界那把尺的被误判")
        let definition = [(path: "Views/PerfLogs/ChartChrome.swift",
                           content: "static func secondsStride(windowSeconds: TimeInterval) -> Int {")]
        XCTAssertTrue(Self.unboundedSecondsStrideCalls(in: definition).isEmpty, "定义本身被当成调用点")
    }
}
