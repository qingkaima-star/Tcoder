import XCTest
@testable import TcoderMonitor

/// R5b · **契约字段清单 `0fbdfc7` 那 11 格**的自带守卫（每格三态 + 逐格点名"缺什么"）。
///
/// 判据口径（AGENTS §8.1 窄口径豁免的条件 2）：
///   · 三态钉法：`nil`（旧报告没统计过）/ `0`（统计过、结论是"没有"）/ `>0`（有东西被摘掉）各一条；
///   · `mergeConfident` 三态各一条，**外加一条反例**：只有一份报告但该份缺 `sourceFingerprint`
///     ⇒ 必须 `false`（钉住"不许由份数推出 confident"）；
///   · 三处截断（深度 ≤6、40 份上限、份数上限）**必须共用 §6.1 那一个显示形状**，
///     由 `testTheThreeTruncationsAllFeedTheOneDisplayShape` 当场拦住"再造一套"。
///
/// **独立真值**：期望数字全部是手算/自己数的（40、41、哪一份被丢按路径排序自己算、
/// HEAD 短哈希自己起 `git` 子进程读），不拿实现输出当唯一正确答案。
final class CoverageContractFieldTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("r5b-fields-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func write(_ relative: String, _ contents: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func outcome() async throws -> CoverageMetrics.AnalysisOutcome {
        try await CoverageAnalyzer().analyzeWithLedger(projectRoot: root, options: .default)
    }

    /// 真 git 仓库：`sourceFingerprint` 只能从真 git 里读出来，拿假值测它等于没测。
    private func makeGitRepo() throws {
        try write("src/a.js", "export const a = 1\n")
        for arguments in [["init", "-q", "."], ["config", "user.name", "R5b Fixture"],
                          ["config", "user.email", "r5b-fixture@tcoder.local"],
                          ["add", "-A"], ["commit", "-qm", "first"]] {
            XCTAssertEqual(try run("/usr/bin/git", arguments), "", "git \(arguments) 有输出")
        }
    }

    private func headCommit() throws -> String {
        try run("/usr/bin/git", ["rev-parse", "HEAD"])
    }

    private func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = root
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(executable) \(arguments) 失败")
        return (String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 身份五格：正例（写进盘、且能原样读回来）

    /// 同一次 nyc 运行的对偶落法 ⇒ 留下的那份报告必须**带着身份**落盘：
    /// 格式键、运行键、证据档、模块键；而源码指纹在非 git 下必须是 `nil`（不是 `""`）。
    func testIdentitySlotsLandOnThePersistedReport() async throws {
        try write("web/coverage/lcov.info", "SF:src/a.ts\nLF:200\nLH:120\nend_of_record\n")
        try write("web/coverage/coverage-summary.json", """
        {"total":{"lines":{"total":200,"covered":120,"skipped":0,"pct":60.0}}}
        """)
        let metrics = try await outcome().metrics
        let report = try XCTUnwrap(metrics.reports.first, "对偶落法应只留一份可核对的读数")
        XCTAssertEqual(report.format, CoverageReportFormat.lcov.rawValue)
        XCTAssertEqual(report.runKey, "dir=web/coverage", "两份互证过 ⇒ 运行键要跟着落盘")
        XCTAssertEqual(report.runEvidence, CoverageRunEvidence.coPublishedPair.rawValue)
        XCTAssertEqual(report.moduleKey, "web", "模块键 = 剥掉产物段之后的相对目录（不是绝对路径）")
        XCTAssertNil(report.sourceFingerprint, "非 git 目录 ⇒ 源码身份就是缺的，不许拿 mtime 顶替")
        XCTAssertTrue(report.bindingText.contains("未绑定提交"), report.bindingText)

        // 落盘 ↔ 读回：整键缺席表达「没测到」，不许在往返里被洗成 `""` 或 `0`。
        let data = try JSONEncoder().encode(metrics)
        let decoded = try JSONDecoder().decode(CoverageMetrics.self, from: data)
        XCTAssertEqual(decoded, metrics, "身份五格必须随报告一起往返")
    }

    /// **反证**：旧版报告（JSON 里没有这五格）读进来 ⇒ 五格一律 `nil`，
    /// 而上屏话术要说"未记录"，**不许**说成"没有格式/没有来源"。
    func testLegacyReportWithoutIdentitySlotsDecodesAsNilNotAsEmpty() throws {
        let metrics = try JSONDecoder().decode(CoverageMetrics.self, from: Data(legacyMetricsJSON.utf8))
        let report = try XCTUnwrap(metrics.reports.first)
        XCTAssertNil(report.format)
        XCTAssertNil(report.runKey)
        XCTAssertNil(report.runEvidence)
        XCTAssertNil(report.moduleKey)
        XCTAssertNil(report.sourceFingerprint)
        XCTAssertEqual(report.formatText, "格式未记录（旧报告，不声称与任何一份同源）")
        XCTAssertEqual(report.runText, "认不出属于哪次运行（不参与任何去重）")
        XCTAssertTrue(report.bindingText.contains("不按新鲜数据声称"), report.bindingText)
    }

    /// `nil`（旧报告没记过）与 `"unrecognized"`（文件名在候选清单里但认不出格式）
    /// **不是同一件事**，两格的说法必须不同（清单 §1 点名要求）。
    func testUnrecognizedFormatIsNotTheSameSentenceAsMissingFormat() {
        var legacy = CoverageReport(path: "/x/lcov.info", kind: .combined, toolName: "lcov",
                                    linesCovered: 1, linesTotal: 2, branchesCovered: 0,
                                    branchesTotal: nil, methodsCovered: 0, methodsTotal: 0)
        XCTAssertNil(legacy.format)
        let nilText = legacy.formatText
        legacy.format = CoverageReportFormat.unrecognized.rawValue
        let unknownText = legacy.formatText
        XCTAssertNotEqual(nilText, unknownText, "两态压成一句就是清单点名的病")
        XCTAssertTrue(unknownText.contains("不与任何报告合并"), unknownText)
    }

    /// 模块身份切不出来（报告在被扫目录之外）⇒ `nil` + 明写"未知"，
    /// **绝不**把绝对路径原样当模块键（换机器就换键，本轮实测踩过 `/var` ↔ `/private/var`）。
    func testModuleKeyIsUnknownOutsideScannedRootAndNeverTheAbsolutePath() {
        let outside = CoverageReportIdentity.derive(path: "/totally/elsewhere/coverage/lcov.info",
                                                    root: URL(fileURLWithPath: "/repo"),
                                                    format: .lcov)
        XCTAssertNil(outside.moduleKey, "切不出来就是未知，不许退回绝对路径")
        XCTAssertNil(outside.directoryKey)
        let atRoot = CoverageReportIdentity.derive(path: "/repo/coverage/lcov.info",
                                                   root: URL(fileURLWithPath: "/repo"),
                                                   format: .lcov)
        XCTAssertEqual(atRoot.moduleKey, "", "仓库根的报告：模块键是空串（全仓的坐标），不是 nil")
    }

    // MARK: - 源码身份：扫描时指纹 ≠ 产物自报提交（两层绑定不许混）

    /// 正例 + 边界：真 git 仓库里 `sourceFingerprint` 等于**本次扫描时**的 HEAD 短哈希；
    /// 措辞上它只能写"扫描时源码在 X"，**不许**长成"这份报告绑定在该提交上"。
    func testSourceFingerprintIsScanTimeHeadAndNeverClaimsToBindTheArtefact() async throws {
        try makeGitRepo()
        let full = try headCommit()
        try write("coverage/lcov.info", "SF:src/a.js\nLF:100\nLH:50\nend_of_record\n")
        let metrics = try await outcome().metrics
        let report = try XCTUnwrap(metrics.reports.first)
        XCTAssertEqual(report.sourceFingerprint, String(full.prefix(12)),
                       "落盘的是扫描时 HEAD 短哈希（与 `CoverageSourceState` 同一处取）")
        XCTAssertEqual(report.sourceRepository, ".", "这个提交号来自**被扫目录自己**的仓库，要这么点名")
        XCTAssertTrue(report.bindingText.contains("被扫目录自己的仓库"), report.bindingText)
        XCTAssertTrue(report.bindingText.contains("不是"), report.bindingText)
        XCTAssertFalse(report.bindingText.contains("绑定在该提交上"),
                       "mtime/HEAD 只能证伪，不许声称产物绑定在某个提交上：\(report.bindingText)")
    }

    /// ⚠ 找 `.git` 是**沿父链**找的（用户会去扫某个大仓库的子目录，这时刻意保留）。
    /// 保留的代价是：外层仓库的提交号可以冒充"这个项目自己的提交"（本仓 §25 点名的形状）。
    /// 判据：指纹照记，但 `sourceRepository` 必须点名它是**外层**，措辞不许声称这是本项目自己的提交。
    func testEnclosingRepositoryCommitIsNotSilentlyAttributedToTheProject() async throws {
        try makeGitRepo()                                     // 外层仓库 = root
        let inner = root.appendingPathComponent("inner/sub", isDirectory: true)   // 被扫总体：没有 .git
        try FileManager.default.createDirectory(at: inner.appendingPathComponent("coverage"),
                                                withIntermediateDirectories: true)
        let report = inner.appendingPathComponent("coverage/lcov.info")
        try "SF:src/a.js\nLF:100\nLH:50\nend_of_record\n".write(to: report, atomically: true,
                                                                   encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: report.path)

        let metrics = try await CoverageAnalyzer().analyze(projectRoot: inner, options: .default)
        let scored = try XCTUnwrap(metrics.reports.first, "mtime 不早于提交 ⇒ 该给数就给")
        XCTAssertNotNil(scored.sourceFingerprint, "父链上有仓库 ⇒ 读得到指纹，这本身不是错")
        XCTAssertEqual(scored.sourceRepository, "../..", "提交号来自往外两层的仓库，必须点名成相对坐标")
        XCTAssertTrue(scored.bindingText.contains("外层"), scored.bindingText)
        XCTAssertTrue(scored.bindingText.contains("说的不是本项目自己的提交"), scored.bindingText)
    }

    // MARK: - mergeConfident：三态 + 清单点名的那条反例

    /// `nil` = **压根没给总数**（缺证据 ≠ 不可信）。
    func testMergeConfidentIsNilWhenNoTotalWasGiven() async throws {
        _ = try write("coverage/lcov.info", "SF:a.js\nLF:0\nLH:0\nend_of_record\n")
        let result = try await outcome()
        XCTAssertNil(result.metrics.overallLinePercent, "没有可用分母 ⇒ 不给总数")
        XCTAssertNil(result.metrics.mergeConfident, "没给总数时不许说可信/不可信：\(result.merge.statement)")
        XCTAssertNil(result.metrics.mergeConfidenceText, "连总数都没有 ⇒ 这一格上屏是空白，不是「不可信」")
    }

    /// **清单点名的反例**：只有一份报告，但那一份缺 `sourceFingerprint` ⇒ 必须 `false`。
    /// 钉住的是"不许由份数推出 confident"（R5 旧写法是 `pool.count == 1 ⇒ true`）。
    func testSingleReportWithoutFingerprintIsNotConfident() async throws {
        try write("web/coverage/lcov.info", "SF:src/a.ts\nLF:200\nLH:120\nend_of_record\n")
        let result = try await outcome()
        XCTAssertEqual(result.metrics.reports.count, 1, "只有一份报告（谈不上合并）")
        XCTAssertNotNil(result.metrics.overallLinePercent, "一份真实读数该给就给")
        XCTAssertNil(result.metrics.reports.first?.sourceFingerprint, "非 git ⇒ 源码身份缺")
        XCTAssertEqual(result.metrics.mergeConfident, false,
                       "只剩一份 ⇒ 就顺手说可信，正是本轮要消灭的写法")
        XCTAssertFalse(result.merge.identityGaps.isEmpty,
                       "不可信要能说出缺哪格：\(result.merge.identityGaps)")
        XCTAssertTrue(result.merge.statement.contains("没有源码提交指纹"), result.merge.statement)
    }

    /// `true` 的形状：进总数的那一份**四格齐全**（格式/运行/模块/源码）才敢说可信。
    /// 运行格这里靠"正文自带运行时刻"成立（coverage.py 的 `timestamp=`），不是靠猜。
    func testMergeConfidentTrueNeedsEverySlotNotJustOneReport() async throws {
        try makeGitRepo()
        try write("py/coverage.xml",
                  "<coverage line-rate=\"0.5\" branches-valid=\"0\" lines-valid=\"100\" "
                  + "lines-covered=\"50\" timestamp=\"1680000000\" version=\"7.4\"><packages/></coverage>")
        let metrics = try await outcome().metrics
        let report = try XCTUnwrap(metrics.reports.first)
        XCTAssertEqual(report.runEvidence, CoverageRunEvidence.contentStamp.rawValue, report.runText)
        XCTAssertEqual(report.moduleKey, "py")
        XCTAssertNotNil(report.sourceFingerprint)
        XCTAssertEqual(report.format, CoverageReportFormat.coveragePyXml.rawValue)
        XCTAssertEqual(metrics.mergeConfident, true,
                       "四格齐 ⇒ 才谈得上可信（与「有几份报告」无关）：\(metrics.mergeConfidenceText ?? "-")")
        XCTAssertTrue(metrics.mergeConfidenceText?.contains("可核对") == true)
    }

    // MARK: - droppedByCap 与 §6.1 形状：三态

    /// `0` = 一份都没丢（一句真话，必须写 0 不许留 nil）；`nil` = 旧报告没统计过。
    func testDroppedByCapWritesZeroWhenNothingWasDroppedAndNilForLegacyReports() async throws {
        try write("web/coverage/lcov.info", "SF:src/a.ts\nLF:200\nLH:120\nend_of_record\n")
        let metrics = try await outcome().metrics
        XCTAssertEqual(metrics.droppedByCap, 0, "每次分析都要写这一格，0 是真话")
        XCTAssertEqual(metrics.truncationTotalCount, 1)
        XCTAssertEqual(metrics.displayedCount, 1)
        XCTAssertEqual(metrics.displayedCount, metrics.scannedFileCount, "两格必须同源")
        XCTAssertEqual(metrics.undisplayedCount, 0)
        XCTAssertEqual(metrics.undisplayedReports, [], "统计过且是空 ⇒ 空数组，不是 nil")
        XCTAssertNil(metrics.unmeasuredScope, "扫描面完整时不造那句「没看完」")
        XCTAssertFalse(metrics.capDisclosureText.contains("另有"), "没丢东西就别喊「另有 N 份未合并」")
        let legacy = try JSONDecoder().decode(CoverageMetrics.self, from: Data(legacyMetricsJSON.utf8))
        XCTAssertNil(legacy.droppedByCap, "旧报告里没这一格 ⇒ 上屏必须是「未统计」")
        XCTAssertEqual(legacy.capDisclosureText, "未统计是否有报告被上限丢弃")
    }

    /// 三道截断**只有一套显示形状**（清单 §2.1）：
    /// ① 深于 6 层 → `unexaminedDirectories` + `unmeasuredScope`；
    /// ② 40 份上限 → `undisplayedReports` 逐条点名；
    /// ③ 份数上限（合并侧）已由 R5 删除，这里钉住"不许再回来"。
    /// 并且：§6.1 那六格在 `Sources/**` 里**只能有一处写入点**、披露句**只能有一处生产者**。
    func testTheThreeTruncationsAllFeedTheOneDisplayShape() throws {
        let writers = try sourceFiles(containing: ["metrics.truncationTotalCount =",
                                                    "metrics.displayedCount =",
                                                    "metrics.undisplayedCount =",
                                                    "metrics.undisplayedReports =",
                                                    "metrics.unexaminedDirectories =",
                                                    "metrics.unmeasuredScope ="])
        XCTAssertEqual(writers.count, 1, "§6.1 六格出现第二个写入点就是两套尺子：\(writers)")
        XCTAssertEqual(writers.first, "CoverageAnalyzer.swift")

        let narrators = try sourceFiles(containing: ["份未合并"], inCodeOnly: true)
        XCTAssertEqual(narrators, ["CoverageDisplayShape.swift"],
                       "「另有 N 份未合并」必须只有一个生产者，再写一套截断说明当场红：\(narrators)")

        let planner = try sourceText(named: "CoverageMergePlanner.swift")
        XCTAssertTrue(planner.contains("不再设上限"), "规划器要写明份数上限已删、由 §6.1 接管")
        XCTAssertFalse(codeOnly(planner).contains("prefix("),
                       "旧「按分母留前六份」的截断形状不许回来（被丢的必须走 §6.1 点名）")

        // 恒等式：真实总数 = 交给合并的 + 没交的（三处截断共用同一个算式）。
        let stats = CoverageDiscoveryStats(foundCount: 40,
                                           fileCapSkippedDirectories: ["m41/coverage"],
                                           overCapReportPaths: ["m41/coverage/lcov.info"])
        let shape = CoverageDisplayShape.evaluate(discovery: stats, displayedCount: 40)
        XCTAssertEqual(shape.truncationTotalCount, 41)
        XCTAssertEqual(shape.undisplayedCount, 1)
        XCTAssertEqual(shape.droppedByCap, shape.undisplayedCount,
                       "droppedByCap 与 §6.1 那个数必须同源，不许各算一遍")
        XCTAssertEqual(shape.unexaminedDirectories, ["m41/coverage"], "超限的目录也要逐条点名")
        XCTAssertTrue(shape.statementParts.contains { $0.contains("另有 1 份未合并")
            && $0.contains("m41/coverage/lcov.info") },
                      "那句必须把坐标也带出来（几十份都叫 lcov.info 时只报文件名等于没点名）：\(shape.statementParts)")
    }

    /// `unmeasuredScope` 非空 ⇒ **「该项目没有覆盖率报告」这句话不成立**（清单 §2.1 写死）。
    func testUnmeasuredScopeMakesTheNoReportsClaimUnsound() async throws {
        // 夹具：一份在 6 层之内（看得见），一份在 7 层目录里（根本没下潜）。
        try write("a/b/c/d/e/f/lcov.info", "SF:src/a.js\nLF:100\nLH:50\nend_of_record\n")
        try write("a/b/c/d/e/f/g/h/lcov.info", "SF:src/deep.js\nLF:400\nLH:400\nend_of_record\n")
        let metrics = try await outcome().metrics
        XCTAssertFalse(metrics.reports.isEmpty, "浅处那份看得见")
        XCTAssertNotNil(metrics.unmeasuredScope, "深处有没看的东西 ⇒ 这句必须非空")
        XCTAssertTrue((metrics.unexaminedDirectories ?? []).contains { $0.contains("a/b/c/d/e/f/g") },
                      "没下潜的目录要逐条点名：\(metrics.unexaminedDirectories ?? [])")
        XCTAssertFalse(metrics.absenceClaimIsSound,
                       "扫描面不完整时不许说「该项目没有覆盖率报告」：\(metrics.unmeasuredScope ?? "-")")

        // 对照：一个文件都没有、也没有任何"没看"的目录 ⇒ 这句才成立（缺证据 ≠ 没看全）。
        let empty = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("r5b-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        let quiet = try await CoverageAnalyzer().analyze(projectRoot: empty, options: .default)
        XCTAssertTrue(quiet.absenceClaimIsSound)
        XCTAssertNil(quiet.unmeasuredScope)
    }

    // MARK: - 源码扫描小工具（守卫的"看盘"部分，只读本仓自己的文件）

    private func sourceURLs() throws -> [URL] {
        let base = URL(fileURLWithPath: #filePath)   // .../Tests/TcoderMonitorTests/本文件
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
        guard let walk = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
        else { return [] }
        return walk.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// 含全部 needle 的 `Sources/**` 文件名。**分母必须 > 0**（永真绿守卫是本仓踩过的坑）。
    /// `inCodeOnly: true` 时先剥注释与字符串再找 —— 只写"某段散文里提了一句"不算第二个生产者。
    private func sourceFiles(containing needles: [String], inCodeOnly: Bool = false) throws -> [String] {
        XCTAssertFalse(needles.isEmpty, "分母不许是空集")
        var hits: [String] = []
        var scanned = 0
        for url in try sourceURLs() {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            scanned += 1
            let text = inCodeOnly ? codeOnly(raw) : raw
            if needles.allSatisfy({ text.contains($0) }) { hits.append(url.lastPathComponent) }
        }
        XCTAssertGreaterThan(scanned, 100, "没真读到 Sources（\(scanned) 个文件）⇒ 这条守卫是空跑")
        return hits.sorted()
    }

    /// 粗粒度剥掉 `//` 行注释与行尾注释（与 `SourceFileReachabilityTests` 同一思路：
    /// 判据要看代码，不能看散文）。这里只需要它挡住"文档注释里提了一句"这种假阳性 ——
    /// **字符串内容要保留**：披露句本身就是产品代码里的字符串，剥掉它守卫就变成永真。
    private func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { rawLine -> String in
            let line = Substring(rawLine)
            guard let slash = line.range(of: "//") else { return String(line) }
            return String(line[..<slash.lowerBound])
        }.joined(separator: "\n")
    }

    private func sourceText(named name: String) throws -> String {
        let url = try sourceURLs().first { $0.lastPathComponent == name }
        return try String(contentsOf: XCTUnwrap(url), encoding: .utf8)
    }
}

/// 旧版 `CoverageMetrics` 的落盘形状（**手抄**，不是从实现里 dump 出来的）：
/// 没有 R5b 那 11 格 ⇒ 用来钉"旧报告读进来一律 nil，而不是整份解码失败"。
private let legacyMetricsJSON = """
{"analyzedAt":1700000000,"reports":[{"path":"/x/lcov.info","kind":"整体","toolName":"lcov",
"linesCovered":10,"linesTotal":20,"branchesCovered":0,"methodsCovered":0,"methodsTotal":0}],
"scannedFileCount":1}
"""
