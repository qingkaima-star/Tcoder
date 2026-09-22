import XCTest
@testable import TcoderMonitor

/// R15 · **RD-51 + RD-55** —— 同一件「有东西被上限摘掉」的事实，全站只许长成一句话说一次。
///
/// # 立案时读到的现场（不是猜的）
/// 修前同一个 `droppedByCap == 3` 有三个出口、两套措辞：
///   · 覆盖率页尾与 CLI（`boardAccountingNote` → `statementParts`）：
///     「另有 3 份未合并：<三条相对路径>等（逐条清单见 undisplayedReports）」；
///   · 健康页（`displayDisclosureText` → `capDisclosureText`）：
///     「另有 3 份未合并（逐条点名见 undisplayedReports）」——**声称逐条点名却一个名字都不给**，
///     而且丢掉「⇒ 这里说的『没找到报告』不等于『该项目没有覆盖率报告』」那半边（RD-26 要的退让句）。
/// 另一条 RD-55：`absenceClaimIsSound` 生产侧零读者，健康页那一维的结论句
/// 先印「该项目没有产出覆盖率报告」，再印一句把它推翻的话 —— 两本账在同一句话里打脸。
///
/// # 真值从哪来
/// 夹具是本文件自己写进 `.scratch/` 的 43 份 lcov；「被丢下的是哪三份」
/// 由测试把自己写出的相对路径自己排序取末尾三个算出来，不读实现输出当答案。
/// 上限那枚数取产品侧常量 `CoverageReportDiscovery.maxReportFiles`，这里不抄字面量。
final class CoverageDisclosureRulerTests: SelfScanHarnessCase {

    private var root: URL!
    private var cap: Int { CoverageReportDiscovery.maxReportFiles }

    override func setUpWithError() throws {
        root = Self.repoRoot.appendingPathComponent(".scratch/r15-disclosure-\(UUID().uuidString)",
                                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - 夹具

    private func writeModule(_ index: Int) throws {
        let directory = root.appendingPathComponent("m\(index)/coverage", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "SF:src/m\(index)/a.js\nLF:10\nLH:5\nend_of_record\n"
            .write(to: directory.appendingPathComponent("lcov.info"), atomically: true, encoding: .utf8)
    }

    /// 独立真值：自己写出的那批路径按字典序排完，取落在上限之外的三份。
    private func droppedTruth(count: Int) -> [String] {
        ((0..<count).map { "m\($0)/coverage/lcov.info" }).sorted().suffix(3).map { $0 }
    }

    private func scanned() async throws -> CoverageMetrics {
        try await CoverageAnalyzer().analyze(projectRoot: root, options: .default)
    }

    /// 手工凑一本"量过的账"（六格齐全），用来走确定性措辞路径。
    private func ledger(unmeasuredScope: String?, dropped: Int, coordinates: [String]) -> CoverageMetrics {
        var metrics = CoverageMetrics(reports: [], scannedFileCount: 0)
        metrics.truncationTotalCount = dropped
        metrics.displayedCount = 0
        metrics.undisplayedCount = dropped
        metrics.droppedByCap = dropped
        metrics.undisplayedReports = coordinates
        metrics.unexaminedDirectories = coordinates.isEmpty ? ["locked"] : []
        metrics.unmeasuredScope = unmeasuredScope
        return metrics
    }

    // MARK: - RD-51 正例：真扫一次，两个出口逐字同一句

    func test_bothExitsQuoteOneByteIdenticalSentence() async throws {
        for index in 0..<(cap + 3) { try writeModule(index) }
        let metrics = try await scanned()
        XCTAssertEqual(metrics.droppedByCap, 3, "夹具自检：写 43 份、上限 \(cap) 份 ⇒ 丢 3 份")

        let coveragePage = try XCTUnwrap(metrics.boardAccountingNote)
        let healthPage = try XCTUnwrap(metrics.displayDisclosureText)
        XCTAssertEqual(coveragePage, healthPage,
                       "同一个数在两页长成两句话（RD-51 就是这句）")
        for coordinate in droppedTruth(count: cap + 3) {
            XCTAssertTrue(healthPage.contains(coordinate),
                          "健康页那句必须与覆盖率页一样点名坐标：\(coordinate) / \(healthPage)")
        }
        // 旧那套"声称点名却不点名"的写法不许在任何一侧复活。
        XCTAssertFalse(coveragePage.contains("逐条点名见"), coveragePage)

        // 第三个出口：CLI 打的还是同一句（`score` 文本走 `boardAccountingNote`）。
        var report = ProjectReport(project: MonitoredProject(name: "夹具", path: root.path))
        report.coverage = metrics
        XCTAssertTrue(CLIScoreText.render(report, exit: .ok).contains(coveragePage),
                      "CLI 没原样打装配口那句 = 第四把尺子")
    }

    // MARK: - RD-51 反例：措辞只有一处生产者，另两格只能是转发

    func test_capSentenceHasExactlyOneProducerAndTwoForwards() {
        let shape = CoverageDisplayShape(truncationTotalCount: 5, displayedCount: 3, undisplayedCount: 2,
                                         undisplayedReports: ["a/lcov.info", "b/lcov.info"],
                                         unexaminedDirectories: [], droppedByCap: 2,
                                         unmeasuredScope: nil)
        let one = CoverageDisplayShape.capSentence(dropped: 2,
                                                   coordinates: ["a/lcov.info", "b/lcov.info"])
        XCTAssertEqual(one, "另有 2 份未合并：a/lcov.info、b/lcov.info（已点名）",
                       "独立真值是手写的一句话（改措辞要连着改这里，不许拿实现输出当答案）")
        XCTAssertEqual(shape.statementParts.first, one, "形状侧没走唯一生产者")

        var metrics = CoverageMetrics(reports: [], scannedFileCount: 0)
        metrics.droppedByCap = 2
        metrics.undisplayedReports = ["a/lcov.info", "b/lcov.info"]
        XCTAssertEqual(metrics.capDisclosureText, one, "字段侧没走唯一生产者（RD-51 的旧形状）")
    }

    /// 计数在、坐标不在 ⇒ 不许装作点过名。
    func test_countWithoutCoordinatesRefusesToClaimNames() {
        let text = CoverageDisplayShape.capSentence(dropped: 3, coordinates: [])
        XCTAssertTrue(text.contains("3 份未合并"), text)
        XCTAssertTrue(text.contains("点不出名"), "把「没记坐标」混进「都点名了」：\(text)")
        XCTAssertFalse(text.contains("已点名"), text)
        XCTAssertFalse(text.contains("逐条清单见"), "把读者指向一份根本不存在的清单：\(text)")
    }

    // MARK: - RD-55：结论句必须先问自己那枚判据

    /// 有目录没看 / 有报告被摘掉 ⇒「该项目没有产出覆盖率报告」这句**不成立**，
    /// 健康页那一维的结论必须自己收窄范围，并且把退让句一起带上来。
    func test_unsoundAbsenceIsNotPrintedAsAbsence() throws {
        let metrics = ledger(unmeasuredScope: "1 个目录读不动（权限或已消失）",
                             dropped: 1, coordinates: ["locked/coverage/lcov.info"])
        XCTAssertFalse(metrics.absenceClaimIsSound, "判据本身要成立，否则下面那条断言是空转")

        let note = try XCTUnwrap(MissingDimensionReason.testingAbsence(coverage: metrics))
        XCTAssertFalse(note.contains("该项目没有产出覆盖率报告"),
                       "被自己字段判为不成立的结论照样上屏：\(note)")
        XCTAssertTrue(note.contains("看得见的部分里没有发现覆盖率报告"), note)
        XCTAssertTrue(note.contains("不等于「该项目没有覆盖率报告」"),
                      "RD-26 要的退让句必须跟着上屏：\(note)")
    }

    /// 反方向：六格齐全、什么都没被摘掉 ⇒ 原来那句「没有产出」必须还在，
    /// 不许为了"少说错话"把两句反过来贴（那等于把一句真话也改没了）。
    func test_soundAbsenceStillUsesThePlainSentence() throws {
        var metrics = CoverageMetrics(reports: [], scannedFileCount: 0)
        metrics.truncationTotalCount = 0
        metrics.displayedCount = 0
        metrics.undisplayedCount = 0
        metrics.droppedByCap = 0
        metrics.undisplayedReports = []
        metrics.unexaminedDirectories = []
        XCTAssertTrue(metrics.absenceClaimIsSound)
        XCTAssertNil(metrics.displayDisclosureText, "扫描面完整 ⇒ 一个字都不许多")

        let note = try XCTUnwrap(MissingDimensionReason.testingAbsence(coverage: metrics))
        XCTAssertEqual(note, "该项目没有产出覆盖率报告，不参与计分。", note)
    }

    // MARK: - 结构守卫：健康页也不许手写披露句（RD-51 的第二层网）

    func test_healthSideNeverRewritesTheDisclosureSentence() throws {
        let files = try swiftFiles(under: "Sources/TcoderMonitor/Services/Health")
        XCTAssertGreaterThan(files.count, 3, "扫不到 Services/Health ⇒ 这条在空跑")
        for file in files {
            let hits = CoverageAccountingReadoutTests.disclosureHits(
                in: (try? String(contentsOf: file, encoding: .utf8)) ?? "")
            XCTAssertTrue(hits.isEmpty,
                          "健康分那一路手写了披露句 = 第二把尺子：\(file.lastPathComponent) \(hits)")
        }
        let health = try source("Sources/TcoderMonitor/Services/Health/HealthBreakdown.swift")
        XCTAssertTrue(health.contains("coverage.displayDisclosureText"),
                      "健康页没再读同一把尺子（RD-51 原地复活）")
    }

    // MARK: - 小工具

    private func swiftFiles(under relative: String) throws -> [URL] {
        let base = Self.repoRoot.appendingPathComponent("TcoderMonitor/" + relative, isDirectory: true)
        guard let walk = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else {
            XCTFail("扫不到 \(relative) —— 这条扫描守卫会在空跑")
            return []
        }
        return walk.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent("TcoderMonitor/" + relative),
                   encoding: .utf8)
    }
}
