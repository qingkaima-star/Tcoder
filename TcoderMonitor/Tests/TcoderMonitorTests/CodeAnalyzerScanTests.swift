import Foundation
import XCTest
@testable import TcoderMonitor

// OWNER: Workstream A (静态代码分析) —— CodeAnalyzerTests 的续篇：
// E 根路径与 classify 前置过滤 / F 扫描纪律 / G 圈复杂度 / H 函数识别。
// 拆分只为守住「800 行以上的文件不得增加」这条红线（本工作流刚把这些测试加到 1,110 行），
// 用例一条没删、一条没改；夹具辅助在 CodeAnalyzerTests.swift 里，已从 private 放宽到模块内。
extension CodeAnalyzerTests {
    // MARK: - E. relativePath 与 classify 的前置过滤

    func testRelativePathUsesRootPrefixAndFallsBackToFileName() {
        let root = URL(fileURLWithPath: "/tmp/tcoder-relative-root")
        XCTAssertEqual(SourceFileClassifier.relativePath(for: root.appendingPathComponent("Sources/Alpha.swift"), root: root),
                       "Sources/Alpha.swift", "根之下的文件必须给出相对路径")
        XCTAssertEqual(SourceFileClassifier.relativePath(for: root.appendingPathComponent("App.swift"), root: root),
                       "App.swift", "根目录直属文件只留文件名")
        XCTAssertEqual(SourceFileClassifier.relativePath(for: URL(fileURLWithPath: "/elsewhere/deep/Other.swift"), root: root),
                       "Other.swift", "现状：根之外的 URL 退化为主文件名")
        // 枚举器返回的是 canonical 路径（/tmp 实为 /private/tmp），而调用方传的是原始根：
        // 归一化后两者必须判定为同一个根，否则相对路径退化成裸文件名，
        // UI 上不同目录的同名文件会显示成同一条路径，且 `ScanOptions.skipDirectories` 里
        // 带 `/` 的项（如 "Resources/raw"）永远命不中。
        XCTAssertEqual(SourceFileClassifier.relativePath(for: URL(fileURLWithPath: "/private/tmp/x/KeepMe/Kept.swift"),
                                                        root: URL(fileURLWithPath: "/tmp/x")),
                       "KeepMe/Kept.swift", "根与 URL 只有软链接形态差异时必须是同一个根")
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
}
