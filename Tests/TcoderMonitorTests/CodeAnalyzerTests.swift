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

    private var fm: FileManager { FileManager.default }

    /// 本测试独占的临时夹具根（已取真实路径）。
    ///
    /// `FileManager` 的目录枚举器返回的是**已解析软链接**的路径，而 macOS 的 temporaryDirectory 位于
    /// `/var -> /private/var` 之下（`resolvingSymlinksInPath()` 不解析这种前缀软链接，实测只有
    /// `canonicalPathKey` 能对齐）。夹具根不归一化就会让 relativePath 退化成主文件名、
    /// 带 `/` 的 skipDirectories 命不中、「是否越出夹具根」的断言也全线失真。
    private func makeFixtureRoot() throws -> URL {
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: false)
        let canonical = try? base.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath
        guard let path = canonical, path.isEmpty == false else { return base }
        return URL(fileURLWithPath: path)
    }

    @discardableResult
    private func write(_ text: String, to relativePath: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func classify(_ url: URL, root: URL, options: ScanOptions = .default) -> ScannedSourceFile? {
        SourceFileClassifier(options: options).classify(url: url, root: root)
    }

    private func scan(_ root: URL, options: ScanOptions = .default) async -> SourceScanResult {
        await SourceTreeScanner(options: options).scan(root: root)
    }

    /// 行种类串：C=代码、M=注释、_=空行，便于一次比对整份夹具的分类结果。
    private func kindPattern(of file: ScannedSourceFile) -> String {
        file.lines.map { line in
            switch line.kind {
            case .code: return "C"
            case .comment: return "M"
            case .blank: return "_"
            }
        }.joined()
    }

    /// 逐行重新计数，不直接信结构体自带的汇总字段。
    private func recount(_ file: ScannedSourceFile) -> (blank: Int, comment: Int, code: Int) {
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

    private func lineCountsHold(_ file: ScannedSourceFile) -> Bool {
        file.totalLineCount == file.blankLineCount + file.commentLineCount + file.codeLineCount
    }

    private func codeLineTotal(of files: [ScannedSourceFile]) -> Int {
        files.reduce(0) { $0 + $1.codeLineCount }
    }

    private func lineTotal(of files: [ScannedSourceFile]) -> Int {
        files.reduce(0) { $0 + $1.totalLineCount }
    }

    /// 显式构造 ScanOptions，避免受默认名单变更影响。
    private func options(maxFiles: Int = 5_000,
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

    // MARK: - E. relativePath 与 classify 的前置过滤

    func testRelativePathUsesRootPrefixAndFallsBackToFileName() {
        let root = URL(fileURLWithPath: "/tmp/tcoder-relative-root")
        XCTAssertEqual(SourceFileClassifier.relativePath(for: root.appendingPathComponent("Sources/Alpha.swift"), root: root),
                       "Sources/Alpha.swift", "根之下的文件必须给出相对路径")
        XCTAssertEqual(SourceFileClassifier.relativePath(for: root.appendingPathComponent("App.swift"), root: root),
                       "App.swift", "根目录直属文件只留文件名")
        XCTAssertEqual(SourceFileClassifier.relativePath(for: URL(fileURLWithPath: "/elsewhere/deep/Other.swift"), root: root),
                       "Other.swift", "现状：根之外的 URL 退化为主文件名")
        // 现状记录：根未做软链接归一化时（macOS 临时目录、软链接下的仓库根都很常见）同样退化成主文件名，
        // 这会让 UI 上不同目录的同名文件显示成同一个路径。
        XCTAssertEqual(SourceFileClassifier.relativePath(for: URL(fileURLWithPath: "/private/tmp/x/KeepMe/Kept.swift"),
                                                        root: URL(fileURLWithPath: "/tmp/x")),
                       "Kept.swift", "现状：/tmp 与 /private/tmp 判定不到同一个根")
    }

    func testClassifyRejectsUnknownExtensionOversizedFileAndSymlink() throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }

        XCTAssertNil(classify(try write("just plain text\n", to: "notes.txt", in: root), root: root),
                     "未收录的扩展名必须返回 nil")

        let bigURL = try write(String(repeating: "let bigLineValue = 1\n", count: 200), to: "Big.swift", in: root)
        XCTAssertNil(classify(bigURL, root: root, options: options(maxFileBytes: 128)),
                     "超过 maxFileBytes 的文件必须拒绝分类")
        XCTAssertNotNil(classify(bigURL, root: root), "默认上限内必须能分类")

        let target = try write("let linkTargetValue = 1\n", to: "Real.swift", in: root)
        let link = root.appendingPathComponent("Alias.swift")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        XCTAssertNil(classify(link, root: root), "符号链接文件必须拒绝分类，不得顺着链接读到夹具外")
    }

    // MARK: - F. 扫描纪律

    func testScanSkipsExcludedDirectoriesByNameAndRelativePath() async throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        try write("let appValue = 1\n", to: "App.swift", in: root)
        try write("let vendoredValue = 1\n", to: "node_modules/Dep.swift", in: root)
        try write("let builtValue = 1\n", to: "build/Generated.swift", in: root)
        try write("let keptValue = 1\n", to: "KeepMe/Kept.swift", in: root)
        try write("let droppedValue = 1\n", to: "SkipMe/Dropped.swift", in: root)

        let custom = await scan(root, options: options(skipDirectories: ["SkipMe"]))
        let paths = custom.files.map(\.relativePath)
        XCTAssertFalse(paths.contains("SkipMe/Dropped.swift"), "skipDirectories 命中的目录必须整体不进入：\(paths)")
        XCTAssertTrue(paths.contains("KeepMe/Kept.swift"), "未命中的子目录必须正常进入：\(paths)")
        XCTAssertTrue(paths.contains("App.swift"), "根目录文件必须进入：\(paths)")
        XCTAssertEqual(custom.visitedFileCount, custom.scannedFileCount + custom.skippedFileCount,
                       "visited 必须等于 scanned + skipped；剔除目录里的文件不得计入 visited")

        let defaults = await scan(root)
        let defaultPaths = defaults.files.map(\.relativePath)
        XCTAssertFalse(defaultPaths.contains { $0.hasPrefix("node_modules/") },
                       "默认 skipDirectories 必须跳过 node_modules：\(defaultPaths)")
        XCTAssertFalse(defaultPaths.contains { $0.hasPrefix("build/") },
                       "默认 skipDirectories 必须跳过 build：\(defaultPaths)")
        XCTAssertTrue(defaults.files.contains { $0.relativePath == "KeepMe/Kept.swift" },
                       "默认配置下普通子目录仍要扫到：\(defaultPaths)")
    }

    func testScanSkipsNestedRelativeSkipPath() async throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        try write("let keptValue = 1\n", to: "Payload/Keep.swift", in: root)
        try write("let generatedValue = 1\n", to: "Payload/Deep/Gen.swift", in: root)

        let result = await scan(root, options: options(skipDirectories: ["Payload/Deep"]))
        XCTAssertEqual(result.files.map(\.relativePath), ["Payload/Keep.swift"],
                       "带 / 的 skipDirectories 必须按相对路径命中，而不是按同名目录全局命中")
    }

    func testHiddenFilesAreScannedOnlyWhenOptionEnabled() async throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        try write("let visibleValue = 1\n", to: "Visible.swift", in: root)
        try write("let hiddenValue = 1\n", to: ".cache/Hidden.swift", in: root)
        try write("let dotfileValue = 1\n", to: ".dotfile.swift", in: root)

        let excluded = await scan(root)
        XCTAssertEqual(excluded.files.map(\.relativePath), ["Visible.swift"],
                       "includeHidden=false（默认）必须跳过 . 开头的文件与目录：\(excluded.files.map(\.relativePath))")

        let included = await scan(root, options: options(includeHidden: true))
        XCTAssertEqual(included.files.map(\.relativePath).sorted(),
                       [".cache/Hidden.swift", ".dotfile.swift", "Visible.swift"],
                       "includeHidden=true 必须把隐藏文件与隐藏目录都纳入")
    }

    func testOversizedBinaryAndUnmappedFilesAreCountedAsSkipped() async throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        try write("let appValue = 1\n", to: "App.swift", in: root)
        try write(String(repeating: "let bigLineValue = 1\n", count: 400), to: "Big.swift", in: root)
        try write("{\n  \"key\": \"value\"\n}\n", to: "payload.json", in: root)
        try write("plain text\n", to: "notes.txt", in: root)

        let result = await scan(root, options: options(maxFileBytes: 300, binaryExtensions: ["json"]))
        XCTAssertEqual(result.files.map(\.relativePath).sorted(), ["App.swift"],
                       "超 maxFileBytes / 命中 binaryExtensions / 未知扩展名都不得进入结果")
        XCTAssertEqual(result.visitedFileCount, 4, "被拦下的文件仍要计入 visited")
        XCTAssertEqual(result.skippedFileCount, 3, "被纪律拦下的文件必须计入 skipped")
        XCTAssertEqual(result.scannedFileCount, 1, "只有合规文件被真正分类")
        XCTAssertFalse(result.truncatedByMaxFiles, "文件数远未达上限，不得标记截断")

        // binaryExtensions 的判定必须优先于语言映射：.json 本身是受支持语言，
        // 被列为二进制才跳过；不放名单时必须能扫到，否则上一条断言没有区分度。
        let jsonAllowed = await scan(root, options: options(maxFileBytes: 300))
        XCTAssertTrue(jsonAllowed.files.contains { $0.relativePath == "payload.json" },
                      "不把 json 列为二进制时它必须被扫到：\(jsonAllowed.files.map(\.relativePath))")
    }

    func testMaxFilesTruncatesScanAndFlagsResult() async throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        for index in 0..<8 {
            try write("let sampleValue\(index) = \(index)\n", to: "Sample\(index).swift", in: root)
        }

        let capped = await scan(root, options: options(maxFiles: 3))
        XCTAssertGreaterThan(capped.files.count, 0, "截断也必须留下可用样本")
        XCTAssertLessThanOrEqual(capped.files.count, 3, "maxFiles 必须真正限制分类文件数")
        XCTAssertEqual(capped.scannedFileCount, capped.files.count, "scannedFileCount 必须与实际结果条数一致")
        XCTAssertTrue(capped.truncatedByMaxFiles, "候选数达到 maxFiles 且仍有剩余时必须置 truncatedByMaxFiles")

        let uncapped = await scan(root)
        XCTAssertEqual(uncapped.files.count, 8, "放开上限后必须扫到全部 8 个夹具文件")
        XCTAssertFalse(uncapped.truncatedByMaxFiles, "没有截断时不得置 truncatedByMaxFiles")
    }

    func testScanNeverFollowsSymlinkedDirectories() async throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        try write("let appValue = 1\n", to: "App.swift", in: root)

        // 夹具根之外的目录，里面放一个可被扫到的源文件，作为「有没有顺链接跑出去」的探针。
        let outside = try makeFixtureRoot()
        defer { try? fm.removeItem(at: outside) }
        try write("let outsideMarkerValue = 1\n", to: "Marker.swift", in: outside)
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("escapeOutside").path, withDestinationPath: outside.path)
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("escapeTmp").path, withDestinationPath: "/tmp")
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("Alias.swift").path,
                                  withDestinationPath: outside.appendingPathComponent("Marker.swift").path)

        let result = await scan(root)
        let names = result.files.map(\.relativePath)
        XCTAssertFalse(names.contains { $0.contains("Marker") }, "绝不能顺着符号链接读到夹具外的文件：\(names)")
        XCTAssertEqual(result.files.count, 1, "只有根内真实文件被扫到：\(names)")
        for file in result.files {
            XCTAssertTrue(file.url.path.hasPrefix(root.path),
                          "扫描结果的绝对路径必须落在夹具根 \(root.path) 之内，实际 \(file.url.path)")
        }
        XCTAssertLessThan(result.visitedFileCount, 50,
                          "若真跟随了 /tmp，visitedFileCount 会爆掉；实际 \(result.visitedFileCount)")
    }

    func testScanOfMissingOrNonDirectoryRootYieldsEmptyResult() async throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }

        let absent = await scan(root.appendingPathComponent("no-such-directory"))
        XCTAssertEqual(absent.files.count, 0, "不存在的目录必须返回空结果而不是崩溃")
        XCTAssertEqual(absent.visitedFileCount, 0, "不存在的目录不得产生任何计数")
        XCTAssertFalse(absent.truncatedByMaxFiles, "空结果不该被标记为截断")

        let fileURL = try write("let a = 1\n", to: "App.swift", in: root)
        let fromFile = await scan(fileURL)
        XCTAssertEqual(fromFile.files.count, 0, "把普通文件当根传入必须返回空结果")
    }

    // MARK: - G. 圈复杂度

    func testSwiftComplexityEqualsOnePlusBranchCount() throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        let body = [
            "func scoreFor(value: Int, flag: Bool) -> Int {",
            "    if value > 10 && flag {",
            "        return value + 20",
            "    } else if value > 5 {",
            "        return value",
            "    }",
            "    return 0",
            "}",
        ]
        let url = try write(body.joined(separator: "\n") + "\n", to: "Score.swift", in: root)
        guard let file = classify(url, root: root) else { return XCTFail("Swift 夹具必须分类成功") }

        // 分支：if(1) + &&(1) + else if(1) = 3 → CC = 1 + 3
        XCTAssertEqual(ComplexityEngine.complexity(forLines: body, language: file.language), 4,
                       "Swift 夹具：CC 必须等于 1 + if + && + else if")
        let detected = ComplexityEngine.functions(in: file)
        XCTAssertEqual(detected.count, 1, "必须恰好识别出 1 个函数，实际 \(detected.map(\.name))")
        let candidate = try XCTUnwrap(detected.first)
        XCTAssertEqual(candidate.name, "scoreFor", "函数名必须取签名里的标识符")
        XCTAssertEqual(candidate.complexity, 4, "函数级 CC 必须与整段 CC 一致，实际 \(candidate)")
        XCTAssertEqual(candidate.parameterCount, 2, "两个入参")
        XCTAssertEqual(candidate.startLine, 1, "startLine 必须是签名所在行")
    }

    func testPythonComplexityEqualsOnePlusBranchCount() throws {
        let body = [
            "def classify(value):",
            "    if value > 90:",
            "        return 1",
            "    elif value > 50:",
            "        return 2",
            "    for item in value:",
            "        print(item)",
            "    while value < 3:",
            "        value += 1",
            "    return 0",
        ]
        // 分支：if + elif + for + while = 4 → CC = 5
        XCTAssertEqual(ComplexityEngine.complexity(forLines: body, language: "Python"), 5,
                       "Python 夹具：CC 必须等于 1 + if + elif + for + while")
    }

    func testJavaComplexityEqualsOnePlusBranchCount() throws {
        let body = [
            "public int grade(int mark) {",
            "    switch (mark) {",
            "        case 1:",
            "            return 10;",
            "        case 2:",
            "            return 20;",
            "        default:",
            "            return 0;",
            "    }",
            "    try {",
            "        worker.run();",
            "    } catch (IllegalStateException ex) {",
            "        return -1;",
            "    }",
            "    return mark;",
            "}",
        ]
        // 分支：case + case + catch = 3 → CC = 4；switch / default / try 不算判定分支。
        XCTAssertEqual(ComplexityEngine.complexity(forLines: body, language: "Java"), 4,
                       "Java 夹具：CC 必须等于 1 + 两个 case + 一个 catch")
    }

    func testComplexityIgnoresKeywordsInsideCommentsAndStrings() throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        let body = [
            "func quiet(text: String) -> String {",
            "    // if a && b { for ever } while case catch",
            "    let note = \"if x && y || z\"",
            "    /* if p && q */",
            "    return text",
            "}",
        ]
        let url = try write(body.joined(separator: "\n") + "\n", to: "Quiet.swift", in: root)
        guard let file = classify(url, root: root), let candidate = ComplexityEngine.functions(in: file).first else {
            return XCTFail("Swift 夹具必须分类成功并识别出函数")
        }

        XCTAssertEqual(ComplexityEngine.complexity(forLines: body, language: "Swift"), 1,
                       "注释与字符串字面量里的 if / && / for 一律不得计入复杂度")
        XCTAssertEqual(candidate.complexity, 1, "函数级统计同样不得被注释/字符串污染：\(candidate)")
        XCTAssertEqual(ComplexityEngine.complexity(forLines: ["# if a && b", "x = 1"], language: "Python"), 1,
                       "Python 的 # 注释行不得计入复杂度")
        XCTAssertEqual(ComplexityEngine.complexity(forLines: ["-- if a && b", "select 1"], language: "SQL"), 1,
                       "SQL 的 -- 注释行不得计入复杂度")
    }

    func testComplexityBaselineAndPerBranchIncrement() throws {
        XCTAssertEqual(ComplexityEngine.complexity(forLines: ["let totalValue = baseValue + rate"], language: "Swift"), 1,
                       "直线代码的 CC 必须是 1")
        XCTAssertEqual(ComplexityEngine.complexity(forLines: [], language: "Swift"), 1, "空输入必须退化成 1 而不是 0")
        XCTAssertEqual(ComplexityEngine.complexity(forLines: ["let a = 1"], language: "未发明的语言"), 1,
                       "未知语言不得崩溃，返回基线 1")

        var lines = ["let totalValue = baseValue"]
        var previous = ComplexityEngine.complexity(forLines: lines, language: "Swift")
        for extra in ["if alphaValue { betaValue() }", "while gammaValue { deltaValue() }", "for epsilonValue in zetaValue { etaValue() }"] {
            lines.append(extra)
            let next = ComplexityEngine.complexity(forLines: lines, language: "Swift")
            XCTAssertEqual(next, previous + 1, "追加一行分支「\(extra)」之后 CC 必须正好加 1，实际 \(previous) → \(next)")
            previous = next
        }
        XCTAssertEqual(previous, 4, "三个分支叠加后 CC 必须是 1 + 3")
    }

    // MARK: - H. 函数识别

    func testFunctionIdentificationForMultilineSignatureAndExtension() throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }

        let multi = """
        func multiLineSignature(
            firstValue: Int,
            secondValue: Int
        ) -> Int {
            if firstValue > secondValue {
                return firstValue
            }
            return secondValue
        }
        """
        let multiFile = try XCTUnwrap(classify(try write(multi + "\n", to: "Multi.swift", in: root), root: root))
        let multiFunctions = ComplexityEngine.functions(in: multiFile)
        XCTAssertEqual(multiFunctions.count, 1, "多行签名必须只算一个函数：\(multiFunctions.map(\.name))")
        let multiCandidate = try XCTUnwrap(multiFunctions.first)
        XCTAssertEqual(multiCandidate.name, "multiLineSignature", "函数名必须来自签名行")
        XCTAssertEqual(multiCandidate.startLine, 1, "startLine 必须是签名所在的 1-based 行号")
        XCTAssertEqual(multiCandidate.parameterCount, 2, "跨行签名里的两个参数都要数到：\(multiCandidate)")
        XCTAssertGreaterThanOrEqual(multiCandidate.lineCount, 2, "退化保护：lineCount 至少 2")
        XCTAssertEqual(multiCandidate.complexity, 2, "分支只有一个 if → CC = 2")

        let ext = """
        extension Widget {
            func renderScaled(scale: Double) -> String {
                if scale > 2 && scale < 9 {
                    return "big"
                }
                return "small"
            }
        }
        """
        let widget = try XCTUnwrap(classify(try write(ext + "\n", to: "Widget.swift", in: root), root: root))
        let extFunctions = ComplexityEngine.functions(in: widget)
        XCTAssertEqual(extFunctions.map(\.name), ["renderScaled"], "extension 内的函数必须被识别：\(extFunctions.map(\.name))")
        let extCandidate = try XCTUnwrap(extFunctions.first)
        XCTAssertEqual(extCandidate.startLine, 2, "startLine 必须是 func 所在行而不是 extension 行")
        XCTAssertEqual(extCandidate.lineCount, 6, "函数体必须覆盖到闭合花括号")
        XCTAssertEqual(extCandidate.complexity, 3, "分支：if + && → CC = 3")
    }

    func testFunctionIdentificationAcrossPythonGoAndJavaScriptClosure() throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }

        let python = """
        def grade_one(mark):
            if mark > 90:
                return 1
            for item in mark:
                print(item)
            return 0
        """
        let pyFile = try XCTUnwrap(classify(try write(python + "\n", to: "Grade.py", in: root), root: root))
        let pyFunctions = ComplexityEngine.functions(in: pyFile)
        XCTAssertEqual(pyFunctions.map(\.name), ["grade_one"], "Python def 必须被识别：\(pyFunctions.map(\.name))")
        XCTAssertEqual(pyFunctions.first?.lineCount, 6, "缩进式函数体必须覆盖到最后一个缩进行")
        XCTAssertEqual(pyFunctions.first?.complexity, 3, "分支：if + for → CC = 3")

        let pythonMulti = """
        def summarize_rows(
            rows,
            tax_rate,
            allow_zero
        ):
            total_value = 0
            for row in rows:
                total_value += row
            return total_value
        """
        let pyMultiFile = try XCTUnwrap(classify(try write(pythonMulti + "\n", to: "Summarize.py", in: root), root: root))
        let pyMultiFunctions = ComplexityEngine.functions(in: pyMultiFile)
        XCTAssertEqual(pyMultiFunctions.map(\.name), ["summarize_rows"], "跨行 def 签名也必须被识别：\(pyMultiFunctions.map(\.name))")
        XCTAssertGreaterThanOrEqual(pyMultiFunctions.first?.lineCount ?? 0, 2, "退化保护：lineCount 至少 2")

        let go = "package main\n\nfunc computeTotal(base int, rate int) int {\n"
            + "\tif base > 10 && rate > 2 {\n\t\treturn base + rate\n\t}\n"
            + "\tfor index := 0; index < 3; index++ {\n\t\t_ = index\n\t}\n"
            + "\treturn base\n}\n"
        let goFile = try XCTUnwrap(classify(try write(go, to: "total.go", in: root), root: root))
        let goFunctions = ComplexityEngine.functions(in: goFile)
        XCTAssertEqual(goFunctions.map(\.name), ["computeTotal"], "Go 函数必须被识别：\(goFunctions.map(\.name))")
        XCTAssertEqual(goFunctions.first?.parameterCount, 2, "Go 两个入参")
        XCTAssertEqual(goFunctions.first?.complexity, 4, "分支：if + && + for → CC = 4")

        let jsClosure = """
        const priceOf = (item) => {
            if (item.flag && item.count > 2) {
                return item.count * 2
            }
            return 0
        }
        """
        let jsFile = try XCTUnwrap(classify(try write(jsClosure + "\n", to: "price.js", in: root), root: root))
        let jsFunctions = ComplexityEngine.functions(in: jsFile)
        XCTAssertTrue(jsFunctions.contains { $0.name == "priceOf" },
                      "箭头函数赋给 const 时也必须被识别，实际：\(jsFunctions.map(\.name))")

        // 没有函数概念的语言不得凭空造函数
        for (name, content) in [("data.json", "{\n  \"key\": 1\n}\n"), ("page.css", ".a { color: red }\n")] {
            let scanned = try XCTUnwrap(classify(try write(content, to: name, in: root), root: root))
            XCTAssertTrue(ComplexityEngine.functions(in: scanned).isEmpty, "\(name) 不该识别出任何函数")
        }
    }

    func testFunctionIdentificationDegradesSafelyOnHostileCode() throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        let cases: [(String, String)] = [
            ("Unclosed.swift", "func neverCloses(a: Int) -> Int {\n    if a > 1 {\n        return a\n    }\n"),
            ("StrayBrace.swift", "func odd(a: Int) -> Int {\n}\n}\nfunc after() -> Int {\n    return 1\n}\n"),
            ("Wide.swift", "func wide(a: Int) -> Int {\n" + String(repeating: "    let v = 1\n", count: 300) + "    return a\n}\n"),
            ("Empty.swift", ""),
            ("OnlyBrace.swift", "{{{{\n}}}}\n"),
            ("NoBrace.swift", "func tail(a: Int) -> Int\n"),
            ("Deep.swift", "func deep(a: Int) -> Int {\n    if a > 1 {\n        if a > 2 {\n            return a\n        }\n    }\n    return 0\n}\n"),
            ("Quoted.swift", "func quoted(a: Int) -> Int {\n    let s = \"} { func fake() {\"\n    return a\n}\n"),
        ]
        for (name, content) in cases {
            let file = try XCTUnwrap(classify(try write(content, to: name, in: root), root: root), "\(name) 夹具必须分类成功")
            let functions = ComplexityEngine.functions(in: file)
            for candidate in functions {
                XCTAssertGreaterThanOrEqual(candidate.startLine, 1,
                                            "\(name)：startLine 必须是 1-based 正数，实际 \(candidate.startLine)")
                XCTAssertGreaterThanOrEqual(candidate.lineCount, 2,
                                            "\(name)：过短片段不得作为函数产出，实际 \(candidate.lineCount)")
                XCTAssertGreaterThanOrEqual(candidate.complexity, 1, "\(name)：CC 必须 >= 1")
                XCTAssertGreaterThanOrEqual(candidate.parameterCount, 0, "\(name)：参数个数不得为负")
                XCTAssertFalse(candidate.name.isEmpty, "\(name)：函数名不得为空串")
                XCTAssertLessThanOrEqual(candidate.startLine + candidate.lineCount - 1, file.totalLineCount,
                                         "\(name)：函数区间必须落在文件行数之内")
            }
        }
    }

    func testParameterCountFromSignatures() {
        XCTAssertEqual(ComplexityEngine.parameterCount(from: "func foo(a: Int, b: Int) -> Void"), 2, "两个普通参数")
        XCTAssertEqual(ComplexityEngine.parameterCount(from: "func foo()"), 0, "空参数表必须是 0 而不是 1")
        XCTAssertEqual(ComplexityEngine.parameterCount(from: "func foo(dict: [String: Int], flag: Bool)"), 2,
                       "方括号里的逗号不得被当成参数分隔")
        XCTAssertEqual(ComplexityEngine.parameterCount(from: "func foo(items: Array<Int>, flag: Bool)"), 2,
                       "泛型尖括号里的逗号不得被当成参数分隔")
        XCTAssertEqual(ComplexityEngine.parameterCount(from: "func foo(msg: String)"), 1, "单个参数")
        XCTAssertEqual(ComplexityEngine.parameterCount(from: "没有括号的签名"), 0, "找不到左括号必须返回 0")
        XCTAssertEqual(ComplexityEngine.parameterCount(from: ""), 0, "空串必须返回 0")
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
            XCTAssertEqual(Set(block.occurrences.map(\.path)).count, block.occurrences.count,
                           "同一块里的 occurrence 必须来自不同文件")
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

    /// `\r\n` 在 Swift 里是**一个** `Character`（字素簇），而 `classify` 用
    /// `split { $0 == "\n" }` 切行，于是整份 CRLF 文件切不出任何分隔符、被当成 1 行。
    /// 这条断言用于钉住该真实缺陷，修复前会失败。
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
