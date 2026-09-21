import Foundation
import XCTest
@testable import TcoderMonitor

// MARK: - 中文排版守卫（批次 P5）
//
// 从 `LocalizationGuardTests.swift` 拆出来住：那个文件加完就 449 行，
// 而 `X3TestSizeAuditTests` 用与产品同一口径（400 行）钉着 Tests 目录。
// 判据、合成样例与数字一字未改，只换了住的地方。

extension LocalizationGuardTests {

    // MARK: - 守卫 7：中文排版两条硬判据（批次 P5）

    /// 两批实拍独立点名"中文里夹着多余空格"与"半全角括号混用"，
    /// 而它们的成因是同一个：**插值拼接**。`"来自 " + 维度名` 在写的时候看着对，
    /// 拼出来是"来自 协作分布"—— 中文词之间那个空格是英文排版习惯的残留。
    ///
    /// 判据（写死成约定，供 §3 术语表引用）：
    /// ① **汉字与汉字之间不留半角空格**；汉字与数字/拉丁字母之间留一个
    ///    （`最近扫描 41 秒前`、`每 1.5 s 采样` 合规）—— 所以判据要求空格**两侧都是汉字**；
    /// ② **中文串里的括号一律全角**：半角 `(` 到 `)` 之间出现汉字即违例。
    ///    只查**字符串字面量内部**，否则 `Text("中文")` 这种调用点括号会全仓误判。
    static func stringLiterals(in line: String) -> [String] {
        let re = try! NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*""#, options: [])
        let range = NSRange(line.startIndex..., in: line)
        return re.matches(in: line, options: [], range: range).compactMap {
            Range($0.range, in: line).map { String(line[$0]) }
        }
    }

    private static func isHan(_ scalar: Character) -> Bool {
        scalar >= "\u{4E00}" && scalar <= "\u{9FFF}"
    }

    /// ① 汉字 + 半角空格 + 汉字。返回命中的片段（供报错时指认）。
    ///
    /// **三条子形状都要查，只查①a 是共享盲区**：真实成因几乎全是插值拼接，
    /// 空格住在字面量里、另一侧的汉字住在 `\(...)` 里，①a 看不见它。
    /// ①b = `汉字 + 空格 + \(…`（如「主要拖累来自 \(low.name)」）；
    /// ①c = `…) + 空格 + 汉字`（如「\(second.name) 与 …」）。
    /// ①b/c 的**另一侧是什么语言**静态判不出来（`最近扫描 \(x)` 里 x 以数字开头，
    /// 那个空格是合规的），所以它们走带存量的棘轮，①a/② 走零闸门。
    static func hanSpacedHan(in literal: String) -> String? {
        let chars = Array(literal)
        for index in 1..<(chars.count - 1) where chars[index] == " " {
            if isHan(chars[index - 1]), isHan(chars[index + 1]) {
                // 只回"汉字 空格 汉字"这一组三元：窗口宽度是任意的，
                // 把它切进报错里会让元测试去钉一个没意义的下标区间。
                return "\(chars[index - 1]) \(chars[index + 1])"
            }
        }
        return nil
    }

    /// ①b'：汉字 + 空格 + **一定是中文词的插值**。
    ///
    /// 为什么只钉"中文词生产者"而不钉所有插值：空格该不该留，取决于值的第一个字符
    /// 是汉字还是数字（`最近扫描 41 秒前` 的空格是对的，`来自 协作分布` 的是错的），
    /// 而这一点静态判不出来。但有一类插值**按构造就产出中文词** ——
    /// 维度名、风险档位、显示消息、页面名。对它们，空格恒为多余，于是可以零闸门。
    /// 数字类生产者（`count` / `NumberFormat.*` / `*At` / `*Ms`）不在此列，不得误判。
    /// 名单里**不放 `.rawValue`**：它两侧都有真实样本 ——
    /// `code.overallRisk.rawValue` 是「高/中/低」（中文，空格多余），
    /// 而 `thermalState.rawValue` 是 "nominal/fair"（拉丁，空格必需）。
    /// 一个会把合法写法判成违例的 needle 比没有 needle 更糟：逼人绕开守卫。
    private static let hanProducingProducers = [
        ".name", ".displayMessage", ".title", ".displayName(",
        ".overallRisk", ".severity",
    ]

    static func hanSpacedChineseWord(in literal: String) -> String? {
        let chars = Array(literal)
        for index in 0..<(chars.count - 2) where chars[index] == " " {
            guard isHan(chars[index - 1]), chars[index + 1] == "\\", chars[index + 2] == "(" else { continue }
            let tail = String(chars[(index + 3)...])
            guard let close = tail.firstIndex(of: ")") else { continue }
            let expression = String(tail[..<close])
            if let producer = hanProducingProducers.first(where: { expression.contains($0) }) {
                return "汉字 空格 + \(expression)（产出中文词，生产者 \(producer)）"
            }
        }
        return nil
    }

    /// ①c'：中文词插值 + 空格 + 汉字。
    static func chineseWordSpacedHan(in literal: String) -> String? {
        let chars = Array(literal)
        var index = 0
        while index + 3 < chars.count {
            guard chars[index] == "\\", chars[index + 1] == "(" else { index += 1; continue }
            var depth = 1
            var cursor = index + 2
            while cursor < chars.count, depth > 0 {
                if chars[cursor] == "(" { depth += 1 }
                else if chars[cursor] == ")" { depth -= 1 }
                cursor += 1
            }
            guard depth == 0 else { return nil }        // 括号不闭合（跨行拼接），不猜
            let expression = String(chars[(index + 2)..<(cursor - 1)])
            if hanProducingProducers.contains(where: { expression.contains($0) }),
               cursor + 1 < chars.count, chars[cursor] == " ", isHan(chars[cursor + 1]) {
                return "\\(expression) 空格 + 汉字"
            }
            index = cursor
        }
        return nil
    }

    /// ② 半角括号里装着汉字。
    static func halfWidthParenInHan(in literal: String) -> String? {
        var search = literal.startIndex
        while let open = literal[search...].firstIndex(of: "(") {
            guard let close = literal[open...].firstIndex(of: ")") else { return nil }
            let inner = literal[literal.index(after: open)..<close]
            if inner.contains(where: isHan) { return String(literal[open...close]) }
            search = literal.index(after: open)
        }
        return nil
    }

    static func typographyOffenders(in files: [(path: String, content: String)]) -> [String] {
        var out: [String] = []
        for file in files {
            for (offset, raw) in file.content.components(separatedBy: "\n").enumerated() {
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }      // 讲代码的话不算违例
                for literal in Self.stringLiterals(in: raw) {
                    if let hit = Self.hanSpacedHan(in: literal) {
                        out.append("\(file.path):\(offset + 1) 汉字间多余空格「…\(hit)…」")
                    }
                    if let hit = Self.halfWidthParenInHan(in: literal) {
                        out.append("\(file.path):\(offset + 1) 半角括号含汉字「\(hit)」")
                    }
                    if let hit = Self.hanSpacedChineseWord(in: literal) {
                        out.append("\(file.path):\(offset + 1) 中文词前多余空格 \(hit)")
                    }
                    if let hit = Self.chineseWordSpacedHan(in: literal) {
                        out.append("\(file.path):\(offset + 1) 中文词后多余空格 \(hit)")
                    }
                }
            }
        }
        return out
    }

    /// 存量清零后当闸门用。先跑一次让它把债报出来 —— 新守卫的第一个产出
    /// 必须是存量清单，不是一片绿。
    func test_chineseTypographyHasNoStraySpacesOrHalfWidthParens() throws {
        let files = try Self.chineseTypographySources()
        XCTAssertGreaterThanOrEqual(files.count, 40, "分母不对，这条没在检查任何东西")
        let offenders = Self.typographyOffenders(in: files)
        XCTAssertTrue(offenders.isEmpty,
                      "中文排版违例 \(offenders.count) 处：\n\(offenders.sorted().joined(separator: "\n"))")
    }

    /// 元测试（①b'/①c'）：中文词生产者要抓到，数字生产者与拉丁生产者不得误判。
    /// 反向那两条是重点 —— `.rawValue` 曾经也在这份名单里，
    /// 于是 `机身 \(thermalState.rawValue)`（值是 "nominal"，空格必需）被判成违例。
    func test_chineseWordProducerRulesCatchWordsAndSpareNumbers() {
        XCTAssertNotNil(Self.hanSpacedChineseWord(in: "主要拖累来自 \\(low.name)（\\(low.score) 分）"),
                        "中文词前的空格没被抓到")
        XCTAssertNotNil(Self.chineseWordSpacedHan(in: "\\(first.name) 与 \\(second.name) 共同拖累"),
                        "中文词后的空格没被抓到")
        XCTAssertNil(Self.hanSpacedChineseWord(in: "最近扫描 \\(DateFormat.sinceDescription(scanned))"),
                     "数字/日期生产者被误判")
        XCTAssertNil(Self.hanSpacedChineseWord(in: "机身 \\(snapshot?.thermalState.rawValue ?? \"--\")"),
                     ".rawValue 的拉丁取值被误判（它已从名单里拿掉）")
        XCTAssertNil(Self.chineseWordSpacedHan(in: "共 \\(NumberFormat.grouped(count)) 个文件"),
                     "纯数字生产者被误判")
    }

    /// 元测试：正反双向都要有效。反向那三条是重点 ——
    /// 误判会逼人为了过守卫去改一个本来没错的写法（"每 1.5 s 采样"就是）。
    func test_typographyScannerCatchesBothRulesAndSparesLegalForms() {
        // ① 汉字之间的空格 → 抓
        XCTAssertEqual(Self.hanSpacedHan(in: "主要拖累来自 协作分布"), "自 协")
        // 汉字与数字/拉丁之间的空格 → 合法（Apple 中文排版惯例）
        XCTAssertNil(Self.hanSpacedHan(in: "最近扫描 41 秒前"))
        XCTAssertNil(Self.hanSpacedHan(in: "每 1.5 s 采样"))
        XCTAssertNil(Self.hanSpacedHan(in: "覆盖 92% 的提交"))
        // ② 半角括号含汉字 → 抓；全角 → 合法
        XCTAssertEqual(Self.halfWidthParenInHan(in: "综合分 = Σ(维度得分 × 归一化权重)"), "(维度得分 × 归一化权重)")
        XCTAssertNil(Self.halfWidthParenInHan(in: "综合分（B 级）"))
        XCTAssertNil(Self.halfWidthParenInHan(in: "format(%@, %lld)"), "括号里没有汉字不该管")
        // 整行：代码括号不得被当成字符串内容
        let dirty = [(path: "Views/Fake.swift",
                      content: "Text(\"主要拖累来自 协作分布\")\nText(\"综合分 = Σ(维度得分)\")\n")]
        let hits = Self.typographyOffenders(in: dirty)
        XCTAssertEqual(hits.count, 2, "两条违例应各命中一次：\(hits)")
        let legal = [(path: "Views/Fake.swift",
                      content: "Text(\"最近扫描 41 秒前\")\nText(\"综合分（B 级）\")\n")]
        XCTAssertTrue(Self.typographyOffenders(in: legal).isEmpty, "合法写法被误判：\(Self.typographyOffenders(in: legal))")
        // 注释里提一句违例写法，不得算
        let commented = [(path: "Views/Fake.swift",
                          content: "// 原来这里是「来自 协作分布」，批次 P5 去掉了空格\n")]
        XCTAssertTrue(Self.typographyOffenders(in: commented).isEmpty, "注释被误判成代码")
    }

    /// 分母：界面三目录的源码。`LocalizationGuardTests.sourceFiles()` 是 private，
    /// 跨文件够不着，所以这里走共享的 `SurfaceScanKit`（同一份读盘口径）。
    static func chineseTypographySources() throws -> [(path: String, content: String)] {
        var out: [(String, String)] = []
        // 五个目录：**喂给界面的句子多半是在 Services/ 里拼出来的**
        // （健康页那句"主要拖累来自 协作分布"就住在 `Services/Health/ScoreCurves.swift`）。
        // 只扫 Views 会得到一份假短的存量清单 —— 那正是"共享盲区"的形状。
        for sub in ["Views", "Design", "App", "Services", "Models"] {
            out += try SurfaceScanKit.sourceFiles(under: sub)
        }
        return out
    }
}
