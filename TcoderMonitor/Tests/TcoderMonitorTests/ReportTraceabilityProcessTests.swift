import Foundation
import XCTest
@testable import TcoderMonitor

/// R10b 的**真子进程**验收（AGENTS §5.9 第 3 条：只有 in-process 断言不算交付证据）。
///
/// 起的是同一次构建产出的那个二进制本身，跑两趟：`scan --out` 落一份 JSON、`score` 出一份文本。
/// 这两份产物来自**同一个进程、同一条装配路**，逐条对得上的话才说明台账那段不是
/// "只在单测里走了一遍函数"，而是真从进程里打出来的。
///
/// 独立真值（手数的份数，见 `makeFixture` 与下面各处注释）：
/// · 文件数 = 测试自己用 `FileManager` 数出来的源码文件个数（不算二进制），与分析器的
///   "数一行一行"完全无关；
/// · 巨大文件真个数 = 1 —— 夹具里只有 `Big.swift` 被我写成 405 行（判据线 400 行，
///   `FileSystemCodeAnalyzer.mediumFileLines`，本轮不许动），其余三个文件都不到 20 行；
/// · 撞上限那一路 = 代码扫描 —— 夹具里放了一个 `dot.png`，二进制扩展名被排除 ⇒
///   `scanLimitations` 必出句子 ⇒ 这一路必须是 partial 而不是 ok。
final class ReportTraceabilityProcessTests: XCTestCase {

    /// 一次扫描的墙钟上限。自扫整仓要 40 秒量级，夹具只有四个文件，20 秒足够；
    /// 超了就是要抓的"挂死"，不是慢。
    private static let wallClockLimit: TimeInterval = 20

    /// 非 Optional：IUO 属性在闭包里不自检，写成占位值更省事。
    private var fixture = URL(fileURLWithPath: "/tmp/r10b-unused")

    /// 三个手写函数（多行体），与 `bigFile()` 里那两个合起来 = 这份夹具**一共 5 个函数**。
    private let smallFile = """
    import Foundation

    func one() -> Int {
        return 1
    }

    func two(_ flag: Bool) -> Int {
        if flag { return 2 }
        return 1
    }

    enum Holder {
        static func three() -> String {
            "x"
        }
    }
    """

    // MARK: - 夹具

    /// 建在**仓库内** `.scratch/`（AGENTS §1.6：一次性产物不进 `$TMPDIR`）。
    /// ⚠ 已知后果，测试里当断言用而不是当意外：`.scratch/` 在这个仓的工作树里，
    /// Git 那一路会向上找到外层仓库 ⇒ `resolvedGitRoot != scannedRoot`，
    /// 溯源行必须把这一跳说出来（`ScanProvenance.relocationNote`）。
    private func makeFixture() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // TcoderMonitorTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // TcoderMonitor
            .deletingLastPathComponent()      // 仓库根
            .appendingPathComponent(".scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dir = root.appendingPathComponent("r10b-cli-\(UUID().uuidString.prefix(8))", isDirectory: true)
        fixture = dir
        let source = dir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try bigFile().write(to: source.appendingPathComponent("Big.swift"), atomically: true, encoding: .utf8)
        try smallFile.write(to: source.appendingPathComponent("Small.swift"), atomically: true, encoding: .utf8)
        try "{\"dependencies\":{\"left-pad\":\"1.0.0\"}}\n"
            .write(to: dir.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        // 二进制扩展名：被按规则排除 ⇒ 必出一条「边界」句子 ⇒ 代码那一路必须是 partial。
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: dir.appendingPathComponent("dot.png"))
        let captured = dir   // 局部量进闭包，避免 teardown 捕获 self
        addTeardownBlock { try? FileManager.default.removeItem(at: captured) }
    }

    /// 405 行：1 行 import + 2 个函数 + 补齐的注释行。判据线是 400，所以它必须上榜且只上 1 个。
    /// 函数体一律写成**多行**：一行体 `func a() -> Int { 1 }` 分析器认不出来
    /// （实测 analyzedFunctionCount 会是 0），那样"手写了 5 个函数"这份真值就悬空了。
    private func bigFile() -> String {
        var lines = ["import Foundation", "", "func bigOne() -> Int {", "    let a = 1", "    return a", "}", "",
                     "func bigTwo() -> Int {", "    if a() { return 2 }", "    return 3", "}", ""]
        while lines.count < 405 { lines.append("// 补齐行数，让这一份越过巨大文件线") }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - 起真进程

    private func launch(_ args: [String]) throws -> (rc: Int32, stdout: String, stderr: String) {
        let out = Pipe()
        let err = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: try CLIProcessTests.productBinary())
        proc.arguments = args
        proc.standardOutput = out
        proc.standardError = err
        try proc.run()
        let deadline = Date().addingTimeInterval(Self.wallClockLimit)
        while proc.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if proc.isRunning {
            proc.terminate()
            proc.waitUntilExit()
            XCTFail("argv \(args) 在 \(Self.wallClockLimit) 秒内没退出")
        } else {
            proc.waitUntilExit()
        }
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (proc.terminationStatus, stdout, stderr)
    }

    /// 扫描产物**放在夹具之外**：写进夹具就会被下一趟扫描当成一个源文件数进去，
    /// 于是"文件数"这份真值被自己的取证动作污染过（本轮实测踩过同类）。
    private func scanOutput() -> URL {
        let url = fixture.deletingLastPathComponent()
            .appendingPathComponent("r10b-out-\(UUID().uuidString.prefix(8)).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func index(_ lines: [String], hasPrefix prefix: String) -> Int {
        lines.firstIndex { $0.hasPrefix(prefix) } ?? -1
    }

    // MARK: - 判据

    func test_realBinaryPrintsLedgerThatMatchesItsOwnJSON() throws {
        try makeFixture()
        let outFile = scanOutput()
        let scan = try launch(["scan", fixture.path, "--out=\(outFile.path)", "--compact"])
        XCTAssertTrue([0, 2].contains(Int(scan.rc)),
                      "夹具至少缺日志与覆盖率两路 ⇒ 档位只能是 0 或 2，不能是 3/4；stderr=\(scan.stderr.prefix(200))")
        let data = try Data(contentsOf: outFile)
        let report = try JSONDecoder.tcoderReportDecoder().decode(ProjectReport.self, from: data)
        let ledger = try XCTUnwrap(report.analyzerLedger, "无头装配没写台账")
        XCTAssertEqual(ledger.count, 5, "五路就得有五本账")

        let score = try launch(["score", fixture.path])
        let lines = score.stdout.components(separatedBy: "\n")
        let header = index(lines, hasPrefix: AnalyzerLedgerText.headerToken)
        XCTAssertGreaterThan(header, -1, "台账整段没从真进程里打出来：\n\(score.stdout.prefix(400))")

        // 逐路：JSON 里每一条状态，文本里必须有对应那一行（同一个二进制、两个出口对得上）。
        for record in ledger {
            let expected = "[\(AnalyzerLedgerText.statePhrase(record.state))] \(record.name)"
            XCTAssertTrue(score.stdout.contains(expected), "缺这一行：\(expected)\n实际：\n\(score.stdout)")
        }
        // 表头四个计数之和必须是 5，且"失败"那一格与 failedSections 数出来的一致。
        let counts = ["跑完", "部分", "失败", "没跑"].map { label in
            ledger.filter { $0.state.nameOfTally == label }.count
        }
        XCTAssertEqual(counts.reduce(0, +), 5, "四态计数加起来不等于路数 = 有状态没被计入")
        XCTAssertEqual(ledger.filter { $0.state == .failed }.count, report.failedSections.count,
                       "台账里的失败数与 failedSections 不是同一批事实数出来的")
        XCTAssertTrue(lines[header].contains("部分 1"),
                      "夹具里放了一个二进制文件，代码那一路必须是部分测量：\(lines[header])")
    }

    func test_realBinaryOrdersCaveatThenLedgerThenScore() throws {
        try makeFixture()
        let score = try launch(["score", fixture.path])
        let lines = score.stdout.components(separatedBy: "\n")
        let caveat = index(lines, hasPrefix: "未量准")
        let ledger = index(lines, hasPrefix: AnalyzerLedgerText.headerToken)
        let verdict = index(lines, hasPrefix: "综合健康分")
        XCTAssertGreaterThan(caveat, -1, "夹具里有被排除的条目，未量准那段必须出声")
        XCTAssertGreaterThan(ledger, caveat, "先说没量准，再说每一路做了什么")
        XCTAssertGreaterThan(verdict, ledger, "…最后才给分")
    }

    func test_realBinarySplitsMeasuredFromDerivedAndCountsMatchHandCount() throws {
        try makeFixture()
        let score = try launch(["score", fixture.path])
        let lines = score.stdout.components(separatedBy: "\n")
        let derived = lines.filter { $0.contains("← 由「") }
        XCTAssertFalse(derived.isEmpty, "乙栏一行都没有")
        let measuredHeader = index(lines, hasPrefix: "  甲·")
        let derivedHeader = index(lines, hasPrefix: "  乙·")
        XCTAssertGreaterThan(measuredHeader, -1)
        XCTAssertGreaterThan(derivedHeader, measuredHeader)

        // 独立真值①：文件数 = 测试自己数的"非二进制条目"个数（2 个 .swift + 1 份 package.json；
        // JSON 在语言表里，实测 languages 会给出 `JSON 1 个文件`，所以它算一个源文件）。
        let handCounted = try handCountedSourceFiles()
        let filesLine = lines.first { $0.contains("· " + MeasuredItem.files + " = ") } ?? ""
        XCTAssertTrue(filesLine.contains("= \(handCounted)"),
                      "文件数读数是「\(filesLine)」，而我自己数出来的是 \(handCounted) 个源文件")
        // 独立真值②：巨大文件真个数 = 1（只有 Big.swift 被我写成 405 行）。
        let hugeLine = lines.first { $0.contains("· " + MeasuredItem.hugeFileTotal + " = ") } ?? ""
        XCTAssertTrue(hugeLine.contains("= 1"), "巨大文件真个数应为手数的 1 个，实际：\(hugeLine)")
    }

    /// 手数的份数：走一遍盘，只数 `.swift` 与清单文件，二进制扩展名不算。
    /// 这条与分析器完全无关（没调它的任何函数），所以能当独立真值。
    private func handCountedSourceFiles() throws -> Int {
        let walker = FileManager.default.enumerator(at: fixture, includingPropertiesForKeys: nil)
        let urls = walker?.compactMap { $0 as? URL } ?? []
        let excluded: Set<String> = ["png"]
        let counted = urls.filter { !$0.hasDirectoryPath && !excluded.contains($0.pathExtension.lowercased()) }
        XCTAssertEqual(counted.count, 3, "夹具里我一共写了 3 个非二进制文件（Big.swift / Small.swift / package.json），"
                       + "这条要是变了，上面那条对表断言就失去意义：\(counted.map(\.lastPathComponent))")
        return counted.count
    }

    func test_realBinaryGivesEveryBoardEntryACoordinateAndNeverADeduction() throws {
        try makeFixture()
        let outFile = scanOutput()
        _ = try launch(["scan", fixture.path, "--out=\(outFile.path)", "--compact"])
        let report = try JSONDecoder.tcoderReportDecoder()
            .decode(ProjectReport.self, from: Data(contentsOf: outFile))
        let score = try launch(["score", fixture.path])
        let lines = score.stdout.components(separatedBy: "\n")
        let headerAt = index(lines, hasPrefix: "结论坐标")
        XCTAssertGreaterThan(headerAt, -1)
        let coordinateLines = Array(lines[(headerAt + 1)...]).prefix(while: { $0.hasPrefix("  ") })
            .filter { $0.contains(" ⇑ ") }
        // 独立真值③：巨大文件那一条 —— 榜上只可能有 `Big.swift`（405 行过线，其余都不到 20 行）。
        let huge = coordinateLines.filter { $0.contains(CriterionName.hugeFile) }
        XCTAssertEqual(huge.count, 1, "榜上巨大文件应为手数的 1 个：\n" + coordinateLines.joined(separator: "\n"))
        XCTAssertTrue(huge.first?.contains("Big.swift") == true)
        // 两个出口对得上：文本里的坐标条数 = JSON 里那几张榜的条目数之和（含 CVE/日志/覆盖率报告）。
        let expected = (report.code?.hugeFiles.count ?? 0) + (report.code?.topComplexFunctions.count ?? 0)
            + (report.code?.duplicatedBlocks.count ?? 0)
            + (report.dependencies?.advisories.reduce(0) { $0 + $1.affectedPackages.count } ?? 0)
            + (report.logs?.topErrors.count ?? 0) + (report.coverage?.reports.count ?? 0)
        XCTAssertEqual(coordinateLines.count, expected,
                       "坐标条数与榜上条目数对不上：\n" + coordinateLines.joined(separator: "\n"))
        XCTAssertGreaterThan(coordinateLines.count, 1, "只有一条坐标的话上面那个求和就形同虚设")
        // 候选提示必须带标记，且一条都不许变成扣分。
        XCTAssertTrue(score.stdout.contains(CandidateRiskHints.screenToken))
        XCTAssertTrue(score.stdout.contains("风险提示 0 条"))
        XCTAssertGreaterThan(index(lines, hasPrefix: "综合健康分"), -1)
    }

    /// 夹具建在仓库工作树里 ⇒ Git 那一路找到的是**外层仓库**。这一跳必须上屏，
    /// 否则"外层仓库的提交号"会被读成"被扫目录的提交号"（这条是 R10 第一半立的，
    /// 我在这里把它当**真子进程**证据用，而不是只在 `ScanProvenanceTests` 里构造一个报告）。
    func test_realBinaryDisclosesThatCommitCameFromTheOuterRepository() throws {
        try makeFixture()
        let score = try launch(["score", fixture.path])
        XCTAssertTrue(score.stdout.contains("提交号来自外层仓库"),
                      "夹具在仓库工作树内，Git 那一路必然向上定位；溯源行不说这一跳就是在冒充：\n"
                      + score.stdout.prefix(400))
        XCTAssertTrue(score.stdout.contains(fixture.path), "扫描根也得打出来，否则没人知道量的是哪个目录")
    }
}

private extension AnalyzerRunState {
    /// 与 `AnalyzerLedgerText` 表头用的四个短名对齐（测试自己列一份，不去改冻结区）。
    var nameOfTally: String {
        switch self {
        case .ok: return "跑完"
        case .partial: return "部分"
        case .failed: return "失败"
        case .notRun: return "没跑"
        }
    }
}
