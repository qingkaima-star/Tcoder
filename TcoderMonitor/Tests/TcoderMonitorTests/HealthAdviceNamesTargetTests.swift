import Foundation
import XCTest
@testable import TcoderMonitor

/// RD-83：健康分建议卡的两句话**必须点名它手里的目标**，而且不许再用界面上已经不存在的旧名。
///
/// 为什么测"句子形状"而不是只测渲染结果：这两处的输入（热点榜第一名、高频错误第一名）
/// 就在同一个函数手里，退化成泛泛而谈时**编译与分数都不会变**——只有句子会开始骗人。
/// 所以这里的三条判据都是"句子必须长出什么形状"，并各配一条反向断言（旧写法回来就红）。
final class HealthAdviceNamesTargetTests: XCTestCase {

    private static let servicesHealth = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // TcoderMonitorTests
        .deletingLastPathComponent()      // Tests
        .deletingLastPathComponent()      // TcoderMonitor
        .appendingPathComponent("Sources/TcoderMonitor/Services/Health")

    private static func source(_ name: String) throws -> String {
        try String(contentsOf: servicesHealth.appendingPathComponent(name), encoding: .utf8)
    }

    /// 只比对**上屏句子**：判据先剥整行注释再匹配，否则我自己写的"为什么改"会被当成残留
    /// （本仓那条「按行扫的守卫会把注释当代码」的同族，2026-09-25 又踩到一次）。
    static func codeOnlySource(_ name: String) throws -> String {
        try source(name).split(separator: "\n").map { line in
            line.trimmingCharacters(in: .whitespaces).hasPrefix("//") ? "" : String(line)
        }.joined(separator: "\n")
    }

    /// 同一族句子允许住在宿主或它拆出去的文件里（RD-84 拆分就把这段搬去了
    /// `HealthDependencyDimension.swift`），所以按**多份文件取并集**来判——
    /// 只认一个路径的守卫会把"整块搬家"报成"句子丢了"，那是假红；反之只查旧路径会漏。
    static func codeOnlySources(_ names: [String]) throws -> String {
        try names.map { try codeOnlySource($0) }.joined(separator: "\n")
    }

    static func catalogText() throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/en.lproj/Localizable.strings"), encoding: .utf8)
    }

    /// 复杂度那条：必须把榜上第一名的**名字、文件、行号、CC** 四个位置都插进去。
    func test_complexityAdviceNamesTheFunctionItWantsSplit() throws {
        let text = try Self.source("HealthCodeDimensions.swift")
        XCTAssertTrue(text.contains("先拆这一个：「%1$@」（%2$@ 第 %3$@ 行 · 圈复杂度 %4$@）"),
                      "退化回「优先拆分最高复杂度函数」那种不点名的写法了——读的人还得自己回榜里找")
        XCTAssertFalse(text.contains("优先拆分最高复杂度函数"),
                       "旧的泛泛句子还在文件里，同一件事出现两套口径")
    }

    /// 稳定性那条：① 不许再印界面上已不存在的旧名「Top Errors」；② 必须点名那条高频错误。
    /// 判的是**上屏句子**，所以先把整行注释剥掉再匹配——本文件第 3 条反例与这段历史
    /// 都会提到那个旧名，把它们算进"残留"就是把守卫写成自指的空转（本仓那条"按行扫的守卫
    /// 会把行尾注释当成代码"的同族）。
    func test_stabilityAdviceNamesTheErrorAndDropsTheDeadBoardName() throws {
        let text = try Self.codeOnlySource("HealthRuntimeDimensions.swift")
        XCTAssertTrue(text.contains("先修这条高频错误：「%1$@」（窗口内 %2$@ 次 · 来自 %3$@）"),
                      "又变回「优先修复…首位」这种不点名的句子")
        XCTAssertFalse(text.contains("Top Errors"),
                       "「Top Errors」是《口径与已知限制》§8 用词表里最后一处残留，屏上已无处可寻")
    }

    /// 反例（证明上面两条不是永真绿）：把两条判据各自喂一枚坏样例，必须都报警。
    func test_meta_theTwoMatchersRejectTheOldShapes() {
        let dirty = "return [localizedCopy(\"优先拆分最高复杂度函数，用早返回替代嵌套分支\")]"
        XCTAssertFalse(dirty.contains("先拆这一个：「%1$@」（%2$@ 第 %3$@ 行 · 圈复杂度 %4$@）"),
                       "认领器见句就认，坏写法会被当成已修")
        let dirtyStability = "return [localizedCopy(\"优先修复 Top Errors 首位\")]"
        XCTAssertTrue(dirtyStability.contains("Top Errors"), "旧名反例构造失效，那第 2 条断言就是空的")
    }

    /// 界面串必须查得到英文译文：两枚新键都要在目录里，且英文值不许夹非 ASCII 标点。
    func test_bothNewSentencesHaveCatalogEntries() throws {
        let catalog = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/en.lproj/Localizable.strings"), encoding: .utf8)
        for key in ["先拆这一个：「%1$@」", "先修这条高频错误：「%1$@」"] {
            XCTAssertTrue(catalog.contains(key), "界面加了整句键却没登记译文：\(key)")
        }
    }

    // MARK: - RD-84：同族剩下两处（重复块与带漏洞依赖）

    /// 重复度那条必须点名"哪一处、多少行"，而且**不许**出现没对过刻度的相似度。
    func test_duplicationAdviceNamesTheBlockAndNotTheSimilarity() throws {
        let body = try Self.codeOnlySource("HealthCodeDimensions.swift")
        XCTAssertTrue(body.contains("先合这一处重复：%1$@ 之间有 %2$@ 行相同"),
                      "又变回「抽取重复块为共享工具或基类」那种不点名的句子")
        XCTAssertFalse(body.contains("抽取重复块为共享工具或基类"), "旧的泛泛句子还留在文件里")
        XCTAssertFalse(body.contains("相似度"),
                       "similarity 的刻度在本仓查不到独立真值，没对过刻度的数不许上屏（卷六 §100）")
    }

    /// 依赖那条点的名字要与 `vulnerableCount` **同源**（advisories / offlineVulnerabilities），
    /// 泛泛一句只允许作为"两处都点不出名字"的兜底存在。
    func test_dependencyAdviceNamesAPackageFromTheCountOwnSource() throws {
        let body = try Self.codeOnlySources(["HealthRuntimeDimensions.swift",
                                             "HealthDependencyDimension.swift"])
        XCTAssertTrue(body.contains("先升级这一个：%1$@（%2$@，公告 %3$@）"), "在线公告那条没点名组件")
        XCTAssertTrue(body.contains("先升级这一个：%1$@（%2$@，命中 %3$@ 个依赖）"), "离线命中那条没点名组件")
        XCTAssertTrue(body.contains("affectedPackages") && body.contains("vulnerableCount"),
                      "点名的来源与计数的来源不同源，就成了第三个口径")
        XCTAssertFalse(body.contains("knownVulnerabilities"),
                       "从 DependencyRecord 去点名会变成第三个口径（计数不看它）")
    }

    /// 反例：这两枚认领器都不许"见句就认"。
    func test_meta_theRD84MatchersRejectGenericSentences() throws {
        let dirty = "return [localizedCopy(\"抽取重复块为共享工具或基类，优先处理跨服务重复\")]"
        XCTAssertFalse(dirty.contains("先合这一处重复：%1$@ 之间有 %2$@ 行相同"),
                       "重复那条的认领器见句就认，泛泛写法会被当成已修")
    }

    /// 三枚新键都要在英文目录里（旧键允许留着，因为它还在兜底分支上被用到）。
    func test_theThreeNewRD84KeysAreInTheCatalog() throws {
        let catalog = try Self.catalogText()
        for key in ["先合这一处重复：", "先升级这一个：%1$@（%2$@，公告 %3$@）", "先升级这一个：%1$@（%2$@，命中 %3$@ 个依赖）"] {
            XCTAssertTrue(catalog.contains(key), "界面加了整句键却没登记译文：\(key)")
        }
    }
}
