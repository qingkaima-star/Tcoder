import Foundation
import XCTest
@testable import TcoderMonitor

// MARK: - 键的有效性（批次 P5）
//
// 从 `LocalizationGuardTests.swift` 拆出来住：主文件加完 510 行，
// 超了 `X3TestSizeAuditTests` 与产品同口径的 400 行线。判据与元测试一字未改。
// 这两条管的是同一件事：**目录里有这条键 ≠ 运行时查得到这条键**。

extension LocalizationGuardTests {

    // MARK: - 守卫 1c：拼接出来的串**永远查不中**（翻了也白翻）

    /// 键必须是**运行时真正送进查表函数的那一串**。
    ///
    /// 2026-09-21 双语批量登记时，翻译同事抓到这个机制洞：源码里写
    /// `"历史里有提交…\n" + "另一段说明"`，于是**目录里那条以 `\n` 结尾的键**
    /// 在运行时永远等不到 —— `Text("…")` 生成的键是拼接后的整串，
    /// 半句键查不中 ⇒ 英文态退回中文，而守卫 1/2/3 全是绿的：
    /// 守卫 3 只要求"键作为完整字面量出现在源码里"，半句恰好满足它。
    /// ⇒ 这是"翻了但白翻"，比没翻更危险（它看起来有账）。
    static func keysBuiltByConcatenation(keys: [String], source: String) -> [String] {
        var out: [String] = []
        for key in keys {
            let escaped = key.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                // 字面量后面紧跟 `+ "`（同一行或换行后）= 它只是半句
                let pattern = "\"" + escaped + "\"\\s*(?:\\n\\s*)?\\+\\s*(?:\\n\\s*)*\""
                let re = try! NSRegularExpression(pattern: pattern, options: [])
                if re.firstMatch(in: source, options: [], range: NSRange(source.startIndex..., in: source)) != nil {
                    out.append(key)
                }
            }
        return out
    }

    func test_noRegisteredKeyIsOnlyAHalfSentence() throws {
        let source = try Self.walkFiles(in: Self.packageRoot.appendingPathComponent("Sources/TcoderMonitor").path)
            .reduce("") { $0 + ((try? String(contentsOfFile: $1, encoding: .utf8)) ?? "") }
        let offenders = Self.keysBuiltByConcatenation(
            keys: Self.catalogKeysForConcatenationCheck(try Self.catalog()), source: source)
        XCTAssertTrue(offenders.isEmpty,
                      "这些键在源码里是被 `+` 拼出去的半句，运行时永远查不中（英文态仍显示中文）：\n"
                      + offenders.joined(separator: "\n"))
    }

    /// 只查"值里带句末标点或以 `\n` 结尾"的可疑键：短标签不会与下一段拼接，
    /// 全量扫会让报错淹没在噪声里（也拖慢守卫）。
    static func catalogKeysForConcatenationCheck(_ entries: [(key: String, value: String)]) -> [String] {
        entries.map(\.key).filter { $0.hasSuffix("\\n") || $0.hasSuffix("。") || $0.hasSuffix("，") }
    }

    /// 元测试：半句必须抓到、整句不得误判。
    func test_concatenationGuardCatchesHalfSentencesAndSparesWholeOnes() {
        let source = """
        let a = DataNotice(text: "历史里有提交，\\n" + "但没有作者字段。")
        let b = DataNotice(text: "这是一句完整的话，没有拼接。")
        """
        XCTAssertEqual(Self.keysBuiltByConcatenation(keys: ["历史里有提交，\\n"], source: source),
                       ["历史里有提交，\\n"], "半句键没被抓到")
        XCTAssertTrue(Self.keysBuiltByConcatenation(keys: ["这是一句完整的话，没有拼接。"], source: source).isEmpty,
                      "整句键被误判")
        // 分母自证：可疑键筛选器确实会挑出以 \n / 。 结尾的键
        XCTAssertEqual(Self.catalogKeysForConcatenationCheck([
            (key: "甲\\n", value: "A"), (key: "乙。", value: "B"), (key: "丙", value: "C")
        ].map { (key: $0.key, value: $0.value) }), ["甲\\n", "乙。"])
    }

    /// stringsdict 里的**顶层键**也算"已登记"。
    ///
    /// 复数串（`%lld 次`、`另有 %lld 处`）住在 `Localizable.stringsdict`，
    /// 不在 `.strings` 里。守卫原来只认 `.strings`，于是"已经翻了复数形态"的键
    /// 会被算成双语债 —— 逼人把复数串退回单数键，那正是"乱翻译"的成因。
    static func stringsDictKeys(in text: String) -> Set<String> {
        // 顶层键 = 第一个 `<dict>` 之后、缩进只有一层 tab 的 `<key>`。
        // 用缩进判层级，比数尖括号稳（`one`/`other` 那些是三层）。
        let re = try! NSRegularExpression(pattern: "^\t<key>(.+)</key>$", options: [.anchorsMatchLines])
        let range = NSRange(text.startIndex..., in: text)
        return Set(re.matches(in: text, options: [], range: range).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        })
    }

    /// 读 stringsdict 的顶层键；文件不存在时返回空集（源语言侧不需要目录）。
    static func registeredStringsDictKeys() -> Set<String> {
        let path = packageRoot.appendingPathComponent("Resources/en.lproj/Localizable.stringsdict").path
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return stringsDictKeys(in: text)
    }

    func test_stringsDictTopLevelKeysAreParsed() throws {
        let path = Self.packageRoot.appendingPathComponent("Resources/en.lproj/Localizable.stringsdict").path
        let keys = Self.stringsDictKeys(in: try String(contentsOfFile: path, encoding: .utf8))
        XCTAssertFalse(keys.isEmpty, "stringsdict 解析出 0 个顶层键 —— 解析器坏了")
        XCTAssertTrue(keys.contains("%lld 次"), "复数键没被认成已登记：\(keys.sorted())")
        XCTAssertFalse(keys.contains("one"), "把子层的 one/other 当成了顶层键")
        XCTAssertFalse(keys.contains("NSStringLocalizedFormatKey"), "把元数据键当成了文案键")
    }
}
