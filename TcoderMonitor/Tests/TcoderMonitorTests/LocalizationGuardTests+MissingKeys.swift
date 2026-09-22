import Foundation
import XCTest

/// OWNER: 总工（双语线）—— 从 `LocalizationGuardTests` 拆出来的一条静态判据。
///
/// 判的是**查了但目录里没键**：`localizedCopy("…")` / `localizedCount("…", …)` /
/// `localizedFormat("…", …)` 的字面量实参，必须在 `en.lproj/Localizable.strings` 里有同名键。
///
/// 为什么这条必须存在：缺键**不报错、不崩、测试全绿**，
/// 唯一的症状是英文界面上铺着中文原文 —— 也就是只有切到英文的人才看得见。
/// 而"看得见"这件事在活界面侧要靠 18 趟 AX 扫描（`ax_body_audit.py`）才能数出来，
/// 静态一条正则就能盯住的东西不该留给动态。
///
/// P51 第一次跑就抓到 9 条：`%lld 次`（四处调用点共用一把 `localizedCount`，
/// 目录里却始终没这条键）、`%lld 行`、相对时间六档（`%lld 分钟前` 那一族只登记了不带「前」的形态）、
/// `另有 %lld 处`。
extension LocalizationGuardTests {

    /// 含插值的查表实参（`"尚未分析\(subject.rawValue)"` 那一族）**不在本条范围里** ——
    /// 它们要改成 `localizedFormat` + 位置参数，属双语迁移线的存量（台账另记句数），
    /// 混进来的话这条判据会把"改法不同"误报成"写错了"。
    static func lookedUpLiterals(in text: String) -> (plain: [String], interpolated: [String]) {
        let pattern = #"localized(?:Copy|Count|Format)\(\s*"((?:[^"\\]|\\.)+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            XCTFail("正则构造失败 ⇒ 这条判据根本没在跑")
            return ([], [])
        }
        var plain: [String] = []
        var interpolated: [String] = []
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard let span = Range(match.range(at: 1), in: text) else { continue }
            let key = String(text[span])
            if key.contains("\\(") {
                interpolated.append(key)
            } else {
                plain.append(key)
            }
        }
        return (plain, interpolated)
    }

    static func missingKeys(in files: [(path: String, content: String)], keys: Set<String>) -> [String] {
        files.flatMap { file in
            lookedUpLiterals(in: file.content).plain.filter { !keys.contains($0) }
                .map { "\(file.path) → \($0)" }
        }
    }

    func test_everyLookedUpLiteralHasACatalogKey() throws {
        let files = try SurfaceScanKit.sourceFiles(under: "")
        XCTAssertFalse(files.isEmpty, "一个源码文件都没扫到 ⇒ 这条判据在空转")
        // **两本目录都要读**：`.strings` 是单数键，复数形态（`%lld 次` / `%lld 行` /
        // 相对时间那一族）住在 `.stringsdict`。只读前者会把已翻的复数键算成债，
        // 然后逼人往 `.strings` 里补一条同名单数键 —— 那是"乱翻译"，不是收口。
        // （P51 就是这么差点犯错的：判据自己写的注释里就有这条教训。）
        let keys = Set(try Self.catalog().map(\.key))
            .union(Self.registeredStringsDictKeys())
        XCTAssertFalse(keys.isEmpty, "两本目录一条键都没读到 ⇒ 判据会全体误报，先修读数")

        let missing = Self.missingKeys(in: files, keys: keys)
        XCTAssertTrue(missing.isEmpty,
                      "这些句子查了表，但目录里根本没键 ⇒ 英文态直接把中文原文铺上屏，"
                    + "而且一句都不会报错：\n  " + missing.sorted().joined(separator: "\n  "))

        let interpolated = files.reduce(0) { $0 + Self.lookedUpLiterals(in: $1.content).interpolated.count }
        print("【查表必有键】扫 \(files.count) 个文件 → 缺键 0 条；"
            + "含插值的查表实参 \(interpolated) 处（另一档：要改成 localizedFormat，见双语台账）")
    }

    /// 双向元测试：缺键必须抓到、有键不许误报、含插值的走另一档不误伤。
    func test_missingKeyRulerCatchesGapsAndSparesInterpolated() {
        let keys: Set<String> = ["已有键"]
        let dirty = [(path: "Views/Fake.swift",
                      content: "Text(localizedCopy(\"缺的键\")) localizedCount(\"%lld 次\", n)")]
        XCTAssertEqual(Set(Self.missingKeys(in: dirty, keys: keys)),
                       ["Views/Fake.swift → 缺的键", "Views/Fake.swift → %lld 次"],
                       "缺键没被抓全 ⇒ 这条判据数不出东西")
        let clean = [(path: "Views/Fake.swift", content: "localizedCopy(\"已有键\")")]
        XCTAssertTrue(Self.missingKeys(in: clean, keys: keys).isEmpty, "有键还报 ⇒ 下次没人信它")
        let interpolated = [(path: "Views/Fake.swift",
                             content: "localizedCopy(\"尚未分析\\(subject.rawValue)\")")]
        XCTAssertTrue(Self.missingKeys(in: interpolated, keys: keys).isEmpty,
                      "含插值的查表实参要改的是写法（localizedFormat + 位置参数），不该被这条误伤")
        XCTAssertEqual(Self.lookedUpLiterals(in: interpolated[0].content).interpolated.count, 1,
                       "插值那一档必须被**数出来**，不能悄悄不算")
    }
}
