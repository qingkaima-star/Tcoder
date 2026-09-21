/// OWNER: WS-X3 TestSplit —— 自 DesignAbsenceStateTests.swift 拆出，缺数据态只从一处出：HealthRing/MetricTile 与页面单点。用例本体未改，只是搬了家。
import Foundation
import XCTest
@testable import TcoderMonitor

extension DesignAbsenceStateTests {

    /// WS-M 三页的本地单点 `Live.missing` 现在只是全仓单点的一个别名，不再是第二处字面定义。
    func testLiveMissingIsAnAliasOfTheSinglePoint() {
        XCTAssertEqual(Live.missing, DataAbsence.notAnalysed.display)
        XCTAssertTrue(Live.isMissing(Live.missing))
        XCTAssertFalse(Live.isMissing("0"), "真 0 不是占位符")
        XCTAssertEqual(Live.text(nil), Live.missing)
    }

    /// `MetricTile` 的 `value: nil` 也必须从单点取字面（总览四枚 tile 走的就是这条路）。
    func testMetricTileMissingValueComesFromTheSinglePoint() {
        XCTAssertEqual(MetricTile.displayValue(nil), DataAbsence.notAnalysed.display)
        XCTAssertEqual(MetricTile.displayValue("0"), "0", "真 0 必须原样显示")
    }

    func testHealthRingScoreTextIsTheUnscoredLiteral() {
        XCTAssertEqual(HealthRing.scoreText(for: nil), DataAbsence.notAnalysed.display,
                       "未评分属「没查」这一态，字面归单点")
        XCTAssertNotEqual(HealthRing.scoreText(for: nil), HealthRing.scoreText(for: 0),
                          "「未评分」与「0 分」若同串，等于把没查说成最差")
        XCTAssertEqual(HealthRing.scoreText(for: 87), "87")
    }

    /// **同源的行为判据**：未评分时，读屏出口必须与视觉出口给**同一个串**。
    /// 任何一边单独改措辞（哪怕改成的还是 `--` 的近义句），这里就红。
    func testHealthRingVoiceOverAndVisualGiveTheSameStringWhenUnscored() {
        XCTAssertEqual(HealthRing.accessibilityText(score: nil, grade: nil, trend: nil),
                       HealthRing.scoreText(for: nil),
                       "眼睛看到 `--`、VoiceOver 念出另一句——《42》§14.3 第 2 条就是防这个")
        XCTAssertEqual(HealthRing.accessibilityText(score: nil, grade: .a, trend: 3),
                       HealthRing.scoreText(for: nil),
                       "未评分时等级与趋势都不该给读屏添第二句说法")
        let scored = HealthRing.accessibilityText(score: 87, grade: .a, trend: 3)
        XCTAssertTrue(scored.contains(HealthRing.scoreText(for: 87)),
                      "有评分时读屏里的数字也得来自同一个出口：\(scored)")
        XCTAssertTrue(scored.contains("分"), scored)
    }

    /// 两个出口还都得**真的**从这两个唯一函数取串：谁在视图里就地拼字面，扫描判红。
    func testHealthRingVisualAndVoiceOverOutletsBothGoThroughOneFunction() throws {
        let hero = try Self.fileContent(underViews: "Shell/DashboardHero.swift")
        let readoutBody = try Self.functionBody(of: "private func readout(role:", in: hero)
        let summaryBody = try Self.functionBody(
            of: "private var accessibilitySummary:", in: hero, endingWith: "    }")
        XCTAssertTrue(readoutBody.contains("Self.scoreText(for:"),
                      "HealthRing.readout 没走 scoreText(for:) 这个唯一视觉出口：\n" + readoutBody)
        XCTAssertTrue(summaryBody.contains("Self.accessibilityText("),
                      "HealthRing.accessibilitySummary 没走 accessibilityText(…) 这个唯一读屏出口：\n"
                          + summaryBody)
        for (name, body) in [("readout", readoutBody), ("accessibilitySummary", summaryBody)] {
            XCTAssertFalse(body.contains("--"),
                           "HealthRing.\(name) 里又手写了一遍占位字面，改措辞时只会改到一边：\n" + body)
            XCTAssertFalse(body.contains("Theme.Placeholder"),
                           "HealthRing.\(name) 绕开单点直接取字面本体：\n" + body)
        }
    }

    /// 上提之后必须**真有人用**（《42》§14.3 第 3 条：不许基座预建等待接入的壳）。
    func testPagesActuallyRouteThroughTheSinglePoint() throws {
        let files = Self.viewFiles
        let uses = try Self.scan(Self.singlePointUsePattern, in: files)
        XCTAssertGreaterThanOrEqual(uses.count, Self.minimumSinglePointUseSites,
                                    "页面走单点的处数掉到 \(uses.count)（下限 \(Self.minimumSinglePointUseSites)）"
                                        + "——说明有锚点被改回手写：\n" + Self.describe(uses))
        // 12 个锚点所在文件都要么引单点、要么本来就没有手写占位。
        for anchorFile in ["Views/DashboardView.swift", "Views/Shell/ProjectSidebar.swift",
                           "Views/Shell/DashboardHero.swift", "Views/Code/CodeMetricsView.swift",
                           "Views/Code/CodeRiskRows.swift", "Views/Git/ContributorRows.swift",
                           "Views/Git/GitInsightsSections.swift", "Views/PerfLogs/LiveReadings.swift"] {
            let entry = files.first { $0.path.hasSuffix(anchorFile) }
            XCTAssertNotNil(entry, "锚点文件 \(anchorFile) 扫不到")
            let usesHere = try Self.scan(Self.singlePointUsePattern, in: [entry ?? ("", "")])
            XCTAssertFalse(usesHere.isEmpty, "\(anchorFile) 不再引用 DataAbsence，§14.1 的锚点被改回去了")
        }
    }

}
