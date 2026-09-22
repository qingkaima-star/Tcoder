import XCTest
@testable import TcoderMonitor

/// OWNER: WS-R10 报告追溯（R10b 第二半）。
///
/// 钉三件事（用户 §十一）：① 每一路的**状态/耗时/上限/失败原因**能在文本出口问出来；
/// ② **量出来的**与**算出来的**分栏，派生项点名它的来源；③ 每条重要结论落到
/// **文件 + 符号 + 判据名** 的可定位坐标。外加四类高价值检查只出「候选·未判定」的提示。
///
/// **独立真值怎么来的**（本轮纪律：不许拿实现自身的输出当唯一真值）：`fullReport()` 里每一格
/// 都是手写的具体数字，期望值全部手算 —— 注释 25 / 总行 100 ⇒ 0.25；作者 7+3 ⇒ 集中度 70.0%；
/// 覆盖 40/100 ⇒ 40.00；分量 80×0.6 + 60×0.4 ⇒ 72；坐标 = 巨大文件 2 + 复杂度榜 3 + 重复块 1
/// + 通告 1 + 日志簇 1 + 覆盖率报告 1 = **9 条**，是数出来的，不是让被测代码自己报的。
final class ReportTraceabilityTests: XCTestCase {

    // MARK: - 夹具

    private func record(_ name: String, _ state: AnalyzerRunState, durationMs: Int? = 7,
                        limits: [String]? = nil, reason: String? = nil) -> AnalyzerRunRecord {
        AnalyzerRunRecord(name: name, state: state, durationMs: durationMs,
                          limitsHit: limits, failureReason: reason)
    }

    private func stubReport(code: CodeMetrics? = nil,
                            ledger: [AnalyzerRunRecord]? = nil) -> ProjectReport {
        var report = ProjectReport(project: MonitoredProject(name: "夹具", path: "/tmp/r10b"))
        report.code = code
        report.analyzerLedger = ledger
        return report
    }

    private func fullReport() -> ProjectReport {
        var full = stubReport(code: fixtureCode())
        full.git = fixtureGit()
        full.logs = fixtureLogs()
        full.dependencies = fixtureDeps()
        full.coverage = fixtureCoverage()
        full.health = fixtureHealth()
        full.provenance = provenanceStub(root: "/tmp/r10b")
        full.analyzerLedger = AnalyzerLedger.records(from: [
            AnalyzerAttempt(label: AnalyzerLedger.sectionLabels[0], durationMs: 42,
                            limitsHit: ["明细榜单截断到 20 块"]),
            AnalyzerAttempt(label: AnalyzerLedger.sectionLabels[1], durationMs: 31),
            AnalyzerAttempt(label: AnalyzerLedger.sectionLabels[2], durationMs: 9, failureReason: "没有可读日志"),
            AnalyzerAttempt(label: AnalyzerLedger.sectionLabels[3], didRun: false),
            AnalyzerAttempt(label: AnalyzerLedger.sectionLabels[4], durationMs: 5),
        ])
        return full
    }

    private func fixtureCode() -> CodeMetrics {
        var code = CodeMetrics()          // 下面每一格都是手写的整数，期望值全部能手算
        code.totalFiles = 7; code.totalLines = 100; code.blankLines = 10
        code.commentLines = 25; code.codeLines = 65; code.analyzedFunctionCount = 8
        code.averageFunctionLength = 20; code.averageCyclomaticComplexity = 4.25
        code.hugeFileCount = 5; code.highRiskHotspotCount = 2
        code.duplicationRatio = 0.10; code.durationMs = 42
        code.scanLimitations = ["明细榜单截断到 20 块。"]
        code.hugeFiles = [FileHotspot(path: "/tmp/r10b/A.swift", lineCount: 900, risk: .high, suggestion: "拆"),
                         FileHotspot(path: "/tmp/r10b/B.swift", lineCount: 500, risk: .medium, suggestion: "拆")]
        code.topComplexFunctions = [
            FunctionHotspot(name: "alpha", filePath: "/tmp/r10b/A.swift", startLine: 12, lineCount: 90,
                            cyclomaticComplexity: 33, parameterCount: 4, risk: .high),
            FunctionHotspot(name: "beta", filePath: "/tmp/r10b/B.swift", startLine: 8, lineCount: 60,
                            cyclomaticComplexity: 24, parameterCount: 2, risk: .high),
            FunctionHotspot(name: "gamma", filePath: "/tmp/r10b/A.swift", startLine: 400, lineCount: 30,
                            cyclomaticComplexity: 18, parameterCount: 1, risk: .medium),
        ]
        code.duplicatedBlocks = [DuplicatedBlock(
            occurrences: [DuplicatedFragment(path: "/tmp/r10b/A.swift", startLine: 12),
                          DuplicatedFragment(path: "/tmp/r10b/B.swift", startLine: 8)],
            lineCount: 12, similarity: 0.92)]
        return code
    }

    private func fixtureGit() -> GitInsights {
        var git = GitInsights()
        git.isRepository = true; git.totalCommits = 10; git.commitsAnalyzed = 8; git.projectAgeDays = 10
        git.firstCommitAt = Date(timeIntervalSince1970: 1_700_000_000)
        git.lastCommitAt = Date(timeIntervalSince1970: 1_700_000_000 + 10 * 86_400)
        git.authors = [author("甲", commits: 7), author("乙", commits: 3)]
        return git
    }

    private func fixtureLogs() -> LogSummary {
        var logs = LogSummary()
        logs.totalLinesScanned = 1_000; logs.errorCount = 6; logs.warningCount = 2; logs.crashCount = 1
        logs.scannedFiles = [scannedLog("/tmp/a.log"), scannedLog("/tmp/b.log")]
        logs.topErrors = [cluster(signature: "sig-null-1", source: "/tmp/r10b/A.swift")]
        return logs
    }

    private func fixtureDeps() -> DependencyReport {
        var deps = DependencyReport()
        deps.ecosystems = [EcosystemReport(
            ecosystem: .npm, manifestPath: "/tmp/r10b/package.json", lockfileName: nil,
            dependencies: [dependency("left-pad", "1.0.0", "1.3.0"),
                           dependency("express", "4.18.2", "4.18.2"),
                           dependency("chalk", "5.0.0", "5.0.0")],
            frameworkMarkers: [])]
        deps.advisories = [SecurityAdvisory(id: "GHSA-aaaa-bbbb-cccc", aliases: ["CVE-2024-0001"],
                                            summary: "s", details: "d", severity: .high, cvssScore: 7.5,
                                            affectedPackages: ["left-pad"], ecosystem: .npm,
                                            publishedAt: nil, source: "osv")]
        return deps
    }

    private func fixtureCoverage() -> CoverageMetrics {
        var coverage = CoverageMetrics()
        coverage.scannedFileCount = 12; coverage.unreadableDirectoryCount = 0
        coverage.reports = [coverageReport("/tmp/r10b/lcov.info", covered: 40, total: 100)]
        return coverage
    }

    private func fixtureHealth() -> HealthScore {
        var health = HealthScore()       // 80×0.6 + 60×0.4 = 72，就是下面 overall 那个数
        health.components = [ScoreComponent(name: "代码质量", score: 80, weight: 0.6, detail: "d", risk: .low),
                             ScoreComponent(name: "复杂度", score: 60, weight: 0.4, detail: "d", risk: .medium)]
        health.overall = 72
        health.recommendations = ["把超长文件按类型整块搬去新文件"]
        health.issues = ["榜上有 3 个函数判档达到高"]
        return health
    }

    private func author(_ name: String, commits: Int) -> AuthorStats {
        AuthorStats(name: name, email: "\(name)@tcoder.local", commits: commits, additions: commits * 10,
                    deletions: commits, filesTouched: commits, firstCommitAt: nil, lastCommitAt: nil,
                    activityByHour: Array(repeating: 0, count: 24), topDirectories: [:])
    }

    private func scannedLog(_ path: String) -> ScannedLogFile {
        ScannedLogFile(path: path, sizeBytes: 1_024, lineCount: 500, modifiedAt: Date(), role: .application)
    }

    private func cluster(signature: String, source: String) -> ErrorCluster {
        ErrorCluster(signature: signature, displayMessage: "m", count: 3, firstSeen: nil, lastSeen: nil,
                     sourceFile: source, severity: .error, sampleLines: [], stackTopFrames: [])
    }

    private func dependency(_ name: String, _ current: String, _ latest: String) -> DependencyRecord {
        DependencyRecord(name: name, version: current, ecosystem: .npm, scope: .runtime,
                         manifestPath: "/tmp/r10b/package.json", latestKnownVersion: latest,
                         versionCheckSource: .bundledSnapshot, knownVulnerabilities: [])
    }

    private func coverageReport(_ path: String, covered: Int, total: Int) -> CoverageReport {
        CoverageReport(path: path, kind: .unit, toolName: "llvm-cov", linesCovered: covered,
                       linesTotal: total, branchesCovered: 0, branchesTotal: nil, methodsCovered: 0,
                       methodsTotal: 0, allLinesCovered: covered + 10, allLinesTotal: total + 40,
                       scopeGranularity: .perSourceFile, generatedAt: nil)
    }

    private func provenanceStub(root: String) -> ScanProvenance {
        var provenance = ScanProvenance()
        provenance.scannedRoot = root   // 其余字段留 nil = 未记录，不去凑一个假提交号
        return provenance
    }

    private func value(_ ledger: MeasurementLedger, _ item: String) -> String {
        ledger.rows.first { $0.item == item }?.value ?? "（这一项不在台账里）"
    }

    // MARK: - ① 台账上屏：四态各自可观测

    func test_fourStatesRenderAsFourDifferentPhrases() {
        // 四态名单在测试里自己列一份：`AnalyzerRunState` 在冻结区、没有 allCases，
        // 也不许为了让一条断言顺手就改契约。
        let phrases = [.ok, .partial, .failed, .notRun].map { AnalyzerLedgerText.statePhrase($0) }
        XCTAssertEqual(Set(phrases).count, 4, "四态必须四样措辞，长得一样就说明某一态被折叠了")
        XCTAssertEqual(AnalyzerLedgerText.statePhrase(.notRun), "没跑（装配口没排进来）")
    }

    func test_notRunNeverRendersAsAPass() {
        let line = AnalyzerLedgerText.row(record("依赖分析", .notRun, durationMs: nil))
        XCTAssertEqual(line, "  [没跑（装配口没排进来）] 依赖分析 · 无耗时 · 无读数")
        for forbidden in ["没问题", "通过", "正常", "健康", "无失败", "耗时 0"] {
            XCTAssertFalse(line.contains(forbidden), "没跑被写成了判定词 \(forbidden)：\(line)")
        }
    }

    func test_tallyPrintsAllFourCountersEvenWhenZero() {
        let onlyFailures = [record("代码扫描", .failed, reason: "读不到"),
                            record("Git 分析", .failed, reason: "读不到")]
        let tally = AnalyzerLedgerText.tally(onlyFailures)
        for label in ["跑完 0", "部分 0", "失败 2", "没跑 0"] {
            XCTAssertTrue(tally.contains(label), "计数缺一即等于把四态折成两态：\(tally)")
        }
    }

    func test_durationAndReasonNeverCollapseToZeroOrEmpty() {
        XCTAssertEqual(AnalyzerLedgerText.durationText(nil), "耗时未记录")
        XCTAssertEqual(AnalyzerLedgerText.durationText(0), "耗时 0 ms", "量到的 0 与没量到是两件事")
        XCTAssertTrue(AnalyzerLedgerText.reasonText(nil).hasPrefix("未记录"))
        XCTAssertEqual(AnalyzerLedgerText.limitsText(["A", "B"]), "撞到 2 条上限：A / B",
                       "撞到的上限必须逐条列出，不许折叠成「另有若干限制」")
        XCTAssertEqual(AnalyzerLedgerText.limitsText([]), "撞上限的条目未记录")
    }

    /// 顺序就是这一屏的全部设计：先说没量准，再说每一路做了什么，最后才给分。
    func test_sectionSitsAfterCaveatAndBeforeTheScore() {
        let lines = CLIScoreText.render(fullReport(), exit: .partial).components(separatedBy: "\n")
        let caveat = lines.firstIndex { $0.hasPrefix("未量准") }
        let ledger = lines.firstIndex { $0.hasPrefix(AnalyzerLedgerText.headerToken) }
        let score = lines.firstIndex { $0.hasPrefix("综合健康分") }
        XCTAssertNotNil(caveat, "未量准那段没打出来，这条顺序断言不作数")
        XCTAssertNotNil(ledger, "台账整段没上屏：\n" + lines.joined(separator: "\n"))
        XCTAssertNotNil(score)
        if let caveat, let ledger, let score {
            XCTAssertLessThan(caveat, ledger, "台账必须排在「未量准」之后")
            XCTAssertLessThan(ledger, score, "台账必须排在综合分之前：先交代每一路做了什么，再给分")
        }
    }

    func test_missingLedgerStillSpeaksAndEmptyArrayIsNotClaimedAsNotRun() {
        let nilText = AnalyzerLedgerText.section(stubReport(code: nil, ledger: nil)).joined(separator: "\n")
        XCTAssertTrue(nilText.contains("未记录"), "旧报告没有台账格时整段静默消失 = 这一屏不需要交代")
        XCTAssertFalse(nilText.contains("各路执行情况 5 路"), "台账一个字节都没有，却打出五路计数 = 凭空造读数")
        let emptyText = AnalyzerLedgerText.section(stubReport(code: nil, ledger: [])).joined(separator: "\n")
        XCTAssertTrue(emptyText.contains("空数组"), "空数组必须被读成「这份台账没写」，而不是「五路都没跑」")
        XCTAssertFalse(emptyText.contains("没跑 5"))
    }

    // MARK: - ② 测量台账：两栏 + 派生项点名来源

    /// 甲栏（量出来的）与乙栏（算出来的）必须真是两栏，且乙栏每行都带来源。
    func test_measuredAndDerivedAreTwoSeparateColumns() {
        let ledger = MeasurementLedger.of(fullReport())
        XCTAssertFalse(ledger.measuredRows.isEmpty, "甲栏空了，分栏就形同虚设")
        XCTAssertFalse(ledger.derivedRows.isEmpty, "乙栏空了，同上")
        let lines = ledger.text()
        let first = lines.firstIndex { $0.hasPrefix("  甲·") } ?? -1
        let second = lines.firstIndex { $0.hasPrefix("  乙·") } ?? -1
        XCTAssertGreaterThan(first, -1, "甲栏标题没上屏")
        XCTAssertGreaterThan(second, -1, "乙栏标题没上屏")
        XCTAssertLessThan(first, second, "甲栏（量出来的）必须排在乙栏之前")
        let attributed = lines.filter { $0.contains("← 由「") }.count
        XCTAssertEqual(attributed, ledger.derivedRows.count, "有几条派生行没带「由哪些测量项算来」")
    }

    func test_derivedSourcesAllResolveAndNothingIsLeftUnattributed() {
        let ledger = MeasurementLedger.of(fullReport())
        XCTAssertTrue(ledger.derivedWithoutNamedSource.isEmpty,
                      "有派生项没点名来源：\(ledger.derivedWithoutNamedSource.map(\.item))")
        XCTAssertTrue(ledger.danglingSources.isEmpty,
                      "派生项引了本表与上游清单里都不存在的来源：\(ledger.danglingSources)")
    }

    /// 上游清单也要有牙：每条都得写理由，且真的被某条派生行用到（挂账不许当遮羞布）。
    func test_upstreamRosterHasOneReasonPerEntryAndNoneIsDead() {
        let used = Set(MeasurementLedger.of(fullReport()).derivedRows.flatMap(\.source))
        XCTAssertFalse(MeasurementLedger.upstreamInputs.isEmpty)
        for (key, reason) in MeasurementLedger.upstreamInputs {
            XCTAssertGreaterThan(reason.count, 12, "\(key) 的理由是一句空话：\(reason)")
            XCTAssertTrue(used.contains(key), "\(key) 挂在清单里却没有任何派生行引用它 —— 划掉它")
        }
    }

    /// 独立真值：下面每个期望数都是夹具手写值算出来的，不是被测代码给的。
    func test_handComputedDerivedValuesAreWhatTheColumnShows() {
        let ledger = MeasurementLedger.of(fullReport())
        XCTAssertEqual(value(ledger, "注释占比"), "0.25", "25 / 100 手算 = 0.25")
        XCTAssertEqual(value(ledger, "平均圈复杂度"), "4.25")
        XCTAssertEqual(value(ledger, "重复行占比"), "0.10", "12 行重复块 / 65 码行是另一回事，这里读契约给的 0.10")
        XCTAssertEqual(value(ledger, DerivedItem.topAuthorShare), "70.0%", "7 /(7+3) 手算 = 70%")
        XCTAssertEqual(value(ledger, DerivedItem.scoredLinePercent), "40.00", "40 / 100 手算")
        XCTAssertEqual(value(ledger, "综合健康分"), "72", "80×0.6 + 60×0.4 手算 = 72")
        XCTAssertEqual(value(ledger, MeasuredItem.files), "7", "甲栏必须原样给出文件数，不许被乙栏的比值顶替")
    }

    /// 元测试（证明尺子有牙）：塞一条假来源与一条无来源的派生行，两个反例都得抓到。
    func test_meta_danglingSourceIsCaught() {
        let fake = MeasurementLedger(rows: [
            MeasurementRow(basis: .measured, path: "代码扫描", item: "文件数", value: "3", source: ["x"]),
            MeasurementRow(basis: .derived, path: "代码扫描", item: "假派生", value: "9",
                           source: ["根本不存在的那一项"]),
            MeasurementRow(basis: .derived, path: "代码扫描", item: "没来源的派生", value: "8", source: []),
        ])
        XCTAssertEqual(fake.danglingSources, ["根本不存在的那一项"])
        XCTAssertEqual(fake.derivedWithoutNamedSource.map(\.item), ["没来源的派生"])
        XCTAssertTrue(fake.text().joined(separator: "\n").contains("⚠"))
    }

    // MARK: - ③ 结论 → 可定位证据

    func test_everyBoardEntryCarriesExactlyOneCoordinate() {
        let coordinates = EvidenceCoordinates.of(fullReport())
        // 手数的份数：巨大文件 2 + 复杂度榜 3 + 重复块 1 + 通告（受影响包 1 个）1
        // + 日志簇 1 + 覆盖率报告 1 = 9
        XCTAssertEqual(coordinates.count, 9, "坐标条数必须与榜上条目一一对得上：\n"
                     + coordinates.map(\.key).joined(separator: "\n"))
        XCTAssertEqual(Set(coordinates.map(\.key)).count, 9, "两条坐标撞了同一个 key，就没法点名")
    }

    func test_coordinatesSupportIntersectionAndDiff() {
        let before = Set(EvidenceCoordinates.of(fullReport()).map(\.key))
        var grown = fullReport()
        grown.code?.topComplexFunctions.append(
            FunctionHotspot(name: "delta", filePath: "/tmp/r10b/C.swift", startLine: 3, lineCount: 12,
                            cyclomaticComplexity: 17, parameterCount: 1, risk: .medium))
        let after = Set(EvidenceCoordinates.of(grown).map(\.key))
        XCTAssertEqual(after.intersection(before).count, before.count, "同一条结论的坐标必须逐字稳定")
        XCTAssertEqual(after.subtracting(before), ["C.swift ⇑ delta ⇑ " + CriterionName.hotspot],
                       "多一条结论就只能多这一个坐标")
    }

    func test_keysAreRelativePathLineFreeAndHonestAboutMissingSymbol() {
        let coordinates = EvidenceCoordinates.of(fullReport())
        for coordinate in coordinates {
            XCTAssertFalse(coordinate.file.hasPrefix("/tmp/r10b/"),
                           "坐标里留着绝对路径，换个目录就没法求交：\(coordinate)")
            XCTAssertFalse(coordinate.symbol.isEmpty, "符号位空着会被读成「这一条没有符号」")
            XCTAssertFalse(coordinate.criterion.isEmpty)
            XCTAssertFalse(coordinate.key.contains("startLine"))
        }
        let fileLevel = coordinates.filter { $0.symbol == EvidenceCoordinate.fileLevelSymbol }
        XCTAssertEqual(fileLevel.count, 2, "两条巨大文件结论在契约里就是没有符号位的，必须明说不塞个问号")
    }

    func test_cveRowsLandOnTheManifestThatCarriesThePackage() {
        let osv = EvidenceCoordinates.of(fullReport()).filter { $0.criterion == CriterionName.osvAdvisory }
        XCTAssertEqual(osv.count, 1)
        XCTAssertEqual(osv.first?.file, "package.json", "CVE 行必须落到装着这个包的那份清单，而不是没有文件")
        XCTAssertTrue(osv.first?.symbol.contains("GHSA-aaaa-bbbb-cccc") == true, "通告号也得在坐标里")
    }

    func test_adviceWithoutAStructuredAnchorIsNamedNotHidden() {
        let loose = EvidenceCoordinates.unanchored(fullReport())
        XCTAssertEqual(loose.count, 2, "夹具里 1 条建议 + 1 条问题，两句在契约里都没有回指字段")
        XCTAssertTrue(loose.allSatisfy { $0.contains("未落坐标") })
        XCTAssertTrue(EvidenceCoordinates.text(fullReport()).joined(separator: "\n").contains("未落坐标 2 条"))
    }

    // MARK: - ④ 候选风险提示：只提示，不扣分

    func test_productSideEmitsNoHintsAndSaysWhichInputIsMissing() {
        let text = CandidateRiskHints.text(fullReport()).joined(separator: "\n")
        XCTAssertEqual(CandidateRiskHints.rules.count, 4, "用户点名的四类检查一条都不能少")
        for rule in CandidateRiskHints.rules {
            XCTAssertTrue(text.contains(rule.kind), "\(rule.kind) 没上屏")
            XCTAssertTrue(text.contains("缺输入"), "\(rule.kind) 没交代为什么一条都没发")
        }
        XCTAssertTrue(text.contains("风险提示 0 条"))
    }

    /// 正例：给了输入，规则本体真能出条目并自带坐标（不是空壳）。
    func test_ruleEmitsCoordinatedHintWhenGivenEvidence() {
        let evidence = CandidateRiskHints.rules.map {
            CandidateRiskHints.CandidateEvidence(kind: $0.kind, file: "A.swift", symbol: "run()", detail: "形态像")
        } + [CandidateRiskHints.CandidateEvidence(kind: "用户没点名的第 5 类", file: "B.swift",
                                                 symbol: "x()", detail: "不该出现")]
        let hints = CandidateRiskHints.hints(from: evidence)
        XCTAssertEqual(hints.count, 4, "只认清单里的四类，第 5 类不许悄悄收进来")
        for hint in hints {
            XCTAssertTrue(hint.displayLine.contains(CandidateRiskHints.screenToken),
                          "候选行少了这个标记就会长成判定：\(hint.displayLine)")
            XCTAssertEqual(hint.coordinate.key, "\(hint.file) ⇑ \(hint.symbol) ⇑ \(hint.kind)")
            XCTAssertTrue(hint.confidence.contains("无独立真值"))
        }
    }

    /// 结构门：评分与判据那几路不许读候选提示（提示一旦进评分就变成扣分项）。
    func test_scorerNeverLooksAtCandidateHints() throws {
        for dir in ["Services/Health", "Services/Code", "Models"] {
            for file in try SurfaceScanKit.sourceFiles(under: dir) {
                XCTAssertFalse(file.content.contains("CandidateRiskHint"),
                               "\(file.path) 引用了候选提示 —— 提示会变成扣分项，本轮明令禁止")
            }
        }
        let cli = try SurfaceScanKit.sourceFiles(under: "Services/CLI")
        XCTAssertTrue(cli.contains { $0.content.contains("CandidateRiskHints") },
                      "CLI 才是这段文字唯一的出口；它不在场说明这段没接上屏")
    }

    func test_scoreLineComesBeforeEveryTraceabilitySection() {
        let lines = CLIScoreText.render(fullReport(), exit: .partial).components(separatedBy: "\n")
        let score = lines.firstIndex { $0.hasPrefix("综合健康分") } ?? -1
        let tail = lines.firstIndex { $0.hasPrefix("测量台账") } ?? -1
        let coordinates = lines.firstIndex { $0.hasPrefix("结论坐标") } ?? -1
        let hints = lines.firstIndex { $0.hasPrefix("风险提示") } ?? -1
        XCTAssertGreaterThan(score, -1)
        XCTAssertGreaterThan(tail, score, "附页跑到分数前面去影响判断了")
        XCTAssertGreaterThan(coordinates, tail)
        XCTAssertGreaterThan(hints, coordinates)
    }
}
