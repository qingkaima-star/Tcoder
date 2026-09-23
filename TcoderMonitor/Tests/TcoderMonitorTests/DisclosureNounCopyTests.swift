import Foundation
import XCTest
@testable import TcoderMonitor

/// OWNER: 总工（双语线）—— 批次 P56：「展开其余 N …」这一族的整句复数键。
///
/// 钉的是三件事，缺一都会让这一族悄悄退回"屏上铺中文"：
///   ① `DisclosureNoun` 每个成员的两条键**必须在 `Localizable.stringsdict` 里**
///      （不在 ⇒ `localizedCount` 查不到 ⇒ 英文态整句中文，而且一句都不报错）；
///   ② 反向：stringsdict 里属于这一族的键**必须被某个成员用到**
///      （否则加了个没人用的复数形态，或成员被删了而目录还留着）；
///   ③ `one` 与 `other` 必须**不同形** —— 相同就说明这条键根本没在管复数，
///      那正是"Show 1 more commits"这种语法错的来源。
///
/// 中文态的已知答案也钉在这里：改的是"怎么取文案"，不是文案本身，
/// 所以中文串必须逐字不变（含千分位）。
final class DisclosureNounCopyTests: XCTestCase {

    /// 目录里这一族键的前缀 —— 反向判据按它认领成员。
    private static let familyPrefixes = ["展开其余 %lld ", "收起 %lld "]

    private func dictText() throws -> String {
        let path = LocalizationGuardTests.packageRoot
            .appendingPathComponent("Resources/en.lproj/Localizable.stringsdict").path
        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertFalse(text.isEmpty, "读不到 stringsdict ⇒ 下面几条判据全在空转")
        return text
    }

    func test_everyDisclosureCopyKeyIsRegisteredAsPluralForm() throws {
        let registered = LocalizationGuardTests.registeredStringsDictKeys()
        XCTAssertFalse(registered.isEmpty, "stringsdict 解析出 0 个顶层键 ⇒ 判据在空转")
        let missing = DisclosureNoun.allCases.flatMap { noun -> [String] in
            [noun.expandKey, noun.collapseKey].filter { !registered.contains($0) }
        }
        XCTAssertTrue(missing.isEmpty,
                      "这些展开/收起的整句键在 stringsdict 里没有 ⇒ 英文态会整句铺中文："
                    + missing.joined(separator: " / "))
    }

    /// 反向：目录里这一族的键，成员清单里必须点得到名。
    func test_noOrphanDisclosureKeyInTheCatalog() throws {
        let used = Set(DisclosureNoun.allCases.flatMap { [$0.expandKey, $0.collapseKey] })
        let registered = LocalizationGuardTests.registeredStringsDictKeys()
        let family = registered.filter { key in Self.familyPrefixes.contains { key.hasPrefix($0) } }
        // **反向判据最容易假绿**：解析器看不见任何一条键时，"孤儿"自然是空集。
        // 这条前置不是装饰 —— `stringsDictKeys` 用**行首一个 tab**认顶层键，
        // 用空格缩进的合法 plist 会整段读不到（P56 第一次写就是这么撞的：
        // plist 合法、`plutil -lint` 通过，而判据一条键都没看见）。
        XCTAssertGreaterThanOrEqual(family.count, used.count,
                                    "解析器只看到 \(family.count) 条这一族的键，成员却要 \(used.count) 条"
                                  + "—— 缩进不是 tab，反向判据会在空集上假绿")
        let orphans = family.filter { !used.contains($0) }.sorted()
        XCTAssertTrue(orphans.isEmpty,
                      "目录里有 \(orphans.count) 条展开/收起键没人用（成员被删？改名？拼错？）：\(orphans)")
    }

    /// one / other 同形 = 这条键根本没管复数。
    func test_eachDisclosureKeyDeclaresTwoDifferentPluralForms() throws {
        let text = try dictText()
        var sameForm: [String] = []
        for noun in DisclosureNoun.allCases {
            for key in [noun.expandKey, noun.collapseKey] {
                guard let (one, other) = Self.pluralPair(for: key, in: text) else {
                    sameForm.append("\(key)（取不到 one/other）")
                    continue
                }
                if one == other { sameForm.append(key) }
            }
        }
        XCTAssertTrue(sameForm.isEmpty,
                      "这些键的 one 与 other 一模一样，等于没有复数形态：\(sameForm)")
    }

    /// 从 plist 文本里取一条键的 one / other。
    /// 不引 `PropertyListSerialization` 整份解析：那要先把 XML 读成字典再逐层下钻，
    /// 而这里只问一件事 —— 这一条键的两个形态是否不同。
    private static func pluralPair(for key: String, in text: String) -> (one: String, other: String)? {
        guard let at = text.range(of: "<key>\(key)</key>") else { return nil }
        let tail = text[at.upperBound...]
        return (firstString(after: "<key>one</key>", in: tail),
                firstString(after: "<key>other</key>", in: tail))
    }

    private static func firstString(after marker: String, in slice: some StringProtocol) -> String {
        guard let at = slice.range(of: marker),
              let open = slice.range(of: "<string>", range: at.upperBound..<slice.endIndex),
              let close = slice.range(of: "</string>", range: open.upperBound..<slice.endIndex)
        else { return "" }
        return String(slice[open.upperBound..<close.lowerBound])
    }

    // MARK: 中文态已知答案：改的是取法，不是文案

    func test_chineseDisclosureCopyIsUnchangedWordForWord() {
        XCTAssertEqual(DataDisclosureButton.title(expanded: false, hiddenCount: 12, noun: .commits),
                       "展开其余 12 条提交")
        XCTAssertEqual(DataDisclosureButton.title(expanded: true, hiddenCount: 12, noun: .commits),
                       "收起 12 条提交")
        XCTAssertEqual(DataDisclosureButton.title(expanded: false, hiddenCount: 3, noun: .duplicateBlocks),
                       "展开其余 3 个重复块")
        // 榜内那一支是**动态选的量词**，两条都必须原样在（旧写法就是这两个串）
        XCTAssertEqual(DataDisclosureButton.title(expanded: false, hiddenCount: 5, noun: .cappedBlocks),
                       "展开其余 5 个榜内重复块")
    }

    /// 计数不许在改写过程中被丢掉（这条键的全部意义就是"折叠被计数交代"）。
    func test_disclosureTitleAlwaysCarriesTheCount() {
        for noun in DisclosureNoun.allCases {
            for count in [1, 7, 1_234] {
                let title = DataDisclosureButton.title(expanded: false, hiddenCount: count, noun: noun)
                XCTAssertTrue(title.contains(String(count)) || title.contains("1,234"),
                              "\(noun.expandKey) 在 \(count) 时把数弄丢了：\(title)")
            }
        }
    }
}
