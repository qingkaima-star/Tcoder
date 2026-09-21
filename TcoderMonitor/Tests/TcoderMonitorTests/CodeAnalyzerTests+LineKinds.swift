/// OWNER: WS-X3 TestSplit —— 自 CodeAnalyzerTests.swift 拆出，行种不变式：块注释/三引号/未闭合注释与 TODO 计数的独立性。用例本体未改，只是搬了家。
import XCTest
@testable import TcoderMonitor

extension CodeAnalyzerTests {

    func testLineKindInvariantHoldsForBlockComments() throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        let content = """
        import Foundation

        /*
         * block two
         * block three
         */
        let v1 = 2 /* mid */ + 3
        // tail comment
        /* one */ let v2 = 4

        """
        let url = try write(content, to: "Block.swift", in: root)
        guard let file = classify(url, root: root) else { return XCTFail("Swift 夹具必须分类成功") }
        let counted = recount(file)

        XCTAssertTrue(lineCountsHold(file),
                      "行分类必须无重无漏：total=\(file.totalLineCount) 应等于 blank+comment+code=\(file.blankLineCount + file.commentLineCount + file.codeLineCount)")
        XCTAssertEqual(kindPattern(of: file), "C_MMMMCMC",
                       "块注释整段算注释；`代码 /* 注释 */ 代码` 算代码行；以块注释开头但后续还有代码的行也算代码")
        XCTAssertEqual(file.totalLineCount, 9, "以换行符收尾的文件不得把末尾换行再算成一空行")
        XCTAssertEqual(file.blankLineCount, counted.blank, "blankLineCount 必须与逐行 kind 一致")
        XCTAssertEqual(file.commentLineCount, counted.comment, "commentLineCount 必须与逐行 kind 一致")
        XCTAssertEqual(file.codeLineCount, counted.code, "codeLineCount 必须与逐行 kind 一致")
        XCTAssertEqual(file.totalLineCount, file.lines.count, "totalLineCount 必须就是 lines 条数")
        XCTAssertEqual(file.url, url, "classify 必须原样回传被分类的 URL")
        XCTAssertEqual(file.relativePath, "Block.swift", "relativePath 必须以夹具根为基准")
        XCTAssertEqual(file.lines.first?.number, 1, "行号必须从 1 开始")
        XCTAssertEqual(file.lines.last?.number, file.totalLineCount, "行号必须连续到最后一行")
    }

    func testPythonTripleQuoteDocStringIsClassifiedAsComment() throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        let content = "def helper():\n    \"\"\"Docstring line one.\n    Docstring line two.\n    \"\"\"\n    return 1\n"
        let url = try write(content, to: "Doc.py", in: root)
        guard let file = classify(url, root: root) else { return XCTFail("Python 夹具必须分类成功") }

        XCTAssertEqual(file.language, "Python", "扩展名决定语言")
        XCTAssertTrue(lineCountsHold(file), "三引号夹具同样必须满足 total == blank+comment+code")
        XCTAssertEqual(kindPattern(of: file), "CMMMC", "三引号文档字符串跨行期间必须一直是注释")
    }

    func testCrossLineDocCommentKeepsCommentStateBetweenLines() throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        let url = try write("/**\n * multi doc\n */\nfunc noop() {}\n", to: "Doc.swift", in: root)
        guard let file = classify(url, root: root) else { return XCTFail("Swift 夹具必须分类成功") }

        XCTAssertEqual(kindPattern(of: file), "MMMC", "块注释状态机必须跨行保持，闭合之后的行才回到代码")
        XCTAssertTrue(lineCountsHold(file), "跨行注释夹具必须满足行分类不变式")
    }

    func testUnterminatedBlockCommentAndEmptyFileKeepInvariant() throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }

        let open = try XCTUnwrap(classify(try write("/* 未闭合的块注释\nlet a = 1\nlet b = 2\n", to: "Open.swift", in: root), root: root))
        XCTAssertTrue(lineCountsHold(open), "未闭合块注释也不得破坏 total == blank+comment+code")
        XCTAssertEqual(open.codeLineCount, 0, "现状：未闭合块注释之后的行一律视作注释内容")

        let empty = try XCTUnwrap(classify(try write("", to: "Empty.swift", in: root), root: root))
        XCTAssertEqual(empty.totalLineCount, 0, "空文件行数为 0")
        XCTAssertTrue(empty.lines.isEmpty, "空文件不得产生行记录")
        XCTAssertTrue(lineCountsHold(empty), "空文件也必须满足行分类不变式")

        let noNewline = try XCTUnwrap(classify(try write("let a = 1", to: "Tail.swift", in: root), root: root))
        XCTAssertEqual(noNewline.totalLineCount, 1, "末行没有换行符时仍要计入 1 行")
    }

    func testCommentPrefixDependsOnLanguage() throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }

        // 同一行内容 `// x`：Swift 里是注释，JSON / YAML 里不是（JSON 无注释语法，YAML 用 #）。
        let swift = try XCTUnwrap(classify(try write("// x\n", to: "Same.swift", in: root), root: root))
        XCTAssertEqual(swift.language, "Swift", ".swift 必须映射为 Swift")
        XCTAssertEqual(swift.commentLineCount, 1, "Swift 中 // 开头必须是注释行")

        let json = try XCTUnwrap(classify(try write("// x\n", to: "Same.json", in: root), root: root))
        XCTAssertEqual(json.commentLineCount, 0, "JSON 没有 // 注释语法，不得判成注释")
        XCTAssertEqual(json.codeLineCount, 1, "JSON 中的 // 行按代码统计")

        let yaml = try XCTUnwrap(classify(try write("// x\n# y\n", to: "Same.yml", in: root), root: root))
        XCTAssertEqual(yaml.commentLineCount, 1, "YAML 只有 # 是注释")
        XCTAssertEqual(yaml.codeLineCount, 1, "YAML 中的 // 行按代码统计")

        let sql = try XCTUnwrap(classify(try write("-- x\n// y\n", to: "Same.sql", in: root), root: root))
        XCTAssertEqual(sql.commentLineCount, 1, "SQL 的行注释前缀是 --")
        XCTAssertEqual(sql.codeLineCount, 1, "SQL 中 // 不是注释")

        for (name, content) in [("m.md", "<!-- hidden -->\ntext\n"), ("m.xml", "<!-- c -->\n<a/>\n"), ("m.py", "# c\nx = 1\n")] {
            let file = try XCTUnwrap(classify(try write(content, to: name, in: root), root: root), "\(name) 必须分类成功")
            XCTAssertTrue(lineCountsHold(file), "\(name) 必须满足行分类不变式")
            XCTAssertEqual(file.commentLineCount, 1, "\(name) 的第一行必须按其语言规则判为注释")
        }
    }

    func testTodoAndFixmeCountsAreIndependent() throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        let url = try write("// FIXME: 只有这个\nlet a = 1\n", to: "Marker.swift", in: root)
        guard let file = classify(url, root: root) else { return XCTFail("Swift 夹具必须分类成功") }

        XCTAssertEqual(file.fixmeCount, 1, "FIXME 必须计 1 次")
        XCTAssertEqual(file.todoCount, 0, "FIXME 不含 TODO 子串，绝不能被算进 TODO")
    }

    func testTodoAndFixmeCountEveryMarkerOnTheLine() throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        let content = """
        // TODO: alpha
        // TODO beta TODO gamma
        // FIXME: delta
        // FIXME with TODO inside
        """
        let url = try write(content + "\n", to: "Many.swift", in: root)
        guard let file = classify(url, root: root) else { return XCTFail("Swift 夹具必须分类成功") }

        // 手算（收官轮判据收紧后）：todo = 第 1 行 `TODO:` 1 个 + 第 2 行行首那个 1 个 = 2；
        // 第 2 行句中的第二个 TODO、第 4 行 "with TODO inside" 都不在行首、后面也不是冒号 ⇒ 不算。
        // FIXME = 第 3 行 `FIXME:` 与第 4 行行首各 1 个 = 2（与收紧前同值，这两行本来就是真标记）。
        // 收紧前这里报 4：同一行里"提到两次"被数成"欠两笔"。
        XCTAssertEqual(file.todoCount, 2, "只有位于注释开头或紧跟冒号的 TODO 才算一笔")
        XCTAssertEqual(file.fixmeCount, 2, "第 3、4 行各 1 个")
    }

    /// 词边界 + 位置双判据：标识符（`todoTotal` / `TODOS`）不算，**代码行里的字符串字面量也不算**。
    /// 改名沿革：原名 `...ButStillCountsStringLiterals` 钉的是收紧前的子串口径；
    /// 收官轮把「界面文案 `Text("FIXME 45 处")` 被数成 45 里的 3 处」这类误报修掉之后，
    /// 那个前提反了，于是按本仓规矩**翻正并改名**（不是删用例）。大小写仍不敏感。
    func testTodoMarkerIgnoresIdentifiersStringLiteralsAndProse() throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        let content = """
        let todoTotal = 1
        let msg = "TODO in string and FIXME too"
        // fixme lowercase counted
        // TODOS plural
        """
        let url = try write(content + "\n", to: "Boundary.swift", in: root)
        guard let file = classify(url, root: root) else { return XCTFail("Swift 夹具必须分类成功") }

        // 手算：todo = 0（第 1 行标识符、第 2 行在代码行的字符串里、第 4 行 TODOS 越出词边界）；
        // fixme = 1（只有第 3 行 `// fixme lowercase counted` 是注释开头的真标记，大小写不敏感）。
        XCTAssertEqual(file.todoCount, 0, "标识符、代码行里的字符串字面量都不是欠账")
        XCTAssertEqual(file.fixmeCount, 1, "只数注释行开头那一个小写 fixme（大小写不敏感）")
    }

}
