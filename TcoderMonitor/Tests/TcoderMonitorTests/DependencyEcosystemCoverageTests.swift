// OWNER: WS-R41 EcoSysVerdict · RD-70（台账卷五 §81：那份账的**第四个出口** —— 生态卡头）
//
// # 这一格坏在哪（不是文案，是**真假绿**）
// R39（RD-68）把「能不能说没有已知漏洞」收成一道闸（`DependencyEvidence.vulnerabilityCoverage`
// 三档 + 话术只产自 `statement`），收了三处出口，**漏了第四处**：
// `DependenciesView.DependencyEcosystemSection` 的开关是 `deps.hasVulnerabilityCoverage == false`，
// 而那枚字段的本体是 `networkLookupPerformed || !advisories.isEmpty` —— 正是 RD-11 记过的旧闸门
// （**「发过请求」被当成「核对过」**）。于是「两条查询全失败」的那份报告里：
// 账本 `vulnerabilityCheckedCount == 0`、页面上方写着「共 2 个依赖，一条都没核对」、
// 下方每个生态卡头却走 `RiskBadge(risk: .none)` = 对勾 +「风险：无」。
// 为什么谁都拦不住它：改之前 `git grep -l DependencyEcosystemSection -- TcoderMonitor/Tests` 是**空集**
// （本文件跑的就是那条命令的现量，见 `test_meta_theZeroThatStartedThisCase`），
// 这一格零用例，RD-11 与 RD-68 那两族用例一个都管不到它。
//
// # 期望值从哪来（AGENTS §8 第 6 条：不许拿实现返回值当期望）
// · 「查询全失败」那一份是**独立证据**：复用 `DependencyAttemptedVsCheckedTests` 同形状的
//   真分析器 + `StubOnlineSource`（不新造夹具），发出几条查询由假源自己回读。
// · 「混合形状」那一份是**测试自己手写的行为表**（npm 3 条 `.checked` + SwiftPM 2 条 `.notAttempted`），
//   3 / 2 / 5 三个数都是本文件写下的，任何一处换掉都会红。
// · 断言的是**分派结果**（`DependencyEcosystemRiskSlot`：走哪一支徽标），画法那一层由
//   `test_cardDrawingBindsEachSlotToItsOwnBadge` 那把静态尺子钉（本仓不许为了测一格界面去开 App，
//   AGENTS §3 横切约束 2.1/2.2）。证据等级：全部 in-process 断言 + 静态扫描，**没有实拍/AX 出证**。
import XCTest
@testable import TcoderMonitor

final class DependencyEcosystemCoverageTests: XCTestCase {

    /// 两个内置快照与公告表都没收录的包名 + 精确版本 ⇒ 「没核成」是被测的、不是碰巧的。
    private static let manifest = #"{"name":"app","dependencies":{"acme-alpha":"1.0.0","acme-beta":"2.0.0"}}"#

    /// 手写期望：一条都没核成那一档的**唯一一句**（与 `statement` 逐字比对）。
    private static let noneSentence = "共 2 个依赖，一条都没核对 —— 这是「没查全」，不是「没有漏洞」"
    /// 手写期望：npm 那三行逐条核成那一句。
    private static let fullNpmSentence = "已核对 3 / 3 个依赖，未发现已知漏洞"
    /// 手写期望：报告级那一档（3 核成 / 共 5）—— 用来证明"按报告级涂卡头"会说什么。
    private static let partialReportSentence =
        "已核对 3 / 5 个依赖，另外 2 个没查 —— 这是「没查全」，不是「没有漏洞」"

    // MARK: - 夹具

    private func analyze(_ files: [String: String], tag: String,
                         online: (any DependencyOnlineSource)?,
                         allowNetwork: Bool) async throws -> DependencyReport {
        let root = try makeTree(tag, files: files)
        let analyzer = online == nil
            ? ManifestDependencyAnalyzer(options: .default, maxDepth: 3)
            : ManifestDependencyAnalyzer(options: .default, maxDepth: 3, onlineSource: online!)
        return try await analyzer.analyze(projectRoot: root, allowNetwork: allowNetwork)
    }

    private func makeTree(_ tag: String, files: [String: String]) throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tcoder-rd70-\(tag)-\(UUID().uuidString.prefix(8))", isDirectory: true)
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

    /// 手写一条依赖（只给本文件用得上的那几格）。
    private func record(_ name: String, ecosystem: DependencyEcosystem,
                        vulnerability: DependencyCheckState) -> DependencyRecord {
        var one = DependencyRecord(name: name, version: "1.0.0", ecosystem: ecosystem,
                                   scope: .runtime, manifestPath: "package.json",
                                   latestKnownVersion: nil, versionCheckSource: .none,
                                   knownVulnerabilities: [])
        one.versionCheckState = vulnerability
        one.vulnerabilityCheckState = vulnerability
        return one
    }

    /// 混合形状：**npm 全量核完 + SwiftPM 一条没查** ⇒ 报告级因此是 `.partial`。
    private func mixedReport() -> (report: DependencyReport, npm: EcosystemReport, swiftPM: EcosystemReport) {
        let npm = EcosystemReport(ecosystem: .npm, manifestPath: "package.json", lockfileName: nil,
                                  dependencies: (1...3).map {
                                      record("npm-\($0)", ecosystem: .npm, vulnerability: .checked)
                                  }, frameworkMarkers: [])
        let swiftPM = EcosystemReport(ecosystem: .swiftPM, manifestPath: "Package.swift", lockfileName: nil,
                                      dependencies: (1...2).map {
                                          record("spm-\($0)", ecosystem: .swiftPM, vulnerability: .notAttempted)
                                      }, frameworkMarkers: [])
        var report = DependencyReport()
        report.ecosystems = [npm, swiftPM]
        report.networkLookupPerformed = true
        return (report, npm, swiftPM)
    }

    /// 卡头那一格：与 `DependenciesView` 同一个装配形状（报告账本 → 子账 → 唯一分档入口 → 分派）。
    private func slot(eco: EcosystemReport, ledger: DependencyEvidenceLedger) -> DependencyEcosystemRiskSlot {
        DependencyEcosystemBadge.slot(riskLevel: eco.riskLevel,
                                      coverage: DependencyEvidence.vulnerabilityCoverage(
                                        ledger.subledger(forEcosystem: eco.ecosystem)))
    }

    // MARK: - ① 真红用例：查询全失败 ⇒ 卡头必须走中性那一支，不许是 `RiskBadge(.none)`

    /// 与 `DependencyAttemptedVsCheckedTests.testFailedOrTimedOutLookupSitsInTheSameTierAsUnchecked`
    /// 同一份报告（两条 OSV 点名失败、registry 那一路全答上）。
    func testAllQueriesFailedSitsInNeutralSlotNotTheAllClearOne() async throws {
        let coordinateA = DependencyVersionIdentity.coordinate(ecosystem: .npm, name: "acme-alpha",
                                                               queryVersion: "1.0.0")
        let coordinateB = DependencyVersionIdentity.coordinate(ecosystem: .npm, name: "acme-beta",
                                                               queryVersion: "2.0.0")
        let stub = StubOnlineSource(failedCoordinates: [coordinateA, coordinateB],
                                    latestVersions: ["acme-alpha": "1.0.0", "acme-beta": "2.0.0"])
        let report = try await analyze(["package.json": Self.manifest], tag: "all-failed",
                                       online: stub, allowNetwork: true)

        // ---- 独立真值：先把缺陷的机制钉住，再判卡头 ----
        XCTAssertEqual(stub.receivedOsvQueries.count, 2, "前提：两条查询确实发出去了")
        XCTAssertTrue(report.networkLookupPerformed, "前提：报告级写着「发过请求」")
        XCTAssertTrue(report.hasVulnerabilityCoverage,
                      "旧闸门在这份报告上判的是「有覆盖」——语义不许改（它另有读者），改的是这一格的读法")
        let ledger = DependencyEvidence.ledger(for: report)
        XCTAssertEqual(ledger.totalCount, 2, "手写：两条依赖")
        XCTAssertEqual(ledger.vulnerabilityCheckedCount, 0, "两条全失败 ⇒ 核成的条数是 0，不是 2")
        XCTAssertEqual(DependencyEvidence.vulnerabilityCoverage(ledger), .none(total: 2))

        let eco = try XCTUnwrap(report.ecosystems.first)
        XCTAssertEqual(eco.riskLevel, .none, "零命中让 `riskLevel` 说「无风险」——卡头只能靠覆盖度背书")
        let decided = self.slot(eco: eco, ledger: ledger)
        XCTAssertEqual(decided, .unchecked,
                       "一条都没核成的生态卡头走成了 \(decided)：all-clear 那一支在这一档是假的")
        XCTAssertNotEqual(decided, .riskBadge, "`.riskBadge` 就是 `RiskBadge(.none)`（对勾 +「风险：无」）那一支")
        XCTAssertEqual(DependencyEvidence.vulnerabilityCoverage(ledger.subledger(forEcosystem: .npm))
                           .statement, Self.noneSentence, "hover 那句必须逐字取自唯一装配口")
    }

    // MARK: - ② 反向用例：逐条真核成过 ⇒ 对勾**仍然要出现**（防止"一律涂灰"糊过去）

    func testFullyCheckedEcosystemStillGetsTheAllClearBadge() async throws {
        let stub = StubOnlineSource(latestVersions: ["acme-alpha": "1.0.0", "acme-beta": "2.0.0"])
        let report = try await analyze(["package.json": Self.manifest], tag: "all-checked",
                                       online: stub, allowNetwork: true)
        let ledger = DependencyEvidence.ledger(for: report)
        XCTAssertEqual(ledger.totalCount, 2)
        XCTAssertEqual(ledger.vulnerabilityCheckedCount, 2, "手写期望：两条都核成了")
        let eco = try XCTUnwrap(report.ecosystems.first)
        XCTAssertEqual(eco.riskLevel, .none)
        XCTAssertEqual(self.slot(eco: eco, ledger: ledger), .riskBadge,
                       "逐条全核成、零命中 —— 这时还不发 all-clear 就是另一种不准")
        // 「`.riskBadge` 在 `riskLevel == .none` 时就是那枚对勾」不许靠读代码默认成立：
        // 文字那一通道由下面这条钉（屏上是「风险：无」）；图标与画法那一通道由 ⑤ 的
        // `test_cardDrawingBindsEachSlotToItsOwnBadge`（静态绑定）钉。
        // ⚠ 这里**不**直接调 `RiskBadge.icon(for:)`：那是 `@MainActor` 的成员，
        // 测试侧同步调它会拿一条并发隔离警告（Swift 6 语言模式下就是错误）。
        XCTAssertEqual(RiskLevel.none.rawValue, "无", "all-clear 那句的档位词")
        // ⚠ 取色上 `Theme.Semantic.role(for: .none)` 是 `neutral`（绿属于 `.low` 那一档），
        // 所以这一格的"假安心"由**图标 +「风险：无」那句话**承载，不是颜色 —— 上面钉的是这两样。
    }

    // MARK: - ③ 混合形状：分档必须按生态，报告级档位会冤枉那个真查全了的

    func testPerEcosystemTierDoesNotPunishTheFullyCheckedEcosystem() throws {
        let (report, npm, swiftPM) = mixedReport()
        let ledger = DependencyEvidence.ledger(for: report)

        // 报告级：3 核成 / 5 条 ⇒ `.partial`。拿它涂卡头就会把 npm 那张也说成「没查全」。
        XCTAssertEqual(ledger.totalCount, 5, "手写：3 + 2 = 5 条")
        XCTAssertEqual(ledger.vulnerabilityCheckedCount, 3, "手写：只有 npm 那 3 条核成了")
        let reportCoverage = DependencyEvidence.vulnerabilityCoverage(ledger)
        XCTAssertEqual(reportCoverage, .partial(covered: 3, total: 5))
        XCTAssertFalse(reportCoverage.isFull, "前提：报告级不是全覆盖（否则下面在空跑）")

        // 子账：同一枚 `vulnerabilityCoverage`，喂的是各自那本子账；数只能来自筛行。
        let npmLedger = ledger.subledger(forEcosystem: .npm)
        let swiftLedger = ledger.subledger(forEcosystem: .swiftPM)
        XCTAssertEqual(DependencyEvidence.vulnerabilityCoverage(npmLedger), .full(total: 3))
        XCTAssertEqual(DependencyEvidence.vulnerabilityCoverage(swiftLedger), .none(total: 2))
        XCTAssertEqual(npmLedger.totalCount, 3)
        XCTAssertEqual(npmLedger.vulnerabilityCheckedCount, 3)
        XCTAssertEqual(swiftLedger.totalCount, 2)
        XCTAssertEqual(swiftLedger.vulnerabilityCheckedCount, 0)

        XCTAssertEqual(self.slot(eco: npm, ledger: ledger), .riskBadge, "npm 那张卡：对勾（它真全核完）")
        XCTAssertEqual(self.slot(eco: swiftPM, ledger: ledger), .unchecked, "SwiftPM 那张不是")
        // 报告级与 npm 子账必须是**两个不同的值**（否则"按生态"这件事根本没在跑），
        // 而那三句话仍然只由同一枚装配口 `statement` 产出 —— 话术一处都不新增。
        XCTAssertNotEqual(DependencyEvidence.vulnerabilityCoverage(npmLedger), reportCoverage)
        XCTAssertEqual(reportCoverage.statement, Self.partialReportSentence)
        XCTAssertEqual(DependencyEvidence.vulnerabilityCoverage(npmLedger).statement, Self.fullNpmSentence)
    }

    // MARK: - ④ 部分覆盖那一档 + 三档互不折叠

    func testPartiallyCheckedEcosystemIsItsOwnSlot() throws {
        var npm = EcosystemReport(ecosystem: .npm, manifestPath: "package.json", lockfileName: nil,
                                  dependencies: [record("a", ecosystem: .npm, vulnerability: .checked),
                                                 record("b", ecosystem: .npm, vulnerability: .failed)],
                                  frameworkMarkers: [])
        npm.dependencies[1].knownVulnerabilities = []          // 手写：零命中（最容易被说成"干净"）
        var report = DependencyReport()
        report.ecosystems = [npm]
        let ledger = DependencyEvidence.ledger(for: report)
        let coverage = DependencyEvidence.vulnerabilityCoverage(ledger)
        XCTAssertEqual(coverage, .partial(covered: 1, total: 2), "手写：1 核成 / 1 查失败")
        let slot = DependencyEcosystemBadge.slot(riskLevel: npm.riskLevel, coverage: coverage)
        XCTAssertEqual(slot, .partiallyChecked, "部分覆盖既不是 all-clear 也不是「没查」，实得 \(slot)")
        XCTAssertEqual(coverage.statement,
                       "已核对 1 / 2 个依赖，另外 1 个没查 —— 这是「没查全」，不是「没有漏洞」")
    }

    /// 三档必须分得开（all-clear / 琥珀 / 中性互不折叠）。
    func testThreeTiersNeverCollapseIntoEachOther() throws {
        let (report, npm, swiftPM) = mixedReport()
        let ledger = DependencyEvidence.ledger(for: report)
        let full = self.slot(eco: npm, ledger: ledger)
        let none = self.slot(eco: swiftPM, ledger: ledger)
        let partial = DependencyEcosystemBadge.slot(riskLevel: .none, coverage: .partial(covered: 1, total: 2))
        XCTAssertEqual([full, partial, none], [.riskBadge, .partiallyChecked, .unchecked])
        XCTAssertNotEqual(full, partial)
        XCTAssertNotEqual(full, none)
        XCTAssertNotEqual(partial, none)
    }

    /// 已经查出问题的生态不许被覆盖度那一格**吞掉**：坏消息照旧上屏（P7-B 那条边界不动）。
    func testEcosystemWithFindingsStillShowsItsOwnRisk() throws {
        let hit = record("lodash", ecosystem: .npm, vulnerability: .checked)
        var withFinding = hit
        withFinding.knownVulnerabilities = ["CVE-2021-23337"]
        let eco = EcosystemReport(ecosystem: .npm, manifestPath: "package.json", lockfileName: nil,
                                  dependencies: [withFinding], frameworkMarkers: [])
        XCTAssertEqual(eco.riskLevel, .high, "手写：带命中的生态判高风险")
        XCTAssertEqual(DependencyEcosystemBadge.slot(riskLevel: eco.riskLevel, coverage: .none(total: 1)),
                       .riskBadge, "卡头只替「没查出问题」那一档背书，坏消息不许被改成中性")
    }

    // MARK: - ⑤ 扫描型守卫：第四号出口不许再读那把旧闸门

    /// 旧闸门的字面特征：读 `hasVulnerabilityCoverage`，或再传那枚 `vulnerabilityUnchecked` 开关。
    static let legacyGateMarkers = ["hasVulnerabilityCoverage", "vulnerabilityUnchecked"]
    /// 唯一合法装配形状：卡头的档位由「子账 → `vulnerabilityCoverage`」出来。
    static let requiredWiring = ["subledger(forEcosystem:", "DependencyEvidence.vulnerabilityCoverage("]
    /// 入参声明位（**不许有默认值**：给了默认值就能被漏传）。
    static let parameterPrefix = "let vulnerabilityCoverage: DependencyVulnerabilityCoverage"
    /// 卡头 `body` 那三臂的表头（画法与槽位的绑定关系）。
    static let slotArms = ["case .riskBadge:", "case .partiallyChecked:", "case .unchecked:"]

    static func legacyGateHits(in files: [(path: String, content: String)]) -> [String] {
        var out: [String] = []
        for file in files {
            for line in SurfaceScanKit.codeLines(file.content) {
                for marker in legacyGateMarkers where line.contains(marker) {
                    out.append("\(file.path) → \(marker)")
                }
            }
        }
        return out.sorted()
    }

    static func wiringHits(in files: [(path: String, content: String)]) -> Set<String> {
        let code = files.flatMap { SurfaceScanKit.codeLines($0.content) }.joined(separator: "\n")
        return Set(requiredWiring.filter { code.contains($0) })
    }

    static func defaultedParameters(in files: [(path: String, content: String)]) -> [String] {
        var out: [String] = []
        for file in files {
            for line in SurfaceScanKit.codeLines(file.content) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix(parameterPrefix), trimmed.contains("=") {
                    out.append("\(file.path) → \(trimmed)")
                }
            }
        }
        return out
    }

    /// 卡头 `switch` 三臂的原文（按表头切片，遇下一臂或收尾 `}` 为止）。
    static func arms(ofBadge text: String) -> [String: String] {
        let lines = SurfaceScanKit.codeLines(text)
        var out: [String: String] = [:]
        for label in slotArms {
            guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == label })
            else { continue }
            var arm: [String] = []
            for line in lines[(start + 1)...] {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if slotArms.contains(trimmed) || trimmed == "}" { break }
                arm.append(trimmed)
            }
            out[label] = arm.joined(separator: "\n")
        }
        return out
    }

    /// 画法判据的纯函数版：槽位 ↔ 徽标绑错就报（元测试因此能在内存里造坏样例）。
    static func drawingFindings(arms: [String: String]) -> [String] {
        var out: [String] = []
        let expected: [(arm: String, must: String, mustNot: String)] = [
            ("case .riskBadge:", "RiskBadge(risk: eco.riskLevel)", "SemanticBadge("),
            ("case .partiallyChecked:", "SemanticBadge(\"部分核对\", role: Theme.Semantic.warning, icon: .unverified)", "RiskBadge("),
            ("case .unchecked:", "SemanticBadge(\"未核对\", role: Theme.Semantic.neutral, icon: .unverified)", "RiskBadge("),
        ]
        for rule in expected {
            guard let arm = arms[rule.arm] else {
                out.append("找不到 \(rule.arm) 那一臂（分派被改写或整格搬家了）")
                continue
            }
            if !arm.contains(rule.must) { out.append("\(rule.arm) 没画成「\(rule.must)」：\(arm)") }
            if arm.contains(rule.mustNot) { out.append("\(rule.arm) 里出现了 \(rule.mustNot)") }
        }
        // 话术那一半：两臂的 hover 只许取装配口那一句，不许在视图里现写带数的句子。
        for arm in ["case .partiallyChecked:", "case .unchecked:"] {
            guard let text = arms[arm] else { continue }
            if !text.contains(".help(coverage.statement)") {
                out.append("\(arm) 的 hover 不再取自唯一装配口：\(text)")
            }
        }
        return out
    }

    func testEcosystemCardIsWiredToThePerEcosystemTierOnly() throws {
        let files = try SurfaceScanKit.sourceFiles(under: "Views/Dependencies")
        XCTAssertGreaterThanOrEqual(files.count, 4,
                                    "只扫到 \(files.count) 个依赖页文件 ⇒ 扫描面坏了，下面全是永真绿")
        XCTAssertTrue(files.contains { $0.path.hasSuffix("DependenciesView.swift") },
                      "扫描面里没有 DependenciesView.swift ⇒ 这条守卫在空跑")
        XCTAssertEqual(Self.legacyGateHits(in: files), [],
                       "依赖页又去读那把「发过请求＝核对过」的旧闸门了（RD-11 在第四号出口复活）")
        XCTAssertEqual(Self.wiringHits(in: files), Set(Self.requiredWiring),
                       "卡头没接在唯一分档入口上（子账 / `vulnerabilityCoverage` 至少缺一条）")
        XCTAssertEqual(Self.defaultedParameters(in: files).count, 0,
                       "卡头的覆盖度入参被加了默认值 ⇒ 漏传就不会再有人知道")
        // 分母自证：入参声明位本身必须扫得到，否则上一条断言是空转。
        let declared = files.flatMap { SurfaceScanKit.codeLines($0.content) }
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix(Self.parameterPrefix) }
        XCTAssertEqual(declared.count, 1, "卡头入参声明位应当恰好一处，实得 \(declared)")

        // 画法那一层的绑定（尺子在内存里判，坏样例见下面的元测试）。
        let badge = try XCTUnwrap(files.first { $0.path.hasSuffix("DependencyAdvisoryRows.swift") }?.content,
                                  "扫不到卡头的宿主文件 ⇒ 这条在空跑")
        let arms = Self.arms(ofBadge: badge)
        XCTAssertEqual(arms.count, Self.slotArms.count, "三臂没扫全（分派被改写）：\(arms.keys.sorted())")
        XCTAssertEqual(Self.drawingFindings(arms: arms), [], "槽位与徽标的绑定被改写了")
    }

    // MARK: - ⑥ 元测试（扫描型守卫必须有牙）

    /// 起点那条「不该为 0 的桶归零」：改前这一格**零用例**
    /// （现量：`git grep -l DependencyEcosystemSection -- TcoderMonitor/Tests` 在改前是空集），
    /// 本条把"这一格有人管了"钉成机读事实，并给分母自证（扫不到测试文件当场红）。
    func testMeta_theZeroThatStartedThisCase() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".swift") }
        XCTAssertGreaterThanOrEqual(names.count, 100, "只数到 \(names.count) 个测试文件 ⇒ 分母不对")
        let readers = names.filter { name in
            let text = (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
            return text.contains("DependencyEcosystemBadge") || text.contains("DependencyEcosystemSection")
        }
        XCTAssertEqual(readers.sorted(), ["DependencyEcosystemCoverageTests.swift"],
                       "卡头这一格的用例面应当恰好由本文件覆盖，实得 \(readers.sorted())")
        print("【RD-70 用例面】扫 Tests \(names.count) 个文件 → 读卡头那格的只有 \(readers.sorted())（改前 0 个）")
    }

    /// 注入第二处必红、只在注释里提一句不红、干净文件不红、画法绑错必红。
    func testMeta_cardRulersCatchInjectedCopiesAndSpareComments() throws {
        let dirty = [(path: "Views/Dependencies/Fake.swift",
                      content: "struct S { let x: Bool\n"
                         + "  init(_ d: DependencyReport) { x = d.hasVulnerabilityCoverage } }\n")]
        XCTAssertEqual(Set(Self.legacyGateHits(in: dirty)),
                       ["Views/Dependencies/Fake.swift → hasVulnerabilityCoverage"],
                       "旧闸门被抄回第二处却没抓到 ⇒ 这条守卫没有牙")
        let commented = [(path: "Views/Dependencies/Fake2.swift",
                          content: "// 旧判据是 deps.hasVulnerabilityCoverage == false —— 已废\n"
                              + "/// 别再传 vulnerabilityUnchecked 这一格\nstruct Clean { let y = 1 }\n")]
        XCTAssertTrue(Self.legacyGateHits(in: commented).isEmpty,
                      "注释里讲旧写法被判红 ⇒ 没人能在判据旁边解释它为什么存在")
        let clean = [(path: "Views/Dependencies/Fake3.swift", content: "enum Clean { let x = 1 }\n")]
        XCTAssertTrue(Self.legacyGateHits(in: clean).isEmpty, "干净文件被误报")
        XCTAssertTrue(Self.wiringHits(in: clean).isEmpty, "没接装配口的文件却被判「已接上」")

        // 默认值那把尺子双向：加了默认值要抓、没加不许抓。
        let defaulted = "  \(Self.parameterPrefix) = .none(total: 0)\n"
        XCTAssertEqual(Self.defaultedParameters(in: [(path: "Views/Dependencies/Fake4.swift",
                                                      content: defaulted)]).count, 1, "默认值没被抓到")
        XCTAssertTrue(Self.defaultedParameters(in: commented).isEmpty)

        // 画法那把尺子三向：把 `.unchecked` 那一臂改回 all-clear（本次缺陷的形状）必须红、
        // 把 hover 改成视图里现写的句子必须红、正确的三臂不许红。
        let wrongArm = ["case .riskBadge:": "RiskBadge(risk: eco.riskLevel)",
                        "case .partiallyChecked:": "SemanticBadge(\"部分核对\", role: Theme.Semantic.warning, icon: .unverified)\n.help(coverage.statement)",
                        "case .unchecked:": "RiskBadge(risk: .none)"]
        XCTAssertEqual(Self.drawingFindings(arms: wrongArm).count, 3,
                       "「未核对」那一臂被改回绿底对勾却没被抓全 ⇒ 画法这把尺子是空的")
        let handWrittenSentence = ["case .riskBadge:": "RiskBadge(risk: eco.riskLevel)",
                                   "case .partiallyChecked:": "SemanticBadge(\"部分核对\", role: Theme.Semantic.warning, icon: .unverified)\n.help(\"还有 1 个没查\")",
                                   "case .unchecked:": "SemanticBadge(\"未核对\", role: Theme.Semantic.neutral, icon: .unverified)\n.help(coverage.statement)"]
        let sentenceFindings = Self.drawingFindings(arms: handWrittenSentence)
        XCTAssertEqual(sentenceFindings.count, 1, "视图里现写覆盖度话术没被抓到（RD-68 的第二把嘴）")
        XCTAssertTrue(sentenceFindings.first?.contains("不再取自唯一装配口") == true,
                      "抓到的是别的东西，报错会指错方向：\(sentenceFindings)")
        let right = Self.arms(ofBadge: try XCTUnwrap(
            SurfaceScanKit.sourceFiles(under: "Views/Dependencies")
                .first { $0.path.hasSuffix("DependencyAdvisoryRows.swift") }?.content))
        XCTAssertTrue(Self.drawingFindings(arms: right).isEmpty, "正确的画法被误报：\(right)")
    }
}
