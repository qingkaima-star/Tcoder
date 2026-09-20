import XCTest
@testable import TcoderMonitor

/// OWNER: WS-T（Git 时间口径）。缺陷 #43 的守卫：**历史不足门槛时，
/// 不许把「提交总数」当「日均」输出成"节奏稳定"，也不许因此给活动分量高分。**
///
/// 靶子是本工作树 main `9757722` 的实拍形状：非合并窗口 152 条、首末相隔 51,709 秒
/// （14.36 小时）、含合并总数 271 → 冻结字段 `commitsPerDay` 给出 **271.0**
/// （分母 `max(1, Int(0.598)) = 1`），界面于是写「提交节奏稳定（日均 271.0 次）」。
///
/// 每条守卫都配双向断言（坏例必须被抓、好例必须放过），并对阈值常量做棘轮钉。
final class HealthGitCadenceHonestyTests: HealthScoreTestCase {

    // MARK: - 夹具

    /// 14.36 小时的历史：就是本仓现在的形状（时间一律相对 `Date()`，
    /// 免得断言依赖某个具体时钟读数——同 `HealthScoreTestCase.activeGit()` 的立场）。
    private func burstGit(total: Int = 271, analyzed: Int = 152,
                          spanSeconds: Double = 51_709) -> GitInsights {
        let last = Date()
        let first = last.addingTimeInterval(-spanSeconds)
        return GitInsights(
            isRepository: true, branch: "main", headSHA: String(repeating: "b", count: 40),
            totalCommits: total, commitsAnalyzed: analyzed,
            firstCommitAt: first, lastCommitAt: last,
            totalAdditions: 9_000, totalDeletions: 1_200, filesTouched: 60,
            authors: [author(name: "ws-t", commits: analyzed, first: first, last: last)]
        )
    }

    /// 跑了 400 天、日均 20 次、刚刚还在提交的老实仓库——"节奏稳定"这句话它配说。
    private func matureGit() -> GitInsights {
        let last = Date().addingTimeInterval(-3_600)
        let first = last.addingTimeInterval(-400 * 86_400)
        return GitInsights(
            isRepository: true, branch: "main", headSHA: String(repeating: "c", count: 40),
            totalCommits: 8_200, commitsAnalyzed: 8_000,
            firstCommitAt: first, lastCommitAt: last,
            totalAdditions: 90_000, totalDeletions: 20_000, filesTouched: 400,
            authors: [author(name: "ws-t", commits: 8_000, first: first, last: last)]
        )
    }

    private func component(_ name: String, in score: HealthScore) throws -> ScoreComponent {
        try XCTUnwrap(score.components.first { $0.name == name },
                      "分量 \(name) 必须在场，实得 \(score.components.map(\.name))")
    }

    /// 从 detail 里抽出"日均 X 次提交"的那个数（不猜实现保留几位：连着原文一起返回）。
    private func reportedRate(in detail: String) -> (value: Double, text: String)? {
        let pattern = "日均\\s*([0-9]+(?:\\.[0-9]+)?)\\s*次提交"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: detail, range: NSRange(detail.startIndex..., in: detail)),
              match.numberOfRanges >= 2,
              let captured = Range(match.range(at: 1), in: detail),
              let value = Double(detail[captured]) else { return nil }
        return (value, String(detail[captured]))
    }

    private let activityName = HealthDimension.activity.rawValue

    // MARK: - ① 前提钉：靶子必须真的还是那个靶子（否则守卫在盯一个不存在的缺陷）

    /// 冻结字段自己仍然是退化的：日均 == 提交总数、且远大于 8。
    /// 这条一旦变红，说明 `Models/GitInsights.swift` 被改过了——那 #43 就不必修第二遍了。
    func testFrozenCommitsPerDayIsStillTheDegenerateRuler() {
        let git = burstGit()
        XCTAssertEqual(git.commitsPerDay, 271.0, accuracy: 0.001,
                       "冻结区的日均不再等于提交总数了？#43 的前提变了，请把本流判定一起更新")
        XCTAssertGreaterThanOrEqual(git.commitsPerDay, GitCadenceEvidence.steadyCadenceCommitsPerDay,
                                    "旧加分条件仍然会被这个数满足，否则下面的守卫就是空转")
        // 同窗口真速率 = 152 ÷ 0.5985 天 ≈ 254 次/天：冻结值既被"1 天"分母兜高，
        // 又混进了含合并的分子，两个偏差叠在一起才使这句话成为虚报。
        let honest = Double(152) / (51_709.0 / 86_400)
        XCTAssertGreaterThan(git.commitsPerDay, honest * 1.05,
                             "冻结日均已贴近真速率 \(honest)，本条前提消失，删掉它")
    }

    // MARK: - ② 坏例：短历史不得宣称节奏，也不得拿高分

    func testShortHistoryNeitherClaimsSteadyCadenceNorHighScore() throws {
        let score = WeightedHealthScorer().score(HealthInputs(code: healthyCode(), git: burstGit(),
                                                              logs: healthyLogs()))
        XCTAssertFalse(score.strengths.contains { $0.contains("提交节奏稳定") },
                       "14 小时历史被当成\"节奏稳定\"就是虚报，实得 \(score.strengths)")
        let activity = try component(activityName, in: score)
        XCTAssertLessThanOrEqual(activity.score, Int(GitCadenceEvidence.shortHistoryScoreCeiling),
                                 "样本不足时活跃度必须封顶，实得 \(activity.score)")
        XCTAssertTrue(activity.detail.contains("样本不足"), "detail 必须承认样本不足：\(activity.detail)")
        XCTAssertTrue(activity.detail.contains("14.4") || activity.detail.contains("0.6"),
                      "detail 要报出真实跨度，让人能复核：\(activity.detail)")
        XCTAssertTrue(score.recommendations.contains { $0.contains("跑满一周") || $0.contains("样本不足") },
                      "必须给出一条说清为什么没评节奏的建议，实得 \(score.recommendations)")
    }

    /// detail 里那个"日均"必须是浮点跨度算出来的真速率，而不是退化值 271。
    func testReportedRateIsHonestNotTheCommitTotal() throws {
        let score = WeightedHealthScorer().score(HealthInputs(git: burstGit()))
        let activity = try component(activityName, in: score)
        guard let reported = reportedRate(in: activity.detail) else {
            return XCTFail("detail 里解析不出\"日均 X 次提交\"，本条判据形同虚设：\(activity.detail)")
        }
        let honest = Double(152) / (51_709.0 / 86_400)          // 同窗口分子 ÷ 浮点跨度 ≈ 254.0
        XCTAssertEqual(reported.value, honest, accuracy: 0.6,
                       "报的日均 \(reported.text) 与浮点跨度真值 \(honest) 对不上")
        XCTAssertNotEqual(reported.value, 271.0, accuracy: 0.5,
                          "日均又等于提交总数了，退化分母回来了")
    }

    /// 封顶只许压低：曲线本身更低时必须原样保留，不许被"上限"抬上去。
    func testCeilingOnlyEverLowersTheActivityScore() throws {
        let tiny = WeightedHealthScorer().score(HealthInputs(git: burstGit(total: 2, analyzed: 2,
                                                                           spanSeconds: 6 * 86_400)))
        let tinyCurve = HealthCurves.activity(commitsPerDay: 2.0 / 6.0, daysSinceLastCommit: 0,
                                             totalCommits: 2)
        let tinyActivity = try component(activityName, in: tiny)
        XCTAssertLessThan(tinyCurve.score, GitCadenceEvidence.shortHistoryScoreCeiling,
                          "夹具本该落在上限之下，否则这条测不到\"只压低\"")
        XCTAssertEqual(Double(tinyActivity.score), tinyCurve.score, accuracy: 0.5,
                       "曲线本就低时不得被抬到上限，实得 \(tinyActivity.score) vs 曲线 \(tinyCurve.score)")

        let hot = WeightedHealthScorer().score(HealthInputs(git: burstGit()))
        let hotCurve = HealthCurves.activity(commitsPerDay: 152.0 / (51_709.0 / 86_400),
                                             daysSinceLastCommit: 0, totalCommits: 271)
        let hotActivity = try component(activityName, in: hot)
        XCTAssertGreaterThan(hotCurve.score, GitCadenceEvidence.shortHistoryScoreCeiling + 5,
                             "271 条挤在 14 小时里，曲线本来会给高分，这条前提变了请复核")
        XCTAssertEqual(Double(hotActivity.score), GitCadenceEvidence.shortHistoryScoreCeiling, accuracy: 0.5,
                       "踩到高分时必须被封顶在 60，实得 \(hotActivity.score)")
    }

    // MARK: - ③ 好例必须放过：够长的历史照旧可以宣称节奏

    func testMatureHistoryStillEarnsTheSteadyCadenceStrength() throws {
        let score = WeightedHealthScorer().score(HealthInputs(code: healthyCode(), git: matureGit(),
                                                             logs: healthyLogs()))
        XCTAssertTrue(score.strengths.contains { $0.contains("提交节奏稳定") },
                      "400 天、日均 20 次的仓库当然配这句优点，实得 \(score.strengths)")
        let activity = try component(activityName, in: score)
        XCTAssertGreaterThan(activity.score, Int(GitCadenceEvidence.shortHistoryScoreCeiling),
                             "证据够时不得被封顶压低，实得 \(activity.score)")
        XCTAssertFalse(activity.detail.contains("样本不足"), "够长时不许出现样本不足：\(activity.detail)")
    }

    /// 边界必须钉在 7 天：6.99 天算样本不足，7.000 天算够。
    func testSevenDayBoundaryIsExactlyWhereTheGateSays() {
        func assess(spanDays: Double) -> GitCadenceEvidence.Status {
            let last = Date(timeIntervalSince1970: 1_750_000_000)
            let git = GitInsights(totalCommits: 100, commitsAnalyzed: 100,
                                  firstCommitAt: last.addingTimeInterval(-spanDays * 86_400),
                                  lastCommitAt: last)
            return GitCadenceEvidence.assess(git).status
        }
        XCTAssertEqual(assess(spanDays: 7), .sufficient, "刚好 7 天算够")
        XCTAssertEqual(assess(spanDays: 6.99), .shortHistory, "差一点点仍算样本不足")
        XCTAssertEqual(assess(spanDays: 0.598), .shortHistory)
    }

    // MARK: - ④ 三态：分母无定义就承认未知

    func testMissingEndpointsAreUnknownNotSlow() throws {
        let noDates = GitInsights(totalCommits: 271)                          // 旧报告：没有首末时刻
        XCTAssertEqual(GitCadenceEvidence.assess(noDates).status, .unknown)
        let sameInstant = burstGit(spanSeconds: 0)                            // 首末同一秒
        XCTAssertEqual(GitCadenceEvidence.assess(sameInstant).status, .unknown,
                       "跨度为 0 时速率无定义，不许被兜成\"1 天\"")

        let score = WeightedHealthScorer().score(HealthInputs(git: sameInstant))
        XCTAssertFalse(score.strengths.contains { $0.contains("提交节奏稳定") },
                       "无定义的分母不配写优点，实得 \(score.strengths)")
        let activity = try component(activityName, in: score)
        XCTAssertTrue(activity.detail.contains("无定义"), "detail 必须承认速率无定义：\(activity.detail)")
        XCTAssertLessThan(activity.score, 40, "无定义时按曲线最低档，实得 \(activity.score)")
    }

    /// 旧报告没有 `commitsAnalyzed`（缺字段 = 0）时退回含合并总数，但必须把口径写出来。
    func testLegacyNumeratorFallbackIsDisclosed() {
        let last = Date(timeIntervalSince1970: 1_789_860_583)
        let legacy = GitInsights(totalCommits: 271, commitsAnalyzed: 0,
                                 firstCommitAt: last.addingTimeInterval(-51_709), lastCommitAt: last)
        let evidence = GitCadenceEvidence.assess(legacy)
        XCTAssertFalse(evidence.numeratorSharesSpanWindow, "缺窗口条数时必须标记口径更粗")
        XCTAssertTrue(evidence.shortHistoryNote.contains("含合并"), "注记要交代分子口径：\(evidence.shortHistoryNote)")
        let fresh = GitCadenceEvidence.assess(burstGit())
        XCTAssertFalse(fresh.shortHistoryNote.contains("含合并"), "窗口口径一致时不许乱标注")
    }

    // MARK: - ⑤ 棘轮：三个判据只许往紧拧

    /// 门槛数字写进注释与断言两处，谁放宽谁变红。7 = 浮点跨度残余量化误差 ≤14%
    /// 且与 `HealthCurves.activity` 起扣陈旧的 7 天同一把尺子；8 = 评分器原本就有的
    /// 速率门槛（原样搬来，没放宽）；60 = `graded(score, 85, 65, 45, 25)` 的低风险下沿之下。
    func testThresholdConstantsStayPut() {
        XCTAssertEqual(GitCadenceEvidence.minimumSpanDays, 7,
                       "历史跨度门槛只许提高不许降低：降到 7 以下等于把 #43 放回去")
        XCTAssertEqual(GitCadenceEvidence.steadyCadenceCommitsPerDay, 8,
                       "这条是本流接手前就存在的加分门槛（`git.commitsPerDay >= 8`），不许放宽")
        XCTAssertEqual(GitCadenceEvidence.shortHistoryScoreCeiling, 60,
                       "样本不足的封顶值只许压低不许抬高")
    }

    /// 我自己那把定点格式化尺子也得有真值（detail 里的跨度数字靠它）。
    func testFixedFormattingHasKnownValues() {
        XCTAssertEqual(GitCadenceEvidence.fixed(7), "7")
        XCTAssertEqual(GitCadenceEvidence.fixed(0.598), "0.6")
        XCTAssertEqual(GitCadenceEvidence.fixed(14.36), "14.4")
        XCTAssertEqual(GitCadenceEvidence.fixed(60), "60")
        XCTAssertEqual(GitCadenceEvidence.fixed(.nan), "0", "非有限值不得吐出 nan")
    }

    // MARK: - ⑥ 加权契约不受影响

    func testWeightingInvariantsSurviveShortHistory() throws {
        let score = WeightedHealthScorer().score(fullInputs())
        XCTAssertEqual(score.components.reduce(0) { $0 + $1.weight }, 1.0, accuracy: 1e-6)
        let weighted = score.components.reduce(0.0) { $0 + Double($1.score) * $1.weight }
        XCTAssertEqual(Double(score.overall), weighted.rounded(), accuracy: 1)

        // 两边**同一批维度**（code + git + logs），只有 Git 的历史长短不同，才比得出"谁高谁低"。
        let young = WeightedHealthScorer().score(HealthInputs(code: healthyCode(), git: burstGit(),
                                                             logs: healthyLogs()))
        let mature = WeightedHealthScorer().score(HealthInputs(code: healthyCode(), git: matureGit(),
                                                              logs: healthyLogs()))
        for result in [young, mature] {
            XCTAssertEqual(result.components.reduce(0) { $0 + $1.weight }, 1.0, accuracy: 1e-6,
                           "样本不足也得把权重归一到 1.0，否则 overall 复现不出来")
            let sum = result.components.reduce(0.0) { $0 + Double($1.score) * $1.weight }
            XCTAssertEqual(Double(result.overall), sum.rounded(), accuracy: 1)
        }
        XCTAssertEqual(young.components.count, mature.components.count, "比的必须是同一组维度")
        let youngActivity = try component(activityName, in: young)
        let matureActivity = try component(activityName, in: mature)
        XCTAssertLessThan(youngActivity.score, matureActivity.score,
                          "同一批代码证据下，14 小时历史的活跃度不得高于 400 天历史")
    }

    // MARK: - ⑦ 接线守卫：活跃度分支必须真的走派生判断

    /// 从源码文本里切出 `case .<kind>:` 那一段，到**同一缩进层级**的下一个 `case .`
    /// 或收尾 `}` 为止。嵌套 switch 的 case 深一档（缩进不同），不会被误当成终点——
    /// 活跃度分支里就嵌着一个三态 switch。
    private func branch(of kind: String, in source: String) -> String? {
        let lines = source.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "case .\(kind):" }),
              start + 1 <= lines.count else { return nil }
        let indent = Self.leadingSpaces(lines[start])
        var collected: [String] = []
        for line in lines[(start + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if Self.leadingSpaces(line) == indent, trimmed.hasPrefix("case .") || trimmed == "}" { break }
            collected.append(line)
        }
        return collected.joined(separator: "\n")
    }

    private static func leadingSpaces(_ line: String) -> Int {
        line.prefix(while: { $0 == " " }).count
    }

    /// 判据：活跃度分支里不许再**直接读**冻结区那个退化日均（`git.commitsPerDay`）。
    /// 先剥掉 `//` 注释——本流在注释里解释这个字段为什么退化，注释不是读取；
    /// 曲线参数标签 `commitsPerDay:` 也不算读那个字段。
    private func detectDegenerateCadenceUse(in branch: String) -> String? {
        let code = branch.components(separatedBy: "\n")
            .map { line in line.components(separatedBy: "//").first ?? "" }
            .joined(separator: "\n")
        return code.contains("git.commitsPerDay") ? "活跃度分支直接读了 commitsPerDay（退化分母）" : nil
    }

    /// 元测试：抽取器与判据必须**双向**有效——坏例判红、好例判绿，
    /// 否则这条守卫会悄悄空转（比如抽取器哪天切不出段落，判据就永远看到空串）。
    func testWiringGuardCatchesRegressionAndPassesFix() throws {
        let badSource = [
            "        switch dimension {",
            "        case .activity:",
            "            guard let git = inputs.git, git.totalCommits > 0 else { return nil }",
            "            let curve = HealthCurves.activity(commitsPerDay: git.commitsPerDay,",
            "                                             daysSinceLastCommit: nil, totalCommits: 1)",
            "            if git.commitsPerDay >= 8 { strengths.append(\"提交节奏稳定\") }",
            "            return curve",
            "        case .busFactor:",
            "            return nil",
            "        }",
        ].joined(separator: "\n")
        let badBranch = try XCTUnwrap(branch(of: "activity", in: badSource), "抽取器必须能切出这段")
        XCTAssertFalse(badBranch.isEmpty, "抽出空段落 = 守卫在看空气，永真绿")
        XCTAssertNotNil(detectDegenerateCadenceUse(in: badBranch), "坏例必须被抓到，否则守卫是摆设")
        XCTAssertEqual(Self.leadingSpaces("            x"), 12, "缩进层级判定本身也得对")
        XCTAssertNil(detectDegenerateCadenceUse(in: "        case .testing:\n            return nil"),
                     "别的分支里有同名字段不该被算进活跃度的账")
        XCTAssertNil(detectDegenerateCadenceUse(in: "            // 冻结区的 git.commitsPerDay 是退化分母\n"),
                     "注释里提一句字段名不得被判成读取，否则这条守卫会误伤讲解")
        XCTAssertNotNil(detectDegenerateCadenceUse(in: "            if git.commitsPerDay >= 8 { }\n"),
                        "同一行前半段是真读取时仍须抓到")

        let real = try scorerSource()
        let goodBranch = try XCTUnwrap(branch(of: "activity", in: real),
                                      "活跃度分支的写法变了，抽取器对不上号了，请同步")
        XCTAssertFalse(goodBranch.contains("case .busFactor"), "抽取必须停在下一个同级 case 之前")
        XCTAssertTrue(goodBranch.contains("case .sufficient"), "嵌套三态 switch 必须整段被抽到")
        XCTAssertNil(detectDegenerateCadenceUse(in: goodBranch), "现状必须是干净的")
        XCTAssertTrue(goodBranch.contains("GitCadenceEvidence"), "活跃度分支必须真的用上了派生判断")
    }

    private func scorerSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TcoderMonitorTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // TcoderMonitor
            .appendingPathComponent("Sources/TcoderMonitor/Services/Health/WeightedHealthScorer.swift")
        guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else {
            throw AnalysisError.empty("读不到评分器源码：\(url.path)")
        }
        return text
    }
}
