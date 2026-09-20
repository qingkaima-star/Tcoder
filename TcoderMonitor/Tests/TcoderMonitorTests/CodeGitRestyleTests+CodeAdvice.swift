/// OWNER: WS-X3 TestSplit —— 自 CodeGitRestyleTests.swift 拆出，代码规模/建议行/重复与复杂度档位的诚实读数。用例本体未改，只是搬了家。
import XCTest
@testable import TcoderMonitor

extension CodeGitRestyleTests {

    func testCodeGateKeepsNotAnalysedApartFromMeasuredEmpty() {
        XCTAssertEqual(CodeDataGate.state(of: nil), .notAnalysed)
        XCTAssertEqual(CodeDataGate.state(of: CodeMetrics()), .measuredEmpty)
        XCTAssertEqual(CodeDataGate.state(of: CodeMetrics(totalFiles: 3, totalLines: 30)), .analysed)
        XCTAssertNil(CodeDataGate.metrics(of: CodeMetrics()), "扫到空结果时不能继续渲染指标卡")

        let notAnalysed = CodeDataGate.emptyCopy(for: nil, page: "复杂度")
        let measured = CodeDataGate.emptyCopy(for: CodeMetrics(), page: "复杂度")
        XCTAssertNotNil(notAnalysed)
        XCTAssertNotNil(measured)
        XCTAssertNotEqual(notAnalysed?.title, measured?.title)
        XCTAssertTrue(measured!.message.contains("这是测得的结果"), measured!.message)
        XCTAssertTrue(notAnalysed!.message.contains("重新分析"), notAnalysed!.message)
    }

    func testMissingNumbersRenderAsPlaceholderNotZero() {
        XCTAssertEqual(DataAbsence.value("12").display, "12")
        XCTAssertEqual(DataAbsence.measuredEmpty.display, NumberFormat.grouped(0))
        XCTAssertEqual(DataAbsence.notAnalysed.display, "--",
                       "没有证据时必须显示 --，0 会被读成「零风险」这个好消息")
        XCTAssertFalse(DataAbsence.notAnalysed.permitsConclusion)
        XCTAssertEqual(DataAbsence.notAnalysed.effectiveRole(Theme.Semantic.success).name, "neutral",
                       "缺数据时中性角色必须盖掉调用方给的倾向色")
        XCTAssertEqual(DataAbsence.value("0").effectiveRole(Theme.Semantic.success).name, "success")
    }

    /// #47 之后这三处不再是 `--`：分母为 0 属「算不出」，`--` 只留给「没扫/没查」，
    /// 否则用户分不清"这项目真的没有"和"我们没查"（《42》§14.3 第 1 条）。
    /// 字面单点在 `Design/DataAbsence.swift`，四态本身由 `DesignAbsenceStateTests` 钉。
    func testAverageFileLinesUnknownIsPlaceholderNotZero() {
        XCTAssertEqual(CodeScaleSection.averageFileLines(CodeMetrics()), "算不出")
        XCTAssertEqual(CodeScaleSection.averageFileLines(CodeMetrics(totalFiles: 4, totalLines: 40)), "10.0")
        XCTAssertEqual(CodeMetricsSummaryGrid.shareOf(10, CodeMetrics()), "算不出",
                       "总行数为 0 时没有「占比」这个结论可言，但也不是没扫")
        XCTAssertEqual(CodeRiskAnalysis.averageComplexityValue(CodeMetrics(totalFiles: 1, totalLines: 10)),
                       "算不出", "一个函数都没识别出来时不能显示 0，也不能显示成「没查」")
    }

    func testLanguageMixMergesTailHonestly() {
        let shares = [
            LanguageShare(language: "Swift", fileCount: 40, lineCount: 1_000, share: 0.5),
            LanguageShare(language: "Python", fileCount: 10, lineCount: 400, share: 0.2),
            LanguageShare(language: "Ruby", fileCount: 5, lineCount: 200, share: 0.1),
            LanguageShare(language: "Go", fileCount: 5, lineCount: 200, share: 0.1),
            LanguageShare(language: "JS", fileCount: 2, lineCount: 100, share: 0.05),
            LanguageShare(language: "CSS", fileCount: 2, lineCount: 100, share: 0.05),
            LanguageShare(language: "Sh", fileCount: 1, lineCount: 0, share: 0),
        ]
        let code = CodeMetrics(languages: shares)
        let visible = CodeMetricsView.visibleShares(code, head: 4)
        // 同分时先按行数降序、再按语言名升序：Ruby 与 Go 都是 200 行 / 10%，所以 Go 在前。
        XCTAssertEqual(visible.map(\.language), ["Swift", "Python", "Go", "Ruby", "其他"])
        XCTAssertEqual(visible.last?.lineCount, 200, "「其他」= JS 100 + CSS 100")
        XCTAssertEqual(visible.last?.fileCount, 4)
        XCTAssertTrue(CodeMetricsView.mergedNote(code, head: 4)!.contains("占比最低的 2 种语言"))
        XCTAssertNil(CodeMetricsView.mergedNote(code, head: 8), "没超过展示上限就不该有合并说明")
        XCTAssertEqual(CodeScaleSection.subtitle(code), "按有效代码行计，共 7 种语言，展示前 6 种")
    }

    func testMarkerNoteOnZeroMarkersSaysScannedNotFound() {
        let clean = CodeMetrics(totalFiles: 12, totalLines: 400, codeLines: 300)
        XCTAssertTrue(CodeMarkersSection.markerNote(clean).contains("已完成扫描"))
        XCTAssertFalse(CodeMarkersSection.markerNote(clean).contains("建议优先"))
        XCTAssertEqual(CodeMarkersSection.markerDensityPerKilo(clean), 0)
        let withFixMe = CodeMetrics(totalFiles: 12, totalLines: 400, codeLines: 300, fixmeCount: 3)
        XCTAssertTrue(CodeMarkersSection.markerNote(withFixMe).contains("FIXME 3 处"))
    }

    func testDuplicationTiersFlipAtTheirDocumentedThresholds() {
        XCTAssertEqual(CodeRiskAnalysis.ratioRole(0).name, "success")
        XCTAssertEqual(CodeRiskAnalysis.ratioRole(CodeRiskAnalysis.duplicationNotableRatio - 0.001).name,
                       "success")
        XCTAssertEqual(CodeRiskAnalysis.ratioRole(CodeRiskAnalysis.duplicationNotableRatio).name, "warning")
        XCTAssertEqual(CodeRiskAnalysis.ratioRole(CodeRiskAnalysis.duplicationHighRatio).name, "danger")
    }

    func testEverySuggestionLineCarriesARealNumber() {
        let block = DuplicatedBlock(occurrences: [
            DuplicatedFragment(path: "/p/a.swift", startLine: 10),
            DuplicatedFragment(path: "/p/b.swift", startLine: 40),
            DuplicatedFragment(path: "/p/c.swift", startLine: 70),
        ], lineCount: 22, similarity: 0.94)
        let code = CodeMetrics(
            totalFiles: 50, totalLines: 9_000, commentLines: 120, codeLines: 7_000,
            todoCount: 9, fixmeCount: 4,
            hugeFiles: [FileHotspot(path: "/p/big.swift", lineCount: 900, risk: .high,
                                    suggestion: "按职责拆分")],
            duplicationRatio: 0.2, duplicatedBlocks: [block])
        let items = CodeRiskAnalysis.suggestions(for: code)
        XCTAssertFalse(items.isEmpty)
        for item in items {
            XCTAssertTrue(item.text.contains { $0.isNumber },
                          "无数字支撑的结论不许出现在建议区：\(item.text)")
        }
        XCTAssertTrue(items.contains { $0.id == "duplication-high" })
        XCTAssertTrue(items.contains { $0.id == "huge-file" })
        XCTAssertTrue(items.contains { $0.id == "markers" })
        XCTAssertTrue(items.contains { $0.id == "comments" })
        XCTAssertEqual(items.first(where: { $0.id == "duplication-high" })?.role.name, "danger")
    }

    func testCleanScanProducesNoSuggestionsAndOneHonestNote() {
        // 注释率要给到提示线以上，否则「注释率偏低」本身就会产出一条建议，测不到空集。
        let code = CodeMetrics(totalFiles: 4, totalLines: 200, commentLines: 20, codeLines: 180)
        XCTAssertTrue(CodeRiskAnalysis.suggestions(for: code).isEmpty)
        let note = CodeRiskAnalysis.noRiskNote(code)
        XCTAssertTrue(note.contains("已完成扫描"), note)
        XCTAssertTrue(note.contains("重复代码率 0.0%"), note)
    }

    func testComplexityDivergenceNeedsFiveHotspots() {
        func hotspots(_ count: Int, cc: Int) -> [FunctionHotspot] {
            (1...count).map {
                FunctionHotspot(name: "f\($0)", filePath: "/p/x.swift", startLine: $0,
                                lineCount: 60, cyclomaticComplexity: cc, parameterCount: 7, risk: .high)
            }
        }
        let few = CodeMetrics(totalFiles: 5, totalLines: 500, codeLines: 400,
                              topComplexFunctions: hotspots(4, cc: 30),
                              averageCyclomaticComplexity: 4)
        XCTAssertNil(CodeRiskAnalysis.relativeComplexitySuggestion(few),
                     "样本不足 5 个就不该断言「平均值被少数函数拉高」")
        let many = CodeMetrics(totalFiles: 5, totalLines: 500, codeLines: 400,
                               topComplexFunctions: hotspots(6, cc: 40), longFunctions: 6,
                               averageCyclomaticComplexity: 4)
        XCTAssertNotNil(CodeRiskAnalysis.relativeComplexitySuggestion(many))
        let items = CodeRiskAnalysis.suggestions(for: many)
        XCTAssertTrue(items.contains { $0.id == "parameters" }, "7 个参数 ≥ 阈值 6，必须点名")
        XCTAssertTrue(items.contains { $0.id == "complexity-high-cluster" })
        XCTAssertEqual(CodeRiskAnalysis.highRiskFunctionCount(many), 6)
    }

    func testDuplicationOccurrenceSummaryCountsTheRest() {
        let block = DuplicatedBlock(occurrences: (1...6).map {
            DuplicatedFragment(path: "/src/dir/file\($0).swift", startLine: $0 * 10)
        }, lineCount: 30, similarity: 0.9)
        let shown = CodeDuplicationBlockRow.occurrenceTitles(block, root: "/src")
        XCTAssertTrue(shown.contains("另有 2 处"), shown)
        XCTAssertEqual(CodeDuplicationBlockRow.occurrenceTitles(block, root: "/src", limit: 6)
            .components(separatedBy: "   ").count, 6)
        XCTAssertTrue(CodeDuplicationBlockRow.hint(block, root: "/src").contains("相似度 90.0%"))
    }

    /// 单元格侧的渲染契约：**一行一条路径**，折掉的条数与实际条数对得上。
    /// 粘连串（`occurrenceTitles`）只许留在 tooltip，见 `pathGlueOutsideHelp` 守卫。
    func testDuplicationOccurrencesRenderOnePathPerLine() {
        let block = DuplicatedBlock(occurrences: (1...6).map {
            DuplicatedFragment(path: "/src/dir/file\($0).swift", startLine: $0 * 10)
        }, lineCount: 30, similarity: 0.9)
        let lines = CodeDuplicationBlockRow.occurrenceLines(block, root: "/src")
        XCTAssertEqual(lines.count, CodeDuplicationBlockRow.occurrenceLineLimit)
        XCTAssertEqual(CodeDuplicationBlockRow.occurrenceRestCount(block),
                       block.occurrences.count - lines.count,
                       "「另有 N 处」的 N 必须等于真被折掉的条数，不能凭感觉写")
        for line in lines {
            XCTAssertFalse(line.text.contains("   "), "单格里又粘了多段路径：\(line.text)")
            XCTAssertEqual(line.text.split(separator: ":").count, 2, "一行只该有一个 路径:行号：\(line.text)")
            XCTAssertNotNil(line.help, "中间截断必须有整条路径可回读")
        }
        // 出现次数没超上限时不该冒出汇总行
        let few = DuplicatedBlock(occurrences: Array(block.occurrences.prefix(2)),
                                  lineCount: 30, similarity: 0.9)
        XCTAssertEqual(CodeDuplicationBlockRow.occurrenceRestCount(few), 0)
        XCTAssertEqual(CodeDuplicationBlockRow.occurrenceLines(few, root: "/src").count, 2)
    }

}
