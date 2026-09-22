// OWNER: R3 依赖证据链 · 核对状态是**一处事实、三处消费**（RD-11 / RD-13）
//
// 本文件是 `DependencyEvidence` 这份账本的契约测试。三件事各钉一族用例：
//   ① **保守方向不许松**（用户点名的红线）：原来判 `.degraded` 的样本，改完仍不许变 `.verified`；
//   ② "未发现漏洞"这句话必须同时给出**已成功核对的范围与条数**，
//      总览 / 依赖行 / 评分三处必须消费同一份证据（不许各自再推一遍）；
//   ③ 手写坐标字符串 = RD-12 的病根，扫描守卫 + 分母 + 反向元测试。
// 真值全部来自本文件内联夹具与手写推导，**没有一条期望是从实现输出回填的**。
import XCTest
@testable import TcoderMonitor

/// 继承 `ManifestLabTestCase` 只为一件事：拿 WS-F 那套十生态夹具（`root`）
/// 做第 ④ 组"分析器账本 vs 手写独立真值"的对照，其余用例都自带内联夹具。
final class DependencyEvidenceTests: ManifestLabTestCase {

    // MARK: - 夹具：手写一份"这条依赖被核对到什么程度"的报告

    /// 手写一条依赖。`version` 一律是**清单原文**，`resolved` 才是锁文件里装的那个。
    private func rec(_ name: String, _ version: String, ecosystem: DependencyEcosystem = .npm,
                     resolved: String? = nil, latest: String? = nil, vulns: [String] = [],
                     versionState: DependencyCheckState? = nil,
                     vulnerabilityState: DependencyCheckState? = nil) -> DependencyRecord {
        var record = DependencyRecord(name: name, version: version, ecosystem: ecosystem, scope: .runtime,
                                      manifestPath: "package.json", latestKnownVersion: latest,
                                      versionCheckSource: latest == nil ? .none : .bundledSnapshot,
                                      knownVulnerabilities: vulns, resolvedVersion: resolved)
        record.versionCheckState = versionState
        record.vulnerabilityCheckState = vulnerabilityState
        return record
    }

    private func report(_ records: [DependencyRecord], performed: Bool = false, note: String = "",
                        advisories: [SecurityAdvisory] = [], offlineHits: Int = 0) -> DependencyReport {
        var result = DependencyReport()
        result.ecosystems = [EcosystemReport(ecosystem: .npm, manifestPath: "package.json",
                                            lockfileName: nil, dependencies: records, frameworkMarkers: [])]
        result.networkLookupPerformed = performed
        result.networkLookupNote = note
        result.advisories = advisories
        // 内置规则的命中在报告里是 `offlineVulnerabilities`（契约的 `vulnerableCount` 读它），
        // 造夹具时要一并写，否则"有正向发现"这件事在两层账上对不上。
        result.offlineVulnerabilities = (0..<offlineHits).map { index in
            DependencyVulnerability(id: "TCODER-fixture-\(index)", package: "a", ecosystem: .npm,
                                    vulnerableRange: "< 4.17.21", fixedVersion: "4.17.21",
                                    summary: "夹具命中", severity: .high,
                                    cveIdentifiers: ["CVE-2021-23337"], affectedDependencies: ["npm|a|4.17.15"])
        }
        return result
    }

    // MARK: - ① 保守方向：旧判据降级/未核对的样本，改完一律不许升成 verified

    /// **这一族判据的快照**（只存在于测试里，用来对照方向，生产代码已删）：
    /// `report.networkLookupNote.contains("失败") ? .degraded : .verified`
    /// 配 `hasVulnerabilityCoverage = networkLookupPerformed || !advisories.isEmpty`。
    private func legacyClassify(_ report: DependencyReport) -> VulnerabilityEvidence {
        if report.vulnerableCount > 0 { return .verified }
        guard report.networkLookupPerformed || !report.advisories.isEmpty else { return .unchecked }
        return report.networkLookupNote.contains("失败") ? .degraded : .verified
    }

    /// 方向表：每一条都写清"旧判据给什么 / 新判据必须给什么"，
    /// 并机器断言**旧→新只许往保守那侧走**（degraded/unchecked 永远不许变 verified）。
    func testStructuredStatesKeepTheConservativeDirection() {
        let offlineNote = "未联网核对，漏洞判定只依据内置快照（覆盖 npm / Maven / Python），快照截至 2026-09-19"
        let cases: [(name: String, report: DependencyReport, new: VulnerabilityEvidence)] = [
            // 旧判据 = .degraded 的四支：改完必须仍是 .degraded（或更保守）
            ("在线但部分失败", report([rec("a", "1.0.0", vulnerabilityState: .failed)],
                                      performed: true, note: "OSV：52 个包中 3 个查询失败"), .degraded),
            ("在线但被预算截断", report([rec("a", "1.0.0", vulnerabilityState: .budgetExcluded)],
                                          performed: true, note: "OSV 单次上限：7 条未查询"), .degraded),
            ("旧报告：只说发起过、没有逐条账", report([rec("a", "1.0.0")],
                                                       performed: true, note: "OSV 查询失败"), .degraded),
            ("整路硬超时（说明里没有「失败」两个字）", report([rec("a", "1.0.0")],
                                                                performed: true,
                                                                note: "OSV 查询超过 5 秒硬超时，本次在线漏洞结果整体放弃"), .degraded),
            // 旧判也是 degraded 的一支：新旧同侧 ⇒ 方向线要能证明"改完仍然不乐观"，
            // 而不是只证明"旧判据管不到的那些被收回了"。
            ("npm 侧有包失败（说明里就写着「失败」）", report(
                [rec("a", "1.0.0", versionState: .checked, vulnerabilityState: .checked),
                 rec("b", "2.0.0", versionState: .failed, vulnerabilityState: .failed)],
                performed: true, note: "npm registry：4 个包中 1 个查询失败"), .degraded),
            ("部分核对成功、部分没查完", report([rec("a", "1.0.0", vulnerabilityState: .checked),
                                                 rec("b", "2.0.0", vulnerabilityState: .failed)],
                                                performed: true, note: "在线查询已完成（OSV + npm registry）"), .degraded),
            // 旧判据 = .unchecked 的三支：改完仍不许是 verified
            ("默认离线", report([rec("a", "1.0.0")], note: offlineNote), .unchecked),
            ("离线且一条依赖都没有", report([]), .unchecked),
            ("离线、note 里带日期那一句", report([rec("a", "1.0.0")], note: offlineNote), .unchecked),
            // 旧判据 = .verified 的两支：正向发现永远保留（不许为了保守把维度摘掉）
            ("内置规则有命中（离线也算查过）", report(
                [rec("a", "4.17.15", vulns: ["CVE-2021-23337"])],
                advisories: [], offlineHits: 1), .verified),
            ("在线全部核对成功且零命中", report([rec("a", "1.0.0", vulnerabilityState: .checked)],
                                                 performed: true, note: "在线查询已完成（OSV + npm registry）"), .verified),
            // 旧判据把这三种"同样不该给绿灯"的结局读成 verified（台账 §RD-13 第 ③ 条），现在各归各位
            ("生态不支持（OSV 不收 SwiftPM）",
             report([rec("a", "1.0.0", ecosystem: .swiftPM, vulnerabilityState: .ecosystemUnsupported)],
                    performed: true, note: "在线查询已完成（OSV + npm registry）"), .unchecked),
            ("版本没解析出来（只有范围）",
             report([rec("a", "^1.0.0", vulnerabilityState: .versionUnresolved)],
                    performed: true, note: "在线查询已完成（OSV + npm registry）"), .unchecked),
        ]

        var legacyDegradedOrUnchecked = 0
        var legacyDegraded = 0
        for entry in cases {
            let judged = VulnerabilityEvidence.classify(entry.report)
            XCTAssertEqual(judged, entry.new, entry.name)
            let legacy = legacyClassify(entry.report)
            if legacy == .degraded || legacy == .unchecked { legacyDegradedOrUnchecked += 1 }
            if legacy == .degraded { legacyDegraded += 1 }
            // **用户点名的那条红线**：原来判"试了没查完"的样本，改完一律不许升成 verified。
            if legacy == .degraded {
                XCTAssertNotEqual(judged, .verified, "保守方向被放松（旧判降级、新判 verified）：\(entry.name)")
            }
            // 旧判"压根没核对"要翻成"已核对"，只有一个合法理由：报告里**确实有正向发现**
            // （内置规则命中本身就是证据，旧判据看不见它，于是带 CVE 的仓库反而整个维度缺席）。
            if legacy == .unchecked, judged == .verified {
                XCTAssertGreaterThan(entry.report.vulnerableCount, 0,
                                     "没有任何正向发现就把未核对翻成已核对：\(entry.name)")
            }
        }
        XCTAssertGreaterThanOrEqual(legacyDegradedOrUnchecked, 6,
                                    "方向表里旧判降级/未核对的样本不足，守卫管不到东西")
        // 单独再数一遍"旧判降级"那一支：它才是用户点名的那条红线所管的样本，不能只靠总数。
        XCTAssertGreaterThanOrEqual(legacyDegraded, 3, "旧判降级的样本不足 3 条 ⇒ 方向线是空跑的")
        // 台账 §RD-13 第 ③ 条：旧判据把"不该给绿灯"的结局一律读成 verified，新判据必须收回来。
        let takenBackGreen: Set<String> = Set(cases.filter { legacyClassify($0.report) == .verified
            && VulnerabilityEvidence.classify($0.report) != .verified }.map(\.name))
        XCTAssertEqual(takenBackGreen, [
            "在线但被预算截断",                      // 上限切掉一批：旧判据看不见
            "部分核对成功、部分没查完",
            "整路硬超时（说明里没有「失败」两个字）",
            "生态不支持（OSV 不收 SwiftPM）",
            "版本没解析出来（只有范围）",
        ], "已确认误报的消除点必须还在：\(takenBackGreen)")
    }

    // MARK: - ② 三处消费同一份证据

    /// 总览（`DependencySafetyVerdict`）、依赖行（`DependencyRowStatus`）、评分
    /// （`VulnerabilityEvidence.classify`）必须读同一份账本：**任何一处独自乐观都算分叉**。
    /// 判据写成互斥矩阵而不是各测各的三遍 —— 分叉的样子就是"总览绿、行灰"。
    func testOverviewRowsAndScoreNeverDisagreeAboutCoverage() {
        let shapes: [(String, DependencyReport)] = [
            ("离线未查", report([rec("a", "1.0.0")])),
            ("在线且核对成功", report([rec("a", "1.0.0", vulnerabilityState: .checked)], performed: true)),
            ("在线但失败", report([rec("a", "1.0.0", vulnerabilityState: .failed)], performed: true)),
            ("版本未解析", report([rec("a", "^1.0.0", vulnerabilityState: .versionUnresolved)], performed: true)),
            ("生态不支持", report([rec("a", "1.0.0", ecosystem: .swiftPM,
                                       vulnerabilityState: .ecosystemUnsupported)], performed: true)),
            ("预算未覆盖", report([rec("a", "1.0.0", vulnerabilityState: .budgetExcluded)], performed: true)),
            ("有命中", report([rec("a", "1.0.0", vulns: ["CVE-1"])])),
        ]
        for (name, subject) in shapes {
            let ledger = DependencyEvidence.ledger(for: subject)
            let verdict = DependencySafetyVerdict(subject, ledger: ledger)
            let evidence = VulnerabilityEvidence.classify(subject)
            let rowStatuses = ledger.records.map { DependencyRowStatus.of(record(subject, $0.name)) }

            // 1. 任何一处"绿"都必须建立在"漏洞这一路已核对"之上。
            if verdict.mayClaimSafe {
                XCTAssertGreaterThan(ledger.vulnerabilityCheckedCount, 0, "\(name)：总览发绿却没有一条核对记录")
                XCTAssertFalse(rowStatuses.contains(.verifiedSafe) && ledger.vulnerabilityCheckedCount == 0,
                               "\(name)：行绿而账本空")
            }
            // 2. 行上出现"正常" ⇒ 该条两路都必须已核对。
            for (record, status) in zip(ledger.records, rowStatuses) where status == .verifiedSafe {
                XCTAssertTrue(record.versionState.isCovered && record.vulnerabilityState.isCovered,
                              "\(name)：行「正常」是由来源种类而不是核对结果推出来的")
            }
            // 3. 评分侧与总览侧对"核对到什么程度"的分歧只允许一种方向：都不许多说。
            if evidence == .verified {
                XCTAssertGreaterThanOrEqual(ledger.vulnerabilityCheckedCount, 1,
                                            "\(name)：评分说已核对，账本里却一条都没有")
            }
            // 4. 未覆盖的每一档都要在**总览文案**里点名（不许只报一个总数）。
            let uncovered = ledger.totalCount - ledger.vulnerabilityCheckedCount
            if uncovered > 0, ledger.vulnerabilityCheckedCount > 0 {
                let statement = DependencyEvidence.findingsStatement(for: subject, ledger: ledger)
                XCTAssertTrue(DependencyEvidence.tailPieces(ledger).allSatisfy(statement.contains),
                              "\(name)：「未发现漏洞」没交代未覆盖的部分：\(statement)")
            }
        }
    }

    /// 「未发现已知漏洞」这句话的两个必要条件：**说得出已核对的条数** + **一条都没落下**。
    func testNoKnownVulnerabilitiesSentenceCarriesScopeAndCount() {
        let fullyChecked = report([rec("a", "1.0.0", vulnerabilityState: .checked),
                                   rec("b", "2.0.0", vulnerabilityState: .checked)], performed: true)
        let ledger = DependencyEvidence.ledger(for: fullyChecked)
        XCTAssertTrue(DependencyEvidence.mayClaimNoKnownVulnerabilities(ledger))
        let statement = DependencyEvidence.findingsStatement(for: fullyChecked, ledger: ledger)
        XCTAssertTrue(statement.contains("已核对 2"), statement)
        XCTAssertTrue(statement.contains("/ 2"), statement)
        XCTAssertTrue(statement.contains("未发现已知漏洞"), statement)

        // 少一条就不许再说这句话。
        var partial = fullyChecked
        partial.ecosystems[0].dependencies[1].vulnerabilityCheckState = .notAttempted
        let partialLedger = DependencyEvidence.ledger(for: partial)
        XCTAssertFalse(DependencyEvidence.mayClaimNoKnownVulnerabilities(partialLedger))
        let partialStatement = DependencyEvidence.findingsStatement(for: partial, ledger: partialLedger)
        XCTAssertTrue(partialStatement.contains("1 / 2"), partialStatement)
        XCTAssertTrue(partialStatement.contains("1 个未查"), partialStatement)

        // 一条都没核对成时，禁止出现"未发现已知漏洞"。
        let offline = report([rec("a", "1.0.0")])
        let offlineStatement = DependencyEvidence.findingsStatement(
            for: offline, ledger: DependencyEvidence.ledger(for: offline))
        XCTAssertFalse(offlineStatement.contains("未发现已知漏洞"),
                       "离线态把「没查」说成「没有病」：\(offlineStatement)")
        XCTAssertTrue(offlineStatement.contains("漏洞核对未覆盖"), offlineStatement)
    }

    /// npm 版本查成功**不得**替代 OSV 查成功：两路各自一条账，谁也不许替谁背书。
    func testRegistrySuccessDoesNotSubstituteOsvSuccess() {
        let subject = report([rec("a", "1.0.0", latest: "9.9.9", versionState: .checked,
                                  vulnerabilityState: .failed)], performed: true)
        let ledger = DependencyEvidence.ledger(for: subject)
        XCTAssertEqual(ledger.versionCheckedCount, 1)
        XCTAssertEqual(ledger.vulnerabilityCheckedCount, 0)
        XCTAssertFalse(DependencyEvidence.mayClaimNoKnownVulnerabilities(ledger))
        // 报告级两本账各记各的（分析器写的形状）。
        var two = subject
        two.versionLookup = DependencyLookupEvidence(source: "内置快照 + npm registry", totalRecords: 1,
                                                    attempted: 1, checked: 1)
        two.vulnerabilityLookup = DependencyLookupEvidence(source: "内置规则 + OSV", totalRecords: 1,
                                                          attempted: 1, failed: 1)
        XCTAssertTrue(two.versionLookup!.hasCoverage)
        XCTAssertFalse(two.vulnerabilityLookup!.hasCoverage, "版本那本账的绿灯不许串到漏洞那本")
        XCTAssertTrue(two.vulnerabilityLookup!.isPartial)
        // 账本里"两路都成功"的条数必须是 0（`isCheckedOnBothAxes` 是唯一口径）。
        XCTAssertEqual(DependencyEvidence.ledger(for: two).records.filter(\.isCheckedOnBothAxes).count, 0)
    }

    // MARK: - ③ 手写坐标串 = RD-12 的病根，扫描守卫要有牙

    /// 生产代码里**不许**再手写 `"\(name)@\(version)"` 这种 key：
    /// 一侧用声明原文、一侧用查询身份，两边永不相等 ⇒ 总览有公告而依赖行不标记。
    /// 唯一合法出口是 `DependencyVersionIdentity.coordinate(ecosystem:name:queryVersion:)`。
    static let coordinateNeedleParts = ["@\\(", "@\" +"]
    static func handBuiltCoordinateFindings(in files: [(path: String, text: String)]) -> [String] {
        files.filter { $0.path.contains("/Services/Dependencies/") || $0.path.contains("/Views/Dependencies/") }
            .compactMap { file in
                let hit = file.text.split(separator: "\n").contains { rawLine in
                    let line = rawLine.trimmingCharacters(in: .whitespaces)
                    if line.hasPrefix("//") || line.hasPrefix("///") { return false }
                    guard coordinateNeedleParts.contains(where: { line.contains($0) }) else { return false }
                    // 只有"拿**记录里的版本原文**拼 key"才算分叉；展示层把已存好的坐标
                    // 三段还原成 `lodash@4.17.15` 是合法的（它不生成 key，只还原文案）。
                    return line.contains("record.version") || line.contains(".$0.version")
                        || line.contains("record.resolvedVersion")
                }
                return hit ? file.path : nil
            }
    }

    func testNoHandBuiltCoordinateStringsRemain() throws {
        let files = try dependencyViewAndServiceSources()
        XCTAssertGreaterThan(files.count, 20, "扫描面小到这个程度说明扫描坏了，不是代码干净")
        XCTAssertTrue(Self.handBuiltCoordinateFindings(in: files).isEmpty,
                      "出现手写坐标串：\(Self.handBuiltCoordinateFindings(in: files))")
    }

    /// 元测试①：坏样例必须抓到。
    func testCoordinateGuardCatchesHandBuiltKey() {
        let bad = [(path: "Sources/TcoderMonitor/Services/Dependencies/X.swift",
                    text: #"let key = \(record.name)@\(record.version)"#)]
        XCTAssertEqual(Self.handBuiltCoordinateFindings(in: bad).count, 1)
    }

    /// 元测试②：合法形状不误伤（展示层还原文案、注释里提到旧拼法）。
    func testCoordinateGuardIgnoresLegalShapes() {
        let legal = [
            (path: "Sources/TcoderMonitor/Services/Dependencies/DependencyVersionIdentity.swift",
             text: ##"return "\(pieces[1])@\(pieces[2])""##),
            (path: "Sources/TcoderMonitor/Services/Dependencies/Y.swift",
             text: "// 旧实现一侧是 pkg@\\(version)，另一侧是 record.version —— 已删"),
            (path: "Sources/TcoderMonitor/Services/Code/Z.swift",
             text: #"let key = \(record.name)@\(record.version)"#),   // 域外，不归这条管
        ]
        XCTAssertTrue(Self.handBuiltCoordinateFindings(in: legal).isEmpty, "合法形状被误伤")
    }

    // MARK: - ④ 分析器账本 vs 手写独立真值（不拿实现输出反推）

    /// 对 WS-F 十生态夹具跑一次**离线**分析，逐条比两本账：
    ///   · 账本 A = 分析器写进报告的 `vulnerabilityCheckState`；
    ///   · 账本 B = 测试自己从内置公告表 + 查询身份推出来的（独立真值）。
    /// 两者必须逐条一致；并且分 scope 每一档的 declared 相加必须等于依赖总数（分母非空）。
    func testAnalyzerLedgerMatchesHandDerivedTruthOnManifestLab() async throws {
        let report = try await ManifestDependencyAnalyzer(options: .default, maxDepth: 6)
            .analyze(projectRoot: root, allowNetwork: false)
        let records = report.ecosystems.flatMap(\.dependencies)
        XCTAssertGreaterThan(records.count, 60, "夹具解析出来的依赖太少 ⇒ 这条对照没有覆盖面")

        var handChecked = 0
        var handVulnerable = 0
        for record in records {
            let queryVersion = DependencyVersionIdentity.of(record).query?.version
            let hits = queryVersion.map {
                VulnerabilitySource.matches(ecosystem: record.ecosystem, name: record.name, version: $0)
            } ?? []
            if !hits.isEmpty { handVulnerable += 1 }
            // 独立推导"这一条的漏洞核对算不算成功"：
            //   内置表命中 ⇒ 确实核对过；OSV 不收该生态 ⇒ 不支持；没有查询身份 ⇒ 版本未解析；
            //   其余（离线没发起在线）⇒ 未查。
            let expected: DependencyCheckState
            if !hits.isEmpty { expected = .checked }
            else if OsvPackageQuery.osvEcosystem(for: record.ecosystem) == nil { expected = .ecosystemUnsupported }
            else if queryVersion == nil { expected = .versionUnresolved }
            else { expected = .notAttempted }
            XCTAssertEqual(record.vulnerabilityCheckState, expected,
                           "账本分叉：\(record.name)@\(record.version) 声明生态 \(record.ecosystem.rawValue)")
            if expected == .checked { handChecked += 1 }
        }
        let ledger = DependencyEvidence.ledger(for: report)
        XCTAssertEqual(ledger.vulnerabilityCheckedCount, handChecked, "已核对条数与手写推导不一致")
        XCTAssertEqual(ledger.vulnerableCount, handVulnerable, "命中条数与手写推导不一致")
        XCTAssertGreaterThan(handVulnerable, 3, "手写推导本身要保证有正向发现，否则上面两条是空跑")

        // 分 scope（RD-13c）：总数必须对得上，且至少四档非空。
        let breakdown = try XCTUnwrap(report.scopeBreakdown, "分析器必须落分 scope 统计")
        XCTAssertEqual(breakdown.reduce(0) { $0 + $1.declared }, report.totalDependencies)
        XCTAssertGreaterThanOrEqual(breakdown.filter { $0.declared > 0 }.count, 4,
                                    "六档里至少四档要有东西，否则分 scope 统计没在被测到")
        XCTAssertEqual(ledger.scopeBreakdown, breakdown, "账本与报告必须是同一份 scope 统计")
    }

    // MARK: - 辅助

    private func record(_ report: DependencyReport, _ name: String) -> DependencyRecord {
        report.ecosystems.flatMap(\.dependencies).first { $0.name == name }
            ?? DependencyRecord(name: name, version: "0", ecosystem: .npm, scope: .runtime,
                                manifestPath: "package.json", latestKnownVersion: nil,
                                versionCheckSource: .none, knownVulnerabilities: [])
    }

    private func dependencyViewAndServiceSources() throws -> [(path: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TcoderMonitor", isDirectory: true)
        let manager = FileManager.default
        var files: [(String, String)] = []
        for directory in ["Services/Dependencies", "Views/Dependencies"] {
            let url = root.appendingPathComponent(directory, isDirectory: true)
            for name in try manager.contentsOfDirectory(atPath: url.path).sorted() where name.hasSuffix(".swift") {
                let path = url.appendingPathComponent(name).path
                guard let data = manager.contents(atPath: path), let text = String(data: data, encoding: .utf8)
                else { continue }
                files.append((path: path, text: text))
            }
        }
        return files
    }
}
