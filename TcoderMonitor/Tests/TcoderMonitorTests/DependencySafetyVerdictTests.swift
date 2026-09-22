import XCTest
@testable import TcoderMonitor

// OWNER: R3 依赖证据链（自 `DependencyAnalysisTests.swift` 整块搬来，2026-09-22）
//
// 搬动理由：`X3TestSizeAuditTests` 用产品侧同一条 400 行口径点名
// `DependencyAnalysisTests.swift` 404 行，而它给的唯一合法修法是"按类型整块搬"。
// 搬的是**整个 `DependencySafetyVerdictTests` 类**（契约 F：漏洞核对覆盖度三态）
// —— 判据要和它的用例住在一起，所以没拆类、没改任何一条断言。
// 对账：下面这段与源文件里那 221 行按行多重集相同（丢失 0 / 多出 0）。

// MARK: - 契约 F：漏洞核对覆盖度（WS-D 审计 P0#1/#2/#4 的回归门）
//
// 根因：默认 allowNetworkLookups = false → vulnerableCount 恒为 0，
// 而 riskLevel 只看 vulnerableCount，于是任何项目都能拿到绿色「风险 无」+ 每行「正常」。
// 现在视图与单测共用 DependencySafetyVerdict / DependencyRowStatus 这一份判定。

final class DependencySafetyVerdictTests: XCTestCase {
    /// 造一份依赖报告。
    ///
    /// RD-11 之后**绿灯只能由逐条结构化状态授权**，所以这里除了 `versionCheckSource`
    /// （那是"版本数据从哪来"，不是"漏洞查没查"）还要能落 `vulnerabilityCheckState`。
    /// 旧写法只给 source：那种报告在新口径下必须读成"没核对"，`testSourceKindAloneNeverClaimsSafe`
    /// 就是钉这一件的（旧实现会发绿 ⇒ 这条用例修前红）。
    func report(networkPerformed: Bool,
                        versions: [VersionCheckSource],
                        advisories: [SecurityAdvisory] = [],
                        offlineVulns: [DependencyVulnerability] = [],
                        vulnerabilityStates: [DependencyCheckState] = []) -> DependencyReport {
        let records = versions.enumerated().map { index, source -> DependencyRecord in
            var record = DependencyRecord(name: "pkg\(index)", version: "1.0.0", ecosystem: .npm, scope: .runtime,
                                          manifestPath: "package.json",
                                          latestKnownVersion: source == .none ? nil : "9.9.9",
                                          versionCheckSource: source, knownVulnerabilities: [])
            record.vulnerabilityCheckState = index < vulnerabilityStates.count ? vulnerabilityStates[index] : nil
            record.versionCheckState = source == .none ? .notAttempted : .checked
            return record
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
        let online = DependencySafetyVerdict(report(networkPerformed: true, versions: [.onlineRegistry],
                                                     vulnerabilityStates: [.checked]))

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

    /// 读数带格子里的短脚注：**压缩重复，但状态词一个不许少**。
    /// 清单 3.16 要求"每屏一处权威落点"，`summaryCaption` 的全文留在口径条那一处；
    /// 这一格只许留下核对状态 —— 少了它，`0 条` 就会被读成"查过、没有病"。
    func testVerdictTileCaptionKeepsTheHonestyStateAndPointsAtTheAuthority() {
        let offline = DependencySafetyVerdict(report(networkPerformed: false, versions: []))
        let online = DependencySafetyVerdict(report(networkPerformed: true, versions: [.onlineRegistry],
                                                    vulnerabilityStates: [.checked]))
        XCTAssertTrue(offline.tileCaption.contains("未联网核对"), offline.tileCaption)
        XCTAssertFalse(online.tileCaption.contains("未联网"), online.tileCaption)
        XCTAssertFalse(offline.tileCaption.contains("未发现已知漏洞"),
                       "短脚注里更不许出现 all-clear：" + offline.tileCaption)
        for verdict in [offline, online] {
            XCTAssertLessThanOrEqual(verdict.tileCaption.count, 24,
                                     "脚注超过一行就会把四格读数带撑成高低不齐：" + verdict.tileCaption)
            XCTAssertTrue(verdict.tileCaption.contains("见上方") || verdict.tileCaption.contains("见下方"),
                          "短脚注必须指出全口径的权威落点：" + verdict.tileCaption)
        }
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

    /// 行级绿灯的唯一授权是**两个维度的结构化状态**，不再是"版本数据从哪来"。
    ///
    /// 旧实现这一格是 `switch record.versionCheckSource { case .onlineRegistry: return .verifiedSafe }`
    /// —— npm 版本查成功就发绿，从没问过"这条的漏洞核对成功了没有"（RD-11 点名的冒充关系）。
    /// 修前红的那一条是 `source == .onlineRegistry` 而漏洞状态没落账：现在必须落「仅版本比对」。
    func testRowStatusIsAuthorizedByStatesNotBySourceKind() {
        func row(source: VersionCheckSource,
                 vulnerability: DependencyCheckState?,
                 version versionState: DependencyCheckState? = nil,
                 vulns: [String] = [],
                 latest: String? = "1.0.0") -> DependencyRowStatus {
            var record = DependencyRecord(name: "pkg", version: "1.0.0", ecosystem: .npm, scope: .runtime,
                                          manifestPath: "package.json", latestKnownVersion: latest,
                                          versionCheckSource: source, knownVulnerabilities: vulns)
            record.vulnerabilityCheckState = vulnerability
            record.versionCheckState = versionState
            return DependencyRowStatus.of(record)
        }

        // 正例：两路都已核对且零命中 —— 这才是唯一能发绿的形状。
        XCTAssertEqual(row(source: .onlineRegistry, vulnerability: .checked), .verifiedSafe)
        XCTAssertEqual(row(source: .bundledSnapshot, vulnerability: .checked), .verifiedSafe,
                       "绿灯与「数据从哪来」无关，只看两路各自的结果")
        // 反例（RD-11 的原始形状）：来源是在线源，但漏洞这一路没核对成 ⇒ 绝不发绿。
        XCTAssertNotEqual(row(source: .onlineRegistry, vulnerability: nil), .verifiedSafe,
                          "来源种类不许单独授权绿灯")
        XCTAssertEqual(row(source: .onlineRegistry, vulnerability: nil), .versionOnly)
        XCTAssertEqual(row(source: .onlineRegistry, vulnerability: .notAttempted), .versionOnly)
        // 另外四种"没查成"各占一格，谁也不许长成"正常"。
        for (state, expected) in [(DependencyCheckState.failed, DependencyRowStatus.checkFailed),
                                  (.versionUnresolved, .versionUnresolved),
                                  (.ecosystemUnsupported, .unsupported),
                                  (.budgetExcluded, .budgetExcluded)] {
            XCTAssertEqual(row(source: .onlineRegistry, vulnerability: state), expected, state.rawValue)
            XCTAssertNotEqual(row(source: .onlineRegistry, vulnerability: state).text, "正常", state.rawValue)
        }
        // 有命中优先于一切状态。
        XCTAssertEqual(row(source: .none, vulnerability: .notAttempted, vulns: ["CVE-1"], latest: nil).text, "有漏洞")
        // 版本落后是另一件事，仍可保留（但不是绿灯）。
        let outdated = row(source: .bundledSnapshot, vulnerability: .checked, latest: "9.9.9")
        XCTAssertEqual(outdated, .outdated)
        XCTAssertNotEqual(outdated.role, Theme.Semantic.success, "「过旧」不许画成绿色")
        XCTAssertTrue(DependencyRowStatus.versionOnly.tooltip(
            record: DependencyRecord(name: "pkg", version: "1.0.0", ecosystem: .npm, scope: .runtime,
                                     manifestPath: "package.json", latestKnownVersion: "1.0.0",
                                     versionCheckSource: .bundledSnapshot,
                                     knownVulnerabilities: [])).contains("只比对了版本新旧"))
    }

    /// 旧报告（只有 `versionCheckSource`、没有任何逐条状态）在新口径下必须读成"没核对"。
    func testSourceKindAloneNeverClaimsSafe() {
        let legacy = DependencyRecord(name: "pkg", version: "1.0.0", ecosystem: .npm, scope: .runtime,
                                      manifestPath: "package.json", latestKnownVersion: "1.0.0",
                                      versionCheckSource: .onlineRegistry, knownVulnerabilities: [])
        XCTAssertEqual(DependencyEvidence.vulnerabilityState(of: legacy), .notAttempted,
                       "字段缺席 = 没测过：宁可得罪人，不得给假绿灯")
        XCTAssertEqual(DependencyRowStatus.of(legacy), .versionOnly)
        XCTAssertFalse(DependencySafetyVerdict(DependencyReport(ecosystems: [
            EcosystemReport(ecosystem: .npm, manifestPath: "package.json", lockfileName: nil,
                            dependencies: [legacy], frameworkMarkers: []),
        ])).mayClaimSafe)
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
