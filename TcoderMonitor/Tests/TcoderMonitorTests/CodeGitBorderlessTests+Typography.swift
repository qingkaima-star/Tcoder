/// OWNER: WS-X3 TestSplit —— 自 CodeGitBorderlessTests.swift 拆出，五页排版链：不用 tertiary、不裸写系统字体、每页一个主读数、大档位不直用。用例本体未改，只是搬了家。
import Foundation
import XCTest
@testable import TcoderMonitor

extension CodeGitBorderlessTests {

    func test_noTertiaryAnywhereOnTheFivePages() throws {
        let hits = Self.tertiaryUses(in: try Self.pageSourceFiles())
        XCTAssertTrue(hits.isEmpty,
                      "本流五页不得出现 .tertiary（\(hits.count) 处）：\n\(hits.joined(separator: "\n"))")
    }

    func test_noBareSystemFontsAnywhere() throws {
        let hits = Self.bareSystemFonts(in: try Self.pageSourceFiles())
        XCTAssertTrue(hits.isEmpty,
                      "出现裸字号，排版令牌的唯一消费入口被绕过：\(hits)")
        // 反向：收编之后必须真取到 11pt 等宽档，而不是"删掉了事"留个空洞。
        XCTAssertTrue(try Self.pageSourceFiles(dirs: ["CodeGit"])
                          .contains { $0.content.contains("Theme.Typo.monoLabel.font") },
                      "tableIdentifier 没收进 Theme.Typo.monoLabel，上面那条就成了死断言")
    }

    func test_everyPageHasAtMostOneHeroReadout() throws {
        let all = try Self.pageSourceFiles()
        for page in Self.pageFiles.keys {
            let owned = Self.files(forPage: page, in: all)
            XCTAssertFalse(owned.isEmpty, "页面「\(page)」一个文件都没匹配上 —— 归属表过期了")
            let heroes = Self.heroCallSites(in: owned)
            XCTAssertLessThanOrEqual(heroes.count, 1,
                                     "页面「\(page)」有 \(heroes.count) 枚主角读数：\(heroes)")
        }
    }

    /// 56 与 34 只能从原语出来。页面自己写 = 绕过「纯墨」与「每页一枚」两条。
    func test_bigTiersAreNotUsedDirectlyInPages() throws {
        let pages = try Self.pageSourceFiles(dirs: Self.pageDirs)
        let hero = Self.directBigTierUses(in: pages, tokenNamed: "heroMetric")
        let number = Self.directBigTierUses(in: pages, tokenNamed: "metricNumber")
        XCTAssertTrue(hero.isEmpty, "页面自己写了 56pt，请改用 DataHeroReadout：\(hero)")
        XCTAssertTrue(number.isEmpty,
                      "页面自己写了 34pt。34pt 的唯一合法来源是读数带里的 MetricTile，"
                          + "否则第二主角会盖过本页主角：\(number)")
    }

    /// 主角原语本身不许被掏空：字号与纯墨两条都挂在它身上。
    func test_heroReadoutPrimitiveCarriesTheContract() throws {
        let kit = try Self.pageSourceFiles(dirs: ["CodeGit"])
        let hero = try XCTUnwrap(kit.first { $0.content.contains("struct DataHeroReadout") },
                                 "DataHeroReadout 没了 —— 主角约束失去了唯一落点")
        XCTAssertTrue(hero.content.contains("typed(Theme.Typo.heroMetric)"),
                      "主角没走 .typed(heroMetric)：56pt 档或行高已丢")
        XCTAssertTrue(hero.content.contains("Surface.ink"),
                      "主角不是纯墨。.primary 只有 85% 黑，全页最暗像素会落到小号正文上")
    }

    func test_groupGapsComeFromNamedBandsAndAreAtLeast24() throws {
        XCTAssertGreaterThanOrEqual(Theme.Spacing.group, 24, "主分组档必须 ≥ 24")
        XCTAssertGreaterThanOrEqual(Theme.Spacing.section, 24, "段落档必须 ≥ 24")
        XCTAssertGreaterThanOrEqual(Theme.Spacing.pageMargin, 24, "页边距必须 ≥ 24")

        let kit = try Self.pageSourceFiles(dirs: ["CodeGit"])
        let group = try XCTUnwrap(kit.first { $0.content.contains("struct GroupStack") },
                                  "GroupStack 没了 —— 页面就会各自写 VStack 来排分组")
        XCTAssertTrue(group.content.contains("Spacing.group"), "分组容器必须吃 group(32)")

        // 三档真的被五页用起来：只定义不接线 = spec §0 根因⑤ 原样复发
        let pages = try Self.pageSourceFiles(dirs: Self.pageDirs)
        let joined = pages.map(\.content).joined(separator: "\n")
        XCTAssertTrue(joined.contains("GroupStack"),
                      "没有页面用 GroupStack → 分组档仍是零引用死令牌")
        XCTAssertTrue(joined.contains("Theme.Page.Scaffold"),
                      "没有页面走基座骨架 → 24/32/40 三档对这一页完全不生效")
    }

}
