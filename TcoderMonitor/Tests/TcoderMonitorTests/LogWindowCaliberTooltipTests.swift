import XCTest
@testable import TcoderMonitor

/// OWNER: 总工（RD-82）—— 错误日志卡头那句「窗口按文件挑、不逐行过滤」的接线自检。
///
/// 台账卷五 §92 把这句记成「另立一项、不假装说完」：口径写在 `docs/口径与已知限制.md` §4.8，
/// 但屏上从来没说过 ⇒ 读者照样会把「每千行日志 N 个错误」读成「最近 N 天的错误率」。
/// 本文件只管三件事，**不复制** `LocalizationGuardTests` 与 `TooltipMigrationGuardTests` 已有的尺子
/// （同一判据两处入口 = 两把尺子，RD-38 那一族）：
///   ① 那句确实挂在卡头的 `subtitleHelp:` 上（挂了键不等于上屏，反向也一样）；
///   ② 它走 `localizedFormat` 的整句键，不是裸中文字面量（英文态会整句漏翻）；
///   ③ 一句只有一个家，且英文目录里那格的占位符数量与中文一致。
final class LogWindowCaliberTooltipTests: XCTestCase {

    private static let viewPath = "Views/Logs/LogsMetricGrid.swift"
    private static let sentencePrefix = "时间窗口按文件挑、不逐行过滤"

    private func codeLines() throws -> [String] {
        let files = try SurfaceScanKit.sourceFiles(under: "")
        let content = try XCTUnwrap(files.first { $0.path == Self.viewPath },
                                    "扫不到这个文件 —— 它被搬走而这条自检还绿着").content
        return content.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && !$0.hasPrefix("///") }
    }

    /// ①＋② 真接上了，而且是查表的整句键。
    func testCardHeaderPassesTheWindowCaliberIntoHelpSlot() throws {
        let lines = try codeLines()
        XCTAssertTrue(lines.contains { $0.contains("subtitleHelp: windowCaliberNote") },
                      "卡头没把那句挂进 subtitleHelp: ⇒ 口径又回到只写在文档里")
        XCTAssertTrue(lines.contains { $0.contains("localizedFormat(") && $0.contains(Self.sentencePrefix) },
                      "那句必须是 localizedFormat 的整句键，裸中文字面量在英文态永远不翻")
    }

    /// ③ 一句一个家：整句中文在这份文件里只出现一次。
    func testSentenceHasExactlyOneHomeInView() throws {
        let hits = try codeLines().filter { $0.contains(Self.sentencePrefix) }
        XCTAssertEqual(hits.count, 1,
                       "那句话出现 \(hits.count) 次，应当只有 1 次（两处 = 两把尺子）")
    }

    /// 英文目录侧：键在、值不是空、两侧占位符数量相等、英文值只用 ASCII 标点。
    func testCatalogCarriesTheKeyWithMatchingPlaceholders() throws {
        // 复用既有那把尺子的解析器（`LocalizationGuardTests.catalog()`），
        // 自己再写一遍 .strings 解析就是 RD-38 那个「同一件事两个入口」。
        let catalog = try LocalizationGuardTests.catalog()
        guard let value = catalog.first(where: { $0.key.hasPrefix(Self.sentencePrefix) }) else {
            return XCTFail("英文目录里没有这句键 ⇒ 英文态会退回中文，而守卫查不到它")
        }
        let zhSlots = value.key.components(separatedBy: "%1$@").count - 1
        let enSlots = value.value.components(separatedBy: "%1$@").count - 1
        XCTAssertEqual(zhSlots, 2, "中文侧该有两次占位符（结论与提醒各一次）")
        XCTAssertEqual(enSlots, zhSlots, "英文侧占位符数与中文不符 ⇒ 会打出漏槽的句子")
        XCTAssertFalse(value.value.unicodeScalars.contains { $0.value > 127 },
                       "英文值只许 ASCII 标点：全角括号或破折号混进来会让整份表在运行时无声作废（双语台账第 1 坑）")
    }

    /// 反向自证：合成一份没挂槽的形状必须判缺失，真文件判在场 —— 两条同时成立才不是永真绿。
    func test_scannerNeedsBothEndsOfTheLine() throws {
        let unwired = ["GlassSection(\"错误概览\", subtitle: subtitle,",
                       "                     icon: .riskSevere, trailing: headerTrailing) {"]
        XCTAssertFalse(unwired.contains { $0.contains("subtitleHelp: windowCaliberNote") },
                       "合成反例自己就先挂了 ⇒ 这条判据什么都没在测")
        XCTAssertTrue(try codeLines().contains { $0.contains("subtitleHelp: windowCaliberNote") },
                      "真文件这一侧没挂上（① 已单独判过，这里补的是双向）")
    }
}
