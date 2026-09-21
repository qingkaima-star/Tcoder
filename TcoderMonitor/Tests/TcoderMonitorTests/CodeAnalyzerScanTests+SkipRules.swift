/// OWNER: WS-X3 TestSplit —— 自 CodeAnalyzerScanTests.swift 拆出，扫描面的排除规则：目录名/相对路径/隐藏文件/超大二进制/文件数上限/不跟软链目录。用例本体未改，只是搬了家。
import Foundation
import XCTest
@testable import TcoderMonitor

extension CodeAnalyzerTests {

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

}
