import Foundation
import XCTest
@testable import TcoderMonitor

// MARK: - 页 H1 与卡名不许重名
//
// 权威 = `docs/界面语言-对齐AiX.md` §6「还没做」第 2 条，起因是卡片层落地后的实拍：
// 「代码规模」页的 H1 是 代码规模，第一张卡的标题也是 代码规模 —— 同一屏两行一模一样的字，
// 读起来像页面渲染了两遍。参考图里卡名各自具体（"24 小时活动""Agent 时长占比""当前运行中的 Agent"），
// **页名只出现在 H1 一处**。
//
// 为什么值得机器守：卡片层是默认生效的（`GlassSection` 默认 `.card`），
// 于是"卡名"从原来可有可无的小标升格成每张卡的标题行主角。
// 页面越往后长，随手把页名抄成卡名的概率越高，而它不会踩任何既有判据。

final class PageTitleCollisionGuardTests: XCTestCase {

    /// 页标题 → 渲染它的那个视图类型。**这张表不许凭记忆写**：
    /// 下面 `test_pageOwnershipTableMatchesTheRealRouter` 会逐条回源码核对。
    static let pageOwners: [(title: String, view: String)] = [
        ("总览", "DashboardView"),
        ("代码规模", "CodeMetricsView"),
        ("复杂度风险", "CodeRiskView"),
        ("Git 洞察", "GitInsightsView"),
        ("贡献者", "ContributorsView"),
        ("性能监控", "PerformanceView"),
        ("错误日志", "LogsView"),
        ("依赖分析", "DependenciesView"),
        ("健康评分", "HealthView"),
    ]

    /// 页标题必须真的等于 `DetailSection` 的展示名（它是 H1 的唯一来源）。
    func test_pageTitlesAreTheRealSectionTitles() {
        let titles = Set(DetailSection.allCases.map(\.title))
        let mapped = Set(Self.pageOwners.map(\.title))
        XCTAssertEqual(mapped, titles.intersection(mapped),
                       "表里写了不是页标题的名字（这条守卫会因此指错对象）：\(mapped.subtracting(titles))")
        XCTAssertEqual(titles.subtracting(mapped), [],
                       "有页面没进归属表，它就永远查不出重名：\(titles.subtracting(mapped))")
    }

    /// 归属表与真实路由必须一致 —— 表漂了这条先红，而不是让上面的碰撞检查悄悄查错文件。
    func test_pageOwnershipTableMatchesTheRealRouter() throws {
        let router = try SurfaceScanKit.sourceFiles(under: "Views")
            .first { $0.path.hasSuffix("ProjectDetailView.swift") }
        let body = router?.content ?? ""
        for pair in Self.pageOwners {
            XCTAssertTrue(body.contains(pair.view),
                          "归属表说 \(pair.title) 由 \(pair.view) 渲染，但路由里没有它 —— 表该更新了")
        }
    }

    /// 判据本体：某页自己的文件里不许出现 `GlassSection("<本页名>"`。
    static func collisions(in files: [(path: String, content: String)],
                           owners: [(title: String, view: String)]) -> [String] {
        owners.compactMap { pair in
            let needle = "GlassSection(\n                \"\(pair.title)\""
            let looseNeedle = "GlassSection(\"\(pair.title)\""
            guard let hit = files.first(where: {
                $0.path.hasSuffix("\(pair.view).swift")
                    && ($0.content.contains(needle) || $0.content.contains(looseNeedle))
            }) else { return nil }
            return "\(hit.path) → 「\(pair.title)」既是页 H1 又是卡名"
        }
    }

    func test_noCardRepeatsItsOwnPageTitle() throws {
        let files = try SurfaceScanKit.sourceFiles(under: "Views")
        XCTAssertGreaterThan(files.count, 20, "Views/ 只扫到 \(files.count) 个文件，口径可疑")
        let hits = Self.collisions(in: files, owners: Self.pageOwners)
        XCTAssertTrue(hits.isEmpty,
                      "同一屏出现两行一模一样的标题，读起来像页面渲染了两遍：\(hits)")
    }

    /// 反向元测试：合成一份"页名当卡名"的文件必须判红；
    /// 而**跨页引用**（总览页里放一块叫「代码规模」的摘要带）不许误伤 ——
    /// 那是指向另一页的路标，不是重名。
    func test_collisionRulerCatchesSyntheticAndSparesCrossPageBands() {
        let dirty = [(path: "Views/Code/CodeMetricsView.swift",
                      content: "GlassSection(\"代码规模\", subtitle: nil) {\n}\n")]
        XCTAssertEqual(Self.collisions(in: dirty, owners: Self.pageOwners).count, 1,
                       "页名当卡名没抓到 → 这条守卫是摆设")

        let legal = [(path: "Views/DashboardView.swift",
                      content: "GlassSection(\"代码规模\", subtitle: nil) {\n}\n")]
        XCTAssertTrue(Self.collisions(in: legal, owners: Self.pageOwners).isEmpty,
                      "总览页引用别的页名是路标，误伤会把人逼去删守卫")
    }

    // MARK: - 卡名与同卡主角读数的 note 不许重名（批次 P37）

    /// 「页名不许当卡名」的**下一层**：同一张卡里，卡名与主角读数旁边那句 `note` 也不许是同一个字面量。
    ///
    /// 实拍来源：`fb94e88` 那批 36 张·代码规模页头。卡名已经叫「总行数」，
    /// 56pt 的 `101,856` 后面又跟着 `行` + note「总行数」—— 同一屏把这个词念两遍。
    /// 而 `DataHeroReadout.note` 的契约写着"一句话口径，不许省"，
    /// 所以正解不是删掉它，是让它说卡名没交代的那件事（这里改成「含空行与注释」）。
    ///
    /// 粒度是**文件级**（一个视图文件通常就是一张卡），不是作用域级：
    /// 同文件里另一张卡恰好同名也会被算进来。这里偏严是故意的——
    /// 它只会逼人换一个说法，不会诱使人删守卫。
    static func heroNotesRepeatingACardTitle(in files: [(path: String, content: String)]) -> [String] {
        // 正则一律 `try!`：构造失败被 `try?` 吞成 nil 时，"0 命中"看起来像通过（本项目踩过）。
        let titleRE = try! NSRegularExpression(pattern: "GlassSection\\(\\s*\"([^\"]+)\"")
        let noteRE = try! NSRegularExpression(pattern: "note:\\s*\"([^\"]+)\"")
        func literals(_ re: NSRegularExpression, _ text: String) -> [String] {
            let whole = NSRange(text.startIndex..., in: text)
            return re.matches(in: text, options: [], range: whole).compactMap { match in
                guard let inner = Range(match.range(at: 1), in: text) else { return nil }
                return String(text[inner])
            }
        }
        return files.compactMap { file in
            // 先剥注释再配：全站这些视图的注释里大量在交代"旧写法是什么"，
            // 不剥就会把"讲代码的话"当成界面文案（这一族已经绊倒守卫多次）。
            let code = SurfaceScanKit.codeLines(file.content).joined(separator: "\n")
            let titles = Set(literals(titleRE, code))
            let repeats = Set(literals(noteRE, code).filter { titles.contains($0) })
            return repeats.isEmpty ? nil : "\(file.path): \(repeats.sorted().joined(separator: "、"))"
        }
    }

    func test_heroNoteNeverRepeatsItsOwnCardTitle() throws {
        let views = try SurfaceScanKit.sourceFiles(under: "Views")
        XCTAssertFalse(views.isEmpty, "扫不到 Views 面 ⇒ 分母坏了，下面的绿是假零")
        let hits = Self.heroNotesRepeatingACardTitle(in: views)
        XCTAssertTrue(hits.isEmpty,
                      "这些卡的主角读数把卡名又念了一遍；note 要说卡名没交代的事（口径/分母/范围）：\(hits)")
    }

    func test_heroNoteRulerCatchesSyntheticAndSparesADifferentCaliber() {
        let dirty = [(path: "Views/Code/Fake.swift", content: """
            GlassSection(
                "总行数",
                subtitle: nil
            ) {
                DataHeroReadout(value: "101,856", unit: "行", note: "总行数")
            }
            """)]
        XCTAssertEqual(Self.heroNotesRepeatingACardTitle(in: dirty).count, 1,
                       "note 重复卡名没抓到 → 这条守卫数不出东西")
        let legal = [(path: "Views/Code/Fake2.swift", content: """
            GlassSection(
                "总行数",
                subtitle: nil
            ) {
                DataHeroReadout(value: "101,856", unit: "行", note: "含空行与注释")
            }
            """)]
        XCTAssertTrue(Self.heroNotesRepeatingACardTitle(in: legal).isEmpty, "说了新信息的 note 被误伤")
        let commented = [(path: "Views/Code/Fake3.swift",
                          content: "  // 旧写法是 note: \"总行数\"，与卡名重复，已改成口径\n")]
        XCTAssertTrue(Self.heroNotesRepeatingACardTitle(in: commented).isEmpty,
                      "注释里交代旧写法就被判红（讲代码的话绊倒守卫，已记过多次）")
    }
}
