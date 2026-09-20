import XCTest
@testable import TcoderMonitor

/// OWNER: WS-J 自食其果。**口径与普查门**：工具报的那个数，到底是不是它自称的那个口径。
/// 仓库形态门（超限文件、只减不增棘轮、证据转储）在 `SelfScanDogfoodTests`，
/// 共用管道在 `SelfScanHarnessCase`。
///
/// 开法：TCODER_SELF_SCAN=1 ./scripts/locked_build.sh test
final class SelfScanConventionGates: SelfScanHarnessCase {
    /// 自扫复核台。**上半段是已经翻正的历史缺陷**（负责人修好后按约定翻正，
    /// 过程记在 48 号笔记），**下半段是仍在身的缺陷钉**：断言的是"现在还错着"这件事，
    /// 每条失败信息都写清了修好后该改成什么，谁修谁翻正，不让缺陷悄悄回潮。
    func testKnownSelfScanDefectsArePinned() async throws {
        let scan = try await selfScan()
        let census = try await complexityCensus()
        let code = scan.code

        // —— 已翻正 1（WS-A `f55e4a0`）：全仓普查的两个字段终于有生产者了。
        // 基线不是我抄分析器的，而是我自己调 ComplexityEngine 绕开榜单重数一遍。
        XCTAssertEqual(code.analyzedFunctionCount, census.functionCount,
                       "analyzedFunctionCount=\(code.analyzedFunctionCount) 与独立普查 "
                     + "\(census.functionCount) 不一致：要么生产者漏了文件，要么我的走树口径变了")
        XCTAssertNotNil(code.averageCyclomaticComplexity, "有函数可数时全仓均值不得是 nil")
        XCTAssertEqual(code.averageCyclomaticComplexity!, census.repoMean, accuracy: 0.01,
                       "全仓均复杂度与独立普查对不上（测得 "
                     + "\(code.averageCyclomaticComplexity ?? -1) vs 普查 \(census.repoMean)）")

        // —— 已翻正 2（WS-C + WS-A）：复杂度维度不再拿 top-20 热点均值冒充全仓水位。
        // 校法刻意**不碰数字字面量**：detail 把 4.098 写成 "4" 还是 "4.1" 是格式化选择，
        // 拿字符串去比小位数等于用测试绑架实现格式（上一轮就是这么红的：断言 "4.0"，
        // 而实现如实给出 "4"）。改成三层，各管一件事。
        let complexity = try XCTUnwrap(scan.health.components.first { $0.name.contains("复杂度") },
                                       "复杂度维度必须存在")

        // ① 校**口径声明**：均值必须自称全仓，且不得再出现"热点样本"。
        XCTAssertTrue(complexity.detail.contains("全仓"),
                      "复杂度维度没声明均值口径是全仓，当前 detail：\(complexity.detail)")
        XCTAssertFalse(complexity.detail.contains("热点样本"),
                       "复杂度维度又拿 top-20 热点样本均值冒充全仓水位了")

        // ② 要校数值就**先解析再比数**，容差跟着它自己的显示精度走：
        //    只写整数位就允许 ±0.5，写了一位小数就收紧到 ±0.05。
        let reported = try XCTUnwrap(reportedRepoMean(in: complexity.detail),
                                     "detail 里解析不出『平均圈复杂度 <数字>』，数值校验形同虚设")
        let tolerance = reported.text.contains(".") ? 0.05 : 0.5
        XCTAssertEqual(reported.value, census.repoMean, accuracy: tolerance,
                       "detail 报的均值 \(reported.text) 与独立普查 "
                     + "\(String(format: "%.3f", census.repoMean)) 对不上")
        XCTAssertLessThan(abs(reported.value - census.repoMean),
                          abs(reported.value - census.hotspotMean),
                          "detail 里的均值离热点样本均值 \(census.hotspotMean) 反而更近，疑似又用错口径")

        // ③ **分母也必须上屏**：均值为 4 的可信度完全取决于"4 是多少个函数的 4"，
        //    不报样本量的均值没有意义。
        XCTAssertTrue(complexity.detail.contains("\(census.functionCount)"),
                      "detail 没报出分母（独立普查 \(census.functionCount) 个函数）："
                    + "不报样本量的均值没有意义。当前 detail：\(complexity.detail)")

        // —— 已翻正（收官轮 2026-09-21）：这条原本钉的是「detail 里 N 个函数 CC≥16 数的
        //    是被 prefix(20) 截断的榜单条数，而不是普查真值」——当时全仓真实 54 个、榜上写 20。
        //    三包把全仓拆到 \(census.atLeast16) 个之后，榜内计数与普查真值第一次对得上，
        //    于是按这条门自己写好的修法翻正：改判「detail 必须含普查真值」，
        //    并删掉「全仓必须多于榜单条数」那前提已消失的断言。
        XCTAssertEqual(code.topComplexFunctions.count, 20,
                       "榜单截断长度变了，本门与 48 号笔记里的措辞要同步")
        XCTAssertTrue(complexity.detail.contains("\(census.atLeast16) 个函数"),
                      "detail 里的 CC≥16 计数必须等于独立普查真值 \(census.atLeast16)，"
                    + "实际：\(complexity.detail)")
        XCTAssertFalse(complexity.detail.contains("热点样本"),
                       "有全仓均值时不许再退回热点样本口径：\(complexity.detail)")

        print("【普查 vs 榜单】真实 CC≥\(Self.complexFunctionBar) 共 \(census.atLeast16) 个，"
            + "detail 报的也是这个数（翻正前：真实 54 / detail 20）")
    }

    /// 手算可验证的普查门：用一个我能逐个点数函数的最小夹具，
    /// 确认 `analyzedFunctionCount` / `averageCyclomaticComplexity` 不是"自洽的错数"。
    /// 夹具 5 个函数、期望复杂度 `1 + 2 + 2 + 4 + 2 = 11`，手算均值 11 ÷ 5 = **2.2**。
    func testComplexityCensusMatchesHandCountedFixture() async throws {
        let dir = try makeComplexityProbeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let metrics = try await FileSystemCodeAnalyzer().analyze(root: dir, options: .default)

        XCTAssertEqual(metrics.analyzedFunctionCount, 5,
                       "夹具里只有 5 个函数，生产者数出来的却不是我手点数的那个")
        let expectedMean = (1 + 2 + 2 + 4 + 2) / 5.0
        XCTAssertEqual(metrics.averageCyclomaticComplexity ?? -1, expectedMean, accuracy: 0.01,
                       "手算全仓均复杂度应为 \(expectedMean)")
        print("【手算核对】夹具函数 5 个、手算均值 \(expectedMean)，测得 "
            + "\(metrics.analyzedFunctionCount) 个 / \(metrics.averageCyclomaticComplexity ?? -1)")
    }

    /// 把只含一种语法的最小函数喂给 `ComplexityEngine`，看它各加几分。
    /// 目的：判定"平均圈复杂度"里有多少是真实判定、多少是 Swift 口径通胀。
    func testComplexityEngineBranchCountingConvention() async throws {
        let dir = try makeComplexityProbeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let files = await SourceTreeScanner(options: .default).scan(root: dir).files
        let measured = ComplexityEngine.functions(in: files[0])
        let byName = Dictionary(uniqueKeysWithValues: measured.map { ($0.name, $0.complexity) })

        func cc(_ name: String) -> Int { byName[name] ?? -1 }
        print("【引擎口径】plain=\(cc("plain")) oneIf=\(cc("oneIf")) "
            + "nilCoalesce=\(cc("oneNilCoalesce")) failableCast=\(cc("failableCast")) "
            + "ternary=\(cc("oneTernary"))")

        XCTAssertEqual(cc("plain"), 1, "无分支函数必须是 1，否则整个榜单口径都不可信")
        XCTAssertEqual(cc("oneIf"), 2, "单个 if 应当 +1")
        XCTAssertEqual(cc("oneNilCoalesce"), 2, "?? 算一次判定；数字变了说明 Swift 口径被动过")
        XCTAssertEqual(cc("oneTernary"), 2, "三元算一次判定，且不重复计数")
        // 这一条是**口径与阈值不匹配**的证据：一个 2 行、线性、无嵌套的函数，
        // 仅仅因为写了 as? / ?. / ?? 就被判 CC=4。`parseIstanbulSummary` 27 行
        // 被测成 CC=24 并打上[高]风险，根因就在这里——阈值 highFunctionComplexity=21
        // 是按经典 McCabe 标定的，而计数口径把可选值语法糖也记成了判定。
        XCTAssertEqual(cc("failableCast"), 4,
                       "as?/?. 与 ?? 各算一次判定。若你收紧了口径，请把本条与 48 号笔记一起更新")
    }

    // MARK: - merge 口径的界面诚实性（钉 WS-L 的 `GitHistoryScope`）

    /// 页头「共 62 次提交」与作者表求和 48 对不上，用户自己就会发现，
    /// 而我们过去从不解释。WS-L 把这句话写进了界面，这里**用 git 命令复核那行字里的每个数**，
    /// 让它不只是"写了"，而是"写对了"——文案改一个字都不要紧，数字对不上就是虚报。
    func testGitPageExplainsTheMergeConventionAgainstGitGroundTruth() async throws {
        let git = try await selfScan().git
        let scope = GitHistoryScope(git)

        let all = try revListCount([])
        let nonMerge = try revListCount(["--no-merges"])
        let merges = try revListCount(["--merges"])

        XCTAssertEqual(scope.totalCommits, all, "页头用的总数必须等于 `rev-list --count HEAD`")
        XCTAssertEqual(scope.authorBasis, nonMerge,
                       "作者与代码行的分母必须等于 `rev-list --count --no-merges HEAD`，"
                     + "差的那几个是合并提交，不是漏计的人")
        XCTAssertEqual(scope.mergeCount, merges,
                       "界面上写的合并数必须等于 `rev-list --count --merges HEAD`")

        // 本仓库历史全部在窗口内，差额就应当能完整归因给合并提交。
        XCTAssertEqual(scope.basis, .complete(mergeCount: merges),
                       "窗口没用满时口径必须是 .complete，当前 \(scope.basis)")
        XCTAssertFalse(scope.isWindowTruncated,
                       "非合并历史已读完，不得标成窗口截断（这正是旧 `historyTruncated` 的毛病）")
        XCTAssertTrue(scope.mergesExplainTheGap)

        // 那行字必须三个数都在，用户拿计算器就能对上账。
        // 比对用视图自己那个格式化器：仓库涨过 999 个提交后分隔符会变，
        // 拿裸整数去 contains 会假红（和上一轮 `contains("4.0")` 是同一类错）。
        let headline = scope.headline
        print("【界面口径句】\(headline)")
        for number in [all, nonMerge, merges] {
            XCTAssertTrue(headline.contains(NumberFormat.grouped(number)),
                          "页头文案里少了 \(number)，用户无法对账。当前文案：\(headline)")
        }
        XCTAssertTrue(headline.contains("合并"),
                      "文案没出现『合并』二字，等于没解释差额来源：\(headline)")
    }

    /// **不许把窗口截断编成合并数。** 窗口打满时差额 = 合并 + 没读到的更早历史,
    /// 现有字段拆不开，只能如实说"窗口内"。这是 Homebrew 那种 5 万提交仓库的真实处境
    /// （实测 total 50,666 / 窗口 20,000）。
    func testGitScopeNeverInventsMergeCounts() {
        let capped = GitHistoryScope(totalCommits: 50_666, nonMergeCommitsAnalysed: 20_000,
                                     windowLimit: 20_000)
        XCTAssertNil(capped.mergeCount,
                     "窗口打满时报出精确合并数就是编数字（差额里混着未读的更早历史）")
        XCTAssertTrue(capped.isWindowTruncated)
        XCTAssertEqual(capped.basis, .windowCapped)
        XCTAssertTrue(capped.headline.contains("更早的历史未纳入") || capped.headline.contains("窗口"),
                      "真截断时文案必须交代覆盖范围：\(capped.headline)")
        // 「（含 N 次合并）」这种句式只能出现在 .complete 分支——
        // 窗口打满时那个 N 是错的，所以文案里绝不能出现它。
        XCTAssertFalse(capped.headline.contains("次合并）"),
                       "窗口打满却给出合并数，等于把未读历史算进合并：\(capped.headline)")

        let clean = GitHistoryScope(totalCommits: 62, nonMergeCommitsAnalysed: 48, windowLimit: 20_000)
        XCTAssertEqual(clean.mergeCount, 14)
        XCTAssertFalse(clean.isWindowTruncated)
        XCTAssertTrue(clean.headline.contains("含 14 次合并"), clean.headline)
        XCTAssertTrue(clean.headline.contains("48 次非合并提交"), clean.headline)

        let noMerges = GitHistoryScope(totalCommits: 30, nonMergeCommitsAnalysed: 30, windowLimit: 20_000)
        XCTAssertEqual(noMerges.mergeCount, 0)
        XCTAssertFalse(noMerges.mergesExplainTheGap, "没有合并时不许虚构差额解释")
        XCTAssertFalse(noMerges.headline.contains("含 0 次合并"), "零合并要说不写合并，别写『含 0 次』")

        // 旧报告没有 commitsAnalyzed（缺字段=0）：口径未知，宁可不写也不退回含合并总数冒充。
        let legacy = GitHistoryScope(totalCommits: 62, nonMergeCommitsAnalysed: 0, windowLimit: 20_000)
        XCTAssertEqual(legacy.basis, .unknown)
        XCTAssertNil(legacy.mergeCount, "旧报告口径未知时报 62 个合并就是凭空捏造")
        XCTAssertTrue(legacy.headline.contains("旧口径") || legacy.headline.contains("没有记录"),
                      "未知口径必须如实说明：\(legacy.headline)")
    }

    // MARK: - 缺陷钉：同一个集中度在屏幕上不该有两个数

    /// 从文案里抽"某个数 %"这样的百分比，避免去猜实现保留几位、四舍五入还是截断。
    private func percent(in text: String, after keyword: String) -> Double? {
        let pattern = "\(keyword)\\s*([0-9]+(?:\\.[0-9]+)?)\\s*%"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges >= 2,
              let captured = Range(match.range(at: 1), in: text) else { return nil }
        return Double(text[captured])
    }

    /// **缺陷钉（WS-R）**：Git 页与健康分对"单一作者集中度"报出两个数。
    /// 分析器用 `git log --no-merges` 统计作者（分母 = 非合并），
    /// 而 `GitInsights.totalCommits` 含合并；协作分布拿含合并的当分母，
    /// 于是每有一次合并工作流合树，评分里的集中度就被稀释一次。
    /// WS-L 已经在视图侧换成 `GitHistoryScope.authorBasis`（`ContributorRows.busFactorRisk(_:)`
    /// 明写了"模型是冻结的，它拿含合并的 totalCommits 做分母，仓库越大越低估"），
    /// **评分侧还没有**。这里把现状钉住，谁修谁翻正。
    // ⚠️ 本条断言的是**缺陷现状**，不是期望值。期望值 = 与 Git 页同分母：
    //    XCTAssertEqual(scored, pageShare, accuracy: 1.0)  ← 修好后换成这行并删掉下面两条。
    func testPinned_BusFactorDilutedByMergeCommitsInHealthScore() async throws {
        let scan = try await selfScan()
        let git = scan.git
        let scope = GitHistoryScope(git)
        let top = try XCTUnwrap(git.authors.max { $0.commits < $1.commits })

        // 真相：与分析器同口径的邮箱归并占比。
        let truth = try independentTopAuthorShare()
        let pageShare = 100 * Double(top.commits) / Double(scope.authorBasis)
        XCTAssertEqual(pageShare / 100, truth, accuracy: 0.01,
                       "Git 页的占比与 `git log --no-merges --format=%aE` 不一致")

        let diluted = 100 * Double(top.commits) / Double(git.totalCommits)
        XCTAssertLessThan(diluted, pageShare - 5,
                          "合并提交已经不多到把两个分母拉开 5 个点，这条钉的前提消失，删掉它")

        let collaboration = try XCTUnwrap(scan.health.components.first { $0.name.contains("协作") },
                                          "协作分布维度必须存在")
        let scored = try XCTUnwrap(percent(in: collaboration.detail, after: "最高作者占比"),
                                   "协作分布 detail 里解析不出『最高作者占比 X%』，本钉失效")

        // ① 修好之后（#44）：评分与 Git 页同分母。以前这里钉的是"被合并提交稀释"的现状态。
        XCTAssertEqual(scored, pageShare, accuracy: 1.0,
                       "评分必须与 Git 页同一个分母（非合并总体）；若又漂回 diluted，就是分母被换回去了")
        XCTAssertGreaterThan(scored, diluted + 30,
                             "辅助方向：证明这条 pin 仍有意义——含合并的分母确实会把集中度压低 30 个点以上。"
                           + "若哪天合并提交少到不再拉开差距，就删掉本条与 diluted 那两行")
        print("【集中度两个数】Git 页=\(Int(pageShare))%（等于 git 非合并口径）"
            + " 健康分=\(Int(scored))%（同一个分母，已修）"
            + " 反例分母=\(Int(diluted))%（若误用含合并的 \(git.totalCommits) 次会算成这样）")
    }

    // MARK: - 巨大文件榜截断的机制测试（不依赖仓库当下有没有债）

    /// 工具的巨大文件榜被 `prefix(20)` 截断
    /// （`FileSystemCodeAnalyzer.hugeFiles(files:functionsPerFile:)` 的收尾），
    /// 而代码质量维度拿 `hugeFiles.count` 当普查分子。
    ///
    /// 上一版这条是"钉仓库现状"，WS-V 把超长文件拆完后前提就塌了（真实 >400 行
    /// 的文件数掉到正好等于截断上限 20，低估看不出来）。那是**守卫找错对象**：
    /// 它在盯"债还在不在"，而不是"工具能不能数"。
    /// 这里改成自己造债——合成 25 个 >400 行文件，工具只许报 20 个——
    /// "拿榜单条数当分子必然少算"就被永久钉住，仓库拆到多干净都不影响它。
    func testHugeFileListTruncationUnderstatesACensus() async throws {
        let fileCount = 25
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tcoder-wsj-truncation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        for index in 0..<fileCount {
            // 每个文件 420 行：函数声明 1 行 + 注释 418 行 + 收尾 1 行，稳过 400 这条线。
            var body = "func sample\(index)() {\n"
            body += String(repeating: "// 占位行\n", count: 418)
            body += "}\n"
            try body.write(to: dir.appendingPathComponent("Sample\(index).swift"),
                           atomically: true, encoding: .utf8)
        }

        var collected: [GroundTruthFile] = []
        try collectSwiftFiles(in: dir, into: &collected)
        let truthOverMedium = collected.filter { $0.lines > Self.mediumFileLines }.count
        XCTAssertEqual(truthOverMedium, fileCount,
                       "夹具应当造出 \(fileCount) 个 >\(Self.mediumFileLines) 行文件，实得 \(truthOverMedium)")

        let metrics = try await FileSystemCodeAnalyzer().analyze(root: dir, options: .default)
        XCTAssertEqual(metrics.hugeFiles.count, 20,
                       "榜单截断长度变了（现在 \(metrics.hugeFiles.count)），本测试与 48 号笔记要同步")
        XCTAssertLessThan(metrics.hugeFiles.count, truthOverMedium,
                          "工具报出的巨大文件数不再少于真实值——截断已被修掉，"
                        + "请把本条改成 XCTAssertEqual(metrics.hugeFiles.count, truthOverMedium)")

        // 少算的那几个会怎样进评分：分子用榜单条数就低报占比。
        let cappedRatio = Double(metrics.hugeFiles.count) / Double(metrics.totalFiles)
        let trueRatio = Double(truthOverMedium) / Double(metrics.totalFiles)
        XCTAssertLessThan(cappedRatio, trueRatio - 0.05,
                          "占比低估不足 5 个百分点，说明分子已不再取截断榜单，删掉这条")
        print("【榜单截断机制】夹具真实 >\(Self.mediumFileLines) 行 \(truthOverMedium) 个，"
            + "工具 hugeFiles 只报 \(metrics.hugeFiles.count) 个；分子若用榜单 = "
            + "\(String(format: "%.1f", cappedRatio * 100))%，真实 = "
            + "\(String(format: "%.1f", trueRatio * 100))%")
    }
}