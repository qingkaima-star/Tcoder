/// OWNER: WS-X3 TestSplit —— 自 CodeGitBorderlessTests.swift 拆出，扫描器反例：合成违规样例必须被自己的尺子抓到。用例本体未改，只是搬了家。
import Foundation
import XCTest
@testable import TcoderMonitor

extension CodeGitBorderlessTests {

    /// 契约 3/5：tertiary 与裸字号两类反例，正反两向都要判得动。
    /// 原为 `test_scannersCatchSyntheticViolations` 的一段（WS-X3 拆分：该函数 154 行超本仓 50 行口径，
    /// 按原节号切成 7 条，断言与夹具文本逐字保留）。
    func test_scannerCatchesSyntheticTertiaryAndBareFonts() {
        // ① .tertiary
        XCTAssertEqual(Self.tertiaryUses(in: [("Code/A.swift",
                                               "Text(x).foregroundStyle(.tertiary)")]),
                       ["Code/A.swift:1"], "测得值上的 tertiary 没抓到")
        XCTAssertTrue(Self.tertiaryUses(in: [("Code/A.swift", "// .tertiary 是旧写法")]).isEmpty,
                      "注释被误判 —— 文档将无法解释自己禁了什么")

        // ② 裸字号
        XCTAssertEqual(Self.bareSystemFonts(in: [("Code/A.swift",
                                                  "let f = Font.system(size: 11)")]).count, 1,
                       "裸字号没抓到")
        XCTAssertEqual(Self.bareSystemFonts(in: [("Code/A.swift",
                                                  "Text(x).font(.system(size: 9))")]).count, 1,
                       "语义字面写法没抓到")
        XCTAssertTrue(Self.bareSystemFonts(in: [("Code/A.swift",
                                                 "// 旧写法 Font.system(size: 11)")]).isEmpty,
                      "注释里的裸字号被误判")
        XCTAssertTrue(Self.bareSystemFonts(in: [("Code/A.swift",
                                                 "let f = Theme.Typo.monoLabel.font")]).isEmpty,
                      "收编之后的合法写法被判违规")
    }

    /// 契约 5：主角数与「绕过原语直用 56pt」两类反例。
    /// 原为 `test_scannersCatchSyntheticViolations` 的一段（WS-X3 拆分：该函数 154 行超本仓 50 行口径，
    /// 按原节号切成 7 条，断言与夹具文本逐字保留）。
    func test_scannerCatchesSyntheticHeroAndBigTier() {
        // ③ 主角
        let twoHeroes = [("Code/A.swift",
                          "DataHeroReadout(value: a)\nDataHeroReadout(value: b)")]
        XCTAssertEqual(Self.heroCallSites(in: twoHeroes).count, 2,
                       "两枚主角没数出来 —— 「每页一枚」会变成空断言")
        XCTAssertEqual(Self.directBigTierUses(in: [("Code/A.swift",
                                                    ".font(Theme.Typo.heroMetric.font)")],
                                              tokenNamed: "heroMetric").count, 1,
                       "绕过原语的 56pt 没抓到")
    }

    /// §M0 4/§P-8：手排分组容器与第二份页骨架。
    /// 原为 `test_scannersCatchSyntheticViolations` 的一段（WS-X3 拆分：该函数 154 行超本仓 50 行口径，
    /// 按原节号切成 7 条，断言与夹具文本逐字保留）。
    func test_scannerCatchesHandRolledContainersAndSecondScaffold() {
        // ④ 手写容器
        let dirtyStack = "VStack(spacing: 16) {\n"
            + "    GlassSection(\"甲\") { EmptyView() }\n"
            + "    GlassSection(\"乙\") { EmptyView() }\n}"
        XCTAssertEqual(Self.handRolledGroupContainers(in: [("Code/A.swift", dirtyStack)]).count, 1,
                       "页面自己排 GlassSection 没抓到 → 间距档位形同虚设")
        let namedStack = "Theme.Page.Scaffold {\n"
            + "    GroupStack {\n"
            + "        GlassSection(\"甲\") { EmptyView() }\n"
            + "    }\n}"
        XCTAssertTrue(Self.handRolledGroupContainers(in: [("Code/A.swift", namedStack)]).isEmpty,
                      "命名容器被误判 —— 合法写法将无法表达")
        // 缩进这一维的真样本：section **内部**的 VStack，它的兄弟节点恰好是下一个 section。
        // 不判缩进就会误报（本文件第一版就真的误报了 CodeMetricsView.swift:151）。
        let innerStack = "GlassSection(\"代码规模\") {\n"
            + "    VStack(alignment: .leading, spacing: Theme.Spacing.md) {\n"
            + "        DataHeroReadout(value: \"1\")\n"
            + "    }\n"
            + "}\n"
            + "GlassSection(\"语言构成\") {\n    EmptyView()\n}"
        XCTAssertTrue(Self.handRolledGroupContainers(in: [("Code/A.swift", innerStack)]).isEmpty,
                      "section 内部的 VStack 被误判成手排容器 —— 缩进这一维丢了")
        XCTAssertTrue(Self.handRolledGroupContainers(in: [("CodeGit/Kit.swift", dirtyStack)]).isEmpty,
                      "基座被误判 —— 容器实现本来就只许写在基座里")

        // ④b 页骨架重复：脏样本必须认得出来，否则「本流不得有第二份」是永真绿
        XCTAssertEqual(Self.pageScaffoldDeclarations(in: [("CodeGit/Kit.swift",
            "struct DataPageScaffold<Content: View>: View {\n    var body: some View { EmptyView() }\n}")]),
                       ["CodeGit/Kit.swift:1"], "第二份页骨架没认出来 —— 那条断言是假的")
        XCTAssertTrue(Self.pageScaffoldDeclarations(in: [("CodeGit/Kit.swift",
            "struct GroupStack<Content: View>: View {\n    var body: some View { EmptyView() }\n}")]).isEmpty,
                      "普通容器被判成页骨架 —— 五页会因此写不出分组")
        XCTAssertTrue(Self.pageScaffoldDeclarations(in: [("CodeGit/Kit.swift",
            "Theme.Page.Scaffold {\n}  // 用法不是声明，不该算一份")]).isEmpty,
                      "骨架的**调用点**被当成声明 —— 那五页必然全红")
    }

    /// 契约 5：数据色不撞 accent/info、非交互件不涂蓝。
    /// 原为 `test_scannersCatchSyntheticViolations` 的一段（WS-X3 拆分：该函数 154 行超本仓 50 行口径，
    /// 按原节号切成 7 条，断言与夹具文本逐字保留）。
    func test_scannerCatchesDataTintAndAccentOutsideInteractive() {
        // ⑤ 倾向色
        let accentTint = [("Code/A.swift", "tint: Theme.Semantic.accent.textColor)")]
        XCTAssertEqual(Self.dataTintedWithAccentOrInfo(in: accentTint).count, 1,
                       "tile 显式传 accent 没抓到 —— 本轮蓝数字的直接成因")
        let infoTint = [("Code/A.swift", "MetricTile(label: x, tint: Theme.Semantic.info.textColor)")]
        XCTAssertEqual(Self.dataTintedWithAccentOrInfo(in: infoTint).count, 1,
                       "tile 显式传 info 没抓到")
        let roleTint = [("Code/A.swift", "role: Theme.Semantic.danger")]
        XCTAssertTrue(Self.dataTintedWithAccentOrInfo(in: roleTint).isEmpty,
                      "状态语义色被误判 —— 风险与增删必须留色")

        let shaRow = "struct GitCommitRow: View {\n"
            + "    var body: some View {\n"
            + "        Text(sha).foregroundStyle(Theme.Semantic.accent.textColor)\n"
            + "    }\n}"
        XCTAssertEqual(Self.accentOutsideInteractiveViews(in: [("Git/A.swift", shaRow)]).count, 1,
                       "非交互件涂 accent 没抓到")
        let openButton = "struct CodeOpenFileButton: View {\n"
            + "    var body: some View {\n"
            + "        Button {} label: { icon.foregroundStyle(Theme.Semantic.accent.textColor) }\n"
            + "    }\n}"
        XCTAssertTrue(Self.accentOutsideInteractiveViews(in: [("Code/A.swift", openButton)]).isEmpty,
                      "按钮上的 accent 被判违规 —— 交互本身就是语义，蓝就是它的意思")
        XCTAssertTrue(Self.accentOutsideInteractiveViews(in: [("Code/A.swift",
                                                               "// 见 Theme.Semantic.accent 的讨论")]).isEmpty,
                      "注释被误判")
        XCTAssertEqual(Self.declaredStructName(in: "struct GitCommitRow: View {"), "GitCommitRow",
                       "块名解析失灵，上面两条 accent 判据会一起失真")
        XCTAssertTrue(Self.isInteractive("CodeOpenFileButton"))
        XCTAssertFalse(Self.isInteractive("GitCommitRow"))
    }

    /// 契约 5 保留侧：徽标 role: accent 放行，同行文本仍判违规。
    /// 原为 `test_scannersCatchSyntheticViolations` 的一段（WS-X3 拆分：该函数 154 行超本仓 50 行口径，
    /// 按原节号切成 7 条，断言与夹具文本逐字保留）。
    func test_scannerKeepsBadgeRoleAccentAndCatchesTextTint() {
        // ⑤b 徽标 role: accent 是「选中态」，放行的是这个形状，不是整行
        let badgeRow = "struct GitNestedCandidateRow: View {\n"
            + "    SemanticBadge(\"当前分析对象\", role: Theme.Semantic.accent, icon: .info)\n}"
        XCTAssertTrue(Self.accentOutsideInteractiveViews(in: [("Git/A.swift", badgeRow)]).isEmpty,
                      "徽标的 role: accent 被判违规 —— 它标的是选中态，属契约 5 保留侧")
        let textRow = "struct GitNestedCandidateRow: View {\n"
            + "    Text(x).foregroundStyle(Theme.Semantic.accent.textColor)\n}"
        XCTAssertEqual(Self.accentOutsideInteractiveViews(in: [("Git/A.swift", textRow)]).count, 1,
                      "同一非交互视图里的文本涂蓝没抓到 —— 说明放行做宽了，整行都放过了")
        XCTAssertFalse(Self.isBadgeRoleArgument("Text(x).role(Theme.Semantic.accent)"),
                       "没有 SemanticBadge 也算徽标，会放过任意一行")
    }

    /// §M0 4/6：井、表格进井、读数条、色板 0 号位。
    /// 原为 `test_scannersCatchSyntheticViolations` 的一段（WS-X3 拆分：该函数 154 行超本仓 50 行口径，
    /// 按原节号切成 7 条，断言与夹具文本逐字保留）。
    func test_scannerCatchesWellsTablesReadoutsAndAggregateIndex() {
        // ⑥ 面
        XCTAssertEqual(Self.wellsOutsideKit(in: [("Git/A.swift",
                                                  ".surface(layer: .contentInset)")]).count, 1,
                       "页面自己画井没抓到")
        XCTAssertTrue(Self.wellsOutsideKit(in: [("CodeGit/Kit.swift",
                                                 ".surface(layer: .contentInset)")]).isEmpty,
                      "基座里的井被判违规 —— DataTableWell 就没法写了")
        XCTAssertEqual(Self.tablesWithoutWell(in: [("Code/A.swift",
                                                    "DataTableHeader(columns: c)")]),
                       ["Code/A.swift"], "有列头没进井没抓到")
        XCTAssertTrue(Self.tablesWithoutWell(in: [("Code/A.swift",
                                                   "DataTableWell { DataTableHeader(columns: c) }")]).isEmpty,
                      "进了井的表被判违规")
        XCTAssertEqual(Self.readoutBarsUsed(in: [("Code/A.swift", "DataReadoutBar { }")]).count, 1,
                      "读数条画井没抓到")
        // 色板 0 号位：单序列图占位必须抓到，成员索引色不得误判
        XCTAssertEqual(Self.aggregateIndexUses(in: [("Git/A.swift",
            "BarMark(x: v).foregroundStyle(Theme.Chart.color(at: CodeGitCategoryColor.aggregateIndex))")]).count,
                       1, "单序列图占 0 号位没抓到 —— 这条守卫就是空的")
        XCTAssertTrue(Self.aggregateIndexUses(in: [("Git/A.swift",
            "DataShareBarRow(label: \"合计\", tint: Theme.Chart.color(at: other))")]).isEmpty,
                      "其他索引色被误判成合计行专用位")
    }

    /// §M0 7/契约 6：散写材质与裸圆角数字（Canvas 几何豁免）。
    /// 原为 `test_scannersCatchSyntheticViolations` 的一段（WS-X3 拆分：该函数 154 行超本仓 50 行口径，
    /// 按原节号切成 7 条，断言与夹具文本逐字保留）。
    func test_scannerCatchesMaterialsAndRawCorners() {
        // ⑦ 材质与裸圆角
        XCTAssertEqual(Self.materialUses(in: [("Git/A.swift",
            "Text(t).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))")]).count, 1,
            "页面散写材质没抓到 —— 这正是 P-1 漏进来的那一处")
        XCTAssertEqual(Self.materialUses(in: [("Git/A.swift",
            "Overlay().background(.thinMaterial)")]).count, 1, "thinMaterial 这一档没被抓到")
        XCTAssertTrue(Self.materialUses(in: [("CodeGit/Kit.swift",
            "// 旧写法 .regularMaterial 会糊成脏灰")]).isEmpty, "注释里的材质名被误判")
        XCTAssertEqual(Self.rawCornerRadius(in: [("Git/A.swift",
            "RoundedRectangle(cornerRadius: 4)")]).count, 1, "裸圆角数字没抓到")
        XCTAssertTrue(Self.rawCornerRadius(in: [("Git/A.swift",
            "RoundedRectangle(cornerRadius: Theme.Radius.md)")]).isEmpty,
            "走令牌的圆角被判违规 —— 那等于逼页面回去写数字")
        XCTAssertTrue(Self.rawCornerRadius(in: [("Git/A.swift",
            "RoundedRectangle(cornerRadius: Self.barCorner)")]).isEmpty,
            "具名常量被判成魔法数 —— 判据必须只认字面数字")
        XCTAssertTrue(Self.rawCornerRadius(in: [("Git/A.swift",
            "ctx.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(c))")]).isEmpty,
            "Canvas 图表几何被判违规 —— WS-I §9 豁免这一类，判据不许越界")
    }

    /// 反向自证：扫描器真读到了文件。否则本文件所有「空 = 通过」的断言集体假绿。
    func test_sourceScannerActuallyFindsFiles() throws {
        let all = try Self.pageSourceFiles()
        // 13 → 14（收官轮 WS-X0）：自扫点名 CodeRiskAnalysis.suggestions 138 行 / CC 17，
        // 拆出的实现分片落在同目录 Code/CodeRiskAdvice.swift；归属没动。
        // 14 → 15（收官轮 WS-X7）：CodeMetricsView 427 行拆出同目录 Code/CodeMetricsSections.swift；归属没动。
        XCTAssertEqual(all.count, PageScanDenominators.codeGitPageFiles,
                       "\(PageScanDenominators.codeGitRosterText)；"
                          + "数量变了说明有文件被新增或删除（分母单源在 `PageScanDenominators`，"
                          + "`CodeGitRestyleTests` 读的是同一个数）")
        for dir in Self.scannedDirs {
            XCTAssertTrue(all.contains { $0.path.hasPrefix("\(dir)/") },
                          "扫不到 \(dir)/ —— 该目录的全部断言会变成空跑")
        }
        for (page, owned) in Self.pageFiles {
            for name in owned {
                XCTAssertTrue(all.contains { $0.path == name },
                              "页面「\(page)」的 \(name) 不在扫描结果里，该页的主角数会被静默少算")
            }
        }
        XCTAssertFalse(Self.heroCallSites(in: Self.pageOnly(all)).isEmpty,
                       "五页里没有一枚 DataHeroReadout —— 主角约束根本没接线。\n"
                          + "（必须在**页面目录**上判，不是四目录全集：基座里 `struct DataHeroReadout` "
                          + "本身含这个名字，拿全集判会永远为真。）")
        // 真源码里必须仍能扫到至少一处「合法」的井（基座的 DataTableWell），
        // 否则「井只包表格」这一族判据是在跟空集合说话。
        XCTAssertTrue(try Self.pageSourceFiles(dirs: ["CodeGit"])
                          .contains { $0.content.contains("contentInset") },
                      "基座里已经没有井了 —— wellsOutsideKit 变成永真")
    }


    /// 上面那条建议列角色扫描器的双向元测试（扫描型判据没有元测试 = 没在扫）。
    /// 两个方向都要红过一次才算数：脏写法必须被抓、状态行与注释必须不被误判。
    func test_scannerCatchesRawRiskRoleInAdviceButNotInStatusRows() {
        let dirty = [(path: "Code/CodeRiskAdvice.swift", content: """
            items.append(Item(id: "huge-file",
                              role: Theme.Semantic.role(for: largest.risk),
                              text: "按领域或路由拆成多个文件"))
            // role: Theme.Semantic.role(for: legacy.risk) —— 注释里的旧写法不该被抓
            """
        )]
        let hits = Self.adviceItemsWithRawRiskRole(in: dirty)
        XCTAssertEqual(hits.count, 1, "脏写法没被抓到 ⇒ 这条判据是摆设（注释行不算命中）")
        XCTAssertTrue(hits[0].contains("Code/CodeRiskAdvice.swift"), "命中要报得出文件：\(hits)")

        let clean = [
            (path: "Code/CodeRiskAdvice.swift", content: "role: Self.adviceRole(for: largest.risk),"),
            (path: "Code/CodeRiskRows.swift",
             content: "private var role: Theme.SemanticRole { Theme.Semantic.role(for: hotspot.risk) }"),
        ]
        XCTAssertTrue(Self.adviceItemsWithRawRiskRole(in: clean).isEmpty,
                      "状态行与改好的建议行被一起抓 ⇒ 判据越界，下次有人就把整条删掉")
    }

}
