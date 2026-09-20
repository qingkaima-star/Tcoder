/// OWNER: WS-X3 TestSplit —— 自 DesignAbsenceStateTests.swift 拆出，四态字面量互斥、无证据不得下结论、占比与首提交文案。用例本体未改，只是搬了家。
import Foundation
import XCTest
@testable import TcoderMonitor

extension DesignAbsenceStateTests {

    /// 四个态**各自的中文字面**互不相同、都不是空串。
    /// `indeterminate` ≠ `notAnalysed` 是这张工单存在的理由，单独再钉一条（见下一条）。
    func testFourStateLiteralsAreMutuallyDistinctAndNonEmpty() {
        let states: [(name: String, term: String, display: String)] = [
            ("value", DataAbsence.value("42").term, DataAbsence.value("42").display),
            ("measuredEmpty", DataAbsence.measuredEmpty.term, DataAbsence.measuredEmpty.display),
            ("indeterminate", DataAbsence.indeterminate.term, DataAbsence.indeterminate.display),
            ("notAnalysed", DataAbsence.notAnalysed.term, DataAbsence.notAnalysed.display),
        ]
        XCTAssertEqual(states.count, 4, "四态少一个，这张工单就白做")
        for state in states {
            XCTAssertFalse(state.term.isEmpty, "\(state.name) 的态名字面是空串")
            XCTAssertFalse(state.display.isEmpty, "\(state.name) 的显示字面是空串")
        }
        XCTAssertEqual(Set(states.map(\.term)).count, 4,
                       "四态字面撞车：\(states.map { "\($0.name)=\($0.term)" })")
        XCTAssertEqual(Set(states.map(\.display)).count, 4,
                       "四态数字位字面撞车：\(states.map { "\($0.name)=\($0.display)" })")
    }

    /// 最关键的一条：除零不能借用「没查」的 `--`。
    func testIndeterminateNeverSharesTheNotAnalysedLiteral() {
        XCTAssertNotEqual(DataAbsence.indeterminate.display, DataAbsence.notAnalysed.display,
                          "「算不出」与「未分析」共用同一个字面，用户就没法分清"
                              + "「这项目真的没有」和「我们没查」——本轮收敛的就是这件事")
        XCTAssertNotEqual(DataAbsence.indeterminate.term, DataAbsence.measuredEmpty.term,
                          "「分母为 0」也不是「查了但是空的」")
        XCTAssertEqual(DataAbsence.notAnalysed.display, Theme.Placeholder.missingValue,
                       "「没查」仍是全仓那个 `--`，字面本体只有一个定义处")
    }

    /// 真 0 与「查了但是空的」都必须和「没查」不同：`0` 是结论，不许塌成占位符。
    func testRealZeroAndMeasuredEmptyStayApartFromNotAnalysed() {
        XCTAssertEqual(DataAbsence.value("0").display, "0")
        XCTAssertEqual(DataAbsence.measuredEmpty.display, NumberFormat.grouped(0))
        XCTAssertNotEqual(DataAbsence.measuredEmpty.display, DataAbsence.notAnalysed.display)
        XCTAssertNotEqual(DataAbsence.value("0").display, DataAbsence.notAnalysed.display)
    }

    /// 文字槽位（日期 / 名称）：`measuredEmpty` 在那里渲染成 `0` 会被读成假数字，
    /// 所以它另有字面；而 `--` 仍只有「没查」这一态在用。
    func testTextSlotsNeverRenderMeasuredEmptyAsAFakeNumber() {
        XCTAssertEqual(DataAbsence.measuredEmpty.textDisplay, "无记录")
        XCTAssertNotEqual(DataAbsence.measuredEmpty.textDisplay, DataAbsence.measuredEmpty.display)
        XCTAssertEqual(DataAbsence.value("2024-01-02").textDisplay, "2024-01-02")
        XCTAssertEqual(DataAbsence.notAnalysed.textDisplay, DataAbsence.notAnalysed.display)
        XCTAssertEqual(DataAbsence.indeterminate.textDisplay, DataAbsence.indeterminate.display)
    }

    func testStatesWithoutEvidencePermitNoConclusion() {
        XCTAssertTrue(DataAbsence.value("3").permitsConclusion)
        XCTAssertTrue(DataAbsence.measuredEmpty.permitsConclusion,
                      "「查了、确实是空的」本身就是结论，这一态可以给定心丸语气")
        XCTAssertFalse(DataAbsence.indeterminate.permitsConclusion,
                       "算不出撑不起一句安心话")
        XCTAssertFalse(DataAbsence.notAnalysed.permitsConclusion, "没查更不行")
    }

    func testEvidenceFreeStatesForceNeutralRole() {
        for state in [DataAbsence.indeterminate, .notAnalysed] {
            XCTAssertEqual(state.effectiveRole(Theme.Semantic.success).name, "neutral",
                             "\(state) 态不该保留调用方给的倾向色")
        }
        XCTAssertEqual(DataAbsence.value("0").effectiveRole(Theme.Semantic.success).name, "success",
                       "真值（含真 0）的着色归调用方")
        XCTAssertEqual(DataAbsence.measuredEmpty.effectiveRole(Theme.Semantic.success).name, "success")
    }

    /// 悬停口径：`indeterminate` 必须说出分母是什么（§14.3 第 1 条的「或加 help:」这一支），
    /// 且三句说明彼此不同、都不许出现「没问题 / 正常」这类结论词。
    func testHelpSentencesDifferAndNameTheDenominator() {
        XCTAssertNil(DataAbsence.value("7").help(denominator: "总行数"))
        let text = DataAbsence.indeterminate.help(denominator: "总行数") ?? ""
        XCTAssertTrue(text.contains("总行数"), "算不出这一态的 help 必须点出分母：\(text)")
        XCTAssertTrue(text.contains("0"), "算不出这一态要说明是分母为 0：\(text)")
        for fragment in ["没问题", "正常", "无风险"] {
            XCTAssertFalse(text.contains(fragment), "help 里不许藏结论词「\(fragment)」：\(text)")
        }
        let notAnalysed = DataAbsence.notAnalysed.help() ?? ""
        let measuredEmpty = DataAbsence.measuredEmpty.help() ?? ""
        XCTAssertEqual(Set([text, notAnalysed, measuredEmpty]).count, 3,
                       "三种空位的说明撞成一句，用户还是分不清")
        XCTAssertTrue(notAnalysed.contains("没"), "「没查」的说明要认得出是没查：\(notAnalysed)")
        XCTAssertTrue(measuredEmpty.contains("已完成扫描"),
                      "「查了但是空的」必须交代查过（《40》§7.3 句式）：\(measuredEmpty)")
    }

    /// `optional(absent:)` 把「选哪一态」变成形参：调用点被迫表态，不许默认糊过去。
    func testOptionalConstructorKeepsTheStateChoiceExplicit() {
        XCTAssertEqual(DataAbsence.optional(nil), .notAnalysed, "不表态时默认「没查」")
        XCTAssertEqual(DataAbsence.optional(nil, absent: .indeterminate), .indeterminate)
        XCTAssertEqual(DataAbsence.optional("8"), .value("8"))
        XCTAssertEqual(DataAbsence.optional("", absent: .notAnalysed), .value(""),
                       "空串是调用方给的真值，不能顺手当缺失")
    }

    func testDivideByZeroAnchorsRenderAsIndeterminate() {
        XCTAssertEqual(CodeMetricsSummaryGrid.shareOf(10, CodeMetrics()),
                       DataAbsence.indeterminate.display,
                       "总行数 0 → 占比算不出，不是没扫")
        XCTAssertEqual(CodeScaleSection.averageFileLines(CodeMetrics()),
                       DataAbsence.indeterminate.display,
                       "行数与文件数都是 0 → 平均算不出")
        XCTAssertEqual(CodeRiskAnalysis.averageComplexityValue(CodeMetrics(totalFiles: 1, totalLines: 10)),
                       DataAbsence.indeterminate.display,
                       "一个函数都没识别出来 → 均值算不出，既不是 0 也不是没扫")
        for anchor in [CodeMetricsSummaryGrid.shareOf(10, CodeMetrics()),
                       CodeScaleSection.averageFileLines(CodeMetrics()),
                       CodeRiskAnalysis.averageComplexityValue(CodeMetrics())] {
            XCTAssertNotEqual(anchor, Theme.Placeholder.missingValue,
                              "锚点又退回和「没查」共用 `--`，语义塌陷回来了")
        }
    }

    /// 分母在场时照实给比值——不许把「算不出」当成新的偷懒默认值到处盖。
    func testRatiosStillRenderWhenTheDenominatorExists() {
        XCTAssertEqual(CodeMetricsSummaryGrid.shareOf(0, CodeMetrics(totalFiles: 4, totalLines: 100)), "0%",
                       "真 0% 是结论")
        XCTAssertEqual(CodeScaleSection.averageFileLines(CodeMetrics(totalFiles: 4, totalLines: 40)), "10.0")
    }

    func testContributorShareUsesIndeterminateNotNotAnalysed() {
        // `authorShare` 在分母（非合并提交数）为 0 时给 nil；这一格的 help 原文就写着「占比无法计算」。
        let git = GitInsights()
        let author = AuthorStats(name: "张三", email: "z@e.com", commits: 1,
                                 additions: 2, deletions: 3, filesTouched: 1,
                                 firstCommitAt: nil, lastCommitAt: nil,
                                 activityByHour: [], topDirectories: [:])
        XCTAssertNil(git.authorShare(of: author),
                     "夹具要造的是「分母为 0」，不然这条测试没在量东西")
        let absence = DataAbsence.optional(git.authorShare(of: author).map { NumberFormat.percent($0) },
                                           absent: .indeterminate)
        XCTAssertEqual(absence, .indeterminate)
        XCTAssertEqual(absence.display, DataAbsence.indeterminate.display)
        XCTAssertNotEqual(absence.display, DataAbsence.notAnalysed.display)
    }

    /// 「首次提交」这一格：空仓库（查了、真的没有）与没跑分析（没查）是两句话。
    func testFirstCommitCaptionSeparatesEmptyRepositoryFromNoAnalysis() {
        XCTAssertEqual(GitRepositoryInfoSection.firstCommitCaption(GitInsights()),
                       DataAbsence.notAnalysed.display, "压根不是仓库 / 没跑分析 → 没查")
        XCTAssertEqual(GitRepositoryInfoSection.firstCommitCaption(
                           GitInsights(isRepository: true, totalCommits: 0)),
                       DataAbsence.measuredEmpty.textDisplay,
                       "是仓库且 0 次提交 → 查了、真的没有，这一态不能写成 `--`")
        XCTAssertNotEqual(GitRepositoryInfoSection.firstCommitCaption(
                              GitInsights(isRepository: true, totalCommits: 0)),
                          GitRepositoryInfoSection.firstCommitCaption(GitInsights()),
                          "两态撞回同一个字面，就是本轮要修的毛病")
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(GitRepositoryInfoSection.firstCommitCaption(
                           GitInsights(isRepository: true, totalCommits: 3, firstCommitAt: stamp)),
                       DateFormat.full.string(from: stamp))
    }

}
