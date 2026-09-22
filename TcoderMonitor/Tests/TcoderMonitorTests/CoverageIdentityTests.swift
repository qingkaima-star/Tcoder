import XCTest
@testable import TcoderMonitor

/// R5 · RD-25/26 的**身份层**：格式 / 运行 / 模块 三格 + 多语言测试路径判定。
/// （第四格"源码指纹"在 `CoverageSourceBinding.swift`，它的四态用例在 `CoverageMergeTests`。）
///
/// 这一层必须有**双向元测试**：只有"坏样例被抓到"的用例，会把规则改宽到什么都不抓也照样绿。
final class CoverageIdentityTests: XCTestCase {

    // MARK: - 格式身份

    func testEveryFileNameMapsToOneKnownFormat() {
        let table: [(String, CoverageReportFormat)] = [
            ("lcov.info", .lcov), ("lcov.dat", .lcov),
            ("coverage-summary.json", .istanbulSummary),
            ("jacoco.xml", .jacocoXml), ("jacocoTestReport.xml", .jacocoXml),
            ("coverage.xml", .coveragePyXml), ("clover.xml", .cloverXml),
        ]
        for (name, format) in table {
            XCTAssertEqual(CoverageReportFormat.identify(fileName: name), format, name)
        }
        // 反例：像覆盖率报告但不在清单里的名字，一律 `unrecognized`（不许猜格式）。
        for name in ["coverage.json", "lcov.txt", "jacoco.csv", "index.html", "cov.xml"] {
            XCTAssertEqual(CoverageReportFormat.identify(fileName: name), .unrecognized, name)
        }
    }

    /// 工具名要能对上 `CoverageAnalyzer` 实际写进报告的那些字（两侧不一致 ⇒ 界面上的
    /// "来源"会指错工具）。五种格式**各扫一次**：多份并存时总数只会留并集/那一份，
    /// 混在一起扫会把四种格式挤出去，测不到它们各自的工具名。
    func testToolNamesMatchWhatTheParsersActuallyWrite() async throws {
        let fixtures: [(String, String, CoverageReportFormat)] = [
            ("coverage/lcov.info", "SF:a.js\nLF:10\nLH:5\nend_of_record\n", .lcov),
            ("web/coverage/coverage-summary.json",
             #"{"total":{"lines":{"total":10,"covered":5}}}"#, .istanbulSummary),
            ("t/jacoco.xml", #"<report><counter type="LINE" missed="5" covered="5"/></report>"#, .jacocoXml),
            ("py/coverage.xml", #"<coverage lines-covered="5" lines-valid="10"/>"#, .coveragePyXml),
            ("legacy/clover.xml",
             #"<coverage><project><metrics statements="10" coveredstatements="5"/></project></coverage>"#,
             .cloverXml),
        ]
        XCTAssertEqual(Set(fixtures.map { $0.2 }), Set(CoverageReportFormat.allCases.filter {
            $0 != .unrecognized }), "五种格式没测全")
        for (path, body, format) in fixtures {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("r5-tool-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
            let metrics = try await CoverageAnalyzer().analyze(projectRoot: dir, options: .default)
            let report = try XCTUnwrap(metrics.reports.first, "格式 \(format.rawValue) 没被解析出来")
            XCTAssertEqual(report.toolName, format.toolName,
                           "格式 \(format.rawValue) 的工具名两侧不一致")
        }
    }

    // MARK: - 运行 / 模块身份

    func testModuleKeyDropsOnlyOutputDirectorySegments() throws {
        let root = URL(fileURLWithPath: "/repo")
        func module(_ path: String, _ kind: CoverageReport.Kind = .combined) throws -> String? {
            try XCTUnwrap(CoverageReportIdentity.derive(path: path, root: root, format: .lcov,
                                                        kind: kind).moduleKey)
        }
        XCTAssertEqual(try module("/repo/coverage/lcov.info"), "", "仓库根的 coverage/ ⇒ 全仓候选")
        XCTAssertEqual(try module("/repo/packages/pay/coverage/lcov.info"), "packages/pay")
        XCTAssertEqual(try module("/repo/app/build/reports/jacoco/jacoco.xml"), "app")
        XCTAssertEqual(try module("/repo/coverage/html/lcov.info"), "", "html 只是产物形式，不是模块")
        // **保守面**：尾巴上出现表里没有的段（Gradle 的 `test`）时停止剥离，模块键留在长形式。
        // 方向是故意的：宁可把同一次运行当成两次（分开呈现，最多数字重复），
        // 也不许把两次运行认成一次（去重会**丢掉证据**）。
        XCTAssertEqual(try module("/repo/server/build/reports/jacoco/test/jacoco.xml"),
                       "server/build/reports/jacoco/test")
        // 反例（误伤面）：目录名**含** coverage 不算产物段，否则模块键会被剥错。
        XCTAssertEqual(try module("/repo/services/coverage-payment/coverage/lcov.info"),
                       "services/coverage-payment")
        XCTAssertEqual(try module("/repo/latest/lcov.info"), "latest", "`latest` 不是 `test`")
    }

    /// 同一模块、同一归类、同一目录里共存的对偶格式 ⇒ 同一个 runKey（去重的前提）。
    func testCoPublishedFormatsShareOneRunKey() throws {
        let root = URL(fileURLWithPath: "/repo")
        let lcov = CoverageReportIdentity.derive(path: "/repo/web/coverage/lcov.info", root: root,
                                                 format: .lcov, kind: .combined)
        let json = CoverageReportIdentity.derive(path: "/repo/web/coverage/coverage-summary.json",
                                                 root: root, format: .istanbulSummary, kind: .combined)
        XCTAssertEqual(lcov.runKey, json.runKey, "一次 nyc 运行的两种落法必须认出同一来源")
        XCTAssertTrue(CoverageReportFormat.isCoPublishedPair(lcov.format, json.format))
        XCTAssertEqual(lcov.runKey, "module=web|kind=整体")
    }

    /// unit 与 integration 是**两次运行**，绝不能共用 runKey（否则会被去重成一份，
    /// 联合覆盖就永久丢失 —— 那是另一种漏报）。
    func testUnitAndIntegrationRunsAreNeverCollapsed() throws {
        let root = URL(fileURLWithPath: "/repo")
        let unit = CoverageReportIdentity.derive(path: "/repo/coverage/unit/lcov.info", root: root,
                                                 format: .lcov, kind: .unit)
        let integration = CoverageReportIdentity.derive(path: "/repo/coverage/integration/lcov.info",
                                                        root: root, format: .lcov, kind: .integration)
        XCTAssertNotEqual(unit.runKey, integration.runKey)
        XCTAssertNotEqual(CoverageReportFormat.lcov, CoverageReportFormat.coveragePyXml,
                          "不同工具不是一对对偶落法")
        XCTAssertFalse(CoverageReportFormat.isCoPublishedPair(.lcov, .coveragePyXml))
        XCTAssertFalse(CoverageReportFormat.isCoPublishedPair(.lcov, .lcov),
                       "同格式的重名靠 runKey 相同即可判重，不需要对偶表放行")
    }

    /// 推不出来的必须显式未知：报告不在被扫目录之下 ⇒ 没有 runKey、没有模块键。
    func testIdentityOutsideTheScannedRootStaysUnknown() throws {
        let root = URL(fileURLWithPath: "/repo")
        let foreign = CoverageReportIdentity.derive(path: "/elsewhere/lcov.info", root: root,
                                                    format: .lcov, kind: .combined)
        XCTAssertNil(foreign.runKey, "路径切不出可信相对形状 ⇒ 未知，不许凭猜合并")
        XCTAssertNil(foreign.moduleKey)
        XCTAssertFalse(foreign.isRepositoryWide)
    }

    func testAggregateFormatsDeclareNoPerFileGranularity() {
        XCTAssertTrue(CoverageReportFormat.lcov.carriesPerSourceFileRecords)
        for format in [CoverageReportFormat.istanbulSummary, .jacocoXml, .coveragePyXml,
                       .cloverXml, .unrecognized] {
            XCTAssertFalse(format.carriesPerSourceFileRecords, "\(format.rawValue) 没有文件粒度")
        }
    }

    // MARK: - 多语言测试路径（RD-26）

    /// 正向表：这些路径一律算测试码，**不许进生产码分母**。
    func testKnownTestPathsAreExcludedFromProductionScope() {
        let needles = [
            "src/app.test.ts", "src/App.test.tsx", "src/old.test.js", "src/modern.test.mjs",
            "src/app.spec.ts", "src/view.spec.tsx", "src/legacy.spec.jsx",
            "src/__tests__/helper.ts", "web/test/unit.ts", "web/tests/a.py",
            "src/test/java/com/acme/OrderTest.java",           // Maven 标准测试根
            "src/test/kotlin/com/acme/OrderTest.kt",
            "src/it/java/com/acme/PaymentIT.java",             // Maven 验收集成测试
            "app/src/androidTest/java/com/acme/LoginTest.kt",
            "src/main/java/com/acme/WidgetTest.java",
            "tests/test_order.py", "src/handler_test.py",
            "store/item_test.go", "lib/deep_test.rb", "user_spec.rb",
            "crate/tests/it.rs", "src/test/JavaThingsTests.swift",
            "pkg/a/__mocks__/fs.ts",
        ]
        var hits = 0
        for path in needles {
            XCTAssertTrue(CoverageTestPathRules.isTestSource(path: path), "漏报：\(path)")
            XCTAssertFalse(CoverageSourceScope.isProductionSource(path: path), "仍进分母：\(path)")
            hits += 1
        }
        XCTAssertGreaterThanOrEqual(hits, 20, "正向表缩水了，这条守卫就没覆盖面")
    }

    /// 反向表（**合法写法不误伤**）：这些是真生产码。
    /// 每一条都对应一种朴素质疑会犯的错：子串匹配 `test`/`spec`、大小写不分、段匹配写成包含。
    func testProductionPathsAreNeverMistakenForTests() {
        let production = [
            "src/latest.ts", "src/progress.ts", "src/contest.ts", "src/harvest.ts",   // 含 "test" 子串
            "src/special.ts", "src/aspect.ts", "src/specification.ts",                // 含 "spec" 子串
            "src/Latest.java", "src/Contest.java", "src/Request.java",                // 结尾小写 test.java
            "src/tester/Runner.ts", "src/latest/data.ts", "src/specifications/x.ts",  // 目录名含 test/spec
            "src/testbed/Main.kt", "src/tests-helpers/README.md",                     // 不是精确段名
            "testbed/app.ts", "src/testing/framework.ts",
            "src/main/java/com/acme/OrderService.java", "src/testutil/Helper.java",
            "protest.py", "src/mytest.go", "src/report_test_data.py",
        ]
        var checked = 0
        for path in production {
            XCTAssertFalse(CoverageTestPathRules.isTestSource(path: path), "误伤生产码：\(path)")
            XCTAssertTrue(CoverageSourceScope.isProductionSource(path: path), "被踢出分母：\(path)")
            checked += 1
        }
        XCTAssertGreaterThanOrEqual(checked, 15, "反向表缩水 ⇒ 这条守卫没在管任何东西")
    }

    /// 冻结区那四条 Swift 规则必须**一字不改地继续生效**（叠加层不许把它们削弱）。
    func testFrozenSwiftRulesStillApplyThroughTheExtension() {
        for path in ["repo/Tests/XTests.swift", "repo/PackageTests.swift", "repo/.build/Derived/m.swift",
                     "Sources/LegacyTests.swift"] {
            XCTAssertFalse(CoverageScope.isProductionSource(path: path), "契约口径本身就漏了：\(path)")
            XCTAssertFalse(CoverageSourceScope.isProductionSource(path: path), "叠加层把它放回来了：\(path)")
        }
        XCTAssertTrue(CoverageScope.isProductionSource(path: "Sources/App/File.swift"))
        XCTAssertTrue(CoverageSourceScope.isProductionSource(path: "Sources/App/File.swift"))
    }

    /// 空路径按"不确定的不算生产码"处理（沿用契约里的判定，不自己放宽）。
    func testEmptyPathStaysNonProduction() {
        XCTAssertFalse(CoverageTestPathRules.isTestSource(path: ""))
        XCTAssertFalse(CoverageSourceScope.isProductionSource(path: ""))
    }

    /// `DA:` 的行号解析：命中位不是数字（少数工具写 `-`）时按**未命中**处理，
    /// 行仍然进分母（它是可执行行）。这条直接打账本，不经过分析器，免得把两件事混在一条里。
    func testUnknownHitCountIsTreatedAsMissNotHit() throws {
        var tally = CoverageAnalyzer.LCovTally(root: URL(fileURLWithPath: "/repo"))
        for line in "SF:/repo/src/a.ts\nDA:1,5\nDA:2,-\nDA:3,0\nLF:3\nLH:1\nend_of_record\n"
            .split(separator: "\n") {
            tally.consume(String(line))
        }
        let record = try XCTUnwrap(tally.ledger.files["src/a.ts"])
        XCTAssertEqual(record.foundLines, [1, 2, 3], "`-` 也是可执行行，要进分母")
        XCTAssertEqual(record.hitLines, [1], "非数字命中位按未命中算")
        XCTAssertTrue(tally.ledger.isMergeSafe)
        XCTAssertEqual(record.isProduction, true)
    }

    /// `SF:` 之外冒出来的 LF/LH：这份 lcov 的汇总数与文件清单对不上 ⇒ 账本整体降级。
    func testOrphanCountsMakeTheLedgerUntrustworthy() throws {
        var tally = CoverageAnalyzer.LCovTally(root: URL(fileURLWithPath: "/repo"))
        for line in "LF:50\nLH:20\nSF:/repo/src/a.ts\nLF:10\nLH:5\nend_of_record\n"
            .split(separator: "\n") {
            tally.consume(String(line))
        }
        XCTAssertFalse(tally.ledger.isMergeSafe, "缺了文件的账本去做并集 = 少算东西的伪精确总数")
        XCTAssertEqual(tally.ledger.orphanAggregateFound, 50)
    }

}
