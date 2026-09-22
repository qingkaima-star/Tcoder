import XCTest
@testable import TcoderMonitor

/// R5 覆盖率链的**场景夹具库**：六条验收场景各一份，全部是本文件手写的内容，
/// 真值写在每个场景的 `truth` 字段里（独立于实现，不拿分析器自己的输出当真值）。
///
/// 为什么单独一个文件：`CoverageMergeTests`（in-process 读数）、
/// `CoverageChainProofTests`（真子进程 + JSON 对表）、以及后续回归都要吃同一批夹具；
/// 三处各写一遍必然漂（本仓踩过"两份手算账对不上"）。
struct CoverageScenarioFixture {
    var name: String
    /// 相对路径 → 文件内容。
    var reportFiles: [String: String]
    /// 手算真值：计分分母 / 分子（生产码口径）。`nil` = 该场景**不该给出总数**。
    var truth: (covered: Int, total: Int)?
    /// 该场景应当被丢弃/未并入的报告份数（手算，与 `reportFiles.count` 一起对账）。
    var expectedDropped: Int

    @discardableResult
    func install(into base: URL) -> URL {
        for (path, body) in reportFiles {
            let url = base.appendingPathComponent(path)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? body.write(to: url, atomically: true, encoding: .utf8)
        }
        return base
    }

    func installedPaths(in base: URL) -> [String] {
        reportFiles.keys.map { base.appendingPathComponent($0).path }.sorted()
    }
}

enum CoverageMergeFixtures {
    /// lcov 里一段带 `DA:` 的文件记录。`hits` 为命中行号。
    static func file(_ path: String, lines: ClosedRange<Int>, hits: Set<Int>) -> String {
        var text = "SF:\(path)\n"
        for line in lines { text += "DA:\(line),\(hits.contains(line) ? 1 : 0)\n" }
        text += "LF:\(lines.count)\nLH:\(hits.filter { lines.contains($0) }.count)\nend_of_record\n"
        return text
    }

    static func file(_ path: String, found: Int, hit: Int) -> String {
        "SF:\(path)\nLF:\(found)\nLH:\(hit)\nend_of_record\n"
    }

    // MARK: ①　同一次运行的两种落法

    static let sameRunTwoFormats = CoverageScenarioFixture(
        name: "双格式同源（一次 nyc 运行）",
        reportFiles: [
            "web/coverage/lcov.info": file("src/app.js", found: 100, hit: 60)
                + file("src/util.js", found: 100, hit: 60),
            "web/coverage/coverage-summary.json":
                #"{"total":{"lines":{"total":200,"covered":120},"branches":{"total":40,"covered":20}}}"#,
        ],
        truth: (120, 200), expectedDropped: 1)

    // MARK: ②　全仓 + 模块并存

    static let wholeRepoPlusModules = CoverageScenarioFixture(
        name: "全仓 + 三模块",
        reportFiles: [
            "coverage/lcov.info": file("src/a.js", found: 200, hit: 100)
                + file("src/b.js", found: 200, hit: 100)
                + file("src/c.js", found: 200, hit: 100),
            "pkgs/a/coverage/lcov.info": file("src/a.js", found: 200, hit: 100),
            "pkgs/b/coverage/lcov.info": file("src/b.js", found: 200, hit: 100),
            "pkgs/c/coverage/lcov.info": file("src/c.js", found: 200, hit: 100),
        ],
        truth: (300, 600), expectedDropped: 0)

    // MARK: ③　unit / integration 命中集合重叠

    static let unitIntegrationOverlap = CoverageScenarioFixture(
        name: "unit 与集成重叠（按行求并）",
        reportFiles: [
            "coverage/unit/lcov.info": file("src/shared.js", lines: 1...100, hits: Set(1...60)),
            "coverage/integration/lcov.info": file("src/shared.js", lines: 1...100, hits: Set(41...100))
                + file("src/only-it.js", lines: 1...20, hits: Set(1...10)),
        ],
        truth: (110, 120), expectedDropped: 0)

    // MARK: ④　七个以上模块

    static let nineModules: CoverageScenarioFixture = {
        var files: [String: String] = [:]
        for module in ["a", "b", "c", "d", "e", "f", "g", "h"] {
            files["pkg-\(module)/coverage/lcov.info"] = file("src/\(module)/core.js", found: 100, hit: 50)
        }
        return CoverageScenarioFixture(name: "8 个模块（旧实现只留 6 份）", reportFiles: files,
                                       truth: (400, 800), expectedDropped: 0)
    }()

    // MARK: ⑤　多语言测试路径

    /// 生产码 3 份 × 100 行、命中 50 ⇒ **150/300 = 50%**；
    /// 测试码 7 份 × 100 行、全命中 ⇒ 混进分母就是 850/1000 = 85%（修前读数）。
    /// 反面对照（**不许误伤**）：`src/latest.ts`、`src/testutil/Helper.java` 这类路径留在
    /// `CoverageIdentityTests.testProductionPathsAreNeverMistakenForTests` 里逐条钉。
    static let multilanguageTestPaths = CoverageScenarioFixture(
        name: "多语言测试路径",
        reportFiles: [
            "coverage/lcov.info": [
                file("src/app.ts", found: 100, hit: 50),
                file("src/App.java", found: 100, hit: 50),
                file("src/main.py", found: 100, hit: 50),
                file("src/app.test.ts", found: 100, hit: 100),
                file("src/app.spec.ts", found: 100, hit: 100),
                file("src/main.spec.tsx", found: 100, hit: 100),
                file("src/__tests__/helper.ts", found: 100, hit: 100),
                file("src/test/java/com/acme/OrderTest.java", found: 100, hit: 100),
                file("src/test/kotlin/com/acme/OrderTest.kt", found: 100, hit: 100),
                file("tests/py/test_order.py", found: 100, hit: 100),
            ].joined(),
        ],
        truth: (150, 300), expectedDropped: 0)

    // MARK: ⑥　全汇总粒度、无法核对重叠

    static let aggregateOnly = CoverageScenarioFixture(
        name: "四份汇总粒度（无法核对重叠 ⇒ 不给总数）",
        reportFiles: [
            "web/coverage/coverage-summary.json": #"{"total":{"lines":{"total":400,"covered":340}}}"#,
            "server/target/jacoco.xml": #"<report><counter type="LINE" missed="300" covered="700"/></report>"#,
            "py/coverage.xml": #"<coverage lines-covered="620" lines-valid="1000"/>"#,
            "legacy/clover.xml": #"<coverage><project><metrics statements="500" coveredstatements="425"/></project></coverage>"#,
        ],
        truth: nil, expectedDropped: 4)

    /// 六条验收场景 + 重叠无逐行证据的冲突态。
    static let all: [CoverageScenarioFixture] = [
        sameRunTwoFormats, wholeRepoPlusModules, unitIntegrationOverlap,
        nineModules, multilanguageTestPaths, aggregateOnly,
    ]
}

/// 这条用例只为把"夹具库本身不是空的、真值不是 0"钉住：
/// 空夹具库会让上面所有依赖它的用例变成永真绿（本仓反复踩过的病）。
final class CoverageScenarioFixturesTests: XCTestCase {
    func testFixtureLibraryIsNotEmptyAndTruthsArePositive() throws {
        XCTAssertGreaterThanOrEqual(CoverageMergeFixtures.all.count, 6)
        for scenario in CoverageMergeFixtures.all {
            XCTAssertFalse(scenario.reportFiles.isEmpty, "场景「\(scenario.name)」没有文件")
            guard let truth = scenario.truth else { continue }
            XCTAssertGreaterThan(truth.total, 0, "场景「\(scenario.name)」的真值分母为 0，测不出任何东西")
            XCTAssertLessThanOrEqual(truth.covered, truth.total, "真值分子大于分母：\(scenario.name)")
        }
        let overlap = CoverageMergeFixtures.unitIntegrationOverlap
        XCTAssertEqual(overlap.truth?.total, 120, "重叠场景的真值要先算错，用例才会跟着错")
    }

    /// 场景⑤ 的"测试码"必须是**真的**被算进全量分母的（否则它测不到"排除"这件事）。
    func testMultilanguageScenarioActuallyContainsTestCodeRecords() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("r5-fixture-meta-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        CoverageMergeFixtures.multilanguageTestPaths.install(into: base)
        let metrics = try await CoverageAnalyzer().analyze(projectRoot: base, options: .default)
        let report = try XCTUnwrap(metrics.reports.first)
        XCTAssertEqual(report.allLinesTotal, 1000, "全量分母要含那 7 份测试码记录")
        XCTAssertEqual(report.linesTotal, 300, "计分分母只剩 3 份生产码")
        XCTAssertGreaterThan((report.allLinesTotal ?? 0) - report.linesTotal, 0,
                             "两个口径相等说明测试码排除这条判定根本没生效")
    }
}
