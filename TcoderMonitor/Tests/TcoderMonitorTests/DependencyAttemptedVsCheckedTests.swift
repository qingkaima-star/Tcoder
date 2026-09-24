// OWNER: R3 依赖证据链 · 「尝试过」不许冒充「已核对安全」—— 反例四件（RD-11 / RD-13）
//
// 工单原文的三态 + 第四态，逐条钉死：
//   ① 离线一条都没核成 ⇒ 状态"未核对"，且**分数不因此升高**；
//   ② 查询失败 / 超时 ⇒ 与"未核对"**同档**，不许算"安全"；
//   ③ 查询成功但**这条包没被覆盖**（版本是范围认不出 / 公告 id 看见了却没展开成）
//      ⇒ 第四态"没查到不等于没有"，绝不是"无已知漏洞"；
//   ④ 查询成功且无命中 ⇒ **只有这一种**才许产出"已核对、无已知漏洞"。
//
// 每条的期望都是**自己推出来的**（内置公告表 + 查询身份 + 评分契约"缺证据不计分、
// 权重归一到剩下的维度"），没有一条是从实现输出回填的。落点用 `XCTAssertEqual`
// 带实测读数，便于交回汇报里贴真实数字。
import XCTest
@testable import TcoderMonitor

final class DependencyAttemptedVsCheckedTests: XCTestCase {

    /// 两个内置快照与公告表都**没收录**的包名 ⇒ 离线阶段不可能有任何正向证据，
    /// "未核对"这件事才是被测的而不是碰巧的。精确版本（非范围）保证有查询身份。
    private static let manifest = #"{"name":"app","dependencies":{"acme-alpha":"1.0.0","acme-beta":"2.0.0"}}"#

    private func analyze(_ files: [String: String], tag: String,
                         online: (any DependencyOnlineSource)?,
                         allowNetwork: Bool) async throws -> DependencyReport {
        let root = try makeTree(tag, files: files)
        let analyzer = online == nil
            ? ManifestDependencyAnalyzer(options: .default, maxDepth: 3)
            : ManifestDependencyAnalyzer(options: .default, maxDepth: 3, onlineSource: online!)
        return try await analyzer.analyze(projectRoot: root, allowNetwork: allowNetwork)
    }

    private func records(_ report: DependencyReport) -> [DependencyRecord] { report.ecosystems.flatMap(\.dependencies) }

    // MARK: - ① 离线一条都没核成

    func testOfflineNothingCheckedIsUncheckedAndDoesNotRaiseTheScore() async throws {
        let report = try await analyze(["package.json": Self.manifest], tag: "attempted-offline",
                                 online: nil, allowNetwork: false)
        let rows = records(report)
        XCTAssertEqual(rows.count, 2, "夹具必须真解析出两条依赖")
        let ledger = DependencyEvidence.ledger(for: report)
        XCTAssertEqual(ledger.vulnerabilityCheckedCount, 0, "离线一条都没核成 ⇒ 漏洞核对成功数必须是 0")
        XCTAssertEqual(ledger.versionCheckedCount, 0)
        for record in rows {
            XCTAssertEqual(DependencyEvidence.versionState(of: record), .notAttempted)
            XCTAssertEqual(DependencyEvidence.vulnerabilityState(of: record), .notAttempted)
            XCTAssertEqual(DependencyRowStatus.of(record), .unchecked,
                           "离线态被渲染成了 \(DependencyRowStatus.of(record).text)")
        }
        XCTAssertFalse(DependencyEvidence.mayClaimNoKnownVulnerabilities(ledger))
        XCTAssertFalse(DependencySafetyVerdict(report).mayClaimSafe,
                       "总览闸门在离线态发绿：\(DependencySafetyVerdict(report))")
        if case .unchecked(let covered, let total, _) = DependencySafetyVerdict(report) {
            XCTAssertEqual(covered, 0, "未核对档要报出「版本核对了几条 / 共几条」")
            XCTAssertEqual(total, 2)
        } else {
            XCTFail("离线一条都没核成，总览却给了 \(DependencySafetyVerdict(report))")
        }
        XCTAssertEqual(VulnerabilityEvidence.classify(report), .unchecked)
        let statement = DependencyEvidence.findingsStatement(for: report, ledger: ledger)
        XCTAssertFalse(statement.contains("未发现已知漏洞"), "离线一句都没核成却说出这句 = 假安心：\(statement)")

        // 分数侧（真值来自契约，不来自实现输出）：依赖维度缺席 ⇒ 只剩它一个维度时综合分是 0；
        // 把同一份报告的逐条状态改成"两路都核对成、零命中"之后，曲线在场且是满分 100。
        // 所以"没核成"这一档的综合分**只可能 ≤ 核对成功那一档** —— 这就是不许因没量到而升分。
        let scorer = WeightedHealthScorer()
        let offlineScore = scorer.score(HealthInputs(dependencies: report))
        var checkedCopy = report
        markAllChecked(&checkedCopy)
        let checkedScore = scorer.score(HealthInputs(dependencies: checkedCopy))
        XCTAssertFalse(offlineScore.components.contains { $0.name == HealthDimension.dependencies.rawValue },
                       "未核对却给了依赖分数：\(offlineScore.components.map(\.name))")
        XCTAssertTrue(offlineScore.overall <= checkedScore.overall,
                      "没核成反而分高：offline=\(offlineScore.overall) checked=\(checkedScore.overall)")
        XCTAssertLessThan(offlineScore.overall, checkedScore.overall,
                          "两档分数必须分得开（实测 offline=\(offlineScore.overall) checked=\(checkedScore.overall)）")
        print("【R3 反例①】离线：依赖维度缺席、overall=\(offlineScore.overall)；"
            + "同数据全部核对成功：overall=\(checkedScore.overall)")
    }

    // MARK: - ② 查询失败 / 超时

    func testFailedOrTimedOutLookupSitsInTheSameTierAsUnchecked() async throws {
        let coordinateA = DependencyVersionIdentity.coordinate(ecosystem: .npm, name: "acme-alpha",
                                                               queryVersion: "1.0.0")
        let coordinateB = DependencyVersionIdentity.coordinate(ecosystem: .npm, name: "acme-beta",
                                                               queryVersion: "2.0.0")
        XCTAssertEqual(coordinateA, "npm|acme-alpha|1.0.0", "手写期望：坐标三段")
        // 两条都点名失败，registry 那一路却全部答上 ⇒ "版本查成功"绝不能顶替"漏洞查成功"（RD-11）。
        let stub = StubOnlineSource(failedCoordinates: [coordinateA, coordinateB],
                                    latestVersions: ["acme-alpha": "1.0.0", "acme-beta": "2.0.0"])
        let report = try await analyze(["package.json": Self.manifest], tag: "attempted-failed",
                                 online: stub, allowNetwork: true)
        XCTAssertEqual(stub.receivedOsvQueries.count, 2, "前提：两条查询确实发出去了")
        let ledger = DependencyEvidence.ledger(for: report)
        XCTAssertEqual(ledger.vulnerabilityCheckedCount, 0)
        XCTAssertEqual(ledger.versionCheckedCount, 2, "registry 答上了两条 —— 这一维是真的核对过")
        for record in records(report) {
            XCTAssertEqual(DependencyEvidence.vulnerabilityState(of: record), .failed)
            XCTAssertEqual(DependencyRowStatus.of(record), .checkFailed,
                           "核对失败被长成 \(DependencyRowStatus.of(record).text)")
        }
        XCTAssertEqual(VulnerabilityEvidence.classify(report), .degraded)
        let verdict = DependencySafetyVerdict(report)
        XCTAssertFalse(verdict.mayClaimSafe, "查询失败这一档永远不许发绿")
        if case .unchecked(let covered, let total, _) = verdict {
            XCTAssertEqual(covered, 2, "失败档：版本核成了 2 条、漏洞一条没核成 ⇒ 仍是未核对档")
            XCTAssertEqual(total, 2)
        } else {
            XCTFail("两条查询都失败时总览却给了 \(verdict)")
        }
        XCTAssertFalse(DependencyEvidence.mayClaimNoKnownVulnerabilities(ledger))

        // "与未核对同档"= 两档都不参与评分，且综合分一模一样（都只剩缺席形状）。
        let offline = try await analyze(["package.json": Self.manifest], tag: "attempted-failed-offline",
                                  online: nil, allowNetwork: false)
        let scorer = WeightedHealthScorer()
        let failedScore = scorer.score(HealthInputs(dependencies: report))
        let offlineScore = scorer.score(HealthInputs(dependencies: offline))
        XCTAssertFalse(failedScore.components.contains { $0.name == HealthDimension.dependencies.rawValue })
        XCTAssertEqual(failedScore.overall, offlineScore.overall,
                       "失败档 \(failedScore.overall) 与未核对档 \(offlineScore.overall) 必须同档")
        XCTAssertTrue(failedScore.recommendations.contains { $0.contains("不计分") },
                      "实得 \(failedScore.recommendations)")
        print("【R3 反例②】两条查询全失败：checked=0／failed=\(ledger.vulnerabilityStateCounts[.failed] ?? 0)"
            + "／版本 checked=\(ledger.versionCheckedCount)，overall=\(failedScore.overall)"
            + "（未核对档 overall=\(offlineScore.overall)）")
    }

    // MARK: - ③ 查询成功但这条包没被覆盖 ⇒ 第四态

    /// 本地就能判的那一支：版本是范围、认不出 ⇒ 不许进"已核对"，也不许进"无漏洞"。
    func testUnresolvedVersionIsNotCoveredByASuccessfulQuery() async throws {
        let report = try await analyze(["package.json": #"{"name":"app","dependencies":{"acme-wild":"*"}}"#],
                                 tag: "attempted-unresolved", online: nil, allowNetwork: false)
        let record = try XCTUnwrap(records(report).first)
        XCTAssertEqual(DependencyEvidence.vulnerabilityState(of: record), .versionUnresolved)
        XCTAssertEqual(DependencyRowStatus.of(record), .versionUnresolved)
        XCTAssertEqual(VulnerabilityEvidence.classify(report), .unchecked)
        let ledger = DependencyEvidence.ledger(for: report)
        XCTAssertFalse(DependencyEvidence.mayClaimNoKnownVulnerabilities(ledger))
        let statement = DependencyEvidence.findingsStatement(for: report, ledger: ledger)
        XCTAssertTrue(statement.contains("未解析"), "第四态要出声：\(statement)")
    }

    /// 真源归因层那一支（本轮补的洞）：**公告 id 看见了、详情没能展开成**，
    /// 旧实现把这条坐标摊成 `.answered(空)` ⇒ 行状态 `.verifiedSafe`、总览"未发现已知漏洞"。
    /// 现在按身份落 `.failed`（`DependencyCheckState.failed` 的注释就写着"响应解不出来"）。
    func testAdvisorySeenButDetailUnexpandedIsNotChecked() {
        let first = OsvPackageQuery(ecosystem: "npm", package: "acme-alpha", version: "1.0.0")
        let second = OsvPackageQuery(ecosystem: "npm", package: "acme-beta", version: "2.0.0")
        let queries = [first, second]
        let clean = OsvLookupResult(advisories: [], packagesChecked: 2, failedRequests: 0, note: "",
                                    incompleteCoordinates: [first.coordinate])
        let outcomes = LiveDependencyOnlineSource.osvOutcomes(for: queries, result: clean)
        XCTAssertEqual(outcomes[first.coordinate], .failed,
                       "没查到底被摊成答上了：\(String(describing: outcomes[first.coordinate]))")
        XCTAssertEqual(outcomes[second.coordinate], .answered(advisories: []),
                       "点名之外的坐标不受影响（否则又长成一条失败全部未核对）")
        // 对照：同一份 result 若不带 incompleteCoordinates（= 改前形状），这条才会被判干净。
        let legacy = OsvLookupResult(advisories: [], packagesChecked: 2, failedRequests: 0, note: "")
        XCTAssertEqual(LiveDependencyOnlineSource.osvOutcomes(for: queries, result: legacy)[first.coordinate],
                       .answered(advisories: []), "这条钉的是没有结构化出口时旧行为长什么样")

        // 纯函数侧：被上限截断（仍留在 expanded 里但 vuln == nil）也算没查到底。
        let seed: [String: DependencyNetworkLookup.OsvEntry] = [
            "GHSA-one": .init(vuln: nil, queryIndices: [0]),
            "GHSA-two": .init(vuln: nil, queryIndices: [0]),
            "GHSA-three": .init(vuln: nil, queryIndices: [1]),
        ]
        var expanded = seed
        // `OsvVuln` 是 Decodable 且无默认值 ⇒ 用真实 JSON 解一个，不改产品形状。
        let decoded = try? JSONDecoder().decode(DependencyNetworkLookup.OsvVuln.self,
                                                from: Data(#"{"id":"GHSA-two"}"#.utf8))
        XCTAssertNotNil(decoded, "夹具：解不出这条最小 OSV 记录，下面的对照就是空跑")
        expanded["GHSA-two"]?.vuln = decoded                     // 只有它展开成了
        let unresolved = DependencyNetworkLookup.unresolvedOsvCoordinates(
            queries: queries, seed: seed, expanded: expanded,
            droppedIDs: ["GHSA-one", "GHSA-three"])
        // 手写推导：q0 有展开成的 GHSA-two ⇒ 不算没查到底；q1 名下只有被丢掉 / 截断的 id ⇒ 算。
        XCTAssertEqual(unresolved, [second.coordinate])
    }

    // MARK: - ④ 查询成功且无命中 ⇒ 才许"已核对安全"

    func testOnlySuccessfulQueryWithNoHitMayClaimVerifiedSafe() async throws {
        let stub = StubOnlineSource(latestVersions: ["acme-alpha": "1.0.0", "acme-beta": "2.0.0"])
        let report = try await analyze(["package.json": Self.manifest], tag: "attempted-clean",
                                 online: stub, allowNetwork: true)
        let ledger = DependencyEvidence.ledger(for: report)
        XCTAssertEqual(ledger.vulnerabilityCheckedCount, 2)
        XCTAssertEqual(VulnerabilityEvidence.classify(report), .verified)
        XCTAssertTrue(DependencyEvidence.mayClaimNoKnownVulnerabilities(ledger))
        for record in records(report) {
            XCTAssertEqual(DependencyEvidence.vulnerabilityState(of: record), .checked)
            XCTAssertEqual(DependencyRowStatus.of(record), .verifiedSafe)
        }
        XCTAssertEqual(DependencySafetyVerdict(report), .clean(total: 2))
        XCTAssertTrue(DependencyEvidence.findingsStatement(for: report, ledger: ledger)
                      .contains("未发现已知漏洞"), "四件里只有这一件配说这句")
        print("【R3 反例④】查询成功且零命中：\(ledger.vulnerabilityCheckedCount)/\(ledger.totalCount)"
            + " 已核对，verdict=.clean，逐条 .verifiedSafe")
    }

    // MARK: - 辅助

    /// 把逐条两路状态都改成"核对成功"（①用的对照档：同一份数据、只差"核成没核成"）。
    private func markAllChecked(_ report: inout DependencyReport) {
        for ecosystemIndex in report.ecosystems.indices {
            for index in report.ecosystems[ecosystemIndex].dependencies.indices {
                report.ecosystems[ecosystemIndex].dependencies[index].versionCheckState = .checked
                report.ecosystems[ecosystemIndex].dependencies[index].vulnerabilityCheckState = .checked
            }
        }
    }

    private func makeTree(_ tag: String, files: [String: String]) throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tcoder-r3-attempted-\(tag)-\(UUID().uuidString.prefix(8))", isDirectory: true)
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
