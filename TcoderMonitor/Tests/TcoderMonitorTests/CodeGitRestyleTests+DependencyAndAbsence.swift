/// OWNER: WS-X3 TestSplit —— 自 CodeGitRestyleTests.swift 拆出，依赖缺数据态、表格唯一标题与缺省态互斥。用例本体未改，只是搬了家。
import XCTest
@testable import TcoderMonitor

extension CodeGitRestyleTests {

    func testUncheckedRowNeverRendersAsSafe() {
        for status in [DependencyRowStatus.versionOnly, .unchecked] {
            XCTAssertEqual(status.role.name, "neutral", "\(status.text) 不得带倾向色")
            XCTAssertNotEqual(status.badgeIcon, .noRisk, "没核对过就不能用对勾")
            XCTAssertNotEqual(status.text, "正常")
        }
        XCTAssertEqual(DependencyRowStatus.verifiedSafe.role.name, "success")
        XCTAssertEqual(DependencyRowStatus.verifiedSafe.badgeIcon, .noRisk)
        XCTAssertEqual(DependencyRowStatus.outdated.role.name, "warning")
        XCTAssertEqual(DependencyRowStatus.vulnerable(count: 2).badgeIcon, .vulnerable)
    }

    func testOfflineEmptyAdvisorySaysNotChecked() {
        let record = DependencyRecord(name: "lodash", version: "4.17.21", ecosystem: .npm,
                                      scope: .runtime, manifestPath: "/p/package.json",
                                      latestKnownVersion: nil, versionCheckSource: .none,
                                      knownVulnerabilities: [])
        let report = DependencyReport(ecosystems: [
            EcosystemReport(ecosystem: .npm, manifestPath: "/p/package.json", lockfileName: nil,
                            dependencies: [record], frameworkMarkers: [])
        ])
        let caption = DependencyAdvisoriesSection.emptyCaption(report)
        XCTAssertTrue(caption.contains("没有查"), caption)
        XCTAssertFalse(caption.contains("未发现已知漏洞"),
                       "离线空列表不得写成 all-clear 句式")
        XCTAssertEqual(DependencyAdvisoriesSection.subtitle(items: [], deps: report),
                       "内置快照与安全公告均未命中")
        XCTAssertEqual(DependencySafetyVerdict(report).badgeIcon, .unverified)
    }

    func testOutdatedCaptionWithoutComparableVersionsIsNotACleanZero() {
        XCTAssertEqual(DependencySummaryGrid.outdatedCaption(DependencyReport()), "没有可判定的依赖")
        let record = DependencyRecord(name: "left-pad", version: "1.0.0", ecosystem: .npm,
                                      scope: .runtime, manifestPath: "/p/package.json",
                                      latestKnownVersion: "2.0.0", versionCheckSource: .bundledSnapshot,
                                      knownVulnerabilities: [])
        let report = DependencyReport(ecosystems: [
            EcosystemReport(ecosystem: .npm, manifestPath: "/p/package.json", lockfileName: nil,
                            dependencies: [record], frameworkMarkers: [])
        ])
        XCTAssertTrue(DependencySummaryGrid.outdatedCaption(report).contains("占依赖总数"),
                      DependencySummaryGrid.outdatedCaption(report))
    }

    /// 批次 P5 把这一档从 `info` 收成 `neutral`：**判据的意图一字未改** ——
    /// "建议升级"既不许读成"已安全"（success），也不该借蓝当"第三种状态"
    /// （两批实拍点名提示条四色，蓝不在成功/警告/危险之内）。
    /// 红线：不许把它改回 success 来"让这条测试通过"。
    func testAdviceLineIsNeutralNotSuccess() {
        let item = VulnerabilityItem(id: "off-1", severity: .high, aliases: ["CVE-1"],
                                     targets: ["a", "b", "c", "d", "e"], range: "pkg <1.0",
                                     summary: "越界读取", advice: "建议升级至 1.0.1", score: 7.5,
                                     source: "npm")
        XCTAssertEqual(VulnerabilityRow.adviceRole(item).name, "neutral",
                       "「建议升级」是修复路径，不是已安全的结论，也不是第三种语义色")
        let line = VulnerabilityRow.targetsLine(item)
        XCTAssertTrue(line.hasPrefix("pkg <1.0 → "), line)
        XCTAssertTrue(line.contains("等 5 项"), line)
    }

    func testEveryTableHasOneLeadingColumnAndUniqueTitles() {
        let tables: [(String, [DataGridColumn])] = [
            ("complexityFunctions", DataColumns.complexityFunctions),
            ("hugeFiles", DataColumns.hugeFiles),
            ("dependencies", DataColumns.dependencies),
            ("recentCommits", DataColumns.recentCommits),
            ("duplicationBlocks", DataColumns.duplicationBlocks),
        ]
        for (name, columns) in tables {
            XCTAssertEqual(columns.filter { $0.width == nil }.count, 1,
                             "\(name) 必须恰好一个弹性名称列，否则表头与行会错位")
            XCTAssertEqual(columns.filter { $0.width == nil }.first?.alignment, .leading)
            XCTAssertTrue(columns.filter { $0.width != nil }.allSatisfy { $0.alignment != .leading }
                            || name == "recentCommits",
                          "\(name) 的定宽列不左对齐（SHA 列除外：十六进制串按前缀读，左对齐才对）")
            XCTAssertEqual(Set(columns.map(\.title)).count, columns.count, "\(name) 列名重复")
        }
    }

    func testColumnLookupsClampInsteadOfCrashing() {
        let columns = DataColumns.dependencies
        XCTAssertEqual(DataColumns.column(columns, columns.count).width, nil)
        XCTAssertEqual(DataColumns.column(columns, -1).width, nil)
    }

    func testGitAbsenceStatesAreMutuallyExclusive() {
        let notRepo = GitInsights(isRepository: false, totalCommits: 0)
        let empty = GitInsights(isRepository: true, totalCommits: 0)
        let unparsed = GitInsights(isRepository: true, totalCommits: 62, commitsAnalyzed: 0)
        XCTAssertEqual(notRepo.commitAbsence, .notARepository)
        XCTAssertEqual(empty.commitAbsence, .repositoryWithoutCommits)
        XCTAssertEqual(unparsed.commitAbsence, .commitsUnparsed(total: 62))
        XCTAssertEqual(GitInsights(isRepository: true, totalCommits: 62,
                                   commitsAnalyzed: 48).commitAbsence, .available)
    }

    func testAbsenceWordingsNeverBlendNotApplicableWithMeasuredZero() {
        let notRepo = GitDataAbsence.notARepository.copy!
        XCTAssertTrue(notRepo.message.contains("不适用"), notRepo.message)
        XCTAssertFalse(notRepo.title.contains("还没有提交"),
                       "不是仓库不能说成「还没有提交」，那是两件事")

        let measured = GitDataAbsence.repositoryWithoutCommits.copy!
        XCTAssertTrue(measured.message.contains("测得"), measured.message)
        XCTAssertTrue(measured.title.contains("还没有提交"), measured.title)

        let unparsed = GitDataAbsence.commitsUnparsed(total: 62).copy!
        XCTAssertTrue(unparsed.message.contains("不给任何结论"), unparsed.message)
        XCTAssertTrue(unparsed.title.contains("62"), unparsed.title)

        let noAuthors = GitDataAbsence.commitsWithoutAuthors(total: 48).copy!
        XCTAssertTrue(noAuthors.message.contains("不是「零贡献者」"), noAuthors.message)

        XCTAssertNil(GitDataAbsence.available.copy)
        XCTAssertFalse(GitDataAbsence.hasDuplicateTitles(),
                       "四个空态标题必须两两不同，否则等于又合回一句话")
    }

    func testAuthorAbsenceChainsAfterCommitAbsence() {
        let noRepo = GitInsights(isRepository: false)
        XCTAssertEqual(noRepo.authorAbsence, .notARepository, "不是仓库时先说仓库问题")
        let commitsButNoAuthors = GitInsights(isRepository: true, totalCommits: 62,
                                              commitsAnalyzed: 48, authors: [])
        XCTAssertEqual(commitsButNoAuthors.authorAbsence, .commitsWithoutAuthors(total: 48))
        let withAuthors = GitInsights(isRepository: true, totalCommits: 62, commitsAnalyzed: 48,
                                      authors: [author("A", "a@x", commits: 48)])
        XCTAssertEqual(withAuthors.authorAbsence, .available)
    }

    func testMemberColorsNeverCollideWithTheAggregateBlue() {
        XCTAssertEqual(CodeGitCategoryColor.aggregateIndex, 0,
                       "0 号蓝是「主/自身数据」档，合计行与主序列专用")
        for key in ["a@x", "b@x", "Swift", "Python", "dev@tcoder.local", "", "张三 <z@x>"] {
            XCTAssertNotEqual(CodeGitCategoryColor.index(for: key),
                              CodeGitCategoryColor.aggregateIndex,
                              "\(key) 抢到了合计行的颜色")
            XCTAssertTrue((0..<Theme.Chart.count).contains(CodeGitCategoryColor.index(for: key)))
        }
    }

}
