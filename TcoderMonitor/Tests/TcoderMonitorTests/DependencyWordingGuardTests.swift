// OWNER: R3 依赖证据链 · 「读中文措辞判业务状态」全仓禁止（RD-13 的收口守卫）
//
// 这条守卫管的形状很具体：**给人看的那句中文成了业务判据**。本轮真修删掉过三处：
//   ① `ScoreCurves.VulnerabilityEvidence.classify` 末尾
//      `report.networkLookupNote.contains("失败") ? .degraded : .verified`（B 组删，判据换成账本）；
//   ② `DependencyNetworkLookup.npmShortfallDisclosed(in:)` 与 `osvShortfallDisclosed(in:)`
//      —— 各拿四/六条中文短语去 `note.contains(...)` 里找，用来决定在线用例"该跳还是该红"
//      （C 组删，消费方改读 `versionLookup.failed` / `vulnerabilityLookup.failed` /
//      `incompleteCoordinates`）；
//   ③ 测试侧那句 `XCTAssertFalse(report.networkLookupNote.contains("失败"))`
//      —— 断言本身就是措辞判据，B 组第 6 处换成"补句不许改状态"。
// 本文件是把"不许再长回来"钉成机器断言，并且**配双向元测试**：
// 讲代码的注释不许掉分（本文件的注释里就写着被禁的字面量），代码里的必须抓到。
//
// 边界（写清楚，避免被当成"全仓不许出现中文判据"）：
//   · 只禁**含汉字**的字面量进字符串谓词 —— 那是"词"，读它就是在读散文取结论；
//   · 标点归一化不禁：`hasSuffix("。")`（把叙述句补上句号）读的是自己刚拼出来的串的形状，
//     不产出任何业务状态。元测试 (c) 专门钉这条不误伤。
//   · 判据面**剥行注释**（含 `///` 续行）：不剥的话本文件自己就会绊住自己 ——
//     上面那段历史说明里全是"失败"两个字。
import XCTest
@testable import TcoderMonitor

final class DependencyWordingGuardTests: XCTestCase {

    /// 字符串谓词：拿一个字面量去问"这个串里有没有 / 是不是以它开头"。
    static let predicateNames = ["contains", "hasPrefix", "hasSuffix", "firstRange",
                                 "range", "localizedCaseInsensitiveContains"]

    /// 纯函数：喂 (路径, 文本)，返回"读措辞判状态"的落点（每条带行号，便于定位）。
    static func wordingFindings(in files: [(path: String, text: String)]) -> [String] {
        var findings: [String] = []
        for file in files {
            for (number, rawLine) in file.text.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated() {
                let code = stripLineComment(String(rawLine))
                guard let hit = prosePredicateHit(in: code) else { continue }
                findings.append("\(file.path):\(number + 1) \(hit)")
            }
        }
        return findings
    }

    /// 剥掉行注释：取**第一个不在字符串里的** `//` 之前。
    /// 只看引号计数的奇偶即可 —— 本仓没有把 `//` 写进未闭合字符串的写法，
    /// 而 `"https://host"` 这种"引号内成对"的必须原样保留，否则会把整条判据吃掉。
    static func stripLineComment(_ line: String) -> String {
        var quotes = 0
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\"" { quotes += 1 }
            if character == "/", quotes.isMultiple(of: 2),
               line.index(after: index) < line.endIndex, line[line.index(after: index)] == "/" {
                return String(line[..<index])
            }
            index = line.index(after: index)
        }
        return line
    }

    /// `.contains("…汉字…")` 一类的形状；返回命中片段供失败信息定位。
    static func prosePredicateHit(in code: String) -> String? {
        for name in predicateNames {
            for needle in [".\(name)(\"", ".\(name)( \""] where code.contains(needle) {
                guard let start = code.range(of: needle)?.upperBound else { continue }
                guard let end = code[start...].firstIndex(of: "\"") else { continue }
                let literal = String(code[start..<end])
                if Self.containsHan(literal) { return ".\(name)(\"\(literal)\")" }
            }
        }
        return nil
    }

    /// 只有**汉字**算"词"；全角标点（`。`、`、`、`：`）不算 —— 见文件头的边界说明。
    static func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains(Int($0.value)) }
    }

    // MARK: - 真树断言（含分母）

    func testProductionCodeNeverReadsChineseProseToDecideState() throws {
        let files = try productionSources()
        XCTAssertGreaterThan(files.count, 100,
                             "扫描面只到 \(files.count) 个文件 ⇒ 扫描器坏了，不是代码干净")
        let findings = Self.wordingFindings(in: files)
        XCTAssertTrue(findings.isEmpty,
                      "读中文措辞判业务状态（RD-13）：\(findings.prefix(6))；"
                      + "判据一律走结构化状态（`DependencyCheckState` / 各 LookupEvidence 计数）")
        // 反向 sanity：扫描面里必须真装着本仓那几条"曾经犯过"的文件，否则 0 命中毫无意义。
        XCTAssertTrue(files.contains { $0.path.hasSuffix("Services/Health/ScoreCurves.swift") },
                      "扫描面没覆盖评分侧 —— 那条正是被删掉的文案判据的老家")
        XCTAssertTrue(files.contains { $0.path.hasSuffix("Services/Dependencies/DependencyNetworkLookup.swift") })
    }

    // MARK: - 元测试（双向）：有牙 + 不误伤

    /// 元测试①（有牙）：代码里的坏样例必须抓到，抓不到就是永真绿守卫。
    func testGuardCatchesProseDrivenStateInCode() {
        let bad = [(path: "Sources/TcoderMonitor/Services/Dependencies/Probe.swift",
                    text: "if report.networkLookupNote.contains(\"失败\") { state = .degraded }")]
        XCTAssertEqual(Self.wordingFindings(in: bad).count, 1, "文案判据没被抓到 ⇒ 守卫是空的")
        let alsoBad = [(path: "Sources/TcoderMonitor/Services/Health/Probe2.swift",
                        text: "return note.hasSuffix(\"未核对\") ? .unchecked : .verified")]
        XCTAssertEqual(Self.wordingFindings(in: alsoBad).count, 1)
        let thirdBad = [(path: "Sources/TcoderMonitor/Services/Health/Probe3.swift",
                         text: "        if text.localizedCaseInsensitiveContains(\"超时\") { return .failed }")]
        XCTAssertEqual(Self.wordingFindings(in: thirdBad).count, 1)
    }

    /// 元测试②（不误伤）：讲代码的注释、只含标点的字面量、非字符串谓词都不许被抓。
    func testGuardIgnoresCommentsPunctuationAndStructuredCalls() {
        let legal = [
            // 注释里出现被禁的字面量：必须不掉分（本文件的文件头就是这种形状）。
            (path: "Sources/TcoderMonitor/Services/Dependencies/Doc.swift",
             text: "/// 旧判据是 note.contains(\"失败\") ? .degraded : .verified —— 已删\nlet x = 1"),
            (path: "Sources/TcoderMonitor/Services/Dependencies/Doc2.swift",
             text: "  // 这里别再写 contains(\"超时\")\nlet y = 2"),
            // 尾随注释同理：判据面只到那个 `//` 之前。
            (path: "Sources/TcoderMonitor/Services/Dependencies/Doc3.swift",
             text: "let z = ledger.failed // 别改成 note.contains(\"失败\")"),
            // 标点归一化：读的是自己拼出来的串的形状，不产出业务状态。
            (path: "Sources/TcoderMonitor/Services/Health/Narrative.swift",
             text: "if !result.hasSuffix(\"。\") { result += \"。\" }"),
            // 合法形状：结构化字段比较（无字面量）、URL 里的 `//` 后面还有判据也不许被吞。
            (path: "Sources/TcoderMonitor/Services/Dependencies/Real.swift",
             text: "if state == .failed { return }\nlet url = URL(string: \"https://a\") // 说明\nif state == .checked { return }"),
        ]
        XCTAssertTrue(Self.wordingFindings(in: legal).isEmpty,
                      "合法形状被误伤：\(Self.wordingFindings(in: legal))")
    }

    /// 元测试③：剥注释这一步自己也不能是"看着剥了其实没剥"——URL 里成对的引号与 `//`
    /// 必须按字符串处理，否则守卫会因为切错而变哑（这一条钉的是判据面的实现）。
    func testCommentStrippingKeepsStringLiteralsIntact() {
        XCTAssertEqual(Self.stripLineComment("let a = 1 // 失败"), "let a = 1 ")
        XCTAssertEqual(Self.stripLineComment("note.contains(\"失败\")"), "note.contains(\"失败\")")
        // 引号未闭合之前的 `//` 属于字符串内容（URL），不能当成注释起点。
        XCTAssertTrue(Self.stripLineComment("let u = \"https://x\"; if n.contains(\"超时\") { }")
                      .contains("超时"))
    }

    // MARK: - 扫描面

    /// 扫描面：`Sources/TcoderMonitor/**` 全部 `.swift`（一次递归，不重不漏）。
    private func productionSources() throws -> [(path: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TcoderMonitor", isDirectory: true)
        return swiftFiles(in: root, manager: FileManager.default, depth: 5)
    }

    /// 递归收 `.swift`（深度上限防符号链接成环）。测试进程的 CWD 不是包根，
    /// 所以一律从 `#filePath` 回溯，不用相对路径（那会"静默扫不到东西、然后判通过"）。
    private func swiftFiles(in directory: URL, manager: FileManager, depth: Int) -> [(String, String)] {
        guard depth > 0 else { return [] }
        var out: [(String, String)] = []
        guard let entries = try? manager.contentsOfDirectory(atPath: directory.path) else { return [] }
        for name in entries.sorted() {
            let url = directory.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                out.append(contentsOf: swiftFiles(in: url, manager: manager, depth: depth - 1))
            } else if name.hasSuffix(".swift"), let data = manager.contents(atPath: url.path),
                      let text = String(data: data, encoding: .utf8) {
                out.append((path: url.path, text: text))
            }
        }
        return out
    }
}
