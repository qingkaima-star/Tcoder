import XCTest
@testable import TcoderMonitor

/// OWNER: 总工程师（#41：裸行号引用的有效性）
///
/// 为什么要单独一条：`DocReferenceRatchetTests`（WS-V 名下）只认两种形状——
/// 「每段都是标识符的符号锚点」与「`File.swift:NN`」。
/// 而文档里大量存在**裸行号** ``` `:349` ```（回指同段落里最近的那个文件名），
/// 它两者都不认 ⇒ **不进分母、永不判红**。
/// 2026-09-20 实测证明这不是理论问题：`docs/使用说明.md:613` 的 `` `:349` ``
/// 回指 `App/AppState.swift`，而该文件只有 197 行——一句指向不存在位置的引用一直绿着。
///
/// 判据（与 §4.6 一致）：
///   1. 裸 `:NNN` / `:NNN-MMM` 必须回指到**同一段落内**最近的一个 `.swift` 文件引用
///      （向上扫到空行或 `#` 标题为止；先取本行内该 token 之前的，再取本行内的，再向上）；
///   2. 回指不到 ⇒ 判失效；
///   3. 回指到的文件不存在、或行号超过该文件行数 ⇒ 判失效；
///   4. 分母正向断言：扫到的裸行号必须 > 0，否则说明这条判据在空转。
///      这里曾经钉的是「至少 50 条」，那是一个会把人往错方向逼的判据：
///      WS-Z2 把 §3.8 之后的行号引用清到 32 条时它判红，于是为了变绿，
///      只能把 21 条已经换成符号锚点的引用原样放回去（它逐条回源码核过指向才放，
///      但**方向是反的**）。"扫描器坏了"由索引规模断言与
///      `live + dead == total` 恒等式负责；拿存量债的条数当哨兵＝奖励留债。
final class DocBareLineReferenceTests: XCTestCase {

    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // TcoderMonitorTests
        .deletingLastPathComponent()      // Tests
        .deletingLastPathComponent()      // TcoderMonitor
        .deletingLastPathComponent()      // 工作树根

    private static let docs: [String] = ["README.md", "docs/使用说明.md",
                                       // 2026-09-25：口径文档的**续卷**（父卷写到 789 行撞上 800 行闸门，
                                       // 尾部三节按日期追加的内容逐字搬过去）。往后新补的口径都往续卷写，
                                       // 所以它必须一起被扫 —— 否则"以后写的行号引用"正好落在扫描面外。
                                       // 登记当下这份续卷里 0 处裸行号引用，加进来不会带进新债。
                                       "docs/口径与已知限制.md", "docs/口径与已知限制-续.md",
                                       "docs/九页实拍读数.md"]

    /// ``` `:349` ``` / ``` `:77-105` ``` / ``` `:58,59,119` ```
    private static let barePattern = try! NSRegularExpression(
        pattern: #"`:([0-9]+)(?:[-,][0-9]+)*`"#)

    /// 任意反引号 token（用来找"被回指的文件名"）
    private static let tokenPattern = try! NSRegularExpression(
        pattern: #"`([^`]+)`"#)

    private static let filePattern = try! NSRegularExpression(
        pattern: #"[A-Za-z0-9_/.-]+\.swift"#)

    /// 文件名（去后缀）-> 行数。覆盖**全仓** .swift，不只 Sources：
    /// 文档也会引用 `Tests/**` 里的用例名，只索引 Sources 会把它们误判成不存在。
    private func swiftLineCounts() throws -> [String: Int] {
        let out = try runGit(["ls-files", "*.swift"])
        let names = out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        XCTAssertGreaterThan(names.count, 50, "git ls-files 只拿到 \(names.count) 个 .swift，索引不可信")
        var counts: [String: Int] = [:]
        let fm = FileManager.default
        for name in names {
            let url = Self.repoRoot.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let base = url.lastPathComponent
            if counts[base] == nil { counts[base] = lineCount(of: text) }
        }
        XCTAssertFalse(counts.isEmpty, "一个 .swift 文件都没读到，判据会空转")
        _ = fm
        return counts
    }

    private func lineCount(of text: String) -> Int {
        let newlines = text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        return text.hasSuffix("\n") ? newlines : newlines + 1
    }

    private func runGit(_ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", Self.repoRoot.path] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(process.terminationStatus, 0, "git \(args.joined(separator: " ")) 失败")
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 找出这一行里所有裸行号 token 及其字符位置。
    private func bareTokens(on line: String) -> [(token: String, location: Int)] {
        let range = NSRange(location: 0, length: line.utf16.count)
        return Self.barePattern.matches(in: line, range: range).map {
            ($0.range.slice(in: line), $0.range.location)
        }
    }

    /// 一行里出现的 `.swift` 文件名（按出现顺序）。
    private func fileTokens(on line: String) -> [String] {
        let range = NSRange(location: 0, length: line.utf16.count)
        return Self.filePattern.matches(in: line, range: range).map { $0.range.slice(in: line) }
    }

    /// 回指规则：本行内该 token 之前最近的文件名 → 本行内之后的第一个 → 向上到段落首行
    /// （遇到空行或 `#` 标题即停，跨段落不许回指）。
    private func resolvedFile(for token: String, at location: Int,
                              lineIndex: Int, lines: [String]) -> String? {
        let line = lines[lineIndex]
        let range = NSRange(location: 0, length: line.utf16.count)
        let positioned = Self.filePattern.matches(in: line, range: range)
            .map { (name: $0.range.slice(in: line), start: $0.range.location) }
        if let before = positioned.filter({ $0.start < location }).last { return before.name }
        if let after = positioned.first { return after.name }
        var k = lineIndex
        while k > 0 {
            k -= 1
            let upper = lines[k]
            if upper.trimmingCharacters(in: .whitespaces).isEmpty || upper.hasPrefix("#") { break }
            if let last = fileTokens(on: upper).last { return last }
        }
        return nil
    }

    private struct Verdict {
        var total = 0
        var live = 0
        var dead: [String: String] = [:]
    }

    private func scan(lines: [String], doc: String, counts: [String: Int]) -> Verdict {
        var verdict = Verdict()
        for (index, line) in lines.enumerated() {
            for (token, location) in bareTokens(on: line) {
                verdict.total += 1
                let key = "\(doc):\(index + 1) \(token)"
                guard let file = resolvedFile(for: token, at: location, lineIndex: index, lines: lines) else {
                    verdict.dead[key] = "回指不到任何 .swift 文件名（同段落内没有文件引用）"
                    continue
                }
                let base = (file as NSString).lastPathComponent
                guard let maxLine = counts[base] else {
                    verdict.dead[key] = "回指的 \(base) 不在仓库的 .swift 清单里"
                    continue
                }
                let numbers = token.trimmingCharacters(in: CharacterSet(charactersIn: "`:"))
                    .split(whereSeparator: { $0 == "-" || $0 == "," })
                    .compactMap { Int($0) }
                guard let reached = numbers.max() else {
                    verdict.dead[key] = "解析不出行号数字"
                    continue
                }
                if reached > maxLine {
                    verdict.dead[key] = "\(base) 只有 \(maxLine) 行，\(token) 指向第 \(reached) 行"
                } else {
                    verdict.live += 1
                }
            }
        }
        return verdict
    }

    private func scannedAll() throws -> (all: Verdict, perDoc: [(String, Verdict)]) {
        let counts = try swiftLineCounts()
        var all = Verdict()
        var perDoc: [(String, Verdict)] = []
        for doc in Self.docs {
            let url = Self.repoRoot.appendingPathComponent(doc)
            let text = try XCTUnwrap(try? String(contentsOf: url, encoding: .utf8),
                                    "读不到 \(doc)，不能把「没读到」当成「没有裸行号引用」")
            let verdict = scan(lines: text.components(separatedBy: "\n"), doc: doc, counts: counts)
            all.total += verdict.total
            all.live += verdict.live
            all.dead.merge(verdict.dead) { _, new in new }
            perDoc.append((doc, verdict))
        }
        return (all, perDoc)
    }

    // MARK: - 元测试：两个方向都要钉，单边等于没修

    /// 合成输入喂给 `scan`，不经文档。
    /// 这条若挂，说明判据本身错了，而不是文档有问题。
    func testBareReferenceRuleHoldsBothWays() throws {
        var counts: [String: Int] = [:]
        counts["FakeAnalyzer.swift"] = 200
        // 同段落：第一行给出文件名，第二行用裸行号回指它；空行之后那句应当回指不到
        let paragraph = [
            "分析器在 `TcoderMonitor/Sources/FakeAnalyzer.swift:10-20` 里定义：",
            "    窗口内一条合法 `:150`，越界一条判死 `:999999`，小行号也活 `:5`。",
            "",
            "孤立的一行 `:7` 没有任何同段落上文可回指。",
        ]
        let verdict = scan(lines: paragraph, doc: "synthetic", counts: counts)
        XCTAssertEqual(verdict.total, 4, "合成本文应扫到 4 条裸行号引用")
        XCTAssertEqual(verdict.live, 2, "`:150` 与 `:5` 都回指 FakeAnalyzer.swift 且 ≤ 200 ⇒ 判活")
        XCTAssertEqual(verdict.dead.count, 2, "应判死 2 条，实得：\n\(DictPreview(verdict.dead))")
        XCTAssertTrue(verdict.dead.keys.contains { $0.contains(":999999") },
                      "越界的裸行号必须判死，实得：\n\(DictPreview(verdict.dead))")
        XCTAssertTrue(verdict.dead.keys.contains { $0.contains(":7") },
                      "跨段落回指不到的裸行号必须判死，实得：\n\(DictPreview(verdict.dead))")
    }

    // MARK: - 真实文档

    func testBareLineReferencesInDocsAllResolveAndInRange() throws {
        let (all, perDoc) = try scannedAll()
        print("【#41 裸行号】扫到 \(all.total) 条：判活 \(all.live)、判死 \(all.dead.count)"
              + "（" + perDoc.map { "\($0.0) \($0.1.total)" }.joined(separator: "，") + "）")
        XCTAssertGreaterThan(all.total, 0,
                                    "只扫到 \(all.total) 条裸行号引用，不像这两份文档的真实规模 ⇒ 判据在空转")
        XCTAssertTrue(all.dead.isEmpty, """
        有 \(all.dead.count) 条裸行号引用不可验证：
        \(DictPreview(all.dead))
        修法只有两种（`AGENTS.md` §4.6）：把文件名补进这个 token，或改成符号锚点。
        **不要**把它塞进任何"已知失效"清单——那等于把守门器关掉。
        """)
    }
}

/// 本文件自带的 NSRange→子串（`DocReferenceRatchetTests.swift` 里那份是 fileprivate，不共享）。
private extension NSRange {
    func slice(in text: String) -> String {
        guard let range = Range(self, in: text) else { return "" }
        return String(text[range])
    }
}

/// 字典的稳定可读渲染（失败信息里要能逐条看到是哪一行）。
private struct DictPreview: CustomStringConvertible {    let items: [String: String]
    init(_ items: [String: String]) { self.items = items }
    var description: String {
        items.keys.sorted().prefix(20)
            .map { "  \($0) → \(items[$0]!)" }
            .joined(separator: "\n")
    }
}
