import XCTest

// 仓库在并行合并期间由 MonaMonitor 改名为 TcoderMonitor，两个模块名都放行。
#if canImport(MonaMonitor)
@testable import MonaMonitor
#elseif canImport(TcoderMonitor)
@testable import TcoderMonitor
#endif

final class CodeAnalyzerTests: XCTestCase {

    private static let legacyRepositoryPath = "/Users/one/Documents/Tcoder/MonaMonitor"
    private static let fallbackRepositoryPath = "/opt/homebrew/Library/Homebrew"
    private static let largeRepositoryPath = "/Users/one/Documents/nebulaflow"

    private static var packageRootPath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
    }

    private var workspaceRoot: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        let root = Self.canonicalized(base)
        workspaceRoot = root
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - A. 纯函数

    func testLanguageCatalogResolvesExtensionsAndCommentMetadata() {
        XCTAssertEqual(SourceLanguageCatalog.language(forExtension: "swift"), "Swift", "swift 后缀必须映射到 Swift")
        XCTAssertEqual(SourceLanguageCatalog.language(forExtension: "TS"), "TypeScript", "后缀查表必须大小写不敏感")
        XCTAssertEqual(SourceLanguageCatalog.language(forExtension: "tsx"), "TypeScript", "tsx 必须归入 TypeScript")
        XCTAssertEqual(SourceLanguageCatalog.language(forExtension: "py"), "Python", "py 必须归入 Python")
        XCTAssertEqual(SourceLanguageCatalog.language(forExtension: "kt"), "Kotlin", "kt 必须归入 Kotlin")
        XCTAssertEqual(SourceLanguageCatalog.language(forExtension: "rs"), "Rust", "rs 必须归入 Rust")
        XCTAssertEqual(SourceLanguageCatalog.language(forExtension: "vue"), "Vue", "vue 必须归入 Vue")
        XCTAssertNil(SourceLanguageCatalog.language(forExtension: "png"), "二进制后缀不得算作源码语言")
        XCTAssertNil(SourceLanguageCatalog.language(forExtension: ""), "空后缀必须返回 nil")
        XCTAssertNil(SourceLanguageCatalog.language(forExtension: "nope"), "未知后缀必须返回 nil")

        XCTAssertTrue(SourceLanguageCatalog.lineCommentPrefixes(for: "Swift").contains("//"), "Swift 行注释前缀必须包含 //")
        XCTAssertTrue(SourceLanguageCatalog.lineCommentPrefixes(for: "Python").contains("#"), "Python 行注释前缀必须包含 #")
        XCTAssertTrue(SourceLanguageCatalog.lineCommentPrefixes(for: "未知语言").isEmpty, "未知语言不得有任何注释规则")
        if let swiftBlock = SourceLanguageCatalog.blockCommentDelimiters(for: "Swift") {
            XCTAssertEqual(swiftBlock.start, "/*", "Swift 块注释起始定界符必须是 /*")
            XCTAssertEqual(swiftBlock.end, "*/", "Swift 块注释结束定界符必须是 */")
        } else {
            return XCTFail("Swift 必须提供块注释定界符")
        }
        XCTAssertNil(SourceLanguageCatalog.blockCommentDelimiters(for: "Python"), "Python 没有块注释，不得返回定界符")
        XCTAssertTrue(SourceLanguageCatalog.docStringDelimiters(for: "Python").contains("\"\"\""), "Python 文档字符串定界符必须包含三引号")
        XCTAssertTrue(SourceLanguageCatalog.docStringDelimiters(for: "Swift").isEmpty, "Swift 没有文档字符串定界符")
    }

    func testNormalizeFoldsIndentationLiteralsAndDropsNoiseLines() {
        XCTAssertEqual(DuplicationEngine.windowSize, 6, "滑窗大小冻结为 6")

        let tabbed = DuplicationEngine.normalize("\t\treturn total + amount", language: "Swift")
        let spaced = DuplicationEngine.normalize("        return total + amount", language: "Swift")
        XCTAssertNotNil(tabbed, "正常代码行不得归一化为 nil")
        XCTAssertNotNil(spaced, "正常代码行不得归一化为 nil")
        XCTAssertEqual(tabbed, spaced, "同一行仅缩进不同，归一化结果必须完全相等")

        let firstLiteral = DuplicationEngine.normalize("let a = \"hello world\"", language: "Swift")
        let secondLiteral = DuplicationEngine.normalize("let b = \"zzz\"", language: "Swift")
        XCTAssertNotNil(firstLiteral, "含字符串字面量的代码行不得归一化为 nil")
        XCTAssertEqual(firstLiteral, secondLiteral, "字符串字面量必须整体替换为占位符")

        let firstNumber = DuplicationEngine.normalize("int x = 12;", language: "C")
        let secondNumber = DuplicationEngine.normalize("int y = 7;", language: "C")
        XCTAssertNotNil(firstNumber, "含数字字面量的代码行不得归一化为 nil")
        XCTAssertEqual(firstNumber, secondNumber, "数字字面量必须替换为占位符，标识符差异不得影响指纹")

        XCTAssertNil(DuplicationEngine.normalize("", language: "Swift"), "空行必须返回 nil")
        XCTAssertNil(DuplicationEngine.normalize("    ", language: "Swift"), "纯空白行必须返回 nil")
        XCTAssertNil(DuplicationEngine.normalize("}", language: "Swift"), "纯右花括号行必须返回 nil")
        XCTAssertNil(DuplicationEngine.normalize("        }", language: "Swift"), "缩进的纯右花括号行必须返回 nil")
        XCTAssertNil(DuplicationEngine.normalize("// 这只是说明文字", language: "Swift"), "行注释必须返回 nil")
        XCTAssertNil(DuplicationEngine.normalize("# 这只是说明文字", language: "Python"), "行注释必须返回 nil")
    }

    func testComplexityGrowsWithBranchesAndIgnoresCommentsAndStrings() {
        XCTAssertEqual(ComplexityEngine.complexity(forLines: ["let total = base + rate"], language: "Swift"), 1,
                       "直线代码的圈复杂度必须是 1")

        var lines = ["let total = base + rate"]
        var score = ComplexityEngine.complexity(forLines: lines, language: "Swift")

        lines.append("if alpha { beta() }")
        var next = ComplexityEngine.complexity(forLines: lines, language: "Swift")
        XCTAssertGreaterThanOrEqual(next, 2, "单个 if 之后复杂度至少为 2")
        XCTAssertGreaterThan(next, score, "增加 if 之后复杂度必须严格上升")
        score = next

        lines.append("for index in 0..<10 { step(index) }")
        next = ComplexityEngine.complexity(forLines: lines, language: "Swift")
        XCTAssertGreaterThanOrEqual(next, 3, "if + for 之后复杂度至少为 3")
        XCTAssertGreaterThan(next, score, "增加 for 之后复杂度必须严格上升")
        score = next

        lines.append("while cursor < limit { cursor += 1 }")
        next = ComplexityEngine.complexity(forLines: lines, language: "Swift")
        XCTAssertGreaterThanOrEqual(next, 4, "if + for + while 之后复杂度至少为 4")
        XCTAssertGreaterThan(next, score, "增加 while 之后复杂度必须严格上升")
        score = next

        lines.append("if alpha && beta { gamma() }")
        next = ComplexityEngine.complexity(forLines: lines, language: "Swift")
        XCTAssertGreaterThanOrEqual(next, 5, "短路 && 必须额外计一次判定")
        XCTAssertGreaterThan(next, score, "增加 && 之后复杂度必须严格上升")
        score = next

        lines.append("if theta || iota { kappa() }")
        next = ComplexityEngine.complexity(forLines: lines, language: "Swift")
        XCTAssertGreaterThanOrEqual(next, 6, "短路 || 必须额外计一次判定")
        XCTAssertGreaterThan(next, score, "增加 || 之后复杂度必须严格上升")

        XCTAssertEqual(ComplexityEngine.complexity(forLines: ["// if if if"], language: "Swift"), 1,
                       "注释里的 if 一律不得计入复杂度")
        XCTAssertEqual(ComplexityEngine.complexity(forLines: ["// if alpha && beta || gamma", "// for x in y"], language: "Swift"), 1,
                       "注释里的所有判定关键字与短路符号都不得计入复杂度")
        XCTAssertEqual(ComplexityEngine.complexity(forLines: ["let message = \"if if if\""], language: "Swift"), 1,
                       "字符串字面量里的 if 不得计入复杂度")
    }

    func testParameterCountParsesSignaturesWithoutMiscountingNestedCommas() {
        XCTAssertEqual(ComplexityEngine.parameterCount(from: "func a()"), 0, "无参签名必须为 0")
        XCTAssertEqual(ComplexityEngine.parameterCount(from: "func a(_ x: Int)"), 1, "单个匿名参数必须为 1")
        XCTAssertEqual(ComplexityEngine.parameterCount(from: "func a(x: Int, y: Int)"), 2, "两个参数必须为 2")
        XCTAssertEqual(ComplexityEngine.parameterCount(from: "func a(d: [String: Int], n: Int)"), 2,
                       "泛型/字典类型里的逗号不得被误算成参数分隔符")
        XCTAssertEqual(ComplexityEngine.parameterCount(from: "func a(b: (Int, String) -> Void)"), 1,
                       "闭包类型内部的逗号不得被误算成参数分隔符")
        XCTAssertEqual(ComplexityEngine.parameterCount(from: "func a(n: Int, handler: @escaping (Int) -> Void = { $0 })"), 2,
                       "带默认闭包实参的签名不得被误算")
    }

    func testFunctionsExtractedFromClassifiedFileLookSane() throws {
        let directory = try makeFixtureDirectory("complexity")
        let url = try writeFixture(Self.pricingSampleSource,
                                  to: directory.appendingPathComponent("PricingSample.swift"))
        guard let file = SourceFileClassifier(options: .default).classify(url: url, root: directory) else {
            return XCTFail("已知后缀的普通源码文件必须能被分类")
        }
        let functions = ComplexityEngine.functions(in: file)
        XCTAssertFalse(functions.isEmpty, "含多个 func 的示例文件必须抽出候选函数")
        for candidate in functions {
            XCTAssertFalse(candidate.name.isEmpty, "候选函数名不得为空")
            XCTAssertGreaterThanOrEqual(candidate.startLine, 1, "起始行号必须是 1 基的行号")
            XCTAssertLessThanOrEqual(candidate.startLine, file.totalLineCount, "起始行号不得越界")
            XCTAssertGreaterThanOrEqual(candidate.lineCount, 1, "函数行数至少为 1")
            XCTAssertGreaterThanOrEqual(candidate.complexity, 1, "任何函数复杂度至少为 1")
            XCTAssertGreaterThanOrEqual(candidate.parameterCount, 0, "参数个数不得为负")
        }
        XCTAssertNotNil(functions.first { $0.name.contains("summarize") }, "示例里的 summarize 函数必须被识别")
        XCTAssertNotNil(functions.first { $0.complexity >= 4 }, "多层分支示例函数的复杂度必须明显高于 1")
    }

    // MARK: - B. 行分类不变式

    func testClassifiedFixtureSatisfiesLineKindInvariants() throws {
        let directory = try makeFixtureDirectory("classifier")
        let url = try writeFixture(Self.classifierFixtureSource, to: directory.appendingPathComponent("Fixture.swift"))
        guard let file = SourceFileClassifier(options: .default).classify(url: url, root: directory) else {
            return XCTFail("fixture 必须被成功分类")
        }

        XCTAssertEqual(file.language, "Swift", ".swift 文件语言必须是 Swift")
        XCTAssertEqual(file.relativePath, "Fixture.swift", "relativePath 必须以 root 为基准")
        XCTAssertEqual(file.url, url, "classify 返回的 url 必须就是传入的文件")
        XCTAssertEqual(file.totalLineCount, file.lines.count, "totalLineCount 必须等于 lines 数量")

        let counted = lineKindCounts(of: file)
        XCTAssertEqual(file.totalLineCount, counted.blank + counted.comment + counted.code,
                       "逐文件不变式：总行数 = 空行 + 注释行 + 代码行")
        XCTAssertEqual(file.blankLineCount, counted.blank, "blankLineCount 必须与逐行 kind 统计一致")
        XCTAssertEqual(file.commentLineCount, counted.comment, "commentLineCount 必须与逐行 kind 统计一致")
        XCTAssertEqual(file.codeLineCount, counted.code, "codeLineCount 必须与逐行 kind 统计一致")
        XCTAssertEqual(file.totalLineCount, 13, "fixture 行数是确定的，分类器不得吞行或造行")
        XCTAssertEqual(file.blankLineCount, 3, "fixture 里写了 3 个空行")
        XCTAssertEqual(file.commentLineCount, 5, "fixture 里写了 5 行注释（块注释 + Javadoc 星号行 + 行注释）")
        XCTAssertEqual(file.codeLineCount, 5, "fixture 里写了 5 行代码（含行尾注释行与块注释夹代码行）")

        for (offset, line) in file.lines.enumerated() {
            XCTAssertEqual(line.number, offset + 1, "行号必须从 1 开始连续递增")
        }
        XCTAssertEqual(file.lines.first?.kind, .comment, "首行是块注释，必须判为 comment")
        XCTAssertEqual(file.lines.first?.text, "/* 块注释第一行", "行文本必须原样保留")
        XCTAssertEqual(kindOfLine(in: file, containing: "tail"), .code, "行尾注释所在的行必须判为 code")
        XCTAssertEqual(kindOfLine(in: file, containing: "y = 2"), .code, "块注释夹在中间的行必须判为 code")
        XCTAssertEqual(kindOfLine(in: file, containing: "x += 1"), .code, "块注释后仍有代码的行必须判为 code")
        XCTAssertEqual(kindOfLine(in: file, containing: "说明"), .comment, "Javadoc 风格的 * 行必须判为 comment")

        XCTAssertGreaterThanOrEqual(file.todoCount, 2, "fixture 写了 2 个 TODO，计数不得少")
        XCTAssertEqual(file.fixmeCount, 2, "FIXME 计数必须与 fixture 中写的数量一致")
    }

    func testClassifyHandlesEmptyUnknownAndOversizedFiles() throws {
        let directory = try makeFixtureDirectory("classifier-edge")
        let classifier = SourceFileClassifier(options: .default)

        let emptyURL = try writeFixture("", to: directory.appendingPathComponent("Empty.swift"))
        guard let empty = classifier.classify(url: emptyURL, root: directory) else {
            return XCTFail("空源码文件仍应返回零计数结果而不是 nil")
        }
        XCTAssertEqual(empty.totalLineCount, 0, "空文件行数为 0")
        XCTAssertTrue(empty.lines.isEmpty, "空文件不得产生任何行记录")
        XCTAssertEqual(empty.blankLineCount, 0, "空文件不得计入空行")
        XCTAssertEqual(empty.commentLineCount, 0, "空文件不得计入注释行")
        XCTAssertEqual(empty.codeLineCount, 0, "空文件不得计入代码行")
        XCTAssertEqual(empty.todoCount, 0, "空文件 TODO 计数必须为 0")
        XCTAssertEqual(empty.fixmeCount, 0, "空文件 FIXME 计数必须为 0")
        XCTAssertEqual(empty.totalLineCount, empty.blankLineCount + empty.commentLineCount + empty.codeLineCount,
                       "空文件也必须满足行分类不变式")

        let unknownURL = try writeFixture("whatever()", to: directory.appendingPathComponent("mystery.zzz"))
        XCTAssertNil(classifier.classify(url: unknownURL, root: directory), "未知后缀必须返回 nil")

        let largeURL = try writeFixture(String(repeating: "let value = 1\n", count: 400),
                                       to: directory.appendingPathComponent("Large.swift"))
        let size = try FileManager.default.attributesOfItem(atPath: largeURL.path)[.size] as? Int
        XCTAssertNotNil(size, "应能读到 fixture 的字节数")
        var tiny = ScanOptions.default
        tiny.maxFileBytes = 64
        XCTAssertLessThan(64, size ?? 128, "前置条件：maxFileBytes 必须真的小于文件体积")
        XCTAssertNil(SourceFileClassifier(options: tiny).classify(url: largeURL, root: directory),
                     "超过 maxFileBytes 的文件必须直接跳过而不是被读取")
    }

    // MARK: - C. 遍历安全

    func testTreeScanSkipsIgnoredDirectoriesAndNeverFollowsSymlinks() async throws {
        let parent = try makeFixtureDirectory("traversal")
        let outside = try makeSubdirectory(under: parent, named: "outside")
        try writeFixture("function leakedIntoScan() { return 1 }", to: outside.appendingPathComponent("leaked.js"))

        let pkg = try makeSubdirectory(under: parent, named: "pkg")
        let keptURL = try writeFixture("func keptFunction() -> Int { return 1 }",
                                       to: pkg.appendingPathComponent("Sources/a.swift"))
        try writeFixture("function vendored() {}", to: pkg.appendingPathComponent("node_modules/x.js"))
        try writeFixture("function insideGitRepo() {}", to: pkg.appendingPathComponent(".git/y.js"))
        try writeFixture("binary looking payload", to: pkg.appendingPathComponent("big.png"))
        try writeFixture("also binary looking payload", to: pkg.appendingPathComponent("archive.bin"))
        try FileManager.default.createSymbolicLink(at: pkg.appendingPathComponent("escape"),
                                                  withDestinationURL: outside)

        XCTAssertTrue(ScanOptions.default.binaryExtensions.contains("png"), "前置条件：png 默认在二进制后缀名单里")
        XCTAssertTrue(ScanOptions.default.skipDirectories.contains(".git"), "前置条件：.git 默认在跳过目录名单里")

        let scan = await SourceTreeScanner(options: .default).scan(root: pkg)
        let paths = scan.files.map(\.url.path)
        XCTAssertTrue(paths.contains(keptURL.path), "遍历必须真的找到 pkg/Sources/a.swift，否则负向断言毫无意义")
        for path in paths {
            XCTAssertTrue(path.hasPrefix(pkg.path + "/"), "返回的文件路径必须位于 root 之内，实际：\(path)")
        }
        XCTAssertFalse(paths.contains(where: { $0.contains("node_modules") }), "node_modules 下的文件不得进入结果")
        XCTAssertFalse(paths.contains(where: { $0.contains("/.git/") }), ".git 下的文件不得进入结果")
        XCTAssertFalse(paths.contains(where: { $0.hasSuffix(".png") }), "binaryExtensions 中的后缀不得进入结果")
        XCTAssertFalse(paths.contains(where: { $0.hasSuffix(".bin") }), "未知后缀不得进入结果")
        XCTAssertFalse(paths.contains(where: { $0.contains("/outside/") }), "符号链接目录一律不得被跟随")
        XCTAssertEqual(scan.files.count, 1, "该目录下只有 1 个合法源码文件")
        XCTAssertGreaterThanOrEqual(scan.visitedFileCount, 1, "visitedFileCount 至少统计到候选文件")
        XCTAssertGreaterThanOrEqual(scan.skippedFileCount, 1, "被过滤的文件必须计入 skippedFileCount")
        XCTAssertFalse(scan.truncatedByMaxFiles, "默认 maxFiles 下不应触发截断")

        var withHidden = ScanOptions.default
        withHidden.includeHidden = true
        let hiddenScan = await SourceTreeScanner(options: withHidden).scan(root: pkg)
        let hiddenPaths = hiddenScan.files.map(\.url.path)
        XCTAssertTrue(hiddenPaths.contains(keptURL.path), "includeHidden 打开后正常文件仍要被扫到")
        XCTAssertFalse(hiddenPaths.contains(where: { $0.contains("/.git/") }),
                       "includeHidden 打开后 .git 仍必须被 skipDirectories 拦住")
        XCTAssertFalse(hiddenPaths.contains(where: { $0.contains("node_modules") }), "includeHidden 不影响 skipDirectories 生效")
        XCTAssertFalse(hiddenPaths.contains(where: { $0.contains("/outside/") }), "includeHidden 打开后符号链接仍不得被跟随")
        for path in hiddenPaths {
            XCTAssertTrue(path.hasPrefix(pkg.path + "/"), "返回的文件路径必须位于 root 之内，实际：\(path)")
        }
        XCTAssertEqual(hiddenScan.files.count, 1, "includeHidden 打开后合法源码文件依然只有 1 个")
    }

    // MARK: - D. 端到端真实目录

    func testAnalyzeRealRepositoryProducesRealNumbers() async throws {
        let root = try Self.realRepositoryRoot()
        let metrics = try await FileSystemCodeAnalyzer().analyze(root: root, options: .default)

        print("WS-A 真实扫描 目录=\(root.path)")
        print("WS-A 真实扫描 文件数=\(metrics.totalFiles) 总行数=\(metrics.totalLines) 空行=\(metrics.blankLines) "
              + "注释行=\(metrics.commentLines) 代码行=\(metrics.codeLines) TODO=\(metrics.todoCount) FIXME=\(metrics.fixmeCount)")
        print("WS-A 真实扫描 主语言=\(metrics.primaryLanguage) 语言数=\(metrics.languages.count) "
              + "最大文件行数=\(metrics.largestFileLineCount) 巨大文件数=\(metrics.hugeFiles.count)")
        print("WS-A 真实扫描 函数热点数=\(metrics.topComplexFunctions.count) 长函数数=\(metrics.longFunctions) "
              + "平均函数长度=\(metrics.averageFunctionLength)")
        print("WS-A 真实扫描 重复率=\(metrics.duplicationRatio) 重复块数=\(metrics.duplicatedBlocks.count) "
              + "整体风险=\(metrics.overallRisk.rawValue) 耗时ms=\(metrics.durationMs)")

        XCTAssertGreaterThan(metrics.totalFiles, 0, "真实代码目录必须扫出文件")
        XCTAssertGreaterThan(metrics.codeLines, 0, "真实代码目录的代码行数必须大于 0")
        XCTAssertGreaterThan(metrics.totalLines, 0, "真实代码目录的总行数必须大于 0")
        XCTAssertEqual(metrics.totalLines, metrics.blankLines + metrics.commentLines + metrics.codeLines,
                       "全库不变式：总行数 = 空行 + 注释行 + 代码行")
        XCTAssertGreaterThan(metrics.largestFileLineCount, 0, "最大文件行数必须被真实测量")

        XCTAssertFalse(metrics.languages.isEmpty, "真实目录必须给出语言分布")
        let shares = metrics.languages.map(\.share)
        XCTAssertEqual(shares, shares.sorted(by: >), "语言占比必须按 share 降序排列")
        for share in shares {
            XCTAssertTrue(share >= 0 && share <= 1, "语言占比必须落在 0...1 区间，实际：\(share)")
        }
        XCTAssertEqual(shares.reduce(0, +), 1.0, accuracy: 0.02, "语言占比之和必须接近 1")
        XCTAssertEqual(metrics.primaryLanguage, metrics.languages.first?.language, "primaryLanguage 必须是占比最高的语言")
        for entry in metrics.languages {
            XCTAssertGreaterThan(entry.fileCount, 0, "语言分布里的文件数必须为正")
            XCTAssertGreaterThanOrEqual(entry.lineCount, 0, "语言分布里的行数不得为负")
        }
        XCTAssertTrue(0...1 ~= metrics.commentRatio, "注释占比必须落在 0...1 区间")

        XCTAssertTrue(0...1 ~= metrics.duplicationRatio, "重复率必须落在 0...1 区间")

        XCTAssertFalse(metrics.topComplexFunctions.isEmpty, "真实仓库不可能一个函数都识别不出来")
        XCTAssertLessThanOrEqual(metrics.topComplexFunctions.count, 20, "复杂函数榜单最多 20 条")
        for (index, hotspot) in metrics.topComplexFunctions.enumerated() {
            XCTAssertFalse(hotspot.name.isEmpty, "函数热点必须有名字")
            XCTAssertTrue(hotspot.filePath.hasPrefix("/"), "函数热点路径必须是绝对路径：\(hotspot.filePath)")
            XCTAssertGreaterThanOrEqual(hotspot.startLine, 1, "函数热点起始行必须 >= 1")
            XCTAssertGreaterThanOrEqual(hotspot.lineCount, 1, "函数热点行数必须 >= 1")
            XCTAssertGreaterThanOrEqual(hotspot.cyclomaticComplexity, 1, "圈复杂度必须 >= 1")
            XCTAssertNotEqual(hotspot.risk, RiskLevel.none, "上榜函数热点不得是无风险")
            if index > 0 {
                XCTAssertLessThanOrEqual(hotspot.cyclomaticComplexity,
                                         metrics.topComplexFunctions[index - 1].cyclomaticComplexity,
                                         "复杂函数榜单必须按圈复杂度降序")
            }
        }

        XCTAssertLessThanOrEqual(metrics.hugeFiles.count, 20, "巨大文件榜单最多 20 条")
        for index in 1..<metrics.hugeFiles.count {
            XCTAssertLessThanOrEqual(metrics.hugeFiles[index].lineCount, metrics.hugeFiles[index - 1].lineCount,
                                     "巨大文件榜单必须按行数降序")
        }
        for hotspot in metrics.hugeFiles {
            XCTAssertTrue(hotspot.path.hasPrefix("/"), "巨大文件路径必须是绝对路径：\(hotspot.path)")
            XCTAssertFalse(hotspot.suggestion.isEmpty, "巨大文件必须给出拆分建议")
        }
        XCTAssertGreaterThanOrEqual(metrics.largestFileLineCount, metrics.hugeFiles.first?.lineCount ?? 0,
                                    "largestFileLineCount 不得小于榜单首位")

        XCTAssertGreaterThan(metrics.durationMs, 0, "耗时必须是真实测量的正值")
        XCTAssertTrue(RiskLevel.allCases.contains(metrics.overallRisk), "整体风险必须是合法枚举值")
    }

    func testAnalyzeEmptyDirectoryReturnsZerosWithoutCrash() async throws {
        let directory = try makeFixtureDirectory("empty-project")
        let metrics = try await FileSystemCodeAnalyzer().analyze(root: directory, options: .default)

        XCTAssertEqual(metrics.totalFiles, 0, "空目录不得扫出文件")
        XCTAssertEqual(metrics.totalLines, 0, "空目录总行数必须为 0")
        XCTAssertEqual(metrics.blankLines, 0, "空目录空行数必须为 0")
        XCTAssertEqual(metrics.commentLines, 0, "空目录注释行数必须为 0")
        XCTAssertEqual(metrics.codeLines, 0, "空目录代码行数必须为 0")
        XCTAssertEqual(metrics.todoCount, 0, "空目录 TODO 计数必须为 0")
        XCTAssertEqual(metrics.fixmeCount, 0, "空目录 FIXME 计数必须为 0")
        XCTAssertTrue(metrics.languages.isEmpty, "空目录不得给出语言分布")
        XCTAssertTrue(metrics.hugeFiles.isEmpty, "空目录不得有巨大文件榜单")
        XCTAssertTrue(metrics.topComplexFunctions.isEmpty, "空目录不得有函数热点")
        XCTAssertEqual(metrics.longFunctions, 0, "空目录长函数数必须为 0")
        XCTAssertEqual(metrics.averageFunctionLength, 0, "空目录平均函数长度必须为 0")
        XCTAssertEqual(metrics.largestFileLineCount, 0, "空目录最大文件行数必须为 0")
        XCTAssertEqual(metrics.duplicationRatio, 0, "空目录重复率必须为 0")
        XCTAssertTrue(metrics.duplicatedBlocks.isEmpty, "空目录不得有重复块")
        XCTAssertEqual(metrics.overallRisk, RiskLevel.none, "空目录整体风险必须是 none")
        XCTAssertEqual(metrics.totalLines, metrics.blankLines + metrics.commentLines + metrics.codeLines,
                       "空目录同样要满足行分类不变式")
    }

    func testAnalyzeNonDirectoryRootThrowsNotDirectory() async throws {
        let directory = try makeFixtureDirectory("not-a-directory")
        let fileURL = try writeFixture("只是一段文本", to: directory.appendingPathComponent("plain.txt"))
        let missingURL = directory.appendingPathComponent("nope/never-existed")
        let analyzer = FileSystemCodeAnalyzer()

        do {
            _ = try await analyzer.analyze(root: fileURL, options: .default)
            XCTFail("对普通文件执行分析必须抛出 AnalysisError.notDirectory")
        } catch let error as AnalysisError {
            XCTAssertEqual(error, AnalysisError.notDirectory(fileURL.path), "错误类型与携带的路径都必须精确匹配")
        }

        do {
            _ = try await analyzer.analyze(root: missingURL, options: .default)
            XCTFail("对不存在的路径执行分析必须抛出 AnalysisError.notDirectory")
        } catch let error as AnalysisError {
            XCTAssertEqual(error, AnalysisError.notDirectory(missingURL.path), "错误类型与携带的路径都必须精确匹配")
        }
    }

    func testDuplicateBlocksAreDetectedAcrossFiles() async throws {
        let directory = try makeFixtureDirectory("duplication")
        let urlA = try writeFixture(Self.duplicatedFileA, to: directory.appendingPathComponent("src/WarehouseLedger.swift"))
        let urlB = try writeFixture(Self.duplicatedFileB, to: directory.appendingPathComponent("src/StoreReportBuilder.swift"))
        let urlC = try writeFixture(Self.duplicatedFileC, to: directory.appendingPathComponent("src/ReplenishmentPlanner.swift"))
        let urls = [urlA, urlB, urlC]

        let engineFiles = urls.compactMap {
            SourceFileClassifier(options: .default).classify(url: $0, root: directory)
        }
        XCTAssertEqual(engineFiles.count, urls.count, "三个 fixture 文件都必须能被分类")
        let engineResult = DuplicationEngine.analyze(engineFiles)
        print("WS-A 重复样例 引擎重复率=\(engineResult.ratio) 重复行=\(engineResult.duplicatedCodeLines) "
              + "总代码行=\(engineResult.totalCodeLines) 块数=\(engineResult.blocks.count)")
        let totalCodeLines = engineFiles.reduce(0) { $0 + $1.codeLineCount }
        XCTAssertEqual(engineResult.totalCodeLines, totalCodeLines, "引擎统计的总代码行必须与分类器一致")
        XCTAssertLessThanOrEqual(engineResult.duplicatedCodeLines, engineResult.totalCodeLines,
                                 "重复行数不得超过总代码行数")
        XCTAssertEqual(engineResult.ratio,
                       engineResult.totalCodeLines == 0 ? 0 : Double(engineResult.duplicatedCodeLines) / Double(engineResult.totalCodeLines),
                       accuracy: 0.01, "重复率必须等于重复行 / 总代码行")
        XCTAssertGreaterThan(engineResult.ratio, 0, "逐字复制的长代码块必须被引擎判为重复")
        XCTAssertFalse(engineResult.blocks.isEmpty, "逐字复制的长代码块必须产出重复块明细")
        for block in engineResult.blocks {
            XCTAssertGreaterThanOrEqual(block.lineCount, DuplicationEngine.windowSize, "重复块行数不得小于滑窗大小")
            XCTAssertGreaterThanOrEqual(block.occurrences.count, 2, "重复块至少要出现两处")
            XCTAssertGreaterThanOrEqual(Set(block.occurrences.map(\.path)).count, 2, "重复块必须跨文件命中")
        }

        let metrics = try await FileSystemCodeAnalyzer().analyze(root: directory, options: .default)
        print("WS-A 重复样例 端到端重复率=\(metrics.duplicationRatio) 块数=\(metrics.duplicatedBlocks.count) "
              + "文件数=\(metrics.totalFiles)")
        XCTAssertEqual(metrics.totalFiles, urls.count, "端到端扫描到的文件数必须与 fixture 一致")
        XCTAssertGreaterThan(metrics.duplicationRatio, 0, "端到端重复率必须大于 0")
        XCTAssertFalse(metrics.duplicatedBlocks.isEmpty, "端到端必须暴露重复块明细")
        XCTAssertEqual(metrics.duplicatedBlocks.count, engineResult.blocks.count, "端到端与引擎直调的重复块数必须一致")
        for block in metrics.duplicatedBlocks {
            XCTAssertGreaterThanOrEqual(block.lineCount, DuplicationEngine.windowSize, "重复块行数不得小于滑窗大小")
            XCTAssertGreaterThanOrEqual(block.occurrences.count, 2, "重复块至少要出现两处")
            XCTAssertTrue(block.similarity >= 0 && block.similarity <= 1, "相似度必须落在 0...1，实际：\(block.similarity)")
            for occurrence in block.occurrences {
                XCTAssertTrue(occurrence.path.hasPrefix(directory.path), "重复块路径必须是绝对路径：\(occurrence.path)")
                XCTAssertGreaterThanOrEqual(occurrence.startLine, 1, "重复出现位置必须给出 1 基行号")
            }
        }
        let coveredPaths = Set(metrics.duplicatedBlocks.flatMap { $0.occurrences.map(\.path) })
        XCTAssertGreaterThanOrEqual(coveredPaths.count, 2, "重复命中必须覆盖至少两个不同文件")
        let widest = metrics.duplicatedBlocks.max { $0.occurrences.count < $1.occurrences.count }
        XCTAssertGreaterThanOrEqual(Set(widest?.occurrences.map(\.path) ?? []).count, 2,
                                    "最宽的那个重复块本身就应当跨文件出现")
    }

    func testUnrelatedFilesReportAlmostNoDuplication() async throws {
        let directory = try makeFixtureDirectory("no-duplication")
        try writeFixture(Self.uniqueFileOne, to: directory.appendingPathComponent("src/PriceBandBuilder.swift"))
        try writeFixture(Self.uniqueFileTwo, to: directory.appendingPathComponent("src/ShipmentTracer.swift"))
        let metrics = try await FileSystemCodeAnalyzer().analyze(root: directory, options: .default)
        print("WS-A 无重复样例 重复率=\(metrics.duplicationRatio) 块数=\(metrics.duplicatedBlocks.count) "
              + "代码行=\(metrics.codeLines)")
        XCTAssertEqual(metrics.totalFiles, 2, "两个 fixture 都必须被扫到")
        XCTAssertGreaterThan(metrics.codeLines, 20, "前置条件：两个不相关 fixture 必须真的贡献代码行数")
        XCTAssertLessThan(metrics.duplicationRatio, 0.02, "内容互不相关的文件不得被判为重复")
        XCTAssertEqual(metrics.totalLines, metrics.blankLines + metrics.commentLines + metrics.codeLines,
                       "行分类不变式在小 fixture 上同样成立")
    }

    // MARK: - E. 性能护栏

    func testPerformanceOnLargeRealDirectory() async throws {
        let path = Self.largeRepositoryPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw XCTSkip("没有大型真实仓库可测")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let startedAt = Date()
        let metrics = try await FileSystemCodeAnalyzer().analyze(root: root, options: .default)
        let wallMs = Int(Date().timeIntervalSince(startedAt) * 1000)

        print("WS-A 大仓性能 目录=\(root.path) 耗时ms=\(metrics.durationMs) 墙钟ms=\(wallMs) "
              + "文件数=\(metrics.totalFiles) 总行数=\(metrics.totalLines) 代码行=\(metrics.codeLines) "
              + "重复率=\(metrics.duplicationRatio)")

        XCTAssertGreaterThan(metrics.totalFiles, 0, "大型仓库必须扫出文件，否则这条护栏没有意义")
        XCTAssertLessThan(metrics.durationMs, 30_000, "用户口径：18 万行必须在 30 秒内完成")
        XCTAssertLessThan(wallMs, 30_000, "墙钟耗时同样必须低于 30 秒（含调度开销）")
        XCTAssertEqual(metrics.totalLines, metrics.blankLines + metrics.commentLines + metrics.codeLines,
                       "大仓同样必须满足行分类不变式")
        XCTAssertTrue(0...1 ~= metrics.duplicationRatio, "重复率必须落在 0...1 区间")
    }

    // MARK: - Helpers

    private static func realRepositoryRoot() throws -> URL {
        let candidates = [packageRootPath, legacyRepositoryPath, fallbackRepositoryPath]
        for path in candidates {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        throw XCTSkip("本机没有可用真实代码目录")
    }

    private static func canonicalized(_ url: URL) -> URL {
        let values = try? url.resourceValues(forKeys: [.canonicalItemPathKey])
        guard let path = values?.canonicalItemPath, path.isEmpty == false else { return url }
        return URL(fileURLWithPath: path)
    }

    @discardableResult
    private func makeFixtureDirectory(_ name: String) throws -> URL {
        try makeSubdirectory(under: workspaceRoot, named: name)
    }

    @discardableResult
    private func makeSubdirectory(under parent: URL, named name: String) throws -> URL {
        let base = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return Self.canonicalized(base)
    }

    @discardableResult
    private func writeFixture(_ contents: String, to url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: false, encoding: .utf8)
        return url
    }

    private func lineKindCounts(of file: ScannedSourceFile) -> (blank: Int, comment: Int, code: Int) {
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

    private func kindOfLine(in file: ScannedSourceFile, containing fragment: String) -> SourceLineKind? {
        file.lines.first(where: { $0.text.contains(fragment) })?.kind
    }

    // MARK: - Fixtures

    private static let classifierFixtureSource = """
    /* 块注释第一行
    *  说明 tail 无关词
    */
    // TODO: 接入真实鉴权

    let value = 1
    int x_tail = 1; // tail
    /** 内联块注释 */ x += 1
    y = 2 /* 中段 */ + 3
    // FIXME: 这里有并发竞态
    // FIXME: 第二个待办
    """

    private static let pricingSampleSource = """
    import Foundation

    enum PricingError: Error {
        case negativeQuantity
    }

    func summarize(_ rows: [PriceRow], taxRate: Double, allowZero: Bool) -> Double {
        var total = 0.0
        for row in rows {
            if row.quantity < 0 && allowZero == false {
                continue
            }
            while row.quantity > 0 {
                total += row.unitPrice
                row.consume()
            }
            if row.region == "eu" || row.region == "uk" {
                total *= 1 + taxRate
            }
        }
        return total
    }

    func format(_ amount: Double) -> String {
        amount.formatted(.currency(code: "USD"))
    }
    """

    private static let sharedInventorySnippet = """
    func summarizeInventory(_ rows: [InventoryRow]) -> InventoryTotals {
        var totalUnits = 0
        var outOfStock = 0
        var revenueByCategory: [String: Double] = [:]
        var largestSale = 0.0
        var processedBatches = 0
        let openedAt = Date(timeIntervalSince1970: 1_700_000_000)
        for row in rows {
            // 缺货品单独计数，避免污染均价统计
            if row.quantity <= 0 {
                outOfStock += 1
                continue
            }
            totalUnits += row.quantity
            processedBatches += 1
            let category = row.category.lowercased()
            let revenue = row.unitPrice * Double(row.quantity)
            largestSale = max(largestSale, revenue)
            revenueByCategory[category, default: 0] += revenue
        }

        let average = Double(totalUnits) / Double(max(rows.count, 1))
        // 汇总结果直接交给报表层，这里不做展示格式化
        return InventoryTotals(units: totalUnits, outOfStock: outOfStock, average: average,
                               largestSale: largestSale, processedBatches: processedBatches,
                               openedAt: openedAt, revenueByCategory: revenueByCategory)
    }
    """

    private static let duplicatedFileA = """
    import Foundation

    struct WarehouseLedger {
        private var rows: [InventoryRow] = []

        mutating func record(_ row: InventoryRow) {
            rows.append(row)
        }

    \(sharedInventorySnippet)
    }
    """

    private static let duplicatedFileB = """
    import Foundation

    final class StoreReportBuilder {
        private let sourceRows: [InventoryRow]

        init(sourceRows: [InventoryRow]) {
            self.sourceRows = sourceRows
        }

    \(sharedInventorySnippet)
    }
    """

    private static let duplicatedFileC = """
    import Foundation

    struct ReplenishmentPlanner {
        let history: [InventoryRow]
        let safetyMargin: Double

        func planForWeek(_ week: Int) -> Int {
            history.count * max(week, 1)
        }

    \(sharedInventorySnippet)
    }
    """

    private static let uniqueFileOne = """
    import Foundation

    struct PriceBandBuilder {
        private var buckets: [(label: String, range: ClosedRange<Double>)] = []

        mutating func addBand(named label: String, from low: Double, to high: Double) {
            precondition(low <= high, "区间方向不合法")
            buckets.append((label, low...high))
        }

        func classify(_ amount: Double) -> String {
            for bucket in buckets where bucket.range.contains(amount) {
                return bucket.label
            }
            return "未分组"
        }

        func histogram(_ amounts: [Double]) -> [String: Int] {
            var counts: [String: Int] = [:]
            for amount in amounts {
                counts[classify(amount), default: 0] += 1
            }
            return counts
        }
    }
    """

    private static let uniqueFileTwo = """
    import Foundation

    final class ShipmentTracer {
        private var events: [Date: String] = [:]

        func record(_ note: String, at moment: Date) {
            events[moment] = note.trimmingCharacters(in: .whitespaces)
        }

        func timeline(after cutoff: Date) -> [(Date, String)] {
            let kept = events.filter { entry in entry.key > cutoff }
            return kept.sorted { left, right in left.key < right.key }.map { ($0.key, $0.value) }
        }

        var eventCount: Int {
            events.count
        }

        func exportPayload() -> Data {
            let stamps = events.keys.sorted().map { $0.timeIntervalSince1970 }
            return (try? JSONSerialization.data(withJSONObject: stamps)) ?? Data()
        }
    }
    """
}
