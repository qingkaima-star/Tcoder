// OWNER: R3 依赖证据链 · 查询身份与回填对账（RD-12 / RD-11）
//
// **不打真网**：所有在线结局都走 `DependencyOnlineSource` 这条注入缝（假源）。
// 真打网络的那一条留给 `DependencyNetworkLiveTests`（默认轮次自动跳过，有明确理由）。
//
// 本文件的主案是第一条用例：它同时读**总览**（`report.advisories`）与**依赖行**
// （该包的 `knownVulnerabilities` / 行状态），因为 RD-12 的症状就是
// "总览有公告、依赖行不标记" —— 只修一边必然测不出来。
import XCTest
@testable import TcoderMonitor

/// 假源：按**查询身份**回执，行为与 `LiveDependencyOnlineSource` 同形。
///
/// 用 class 而不是 struct：分析器拿到的是引用，测试才能回读"它到底发了哪些查询身份"
/// （RD-12 的判据就在这一格里）。单用例内串行 await，无并发写，`@unchecked Sendable` 成立。
final class StubOnlineSource: DependencyOnlineSource, @unchecked Sendable {
    /// coordinate -> 该坐标带回的公告。
    var answered: [String: [SecurityAdvisory]] = [:]
    /// 明确失败的坐标。
    var failedCoordinates: [String] = []
    var latestVersions: [String: String] = [:]
    var registryFailures: [String] = []

    private(set) var receivedOsvQueries: [OsvPackageQuery] = []
    private(set) var receivedNpmPackages: [String] = []

    init(answered: [String: [SecurityAdvisory]] = [:], failedCoordinates: [String] = [],
         latestVersions: [String: String] = [:], registryFailures: [String] = []) {
        self.answered = answered
        self.failedCoordinates = failedCoordinates
        self.latestVersions = latestVersions
        self.registryFailures = registryFailures
    }

    func registryLatestVersions(for packages: [String]) async -> DependencyOnlineReceipt {
        receivedNpmPackages = packages
        var receipt = DependencyOnlineReceipt()
        receipt.latestVersions = Dictionary(uniqueKeysWithValues: packages.compactMap { name in
            latestVersions[name].map { (name, $0) }
        })
        receipt.failedRegistryPackages = registryFailures
        return receipt
    }

    /// 与 `LiveDependencyOnlineSource.osvAdvisories` **同形**：每条发出去的查询都必须有结局，
    /// 没点名失败的那些落 `.answered(空)`（批量端点按顺序逐条回答，空数组就是干净）。
    /// 真源在"答不上但说不清是哪几条"时会更保守（整批判 `.failed`），那条差异由
    /// `DependencyEvidenceTests.testLiveSourceIsNotLessConservativeThanTheStub` 单独钉住 ——
    /// 假源永远不许比生产实现**更乐观**，否则用例全绿而线上是假的。
    func osvAdvisories(for queries: [OsvPackageQuery]) async -> DependencyOnlineReceipt {
        receivedOsvQueries = queries
        var receipt = DependencyOnlineReceipt()
        for query in queries {
            let key = query.coordinate
            if let advisories = answered[key] {
                receipt.osvOutcomes[key] = .answered(advisories: advisories)
            } else if failedCoordinates.contains(key) {
                receipt.osvOutcomes[key] = .failed
            } else {
                receipt.osvOutcomes[key] = .answered(advisories: [])
            }
        }
        receipt.osvPathUnavailable = !failedCoordinates.isEmpty
        return receipt
    }
}

/// 测试用公告构造器：`affectedPackages` 一律用**规范坐标**（与真源同格式）。
func stubAdvisory(id: String, coordinate: String, aliases: [String] = [],
                  ecosystem: DependencyEcosystem = .npm, severity: RiskLevel = .high) -> SecurityAdvisory {
    SecurityAdvisory(id: id, aliases: aliases, summary: "夹具公告 \(id)", details: "",
                     severity: severity, cvssScore: nil, affectedPackages: [coordinate],
                     ecosystem: ecosystem, publishedAt: nil, source: "stub")
}

final class DependencyBackfillIdentityTests: XCTestCase {

    // MARK: - 主案：总览有公告，依赖行必须同时被标记

    func testAdvisoryInOverviewAlsoMarksTheRow() async throws {
        // 真值（手写）：package.json 声明 `left-pad: ^1.2.3`，OSV 对**查询用的下界版本 1.2.3**
        // 回了一条 GHSA-leftpad。旧实现在这里必然漏标：公告侧 key 是 `left-pad@1.2.3`、
        // 回填侧查的是 `left-pad@^1.2.3` ⇒ 永不相等。
        // 故意选内置表**没有**的包：这样行上那串 CVE 只可能来自在线回填，
        // 不会被"内置规则本来就命中"混进同一格（用 lodash 就测不出这条链）。
        let root = try makeTree("backfill-main", files: [
            "package.json": #"{"name":"app","dependencies":{"left-pad":"^1.2.3"}}"#,
        ])
        let coordinate = DependencyVersionIdentity.coordinate(ecosystem: .npm, name: "left-pad",
                                                             queryVersion: "1.2.3")
        let stub = StubOnlineSource(answered: [coordinate: [
            stubAdvisory(id: "GHSA-leftpad-0001", coordinate: coordinate, aliases: ["CVE-2099-0001"]),
        ]])
        let report = try await analyze(root, stub: stub)

        XCTAssertFalse(report.advisories.isEmpty, "前提：总览确实带回了公告")
        let row = try XCTUnwrap(record(report, "left-pad"))
        XCTAssertTrue(row.knownVulnerabilities.contains("CVE-2099-0001"),
                      "总览有公告而依赖行没标记 = RD-12 的原始症状，实得 \(row.knownVulnerabilities)")
        XCTAssertEqual(DependencyRowStatus.of(row), .vulnerable(count: 1),
                       "行状态必须跟着公告走，不是跟着『版本数据从哪来』走")
        XCTAssertEqual(DependencyEvidence.vulnerabilityState(of: row), .checked)
    }

    /// 同包多版本：**只有一个版本有公告**，不得错绑到没有的那条。
    func testAdvisoryBindsOnlyToTheVersionThatHasIt() async throws {
        let root = try makeTree("backfill-two-versions", files: [
            "package.json": #"{"name":"app","dependencies":{"left-pad":"^1.2.3"}}"#,
            "web/package.json": #"{"name":"web","dependencies":{"left-pad":"1.2.9"}}"#,
        ])
        let vulnerableCoordinate = DependencyVersionIdentity.coordinate(ecosystem: .npm, name: "left-pad",
                                                                       queryVersion: "1.2.3")
        let cleanCoordinate = DependencyVersionIdentity.coordinate(ecosystem: .npm, name: "left-pad",
                                                                  queryVersion: "1.2.9")
        let stub = StubOnlineSource(answered: [
            vulnerableCoordinate: [stubAdvisory(id: "GHSA-a", coordinate: vulnerableCoordinate,
                                               aliases: ["CVE-2099-0002"])],
            cleanCoordinate: [],        // 答上了、且干净
        ], latestVersions: ["left-pad": "1.2.9"])   // registry 答上 ⇒ 版本那一路才算"已核对"
        let report = try await analyze(root, stub: stub)
        let old = try XCTUnwrap(recordFrom(root: report, manifest: "package.json", name: "left-pad"))
        let fresh = try XCTUnwrap(recordFrom(root: report, manifest: "web/package.json", name: "left-pad"))
        XCTAssertEqual(old.knownVulnerabilities, ["CVE-2099-0002"], "有公告的那条要标上")
        XCTAssertTrue(fresh.knownVulnerabilities.isEmpty, "同包另一版本确实干净，不得被错绑")
        XCTAssertEqual(DependencyRowStatus.of(old), .vulnerable(count: 1))
        XCTAssertEqual(DependencyEvidence.versionState(of: fresh), .checked,
                       "精确声明 ⇒ 安装版本就是它，版本这一路可比对")
        XCTAssertEqual(DependencyRowStatus.of(fresh), .verifiedSafe, "两路都核对过且无命中才允许发绿")
    }

    /// 同包多清单、同一声明范围：两条都要各自被标记（不得只标第一条）。
    func testSamePackageInTwoManifestsBothMarked() async throws {
        let root = try makeTree("backfill-two-manifests", files: [
            "package.json": #"{"name":"app","dependencies":{"axios":"^0.21.0"}}"#,
            "svc/package.json": #"{"name":"svc","dependencies":{"axios":"^0.21.0"}}"#,
        ])
        let coordinate = DependencyVersionIdentity.coordinate(ecosystem: .npm, name: "axios",
                                                             queryVersion: "0.21.0")
        let stub = StubOnlineSource(answered: [coordinate: [
            stubAdvisory(id: "GHSA-axios", coordinate: coordinate, aliases: ["CVE-2099-0003"]),
        ]])
        let report = try await analyze(root, stub: stub)
        let hits = report.ecosystems.flatMap(\.dependencies).filter { !$0.knownVulnerabilities.isEmpty }
        XCTAssertEqual(hits.count, 2, "两份清单各一条声明，就该各标一次")
        XCTAssertEqual(Set(hits.map(\.manifestPath)), ["package.json", "svc/package.json"])
    }

    /// 锁文件解析值优先于声明下界：查询用的必须是**装的那个**版本。
    func testQueryUsesLockedVersionNotDeclaredLowerBound() async throws {
        let root = try makeTree("backfill-locked", files: [
            "package.json": #"""
            {"name":"app","dependencies":{"left-pad":"^1.2.3"}}
            """#,
            "package-lock.json": #"""
            {"lockfileVersion":3,"packages":{"":{"dependencies":{"left-pad":"^1.2.3"}},
             "node_modules/left-pad":{"version":"1.2.9"}}}
            """#,
        ])
        let lockedCoordinate = DependencyVersionIdentity.coordinate(ecosystem: .npm, name: "left-pad",
                                                                   queryVersion: "1.2.9")
        let stub = StubOnlineSource(answered: [lockedCoordinate: [
            stubAdvisory(id: "GHSA-leftpad", coordinate: lockedCoordinate, aliases: ["CVE-2099-0004"]),
        ]])
        
        let report = try await analyze(root, stub: stub)
        XCTAssertEqual(stub.receivedOsvQueries.map(\.version), ["1.2.9"],
                       "查询身份要用锁文件解析出的 1.2.9，不是声明下界 1.2.3")
        let row = try XCTUnwrap(record(report, "left-pad"))
        XCTAssertEqual(row.resolvedVersion, "1.2.9")
        XCTAssertEqual(row.knownVulnerabilities, ["CVE-2099-0004"], "公告按同源的 key 回到这一条上")
    }

    // MARK: - npm 成功不得冒充 OSV 成功（RD-11）

    func testRegistrySuccessDoesNotImplyVulnerabilityCoverage() async throws {
        // 声明写成**精确版本**：这条用例只管"npm 成功 ≠ OSV 成功"，
        // 不许把"范围没解析成安装版本"那件事混进来（那是另一格，见
        // `testAdvisoryInOverviewAlsoMarksTheRow` 与 `versionState` 的 `.versionUnresolved` 支）。
        let root = try makeTree("npm-vs-osv", files: [
            "package.json": #"{"name":"app","dependencies":{"semver":"7.5.0"}}"#,
        ])
        // registry 答上了最新版；OSV 这一路对该坐标**失败**。
        let coordinate = DependencyVersionIdentity.coordinate(ecosystem: .npm, name: "semver",
                                                             queryVersion: "7.5.0")
        let stub = StubOnlineSource(failedCoordinates: [coordinate], latestVersions: ["semver": "7.6.3"])
        let report = try await analyze(root, stub: stub)
        let row = try XCTUnwrap(record(report, "semver"))
        XCTAssertEqual(row.versionCheckSource, .onlineRegistry, "版本这一路确实成功了")
        XCTAssertEqual(DependencyEvidence.versionState(of: row), .checked)
        XCTAssertEqual(DependencyEvidence.vulnerabilityState(of: row), .failed,
                       "漏洞这一路失败 —— 不许被版本成功盖过去")
        // 行上只有一格徽标， precedence 是「有命中的正向发现 > 没查完 > 中性」：
        // 这条依赖版本确实落后（registry 答了 7.6.3 > 声明 7.5.0）⇒ 先说"过旧"这件真发现，
        // 但它**绝不是绿灯**；"漏洞没查成"必须同时能从 tooltip、总览与评分里读到（下面三行就是在查这个）。
        XCTAssertEqual(DependencyRowStatus.of(row), .outdated, "行状态：过旧是测出来的事实，且不是绿灯")
        XCTAssertNotEqual(DependencyRowStatus.of(row).role, Theme.Semantic.success)
        XCTAssertTrue(DependencyRowStatus.of(row).tooltip(record: row).contains("核对失败"),
                      "「漏洞没核对成」必须能在这一行上讲清楚：" + DependencyRowStatus.of(row).tooltip(record: row))
        XCTAssertEqual(DependencySafetyVerdict(report),
                       .unchecked(coveredCount: 1, total: 1, uncoveredEcosystems: []),
                       "总览也不能发绿")
        XCTAssertEqual(VulnerabilityEvidence.classify(report), .degraded,
                       "评分侧同形：发起了 OSV 且这一条失败 ⇒ 「试了没查完」= degraded，而不是「压根没查」的 unchecked")
    }

    func testPartialOsvFailureStillDisclosesTheUncoveredCount() async throws {
        let deps = (1...6).map { "\"p\($0)\": \"^1.0.0\"" }.joined(separator: ",")
        let root = try makeTree("partial-failure", files: [
            "package.json": "{\"name\":\"app\",\"dependencies\":{\(deps)}}",
        ])
        let failing = (1...2).map {
            DependencyVersionIdentity.coordinate(ecosystem: .npm, name: "p\($0)", queryVersion: "1.0.0")
        }
        let stub = StubOnlineSource(failedCoordinates: failing)
        let report = try await analyze(root, stub: stub)
        let ledger = DependencyEvidence.ledger(for: report)
        XCTAssertEqual(ledger.vulnerabilityCheckedCount, 4)
        XCTAssertEqual(ledger.vulnerabilityStateCounts[.failed], 2)
        XCTAssertFalse(DependencyEvidence.mayClaimNoKnownVulnerabilities(ledger),
                       "还有 2 条没查成，就不能对外说『未发现已知漏洞』")
        let statement = DependencyEvidence.findingsStatement(for: report, ledger: ledger)
        XCTAssertTrue(statement.contains("已核对 4"), statement)
        XCTAssertTrue(statement.contains("6"), statement)
        XCTAssertTrue(statement.contains("2 个核对失败"), statement)
    }

    // MARK: - 预算截断 / 生态不支持 / 版本未解析

    func testBudgetExcludedRecordsSaySo() async throws {
        // 超过 `maxOsvBatchPackages` 的部分是**我们主动没查**，必须落 `.budgetExcluded`。
        let count = DependencyNetworkLookup.maxOsvBatchPackages + 7
        let deps = (1...count).map { "\"pkg\($0)\": \"^1.0.0\"" }.joined(separator: ",")
        let root = try makeTree("budget", files: ["package.json": "{\"dependencies\":{\(deps)}}"])
        let stub = StubOnlineSource()
        let report = try await analyze(root, stub: stub)
        XCTAssertEqual(stub.receivedOsvQueries.count, DependencyNetworkLookup.maxOsvBatchPackages,
                       "发给数据源的条数必须等于上限")
        let ledger = DependencyEvidence.ledger(for: report)
        XCTAssertEqual(ledger.vulnerabilityStateCounts[.budgetExcluded], 7,
                       "只有**真没发出去**的那 7 条能落预算态：发出去并答了的 100 条不许被连坐")
        XCTAssertEqual(ledger.vulnerabilityStateCounts[.checked], 100)
        guard let evidence = report.vulnerabilityLookup else { return XCTFail("报告级账本必须落盘") }
        XCTAssertEqual(evidence.totalRecords, count)
        XCTAssertEqual(evidence.budgetExcluded, 7)
        XCTAssertEqual(VulnerabilityEvidence.classify(report), .degraded)
        XCTAssertTrue(report.networkLookupNote.contains("OSV 单次上限"), report.networkLookupNote)
    }

    func testUnsupportedEcosystemIsNotSilentlyClean() async throws {
        let root = try makeTree("unsupported", files: [
            "Package.swift": """
            let package = Package(
                dependencies: [
                    .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
                ]
            )
            """,
        ])
        let stub = StubOnlineSource()
        let report = try await analyze(root, stub: stub)
        XCTAssertTrue(stub.receivedOsvQueries.isEmpty, "OSV 不收 SwiftPM，一条都不该发出去")
        let row = try XCTUnwrap(record(report, "swift-log"))
        XCTAssertEqual(DependencyEvidence.vulnerabilityState(of: row), .ecosystemUnsupported)
        // 行状态读的是"两路各自结局"里更靠前的那格：这条依赖版本可比对且确实落后
        // （快照里 swift-log 最新 1.6.1 > 声明 1.5.0）⇒ 报「过旧」是真发现，
        // **但它绝不是绿灯** —— 这条用例管的就是"绝不因为 OSV 不收就发绿"。
        XCTAssertNotEqual(DependencyRowStatus.of(row), .verifiedSafe,
                          "生态不支持漏洞核对 ⇒ 永不许出现「正常」")
        XCTAssertEqual(DependencyRowStatus.of(row), .outdated, "过旧是独立于漏洞核对的另一件事")
        // SwiftPM 没有内置离线规则 ⇒ 未覆盖生态必须点名（旧期望写空是把它当"覆盖了"）。
        XCTAssertEqual(DependencySafetyVerdict(report),
                       .unchecked(coveredCount: 1, total: 1, uncoveredEcosystems: ["Swift Package"]))
        XCTAssertTrue(DependencyEvidence.tailPieces(DependencyEvidence.ledger(for: report))
                        .contains { $0.contains("生态不支持") })
    }

    func testUnresolvedVersionIsNotQueriedAndNotMarkedSafe() async throws {
        let root = try makeTree("unresolved", files: [
            "package.json": #"{"name":"app","dependencies":{"anything":"*","local":"workspace:*"}}"#,
        ])
        let stub = StubOnlineSource()
        let report = try await analyze(root, stub: stub)
        XCTAssertTrue(stub.receivedOsvQueries.isEmpty, "版本没解析出来就没资格查询")
        for name in ["anything", "local"] {
            let row = try XCTUnwrap(record(report, name))
            XCTAssertEqual(DependencyEvidence.vulnerabilityState(of: row), .versionUnresolved, name)
            XCTAssertEqual(DependencyRowStatus.of(row), .versionUnresolved, name)
        }
    }

    // MARK: - 离线默认态：一处都不许长成"无已知漏洞"

    func testOfflineRunMarksEverythingNotAttempted() async throws {
        let root = try makeTree("offline", files: [
            "package.json": #"{"name":"app","dependencies":{"lodash":"4.17.15"}}"#,
        ])
        let report = try await ManifestDependencyAnalyzer(options: .default, maxDepth: 3)
            .analyze(projectRoot: root, allowNetwork: false)
        let row = try XCTUnwrap(record(report, "lodash"))
        XCTAssertEqual(DependencyEvidence.versionState(of: row), .checked, "内置快照能比出版本新旧")
        XCTAssertEqual(DependencyEvidence.vulnerabilityState(of: row), .checked,
                       "内置规则命中了 lodash ⇒ 这条确实核对过")
        XCTAssertFalse(row.knownVulnerabilities.isEmpty, "真值：4.17.15 在内置规则覆盖范围内")
        // 真值来自冻结契约 `DependencyReport.riskLevel`：vulnerableCount 落在 1...2 ⇒ .medium。
        // （本流不许改那把分档尺子，只许照它断。）
        XCTAssertEqual(DependencySafetyVerdict(report), .findings(count: 1, risk: .medium),
                       "有命中就报命中：lodash 4.17.15 命中 1 条内置规则（取该规则的第一个 CVE 编号）")
    }

    func testOfflineCleanPackageIsNotClaimedSafe() async throws {
        let root = try makeTree("offline-clean", files: [
            "package.json": #"{"name":"app","dependencies":{"left-pad":"1.3.0"}}"#,
        ])
        let report = try await ManifestDependencyAnalyzer(options: .default, maxDepth: 3)
            .analyze(projectRoot: root, allowNetwork: false)
        XCTAssertEqual(report.vulnerableCount, 0, "内置规则没收录 left-pad")
        XCTAssertEqual(DependencySafetyVerdict(report),
                       .unchecked(coveredCount: 0, total: 1, uncoveredEcosystems: []),
                       "离线且内置规则无命中 ⇒ 只能读作未核对")
        XCTAssertFalse(DependencySafetyVerdict(report).mayClaimSafe)
        XCTAssertEqual(VulnerabilityEvidence.classify(report), .unchecked)
        let statement = DependencyEvidence.findingsStatement(for: report,
                                                            ledger: DependencyEvidence.ledger(for: report))
        XCTAssertFalse(statement.contains("未发现已知漏洞"), "这句在离线态禁止出现：\(statement)")
        XCTAssertTrue(statement.contains("漏洞核对未覆盖"), statement)
    }

    // MARK: - 分 scope 统计（RD-13c）

    func testScopeBreakdownKeepsScopesApart() async throws {
        let root = try makeTree("scopes", files: [
            "package.json": #"""
            {"name":"app","dependencies":{"runtime-a":"^1.0.0"},"devDependencies":{"dev-a":"^1.0.0"},
             "peerDependencies":{"platform-a":"^1.0.0"},"optionalDependencies":{"unknown-a":"^1.0.0"}}
            """#,
            "pom.xml": #"""
            <project><dependencies>
              <dependency><groupId>junit</groupId><artifactId>junit</artifactId>
                <version>4.13.2</version><scope>test</scope></dependency>
              <dependency><groupId>org.ow2.asm</groupId><artifactId>asm</artifactId>
                <version>9.6</version><scope>provided</scope></dependency>
            </dependencies></project>
            """#,
        ])
        let stub = StubOnlineSource()
        let report = try await analyze(root, stub: stub)
        // 报告级那一格是 Optional（旧报告没有它 ⇒ 非 Optional 会让整份解码失败），
        // 但**本次分析必须写下它**，所以这里按"必须有"来断，不写 nil 就当没这回事。
        let breakdown = try XCTUnwrap(report.scopeBreakdown,
                                      "分析器必须把分 scope 统计随报告一起落盘（RD-13c）")
        let rows = Dictionary<String, DependencyScopeCount>(
            uniqueKeysWithValues: breakdown.map { ($0.scope, $0) })
        XCTAssertEqual(rows["运行时"]?.declared, 1)
        XCTAssertEqual(rows["开发"]?.declared, 1)
        XCTAssertEqual(rows["测试"]?.declared, 1, "test scope 必须单列，不许并进运行时")
        XCTAssertEqual(rows["未标注"]?.declared, 1)
        XCTAssertEqual(breakdown.reduce(0) { $0 + $1.declared }, report.totalDependencies,
                       "分 scope 之和必须等于依赖总数")
        // 三处消费者同源的直接证据：账本里那份与报告里那份必须是**同一个值**。
        XCTAssertEqual(DependencyEvidence.ledger(for: report).scopeBreakdown, breakdown,
                       "总览 / 依赖行 / 评分读的是同一份 scope 统计，不许各自再算一遍")
    }

    // MARK: - 辅助

    private func analyze(_ root: URL, stub: StubOnlineSource) async throws -> DependencyReport {
        let analyzer = ManifestDependencyAnalyzer(options: .default, maxDepth: 3, onlineSource: stub)
        return try await analyzer.analyze(projectRoot: root, allowNetwork: true)
    }

    private func record(_ report: DependencyReport, _ name: String) -> DependencyRecord? {
        report.ecosystems.flatMap(\.dependencies).first { $0.name == name }
    }

    private func recordFrom(root report: DependencyReport, manifest: String,
                            name: String) -> DependencyRecord? {
        report.ecosystems.first { $0.manifestPath == manifest }?.dependencies.first { $0.name == name }
    }

    private func makeTree(_ tag: String, files: [String: String]) throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tcoder-r3-id-\(tag)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        for (relative, text) in files {
            let url = base.appendingPathComponent(relative, isDirectory: false)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                   withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return base
    }
}
