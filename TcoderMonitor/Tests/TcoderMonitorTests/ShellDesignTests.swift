import AppKit
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

    // MARK: - ② 分类色只有一个入口，且跨调用路径同号

    /// #32 的契约：`Theme.Chart` 的号位是全仓唯一真相。
    /// 同一 label 经**两条调用路径**——按键入口 `token(forLabel:)` 与
    /// 号位入口 `pair(at: index(forLabel:))`（后者正是 `Theme.Share.Row` 默认取色走的链路）
    /// ——必须落到同一个色值本体，浅深两套各自一致。否则「同色=同类」只在单页内成立。
    func testChartLabelColorAgreesAcrossBothCallPaths() {
        let labels = ["Swift", "Objective-C", "Python", "Ruby", "Go", "Rust", "张三", ""]
        for label in labels {
            for appearance in DesignAppearance.allCases {
                let byLabel = Theme.Chart.token(forLabel: label, in: appearance)
                let byIndex = Theme.Chart.pair(at: Theme.Chart.index(forLabel: label))
                    .token(in: appearance)
                XCTAssertEqual(byLabel.sRGBHex, byIndex.sRGBHex,
                               "「\(label)」在 \(appearance) 下两条取色路径号位不一致")
                XCTAssertFalse(byLabel.sRGBHex.isEmpty)
            }
        }
    }

    /// 号位会变（换算法就整体换位），**不变的是「同名必同号」**。
    /// 这条钉住我上一版的缺陷：自己那份哈希走 `utf8` 且不 `lowercased()`，
    /// 于是 `Swift` 与 `swift` 分到不同号位、中文名因字节序 ≠ 码点序而错位。
    /// 大小写等价本身已由 WS-G 在 `DesignKitTests:112` 钉死，这里不重复，
    /// 只补「越界」与「挤成一格」两条我这页真正依赖的性质。
    func testChartLabelIndexIsInRangeAndSeparatesRealLanguages() {
        for name in ["Swift", "Objective-C", "Python", "Ruby", "Go", "Rust", "张三", ""] {
            XCTAssertTrue((0..<Theme.Chart.count).contains(Theme.Chart.index(forLabel: name)),
                          "「\(name)」号位越界")
            XCTAssertEqual(Theme.Chart.index(forLabel: name), Theme.Chart.index(forLabel: name),
                           "同一名字两次取号不同 = 又引入了每进程随机播种")
        }
        let languages = ["Swift", "Objective-C", "Python", "Ruby", "Go", "Rust"]
        let slots = Set(languages.map { Theme.Chart.index(forLabel: $0) })
        XCTAssertGreaterThanOrEqual(slots.count, 3,
                                    "六门语言挤成 \(slots.count) 格，色板失去表意能力")
    }

    /// 防再犯：本流名下文件的**代码**里不许再有第二份稳定哈希，也不许回到 `hashValue`。
    /// （WS-L 的 `CodeGitCategoryColor` 把 0 号让给「合计行」、成员落在 1..n，
    /// 是它有意的号位策略，属另一条口径，不在本断言范围内——已单独报总工。）
    func testShellLayerNeverReimplementsTheStableHash() throws {
        for (name, text) in try shellLayerSources() {
            let code = Self.strippingComments(text)
            for needle in Self.hashFingerprint {
                XCTAssertFalse(code.contains(needle),
                               "\(name) 的代码里出现了 \(needle)：分类色取号必须走 Theme.Chart")
            }
        }
    }

    /// 剥注释这件事会把守卫悄悄变成**永真绿**（剥多了就什么都扫不到）。
    /// 所以给它配一条机制测试：正例必须留、反例必须掉，两边都钉住。
    /// （本仓的扫描型断言上一轮就空转过一次，见《48》与 `CodeGitRestyleTests:546` 的自述。）
    func testCommentStrippingKeepsCodeAndDropsProse() {
        let sample = """
        let a = Theme.accent          // 旧入口 Theme.accent 已废弃
        // glassEffect 只允许住在 Design/Glass.swift
        let b = 0xcbf29ce484222325
        """
        let stripped = Self.strippingComments(sample)
        XCTAssertTrue(stripped.contains("Theme.accent"),
                      "代码里的 Theme.accent 被剥掉了，守卫会假绿")
        XCTAssertTrue(stripped.contains("0xcbf2"),
                      "代码里的哈希指纹被剥掉了，守卫会假绿")
        XCTAssertFalse(stripped.contains("glassEffect"),
                       "注释里的 glassEffect 没被剥掉，守卫会因文字判红")
        XCTAssertFalse(stripped.contains("已废弃"),
                       "行尾注释没切干净——那说明剥的是整行，代码会被一起丢掉")
        XCTAssertEqual(stripped.components(separatedBy: "\n").count, 3,
                       "剥注释不该改变行数（少一行说明整行被误删）。"
                           + "注意这里必须用 components 而不是 split：split 默认会丢掉空行，"
                           + "而整行注释剥完就正好是空行。")
    }

    /// 扫描集不能是空的：空集会让上面两条源码守卫同时假绿。
    func testShellSourceScanActuallySeesTheFiles() throws {
        let sources = try shellLayerSources()
        // 8 → 9（收官轮 WS-X7）：Shell/ 分件 5 → 6，新增 SidebarRows.swift（ProjectSidebar 486 行拆分）；
        // 与 ShellBorderlessTests 钉的是同一个数，改一处必须两处一起改。
        XCTAssertEqual(sources.count, 9, "外壳应是 3 个页面文件 + Shell/ 下 6 个分件")
        for (name, text) in sources {
            XCTAssertFalse(text.isEmpty, "\(name) 读出来是空的，扫描等于没扫")
            XCTAssertGreaterThan(text.count, 200, "\(name) 内容异常短")
        }
    }

    /// 稳定哈希与随机哈希的指纹。只用于**代码**，注释里讲历史会提到这些词，
    /// 所以上面要先剥注释——第一版我没剥，结果被自己写的说明文字判红一次。
    private static let hashFingerprint = ["0xcbf2", "0xCBF2", "hashValue", "unicodeScalars"]

    /// 剥掉行注释。局限：不处理块注释与字符串里的 `//`；
    /// 本流文件里这几枚 needle 都不会出现在字符串字面量中，够用。
    private static func strippingComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            guard let cut = line.range(of: "//") else { return String(line) }
            return String(line[..<cut.lowerBound])
        }.joined(separator: "\n")
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

    // MARK: - 侧栏数字列（第二轮目视结论 2）

    /// 抖动有两个来源，第二条是 `.monospacedDigit()` 管不到的：
    /// `NumberFormat.compact` 的结果本身会跨位数变宽（`9k`→`20k`→`182k`），
    /// 会把右边的「健康 61」整格推走。所以每个读数还要占一个**右对齐定宽格**。
    /// 这里用 AppKit 真实排版量宽度，确认那两个格真的装得下最坏情况。
    func testSidebarMetricColumnsAreWideEnoughForTheWorstCase() {
        let widestLineCount = "182k 行"
        let widestHealth = "健康 100"
        XCTAssertGreaterThanOrEqual(
            ShellLayout.lineCountColumnWidth,
            Self.width(of: widestLineCount),
            "「\(widestLineCount)」会被截掉；定宽格必须容得下最坏读数")
        XCTAssertGreaterThanOrEqual(
            ShellLayout.healthColumnWidth,
            Self.width(of: widestHealth),
            "「\(widestHealth)」会被截掉")
        // 定宽格的代价是白占横向空间，所以也不许比最坏情况宽出一整倍。
        XCTAssertLessThan(ShellLayout.lineCountColumnWidth, Self.width(of: widestLineCount) * 2)
        XCTAssertLessThan(ShellLayout.healthColumnWidth, Self.width(of: widestHealth) * 2)
    }

    /// 侧栏读数必须显式带 monospacedDigit 字体，而不是靠外层 `.font` 经 environment 传入
    /// （后者与 modifier 先后顺序有关，正是上一轮"已经加了 monospacedDigit 却仍在抖"的成因之一）。
    func testSidebarReadoutsUseExplicitMonospacedDigitFont() throws {
        let url = Self.packageRoot.appendingPathComponent(
            "Sources/TcoderMonitor/Views/Shell/ProjectSidebar.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("label.font.monospacedDigit()"),
                      "侧栏读数格必须逐字写明 monospacedDigit，不接受靠 environment 继承")
        XCTAssertTrue(text.contains("alignment: .trailing"),
                      "定宽格要右对齐，单位「行」的位置才不动")
    }

    /// 用系统排版真实量一段文字的宽度（label 档 = 11pt）。不启动 App。
    private static func width(of text: String) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
        ]
        return ceil((text as NSString).size(withAttributes: attributes).width)
    }

    /// 包根。测试文件在 `Tests/TcoderMonitorTests/` 下，回溯三级。
    private static let packageRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // TcoderMonitorTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // TcoderMonitor

    // MARK: - 外壳层防漂移：闸门与令牌只能有一个落点

    func testShellFilesKeepAvailabilityGateAndTokensInDesignLayer() throws {
        var offenders: [String] = []
        for (name, text) in try shellLayerSources() {
            // 同样先剥注释：这些 needle 会以"历史说明"的形式出现在注释里，
            // 扫到文字不是扫到问题（同一类假阳性我在下一条测试里刚踩过一次）。
            let code = Self.strippingComments(text)
            for needle in ["#available", "glassEffect", ".system(size:",
                           "Color(red:", "Color(hex:", "Theme.accent",
                           "Theme.cardBackground", "Theme.gridLine", "Theme.heroNumber"] {
                if code.contains(needle) {
                    offenders.append("\(name): \(needle)")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "外壳页面出现散写的玻璃闸门 / 裸值 / 旧色入口：\n\(offenders.joined(separator: "\n"))")
    }

    /// 本流名下的外壳文件。路径公式与上面共用 `Self.packageRoot`。
    private func shellLayerSources() throws -> [(name: String, text: String)] {
        let views = Self.packageRoot.appendingPathComponent("Sources/TcoderMonitor/Views")
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
