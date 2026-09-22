import Foundation
import XCTest
@testable import TcoderMonitor

/// 「两头都要在」这一族静态守卫：G9 诚实字段的写入点与读点、G10 折叠提示的入口。
///
/// 从 `FunctionalHonestyGuardTests.swift` 拆出来是因为主文件越过本仓 Tests 400 行口径 ——
/// 按规矩**拆片，不动阈值**。两把尺子都是"扫描面 + 合成输入元测试"的形状，
/// 与主文件里的 G1/G3 共用同一套 `SurfaceScanKit` 读盘入口。
extension FunctionalHonestyGuardTests {

    /// G9（P7-C 3-2）：诚实字段必须**两头都在** —— 分析器写它、视图读它。
    /// `CodeScanCoverage` 就是反面教材：上限算得清清楚楚，但契约里没有承接字段，
    /// 于是"只读了前 3 个文件"的报告在屏上与全量报告长得一模一样。
    static func deadHonestyFields(_ fields: [String],
                                  written: [(path: String, content: String)],
                                  read: [(path: String, content: String)]) -> [String] {
        let writeText = written.map(\.content).joined(separator: "\n")
        let readText = read.map(\.content).joined(separator: "\n")
        return fields.filter { field in
            !(writeText.contains("\(field) =") && readText.contains(field))
        }
    }

    func test_honestyFieldsAreBothWrittenAndDisplayed() throws {
        let services = try SurfaceScanKit.sourceFiles(under: "Services")
        let views = try SurfaceScanKit.sourceFiles(under: "Views")
        let dead = Self.deadHonestyFields(["analyzerRuleFailures", "scanLimitations"],
                                          written: services, read: views)
        XCTAssertTrue(dead.isEmpty, "这些诚实字段有写无读（或缺写入点）：\(dead)")
    }

    func test_deadFieldScannerCatchesSyntheticAndSparesWired() {
        let writtenOnly = [(path: "Services/Code/Fake.swift", content: "metrics.scanLimitations = limits\n")]
        XCTAssertEqual(Self.deadHonestyFields(["scanLimitations"], written: writtenOnly, read: []),
                       ["scanLimitations"], "只写不读没抓到 → 守卫是摆设")
        let wired = [(path: "Views/Code/Fake.swift", content: "code.scanLimitations\n")]
        XCTAssertTrue(Self.deadHonestyFields(["scanLimitations"], written: writtenOnly, read: wired).isEmpty,
                      "两头都在的合法写法被误伤")
    }

    /// G10（P7-C §S4）：**报数必须给入口**。屏上写「另有 N 个未列出 / 未展示」的地方，
    /// 同一个文件里必须出现 `DataDisclosureButton` —— 否则那句话是一条死路：
    /// 读者看完什么也做不了。性能页进程表原来正是这样（一句 `NoteLine` + 20 行里
    /// 19 行排序键相同），页尾实拍抓到后换成展开按钮。
    static func truncationNotesWithoutDisclosure(in files: [(path: String, content: String)]) -> [String] {
        files.compactMap { file in
            let hit = file.content.split(separator: "\n").contains { raw in
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.hasPrefix("//"), !line.hasPrefix("///") else { return false }
                return line.contains("未列出") || line.contains("未展示")
            }
            guard hit, !file.content.contains("DataDisclosureButton") else { return nil }
            return file.path
        }
    }

    func test_truncationIsAlwaysActionable() throws {
        let views = try SurfaceScanKit.sourceFiles(under: "Views")
        let dead = Self.truncationNotesWithoutDisclosure(in: views)
        XCTAssertTrue(dead.isEmpty, "这些文件只报「还有多少没列」却不给入口：\(dead)")
    }

    func test_truncationDisclosureRulerCatchesSyntheticAndSparesWired() {
        let deadEnd = [(path: "Views/Fake/Fake.swift",
                        content: "NoteLine(\"另有 3 个进程未列出。\")\n")]
        XCTAssertEqual(Self.truncationNotesWithoutDisclosure(in: deadEnd), ["Views/Fake/Fake.swift"],
                       "只报数不给入口没抓到 → 守卫是摆设")
        let wired = [(path: "Views/Fake/Fake2.swift", content: """
        if rows.count > rowLimit { DataDisclosureButton(expanded: expanded, hiddenCount: 3) {} }
        NoteLine("另有 3 个进程未列出。")
        """)]
        XCTAssertTrue(Self.truncationNotesWithoutDisclosure(in: wired).isEmpty, "配了入口的合法写法被误伤")
        let commented = [(path: "Views/Fake/Fake3.swift",
                          content: "// 原来这里只写「另有 3 个进程未列出」\n")]
        XCTAssertTrue(Self.truncationNotesWithoutDisclosure(in: commented).isEmpty,
                      "注释里交代旧写法就被判红")
    }

    /// G11（乱清单 §6 第 12 条）：「提交号其实来自外层仓库」这个事实必须**每一页都告示**。
    /// Git 洞察页一直有一条 `DataNotice`，健康评分页此前一个字没有 ——
    /// 实测：把**空的非 git 目录**注册成项目，这一页照样给出「协作分布 6 分 ·
    /// 最高作者占比 78%，29 位活跃作者，678 次非合并提交」，而那些数字是外层仓库的。
    /// 同一件事一页响、一页沉默，等于告诉读者"这一页的分数不必复核"。
    ///
    /// 判据两头：① 健康页必须真的**读** `provenance?.resolvedGitRoot`（有写无读就是死字段）；
    /// ② 健康页不许自己再判一次"是不是偏离"。`GitInsightsSections.isRelocated` 那套
    /// （`discoveryMode` + `canonicalPath` 比较）是 Git 页的私有实现，抄过来就是给同一个
    /// 事实造第二把尺子（AGENTS §3 横切那条点名过），两把尺子迟早分叉。
    static func relocationRulers(in files: [(path: String, content: String)])
        -> (readers: [String], secondRulers: [String]) {
        var readers: [String] = []
        var secondRulers: [String] = []
        for file in files {
            var readsProvenance = false
            for raw in file.content.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.hasPrefix("//"), !line.hasPrefix("///") else { continue }
                if line.contains("provenance?.resolvedGitRoot") { readsProvenance = true }
                if ["discoveryMode", "resolvedRepositoryRoot", "canonicalPath("].contains(where: line.contains) {
                    secondRulers.append("\(file.path): \(line)")
                }
            }
            if readsProvenance { readers.append(file.path) }
        }
        return (readers, secondRulers)
    }

    func test_gitRelocationIsDisclosedOnTheHealthPageToo() throws {
        let health = try SurfaceScanKit.sourceFiles(under: "Views/Health")
        XCTAssertFalse(health.isEmpty, "扫不到健康页任何一个文件 ⇒ 扫描面坏了，下面的绿是假零")
        let rulers = Self.relocationRulers(in: health)
        XCTAssertFalse(rulers.readers.isEmpty,
                       "健康页没有一处读 `provenance?.resolvedGitRoot`：Git 定位偏离这件事"
                       + "在 Git 洞察页有告示、在这一页沉默。修法是 `HealthHero(relocatedGitRoot:)`"
                       + "承接 `ScanProvenance.resolvedGitRoot`，不要在健康页另算。")
        XCTAssertTrue(rulers.secondRulers.isEmpty,
                      "健康页自己重算了一遍「仓库定位是否偏离」⇒ 同一个事实的第二把尺子：\(rulers.secondRulers)")
    }

    func test_relocationRulerScannerCatchesSyntheticAndSparesWired() {
        let silent = [(path: "Views/Health/Fake.swift", content: "HealthHero(health: health)\n")]
        let rulers = Self.relocationRulers(in: silent)
        XCTAssertTrue(rulers.readers.isEmpty, "没读来源的那种写法被当成读了 ⇒ 这条守卫是摆设")
        XCTAssertTrue(rulers.secondRulers.isEmpty)

        let wired = [(path: "Views/Health/Fake2.swift",
                      content: "HealthHero(health: health,\n           relocatedGitRoot: report?.provenance?.resolvedGitRoot)\n")]
        XCTAssertEqual(Self.relocationRulers(in: wired).readers, ["Views/Health/Fake2.swift"],
                       "正确写法判不出读点")

        let copied = [(path: "Views/Health/Fake3.swift",
                       content: "  git.discoveryMode != .selectedDirectory\n")]
        XCTAssertEqual(Self.relocationRulers(in: copied).secondRulers.count, 1, "第二把尺子没抓到")
        let commented = [(path: "Views/Health/Fake4.swift",
                          content: "/// 不在这里重算 `discoveryMode`，那是 Git 页的私有实现\n")]
        XCTAssertTrue(Self.relocationRulers(in: commented).secondRulers.isEmpty,
                      "注释里交代为什么不用它就被判红")
    }
}
