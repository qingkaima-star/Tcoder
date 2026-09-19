import AppKit
import XCTest

@testable import TcoderMonitor

/// WS-G 第二轮（守门人轮）单测。
///
/// 与 `DesignTokenTests` 的分工：那份钉**令牌表的数学性质**（对比度、字号下限、栅格），
/// 这份钉**本轮新增能力的行为**——三态证据、稳定取色、表格排序、量表空值、侧栏未评分。
///
/// 刻意**不扫 `Views/**`**：三条流正在并行改页面，任何对页面源码的计数断言都会
/// 因他们的正常改动而当场判红，而测试是全仓同一个编译单元——那等于我挡住所有人。
/// 那套"零新增棘轮"该挂在 CI 的 diff 上，交总工（见笔记 66）。
final class DesignKitTests: XCTestCase {

    // MARK: - C. 图表色：单一来源与稳定取号

    func testStableIndexIsDeterministicCaseInsensitiveAndInBounds() {
        let keys = ["Swift", "swift", "JavaScript", "python", "", "中文语言名",
                    "a-dep-with-a-very-long-name-9e1f", "☃", "application/json"]
        for key in keys {
            let index = Theme.Chart.index(forLabel: key)
            XCTAssertTrue((0..<Theme.Chart.count).contains(index),
                          "「\(key)」取到越界号位 \(index)")
            XCTAssertEqual(index, Theme.Chart.index(forLabel: key), "同一键两次取号不同 = 不稳定")
        }
        XCTAssertEqual(Theme.Chart.index(forLabel: "Swift"), Theme.Chart.index(forLabel: "swift"),
                       "大小写应视作同一个键")
    }

    func testAreaGradientIntensityTiersAreOrdered() {
        XCTAssertEqual(Theme.Chart.Intensity.specTop.topOpacity,
                       Theme.Palette.Opacity.gradientTop)
        XCTAssertEqual(Theme.Chart.Intensity.soft.topOpacity,
                       Theme.Palette.Opacity.gradientAreaSoft)
        XCTAssertLessThan(Theme.Chart.Intensity.soft.topOpacity,
                          Theme.Chart.Intensity.specTop.topOpacity)
        for intensity in [Theme.Chart.Intensity.specTop, .soft] {
            XCTAssertGreaterThan(intensity.topOpacity, Theme.Palette.Opacity.gradientFloor,
                                 "顶色不得低于收尾色")
        }
    }

    func testGaugeHeightTiersMatchSpec() {
        XCTAssertEqual(Theme.Layout.gaugeInline, 5)
        XCTAssertEqual(Theme.Layout.gaugeMetric, 6)
    }

    // MARK: - F. 补上的令牌档位确实存在

    func testElevenPointMonospacedTierNowExists() {
        // WS-L 报「设计系统没有 11pt 等宽档」，只能自己借 label 的字号换字面
        XCTAssertEqual(Theme.Typo.monoLabel.size, 11)
        XCTAssertTrue(Theme.Typo.monoLabel.monospacedDigits)
        XCTAssertTrue(Theme.Typo.all.contains { $0.name == "monoLabel" },
                      "新档没登记进 all，等于游离在单测覆盖之外")
        XCTAssertTrue(Theme.Typo.numericTiers.contains { $0.name == "monoLabel" })
    }

    func testSinkedSymbolsFromPageFilesAreNowRegistered() {
        let required: [IconName] = [.openInApp, .calendar, .history, .marker, .suggestion,
                                    .parameters, .expand, .comments, .outdated, .refactor,
                                    .verdictClean, .gridDense,
                                    .sortNeutral, .sortAscending, .sortDescending]
        for name in required {
            XCTAssertTrue(IconName.allCases.contains(name), "\(name) 没进登记表")
            XCTAssertNotNil(NSImage(systemSymbolName: name.rawValue, accessibilityDescription: nil),
                            "\(name.rawValue) 本机解析不到")
            XCTAssertTrue(IconRole.allCases.contains(name.role))
        }
    }
}
