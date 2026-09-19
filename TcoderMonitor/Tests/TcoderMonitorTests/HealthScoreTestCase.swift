import XCTest
@testable import TcoderMonitor

/// WS-C 健康评分单测的共用夹具与不变量帮手。
/// WS-V 机械拆分自 HealthScoreTests.swift（1083 行越过 800 闸门），正文逐行原样搬运，
/// 只把 `private` 降为 internal 以便三个拆分类继承：
///   HealthScoreCurvesTests / HealthScoreScorerTests / HealthScoreHonestyTests。
class HealthScoreTestCase: XCTestCase {
    /// 无任何复杂度证据的仓库。
    func blindCode() -> CodeMetrics {
        var code = healthyCode()
        code.analyzedFunctionCount = 0
        code.averageCyclomaticComplexity = nil
        code.topComplexFunctions = []
        return code
    }

    /// 只有热点榜、没有全仓均值的仓库（WS-A 落地前的真实形态）。
    func hotspotCode() -> CodeMetrics {
        var code = healthyCode()
        code.analyzedFunctionCount = 420
        code.averageCyclomaticComplexity = nil
        return code
    }

    // MARK: - 夹具

    /// 曲线通用不变量：分数有限且落在 0...100、detail 非空、风险与分数方向一致。
    /// 风险规则按规格实现：<= 20 视为高危（.high/.critical）；>= 90 不得是 .critical。
    /// 两处刻意放宽：(1) 90+ 允许 .low/.medium（只禁 .critical）；
    /// (2) detail 已说明「无数据/未扫描/默认」时允许低分配低风险，那是证据缺失而非确证高危。
    func assertCurveIsValid(_ result: CurveResult, context: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(result.score.isFinite, "\(context)：分数必须有限，实际 \(result.score)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(result.score, 0, "\(context)：分数不得为负，实际 \(result.score)", file: file, line: line)
        XCTAssertLessThanOrEqual(result.score, 100, "\(context)：分数不得超过 100，实际 \(result.score)", file: file, line: line)
        XCTAssertFalse(result.detail.isEmpty, "\(context)：detail 必须非空", file: file, line: line)
        let explainsMissingData = result.detail.contains("无数据")
            || result.detail.contains("未扫描")
            || result.detail.contains("默认")
        if result.score <= 20 && !explainsMissingData {
            XCTAssertTrue(
                result.risk.rank >= RiskLevel.high.rank,
                "\(context)：分数 \(result.score) <= 20 时风险必须是 high/critical，实际 \(result.risk.rawValue)",
                file: file, line: line
            )
        }
        if result.score >= 90 {
            XCTAssertNotEqual(
                result.risk, .critical,
                "\(context)：分数 \(result.score) >= 90 时不得标严重风险",
                file: file, line: line
            )
        }
    }

    func healthyCode() -> CodeMetrics {
        CodeMetrics(
            totalFiles: 320,
            totalLines: 48_000,
            blankLines: 7_200,
            commentLines: 2_600,
            codeLines: 38_200,
            languages: [LanguageShare(language: "Java", fileCount: 320, lineCount: 48_000, share: 1)],
            todoCount: 3,
            fixmeCount: 0,
            hugeFiles: [],
            topComplexFunctions: [
                FunctionHotspot(
                    name: "calculateTotal",
                    filePath: "src/OrderService.java",
                    startLine: 88,
                    lineCount: 46,
                    cyclomaticComplexity: 9,
                    parameterCount: 3,
                    risk: .low
                ),
            ],
            longFunctions: 5,
            averageFunctionLength: 24,
            analyzedFunctionCount: 420,
            duplicationRatio: 0.02,
            largestFileLineCount: 480,
            overallRisk: .low
        )
    }

    func activeGit() -> GitInsights {
        // 用相对时间造一份「最近仍在提交」的仓库；断言只依赖确定性的曲线与权重不变量，
        // 不对任何具体日期或时钟读数做精确断言。
        let first = Date(timeIntervalSinceNow: -700 * 86_400)
        let last = Date(timeIntervalSinceNow: -2 * 86_400)
        return GitInsights(
            isRepository: true,
            branch: "main",
            headSHA: String(repeating: "a", count: 40),
            totalCommits: 820,
            firstCommitAt: first,
            lastCommitAt: last,
            projectAgeDays: 700,
            totalAdditions: 120_000,
            totalDeletions: 40_000,
            filesTouched: 900,
            authors: [
                author(name: "dev-one", commits: 300, first: first, last: last),
                author(name: "dev-two", commits: 300, first: first, last: last),
                author(name: "dev-three", commits: 220, first: first, last: last),
            ]
        )
    }

    func author(name: String, commits: Int, first: Date, last: Date) -> AuthorStats {
        AuthorStats(
            name: name,
            email: "\(name)@com.example",
            commits: commits,
            additions: commits * 40,
            deletions: commits * 9,
            filesTouched: commits,
            firstCommitAt: first,
            lastCommitAt: last,
            activityByHour: Array(repeating: 1, count: 24),
            topDirectories: ["src": commits]
        )
    }

    func healthyLogs() -> LogSummary {
        LogSummary(
            errorCount: 3,
            exceptionCount: 1,
            warningCount: 40,
            crashCount: 0,
            fatalCount: 0,
            infoLineCount: 9_000,
            totalLinesScanned: 120_000
        )
    }

    func mavenEcosystem(total: Int, outdated: Int) -> EcosystemReport {
        var records: [DependencyRecord] = []
        for index in 0..<total {
            records.append(DependencyRecord(
                name: "com.example.lib\(index)",
                version: index < outdated ? "1.0.0" : "2.0.0",
                ecosystem: .maven,
                scope: .runtime,
                manifestPath: "pom.xml",
                latestKnownVersion: "2.0.0",
                versionCheckSource: .bundledSnapshot,
                knownVulnerabilities: []
            ))
        }
        return EcosystemReport(
            ecosystem: .maven,
            manifestPath: "pom.xml",
            lockfileName: nil,
            dependencies: records,
            frameworkMarkers: []
        )
    }

    /// 造出 count 个「受影响依赖」：每个 advisory 命中 1 个包，vulnerableCount == count。
    func advisories(count: Int) -> [SecurityAdvisory] {
        (0..<count).map { index in
            SecurityAdvisory(
                id: "GHSA-\(index)",
                aliases: ["CVE-2024-\(index)"],
                summary: "com.example.lib\(index) 存在越界写入",
                details: "",
                severity: .high,
                cvssScore: 7.8,
                affectedPackages: ["com.example.lib\(index)"],
                ecosystem: .maven,
                publishedAt: nil,
                source: "本地快照"
            )
        }
    }

    /// 已联网核对且零命中的依赖报告 —— 这是唯一能让依赖维度参与评分并拿高分的形态。
    func cleanDependencies() -> DependencyReport {
        var deps = DependencyReport(ecosystems: [mavenEcosystem(total: 140, outdated: 0)])
        deps.networkLookupPerformed = true
        deps.networkLookupNote = "在线查询已完成（OSV + npm registry）"
        return deps
    }

    /// 默认离线形态：没联网、内置规则也没命中 —— 依赖健康不得计分。
    func offlineDependencies() -> DependencyReport {
        DependencyReport(ecosystems: [mavenEcosystem(total: 140, outdated: 0)])
    }

    func fullInputs() -> HealthInputs {
        HealthInputs(
            code: healthyCode(),
            git: activeGit(),
            logs: healthyLogs(),
            dependencies: cleanDependencies(),
            previousScore: 55
        )
    }

    /// 明显很差的仓库：高重复 + 高圈复杂度 + 崩溃日志 + 12 个漏洞。
    func neglectedInputs() -> HealthInputs {
        var code = healthyCode()
        code.duplicationRatio = 0.30
        code.averageFunctionLength = 150
        code.longFunctions = 180
        code.fixmeCount = 46
        code.hugeFiles = [
            FileHotspot(path: "src/OrderService.java", lineCount: 4_200, risk: .critical, suggestion: "按职责拆分")
        ]
        code.topComplexFunctions = [
            FunctionHotspot(
                name: "applyDiscountRules",
                filePath: "src/OrderService.java",
                startLine: 310,
                lineCount: 420,
                cyclomaticComplexity: 25,
                parameterCount: 9,
                risk: .critical
            ),
            FunctionHotspot(
                name: "syncLegacyLedger",
                filePath: "src/LegacySync.java",
                startLine: 44,
                lineCount: 380,
                cyclomaticComplexity: 31,
                parameterCount: 7,
                risk: .critical
            ),
        ]

        var logs = healthyLogs()
        logs.errorCount = 380
        logs.crashCount = 5
        logs.fatalCount = 3
        logs.exceptionCount = 60
        logs.totalLinesScanned = 60_000

        return HealthInputs(
            code: code,
            git: activeGit(),
            logs: logs,
            dependencies: DependencyReport(
                ecosystems: [mavenEcosystem(total: 120, outdated: 70)],
                advisories: advisories(count: 12)
            )
        )
    }

}
