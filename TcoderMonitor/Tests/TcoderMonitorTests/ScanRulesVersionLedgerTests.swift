import Foundation
import XCTest
@testable import TcoderMonitor

/// OWNER: 总工（RD-81）—— 规则版本台账的判据。
///
/// 正例 + 六条反例 + 分母自证：`rulesLedgerDefects` 是纯函数，
/// 反例一律喂合成输入，不去改产品常量（否则"能红"要靠破坏源码，那是第 16 类失效的形状）。
final class ScanRulesVersionLedgerTests: XCTestCase {

    private func entry(_ stamp: String, _ landed: String) -> ScanProvenance.RulesVersion {
        ScanProvenance.RulesVersion(stamp: stamp, landed: landed)
    }

    /// 分母自证：台账真的有多格、而且当下这格干净（只剩一格或脏了，下面的判据全是空转）。
    func testRealLedgerIsNotEmptyAndSelfConsistent() {
        XCTAssertGreaterThanOrEqual(ScanProvenance.rulesChangeLedger.count, 2,
                                    "台账只剩一格 ⇒ 抬过一次就再没有历史，顺序判据也是空的")
        XCTAssertTrue(ScanProvenance.rulesLedgerDefects(
            current: ScanProvenance.rulesVersionStamp,
            ledger: ScanProvenance.rulesChangeLedger
        ).isEmpty, "真台账必须自洽")
    }

    /// 装配口唯一：上屏的戳 = 台账最新一格，而且**已经不是 RD-30 那枚旧字面量**。
    /// 第二条断言就是 RD-81 本体：那一行手写字符串自 `9932a19` 起从没动过，
    /// 于是带 RD-79 判据的报告仍在说 `2026.09-r1`。
    func testStampIsDerivedFromTheLedgerHeadAndHasActuallyMoved() {
        XCTAssertEqual(ScanProvenance.rulesVersionStamp, ScanProvenance.rulesChangeLedger.first?.stamp,
                       "戳不再等于台账第一格 ⇒ 有人绕过台账改字面量了")
        XCTAssertNotEqual(ScanProvenance.rulesVersionStamp, "2026.09-r1",
                          "规则戳仍停在立块那一版 ⇒ 换过判据的报告读起来像没换（RD-81 的原始缺陷）")
        XCTAssertTrue(ScanProvenance.rulesChangeLedger[0].landed.contains("RD-79"),
                      "最新一格必须点名它收进了哪批判据；今天这格该是 RD-79")
    }

    /// 反例一：改了戳没记账（或改了台账没改戳）——两个方向同一把尺子。
    func testDefectNamesTheHeadMismatch() {
        let ledger = [entry("2026.09-r3", "RD-99 例子"), entry("2026.09-r2", "RD-98 例子")]
        let defects = ScanProvenance.rulesLedgerDefects(current: "2026.09-r2", ledger: ledger)
        XCTAssertEqual(defects.count, 1, "只该报一条：\(defects)")
        XCTAssertTrue(defects[0].contains("不是台账最新一格"), defects[0])
    }

    /// 反例二：某一格没点名任何判据条目 ⇒ 「日常维护」这种空话过不了关。
    func testDefectRequiresAnEntryToNameLedgerItems() {
        let ledger = [entry("2026.09-r2", "日常维护，若干小修")]
        let defects = ScanProvenance.rulesLedgerDefects(current: "2026.09-r2", ledger: ledger)
        XCTAssertEqual(defects.count, 1, "只该报缺 RD 号这一条：\(defects)")
        XCTAssertTrue(defects[0].contains("没点名任何判据条目"), defects[0])
    }

    /// 反例三：顺序不是从新到旧（把更老的一格放在前面会让"最新一格"读成旧判据）。
    func testDefectRequiresNewestFirstOrdering() {
        let ledger = [entry("2026.09-r5", "RD-97 例子"), entry("2026.09-r6", "RD-96 例子")]
        let defects = ScanProvenance.rulesLedgerDefects(current: "2026.09-r5", ledger: ledger)
        XCTAssertTrue(defects.contains { $0.contains("顺序不是从新到旧") }, "\(defects)")
    }

    /// 反例四：空台账 ⇒ 上屏那个戳没有任何一格支撑，必须出声而不是退回一个看起来正常的串。
    func testEmptyLedgerIsAVoicedDefect() {
        let defects = ScanProvenance.rulesLedgerDefects(current: "2026.09-r9", ledger: [])
        XCTAssertEqual(defects.count, 1, "\(defects)")
        XCTAssertTrue(defects[0].contains("没有任何一格支撑"), defects[0])
    }

    /// 反例五：戳号形状漂了（有人随手填了个日期）。
    func testDefectCatchesMalformedStamp() {
        let ledger = [entry("r-2026", "RD-95 例子")]
        let defects = ScanProvenance.rulesLedgerDefects(current: "r-2026", ledger: ledger)
        XCTAssertTrue(defects.contains { $0.contains("形状不合") }, "\(defects)")
    }

    /// 反例六：同一枚戳登记两格 ⇒ 报告无法区分是哪一版判据产的。
    func testDefectCatchesDuplicateStamps() {
        let ledger = [entry("2026.09-r4", "RD-94 例子"), entry("2026.09-r4", "RD-93 例子")]
        let defects = ScanProvenance.rulesLedgerDefects(current: "2026.09-r4", ledger: ledger)
        XCTAssertTrue(defects.contains { $0.contains("戳号重复") }, "\(defects)")
    }

    /// 判据必须有**产品侧读者**，不能只活在自己的单测里（RD-42／RD-69 那一族「判据就绪、无读者」）。
    /// 这一格钉的是 `doctor` 那两行：戳号之外，还要说得出「这一版收进了什么」与台账自检结论。
    func testDoctorPrintsWhatTheStampNames() {
        let lines = CLIRouter.doctorIdentityLines()
        XCTAssertTrue(lines.contains { $0 == "  检测规则戳 = \(ScanProvenance.rulesVersionStamp)" },
                      "戳号那一行的形状不能漂（`doctor` 的读者按整行比对）：\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("该版收进的判据 =") && $0.contains("RD-") },
                      "doctor 里那一行必须点名判据条目，只印戳号等于把 RD-81 那笔漏抬换个地方重演：\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("规则台账自检 = 自洽") && $0.contains("最新一格") },
                      "自检结论要带内容与现量，不许只印「正常」：\(lines)")
    }

    /// `rN` 解析器自己的双向样本（它坏了的话，上面几条反例会一起变成哑的）。
    func testRevisionParserSeesBothEnds() {
        XCTAssertEqual(ScanProvenance.rulesStampRevision("2026.09-r12"), 12)
        XCTAssertNil(ScanProvenance.rulesStampRevision("2026.09-r"), "光一个 r 没有数字要判解析不出")
        XCTAssertNil(ScanProvenance.rulesStampRevision("2026.09x1"), "没有连字符的整串不是戳")
    }
}
