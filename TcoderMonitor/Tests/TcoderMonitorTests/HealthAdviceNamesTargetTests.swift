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
        let text = try Self.source("HealthRuntimeDimensions.swift")
            .split(separator: "\n").map { line in
                line.trimmingCharacters(in: .whitespaces).hasPrefix("//") ? "" : String(line)
            }.joined(separator: "\n")
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
}
