import XCTest
@testable import TcoderMonitor

/// OWNER: WS-S2 代码两页 —— 「代码规模」与「复杂度风险」两页把碎文案收进 ⓘ 的**页面级**守卫。
///
/// 三条成对守卫（A 常驻长句只减不增 / B 口径总量守恒 / C 核心承诺常驻）住在
/// `TooltipMigrationGuardTests`，那个文件只由总工写：本文件**一条判据都不改**，
/// 只复用它的尺子（`scan` / `sight` / `viewFiles`），把结论收窄到本片两个目录，
/// 让"这页到底搬没搬干净"能在页面级被反驳，而不是只信一个总数。
///
/// 两条判据各配"注入坏样例必须红"的元测试（本仓老坑：只出 0 违例却抓不住坏样例的守卫
/// 比没有守卫更危险），外加一条扫描面自证：
///   ① 说好进 ⓘ 的长句：tooltip 侧有且只有一个落点，可见侧一处都不许再出现（两处都在 = 没搬）；
///   ② 屏上留下的短标签：必须仍有非 tooltip 的落点（本片的诚实性下界。它比 A 棘轮严 ——
///      A 只按长度数数，这里点名到句，谁把短句连着删了立刻红）。
final class CodeGitTooltipTests: XCTestCase {

    // MARK: - 名单（逐条对应盘点表 B / C 组本轮做完的那 11 条）

    /// 以**字面量**形式搬进 ⓘ 槽（`CopyHelpBadge("…")` / `.help("…")`）的长句。
    /// 必须与源码里的字面量逐字相同 —— 这条名单同时是"B 守恒没有靠复印件达成"的证据。
    static let stowedCalibers: [String] = [
        "代码 / 注释 / 空行共同构成总行数",                      // B1（判删 → 整条进 ⓘ）
        "总行数（= 空行 + 注释 + 代码）",                        // B2
        "仅概览数字，明细见「复杂度风险」页",                      // B14（判藏）
        "重复块 %1$@ 个 · 复杂度上榜 %2$@ 个函数",                // B17（判删 → 整条进 ⓘ）
        "识别规则降级：%1$@ 条正则没能编译，函数数与圈复杂度会偏低。这一屏的 0 读作「我们的规则没跑起来」，不读作「这个仓库没有函数」。",  // B7
        "源码里留下的待办标记，只代表历史备注，不代表当前缺陷",       // B8
        "的代码行落在重复块内 —— 综合风险 %1$@，明细见下方「重复代码率」",  // C1
        "口径：%1$@ 个文件 · %2$@ 行有效代码 · 主语言 %3$@",      // C2
        "分母是有效代码行数（不含空行与注释）· 分子是落在重复块内的代码行",  // C3
        "点击行在 Finder 中定位源文件，行尾图标用默认应用打开。",     // C8（判藏）
        "逐条对应本次扫描的真实数字，无数字支撑的不写",              // C9（判藏）
    ]

    /// 屏上留下的短标签，一律取自原句（盘点表「留短藏长」的那半句 + 未被搬走的那半）。
    static let keptOnScreen: [String] = [
        "总行数",                            // B2 的头（等式本身另由 `CodeInvariantRow` 常驻）
        "按有效代码行计",                       // B3 的头 = 分母口径
        "「其他」合并了占比最低的 %1$@ 种语言",      // B5 的头
        "识别规则降级：%1$@ 条正则没能编译",        // B7 认账的那半句
        "源码里留下的待办标记",                   // B8 的头
        "已完成扫描：",                         // B9 零标记支：整句即诚实凭据，未拆
        "的代码行落在重复块内",                   // C1 的头
        "行有效代码",                          // C2 屏上留下的三个数
        "分母是有效代码行数",                    // C3 的头
    ]

    // MARK: - 尺子（复用总工那一条，本文件不另造第二把）

    static func sliceFiles() throws -> [(path: String, content: String)] {
        try TooltipMigrationGuardTests.viewFiles().filter { $0.path.hasPrefix("Views/Code") }
    }

    // MARK: - 判据 ①：搬走的长句，落点在 ⓘ 且只有一个是

    func test_stowedCalibersLandExactlyOnceInTheTooltipSlot() throws {
        let (visible, tooltip) = TooltipMigrationGuardTests.scan(try Self.sliceFiles())
        let visibleTexts = visible.map(\.text)
        var offenders: [String] = []
        for sentence in Self.stowedCalibers {
            let landed = tooltip.filter { $0.text == sentence }
            if landed.count != 1 {
                offenders.append("「\(sentence.prefix(16))…」在 ⓘ 侧应有 1 个落点，实到 \(landed.count)")
            }
            if visibleTexts.contains(where: { $0.contains(sentence) }) {
                offenders.append("「\(sentence.prefix(16))…」仍占着可见槽位 —— 搬了个复印件")
            }
        }
        XCTAssertTrue(offenders.isEmpty, offenders.joined(separator: "\n"))
        // 分母自证：名单与实测都不许空转
        XCTAssertGreaterThanOrEqual(Self.stowedCalibers.count, 10)
        XCTAssertGreaterThanOrEqual(tooltip.count, Self.stowedCalibers.count)
    }

    // MARK: - 判据 ②：留下的短句必须仍在屏上

    func test_shortLabelsStayOnScreen() throws {
        let files = try Self.sliceFiles()
        var offenders: [String] = []
        for fragment in Self.keptOnScreen {
            let sightings = TooltipMigrationGuardTests.sight(fragment, in: files)
            if sightings.isEmpty {
                offenders.append("「\(fragment)」整片找不到 —— 短句被连着删掉了")
            } else if sightings.allSatisfy(\.inTooltip) {
                offenders.append("「\(fragment)」只剩 hover 可见（\(sightings[0].path)）")
            }
        }
        XCTAssertTrue(offenders.isEmpty, offenders.joined(separator: "\n"))
        XCTAssertGreaterThanOrEqual(Self.keptOnScreen.count, 8)
    }

    // MARK: - 元测试：两条判据都得抓得住坏样例，且不误伤合法写法

    func test_meta_stowJudgeCatchesTheCopiedButNotMovedShape() {
        let long = "分母是有效代码行数（不含空行与注释）· 分子是落在重复块内的代码行"
        let moved = [(path: "Views/Code/Fake.swift", content: """
        GlassSection("重复代码率", subtitle: "分母是有效代码行数", icon: .duplicate,
                     trailing: AnyView(CopyHelpBadge("\(long)"))) {
            DataFootnote(text: "共 12 个")
        }
        """)]
        let notMoved = [(path: "Views/Code/Fake.swift", content: """
        GlassSection("重复代码率", subtitle: "\(long)", icon: .duplicate) {
            DataFootnote(text: "共 12 个")
        }
        """)]
        let movedScan = TooltipMigrationGuardTests.scan(moved)
        XCTAssertEqual(movedScan.tooltip.filter { $0.text == long }.count, 1,
                       "合法形状（整句在 ⓘ）没被认成 tooltip 落点")
        XCTAssertEqual(movedScan.visible.filter { $0.text.contains(long) }.count, 0,
                       "已搬走却被算成常驻 —— 这条尺子会把正常的搬运判成违例")
        let halfScan = TooltipMigrationGuardTests.scan(notMoved)
        XCTAssertEqual(halfScan.visible.filter { $0.text.contains(long) }.count, 1,
                       "长句仍占可见槽位却没被抓到 —— 判据 ① 是摆设")
        XCTAssertEqual(halfScan.tooltip.filter { $0.text == long }.count, 0)
    }

    func test_meta_sightJudgeSeparatesScreenFromHover() {
        let onScreen = [(path: "Views/Code/Fake.swift", content: """
        GlassSection("总量构成", subtitle: "按有效代码行计", icon: .code)
        """)]
        let onlyHover = [(path: "Views/Code/Fake.swift", content: """
        CopyHelpBadge("按有效代码行计，共 7 种语言")
        """)]
        let screen = TooltipMigrationGuardTests.sight("按有效代码行计", in: onScreen)
        XCTAssertEqual(screen.count, 1)
        XCTAssertTrue(screen.allSatisfy { !$0.inTooltip }, "屏上写法被判成了 hover")
        let hover = TooltipMigrationGuardTests.sight("按有效代码行计", in: onlyHover)
        XCTAssertEqual(hover.count, 1)
        XCTAssertTrue(hover.allSatisfy(\.inTooltip), "hover 写法没被抓出来 —— 判据 ② 是永真绿")
    }

    /// 扫描面自证：本片两个目录真被读到，否则上面两条全是空跑。
    func test_scannerActuallySeesThisSlicesFiles() throws {
        let files = try Self.sliceFiles()
        XCTAssertGreaterThanOrEqual(files.count, 8,
                                   "本片只扫到 \(files.count) 个页面文件，读盘或目录名变了")
        XCTAssertTrue(files.contains { $0.path.contains("CodeMetricsView") })
        XCTAssertTrue(files.contains { $0.path.contains("CodeRiskView") })
    }
}
