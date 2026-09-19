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

    func testSidebarItemShowsPlaceholderRatherThanZeroWhenUnscored() {
        let unscored = Theme.Sidebar.Item(title: " demo ", icon: .code, score: nil, isScored: false)
        XCTAssertEqual(unscored.scoreText, "--", "未分析的项目点旁显示 0 = 把没扫说成 0 分")
        let scored = Theme.Sidebar.Item(title: "demo", icon: .code, score: 0, isScored: true)
        XCTAssertEqual(scored.scoreText, "0", "真 0 分要照实显示")
    }

    func testEmptyCardUsesQuestionMarkNotCheckmarkWhenUnscanned() {
        let never = Theme.Empty.Card(evidence: .notCollected, title: "错误日志")
        XCTAssertEqual(never.icon, .unverified)
        XCTAssertNotEqual(never.icon, .noRisk, "没查过却画对勾 = 本轮 P0 的同一个坑")

        let scanned = Theme.Empty.Card(evidence: .scannedEmpty, title: "错误日志")
        XCTAssertNotEqual(scanned.icon, .noRisk)
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

    /// 按键取色必须**等价于**按号取色——两者走同一条路，页面才没有第二条凑色路径。
    func testColorForLabelIsDefinedExactlyByItsIndex() {
        for appearance in [DesignAppearance.light, .dark] {
            for key in ["npm", "maven", "Swift", "go module", "☃"] {
                let byLabel = Theme.Chart.token(forLabel: key, in: appearance)
                let byIndex = Theme.Chart.pair(at: Theme.Chart.index(forLabel: key))
                    .token(in: appearance)
                XCTAssertEqual(byLabel, byIndex,
                               "键「\(key)」的两条取色路径已经分叉")
            }
        }
    }

    func testSeriesRegistryIndicesAllResolveInsideThePalette() {
        for (name, index) in Theme.Chart.Series.allRegistered {
            XCTAssertTrue((0..<Theme.Chart.count).contains(index),
                          "序列 \(name) 登记了越界号位 \(index)")
        }
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

    // MARK: - D. 曲线轴

    func testAxisTicksCoverTheDomainAndSurviveDegenerateSteps() {
        let axis = Theme.Chart.Axis(step: 25, maxValue: 100)
        XCTAssertEqual(axis.ticks, [0, 25, 50, 75, 100])
        XCTAssertFalse(axis.isZoomed)
        XCTAssertEqual(axis.domain, 0...100)

        let zoomed = Theme.Chart.Axis(minValue: 62, step: 10, maxValue: 92)
        XCTAssertTrue(zoomed.isZoomed, "minValue>0 就是收窄轴，必须被标出来")
        XCTAssertEqual(zoomed.ticks.count, 4)

        // 步长为 0 会让 while 循环永不停止——这一条是给未来的自己上的保险
        XCTAssertEqual(Theme.Chart.Axis(step: 0, maxValue: 100).ticks, [0])
        XCTAssertTrue(Theme.Chart.Axis(step: -5, maxValue: 100).ticks.count <= 1)
    }

    // MARK: - E. 表格与排序

    func testNumericColumnsDefaultToTrailingAlignment() {
        // 左对齐时位数不同的数字看不出谁大，所以数字列默认尾随
        XCTAssertEqual(Theme.Table.Column("CC").alignment, .trailing)
        XCTAssertEqual(Theme.Table.ColumnAlignment.numeric, .trailing)
        XCTAssertEqual(Theme.Table.Column("名称", 220, .leading).alignment, .leading)
    }

    func testColumnsAreNotSortableUntilGivenASortKey() {
        XCTAssertFalse(Theme.Table.Column("备注").isSortable)
        XCTAssertTrue(Theme.Table.Column("CC", 40, .trailing, sortKey: "cc").isSortable)
    }

    func testSortTogglingFlipsSameColumnAndStartsDescendingOnNewColumn() {
        let cc = Theme.Table.Column("CC", 40, .trailing, sortKey: "cc")
        let name = Theme.Table.Column("名称", 220, .leading, sortKey: "name")
        let current = Theme.Table.Sort(key: "cc", ascending: true)
        XCTAssertFalse(current.toggling(cc).ascending, "同列再点应翻向")
        XCTAssertEqual(current.toggling(name).key, "name")
        XCTAssertFalse(current.toggling(name).ascending, "换列默认大的在前")
    }

    func testColumnLookupFallsBackElasticallyInsteadOfCrashing() {
        let columns = [Theme.Table.Column("名称", 220, .leading)]
        XCTAssertEqual(Theme.Table.column(columns, 0).width, 220)
        XCTAssertNil(Theme.Table.column(columns, 9).width, "越界应退回弹性列而不是崩溃")
        XCTAssertEqual(Theme.Table.column([], -1).title, "")
    }

    func testRowTintIsExactlyHalfTheBadgeFill() {
        // 整屏表格若用徽标那档饱和度会被色块盖住，所以行底固定比徽标底弱一半
        XCTAssertEqual(Theme.Table.rowTintAlpha, Theme.Palette.Opacity.badgeFill / 2)
        XCTAssertLessThan(Theme.Table.rowTintAlpha, Theme.Palette.Opacity.badgeFill)
    }

    /// 元测试：解释为什么整套设计系统单测**从不**拿 `Color` 做等号断言。
    /// 语义色由 `NSColor(name:dynamicProvider:)` 现造，描述里带 UUID
    /// （实测形如 `#$customDynamic 6D2B48CA-…`），所以两个取值相同的动态色永远不相等。
    /// 谁想加 `XCTAssertEqual(someColor, anotherColor)`，先让这条把它绊倒。
    func testDynamicColorsCannotBeComparedSoAssertOnTokensInstead() {
        let light = Theme.Semantic.success.textColor
        let sameAgain = Theme.Semantic.success.textColor
        XCTAssertNotEqual(String(describing: light), String(describing: sameAgain),
                          "动态色居然可比较了——那所有基于角色名的断言可以简化，请一并复核")
        // 可比较的是令牌本身
        XCTAssertEqual(Theme.Semantic.success.text.light, Theme.Semantic.success.text.light)
    }

    func testTableAndSidebarRowHeightsAreOrdered() {
        XCTAssertLessThan(Theme.Layout.rowHeightCompact, Theme.Layout.rowHeightTable)
        XCTAssertLessThan(Theme.Layout.rowHeightTable, Theme.Layout.rowHeightSidebar)
        XCTAssertGreaterThanOrEqual(Theme.Layout.rowHeightCompact, Theme.Layout.minHitTarget)
    }

    func testGaugeHeightTiersMatchSpec() {
        XCTAssertEqual(Theme.Layout.gaugeSection, 4)
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
