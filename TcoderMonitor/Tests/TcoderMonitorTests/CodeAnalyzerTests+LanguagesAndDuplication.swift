/// OWNER: WS-X3 TestSplit —— 自 CodeAnalyzerTests.swift 拆出，语言目录/注释元数据/归一化与重复检测。用例本体未改，只是搬了家。
import XCTest
@testable import TcoderMonitor

extension CodeAnalyzerTests {

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

    /// 支持列表本身：非空、无重名、七种语言必须在册（WS-X3 拆分：原来这条与
    /// 注释元数据挤在一个函数里，CC 18 超本仓 16 的热点线；拆成两条，断言一条没少）。
    func testSupportedLanguagesListIsDeduplicatedAndCoversRequiredOnes() {
        let supported = SourceLanguageCatalog.supportedLanguages
        XCTAssertFalse(supported.isEmpty, "必须至少声明一种语言")
        XCTAssertEqual(Set(supported).count, supported.count, "supportedLanguages 不得出现重名语言")
        for language in ["Swift", "Java", "Python", "SQL", "YAML", "JSON", "Markdown"] {
            XCTAssertTrue(supported.contains(language), "支持列表里必须能查到 \(language)")
        }
    }

    /// 行注释前缀与文档字符串定界符。
    func testLineCommentPrefixesAndDocStringsFollowTheLanguageTable() {
        let supported = SourceLanguageCatalog.supportedLanguages
        XCTAssertEqual(SourceLanguageCatalog.lineCommentPrefixes(for: "Swift"), ["//"], "Swift 行注释前缀")
        XCTAssertTrue(SourceLanguageCatalog.lineCommentPrefixes(for: "Python").contains("#"), "Python 行注释前缀")
        XCTAssertTrue(SourceLanguageCatalog.lineCommentPrefixes(for: "SQL").contains("--"), "SQL 行注释前缀")
        XCTAssertTrue(SourceLanguageCatalog.lineCommentPrefixes(for: "JSON").isEmpty, "JSON 规范里没有注释")
        XCTAssertTrue(SourceLanguageCatalog.lineCommentPrefixes(for: "未发明的语言").isEmpty,
                      "未知语言不得给任何规则")
        XCTAssertFalse(supported.isEmpty, "查前缀之前先确认语言表读到了东西")
        XCTAssertTrue(SourceLanguageCatalog.docStringDelimiters(for: "Python").contains("\"\"\""),
                      "Python 三引号文档字符串")
        XCTAssertTrue(SourceLanguageCatalog.docStringDelimiters(for: "Swift").isEmpty, "Swift 没有文档字符串")
    }

    /// 块注释定界符：`?.start` / `?.end` 在复杂度口径里各算一个分支，
    /// 收进这两个取值口之后判据与原来逐字同形。
    func testBlockCommentDelimitersOnlyForLanguagesThatHaveThem() {
        XCTAssertEqual(blockStart("Swift"), "/*", "Swift 块注释起始定界符")
        XCTAssertEqual(blockEnd("Swift"), "*/", "Swift 块注释结束定界符")
        XCTAssertEqual(blockStart("HTML"), "<!--", "HTML 注释定界符")
        XCTAssertNil(blockStart("Python"), "Python 没有块注释")
        XCTAssertNil(blockStart("YAML"), "YAML 没有块注释")
        XCTAssertNil(blockStart("未发明的语言"), "未知语言不得返回定界符")
    }

    private func blockStart(_ language: String) -> String? {
        SourceLanguageCatalog.blockCommentDelimiters(for: language)?.start
    }

    private func blockEnd(_ language: String) -> String? {
        SourceLanguageCatalog.blockCommentDelimiters(for: language)?.end
    }

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
                // RD-61 第二半（WS-R26）：这一行原来断言 `occurrence.path.hasPrefix(root.path)`，
                // 那是把「生产点给绝对路径」当成了契约。它真正要守的不变式没变、也没松：
                // **坐标必须落在夹具根内，并且指向盘上真实存在的那份文件** —— 判据换成
                // 「按夹具根解析回去 + 仍在根内 + 文件在」，与坐标是相对还是绝对无关。
                let coordinateURL = CodeViewFormat.resolvedURL(occurrence.path, root: root.path)
                XCTAssertTrue(coordinateURL.path.hasPrefix(root.path + "/"),
                              "重复块坐标越出夹具根：\(occurrence.path)")
                XCTAssertTrue(FileManager.default.fileExists(atPath: coordinateURL.path),
                              "坐标解析出来的文件盘上没有：\(occurrence.path)")
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

    // MARK: - WS-X3 拆分时丢失的一条（总工 00:58 自 main 取回，并按自扫判词拆成三段）
    //
    // 原用例 23 行里塞了 18 个分支（被本 App 自扫点名 CC≥16）。断言的内容与顺序
    // 一字未动，只是每族各占一个小函数：语言清单 / 行注释前缀 / 块注释与文档字符串。
    func testSupportedLanguagesExposeCommentMetadata() {
        assertSupportedLanguageListIsUnique()
        assertLineCommentPrefixes()
        assertBlockAndDocStringDelimiters()
    }

    private func assertSupportedLanguageListIsUnique() {
        let supported = SourceLanguageCatalog.supportedLanguages
        XCTAssertFalse(supported.isEmpty, "必须至少声明一种语言")
        XCTAssertEqual(Set(supported).count, supported.count, "supportedLanguages 不得出现重名语言")
        for language in ["Swift", "Java", "Python", "SQL", "YAML", "JSON", "Markdown"] {
            XCTAssertTrue(supported.contains(language), "支持列表里必须能查到 \(language)")
        }
    }

    private func assertLineCommentPrefixes() {
        XCTAssertEqual(SourceLanguageCatalog.lineCommentPrefixes(for: "Swift"), ["//"], "Swift 行注释前缀")
        XCTAssertTrue(SourceLanguageCatalog.lineCommentPrefixes(for: "Python").contains("#"), "Python 行注释前缀")
        XCTAssertTrue(SourceLanguageCatalog.lineCommentPrefixes(for: "SQL").contains("--"), "SQL 行注释前缀")
        XCTAssertTrue(SourceLanguageCatalog.lineCommentPrefixes(for: "JSON").isEmpty, "JSON 规范里没有注释")
        XCTAssertTrue(SourceLanguageCatalog.lineCommentPrefixes(for: "未发明的语言").isEmpty, "未知语言不得给任何规则")
    }

    private func assertBlockAndDocStringDelimiters() {
        XCTAssertEqual(SourceLanguageCatalog.blockCommentDelimiters(for: "Swift")?.start, "/*", "Swift 块注释起始定界符")
        XCTAssertEqual(SourceLanguageCatalog.blockCommentDelimiters(for: "Swift")?.end, "*/", "Swift 块注释结束定界符")
        XCTAssertEqual(SourceLanguageCatalog.blockCommentDelimiters(for: "HTML")?.start, "<!--", "HTML 注释定界符")
        XCTAssertNil(SourceLanguageCatalog.blockCommentDelimiters(for: "Python"), "Python 没有块注释")
        XCTAssertNil(SourceLanguageCatalog.blockCommentDelimiters(for: "YAML"), "YAML 没有块注释")
        XCTAssertNil(SourceLanguageCatalog.blockCommentDelimiters(for: "未发明的语言"), "未知语言不得返回定界符")
        XCTAssertTrue(SourceLanguageCatalog.docStringDelimiters(for: "Python").contains("\"\"\""), "Python 三引号文档字符串")
        XCTAssertTrue(SourceLanguageCatalog.docStringDelimiters(for: "Swift").isEmpty, "Swift 没有文档字符串")
    }
}
