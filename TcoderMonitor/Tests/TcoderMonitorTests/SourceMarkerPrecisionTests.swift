import XCTest
@testable import TcoderMonitor

/// 待办标记计数器的**双向**判据。
///
/// 病因（真机自扫扫出来的第 4 条自我矛盾）：本 App 扫自己时报 `FIXME 45 处 / TODO 49 处`，
/// 而逐条 `grep` 之后真正的欠账标记只有 2 处 —— 其余全被子串口径误伤：
/// 界面文案 `Text("FIXME \(...)")`（App 显示"FIXME 45 处"这句话自己贡献了 3 处）、
/// 讲 FIXME 用法的测试说明、文档正文里的词。一个把 FIXME 计数做进界面的工具，
/// 界面上那三个字也在喂计数。收紧之后的代价是"真标记漏计"，所以这里两头都钉：
/// 真标记（哪怕大小写混排、哪怕 `- [ ] TODO`）必计，字符串与散文里的提及必不计。
final class SourceMarkerPrecisionTests: XCTestCase {

    private let fm = FileManager.default

    private func makeRoot(_ name: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tcoder-marker-\(name)-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private func write(_ content: String, named name: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 用产品自己的走树 + 分类器读数，不自己数子串。
    private func markers(in root: URL, named name: String) async throws -> (todo: Int, fixme: Int) {
        let scanned = await SourceTreeScanner(options: .default).scan(root: root)
        let file = try XCTUnwrap(scanned.files.first { $0.url.lastPathComponent == name },
                                 "夹具 \(name) 没被扫到，扫描面退化了")
        return (file.todoCount, file.fixmeCount)
    }

    // MARK: - ① 真标记必计（多语言、多写法）

    func testRealMarkersAreCountedAcrossCommentStyles() async throws {
        let root = try makeRoot("real")
        defer { try? fm.removeItem(at: root) }
        let cases: [(file: String, line: String)] = [
            ("a.swift", "// TODO: 补边界用例"),
            ("b.swift", "// FIXME 这里少了早返回"),
            ("c.swift", "//    TODO 缩进之后仍是行首"),
            ("d.py", "# TODO 走 RPC 而不是桩数据"),
            ("e.sh", "# FIXME: 锁回收没测"),
            ("f.html", "<!-- TODO 补 aria 标签 -->"),
            ("h.swift", "/* FIXME 块注释里的真标记 */"),
        ]
        for item in cases {
            try await assertSingleMarker(root: root, file: item.file, line: item.line)
        }
    }

    private func assertSingleMarker(root: URL, file: String, line: String) async throws {
        try write(line + "\n", named: file, in: root)
        let got = try await markers(in: root, named: file)
        XCTAssertEqual(got.todo + got.fixme, 1,
                       "\(file) 里的「\(line)」必须算作恰好一笔欠账，实测 TODO=\(got.todo) FIXME=\(got.fixme)")
    }

    /// 边界：Markdown 没有注释语法，`- [ ] TODO 某事` 这类**文档任务清单**不计入本数。
    /// 这不是漏判而是口径划线：`todoCount` 量的是代码注释里欠下的技术账，文档里待办的人
    /// 读的是另一页。把两者合成一个数，界面那句「TODO 49 处」就再也不能解释自己数了什么。
    func testMarkdownChecklistIsOutOfScopeByDesign() async throws {
        let root = try makeRoot("md")
        defer { try? fm.removeItem(at: root) }
        try write("- [ ] TODO 把口径写进文档\n", named: "g.md", in: root)
        let got = try await markers(in: root, named: "g.md")
        XCTAssertEqual(got.todo + got.fixme, 0,
                       "文档任务清单按口径不该进代码欠账计数；若将来要数，得另立一个字段而不是改这里")
    }

    // MARK: - ② 提及必不计（字符串、代码行、散文、标识符）

    func testMentionsAreNotDebt() async throws {
        let root = try makeRoot("mentions")
        defer { try? fm.removeItem(at: root) }
        let lines = [
            "let todoTotal = 1",                              // 标识符（词边界）
            "let msg = \"TODO in string and FIXME too\"",     // 代码行里的字符串字面量
            "Text(\"FIXME \\(NumberFormat.grouped(count)) 处\")",  // 界面文案——病因本身
            "// 这里解释 FIXME 的用法，别学它",                  // 注释句子中段
            "// 见 TODO 列表里那条",                            // 同上
            "// TODOS 复数形式",                                // 越出词边界
        ]
        try write(lines.joined(separator: "\n") + "\n", named: "Mentions.swift", in: root)
        let got = try await markers(in: root, named: "Mentions.swift")
        XCTAssertEqual(got.todo, 0, "六行里没有一行是真欠账：\(got)")
        XCTAssertEqual(got.fixme, 0, "六行里没有一行是真欠账：\(got)")
    }

    // MARK: - ③ 混合样本必须等于手算值（防"什么都不数"的假绿）

    func testMixedFixtureMatchesHandCount() async throws {
        let root = try makeRoot("mixed")
        defer { try? fm.removeItem(at: root) }
        let content = """
        // TODO: 一笔
        // TODO 又一笔（行首、无冒号）
        // 句子中段的一个 TODO 不算
        let label = "FIXME 出现在字符串里，不算"
        // FIXME: 一笔
        // fixme 小写在行首，算
        func f() { let fixmeCount = 0 }
        """
        try write(content + "\n", named: "Mixed.swift", in: root)
        let got = try await markers(in: root, named: "Mixed.swift")
        // 手算：TODO = 第 1、2 行；FIXME = 第 5、6 行。第 3 行句中、第 4 行字符串、第 7 行标识符。
        XCTAssertEqual(got.todo, 2, "Mixed.swift 的 TODO 手算 2 笔，实测 \(got.todo)")
        XCTAssertEqual(got.fixme, 2, "Mixed.swift 的 FIXME 手算 2 笔，实测 \(got.fixme)")
    }

    /// 反向自证：本类②组夹具若被扫描器整体跳过，①组与③组会一起变红；
    /// 这里再单独钉一次"确实扫到了东西"，免得整类空转。
    func testScannerActuallyReadsTheFixtures() async throws {
        let root = try makeRoot("denominator")
        defer { try? fm.removeItem(at: root) }
        try write("// TODO: 一行\n", named: "D.swift", in: root)
        let scanned = await SourceTreeScanner(options: .default).scan(root: root)
        XCTAssertGreaterThanOrEqual(scanned.files.count, 1, "一个文件都没扫到，本类所有断言都会假绿")
        let counted = scanned.files.reduce(0) { $0 + $1.todoCount + $1.fixmeCount }
        XCTAssertEqual(counted, 1, "扫到了却没数到标记，说明计数没接上")
    }
}
