import XCTest
@testable import TcoderMonitor

/// WS-K 外壳与导航重样的守卫测试。
///
/// 只测**纯函数与静态扫描**，不启动 App、不抢构建锁（`AGENTS.md` §3 横切约束 2）。
/// 钉住的是这一轮真正修掉的三类缺陷，防止回潮：
/// ① 「没数据」被渲染成 0 / 红色 / 实心着色点（WS-I §3.4、WS-H §1.4#2、WS-D #6 三家同点）；
/// ② 分类色用每进程随机化的 `hashValue` 取位，导致同一门语言每次启动换一个颜色；
/// ③ 导航符号在本机解析不到时整片画成空白（部署下限 macOS 14，而登记表里有 15/26 的新符号）。
final class ShellDesignTests: XCTestCase {

    // MARK: - ① 三态：没有证据不许伪装成结论

    func testUnscoredProjectIsNeverDrawnAsAFilledHealthDot() {
        XCTAssertEqual(HealthDot.kind(for: nil), .hollow,
                       "未评分必须画空心圈；旧写法 color(forScore: 0) 会把「没扫过」渲染成最危险的红点")
        XCTAssertEqual(HealthDot.kind(for: 0), .filled,
                       "0 分是测出来的结论，照实着色，不能和「未评分」混为一态")
        XCTAssertEqual(HealthDot.kind(for: 87), .filled)
    }

    func testMissingScoreFallsBackToNeutralRole() {
        XCTAssertEqual(Theme.Semantic.role(forScore: nil).name, "neutral",
                       "未评分不该带任何倾向色")
        XCTAssertNotEqual(Theme.Semantic.role(forScore: nil).name,
                          Theme.Semantic.role(forScore: 0).name,
                          "「未评分」与「0 分」若同色，等于把没查说成最差")
    }

    func testThreeStateCopyNeverFakesAZOrGreenCheck() {
        let pending = ShellCopy.notAnalyzed("错误日志")
        XCTAssertTrue(pending.contains("尚未"), "③ 态句式：\(pending)")
        XCTAssertFalse(pending.contains("0"), "缺数据的说明里不得出现数字 0：\(pending)")
        XCTAssertFalse(pending.contains("无风险"), "③ 态不得给出安全结论：\(pending)")

        let emptyScan = ShellCopy.scannedButFoundNone("提交记录")
        XCTAssertTrue(emptyScan.contains("已完成扫描"), "② 态必须交代「查过」：\(emptyScan)")

        XCTAssertEqual(Theme.Placeholder.missingValue, "--",
                       "数字位的占符是全仓约定，改它要同步九页与笔记 40")
    }

    // MARK: - ② 分类色必须稳定

    func testStableIndexIsInRangeAndReproducible() {
        for count in [1, 6, 8] {
            for name in ["Swift", "Objective-C", "Python", "Ruby", "Go", "Rust", ""] {
                let slot = LanguageBar.stableIndex(name, count: count)
                XCTAssertTrue((0..<count).contains(slot), "\(name) → \(slot) 越界（count=\(count)）")
                XCTAssertEqual(slot, LanguageBar.stableIndex(name, count: count))
            }
        }
        XCTAssertEqual(LanguageBar.stableIndex("Swift", count: 0), 0, "count 为 0 时不得崩溃")
    }

    func testStableIndexSeparatesTheLanguagesThisRepoActuallyReports() {
        // 只要不是「所有名字都映到同一格」，色板才有余地表达「同色=同语言」。
        let names = ["Swift", "Objective-C", "Python", "Ruby", "Go", "Rust"]
        let slots = Set(names.map { LanguageBar.stableIndex($0, count: Theme.Chart.count) })
        XCTAssertGreaterThanOrEqual(slots.count, 4,
                                    "六门语言在 \(Theme.Chart.count) 色板里挤成 \(slots.count) 格，色板失去表意能力")
    }

    func testLanguageColorIsIndependentOfSwiftHashValue() {
        // 旧写法是 `abs(share.language.hashValue) % palette.count`。
        // 这里把「稳定哈希 ≠ Swift 的每进程随机哈希」这一条钉成断言：
        // 只有当两者偶发同值时才会漏判，所以用一组长度与字符都不同的键来撞。
        let keys = ["Swift", "swift", "Swift ", "Objective-C", "C", "TypeScript", "Kotlin"]
        let drifted = keys.filter {
            let stable = LanguageBar.stableIndex($0, count: Theme.Chart.count)
            let unstable = abs($0.hashValue) % Theme.Chart.count
            return stable == unstable
        }
        XCTAssertLessThan(drifted.count, keys.count,
                          "全部键都与随机 hashValue 同值，说明 stableIndex 退化成了 hashValue")
    }

    // MARK: - ③ 导航图标：存在性与变体语言

    func testEveryNavIconResolvesToASymbolThatExistsHere() {
        for section in DetailSection.allCases {
            let resolved = IconAvailability.resolve(section.iconName)
            XCTAssertTrue(IconAvailability.isAvailable(resolved),
                          "\(section.title) 的图标 \(resolved) 在本机不存在，会画成空白")
        }
    }

    func testNavIconsAreOnePerPage() {
        let icons = DetailSection.allCases.map { $0.iconName }
        XCTAssertEqual(Set(icons).count, DetailSection.allCases.count,
                       "九页共用了同一个图标，导航条上分不清谁是谁")
    }

    func testUnselectedNavIconsAreNotFillVariants() {
        // WS-H §6.1 规则 3：非 fill = 未选中，fill = 选中。基名带 .fill 会让两态没有差别。
        for section in DetailSection.allCases {
            XCTAssertFalse(section.iconName.rawValue.hasSuffix(".fill"),
                           "\(section.title) 的基名 \(section.iconName.rawValue) 应为非 fill 形态")
        }
    }

    func testSelectedNavSymbolsAlsoExist() {
        for section in DetailSection.allCases {
            guard let selected = section.iconName.selectedSymbol else { continue }
            XCTAssertTrue(IconAvailability.isAvailable(selected),
                          "\(section.title) 的选中态符号 \(selected) 在本机不存在")
        }
    }

    func testSectionIconsCarryNoRawStringLiterals() {
        // 裸符号串是 WS-I §7.2 的头号债；这里守住「页图标只能来自登记表」。
        for section in DetailSection.allCases {
            XCTAssertTrue(IconName.allCases.contains(section.iconName),
                          "\(section.title) 的图标没进 IconName 登记表")
        }
    }

    // MARK: - 导航可达性（把此前无人调用的 requiresReport 接上）

    func testPerformancePageIsReachableWithoutAReport() {
        XCTAssertTrue(DetailSection.performance.isReachable(reportAvailable: false),
                      "性能页读实时采样，没有报告也该可进入")
        let needsScan = DetailSection.allCases.filter { $0.requiresReport }
        XCTAssertEqual(needsScan.count, DetailSection.allCases.count - 1)
        for section in needsScan {
            XCTAssertFalse(section.isReachable(reportAvailable: false))
            XCTAssertTrue(section.isReachable(reportAvailable: true))
        }
    }

    // MARK: - 覆盖率百分比的单位换算

    func testPercentOf100DoesNotMultiplyTwice() {
        // `CoverageMetrics.linePercent` 是 0...100，而 `NumberFormat.percent` 收 0...1，
        // 直接喂会把 45.5% 印成 4550%。
        XCTAssertEqual(DashboardView.percentOf100(45.5, precision: 1), "45.5%")
        XCTAssertEqual(DashboardView.percentOf100(100), "100%")
        XCTAssertEqual(DashboardView.percentOf100(0), "0%")
    }

    func testBannerIconsResolveOnThisMachine() {
        for style in [BannerStyle.warning, .info, .error] {
            XCTAssertTrue(IconAvailability.isAvailable(style.icon.rawValue),
                          "横幅符号 \(style.icon.rawValue) 本机不存在")
            XCTAssertFalse(style.role.name.isEmpty)
        }
    }

    // MARK: - 外壳层防漂移：闸门与令牌只能有一个落点

    func testShellFilesKeepAvailabilityGateAndTokensInDesignLayer() throws {
        let sources = try shellLayerSources()
        var offenders: [String] = []
        for (name, text) in sources {
            for needle in ["#available", "glassEffect", ".system(size:",
                           "Color(red:", "Color(hex:", "Theme.accent",
                           "Theme.cardBackground", "Theme.gridLine", "Theme.heroNumber"] {
                if text.contains(needle) {
                    offenders.append("\(name): \(needle)")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "外壳页面出现散写的玻璃闸门 / 裸值 / 旧色入口：\n\(offenders.joined(separator: "\n"))")
    }

    /// 本流名下的外壳文件。`Tests` 与 `Sources` 同级，从 `#filePath` 回溯到包根。
    private func shellLayerSources() throws -> [(name: String, text: String)] {
        let views = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TcoderMonitorTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // TcoderMonitor
            .appendingPathComponent("Sources/TcoderMonitor/Views")
        var result: [(String, String)] = []
        for name in ["RootView.swift", "ProjectDetailView.swift", "DashboardView.swift"] {
            result.append((name, try read(views.appendingPathComponent(name))))
        }
        let shell = try FileManager.default.contentsOfDirectory(at: views.appendingPathComponent("Shell"),
                                                               includingPropertiesForKeys: nil)
        for file in shell.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            result.append((file.lastPathComponent, try read(file)))
        }
        XCTAssertGreaterThanOrEqual(result.count, 7, "扫描到的外壳文件数异常，路径解析可能已经失效")
        return result
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }
}
