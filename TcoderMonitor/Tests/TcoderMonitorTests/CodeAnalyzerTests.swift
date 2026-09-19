import XCTest
@testable import TcoderMonitor

/// WS-A（静态代码分析）单元测试：`Services/Code` 的行分类、扫描纪律、圈复杂度、
/// 重复代码与端到端聚合。
///
/// 约定：
/// - 夹具一律写在 `FileManager.default.temporaryDirectory` 下、随测试即建即删，
///   绝不读写本仓库之外的资产；真实仓库自检只扫本仓库自身目录树。
/// - 断言以「不变式」优先，只有自己构造的夹具与纯函数才写死具体数字。
final class CodeAnalyzerTests: XCTestCase {

    // MARK: - 夹具基础设施

    var fm: FileManager { FileManager.default }

    /// 本测试独占的临时夹具根（已取真实路径）。
    ///
    /// `FileManager` 的目录枚举器返回的是**已解析软链接**的路径，而 macOS 的 temporaryDirectory 位于
    /// `/var -> /private/var` 之下（`resolvingSymlinksInPath()` 不解析这种前缀软链接，实测只有
    /// `canonicalPathKey` 能对齐）。夹具根不归一化就会让 relativePath 退化成主文件名、
    /// 带 `/` 的 skipDirectories 命不中、「是否越出夹具根」的断言也全线失真。
    func makeFixtureRoot() throws -> URL {
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: false)
        let canonical = try? base.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath
        guard let path = canonical, path.isEmpty == false else { return base }
        return URL(fileURLWithPath: path)
    }

    @discardableResult
    func write(_ text: String, to relativePath: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    func classify(_ url: URL, root: URL, options: ScanOptions = .default) -> ScannedSourceFile? {
        SourceFileClassifier(options: options).classify(url: url, root: root)
    }

    func scan(_ root: URL, options: ScanOptions = .default) async -> SourceScanResult {
        await SourceTreeScanner(options: options).scan(root: root)
    }

    /// 行种类串：C=代码、M=注释、_=空行，便于一次比对整份夹具的分类结果。
    func kindPattern(of file: ScannedSourceFile) -> String {
        file.lines.map { line in
            switch line.kind {
            case .code: return "C"
            case .comment: return "M"
            case .blank: return "_"
            }
        }.joined()
    }

    /// 逐行重新计数，不直接信结构体自带的汇总字段。
    func recount(_ file: ScannedSourceFile) -> (blank: Int, comment: Int, code: Int) {
        var blank = 0
        var comment = 0
        var code = 0
        for line in file.lines {
            switch line.kind {
            case .blank: blank += 1
            case .comment: comment += 1
            case .code: code += 1
            }
        }
        return (blank, comment, code)
    }

    func lineCountsHold(_ file: ScannedSourceFile) -> Bool {
        file.totalLineCount == file.blankLineCount + file.commentLineCount + file.codeLineCount
    }

    func codeLineTotal(of files: [ScannedSourceFile]) -> Int {
        files.reduce(0) { $0 + $1.codeLineCount }
    }

    func lineTotal(of files: [ScannedSourceFile]) -> Int {
        files.reduce(0) { $0 + $1.totalLineCount }
    }

    /// 显式构造 ScanOptions，避免受默认名单变更影响。
    func options(maxFiles: Int = 5_000,
                        maxFileBytes: Int = 2_000_000,
                        skipDirectories: Set<String> = [],
                        binaryExtensions: Set<String> = [],
                        includeHidden: Bool = false) -> ScanOptions {
        ScanOptions(maxFiles: maxFiles, maxFileBytes: maxFileBytes, skipDirectories: skipDirectories,
                    binaryExtensions: binaryExtensions, includeHidden: includeHidden)
    }

    // MARK: - A. 行分类不变式

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

    // MARK: - B. 注释判定按语言

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

    // MARK: - C. TODO / FIXME

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

        XCTAssertEqual(file.todoCount, 4, "第 1 行 1 个 + 第 2 行 2 个 + 第 4 行 1 个")
        XCTAssertEqual(file.fixmeCount, 2, "第 3、4 行各 1 个")
    }

    /// 现状记录：标记统计带**词边界**判定（`todoTotal` / `TODOS` 这类标识符不算命中），
    /// 但不做词法分析——字符串字面量里的 TODO 依然计入，且大小写不敏感。
    func testTodoMarkerUsesWordBoundaryButStillCountsStringLiterals() throws {
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

        XCTAssertEqual(file.todoCount, 1, "只有字符串字面量里的 TODO 命中；`todoTotal`、`TODOS` 因词边界规则不得计入")
        XCTAssertEqual(file.fixmeCount, 2, "字符串里的 FIXME + 注释里的小写 fixme 各 1 次（大小写不敏感）")
    }

    // MARK: - D. 语言映射

    func testLanguageCatalogMapsEveryRequiredExtension() {
        let expectations: [(String, String)] = [
            ("swift", "Swift"), ("java", "Java"), ("kt", "Kotlin"), ("ts", "TypeScript"),
            ("tsx", "TypeScript"), ("js", "JavaScript"), ("py", "Python"), ("go", "Go"),
            ("rs", "Rust"), ("c", "C"), ("cpp", "C++"), ("m", "Objective-C"), ("rb", "Ruby"),
            ("php", "PHP"), ("dart", "Dart"), ("vue", "Vue"), ("html", "HTML"), ("css", "CSS"),
            ("sql", "SQL"), ("sh", "Shell"), ("yml", "YAML"), ("toml", "TOML"), ("xml", "XML"),
            ("json", "JSON"), ("md", "Markdown"),
        ]
        for (ext, expected) in expectations {
            let resolved = SourceLanguageCatalog.language(forExtension: ext)
            XCTAssertEqual(resolved, expected, ".\(ext) 必须映射到 \(expected)，实际 \(resolved ?? "nil")")
        }
        XCTAssertEqual(SourceLanguageCatalog.language(forExtension: "SWIFT"), "Swift", "扩展名查表必须大小写不敏感")
        XCTAssertNil(SourceLanguageCatalog.language(forExtension: "png"), "二进制扩展名不得映射成源码语言")
        XCTAssertNil(SourceLanguageCatalog.language(forExtension: ""), "空扩展名必须返回 nil")
        XCTAssertNil(SourceLanguageCatalog.language(forExtension: "definitely-not-a-language"), "未知扩展名必须返回 nil")
    }

    func testSupportedLanguagesExposeCommentMetadata() {
        let supported = SourceLanguageCatalog.supportedLanguages
        XCTAssertFalse(supported.isEmpty, "必须至少声明一种语言")
        XCTAssertEqual(Set(supported).count, supported.count, "supportedLanguages 不得出现重名语言")
        for language in ["Swift", "Java", "Python", "SQL", "YAML", "JSON", "Markdown"] {
            XCTAssertTrue(supported.contains(language), "支持列表里必须能查到 \(language)")
        }

        XCTAssertEqual(SourceLanguageCatalog.lineCommentPrefixes(for: "Swift"), ["//"], "Swift 行注释前缀")
        XCTAssertTrue(SourceLanguageCatalog.lineCommentPrefixes(for: "Python").contains("#"), "Python 行注释前缀")
        XCTAssertTrue(SourceLanguageCatalog.lineCommentPrefixes(for: "SQL").contains("--"), "SQL 行注释前缀")
        XCTAssertTrue(SourceLanguageCatalog.lineCommentPrefixes(for: "JSON").isEmpty, "JSON 规范里没有注释")
        XCTAssertTrue(SourceLanguageCatalog.lineCommentPrefixes(for: "未发明的语言").isEmpty, "未知语言不得给任何规则")

        XCTAssertEqual(SourceLanguageCatalog.blockCommentDelimiters(for: "Swift")?.start, "/*", "Swift 块注释起始定界符")
        XCTAssertEqual(SourceLanguageCatalog.blockCommentDelimiters(for: "Swift")?.end, "*/", "Swift 块注释结束定界符")
        XCTAssertEqual(SourceLanguageCatalog.blockCommentDelimiters(for: "HTML")?.start, "<!--", "HTML 注释定界符")
        XCTAssertNil(SourceLanguageCatalog.blockCommentDelimiters(for: "Python"), "Python 没有块注释")
        XCTAssertNil(SourceLanguageCatalog.blockCommentDelimiters(for: "YAML"), "YAML 没有块注释")
        XCTAssertNil(SourceLanguageCatalog.blockCommentDelimiters(for: "未发明的语言"), "未知语言不得返回定界符")
        XCTAssertTrue(SourceLanguageCatalog.docStringDelimiters(for: "Python").contains("\"\"\""), "Python 三引号文档字符串")
        XCTAssertTrue(SourceLanguageCatalog.docStringDelimiters(for: "Swift").isEmpty, "Swift 没有文档字符串")
    }

    // MARK: - I. 重复代码

    func testNormalizeFoldsNumbersStringsAndIndentation() throws {
        XCTAssertEqual(DuplicationEngine.windowSize, 6, "滑窗大小冻结为 6 行")

        let twelve = try XCTUnwrap(DuplicationEngine.normalize("let totalAmount = 12", language: "Swift"))
        let seven = try XCTUnwrap(DuplicationEngine.normalize("let totalAmount = 7", language: "Swift"))
        XCTAssertEqual(twelve, seven, "只有常量不同的两行必须归一化成同一个 token，实际 \(twelve) / \(seven)")

        let shortText = try XCTUnwrap(DuplicationEngine.normalize("let noteText = \"aaa\"", language: "Swift"))
        let longText = try XCTUnwrap(DuplicationEngine.normalize("let noteText = \"different text here\"", language: "Swift"))
        XCTAssertEqual(shortText, longText, "字符串字面量必须整体折叠成占位符")

        let tabbed = try XCTUnwrap(DuplicationEngine.normalize("\t\tvar sumValue = leftSide + rightSide", language: "Swift"))
        let spaced = try XCTUnwrap(DuplicationEngine.normalize("        var sumValue = leftSide + rightSide", language: "Swift"))
        XCTAssertEqual(tabbed, spaced, "缩进风格不得影响归一化结果")

        for line in [twelve, shortText, tabbed] {
            XCTAssertEqual(line, line.trimmingCharacters(in: .whitespaces), "归一化结果不得残留首尾空白：\(line.debugDescription)")
            XCTAssertFalse(line.contains("  "), "连续空白必须压成单个空格：\(line.debugDescription)")
        }
        XCTAssertTrue(twelve.contains("N"), "数字必须替换为占位符，实际 \(twelve)")
        XCTAssertTrue(shortText.contains("S"), "字符串必须替换为占位符，实际 \(shortText)")
    }

    func testNormalizeDropsBlankCommentAndLowDensityLines() {
        // 低信息行必须丢弃：否则任意两个文件里的 `}` / `);` 都会撞出海量的假重复块。
        for noise in ["", "    ", "}", "x", "a + b", "// 说明文字", "return totalPayable"] {
            XCTAssertNil(DuplicationEngine.normalize(noise, language: "Swift"), "「\(noise)」这类低信息行必须丢弃")
        }
        XCTAssertNil(DuplicationEngine.normalize("# 说明文字", language: "Python"), "Python 注释行必须丢弃")
        XCTAssertNil(DuplicationEngine.normalize("    \"\"\"hi there\"\"\"", language: "Python"), "Python 文档字符串行必须丢弃")
        XCTAssertNotNil(DuplicationEngine.normalize("let totalAmount = 12", language: "Swift"), "正常代码行不得被丢弃")
    }

    func testDuplicationDetectedAcrossNearlyIdenticalFiles() async throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        // 两个文件只有数字常量与字符串字面量不同。
        let shared = { (number: Int, label: String) in
            """
                let grossAmount = itemCount * unitCost
                let discountValue = \(number)
                let shippingValue = \(number + 21)
                var totalPayable = grossAmount - discountValue
                totalPayable = totalPayable + shippingValue
                let capLimitValue = \(number + 77)
                if totalPayable > capLimitValue { totalPayable = capLimitValue }
                let noteText = "\(label)"
                let scaledValue = totalPayable * 3
                let flagState = scaledValue > capLimitValue && grossAmount > 0
                let labelName = noteText + "-"
                return labelName.count + scaledValue
            """
        }
        try write(shared(128, "alpha literal") + "\n", to: "Alpha.swift", in: root)
        try write(shared(999, "beta different literal") + "\n", to: "Beta.swift", in: root)
        try write("""
        enum MoodBoard {
            case calmSea
            case loudStorm
            static func describe(_ mood: MoodBoard) -> String {
                switch mood {
                case .calmSea: return "still water"
                case .loudStorm: return "ragged wind"
                }
            }
        }

        """, to: "Gamma.swift", in: root)

        let files = await scan(root, options: options(maxFiles: 100)).files
        XCTAssertEqual(files.count, 3, "三个夹具都必须进入分析：\(files.map(\.relativePath))")
        let result = DuplicationEngine.analyze(files)
        let expectedTotal = codeLineTotal(of: files)

        XCTAssertEqual(result.totalCodeLines, expectedTotal, "totalCodeLines 必须等于逐文件代码行之和")
        XCTAssertGreaterThan(result.totalCodeLines, 0, "分母必须有代码行")
        XCTAssertFalse(result.blocks.isEmpty, "仅常量/字符串不同的两个文件必须被判为重复")
        XCTAssertLessThanOrEqual(result.blocks.count, 20, "块数必须有上限，避免内存与 UI 失控")
        XCTAssertGreaterThanOrEqual(result.duplicatedCodeLines, DuplicationEngine.windowSize,
                                    "命中重复至少要覆盖一个滑窗")
        XCTAssertLessThanOrEqual(result.duplicatedCodeLines, result.totalCodeLines, "重复行数不得超过代码总行数")
        for block in result.blocks {
            XCTAssertGreaterThanOrEqual(block.lineCount, DuplicationEngine.windowSize, "重复块长度不得小于滑窗")
            XCTAssertGreaterThanOrEqual(block.occurrences.count, 2, "每个重复块至少要出现在两处")
            XCTAssertLessThanOrEqual(block.occurrences.count, 6, "每个块的 occurrence 数必须有上限")
            XCTAssertTrue(block.similarity >= 0 && block.similarity <= 1, "相似度必须落在 0...1")
            XCTAssertEqual(Set(block.occurrences.map { "\($0.path):\($0.startLine)" }).count, block.occurrences.count,
                           "同一块里的 occurrence 位置不得重复（同文件内部粘贴允许作为独立 occurrence）")
            for occurrence in block.occurrences {
                XCTAssertTrue(occurrence.path.hasPrefix(root.path), "重复块路径必须落在夹具根内：\(occurrence.path)")
                XCTAssertGreaterThanOrEqual(occurrence.startLine, 1, "重复位置必须是 1-based 行号")
            }
        }
        XCTAssertEqual(result.blocks.map(\.lineCount), result.blocks.map(\.lineCount).sorted(by: >), "块必须按长度降序输出")
        XCTAssertTrue(result.ratio >= 0 && result.ratio <= 1, "ratio 必须落在 0...1，实际 \(result.ratio)")
        XCTAssertEqual(result.ratio, Double(result.duplicatedCodeLines) / Double(expectedTotal), accuracy: 1e-9,
                       "ratio 必须等于「覆盖行数 / 代码总行数」，分母独立算得 \(expectedTotal)")
    }

    func testUnrelatedFilesReportNoDuplication() async throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        try write("""
            let grossAmount = itemCount * unitCost
            let discountValue = 128
            var totalPayable = grossAmount - discountValue
            totalPayable = totalPayable + shippingValue
            if totalPayable > capLimitValue { totalPayable = capLimitValue }
            let labelName = noteText + "-"
            return labelName.count + scaledValue
        """, to: "Alpha.swift", in: root)
        try write("""
        enum MoodBoard {
            case calmSea
            case loudStorm
            static func describe(_ mood: MoodBoard) -> String {
                switch mood {
                case .calmSea: return "still water"
                }
            }
        }

        """, to: "Gamma.swift", in: root)

        let files = await scan(root, options: options(maxFiles: 100)).files
        XCTAssertEqual(files.count, 2, "两个夹具都必须进入分析")
        let result = DuplicationEngine.analyze(files)
        XCTAssertEqual(result.blocks.count, 0, "内容互不相关的文件不得报出重复块：\(result.blocks)")
        XCTAssertEqual(result.duplicatedCodeLines, 0, "没有重复块时覆盖行数必须为 0")
        XCTAssertEqual(result.ratio, 0, accuracy: 1e-9, "没有重复时 ratio 必须为 0")
        XCTAssertGreaterThan(result.totalCodeLines, 0, "分母仍要如实统计代码行")

        // 少于两个文件不参与「跨文件重复」口径。
        let single = DuplicationEngine.analyze([files[0]])
        XCTAssertEqual(single.blocks.count, 0, "只有一个文件时不得产出跨文件重复块")
        XCTAssertEqual(single.ratio, 0, accuracy: 1e-9, "只有一个文件时 ratio 必须为 0")
        XCTAssertGreaterThan(single.totalCodeLines, 0, "单文件仍要如实给出代码行数")
    }

    // MARK: - J. 端到端

    func testAnalyzeEmptyDirectoryReturnsZerosWithoutThrowing() async throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        do {
            let metrics = try await FileSystemCodeAnalyzer().analyze(root: root, options: .default)
            XCTAssertEqual(metrics.totalFiles, 0, "空目录的文件数必须为 0")
            XCTAssertEqual(metrics.totalLines, 0, "空目录的行数必须为 0")
            XCTAssertEqual(metrics.blankLines, 0, "空目录不得凭空产出空行")
            XCTAssertEqual(metrics.commentLines, 0, "空目录不得凭空产出注释行")
            XCTAssertEqual(metrics.codeLines, 0, "空目录不得凭空产出代码行")
            XCTAssertEqual(metrics.todoCount, 0, "空目录 TODO 计数必须为 0")
            XCTAssertEqual(metrics.fixmeCount, 0, "空目录 FIXME 计数必须为 0")
            XCTAssertTrue(metrics.languages.isEmpty, "空目录没有语言分布")
            XCTAssertTrue(metrics.duplicatedBlocks.isEmpty, "空目录没有重复块")
            XCTAssertTrue(metrics.topComplexFunctions.isEmpty, "空目录不得有函数热点")
            XCTAssertEqual(metrics.duplicationRatio, 0, accuracy: 1e-9, "空目录重复率必须为 0")
            XCTAssertEqual(metrics.largestFileLineCount, 0, "空目录最大文件行数必须为 0")
            XCTAssertEqual(metrics.overallRisk, .none, "空目录不得虚报风险")
            XCTAssertEqual(metrics.totalLines, metrics.blankLines + metrics.commentLines + metrics.codeLines,
                           "空目录同样要满足行分类不变式")
        } catch {
            XCTFail("空目录是合法输入，绝不能抛错，实际抛出 \(error)")
        }
    }

    func testAnalyzeRejectsPathThatIsNotADirectory() async throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        let analyzer = FileSystemCodeAnalyzer()

        let missing = root.appendingPathComponent("no-such-directory")
        do {
            _ = try await analyzer.analyze(root: missing, options: .default)
            XCTFail("不存在的路径必须抛 AnalysisError.notDirectory")
        } catch let error as AnalysisError {
            XCTAssertEqual(error, .notDirectory(missing.path), "必须抛 notDirectory 并带上原路径，实际 \(error)")
        } catch {
            XCTFail("错误类型必须是 AnalysisError，实际 \(type(of: error))")
        }

        let fileURL = try write("let a = 1\n", to: "App.swift", in: root)
        do {
            _ = try await analyzer.analyze(root: fileURL, options: .default)
            XCTFail("传入普通文件必须抛 AnalysisError.notDirectory")
        } catch let error as AnalysisError {
            XCTAssertEqual(error, .notDirectory(fileURL.path), "普通文件不是目录，实际 \(error)")
        }
    }

    func testAnalyzeFixtureDirectorySatisfiesAllInvariants() async throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        try write("""
        import Foundation

        // TODO: 记录待办
        enum Kind {
            case one
            case two
        }

        func computeKindValue(_ kind: Kind, scale: Int) -> Int {
            if kind == .one && scale > 2 {
                return scale * 2
            }
            for step in 0..<3 {
                print(step)
            }
            return scale
        }

        """, to: "Sources/Alpha.swift", in: root)
        try write("let betaValue = 3\n// plain note\n", to: "Sources/Beta.swift", in: root)
        try write("def tool_main(v):\n    # FIXME: 修一下\n    return v\n", to: "Sources/tool.py", in: root)
        try write("# comment\nkey: value\n", to: "config.yml", in: root)
        try write("{\n  \"key\": 1\n}\n", to: "data.json", in: root)
        try write("plain text, 不是源码\n", to: "notes.txt", in: root)

        // 先用扫描器独立算一遍真值，再拿端到端结果对齐，避免写死会漂移的数字。
        let expected = await scan(root)
        let metrics = try await FileSystemCodeAnalyzer().analyze(root: root, options: .default)

        XCTAssertGreaterThan(metrics.totalFiles, 0, "正常夹具目录必须扫到文件")
        XCTAssertEqual(metrics.totalFiles, expected.files.count, "端到端文件数必须与扫描器一致")
        XCTAssertFalse(expected.files.contains { $0.relativePath.contains("notes.txt") }, "未收录扩展名不得进入结果")
        XCTAssertEqual(metrics.totalLines, metrics.blankLines + metrics.commentLines + metrics.codeLines,
                       "总行数必须等于空行+注释+代码：\(metrics.totalLines) vs \(metrics.blankLines)+\(metrics.commentLines)+\(metrics.codeLines)")
        XCTAssertEqual(metrics.totalLines, lineTotal(of: expected.files), "总行数必须等于逐文件行数之和")
        XCTAssertEqual(metrics.codeLines, codeLineTotal(of: expected.files), "代码行数必须等于逐文件代码行之和")
        XCTAssertEqual(metrics.todoCount, expected.files.reduce(0) { $0 + $1.todoCount }, "TODO 必须等于逐文件 TODO 之和")
        XCTAssertEqual(metrics.fixmeCount, expected.files.reduce(0) { $0 + $1.fixmeCount }, "FIXME 必须等于逐文件 FIXME 之和")
        XCTAssertEqual(metrics.largestFileLineCount, expected.files.map(\.totalLineCount).max(),
                       "largestFileLineCount 必须等于真实最长文件的行数")
        XCTAssertGreaterThan(metrics.durationMs, 0, "耗时必须被记录")
        XCTAssertTrue(RiskLevel.allCases.contains(metrics.overallRisk), "overallRisk 必须是有效档位，实际 \(metrics.overallRisk.rawValue)")

        XCTAssertFalse(metrics.languages.isEmpty, "必须给出语言分布")
        XCTAssertEqual(metrics.languages.map(\.lineCount), metrics.languages.map(\.lineCount).sorted(by: >),
                       "语言分布必须按代码行数降序：\(metrics.languages.map(\.lineCount))")
        XCTAssertTrue(metrics.languages.allSatisfy { $0.share >= 0 && $0.share <= 1 },
                      "每个语言占比必须落在 0...1：\(metrics.languages.map(\.share))")
        XCTAssertLessThanOrEqual(metrics.languages.reduce(0.0) { $0 + $1.share }, 1.000001, "占比总和不得超过 1")
        XCTAssertEqual(metrics.languages.reduce(0) { $0 + $1.lineCount }, metrics.codeLines,
                       "各语言代码行之和必须等于代码总行数")
        XCTAssertTrue(metrics.languages.allSatisfy { $0.fileCount > 0 }, "每个语言至少一个文件")
        XCTAssertNotNil(metrics.languages.first { $0.language == "Swift" }, "Swift 夹具必须出现在语言分布里")
        XCTAssertEqual(metrics.primaryLanguage, metrics.languages.first?.language, "primaryLanguage 必须取首位语言")

        XCTAssertTrue(metrics.duplicationRatio >= 0 && metrics.duplicationRatio <= 1, "重复率必须落在 0...1")
        XCTAssertLessThanOrEqual(metrics.duplicatedBlocks.count, 20, "重复块数必须有上限")
        XCTAssertLessThanOrEqual(metrics.topComplexFunctions.count, 20, "热点函数榜单必须有上限")
        XCTAssertLessThanOrEqual(metrics.hugeFiles.count, 20, "大文件榜单必须有上限")
        XCTAssertGreaterThanOrEqual(metrics.averageFunctionLength, 0, "平均函数长度不得为负")
        XCTAssertGreaterThanOrEqual(metrics.longFunctions, 0, "长函数个数不得为负")
        XCTAssertTrue(metrics.commentRatio >= 0 && metrics.commentRatio <= 1, "注释占比必须落在 0...1")
        for hotspot in metrics.topComplexFunctions {
            XCTAssertTrue(hotspot.filePath.hasPrefix(root.path), "热点路径必须落在被扫目录内：\(hotspot.filePath)")
            XCTAssertFalse(hotspot.name.isEmpty, "热点函数必须有名字")
            XCTAssertGreaterThanOrEqual(hotspot.cyclomaticComplexity, 1, "CC 必须 >= 1")
            XCTAssertGreaterThanOrEqual(hotspot.startLine, 1, "热点行号必须是 1-based")
        }
        XCTAssertEqual(metrics.topComplexFunctions.map(\.cyclomaticComplexity),
                       metrics.topComplexFunctions.map(\.cyclomaticComplexity).sorted(by: >), "热点必须按 CC 降序")
        for huge in metrics.hugeFiles {
            XCTAssertFalse(huge.suggestion.isEmpty, "大文件必须给出拆分建议")
            XCTAssertTrue(huge.path.hasPrefix(root.path), "大文件路径必须在被扫目录内：\(huge.path)")
        }
    }

    func testAnalyzeRealRepositoryKeepsInvariants() async throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)   // Tests/TcoderMonitorTests/CodeAnalyzerTests.swift
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: repositoryRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw XCTSkip("拿不到本仓库目录，跳过真实仓库自检")
        }

        let startedAt = Date()
        let metrics = try await FileSystemCodeAnalyzer().analyze(root: repositoryRoot, options: .default)
        let wallMs = Int(Date().timeIntervalSince(startedAt) * 1000)

        // 只断言不变式，不断言具体数字：仓库内容会随并行开发漂移。
        XCTAssertEqual(metrics.totalLines, metrics.blankLines + metrics.commentLines + metrics.codeLines,
                       "真实仓库上总行数不变式必须成立：\(metrics.totalLines) vs \(metrics.blankLines)+\(metrics.commentLines)+\(metrics.codeLines)")
        XCTAssertGreaterThan(metrics.totalFiles, 0, "本仓库一定有源码")
        XCTAssertGreaterThan(metrics.codeLines, 0, "本仓库一定有代码行")
        XCTAssertGreaterThan(metrics.largestFileLineCount, 0, "最大文件行数必须为正")
        XCTAssertEqual(metrics.languages.map(\.lineCount), metrics.languages.map(\.lineCount).sorted(by: >), "语言分布必须降序")
        XCTAssertLessThanOrEqual(metrics.languages.reduce(0.0) { $0 + $1.share }, 1.000001, "语言占比总和不得超过 1")
        XCTAssertTrue(metrics.languages.allSatisfy { $0.share >= 0 && $0.share <= 1 }, "语言占比必须落在 0...1")
        XCTAssertEqual(metrics.languages.reduce(0) { $0 + $1.lineCount }, metrics.codeLines, "语言行数之和必须等于代码总行数")
        XCTAssertTrue(metrics.duplicationRatio >= 0 && metrics.duplicationRatio <= 1, "重复率必须落在 0...1")
        XCTAssertLessThanOrEqual(metrics.duplicatedBlocks.count, 20, "重复块数必须有上限")
        XCTAssertLessThanOrEqual(metrics.topComplexFunctions.count, 20, "热点数必须有上限")
        XCTAssertLessThanOrEqual(metrics.hugeFiles.count, 20, "大文件数必须有上限")
        XCTAssertTrue(RiskLevel.allCases.contains(metrics.overallRisk), "风险档位必须有效")
        XCTAssertGreaterThan(metrics.durationMs, 0, "耗时必须被记录")

        for hotspot in metrics.hugeFiles {
            XCTAssertTrue(hotspot.path.hasPrefix(repositoryRoot.path), "扫描不得越出仓库根：\(hotspot.path)")
        }
        for function in metrics.topComplexFunctions {
            XCTAssertTrue(function.filePath.hasPrefix(repositoryRoot.path), "热点路径不得越出仓库根：\(function.filePath)")
        }
        for block in metrics.duplicatedBlocks {
            for occurrence in block.occurrences {
                XCTAssertTrue(occurrence.path.hasPrefix(repositoryRoot.path), "重复块路径不得越出仓库根：\(occurrence.path)")
            }
        }

        NSLog("[Tcoder][CodeAnalyzerTests] 真实仓库自检 %@ files=%d lines=%d blank=%d comment=%d code=%d largest=%d todo=%d fixme=%d dupRatio=%.4f blocks=%d risk=%@ primary=%@ durationMs=%d wallMs=%d",
              repositoryRoot.path, metrics.totalFiles, metrics.totalLines, metrics.blankLines, metrics.commentLines,
              metrics.codeLines, metrics.largestFileLineCount, metrics.todoCount, metrics.fixmeCount,
              metrics.duplicationRatio, metrics.duplicatedBlocks.count, metrics.overallRisk.rawValue,
              metrics.primaryLanguage, metrics.durationMs, wallMs)
        NSLog("[Tcoder][CodeAnalyzerTests] 真实仓库语言分布：%@",
              metrics.languages.map { "\($0.language)=\($0.lineCount)行/\($0.fileCount)文件" }.joined(separator: ", "))
        NSLog("[Tcoder][CodeAnalyzerTests] 真实仓库热点 Top1：%@",
              metrics.topComplexFunctions.first.map { "\($0.name) CC=\($0.cyclomaticComplexity) 行数=\($0.lineCount)" } ?? "无")
    }

    // MARK: - K. 性能护栏

    func testAnalyzeSyntheticTreeBeyondSixtyThousandLinesWithinBudget() async throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        let perFile = 2_600
        let fileCount = 24
        for index in 0..<fileCount {
            var body = ""
            body.reserveCapacity(perFile * 56)
            for line in 0..<perFile {
                // 每行都带唯一标识符，避免合成夹具自身撞出海量重复块。
                body += "    let compositeValue\(index)_\(line) = baseValue\(line) + \(line)\n"
            }
            try write(body, to: "Generated\(index).swift", in: root)
        }

        let startedAt = Date()
        let metrics = try await FileSystemCodeAnalyzer().analyze(root: root, options: .default)
        let elapsedSeconds = Date().timeIntervalSince(startedAt)

        XCTAssertGreaterThanOrEqual(metrics.totalLines, 60_000, "夹具规模必须真的超过 6 万行，实际 \(metrics.totalLines)")
        XCTAssertEqual(metrics.totalFiles, fileCount, "所有生成文件都要被扫到")
        XCTAssertEqual(metrics.totalLines, metrics.blankLines + metrics.commentLines + metrics.codeLines,
                       "大夹具下不变式仍必须成立：\(metrics.totalLines) vs \(metrics.blankLines)+\(metrics.commentLines)+\(metrics.codeLines)")
        XCTAssertTrue(metrics.duplicationRatio >= 0 && metrics.duplicationRatio <= 1, "大夹具下重复率仍必须合法")
        XCTAssertLessThan(elapsedSeconds, 30,
                          "6 万行以上的分析必须在 30 秒内完成，实际 \(String(format: "%.2f", elapsedSeconds)) 秒")
        NSLog("[Tcoder][CodeAnalyzerTests] 性能护栏 files=%d lines=%d code=%d dupRatio=%.4f blocks=%d durationMs=%d wallMs=%d",
              metrics.totalFiles, metrics.totalLines, metrics.codeLines, metrics.duplicationRatio,
              metrics.duplicatedBlocks.count, metrics.durationMs, Int(elapsedSeconds * 1000))
    }

    // MARK: - L. 已知缺陷（上游修复前预期失败）

    /// `\r\n` 在 Swift 里是**一个** `Character`（字素簇），早期实现用 `split { $0 == "\n" }` 切行，
    /// 于是整份 CRLF 文件切不出分隔符、被当成 1 行。20:38 已由总工修复（谓词同时接受 `\r\n` 与 `\r`），
    /// 本条从「钉缺陷」转为**回归护栏**。
    func testCarriageReturnLineEndingsAreCountedPerLine() throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        let url = try write("let a = 1\r\n// comment line\r\n\r\n", to: "Windows.swift", in: root)
        guard let file = classify(url, root: root) else { return XCTFail("Swift 夹具必须分类成功") }

        XCTAssertTrue(lineCountsHold(file), "CRLF 文件也必须满足 total == blank+comment+code")
        XCTAssertEqual(file.totalLineCount, 3,
                       "CRLF 行尾必须按行切开；当前实现把整份 CRLF 文件算成 \(file.totalLineCount) 行")
        XCTAssertEqual(file.codeLineCount, 1, "CRLF 下代码行数")
        XCTAssertEqual(file.commentLineCount, 1, "CRLF 下注释行数")
        XCTAssertEqual(file.blankLineCount, 1, "CRLF 下空行数")
    }
}
