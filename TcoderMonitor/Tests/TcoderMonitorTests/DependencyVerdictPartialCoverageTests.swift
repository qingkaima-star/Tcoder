import XCTest
@testable import TcoderMonitor

// OWNER: WS-R39 DepVerdict · RD-68（台账：同一道事实两道闸、其中一道说反话）
//
// # 这条缺陷的真身（不是文案问题，是**判据分叉**）
// 修之前 `DependencySafetyVerdict.init` 的分支条件是 `vulnerabilityCheckedCount > 0`，
// 于是「6 条依赖只核对了 4 条」与「6 条全部核对」落进同一个 `.clean`；
// 那两个数虽然挂在 `.clean` 身上，**三个出口没有一个去读它们**：
//   · `mayClaimSafe` 见 `.clean` 一律 true（绿色「安全」结论照给），
//   · `role` 见 `.clean` 一律 `Theme.Semantic.success`，
//   · 安全公告空列表那句一律打「已完成核对，未发现已知漏洞。」—— 部分覆盖时「已完成核对」是假的。
// 而同一份数据的另一把尺子 `DependencyEvidence.mayClaimNoKnownVulnerabilities` 要求严格相等。
//
// # 期望值从哪来（AGENTS §8 第 6 条：不许拿实现返回值当期望）
// 本文件的账是**测试自己手写的**：`ledger(six:four)` 逐条写下哪几条 `.checked`、哪几条 `.notAttempted`，
// 期望值「已核对 4 / 6 个依赖，另外 2 个没查 —— 这是「没查全」，不是「没有漏洞」」
// 是**照措辞模板手抄的字面量**（下面 `expectedPartialSentence`），不是跑一遍实现回填的。
// 4、6、2 三个数各出现一次，任何一处把它们换掉都会红。

final class DependencyVerdictPartialCoverageTests: XCTestCase {

    /// 手写期望：部分覆盖那一档的**唯一一句**（三出口必须逐字等于它）。
    private static let expectedPartialSentence =
        "已核对 4 / 6 个依赖，另外 2 个没查 —— 这是「没查全」，不是「没有漏洞」"
    /// 手写期望：全覆盖那一档的那一句。
    private static let expectedCleanSentence = "已核对 6 / 6 个依赖，未发现已知漏洞"

    // MARK: - 夹具：6 条依赖、4 条核对成功

    /// 手写行为表：`pkg0...pkg{checked-1}` 的漏洞这一路 `.checked`，紧接一条 `.failed`，其余 `.notAttempted`。
    /// ⇒ 已核对 **checkedCount**、总共 **6**、未覆盖 **6-checkedCount**（三个数都是本文件写下的，不是读回来的）。
    private func ledger(checkedCount: Int, withFindings: Bool = false) -> DependencyReport {
        let records: [DependencyRecord] = (0..<6).map { index in
            var record = DependencyRecord(name: "pkg\(index)", version: "1.0.0", ecosystem: .npm,
                                          scope: .runtime, manifestPath: "package.json",
                                          latestKnownVersion: "1.0.0",
                                          versionCheckSource: .onlineRegistry,
                                          knownVulnerabilities: index == 0 && withFindings ? ["V1"] : [])
            record.versionCheckState = .checked
            record.vulnerabilityCheckState = vulnerabilityState(index: index, checkedCount: checkedCount)
            return record
        }
        var report = DependencyReport(analyzedAt: Fixture.commit(sha: Fixture.shaA, date: Date()).date)
        report.ecosystems = [EcosystemReport(ecosystem: .npm, manifestPath: "package.json",
                                             lockfileName: nil, dependencies: records,
                                             frameworkMarkers: [])]
        report.networkLookupPerformed = checkedCount > 0
        report.vulnerabilityLookup = DependencyLookupEvidence(source: "内置规则 + OSV",
                                                             totalRecords: 6, attempted: 6,
                                                             checked: checkedCount)
        report.versionLookup = DependencyLookupEvidence(source: "内置快照 + npm registry",
                                                       totalRecords: 6, attempted: 6, checked: 6)
        if withFindings {
            report.offlineVulnerabilities = [DependencyVulnerability(
                id: "V1", package: "pkg0", ecosystem: .npm, vulnerableRange: "< 2.0.0",
                fixedVersion: "2.0.0", summary: "样例命中", severity: .medium,
                cveIdentifiers: ["CVE-0000-0001"], affectedDependencies: ["pkg0@1.0.0"])]
        }
        return report
    }

    /// 逐条落账的三档：核成 / 核失败 / 压根没查。**一条都没核成时不留 `.failed`** ——
    /// 否则「发起了但没收齐」会被评分侧读成 degraded，与本轮要钉的 unchecked 档混成一格。
    private func vulnerabilityState(index: Int, checkedCount: Int) -> DependencyCheckState {
        if index < checkedCount { return .checked }
        return checkedCount > 0 && index == checkedCount ? .failed : .notAttempted
    }

    /// 无头出口：把这份依赖报告塞进唯一那份 schema，走 `score` 的文本装配口。
    /// 必须带 `health`，否则「漏洞核对状态」那一段整段不打（`CLIScoreText.render` 的排布）。
    private func cliText(of deps: DependencyReport) -> String {
        var report = ProjectReport(project: MonitoredProject(name: "RD68", path: "/tmp/tcoder-rd68"))
        report.dependencies = deps
        report.health = WeightedHealthScorer().score(HealthInputs(dependencies: deps))
        return CLIScoreText.render(report, exit: .ok)
    }

    private func dependencyLines(_ text: String) -> String {
        text.split(separator: "\n").filter { $0.contains("漏洞核对") }.joined(separator: " ⏎ ")
    }

    // MARK: - ① 独立真值：这份账必须是 6 条里核对了 4 条

    func testIndependentTruthLedgerIsFourOfSix() throws {
        let report = ledger(checkedCount: 4)
        let book = DependencyEvidence.ledger(for: report)
        XCTAssertEqual(book.totalCount, 6, "手写：清单里躺着 6 条依赖")
        XCTAssertEqual(book.vulnerabilityCheckedCount, 4, "手写：其中 4 条漏洞这一路核成了")
        XCTAssertEqual(book.vulnerabilityStateCounts[.notAttempted], 1)
        XCTAssertEqual(book.vulnerabilityStateCounts[.failed], 1, "剩两条一个没查、一个查失败")
        XCTAssertEqual(book.vulnerableCount, 0, "手写：一条命中都没有（所以最容易被说成「干净」）")
    }

    // MARK: - ② 部分覆盖必须是**另一件事实**，不是 `.clean`

    /// 修前红的那一条：`vulnerabilityCheckedCount > 0` 让 4/6 落进 `.clean`。
    func testPartialCoverageIsItsOwnFactNotClean() throws {
        let report = ledger(checkedCount: 4)
        let verdict = DependencySafetyVerdict(report)

        XCTAssertEqual(verdict, .partiallyCovered(coveredCount: 4, total: 6),
                       "4/6 必须长成「部分覆盖」这一态，而不是带着两个数的 `.clean`")
        XCTAssertFalse(verdict.mayClaimSafe, "部分覆盖时 `mayClaimSafe` 必须为假")
        XCTAssertNotEqual(verdict.role, Theme.Semantic.success, "绿色只留给全覆盖")
        XCTAssertEqual(verdict.role, Theme.Semantic.warning, "缺口必须出声，不许缩成中性灰")
        XCTAssertNotEqual(verdict.badgeIcon, .clean, "图标通道也不许说「干净」（色觉障碍下靠它）")
        XCTAssertEqual(verdict.badgeIcon, .unverified)
        XCTAssertEqual(verdict.badgeText, "部分核对")
        XCTAssertTrue(verdict.tileCaption.contains("部分核对"), verdict.tileCaption)
        XCTAssertFalse(verdict.tileCaption.contains("已联网核对，"), verdict.tileCaption)
    }

    /// RD-77 钉：`DependencyVulnerabilityCoverage.full(total:)` 那枚句子的字面是「未发现已知漏洞」，
    /// 而这句话只在**零命中**时才成立 —— 类型本身没编码这件事（台账卷五 §82 的 RD-77）。
    /// 今天四个出口都靠"先判命中、再分档"的顺序躲开它；顺序一旦被人搬走，
    /// 或者下一个调用点直接拿 `.full(total:).statement` 去画别的东西，就是这里红，
    /// 而不是等它长成一屏没人怀疑的假话。
    func testFullCoverageWithFindingsNeverSpeaksTheAllClearAtAnyExit() throws {
        let report = ledger(checkedCount: 6, withFindings: true)
        let book = DependencyEvidence.ledger(for: report)
        // 三条前提逐条自证：覆盖度确实是 `.full`、账上确实有命中，否则整条断言在空跑。
        XCTAssertTrue(DependencyEvidence.vulnerabilityCoverage(book).isFull,
                      "前提不成立：这份账不是全覆盖，那下面测的就不是这一档")
        XCTAssertGreaterThan(report.vulnerableCount, 0, "前提不成立：这份账没有命中")
        XCTAssertEqual(book.vulnerabilityCheckedCount, 6, "前提：六条全核成")

        let verdict = DependencySafetyVerdict(report)
        guard case .findings(let count, _) = verdict else {
            return XCTFail("有命中却没落在 .findings ⇒ 命中被覆盖度那一档吞掉了：\(verdict)")
        }
        XCTAssertEqual(count, report.vulnerableCount)

        let allClear = "未发现已知漏洞"
        let statement = DependencyEvidence.findingsStatement(for: report, ledger: book)
        for (exit, text) in [("屏上结论格", verdict.summaryCaption),
                             ("屏上安全公告空态", verdict.advisoryEmptyCaption),
                             ("无头出口", dependencyLines(cliText(of: report))),
                             ("报告级陈述句", statement)] {
            XCTAssertFalse(text.contains(allClear), "\(exit) 在有命中时说「\(allClear)」：\(text)")
        }
    }

    /// 反例钉死：部分覆盖这一态在**任何出口**都不许出现「已完成核对」这一句。
    func testPartialCoverageNeverClaimsTheSweepIsFinished() throws {
        let report = ledger(checkedCount: 4)
        let verdict = DependencySafetyVerdict(report)
        let cli = cliText(of: report)
        let statement = DependencyEvidence.findingsStatement(
            for: report, ledger: DependencyEvidence.ledger(for: report))

        for (exit, text) in [("屏上结论格", verdict.summaryCaption),
                             ("屏上安全公告空态", verdict.advisoryEmptyCaption),
                             ("无头出口", dependencyLines(cli)),
                             ("报告级陈述句", statement)] {
            XCTAssertFalse(text.contains("已完成核对"), "\(exit) 在只核对了 4/6 时说「已完成核对」：\(text)")
            XCTAssertFalse(text.contains("全量覆盖"), "\(exit) 把部分覆盖报成全量：\(text)")
            XCTAssertFalse(text.contains("零命中"), "\(exit) 给出了 all-clear：\(text)")
        }
        XCTAssertFalse(cli.contains("全量覆盖且零命中"), dependencyLines(cli))
    }

    // MARK: - ③ 部分覆盖那一句：三出口**逐字**同源

    func testPartialSentenceIsVerbatimTheSameAtAllThreeExits() throws {
        let report = ledger(checkedCount: 4)
        let verdict = DependencySafetyVerdict(report)
        let book = DependencyEvidence.ledger(for: report)
        let cli = cliText(of: report)

        // 出口一：屏上（结论格副标题 + 安全公告空态那一句，两处都必须是装配口那一枚）。
        XCTAssertEqual(verdict.summaryCaption, Self.expectedPartialSentence)
        XCTAssertEqual(verdict.advisoryEmptyCaption, Self.expectedPartialSentence)
        // 出口二：无头出口里同一句原文出现在「漏洞核对状态」那一行。
        XCTAssertTrue(dependencyLines(cli).contains(Self.expectedPartialSentence),
                      "CLI 那句与屏上不同源：\(dependencyLines(cli))")
        // 出口三：报告级陈述句以同一句开头（后面只补「未覆盖的那几档分别是什么」）。
        let statement = DependencyEvidence.findingsStatement(for: report, ledger: book)
        XCTAssertTrue(statement.hasPrefix(Self.expectedPartialSentence), statement)
        // 三件事必须齐：已核对几条 / 总共几条 / 没查不等于没有漏洞。
        XCTAssertTrue(statement.contains("已核对 4 / 6"), statement)
        XCTAssertTrue(statement.contains("另外 2 个没查"), statement)
        XCTAssertTrue(statement.contains("没查全"), statement)
        // 落盘那一格与账本同一份数（第三出口的「字段」那一半）。
        XCTAssertEqual(book.vulnerabilityLookup?.checked, 4)
        XCTAssertEqual(book.vulnerabilityLookup?.totalRecords, 6)
    }

    // MARK: - ④ 四态 × 三出口：逐态各钉一句

    /// 手写四态真值表（任何两态互换句子都会红）：
    ///   findings        1 命中 / 共 6              ⇒ 报命中，绝不说「没有已知漏洞」
    ///   unchecked       0 核成 / 共 6              ⇒ 说未联网，绝不说「未发现已知漏洞」
    ///   partiallyCovered 4 核成 / 共 6             ⇒ 装配口那一句（三出口逐字相同）
    ///   clean           6 核成 / 共 6              ⇒ 才配「未发现已知漏洞」+ 绿色
    func testEachStateSpeaksOneSentenceAtThreeExits() throws {
        let cases: [(name: String, checked: Int, findings: Bool,
                     expectPartial: Bool, expectGreen: Bool, expectAllClear: Bool)] = [
            ("findings", 4, true, false, false, false),
            ("unchecked", 0, false, false, false, false),
            ("部分覆盖", 4, false, true, false, false),
            ("全覆盖", 6, false, false, true, true),
        ]
        for item in cases {
            let report = ledger(checkedCount: item.checked, withFindings: item.findings)
            let verdict = DependencySafetyVerdict(report)
            let cli = dependencyLines(cliText(of: report))

            XCTAssertEqual(verdict.mayClaimSafe, item.expectGreen, item.name)
            XCTAssertEqual(verdict.role == Theme.Semantic.success, item.expectGreen, item.name)

            switch item.name {
            case "findings":
                guard case .findings(let count, _) = verdict else {
                    return XCTFail("有 1 条命中却给了 \(verdict)")
                }
                XCTAssertEqual(count, 1, item.name)
                XCTAssertFalse(verdict.summaryCaption.contains("未发现已知漏洞"), verdict.summaryCaption)
                XCTAssertFalse(cli.contains("未发现已知漏洞"), cli)
            case "unchecked":
                XCTAssertEqual(verdict, .unchecked(coveredCount: 6, total: 6, uncoveredEcosystems: []),
                               "一条都没核成 ⇒ 未核对档（`coveredCount` 记的是版本那一维）")
                XCTAssertTrue(verdict.summaryCaption.contains("未联网核对"), verdict.summaryCaption)
                XCTAssertTrue(verdict.summaryCaption.contains("6 / 6 项有版本数据"), verdict.summaryCaption)
                XCTAssertFalse(verdict.summaryCaption.contains("未发现已知漏洞"), verdict.summaryCaption)
                XCTAssertFalse(verdict.advisoryEmptyCaption.contains("未发现已知漏洞"),
                               verdict.advisoryEmptyCaption)
                XCTAssertTrue(verdict.advisoryEmptyCaption.contains("没有查"), verdict.advisoryEmptyCaption)
            case "部分覆盖":
                XCTAssertTrue(item.expectPartial)
                XCTAssertEqual(verdict.summaryCaption, Self.expectedPartialSentence, item.name)
                XCTAssertTrue(cli.contains(Self.expectedPartialSentence), cli)
            default:
                XCTAssertEqual(verdict, .clean(total: 6), item.name)
                XCTAssertEqual(verdict.summaryCaption, Self.expectedCleanSentence, item.name)
                XCTAssertTrue(item.expectAllClear)
                XCTAssertTrue(verdict.advisoryEmptyCaption.contains("已完成核对"),
                              verdict.advisoryEmptyCaption)
            }
        }
    }

    /// 全覆盖是唯一配说「已完成核对」的一档，且屏上 / 报告级陈述句 / CLI 三处同口径。
    func testFullCoverageIsTheOnlyStateAllowedTheAllClearAndSharesOneSentence() throws {
        let report = ledger(checkedCount: 6)
        let book = DependencyEvidence.ledger(for: report)
        let verdict = DependencySafetyVerdict(report)

        XCTAssertTrue(DependencyEvidence.vulnerabilityCoverage(book).isFull)
        XCTAssertTrue(DependencyEvidence.mayClaimNoKnownVulnerabilities(book))
        XCTAssertTrue(verdict.mayClaimSafe)
        XCTAssertEqual(verdict.summaryCaption, Self.expectedCleanSentence)
        // 报告级陈述句必须含同一句（后面只补数据源括号）。
        XCTAssertTrue(DependencyEvidence.findingsStatement(for: report, ledger: book)
                        .hasPrefix(Self.expectedCleanSentence))
        // 判据与总览**同向**：闸门说可以，总览才说可以。
        XCTAssertEqual(verdict.role, Theme.Semantic.success)
        XCTAssertEqual(verdict.badgeText, "已核对")
    }

    // MARK: - ⑤ 闸门同向：三道尺子对同一份账不许给出相反结论

    /// RD-68 的病根就是「两把尺子方向相反」。把三把尺子摆在同一条断言里：
    /// **闸门说不行 ⇒ 总览也必须说不行**，四个档各验一次。
    func testGateAndOverviewAgreeOnEveryTier() throws {
        for checked in [0, 1, 4, 5, 6] {
            let report = ledger(checkedCount: checked)
            let book = DependencyEvidence.ledger(for: report)
            let verdict = DependencySafetyVerdict(report)
            XCTAssertEqual(DependencyEvidence.mayClaimNoKnownVulnerabilities(book),
                           verdict.mayClaimSafe,
                           "闸门与总览对「已核对 \(checked)/6」给出相反结论")
            XCTAssertEqual(DependencyEvidence.vulnerabilityCoverage(book).isFull, verdict.mayClaimSafe,
                           "档位与总览分叉：\(checked)/6")
        }
    }

    // MARK: - ⑥ 评分侧不受本次改动影响（爆炸半径的机器证明）

    /// 评分那一路读的是 `DependencyEvidence.ledger` 的**结构化状态**，不是本枚举
    /// （`VulnerabilityEvidence.classify`）。RD-68 只收「绿色/安全/已完成核对」这句话，
    /// 一条评分输入都不许动 —— 动了就是越界改他人流的口径。
    /// 手写期望：0/6 一条没发起 ⇒ `.unchecked`；4/6 与 5/6 发起了没查完 ⇒ `.degraded`；
    /// 6/6 零命中 ⇒ `.verified`。三档都不许因为本次改动往上跳。
    func testScoringInputIsUntouchedByTheVerdictRuler() throws {
        let expectations: [(Int, VulnerabilityEvidence)] = [
            (0, .unchecked), (1, .degraded), (4, .degraded), (5, .degraded), (6, .verified),
        ]
        for (checked, expected) in expectations {
            let report = ledger(checkedCount: checked)
            XCTAssertEqual(VulnerabilityEvidence.classify(report), expected,
                           "已核对 \(checked)/6 这一档的评分证据态被本次改动挪动了")
        }
    }
}
