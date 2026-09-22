/// OWNER: WS-R9 评分口径与措辞（分支 `ws/r9-wording`）—— 工单 R9 三条靶子的守卫。
///
/// 判据对象是**评分口径与措辞**，不是分值：本文件不许出现"分数应该更高/更低"的断言，
/// 也不钉任何阈值数字（阈值与权重都在冻结口径里，本流一个字节没改）。
///
/// 靶子 1（RD-29）：`HealthCurves.busFactor` 的 `commitBasis == 0` 那一支原先给
/// `score 70 + 「提交记录过少，暂不评估协作分布」` —— 话说不评估、数照进加权。
/// 先证可达性（见下面 `test_zeroAuthorBasis…` 与 Obsidian `121`），再把占位分摘掉：
/// 「没有可算作者分布的总体」由 `WeightedHealthScorer.busFactorOutcome` 判成**整维缺席**，
/// 走 `HealthBreakdown.missingDimensions` 那条已存在的路，并把原因显示到界面上。
///
/// 四态各自可观测：正例（有总体照常计分）/ 反例（0 总体必须缺席）/
/// 未知（`git == nil`：不是仓库）/ 失败（`failedSections` 含「Git 分析」）。
import XCTest
@testable import TcoderMonitor

final class ScoreWordingTests: HealthScoreTestCase {

    private var busFactorName: String { HealthDimension.busFactor.rawValue }
    private var activityName: String { HealthDimension.activity.rawValue }

    /// 作者表为空、但仓库有提交（含合并口径）—— 靶子 1 的输入形状。
    private func gitWithoutAuthorBasis(commits: Int = 5) -> GitInsights {
        var git = GitInsights(totalCommits: commits, commitsAnalyzed: commits)
        git.authors = []
        return git
    }

    private func report(git: GitInsights?, failed: [String] = []) -> ProjectReport {
        var report = ProjectReport(project: MonitoredProject(name: "r9", path: "/tmp/r9"))
        report.git = git
        report.attemptedAt = Date()
        report.failedSections = failed
        return report
    }

    // MARK: - ① 反例：0 总体 ⇒ 整维缺席，且不进加权

    func test_zeroAuthorBasis_absentsTheWholeDimensionInsteadOfScoringAPlaceholder() throws {
        let score = WeightedHealthScorer().score(HealthInputs(git: gitWithoutAuthorBasis()))

        XCTAssertFalse(score.components.contains { $0.name == busFactorName },
                       "协作分布必须整维缺席，不许带一个占位分参与加权")
        XCTAssertTrue(HealthBreakdown.missingDimensions(of: score).contains(.busFactor),
                      "缺席要能在 missingDimensions 里被点名（界面与 CLI 都读这一份）")
        XCTAssertTrue(score.recommendations.contains { $0.contains("协作分布不参与本次计分") },
                      "缺席还要出声：实得 \(score.recommendations)")

        // 独立真值：只有活跃度在场时，综合分只能等于活跃度自己 —— 没有任何东西替它抬一手。
        let activity = try XCTUnwrap(score.components.first { $0.name == activityName })
        XCTAssertEqual(score.overall, activity.score,
                       "综合分被没证据的那一维动过了：overall \(score.overall) vs 在场项 \(activity.score)")
        XCTAssertTrue(HealthBreakdown.isSumConsistent(HealthBreakdown.sumOfContributions(
            HealthBreakdown.rows(for: score)), with: score.overall))
    }

    // MARK: - ② 曲线本体：70 那个占位分不许回来

    func test_busFactorCurve_noLongerReturnsTheSeventyPlaceholder() {
        let guardCase = HealthCurves.busFactor(risk: .none, topAuthorShare: 0,
                                               activeAuthors: 0, commitBasis: 0)
        XCTAssertNotEqual(guardCase.score, 70, "「暂不评估」不配有一个进加权的数")
        XCTAssertTrue(guardCase.detail.contains("不该计分"),
                      "死支必须自报「这不是评估结果」：\(guardCase.detail)")
        XCTAssertEqual(guardCase.risk, .critical,
                       "万一守卫被改动，宁可当场砸出一个显眼的低分，也不许悄悄抬一手")
        assertCurveIsValid(guardCase, context: "busFactor 无总体（内部守卫）")

        // 负数同样不许走正常计分
        let negative = HealthCurves.busFactor(risk: .low, topAuthorShare: 0.5,
                                              activeAuthors: 2, commitBasis: -3)
        XCTAssertEqual(negative.score, guardCase.score, "负总体必须与零总体同一处理")
    }

    /// 反例的边界：有一笔总体时**不许**被新守卫顺手摘掉（否则就是往判死方向改口径）。
    func test_singleCommitBasis_isStillScored() {
        let curve = HealthCurves.busFactor(risk: .low, topAuthorShare: 1.0,
                                           activeAuthors: 1, commitBasis: 1)
        XCTAssertGreaterThan(curve.score, 0, "一笔总体虽然单薄，但它是证据，不能按没证据处理")
        XCTAssertTrue(curve.detail.contains("1 次非合并提交"),
                      "总体只有 1 笔时必须把分母写在脸上：\(curve.detail)")
    }

    // MARK: - ③ 上屏：这一维为什么不参与计分，要看得见

    func test_missingReason_namesTheNoAuthorBasisCase() {
        let text = MissingDimensionReason.text(for: .busFactor, report: report(git: gitWithoutAuthorBasis()))
        XCTAssertTrue(text.contains("非合并") && text.contains("不参与计分"),
                      "第③档要说出「没有可算总体」，不许落到兜底句：\(text)")
    }

    /// 未知态：压根不是仓库（`git == nil`）时不许套用第③档那句话。
    func test_missingReason_forNonRepositoryStaysDistinct() {
        let text = MissingDimensionReason.text(for: .busFactor, report: report(git: nil))
        XCTAssertTrue(text.contains("不是 Git 仓库"), "实得 \(text)")
        XCTAssertFalse(text.contains("非合并"), "没取到历史与没有总体是两件事，不许混成一句")
    }

    /// 零提交仓库：是仓库、但一笔提交都没有 —— 第②档。
    func test_missingReason_forEmptyRepository() {
        let text = MissingDimensionReason.text(for: .busFactor,
                                               report: report(git: GitInsights(totalCommits: 0)))
        XCTAssertTrue(text.contains("没有任何提交"), "实得 \(text)")
    }

    /// 失败态：整路分析器报过失败时，原因必须是"那一路失败了"，不是"这一维没总体"。
    func test_missingReason_whenGitAnalyzerFailed() {
        let text = MissingDimensionReason.text(for: .busFactor,
                                               report: report(git: gitWithoutAuthorBasis(), failed: ["Git 分析"]))
        XCTAssertTrue(text.contains("失败"), "实得 \(text)")
    }

    // MARK: - ④ 可达性钉子：死支不许被改活

    /// `HealthCurves.busFactor` 的 0 总体那一支只剩"内部守卫"一个用途，所以它**必须**不可达：
    /// 唯一的生产调用点在 `HealthTeamDimensions.busFactorOutcome`，那里已经先判
    /// `authorBasisCommits > 0`。这条判据读的是源码形状 —— 一旦有人加第二个调用点
    /// 而不再先判总体，它就红（这正是它存在的理由：可达路径一变就响）。
    ///
    /// ⚠ **先剥注释再判**（与 `SourceFileReachabilityTests` 同一立场）：本流在调用点旁边
    /// 写了"旧写法是 `max(…, 1)`"这样的历史说明，不剥注释就会让第一条守卫被自己的注释骗过去、
    /// 第二条被自己的注释冤枉成红（实测踩过一次，红的是这条）。
    func test_busFactorCurveCallSiteIsStillGuardedByAnExplicitBasisCheck() throws {
        let path = Self.packageRoot.appendingPathComponent(
            "Sources/TcoderMonitor/Services/Health/HealthTeamDimensions.swift").path
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        let source = Self.strippingComments(raw)
        let callAt = try XCTUnwrap(source.range(of: "HealthCurves.busFactor("),
                                   "调用点没了 —— 那这条判据的对象就变了，请连本流结论一起更新")
        let beforeCall = String(source[source.startIndex..<callAt.lowerBound])
        XCTAssertTrue(beforeCall.contains("git.authorBasisCommits > 0"),
                      "调用点前面的 `authorBasisCommits > 0` 守卫不见了 ⇒ 0 总体又能进加权")
        XCTAssertFalse(source.contains("max(git.authorBasisCommits, 1)"),
                       "把 0 折成 1 的伪装又回来了：一条记录不能冒充一个分布")
    }

    /// 行注释与块注释都剥掉，只留真代码。
    static func strippingComments(_ source: String) -> String {
        let block = try! NSRegularExpression(pattern: #"/\*.*?\*/"#, options: [.dotMatchesLineSeparators])
        let range = NSRange(source.startIndex..., in: source)
        let withoutBlocks = block.stringByReplacingMatches(in: source, options: [],
                                                           range: range, withTemplate: "")
        return withoutBlocks.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            guard let slash = line.range(of: "//") else { return String(line) }
            return String(line[..<slash.lowerBound])
        }.joined(separator: "\n")
    }

    /// 分母自证：上面那条"读源码"的判据不是永真绿 —— 剥注释这件事本身要能被证伪。
    func test_reachabilityGuardActuallyLooksAtSomething() throws {
        let sample = """
        // 旧写法是 max(git.authorBasisCommits, 1)，把 0 折成 1
        guard let top = git.topAuthor, git.authorBasisCommits > 0 else { return .absent }
        let curve = HealthCurves.busFactor(risk: git.busFactorRisk, topAuthorShare: share, commitBasis: basis)
        """
        let stripped = Self.strippingComments(sample)
        XCTAssertFalse(stripped.contains("max(git.authorBasisCommits, 1)"),
                       "注释没剥掉：那条断言会被自己写的历史说明冤枉成红")
        XCTAssertTrue(stripped.contains("git.authorBasisCommits > 0"), "真代码被剥没了：扫描器读不到东西")
        let sabotaged = stripped.replacingOccurrences(of: "git.authorBasisCommits > 0", with: "true")
        XCTAssertFalse(sabotaged.contains("git.authorBasisCommits > 0"),
                       "这条元测试坏了（改坏样例改不出红），上面的守卫就是永真绿")
    }

    // MARK: - 靶子 2：`stability` 的 `totalLinesScanned == 0 → 85 分` 死支（R9b §1 已删除）

    /// R9 那一轮只把它钉成"不可达"，R9b §1 把占位分整块删了。于是这条用例现在测的是
    /// **删除之后仍然成立**的那件事：零真日志行 ⇒ 整维缺席、没有任何分量带默认分上屏。
    /// 修前现场（真子进程 + 真自扫，见 Obsidian/汇报）：本仓自扫 `totalLinesScanned` 1,063 ⇒ 0，
    /// 综合分 66 ⇒ 69 —— 这一支会"因为没量到而涨分"，那才是它最贵的地方。
    func test_zeroLineLogs_absentRatherThanADefaultEightyFive() throws {
        let inputs = HealthInputs(code: healthyCode(),
                                  logs: LogSummary(errorCount: 0, exceptionCount: 0, warningCount: 0,
                                                   crashCount: 0, fatalCount: 0, totalLinesScanned: 0))
        let score = WeightedHealthScorer().score(inputs)
        XCTAssertFalse(score.components.contains { $0.name == HealthDimension.stability.rawValue },
                       "没有一行日志证据时不许出现一个默认分")
        XCTAssertTrue(score.components.allSatisfy { !$0.detail.contains("按默认值计") },
                      "任何分量都不许带着「按默认值计」上屏：\(score.components.map(\.detail))")
        XCTAssertTrue(HealthBreakdown.missingDimensions(of: score).contains(.stability))
        XCTAssertTrue(score.recommendations.contains { $0.contains("运行稳定性不参与本次评分") },
                      "缺席必须出声，实得 \(score.recommendations)")
        // 综合分只由在场维度算出来（默认分没有混进来）
        let rows = HealthBreakdown.rows(for: score)
        XCTAssertTrue(HealthBreakdown.isSumConsistent(HealthBreakdown.sumOfContributions(rows),
                                                     with: score.overall))
    }

    /// 可达性钉子：**删除之后它更重要**，不是更不重要。
    /// 曲线里那一支原先最坏是给个 85，现在拿 `totalLinesScanned: 0` 直接敲曲线会得到
    /// 「每千行日志 0 个错误 = 100 分」，所以"不许凭空给分"这条不变式的全部承重
    /// 都压在这道 guard 上 —— guard 一没、或第二调用点不判行数就冒出来，这条立刻红。
    /// （配套的第二枚钉子：占位分回潮扫描在 `ScoreEvidenceFloorTests`。）
    func test_stabilityCurveCallSiteStillGuardsBeforeAskingTheCurve() throws {
        let path = Self.packageRoot.appendingPathComponent(
            "Sources/TcoderMonitor/Services/Health/HealthRuntimeDimensions.swift").path
        let source = Self.strippingComments(try String(contentsOfFile: path, encoding: .utf8))
        let callAt = try XCTUnwrap(source.range(of: "HealthCurves.stability("),
                                   "调用点没了 —— 本条判据的对象变了，请连本流结论一起更新")
        let beforeCall = String(source[source.startIndex..<callAt.lowerBound])
        XCTAssertTrue(beforeCall.contains("logs.totalLinesScanned > 0"),
                      "调用曲线之前那道 `totalLinesScanned > 0` 守卫不见了 ⇒ 零分母又能进加权")
        XCTAssertTrue(beforeCall.contains("guard logs.totalLinesScanned > 0 else"),
                      "守卫从 guard 退化成 if/注释 ⇒ 挡住调用这件事不再由编译器与运行时保证")
    }

    /// 分母自证：上面那条读源码的判据扫的确实是代码而不是空气，而且**摘掉 guard 就量得出红**。
    func test_stabilityReachabilityGuardIsNotPermanentlyGreen() throws {
        let sabotaged = Self.strippingComments("""
        // guard logs.totalLinesScanned > 0 else { }   <- 注释里的假守卫，不许算数
        let curve = HealthCurves.stability(errorsPerKiloLogLines: 0, totalLinesScanned: 0)
        """)
        XCTAssertFalse(sabotaged.contains("guard logs.totalLinesScanned > 0"),
                       "注释没剥掉：真守卫与写在注释里的假守卫分不开")
        XCTAssertFalse(sabotaged.contains("logs.totalLinesScanned > 0"), "剥得太狠，把真代码也剥掉了")
        // 反向：把 guard 写回来，同一把尺子必须数得到它（否则上面那条断言是永真绿）
        let guarded = sabotaged + "\nguard logs.totalLinesScanned > 0 else { return .absent }"
        XCTAssertTrue(guarded.contains("guard logs.totalLinesScanned > 0 else"),
                      "探针装不上真守卫 ⇒ 它数不到东西，那条可达性守卫就是假的")
    }

    /// 三档缺席原因：`nil` / 一行没读到 / 列到文件却一行没读出来，三句不许合成一句。
    func test_stabilityMissingReasonHasThreeDistinctStates() {
        let report = ProjectReport(project: MonitoredProject(name: "r9", path: "/tmp/r9"))
        let none = MissingDimensionReason.text(for: .stability, report: report)
        XCTAssertTrue(none.contains("尚未分析日志"), "实得 \(none)")

        var unreadable = report
        unreadable.logs = LogSummary(scannedFiles: [], totalLinesScanned: 0)
        let noFile = MissingDimensionReason.text(for: .stability, report: unreadable)
        XCTAssertTrue(noFile.contains("未发现可读的日志文件"), "实得 \(noFile)")

        var listedButEmpty = report
        listedButEmpty.logs = LogSummary(scannedFiles: [ScannedLogFile(path: "/tmp/a.log", sizeBytes: 0,
                                                                       lineCount: 0, modifiedAt: Date(),
                                                                       role: .application)],
                                         totalLinesScanned: 0)
        let listed = MissingDimensionReason.text(for: .stability, report: listedButEmpty)
        XCTAssertTrue(listed.contains("一行都没读出来") && listed.contains("1 个日志文件"),
                      "hasData 说「有文件」、评分器说「没证据」，这一档必须单独说一句：\(listed)")
        XCTAssertFalse(listed.contains("未发现可读的日志文件"), "第三档不许退化成第二档那句")
    }

    // MARK: - 靶子 3a：排序的名字必须就是排序的键（台账 RD-28）

    /// 独立真值：造一个"低权重低分"与"高权重中分"并存的分量表 ——
    /// 按 `contribution` 排与按 `lostPoints` 排会得到**相反的第一行**，
    /// 所以副标题只能写真的那个键。
    func test_rowOrderingKeyAndItsNameAgreeEvenWhenTheyDiverge() {
        let thin = ScoreComponent(name: HealthDimension.testing.rawValue, score: 20,
                                 weight: 0.05, detail: "低权重低分", risk: .critical)
        let heavy = ScoreComponent(name: HealthDimension.complexity.rawValue, score: 60,
                                  weight: 0.30, detail: "高权重中分", risk: .medium)
        var health = HealthScore()
        health.components = [heavy, thin]

        let rows = HealthBreakdown.rows(for: health)
        XCTAssertEqual(rows.map(\.name).first, DimensionDisplay.name(thin.name),
                       "排序键是 contribution，第一行必须是贡献最小那个")
        XCTAssertGreaterThan(try! XCTUnwrap(rows.last).lostPoints, rows[0].lostPoints,
                             "夹具没做出分叉形状：这条判据就成了永真绿")
        XCTAssertLessThan(rows[0].lostPoints, try! XCTUnwrap(rows.last).lostPoints,
                          "第一行不是失分最多的一项 —— 所以它**不许**被叫作「按拖累程度排序」")
    }

    /// 副标题与 `rows` 的键必须同源：把「按拖累程度排序」写回界面 ⇒ 这条立刻红。
    ///
    /// ⚠️ 2026-09-22 总工改法：这里**不再钉某一条具体文案**。R7 与 R9 修过同一句假话
    /// （我派单时让 §十 的归属重叠了），而常驻长句棘轮只减不增 ⇒ 界面留 R7 的短句、
    /// 「拖累不是第一行」这件事实进 ⓘ。钉死某一版句子会把这种"两版都合格"的取舍变成必然冲突。
    /// 于是这条改钉**不变式**：① 副标题点名它排的是「贡献」；② 不许出现「按拖累程度排序」；
    /// ③ 源码里那串字面量必须在目录里有逐字相等的键（守卫 3 同一条理由，提前拦）。
    func test_componentTableSubtitleNamesTheActualSortKey() throws {
        let path = Self.packageRoot.appendingPathComponent(
            "Sources/TcoderMonitor/Views/Health/HealthComponentTable.swift").path
        let source = Self.strippingComments(try String(contentsOfFile: path, encoding: .utf8))
        let literal = try XCTUnwrap(Self.firstStringLiteral(after: "subtitle:", in: source),
                                    "副标题字面量找不到 ⇒ 形状变了，这条不作数")
        XCTAssertTrue(literal.contains("贡献") && literal.contains("升序"),
                      "副标题必须写出真的排序键（现在是按贡献升序）：\(literal)")
        XCTAssertFalse(source.contains("按拖累程度排序"),
                       "「拖累」这个词只能留给 lostPoints，别把它安到一个不是它的键上")
        let catalog = try String(contentsOfFile: Self.packageRoot
            .appendingPathComponent("Resources/en.lproj/Localizable.strings").path, encoding: .utf8)
        XCTAssertTrue(catalog.contains("\"\(literal)\" ="),
                      "源码字面量与目录键必须逐字相等，缺了英文态就整句掉中文：\(literal)")
        XCTAssertFalse(catalog.contains("按拖累程度排序，贡献最低者在前"),
                       "旧键还留在目录里 = 译文烂尾，守卫 3 会红")
    }

    /// 取 `标签:` 后面那一条 Swift 字符串字面量的内容（不处理转义，页面文案里没有）。
    static func firstStringLiteral(after label: String, in source: String) -> String? {
        guard let at = source.range(of: label) else { return nil }
        let rest = source[at.upperBound...]
        guard let open = rest.firstIndex(of: "\"") else { return nil }
        let afterOpen = rest[rest.index(after: open)...]
        guard let close = afterOpen.firstIndex(of: "\"") else { return nil }
        return String(afterOpen[..<close])
    }

    // MARK: - 靶子 3b：同一个日均频率不许声称两次贡献（台账 RD-29）

    /// 优点句必须自带"这句不另加分"，否则曲线折算一次、优点卡再夸一次。
    func test_steadyCadenceStrengthDisclaimsASecondContribution() throws {
        let score = WeightedHealthScorer().score(HealthInputs(git: matureFastGit()))
        let claim = try XCTUnwrap(score.strengths.first { $0.contains("提交节奏稳定") },
                                  "日均 20 次、历史 400 天的仓库必须还能被说出台词，实得 \(score.strengths)")
        XCTAssertTrue(score.components.first { $0.name == activityName }?.detail.contains("碎片化") == true,
                      "夹具没落进折算区：这条判据现在测不到双计")
        XCTAssertTrue(claim.contains("不另加分") || claim.contains("折算一次"),
                      "同一事实的两处必须有一处承认自己不加第二次分，实得：\(claim)")
    }

    /// 反向：速率不高时压根不写这句优点（不许把"没到门槛"写成优点，也不许反过来偷偷放宽）。
    func test_slowCadenceMakesNoSteadyClaimAtAll() {
        let score = WeightedHealthScorer().score(HealthInputs(git: matureFastGit(commits: 20)))
        XCTAssertFalse(score.strengths.contains { $0.contains("提交节奏稳定") },
                       "日均 0.05 次不配这句，实得 \(score.strengths)")
    }

    /// 两处门槛必须同源一把尺子：曲线里再抄一个裸数字 `rate >= 8` 就是第二把尺子。
    func test_fragmentationTurnComesFromTheSharedConstant() throws {
        let path = Self.packageRoot.appendingPathComponent(
            "Sources/TcoderMonitor/Services/Health/ScoreCurvesTeamRuntime.swift").path
        let source = Self.strippingComments(try String(contentsOfFile: path, encoding: .utf8))
        XCTAssertTrue(source.contains("rate >= GitCadenceEvidence.steadyCadenceCommitsPerDay"),
                      "曲线不再引用共享常量 ⇒ 优点句与折算句会各拿一个数说同一件事")
        XCTAssertFalse(source.contains("rate >= 8"), "裸数字 8 又回来了（值虽然一样，两处会各自漂）")
    }

    // MARK: - 夹具

    func author(_ name: String, _ commits: Int) -> AuthorStats {
        AuthorStats(name: name, email: "\(name)@tcoder.local", commits: commits,
                    additions: commits * 10, deletions: commits, filesTouched: commits,
                    firstCommitAt: nil, lastCommitAt: nil,
                    activityByHour: Array(repeating: 0, count: 24), topDirectories: [:])
    }

    /// 历史够长（400 天）且频率越过折算门槛（默认 8000 笔 ⇒ 日均 20 次）。
    func matureFastGit(commits: Int = 8_000) -> GitInsights {
        let last = Date(timeIntervalSince1970: 1_750_000_000)
        return GitInsights(totalCommits: commits, commitsAnalyzed: commits,
                           firstCommitAt: last.addingTimeInterval(-400 * 86_400),
                           lastCommitAt: last,
                           authors: [author("WS-A", commits / 3), author("WS-B", commits / 3),
                                     author("WS-C", commits - commits / 3 * 2)])
    }

    static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/TcoderMonitorTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // TcoderMonitor
    }
}
