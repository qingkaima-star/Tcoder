/// OWNER: WS-X3 TestSplit —— 自 CodeAnalyzerTests.swift 拆出，analyze 入口的空目录/非目录/夹具树/真仓库/六万行预算/回车换行。用例本体未改，只是搬了家。
import XCTest
@testable import TcoderMonitor

extension CodeAnalyzerTests {

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
