import Foundation
import XCTest
@testable import TcoderMonitor

// MARK: - 跨文档的"§小节"指针必须落在**真的含有那一节**的文件里
//
// 立它的直接理由是我自己刚犯的那次：`界面语言-对齐AiX.md` 涨到 832 行撞上全仓 800 行棘轮，
// §6.15 起整块搬进 `界面语言-批次台账.md`（§6.27 记的是这次搬家）。
// 搬完之后，另有三份文档里**四条**"见 `docs/界面语言-对齐AiX.md` §6.18 / §6.21 / §6.15–§6.17 / §6.22"
// 全部指向了一个不再含有那一节的文件 —— 而锚点棘轮一条都不会红：
// 它管的是**代码符号**锚点，`§6.18` 不是代码符号。
// ⇒ 搬家是合法操作（闸门逼着拆），但**搬家会留下断链**，这条守卫补的就是那一半。

extension DocReferenceRatchetTests {

    /// 抽出 `` `docs/x.md` §6.22 `` 与 `` `docs/x.md` §6.15–§6.17 `` 两种形状。
    /// 返回 `(被指向的文件, 该处引用的所有小节号)`；区间会展开成逐条。
    static func sectionPointers(in text: String) -> [(doc: String, section: String, line: Int)] {
        let pattern = "docs/([^`\\s，。；)]+?\\.md)`?\\s*§(\\d+(?:\\.\\d+)?)(?:\\s*[–—-]\\s*§?(\\d+(?:\\.\\d+)?))?"
        let regex = try! NSRegularExpression(pattern: pattern)
        var out: [(String, String, Int)] = []
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(raw)
            for match in regex.matches(in: line, options: [], range: NSRange(line.startIndex..., in: line)) {
                func group(_ n: Int) -> String? {
                    guard let r = Range(match.range(at: n), in: line) else { return nil }
                    return String(line[r])
                }
                guard let doc = group(1), let first = group(2) else { continue }
                // 补回 `docs/` 前缀：正则从 `docs/` 起匹配，捕获组里天然没有它，
                // 而清单里的键是完整相对路径 —— 漏这一步会让**每条**引用都"找不到文件"，
                // 一条全红的假守卫比一条不响的守卫更糟（它看起来在工作）。
                let fullPath = "docs/" + doc
                guard let last = group(3), last != first else {
                    out.append((fullPath, first, index + 1))
                    continue
                }
                for section in Self.expandSectionRange(from: first, to: last) {
                    out.append((fullPath, section, index + 1))
                }
            }
        }
        return out
    }

    /// `6.15 → 6.17` 展开成三节；主版本号不同就只认两端（不猜跨主版本的编号）。
    static func expandSectionRange(from: String, to: String) -> [String] {
        let parts = { (s: String) -> (Int, Int)? in
            let p = s.split(separator: ".")
            guard p.count == 2, let major = Int(p[0]), let minor = Int(p[1]) else { return nil }
            return (major, minor)
        }
        guard let a = parts(from), let b = parts(to), a.0 == b.0, b.1 >= a.1, b.1 - a.1 <= 30 else {
            return [from, to]
        }
        return (a.1...b.1).map { "\(a.0).\($0)" }
    }

    /// 断链：被指向的文件里找不到 `## §x.y` / `### §x.y` 这一节（文件读不到也算断链）。
    ///
    /// **只在目标文档自己用 `§` 编号时才检查。** 仓里两种编号习惯并存：
    /// 台账族写 `### §6.22 …`，而 `README` / `使用说明` / `乱的清单` 写 `## 5. 密度 / 重复`。
    /// 对后者要求"标题里含 §5"会把**指对了的引用**判成断链（第一次跑就误报 6 条，
    /// 全是这种）。所以判据收窄成："这份文档用 § 编号 ⇒ 它的所有 § 引用必须能对上"，
    /// 这恰好覆盖我要防的那件事（搬家把 §6.15+ 从一份 § 编号文档挪进另一份）。
    static func danglingSectionPointers(in docs: [(path: String, content: String)]) -> [String] {
        let byPath = Dictionary(uniqueKeysWithValues: docs.map { ($0.path, $0.content) })
        func headings(_ content: String) -> [String] {
            content.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("## ") || $0.hasPrefix("### ") }
        }
        var dangling: [String] = []
        for doc in docs {
            for pointer in sectionPointers(in: doc.content) {
                guard let target = byPath[pointer.doc] else {
                    dangling.append("\(doc.path):\(pointer.line) → \(pointer.doc) 不在扫描面里")
                    continue
                }
                let targetHeadings = headings(target)
                guard targetHeadings.contains(where: { $0.contains("§") }) else { continue }
                if !targetHeadings.contains(where: { Self.headingNumber($0) == pointer.section }) {
                    dangling.append("\(doc.path):\(pointer.line) → \(pointer.doc) 里没有 §\(pointer.section)")
                }
            }
        }
        return dangling
    }

    /// 标题里的编号归一化：`## 1. 实测值` → "1"、`### §6.22 批次…` → "6.22"。
    /// 必须两种都认 —— `界面语言-对齐AiX.md` 是**混合编号**（顶层用 `## 1.`，
    /// 批次记录用 `### §6.x`），只认带 § 的那一半会把 `§1` 这种**指对了的**引用判成断链。
    static func headingNumber(_ heading: String) -> String? {
        // 前导的 `#` 要**全部**剥掉：只剥一个的话 `### §6.22` 剩下 `## §6.22`，
        // 开头撞上 `#` ⇒ 读成"无编号"，于是**每一条** § 引用都判成断链
        // （这一步就是这么错的：10 条真引用一次全变假阳）。
        var body = heading.drop(while: { $0 == "#" || $0 == " " })
        if body.first == "§" { body = body.dropFirst() }
        var number = ""
        for ch in body {
            // 只吃**开头**那一段数字：标题正文里常还有日期（`## 6. 落地状态（2026-09-21…）`），
            // 一路扫下去会把 "6." 拼成 "6.20260921"。
            guard ch.isNumber || ch == "." else { break }
            number.append(ch)
        }
        while number.hasSuffix(".") { number.removeLast() }
        return number.isEmpty ? nil : number
    }

    func test_crossDocSectionPointersLandOnAFileThatHasThatSection() throws {
        let docs = try Self.readDocsForSectionPointerScan()
        // 分母：先证明这把尺子在量东西（一条跨文件小节引用都没扫到 = 正则或文档面失效）。
        let scanned = docs.reduce(0) { $0 + Self.sectionPointers(in: $1.content).count }
        XCTAssertGreaterThan(scanned, 0, "一条跨文件 §小节引用都没扫到 ⇒ 先怀疑正则或文档路径失效")
        let dangling = Self.danglingSectionPointers(in: docs)
        XCTAssertEqual(dangling, [], "文档里有 \(dangling.count) 条断掉的小节指针：\(dangling)")
        print("【小节指针】跨文件 §引用 \(scanned) 条 → 断链 0 条")
    }

    /// 复用主守卫那份文档清单，避免两处各写一遍路径（写两遍就会有一天不一致）。
    static func readDocsForSectionPointerScan() throws -> [(path: String, content: String)] {
        let root = Self.repoRoot
        return try docs.map { path in
            (path, try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8))
        }
    }

    func test_sectionPointerScannerCatchesASectionThatMoved() {
        let docs = [
            ("README.md", "详见 `docs/规范.md` §6.18 与 `docs/规范.md` §6.15–§6.17。"),
            ("docs/规范.md", "# 规范\n\n### §6.15 甲\n\n### §6.16 乙\n\n### §6.17 丙\n"),
        ]
        XCTAssertEqual(Self.sectionPointers(in: docs[0].1).map { $0.section }, ["6.18", "6.15", "6.16", "6.17"],
                       "区间没展开，或 §号解析错了")
        XCTAssertEqual(Self.danglingSectionPointers(in: docs),
                       ["README.md:1 → docs/规范.md 里没有 §6.18"],
                       "搬走的那一节没被抓成断链 ⇒ 这条守卫数不出东西")
        // 正例：那一节确实在，就不许报。
        let fixed = [(docs[0].0, docs[0].1.replacingOccurrences(of: "§6.18", with: "§6.17")),
                     docs[1]]
        XCTAssertTrue(Self.danglingSectionPointers(in: fixed).isEmpty, "指对了地方的被误判")
    }
}
