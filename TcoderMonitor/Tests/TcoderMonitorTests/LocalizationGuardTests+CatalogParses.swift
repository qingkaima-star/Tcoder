import Foundation
import XCTest
@testable import TcoderMonitor

// MARK: - 目录必须能被**系统那个解析器**读进来
//
// OWNER: 总工程师（批次 P6-E 收尾时立的规矩）
//
// 为什么单独一条：2026-09-21 我自己往 `Localizable.strings` 追加了一条英文值，
// 里面写了没转义的双引号（`means "our rules did not run"`）。整份文件当场变成
// **解析失败**，于是 `NSLocalizedString` 对**每一个键**都退回键本身 ——
// 英文态九页全部变回中文。而既有守卫全是绿的，因为它们用正则数键、
// 比对键集合，**从不按真正的 .strings 语法解析**。
// 一把只查"内容对不对"的尺子，看不见"整把尺子量的东西已经读不出来"。
//
// 判据因此选 `PropertyListSerialization` —— 它就是 `Foundation` 读 .strings 用的
// 那个解析器。它说失败，运行时就一定查不到表。

extension LocalizationGuardTests {

    /// 用系统解析器读一份 .strings / .stringsdict。失败即返回错误描述。
    static func catalogParseFailure(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return "读不到文件" }
        do {
            let object = try PropertyListSerialization.propertyList(from: data, format: nil)
            guard let dict = object as? [String: Any] else { return "顶层不是字典" }
            guard !dict.isEmpty else { return "解析成功但 0 键" }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func test_localizationCatalogsParseWithTheSystemReader() throws {
        let base = LocalizationGuardTests.packageRoot
        for name in ["Resources/en.lproj/Localizable.strings",
                     "Resources/en.lproj/Localizable.stringsdict"] {
            let url = base.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                XCTFail("\(name) 不在包里 —— 打出来的 App 不会说第二种语言")
                continue
            }
            if let failure = Self.catalogParseFailure(at: url) {
                XCTFail("""
                \(name) 用系统解析器读不进来：\(failure)
                后果不是"某几条没翻"，是**整份目录作废、所有键退回中文**，
                而按正则数键的守卫会全部保持绿色。
                最常见成因：值里写了没转义的双引号（`"..."` 里再出现 `"` 必须写成 \\"）。
                """)
            }
        }
    }

    /// 反向自证：把一条未转义引号喂进去，必须判失败。
    func test_theRulerCatchesAnUnescapedQuote() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-ruler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let broken = dir.appendingPathComponent("broken.strings")
        try "\"你好\" = \"hello\";\n\"坏\" = \"这里有 \"未转义\" 引号\";\n".write(
            to: broken, atomically: true, encoding: .utf8)
        XCTAssertNotNil(Self.catalogParseFailure(at: broken),
                        "未转义引号没被抓到 → 这条守卫挡不住下一次整份目录作废")

        let fine = dir.appendingPathComponent("fine.strings")
        try "\"你好\" = \"hello\";\n\"转义\" = \"里面有 \\\"引号\\\"\";\n".write(
            to: fine, atomically: true, encoding: .utf8)
        XCTAssertNil(Self.catalogParseFailure(at: fine),
                     "合法转义被误判 → 每次加带引号的译文都要手工绕过这条门")
    }

    /// 量词族必须与全站大读数**同一把记法**。
    /// 交付头实拍「代码规模」语言构成那一列打的是 `46330 行`，
    /// 而同页总行数打的是 `77,515` —— 同一个量在一屏上两种写法。
    /// 根因是 84 个 `stringsdict` 量词键一律 `%lld`（复数规则要数字），
    /// 而 `String(format:)` 实测不认分组标志 `%'lld` ⇒ 只能在填完之后补分隔符。
    func test_countsGetTheSameSeparatorsAsBigReadouts() {
        XCTAssertEqual(groupedInto("46330 行", count: 46330), "46,330 行")
        XCTAssertEqual(groupedInto("999 行", count: 999), "999 行", "不足一千不该加分隔")
        XCTAssertEqual(groupedInto("第 1024 名 · 1024 行", count: 1024), "第 1,024 名 · 1024 行",
                       "只替换第一次出现的那串（那才是刚填进去的 token），后面的译文自带数字不动")
        XCTAssertEqual(groupedInto("没有数字", count: 5000), "没有数字",
                       "找不到数字串就原样返回 —— 不许猜着改")
        XCTAssertEqual(localizedCount("%lld 行", 46330), "46,330 行", "端到端：目录 + stringsdict 那条路也要补")
        XCTAssertEqual(localizedCount("%lld 行", 5), "5 行", "小数量词一字不变")
    }
}
