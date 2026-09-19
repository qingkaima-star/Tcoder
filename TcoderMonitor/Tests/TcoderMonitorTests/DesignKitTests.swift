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

    // MARK: - A. Theme.Evidence：缺证据在类型上就不等于 0

    func testEvidenceDisplaysPlaceholderForUnscannedAndZeroForScannedEmpty() {
        XCTAssertEqual(Theme.Evidence.notCollected.displayText, "--")
        XCTAssertEqual(Theme.Evidence.scannedEmpty.displayText,
                       NumberFormat.grouped(0), "扫过且为空 = 真 0，要显示 0")
        XCTAssertEqual(Theme.Evidence.measured("1,024").displayText, "1,024")
        XCTAssertEqual(Theme.Evidence.measured("0").displayText, "0", "测得的 0 必须原样显示")
    }

    /// 核心机制：没证据时**盖掉**调用方给的倾向色。
    func testUnscannedEvidenceForcesNeutralRegardlessOfCallerRole() {
        for preferred in Theme.Semantic.measurable {
            let resolved = Theme.Evidence.notCollected.role(preferred)
            XCTAssertEqual(resolved.name, "neutral",
                           "notCollected 遇到 \(preferred.name) 时被放行了，等于给坏消息/好消息站队")
        }
        // 有证据时不改调用方的判断
        XCTAssertEqual(Theme.Evidence.measured("7").role(Theme.Semantic.danger).name, "danger")
        XCTAssertEqual(Theme.Evidence.scannedEmpty.role(Theme.Semantic.success).name, "success")
    }

    func testOnlyUnscannedEvidenceMayNotAssertAConclusion() {
        XCTAssertFalse(Theme.Evidence.notCollected.permitsConclusion)
        XCTAssertTrue(Theme.Evidence.scannedEmpty.permitsConclusion,
                      "「扫过、确实没有」本身就是结论，不许被一起禁掉")
        XCTAssertTrue(Theme.Evidence.measured("3").permitsConclusion)
    }

    /// 差分型指标（速率、增量）只有首个样本时算不出——这类必须落 notCollected，不能落 0。
    func testOptionalBridgesNilToNotCollectedAndNeverToZero() {
        let unknownRate: Double? = nil
        let firstFrameOnly: Double? = nil
        XCTAssertEqual(Theme.Evidence.optional(unknownRate) { String(format: "%.0f%%", $0) },
                       .notCollected)
        XCTAssertEqual(Theme.Evidence.optional(firstFrameOnly) { "\($0)" }, .notCollected)
        let measuredZero: Int? = 0
        XCTAssertEqual(Theme.Evidence.optional(measuredZero) { NumberFormat.grouped($0) },
                       .measured("0"))
        XCTAssertEqual(Theme.Evidence.optionalCount(nil, scannedEmpty: true), .scannedEmpty)
        XCTAssertEqual(Theme.Evidence.optionalCount(nil, scannedEmpty: false), .notCollected)
        XCTAssertEqual(Theme.Evidence.optionalCount(12, scannedEmpty: true), .measured("12"),
                       "有值时 scannedEmpty 不得覆盖真值")
    }

    // MARK: - B. 数值组件接上三态

    /// `Theme.Evidence` / `Theme.Gauge` / `MetricTile(evidence:)` 目前**页面零引用**：
    /// 页面还在手写 15 处 `?? Theme.Placeholder.missingValue`。保留的理由不是"以后可能用"，
    /// 而是它们是那 15 处手写的收敛目标（#28 已把接线单交总工）。
    /// 若接线单本轮不落地，这三个连同本段测试应一并删除——不要养装饰。
    func testMetricTileEvidenceInitLeavesValueNilWhenAbsent() {
        let absent = MetricTile(label: "今日错误", evidence: .notCollected)
        XCTAssertNil(absent.value, "缺证据被填成了字符串，等于又造出一个假值")
        XCTAssertEqual(MetricTile.displayValue(absent.value), "--")

        let zero = MetricTile(label: "今日错误", evidence: .measured("0"))
        XCTAssertEqual(zero.value, "0")

        let empty = MetricTile(label: "崩溃", evidence: .scannedEmpty)
        XCTAssertEqual(empty.value, "0")
    }

    func testGaugeWithMissingFractionRendersEmptyAndForcesNeutral() {
        XCTAssertTrue(Theme.Gauge.forcesNeutral(fraction: nil),
                      "nil 仍在用倾向色，等于把「没测到」画成 0% 的结论")
        XCTAssertFalse(Theme.Gauge.forcesNeutral(fraction: 0))
        XCTAssertFalse(Theme.Gauge.forcesNeutral(fraction: 0.4))
        XCTAssertEqual(Theme.Gauge.bar(fraction: nil).fraction, 0,
                       "缺测时应给空轨道")
        XCTAssertEqual(Theme.Gauge.bar(fraction: 0.4).fraction, 0.4)
    }

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
