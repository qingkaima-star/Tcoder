import XCTest
@testable import TcoderMonitor

/// OWNER: WS-S1 外壳与总览 —— 本流「碎文案收进 ⓘ」的落点自检。
///
/// 工单是 `docs/superpowers/specs/2026-09-21-ui-copy-tooltip-inventory.md` 的 A 组 9 条。
/// 三条成对守卫（A 常驻长句只减不增 / B 总量守恒 / C 承诺句必须常驻）住在
/// `TooltipMigrationGuardTests`，**本文件不复制那把尺子**：要判"哪一行还常驻上屏"
/// 就直接调它的 `scan`（两处各写一遍 = 两把尺子，本仓吃过四次亏）。
/// 本文件只管 S1 自己写下的四件事：
///   ① 屏上留的短标签必须是它对应那条完整句的**子串**（硬约束 1：不许新造修辞）；
///   ② 本片常驻长句只减不增，且减下来的每一条都真有一个 ⓘ 落点；
///   ③ `ShellCopy` 三组互斥句式（「缺数据 ≠ 0」的读法本身）一条都不许只活在 hover 里；
///   ④ 覆盖率口径的短标签与完整句出自同一条判据，不会各说一支。
final class ShellTooltipTests: XCTestCase {

    /// 本流可写的面：总览与外壳。别的页归别的片。
    static let slicePaths: Set<String> = [
        "Views/DashboardView.swift",
        "Views/ProjectDetailView.swift",
        "Views/Shell/DashboardHero.swift",
        "Views/Shell/DashboardReadouts.swift",
        "Views/Shell/ProjectSidebar.swift",
        "Views/Shell/SectionNav.swift",
        "Views/Shell/ShellLayout.swift",
        "Views/Shell/SidebarRows.swift",
    ]

    static func slice() throws -> [(path: String, content: String)] {
        let files = try SurfaceScanKit.sourceFiles(under: "Views").filter { slicePaths.contains($0.path) }
        XCTAssertEqual(files.count, slicePaths.count,
                       "本流扫描面只齐了 \(files.count)/\(slicePaths.count) 个文件，下面的比对没有含义")
        return files
    }

    /// 前提自证：测试宿主的 `Bundle.main` 里没有 `en.lproj`，
    /// 所以 `localizedCopy` 原样返回键（= 中文原文）。① 与 ④ 比的是**中文整句**，
    /// 前提变了就必须显式跳过，不能拿英文译文去比中文前缀、假装通过。
    private func assumeRawKeys(file: StaticString = #filePath, line: UInt = #line) throws {
        let probed = localizedCopy("口径：仅生产码")
        try XCTSkipIf(probed != "口径：仅生产码",
                      "测试宿主查到了译文（\(probed)），本片按中文原文比对的判据不再成立",
                      file: file, line: line)
    }

    // MARK: - ① 短标签必须是原句子串

    /// 屏上短标签 → 它所属那条完整句（盘点表 A 组的原文，一字未改）。
    /// 两个方向都要成立：原文仍在源码里（不许被顺手删），且短标签是它的子串。
    static let shortTagPairs: [(onScreen: String, fullSentence: String)] = [
        ("没有命中错误行。", "已扫描 %1$@ 个日志文件，没有命中错误行。"),
        ("用「附加日志文件」手动选择。",
         "在项目内放置 Logs/error.log 或 crash.log，或用「附加日志文件」手动选择。"),
        ("指一个本地仓库目录",
         "在左侧「选择目录…」指一个本地仓库目录，九页读数全部由它真实算出来。"),
        ("首个采样点", "首个采样点到达后显示曲线。"),
    ]

    func test_shortTagsAreSubstringsAndTheirFullSentencesSurvive() throws {
        try assumeRawKeys()
        let files = try Self.slice()
        let hay = files.map(\.content).joined(separator: "\n")
        XCTAssertFalse(Self.shortTagPairs.isEmpty, "对照表空了 = 这条判据在空转")
        for pair in Self.shortTagPairs {
            XCTAssertTrue(hay.contains("\"" + pair.onScreen + "\""),
                          "屏上那句短标签没在源码里：\(pair.onScreen)")
            XCTAssertTrue(hay.contains(pair.fullSentence),
                          "完整句被删掉了 —— 搬进 ⓘ 不是删除（B 守恒）：\(pair.fullSentence)")
            XCTAssertTrue(pair.fullSentence.contains(pair.onScreen),
                          "短标签不是原句子串，是新造修辞：\(pair.onScreen)")
        }
    }

    // MARK: - ② 本片常驻长句只减不增，且每条都有 ⓘ 落点

    /// 2026-09-21 本片交回时的现量：**2 条**。逐条留名，新增第 3 条就红：
    ///   · `Views/DashboardView.swift` 「分支覆盖 %1$@ · 来源 %2$@」——这一行里是**测得值**，
    ///     不是解释性小文案，不在 A 组工单里；
    ///   · `Views/Shell/DashboardHero.swift` 「点击右上角「重新分析」，扫描代码规模…」——
    ///     判「留短藏长」，但本文件在 `LocalizationGuardTests.migratedFiles` 那张
    ///     **零余量**名单里，短标签是一条未登记新键，本流不得写 `.strings` → 等总工登记。
    private static let sliceVisibleLongCaliberCeiling = 2

    func test_shellSliceVisibleLongCalibersDoNotGrow() throws {
        let (visible, tooltip) = TooltipMigrationGuardTests.scan(try Self.slice())
        print("ⓘ 本片落点：常驻长句 \(visible.count) / 上限 \(Self.sliceVisibleLongCaliberCeiling)"
              + "，ⓘ 承载 \(tooltip.count) 条")
        XCTAssertGreaterThanOrEqual(tooltip.count, 3,
                                    "ⓘ 落点少于 3 处 —— 搬走的句子必须有一处 hover 接得住，否则就是删了")
        XCTAssertLessThanOrEqual(visible.count, Self.sliceVisibleLongCaliberCeiling,
                                "本片常驻长句从 \(Self.sliceVisibleLongCaliberCeiling) 涨到 \(visible.count)："
                                + visible.map { "\($0.path):\($0.line) \($0.text.prefix(24))" }
                                    .joined(separator: "\n"))
    }

    // MARK: - ③ 三组互斥句式仍全部常驻

    /// `ShellCopy` 的三态在界面上必须读得出三个不同意思（「没查 / 查了是空的 / 查不了」）。
    /// 这条与语言无关：两种语言里都不许有两支撞成同一句。
    func test_threeStatePhrasesStayMutuallyExclusive() {
        let subjects: [CopySubject] = [.thisProject, .allMetrics, .codeSize, .gitHistory,
                                       .errorLogs, .errorLevelLogs, .errors, .commits,
                                       .strengthsAndRisks, .noLogFiles, .notAGitRepo]
        var all = Set<String>()
        for subject in subjects {
            let trio = [ShellCopy.notAnalyzed(subject), ShellCopy.scannedButFoundNone(subject),
                        ShellCopy.cannotAnalyze(subject)]
            XCTAssertEqual(Set(trio).count, 3, "「\(subject.rawValue)」的三态撞车了：\(trio)")
            all.formUnion(trio)
        }
        XCTAssertEqual(all.count, subjects.count * 3, "三态句式在两两之间出现了重复")
    }

    /// 纯函数：找出「把 `ShellCopy.` 三态句写进 hover 槽」的行。剥整行注释。
    static func hoverHiddenHonestyCalls(_ files: [(path: String, content: String)])
        -> (callSites: Int, offenders: [String]) {
        var callSites = 0
        var offenders: [String] = []
        for file in files {
            for (index, raw) in file.content.components(separatedBy: "\n").enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("//") || !line.contains("ShellCopy.") { continue }
                callSites += 1
                if line.contains("help:") || line.contains("CopyHelpBadge(") {
                    offenders.append("\(file.path):\(index + 1): \(line.prefix(60))")
                }
            }
        }
        return (callSites, offenders)
    }

    func test_honestyPhrasesAreNeverHiddenBehindATooltip() throws {
        // （`Views/Shell/SidebarRows.swift` 那枚 `.help(isEnabled ? … : ShellCopy.notAnalyzed(…))`
        //  不在本判据内：那是禁用行的补充说明，行名本身一直常驻，且它是本轮之前的形状，
        //  所以判据只看 `help:` 槽与 `CopyHelpBadge(`，不看裸 `.help(`。）
        let (callSites, offenders) = Self.hoverHiddenHonestyCalls(try Self.slice())
        XCTAssertGreaterThanOrEqual(callSites, 8,
                                    "本片只扫到 \(callSites) 个 ShellCopy 调用点，判据面已经缩了")
        XCTAssertTrue(offenders.isEmpty,
                      "「缺数据 ≠ 0」的读法不许只活在 hover 里（C 的上界）：\n"
                        + offenders.joined(separator: "\n"))
    }

    /// 元测试：上面那条扫描判据必须抓得住坏样例，也不能误伤合法形状。
    func test_meta_hoverHonestyScannerFiresOnBadSampleAndSparesGood() {
        let dirty = [(path: "Views/Fake.swift", content: """
        EmptyStateView(title: "还没有数据", help: ShellCopy.notAnalyzed(.codeSize))
        """)]
        let bad = Self.hoverHiddenHonestyCalls(dirty)
        XCTAssertEqual(bad.callSites, 1, "坏样例没被算成调用点，分母会假零")
        XCTAssertEqual(bad.offenders.count, 1, "把三态句塞进 help: 槽没被抓到")

        let clean = [(path: "Views/Fake.swift", content: """
        EmptyStateView(title: ShellCopy.notAnalyzed(.codeSize), message: "点「重新分析」再看。")
        // help: ShellCopy.notAnalyzed(.codeSize)
        """)]
        let good = Self.hoverHiddenHonestyCalls(clean)
        XCTAssertEqual(good.callSites, 1, "注释里那行不该被算进来（分母虚高）")
        XCTAssertTrue(good.offenders.isEmpty, "合法形状被误报，几次之后就有人删这条判据")
    }

    // MARK: - ④ 覆盖率口径：短标签与完整句同一判据

    private static func metrics(production: Int, productionTotal: Int, all: Int?, allTotal: Int?,
                                granularity: CoverageReport.ScopeGranularity) -> CoverageMetrics {
        CoverageMetrics(reports: [CoverageReport(
            path: "/tmp/tcoder-s1/lcov.info", kind: .unit, toolName: "lcov",
            linesCovered: production, linesTotal: productionTotal,
            branchesCovered: 0, branchesTotal: nil,
            methodsCovered: 0, methodsTotal: 0,
            allLinesCovered: all, allLinesTotal: allTotal,
            scopeGranularity: granularity)])
    }

    func test_coverageCaliberTagAndSentenceShareOneDecision() throws {
        try assumeRawKeys()
        let cases: [(name: String, metric: CoverageMetrics, expectTagPrefix: String)] = [
            ("只有汇总粒度",
             Self.metrics(production: 100, productionTotal: 200, all: nil, allTotal: nil,
                          granularity: .aggregateOnly),
             "口径：报告只有汇总粒度"),
            ("两口径一致",
             Self.metrics(production: 100, productionTotal: 200, all: 100, allTotal: 200,
                          granularity: .perSourceFile),
             "口径：仅生产码"),
            ("含测试代码更高",
             Self.metrics(production: 100, productionTotal: 200, all: 900, allTotal: 1000,
                          granularity: .perSourceFile),
             "口径：仅生产码"),
        ]
        XCTAssertEqual(cases.count, 3)
        for item in cases {
            let tag = DashboardView.coverageCaliberTag(item.metric)
            let sentence = DashboardView.coverageCaliberLine(item.metric)
            XCTAssertEqual(tag, item.expectTagPrefix, item.name)
            XCTAssertTrue(sentence.hasPrefix(tag),
                          "短标签不是完整句的子串（两半各说一套）：\(tag) / \(sentence)")
        }
        // 判据没被顺手改掉：差值 < 0.05 与 ≥ 0.05 走的是两条不同整句键。
        let same = DashboardView.coverageCaliberLine(
            Self.metrics(production: 100, productionTotal: 200, all: 100, allTotal: 200,
                         granularity: .perSourceFile))
        let gap = DashboardView.coverageCaliberLine(
            Self.metrics(production: 100, productionTotal: 200, all: 900, allTotal: 1000,
                         granularity: .perSourceFile))
        XCTAssertTrue(same.contains("与含测试代码的口径一致"), same)
        XCTAssertTrue(gap.contains("不用于评分"), gap)
        XCTAssertTrue(gap.contains("90.0%"), "全口径那个测得值必须还在句子里：" + gap)
        XCTAssertTrue(gap.contains("40.0%"), "差值那个测得值必须还在句子里：" + gap)
        XCTAssertFalse(gap.contains("%1$@"), "占位符没被填掉：" + gap)
    }
}
