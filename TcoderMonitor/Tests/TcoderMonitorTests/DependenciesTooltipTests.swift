import XCTest
@testable import TcoderMonitor

/// OWNER: WS-S4「ⓘ 碎文案收纳」—— 依赖分析页（`Views/Dependencies/**`）本片搬动的落点守卫。
///
/// 工单：`docs/superpowers/specs/2026-09-21-ui-copy-tooltip-inventory.md` H 组 + Z 节，
/// 计划：`docs/superpowers/plans/2026-09-21-copy-into-tooltips.md` §3（每个"藏"动作
/// 都要能指到一处 `CopyHelpBadge(` / `.help(`，**不是只删了字**）。
///
/// 全站三条尺子（A 只减不增 / B 总量守恒 / C 承诺常驻）由
/// `TooltipMigrationGuardTests` 统一把守，本文件**不复制那三条**，只钉本片特有的四件事：
///   ① 本片搬进 ⓘ 的每一句，落点确实只有**一个**（屏上那份是原句的前半，不是新造的词）；
///   ② 搬走之后，本页"没查 ≠ 没病 / 结论来自内置快照"这一层**仍然常驻**（Z 节全站红线第一位）；
///   ③ 分析器产出的那句长口径（`deps.networkLookupNote`）在渲染处**保持常驻**，
///      只有 hover 可见会被误读成"这页没有漏洞信息"，所以这条是被断言钉住的决定，不是遗漏；
///   ④ 每条扫描型判据配一个"注入坏样例必须红"的元测试（本仓吃过六次假绿）。
final class DependenciesTooltipTests: XCTestCase {

    // MARK: - 读盘

    private static func pageFiles() throws -> [(path: String, content: String)] {
        let files = try SurfaceScanKit.sourceFiles(under: "Views/Dependencies")
        XCTAssertGreaterThanOrEqual(files.count, 3,
                                    "依赖页目录只扫到 \(files.count) 个文件，扫描面坏了")
        return files.sorted { $0.path < $1.path }
    }

    private static func content(of name: String, in files: [(path: String, content: String)]) -> String {
        guard let hit = files.first(where: { $0.path.hasSuffix(name) }) else {
            XCTFail("依赖页目录里找不到 \(name)")
            return ""
        }
        return hit.content
    }

    /// 一个**串**在整页源码里作为字面量出现的次数（剥掉注释行：文档注释里允许引用旧写法）。
    static func literalCount(_ text: String, in files: [(path: String, content: String)]) -> Int {
        let needle = "\"\(text)\""
        return files.reduce(0) { total, file in
            total + file.content.components(separatedBy: "\n")
                .filter { SurfaceScanKit.isCode($0) && $0.contains(needle) }
                .count
        }
    }

    /// 承载 tooltip 的三种全站形状：`.help(`、共用组件 `CopyHelpBadge(`、
    /// Design 已有的 `DataOptionalHelp(help:`（它内部就是 `.help`，只是屏上没有可见问号）。
    static func isTooltipCarrierLine(_ line: String) -> Bool {
        line.contains(".help(") || line.contains("CopyHelpBadge(") || line.contains("DataOptionalHelp(help:")
    }

    // MARK: - ① 本片搬动的句子：一个落点、屏上留的是原句前半

    /// 本片登记的 ⓘ 句子（**只列本片真的搬动的那几句**，不列保持常驻的）。
    /// 值是"为什么这一句可以只 hover 可见"——每条都要能被读者反驳。
    private static let hiddenByThisSlice: [(sentence: String, why: String)] = [
        ("清单来源，名单在上方「风险总览」",
         "纯指路句：生态名单逐字写在同页「风险总览」的「生态」行里，屏上少它不减少可核对性。"),
        ("联网核对会显著变慢，离线时仍会用内置快照",
         "副标题的完整口径；同卡下一行 `statusCaption` 常驻写着「当前为离线模式，版本与漏洞结论来自内置快照」，"
         + "Z 节点名的那层信息没有进 hover。"),
    ]

    func test_hiddenCalibersHaveExactlyOneLandingPoint() throws {
        let files = try Self.pageFiles()
        XCTAssertFalse(Self.hiddenByThisSlice.isEmpty, "登记表空了 —— 这条守卫就在空转")
        for (sentence, why) in Self.hiddenByThisSlice {
            let hits = Self.literalCount(sentence, in: files)
            XCTAssertEqual(hits, 1,
                           "「\(sentence)」在依赖页源码里出现 \(hits) 次（应为 1 次）："
                           + "搬进 ⓘ 之后原处必须真的不再上屏。可藏的理由：\(why)")
            let carriers = files.flatMap { file in
                file.content.components(separatedBy: "\n")
                    .filter { SurfaceScanKit.isCode($0) && $0.contains("\"\(sentence)\"") }
            }
            XCTAssertTrue(carriers.allSatisfy { Self.isTooltipCarrierLine($0) },
                          "「\(sentence)」不在 tooltip 承载位上：\(carriers)")
        }
    }

    /// 屏上留下的短句必须是**原句的子串**（工单硬约束 1：不许新造修辞）。
    func test_screenLabelsAreSubstringsOfTheOriginalCalibers() throws {
        let files = try Self.pageFiles()
        let network = Self.content(of: "NetworkOptionsCard.swift", in: files)
        XCTAssertTrue(network.contains("subtitle: \"联网核对会显著变慢\""),
                      "联网开关卡的屏上短标签不在了")
        XCTAssertTrue("联网核对会显著变慢，离线时仍会用内置快照"
            .contains("联网核对会显著变慢"), "短标签不是原句的子串")

        let view = Self.content(of: "DependenciesView.swift", in: files)
        XCTAssertFalse(view.contains("caption: \"清单来源"),
                       "「生态」格的 caption 又回到屏上了 —— 那句现在是 ⓘ 里的，两处都写就是一屏两遍")
    }

    /// 表格脚注的拆分：屏上那句是原句的第一分句，且两支互斥分支不会同时挂落点。
    func test_tableFootnoteKeepsTheCountOnScreenAndTheSortCaliberInHelp() {
        let truncated = DependencyTable.countNote(total: 40, shown: 12)
        let shownAll = DependencyTable.countNote(total: 8, shown: 8)
        let label = DependencyTable.countLabel(total: 40, shown: 12)
        XCTAssertEqual(label, "当前展示 12 / 40 项。")
        // 屏上那句 = 完整句的第一分句（只把尾部分隔符换成句号），不是另写的话。
        XCTAssertTrue(truncated.hasPrefix(String(label.dropLast())),
                      "屏上那句必须是 ⓘ 那句的开头分句（留短藏长，不是改写）：\(label) / \(truncated)")
        XCTAssertTrue(truncated.contains("按名称排序"), "排序口径整句还在：\(truncated)")
        XCTAssertEqual(DependencyTable.countLabel(total: 8, shown: 8), shownAll,
                       "已全部展示时屏上句与完整句必须同一支，否则 ⓘ 里会重复一遍屏上字")
    }

    /// 折叠计数不许因为"字少了"就丢掉：这是 Z 节"分母必须讲"的那一类。
    func test_truncationCountStaysOnScreen() {
        XCTAssertTrue(DependencyTable.countLabel(total: 40, shown: 12).contains("12"))
        XCTAssertTrue(DependencyTable.countLabel(total: 40, shown: 12).contains("40"))
    }

    // MARK: - ② 红线：搬动之后诚实性那一层仍常驻

    /// 依赖页的红线句：默认离线时"0 条命中"是**没查**，不是**没病**。
    /// 它不在 C 名单里，但 Z 节把它列在全站第一位，所以本片一个字没动它。
    func test_uncheckedIsNotClaimedHealthyStillOnTheScreen() throws {
        let report = DependencyReport()
        // 前提自证（RD-78：那枚合成布尔已退役，这里改问它想表达的**两件分开的**事实——
        // 「没发起查询」与「没带回公告」不是一回事，合成一枚写着 coverage 的布尔正是 RD-11 的病根）。
        XCTAssertFalse(report.networkLookupPerformed, "默认离线态不该已经发起过查询，否则下面在空转")
        XCTAssertTrue(report.advisories.isEmpty, "默认离线态不该带回公告，否则下面在空转")
        let notice = DependencyAdvisoriesSection.emptyCaption(report)
        XCTAssertTrue(notice.contains("未联网"), notice)
        XCTAssertTrue(notice.contains("没有查"), notice)
        XCTAssertTrue(notice.contains("没有病"), notice)
        XCTAssertFalse(notice.contains("未发现已知漏洞"), "离线空列表不许写成 all-clear 句式")

        // 常驻证据：这句是**渲染进可见的 DataNotice**，不是挂进 tooltip。
        let files = try Self.pageFiles()
        let view = Self.content(of: "DependenciesView.swift", in: files)
        let mounted = view.components(separatedBy: "\n")
            .filter { SurfaceScanKit.isCode($0) && $0.contains("Self.emptyCaption(deps)") }
        XCTAssertEqual(mounted.count, 1, "找不到 emptyCaption 的渲染点：\(mounted)")
        XCTAssertTrue(mounted.allSatisfy { !$0.contains(".help(") && !$0.contains("CopyHelpBadge(") },
                      "红线句被搬进 ⓘ 了：\(mounted)")
    }

    /// 「未联网 / 内置快照」这一层在屏上至少要有三个常驻落点（开关卡、结论格、风险徽标）。
    func test_offlineSnapshotLayerKeepsVisibleAnchors() throws {
        let offline = NetworkOptionsCard.statusCaption(allowNetwork: false)
        XCTAssertTrue(offline.contains("离线"), offline)
        XCTAssertTrue(offline.contains("内置快照"), "开关卡的常驻行必须自己交代结论从哪来：" + offline)

        let unchecked = DependencySafetyVerdict(DependencyReport())
        XCTAssertTrue(unchecked.tileCaption.contains("未联网核对"), unchecked.tileCaption)
        XCTAssertEqual(unchecked.badgeText, "未核对", unchecked.badgeText)

        let files = try Self.pageFiles()
        let rows = files.flatMap { file in
            file.content.components(separatedBy: "\n")
                .filter { SurfaceScanKit.isCode($0) && $0.contains("SemanticBadge(\"未核对\"") }
        }
        XCTAssertFalse(rows.isEmpty, "生态卡头那枚「未核对」徽标不在了——离线态就没有可见的状态信号")
    }

    // MARK: - ③ H15：分析器产出的长口径句，本片判定为「必须常驻」

    /// `deps.networkLookupNote`（40~110 字，产自 `Services/Dependencies/`）在渲染处**保持常驻**。
    /// 只有 hover 才看见它，用户读到的就是一张"有依赖数、有漏洞数 0、没有一句为什么"的表。
    func test_analyzerProducedLookupNoteStaysRenderedNotHidden() throws {
        let files = try Self.pageFiles()
        let view = Self.content(of: "DependenciesView.swift", in: files)
        let lines = view.components(separatedBy: "\n").filter { SurfaceScanKit.isCode($0) }
        let mounts = lines.filter { $0.contains("DataNotice(text: deps.networkLookupNote") }
        XCTAssertEqual(mounts.count, 1, "长口径句的可见渲染点应当只有一处：\(mounts)")
        let hidden = lines.filter { Self.isTooltipCarrierLine($0) && $0.contains("networkLookupNote") }
        XCTAssertTrue(hidden.isEmpty, "这句不许进 tooltip 承载位（理由见本文件头 ③）：\(hidden)")
    }

    // MARK: - ④ 元测试：上面两条扫描判据必须能抓到坏样例

    func test_meta_landingPointScannerCatchesDuplicateAndSparesSingle() throws {
        let sentence = "这是一句只该出现在 ⓘ 里的依赖页口径说明"
        let once = [(path: "Views/Dependencies/A.swift",
                     content: "    MetricTile(label: \"x\").help(\"\(sentence)\")\n")]
        XCTAssertEqual(Self.literalCount(sentence, in: once), 1)
        XCTAssertTrue(Self.isTooltipCarrierLine(once[0].content))

        let twice = [(path: "Views/Dependencies/A.swift", content: """
            MetricTile(label: "x", caption: "\(sentence)")
                .help("\(sentence)")
            """)]
        XCTAssertEqual(Self.literalCount(sentence, in: twice), 2, "两处落点没被数出来 —— 守卫是摆设")

        let invisible = [(path: "Views/Dependencies/A.swift",
                          content: "  // 旧写法：\"\(sentence)\" 已经搬走\n")]
        XCTAssertEqual(Self.literalCount(sentence, in: invisible), 0, "注释里的引用被当成了落点")
    }

    func test_meta_tooltipCarrierJudgeCatchesAllThreeShapes() {
        XCTAssertTrue(Self.isTooltipCarrierLine("MetricTile(label: \"x\").help(\"口径\")"))
        XCTAssertTrue(Self.isTooltipCarrierLine("CopyHelpBadge(\"口径\")"))
        XCTAssertTrue(Self.isTooltipCarrierLine(".modifier(DataOptionalHelp(help: caliber))"))
        XCTAssertFalse(Self.isTooltipCarrierLine("DataFootnote(text: \"口径说明\")"),
                       "可见槽被判成了 tooltip 承载位 —— 下一条断言会永真绿")
    }

    /// 反向自证：如果谁把红线句整条搬进 ⓘ，② 那条断言必须红。
    func test_meta_redlineJudgeFlagsAHiddenCommitment() throws {
        let bad = "    DataNotice(text: \"漏洞核对状态\", role: Theme.Semantic.neutral)\n"
            + "        .help(Self.emptyCaption(deps))\n"
        let mounts = bad.components(separatedBy: "\n")
            .filter { SurfaceScanKit.isCode($0) && $0.contains("Self.emptyCaption(deps)") }
        XCTAssertEqual(mounts.count, 1, "坏样例没被②的判据看见，那条断言是永真绿")
        XCTAssertTrue(mounts.contains { $0.contains(".help(") },
                      "红线句挂上 .help 时必须能被这一列看见")

        let good = "                DataNotice(text: Self.emptyCaption(deps),\n"
        let kept = good.components(separatedBy: "\n")
            .filter { SurfaceScanKit.isCode($0) && $0.contains("Self.emptyCaption(deps)") }
        XCTAssertEqual(kept.count, 1)
        XCTAssertFalse(kept.contains { $0.contains(".help(") }, "合法样例被误伤")
    }

    // MARK: - 读数（不是断言）：《建议删除》的证据要在跑测试时看得见

    /// 盘点表 H 组判「删」而本片按守恒线**一个字没删**的两处，把现量打出来给总工复核。
    func test_reportDuplicateCalibersForTheChief() throws {
        let files = try SurfaceScanKit.sourceFiles(under: "Views")
        let sentence = "默认不联网时漏洞判定恒为 0 条，这是「没有查」，不是「没有病」"
        let hits = Self.literalCount(sentence, in: files)
        let advisories = DependencyAdvisoriesSection.subtitle(items: [], deps: DependencyReport())
        print("【S4 建议删除·读数】「\(sentence)」全站字面量 \(hits) 处（盘点表判删一处、收成常量）；"
              + "安全公告卡副标题「\(advisories)」与同卡空态句同屏两遍。")
        XCTAssertGreaterThanOrEqual(hits, 1, "这句承诺在源码里彻底没了 —— 那是被删了，不是被藏了")
    }
}
