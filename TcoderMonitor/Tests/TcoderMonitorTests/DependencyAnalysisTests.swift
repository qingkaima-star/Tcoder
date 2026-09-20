import XCTest
@testable import TcoderMonitor

// WS-B · 依赖侧测试：清单解析（契约 B）、内置快照与离线漏洞（契约 C）、
// 漏洞核对覆盖度三态（契约 F）。Git 侧在 GitDependencyTests.swift，
// 两者共用那里的 `Fixture`（同一编译单元内可见，命名不与他文件冲突）。
// MARK: - 契约 B：ManifestParsers

// MARK: - 契约 C：内置快照与离线漏洞

final class DependencySnapshotTests: XCTestCase {

    func assertVulnerable(_ ecosystem: DependencyEcosystem, _ name: String, _ version: String,
                                  _ label: String) {
        XCTAssertFalse(VulnerabilitySource.matches(ecosystem: ecosystem, name: name, version: version).isEmpty,
                       label)
    }

    func assertClean(_ ecosystem: DependencyEcosystem, _ name: String, _ version: String,
                             _ label: String) {
        XCTAssertTrue(VulnerabilitySource.matches(ecosystem: ecosystem, name: name, version: version).isEmpty,
                      label)
    }

    var vulnerableBatch: [DependencyRecord] {
        [Fixture.record(name: "lodash", version: "4.17.15", manifest: "package.json"),
         Fixture.record(name: "com.alibaba:fastjson", version: "1.2.68", ecosystem: .maven, manifest: "pom.xml"),
         Fixture.record(name: "org.apache.logging.log4j:log4j-core", version: "2.14.1", ecosystem: .maven,
                        manifest: "server/pom.xml"),
         Fixture.record(name: "axios", version: "0.21.1", manifest: "web/package.json")]
    }

    func testSnapshotMetadataAndLatestKnownVersion() throws {
        XCTAssertGreaterThan(DependencySnapshot.bundledEntryCount, 0, "内置快照不得为空")
        XCTAssertGreaterThan(DependencySnapshot.snapshotDate.timeIntervalSince1970, 1_600_000_000,
                             "快照日期必须晚于 2020 年")
        // 契约只要求「lodash 已收录、且最新已知版本不低于修复版 4.17.21」，不锁死具体小版本号。
        let lodash = try XCTUnwrap(DependencySnapshot.latestKnownVersion(ecosystem: .npm, name: "lodash"),
                                   "lodash 必须被内置快照收录")
        XCTAssertFalse(DependencyVersion.isOlder(current: lodash, than: "4.17.21"),
                       "lodash 的最新已知版本不得低于修复版 4.17.21")
        XCTAssertNil(DependencySnapshot.latestKnownVersion(ecosystem: .npm, name: "tcoder-not-real"),
                     "不存在的包返回 nil")
        XCTAssertNil(DependencySnapshot.latestKnownVersion(ecosystem: .npm, name: ""), "空包名返回 nil")
        let maven = DependencySnapshot.latestKnownVersion(ecosystem: .maven, name: "com.alibaba:fastjson")
        let gradle = DependencySnapshot.latestKnownVersion(ecosystem: .gradle, name: "com.alibaba:fastjson")
        XCTAssertNotNil(maven, "maven 坐标必须命中快照")
        XCTAssertEqual(gradle, maven, "gradle 与 maven 坐标互通")
    }

    func testMatchesRespectsFixVersionBoundary() throws {
        XCTAssertEqual(VulnerabilitySource.matches(ecosystem: .npm, name: "lodash", version: "4.17.15").count, 1,
                       "lodash 4.17.15 命中 1 条漏洞")
        assertClean(.npm, "lodash", "4.17.21", "lodash 4.17.21 是修复版本，不得命中")
        let hits = VulnerabilitySource.matches(ecosystem: .npm, name: "lodash", version: "4.17.15")
        let first = try XCTUnwrap(hits.first, "lodash 4.17.15 应有命中")
        XCTAssertTrue(first.affects(version: "4.17.20"), "受影响区间内为 true")
        XCTAssertFalse(first.affects(version: "4.17.21"), "修复版本本身为 false")
    }

    func testMatchesBoundariesAcrossEcosystems() {
        assertVulnerable(.maven, "com.alibaba:fastjson", "1.2.68", "fastjson 1.2.68 命中")
        assertVulnerable(.maven, "commons-collections:commons-collections", "3.2.1", "commons-collections 命中")
        assertVulnerable(.maven, "io.jsonwebtoken:jjwt", "0.9.1", "jjwt 0.9.1 命中")
        assertVulnerable(.maven, "org.apache.logging.log4j:log4j-core", "2.14.1", "log4j-core 2.14.1 命中")
        assertVulnerable(.npm, "axios", "0.21.1", "axios 0.21.1 命中")
        assertClean(.maven, "org.apache.logging.log4j:log4j-core", "2.20.0", "log4j-core 2.20.0 已修复")
        assertClean(.npm, "axios", "1.6.0", "新版 axios 不得命中")
        assertClean(.npm, "tcoder-not-real", "1.0.0", "不存在的包不得命中")
    }

    func testOfflineVulnerabilitiesAggregateAndCarryCVEIdentifiers() {
        let vulns = VulnerabilitySource.offlineVulnerabilities(for: vulnerableBatch)
        XCTAssertTrue(Set(["lodash", "com.alibaba:fastjson", "org.apache.logging.log4j:log4j-core", "axios"])
                        .isSubset(of: Set(vulns.map { $0.package })), "四个有漏洞的包都要出现")
        for vuln in vulns {
            XCTAssertFalse(vuln.cveIdentifiers.isEmpty, "\(vuln.package) 的 CVE 列表不得为空")
            XCTAssertTrue(vuln.cveIdentifiers.allSatisfy { $0.hasPrefix("CVE-") }, "\(vuln.package) 编号须为 CVE 格式")
            XCTAssertFalse(vuln.vulnerableRange.isEmpty, "\(vuln.package) 的区间描述不得为空")
            XCTAssertGreaterThan(vuln.severity.rank, RiskLevel.none.rank, "\(vuln.package) 级别不得是「无」")
        }
        let samePackage = VulnerabilitySource.offlineVulnerabilities(for: [
            Fixture.record(name: "lodash", version: "4.17.15", manifest: "package.json"),
            Fixture.record(name: "lodash", version: "4.17.20", manifest: "web/package.json"),
            Fixture.record(name: "lodash", version: "4.17.21", manifest: "app/package.json"),
        ])
        XCTAssertEqual(samePackage.count, 1, "同一包的多条命中聚合成 1 条")
        XCTAssertEqual(samePackage[0].package, "lodash", "包名正确")
        XCTAssertEqual(samePackage[0].ecosystem, .npm, "生态正确")
        XCTAssertEqual(samePackage[0].affectedDependencies.count, 2, "只有两个旧版本被计入")
        XCTAssertFalse(samePackage[0].affectedDependencies.contains { $0.isEmpty }, "受影响项不得为空串")
    }

    func testCleanInputProducesNoOfflineFindings() {
        let clean = [Fixture.record(name: "lodash", version: "4.17.21", manifest: "package.json"),
                     Fixture.record(name: "tcoder-not-real", version: "1.0.0", manifest: "package.json")]
        XCTAssertEqual(VulnerabilitySource.offlineVulnerabilities(for: clean), [], "干净依赖返回空数组")
        XCTAssertEqual(VulnerabilitySource.offlineVulnerabilities(for: []), [], "空输入返回空数组")
        XCTAssertEqual(VulnerabilitySource.bundledAdvisories(for: clean), [], "无漏洞时不得杜撰公告")
    }

    func testBundledAdvisoriesDescribeAffectedPackages() {
        let advisories = VulnerabilitySource.bundledAdvisories(
            for: [Fixture.record(name: "lodash", version: "4.17.15", manifest: "package.json")])
        XCTAssertFalse(advisories.isEmpty, "lodash 旧版本必须有公告")
        XCTAssertEqual(advisories[0].ecosystem, .npm, "公告生态正确")
        XCTAssertFalse(advisories[0].id.isEmpty, "公告 id 不得为空")
        XCTAssertFalse(advisories[0].summary.isEmpty, "公告标题不得为空")
        XCTAssertTrue(advisories[0].affectedPackages.contains { $0.contains("lodash") }, "受影响包含 lodash")
    }

    func testVersionIsOlderEdgeCases() {
        XCTAssertFalse(DependencyVersion.isOlder(current: "1.0.0-SNAPSHOT", than: "1.0.0"), "-SNAPSHOT 后缀要截掉")
        XCTAssertTrue(DependencyVersion.isOlder(current: "^1.2.3", than: "1.2.4"), "^1.2.3 归一化为 0 视为落后")
        XCTAssertFalse(DependencyVersion.isOlder(current: "1.2.3", than: "^1.2.4"), "latest 归一化为 0 时不得判落后")
        XCTAssertTrue(DependencyVersion.isOlder(current: "", than: "1.0.0"), "空串归一化为 [0]")
        XCTAssertTrue(DependencyVersion.isOlder(current: "abc", than: "1.0.0"), "纯字母归一化为 [0]")
        XCTAssertFalse(DependencyVersion.isOlder(current: "1.0.0.0.0.0.0", than: "1.0.0"), "多出的零段不得判落后")
        XCTAssertTrue(DependencyVersion.isOlder(current: "1.0.0.0.0.0.2", than: "1.0.0.0.0.0.3"), "超长段数逐位比较")
        XCTAssertEqual(DependencyVersion.normalize("2.0"), [2, 0], "normalize 行为冻结")
    }
}

// MARK: - 契约 F：漏洞核对覆盖度（WS-D 审计 P0#1/#2/#4 的回归门）
//
// 根因：默认 allowNetworkLookups = false → vulnerableCount 恒为 0，
// 而 riskLevel 只看 vulnerableCount，于是任何项目都能拿到绿色「风险 无」+ 每行「正常」。
// 现在视图与单测共用 DependencySafetyVerdict / DependencyRowStatus 这一份判定。

final class DependencySafetyVerdictTests: XCTestCase {
    func report(networkPerformed: Bool,
                        versions: [VersionCheckSource],
                        advisories: [SecurityAdvisory] = [],
                        offlineVulns: [DependencyVulnerability] = []) -> DependencyReport {
        let records = versions.enumerated().map { index, source -> DependencyRecord in
            DependencyRecord(name: "pkg\(index)", version: "1.0.0", ecosystem: .npm, scope: .runtime,
                             manifestPath: "package.json", latestKnownVersion: source == .none ? nil : "9.9.9",
                             versionCheckSource: source, knownVulnerabilities: [])
        }
        var result = DependencyReport(analyzedAt: Fixture.commit(sha: Fixture.shaA, date: Date()).date)
        result.ecosystems = [EcosystemReport(ecosystem: .npm, manifestPath: "package.json",
                                            lockfileName: nil, dependencies: records, frameworkMarkers: [])]
        result.advisories = advisories
        result.offlineVulnerabilities = offlineVulns
        result.networkLookupPerformed = networkPerformed
        return result
    }

    /// 同一份「零命中」数据，联网与否必须给出**不同**的可见结论。
    func testOfflineAndOnlineZeroFindingsDifferVisibly() {
        let offline = DependencySafetyVerdict(report(networkPerformed: false, versions: [.bundledSnapshot]))
        let online = DependencySafetyVerdict(report(networkPerformed: true, versions: [.onlineRegistry]))

        XCTAssertEqual(offline, .unchecked(coveredCount: 1, total: 1, uncoveredEcosystems: []))
        XCTAssertEqual(online, .clean(coveredCount: 1, total: 1))
        XCTAssertFalse(offline.mayClaimSafe, "没联网就不许声称安全")
        XCTAssertTrue(online.mayClaimSafe)
        XCTAssertNotEqual(offline.badgeText, online.badgeText)
        XCTAssertEqual(offline.badgeText, "未核对")
        XCTAssertEqual(online.badgeText, "已核对")
        XCTAssertTrue(offline.summaryCaption.contains("未联网核对"), offline.summaryCaption)
        XCTAssertTrue(online.summaryCaption.contains("未发现已知漏洞"), online.summaryCaption)
        XCTAssertFalse(offline.summaryCaption.contains("未发现已知漏洞"),
                       "离线文案里不能出现「未发现已知漏洞」这种 all-clear")
    }

    /// 契约层 `uncoveredEcosystemNames` 拿 displayName 去比 ["npm","maven","python"]，
    /// 于是 npm（displayName 是 "npm / Node.js"）被误报成"未覆盖生态"。
    /// 服务层改成从规则表推导，这里把两边差异钉住。
    func testUncoveredEcosystemListFollowsTheRuleTableNotADuplicatedNameSet() {
        var npmOnly = DependencyReport()
        npmOnly.ecosystems = [EcosystemReport(ecosystem: .npm, manifestPath: "package.json",
                                             lockfileName: nil, dependencies: [], frameworkMarkers: [])]
        XCTAssertEqual(ManifestDependencyAnalyzer.ecosystemsWithoutOfflineRules(in: npmOnly), [],
                       "npm 有内置规则，不该被点名为未覆盖")

        var goAndCargo = DependencyReport()
        goAndCargo.ecosystems = [
            EcosystemReport(ecosystem: .go, manifestPath: "go.mod", lockfileName: nil,
                            dependencies: [], frameworkMarkers: []),
            EcosystemReport(ecosystem: .cargo, manifestPath: "Cargo.toml", lockfileName: nil,
                            dependencies: [], frameworkMarkers: []),
        ]
        XCTAssertEqual(ManifestDependencyAnalyzer.ecosystemsWithoutOfflineRules(in: goAndCargo), ["Go", "Cargo"],
                       "无内置规则的生态必须被点名")
        XCTAssertTrue(goAndCargo.uncoveredEcosystemNames.count >= 2,
                      "契约层同样会点名这两个，只是它连 npm 也一起误点名")
    }

    func testVerdictKeepsFindingsAndTreatsAdvisoriesAsCoverage() {
        let hit = DependencyVulnerability(id: "V1", package: "lodash", ecosystem: .npm,
                                          vulnerableRange: "< 4.17.21", fixedVersion: "4.17.21",
                                          summary: "命令注入", severity: .high,
                                          cveIdentifiers: ["CVE-2021-23337"], affectedDependencies: ["lodash@4.17.15"])
        let found = DependencySafetyVerdict(report(networkPerformed: false, versions: [.bundledSnapshot],
                                                  offlineVulns: [hit]))
        guard case .findings(let count, _) = found else { return XCTFail("有命中必须是 findings，实得 \(found)") }
        XCTAssertEqual(count, 1)
        XCTAssertFalse(found.mayClaimSafe)

        // 带回过在线公告＝确实联网查过；但公告非空必然也计入 vulnerableCount，所以走 findings 分支
        let advisory = SecurityAdvisory(id: "A1", aliases: ["CVE-1"], summary: "s", details: "d",
                                        severity: .medium, cvssScore: nil, affectedPackages: ["pkg0@1.0.0"],
                                        ecosystem: .npm, publishedAt: nil, source: "OSV")
        let covered = DependencySafetyVerdict(report(networkPerformed: false, versions: [.onlineRegistry],
                                                    advisories: [advisory]))
        guard case .findings(let coveredCount, _) = covered else {
            return XCTFail("有在线公告就是命中，必须走 findings，实得 \(covered)")
        }
        XCTAssertEqual(coveredCount, 1)
    }

    func testRowStatusOnlyTurnsGreenOnOnlineSource() {
        func row(_ source: VersionCheckSource, vulns: [String] = [], latest: String? = "1.0.0") -> DependencyRowStatus {
            DependencyRowStatus.of(DependencyRecord(name: "pkg", version: "1.0.0", ecosystem: .npm, scope: .runtime,
                                                    manifestPath: "package.json", latestKnownVersion: latest,
                                                    versionCheckSource: source, knownVulnerabilities: vulns))
        }
        XCTAssertEqual(row(.onlineRegistry), .verifiedSafe)
        XCTAssertEqual(row(.onlineRegistry).text, "正常")
        XCTAssertEqual(row(.bundledSnapshot), .versionOnly, "只有内置快照比过版本 → 漏洞层面仍未核对")
        XCTAssertNotEqual(row(.bundledSnapshot).text, "正常")
        XCTAssertEqual(row(.none, latest: nil), .unchecked)
        XCTAssertNotEqual(row(.none, latest: nil).text, "正常")
        XCTAssertEqual(row(.none, vulns: ["CVE-1"]).text, "有漏洞")
        XCTAssertEqual(row(.bundledSnapshot, latest: "9.9.9"), .outdated, "版本落后是版本结论，可保留")
        XCTAssertTrue(row(.bundledSnapshot).tooltip(record: DependencyRecord(
            name: "pkg", version: "1.0.0", ecosystem: .npm, scope: .runtime, manifestPath: "package.json",
            latestKnownVersion: "1.0.0", versionCheckSource: .bundledSnapshot,
            knownVulnerabilities: [])).contains("未联网核对"))
    }

    func testOfflineCaveatNamesSkippedIncomparableVersions() {
        let records: [DependencyRecord] = [
            DependencyRecord(name: "lodash", version: "4.17.21", ecosystem: .npm, scope: .runtime,
                             manifestPath: "package.json", latestKnownVersion: nil,
                             versionCheckSource: .none, knownVulnerabilities: []),
            DependencyRecord(name: "@tcoder/local", version: "workspace:*", ecosystem: .npm, scope: .unknown,
                             manifestPath: "package.json", latestKnownVersion: nil,
                             versionCheckSource: .none, knownVulnerabilities: []),
            DependencyRecord(name: "ghost", version: "*", ecosystem: .npm, scope: .runtime,
                             manifestPath: "package.json", latestKnownVersion: nil,
                             versionCheckSource: .none, knownVulnerabilities: []),
        ]
        var report = DependencyReport()
        report.ecosystems = [EcosystemReport(ecosystem: .npm, manifestPath: "package.json",
                                            lockfileName: nil, dependencies: records, frameworkMarkers: [])]
        let note = ManifestDependencyAnalyzer.offlineCaveat(for: report)
        XCTAssertTrue(note.contains("未联网核对"), note)
        XCTAssertTrue(note.contains("2 项版本不可比较"), "workspace:* 与 * 两个要按数量说出来：\(note)")
    }

    func testOfflineAnalysisWritesCaveatIntoReportEndToEnd() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tcoder-wsb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try #"{"name":"tcoder-lab","dependencies":{"lodash":"4.17.21","@tcoder/local":"workspace:*"}}"#
            .write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)

        let result = try await ManifestDependencyAnalyzer().analyze(projectRoot: root, allowNetwork: false)
        XCTAssertEqual(result.totalDependencies, 2)
        XCTAssertEqual(result.vulnerableCount, 0, "内置规则没有 lodash 4.17.21 的命中")
        XCTAssertFalse(result.networkLookupPerformed)
        XCTAssertFalse(DependencySafetyVerdict(result).mayClaimSafe, "这份报告不得被渲染成安全")
        XCTAssertTrue(result.networkLookupNote.contains("未联网核对"),
                     "离线也要说清我们没做什么，实得：\(result.networkLookupNote)")
        XCTAssertTrue(result.networkLookupNote.contains("1 项版本不可比较"), result.networkLookupNote)
    }
}
