import Foundation

/// Built-in "Tcoder 示例项目" sample project so the app is demonstrable before pointing at a
/// real repository. Chief-engineer owned; numbers mirror the product spec.
/// Every demo report is flagged `isDemo` and badged in the UI.
@MainActor
enum DemoData {
    static func makeProject(in store: ProjectStore) -> MonitoredProject {
        if let existing = store.projects.first(where: { $0.isDemo }) { return existing }
        return store.add(path: AppState.demoProjectPath, name: "Tcoder 示例项目", isDemo: true)
    }

    static func install(into store: ProjectStore, project: MonitoredProject) {
        var report = ProjectReport(project: project)
        report.code = codeMetrics
        report.git = gitInsights
        report.logs = logSummary
        report.dependencies = dependencyReport
        report.health = WeightedHealthScorer().score(
            HealthInputs(
                code: report.code,
                git: report.git,
                logs: report.logs,
                dependencies: report.dependencies,
                previousScore: 81
            )
        )
        report.generatedAt = Date()
        store.upsertReport(report)
        store.recordScore(report.health?.overall ?? 0, for: project.id, projectName: project.name)
    }

    // MARK: Code

    private static let codeMetrics: CodeMetrics = {
        var metrics = CodeMetrics()
        metrics.totalFiles = 2_351
        metrics.totalLines = 224_900
        metrics.blankLines = 27_830
        metrics.commentLines = 14_640
        metrics.codeLines = 182_430
        metrics.durationMs = 4_120
        metrics.languages = [
            LanguageShare(language: "Swift", fileCount: 691, lineCount: 82_094, share: 0.45),
            LanguageShare(language: "Java", fileCount: 974, lineCount: 63_850, share: 0.35),
            LanguageShare(language: "TypeScript", fileCount: 686, lineCount: 36_486, share: 0.20),
        ]
        metrics.todoCount = 47
        metrics.fixmeCount = 12
        metrics.hugeFiles = [
            FileHotspot(path: "server/src/main/java/com/tcoder/service/UserService.java", lineCount: 4_320, risk: .high, suggestion: "建议拆分：按认证、资料、权限拆为 3 个服务"),
            FileHotspot(path: "server/src/main/java/com/tcoder/service/OrderService.java", lineCount: 2_980, risk: .medium, suggestion: "建议拆分：状态机可独立为 OrderStateMachine"),
            FileHotspot(path: "app/Tcoder/Features/Chat/ChatViewModel.swift", lineCount: 1_860, risk: .medium, suggestion: "建议拆分子视图模型，分离网络与渲染"),
            FileHotspot(path: "web/src/pages/Console/index.tsx", lineCount: 1_240, risk: .low, suggestion: "可按路由拆包"),
        ]
        metrics.topComplexFunctions = [
            FunctionHotspot(name: "processTask()", filePath: "server/src/main/java/com/tcoder/worker/TaskDispatcher.java", startLine: 214, lineCount: 386, cyclomaticComplexity: 38, parameterCount: 7, risk: .high),
            FunctionHotspot(name: "resolvePermission()", filePath: "server/src/main/java/com/tcoder/security/AccessControl.java", startLine: 88, lineCount: 142, cyclomaticComplexity: 24, parameterCount: 4, risk: .high),
            FunctionHotspot(name: "syncConversation()", filePath: "app/Tcoder/Services/SyncService.swift", startLine: 320, lineCount: 198, cyclomaticComplexity: 19, parameterCount: 5, risk: .medium),
            FunctionHotspot(name: "handleUpload()", filePath: "server/src/main/java/com/tcoder/file/UploadController.java", startLine: 56, lineCount: 121, cyclomaticComplexity: 17, parameterCount: 6, risk: .medium),
            FunctionHotspot(name: "buildReport()", filePath: "web/src/services/report.ts", startLine: 41, lineCount: 96, cyclomaticComplexity: 14, parameterCount: 3, risk: .low),
        ]
        metrics.longFunctions = 15
        metrics.averageFunctionLength = 23
        metrics.duplicationRatio = 0.125
        metrics.duplicatedBlocks = [
            DuplicatedBlock(occurrences: [
                DuplicatedFragment(path: "server/src/main/java/com/tcoder/service/UserService.java", startLine: 812),
                DuplicatedFragment(path: "server/src/main/java/com/tcoder/service/OrderService.java", startLine: 404),
            ], lineCount: 62, similarity: 0.97),
            DuplicatedBlock(occurrences: [
                DuplicatedFragment(path: "app/Tcoder/Features/Chat/ChatViewModel.swift", startLine: 220),
                DuplicatedFragment(path: "app/Tcoder/Features/Voice/VoiceViewModel.swift", startLine: 168),
            ], lineCount: 41, similarity: 0.92),
        ]
        metrics.largestFileLineCount = 4_320
        metrics.overallRisk = .medium
        return metrics
    }()

    // MARK: Git

    private static func daysAgo(_ days: Double, hour: Int = 14) -> Date {
        let base = Calendar.current.date(byAdding: .day, value: Int(-days), to: Date()) ?? Date()
        return Calendar.current.date(bySettingHour: hour, minute: 37, second: 0, of: base) ?? base
    }

    private static func hourCurve(_ peaks: [Int: Int]) -> [Int] {
        (0..<24).map { peaks[$0] ?? 0 }
    }

    private static let gitInsights: GitInsights = {
        var insights = GitInsights()
        insights.isRepository = true
        insights.branch = "main"
        insights.headSHA = "8f3c1a9"
        insights.remoteURL = "git@git.example.dev:tcoder/tcoder-core.git"
        insights.totalCommits = 1_842
        insights.firstCommitAt = daysAgo(143)
        insights.lastCommitAt = Date().addingTimeInterval(-2 * 3_600)
        insights.projectAgeDays = 143
        insights.totalAdditions = 486_220
        insights.totalDeletions = 303_790
        insights.filesTouched = 2_351

        insights.authors = [
            AuthorStats(name: "张三", email: "zhangsan@example.dev", commits: 342, additions: 45_230, deletions: 12_330, filesTouched: 812, firstCommitAt: daysAgo(143), lastCommitAt: Date().addingTimeInterval(-2 * 3_600), activityByHour: hourCurve([0: 8, 9: 41, 10: 62, 11: 44, 13: 22, 14: 51, 15: 38, 16: 20, 20: 12, 21: 6]), topDirectories: ["server": 188, "app": 96, "web": 58]),
            AuthorStats(name: "李四", email: "lisi@example.dev", commits: 120, additions: 10_500, deletions: 3_240, filesTouched: 296, firstCommitAt: daysAgo(128), lastCommitAt: daysAgo(1), activityByHour: hourCurve([0: 3, 10: 18, 11: 24, 15: 21, 16: 17, 17: 9]), topDirectories: ["web": 74, "app": 32, "server": 14]),
            AuthorStats(name: "王五", email: "wangwu@example.dev", commits: 486, additions: 61_840, deletions: 24_190, filesTouched: 1_024, firstCommitAt: daysAgo(140), lastCommitAt: Date().addingTimeInterval(-7 * 3_600), activityByHour: hourCurve([0: 14, 9: 52, 10: 88, 11: 71, 14: 63, 15: 57, 21: 41]), topDirectories: ["app": 262, "server": 148, "shared": 76]),
            AuthorStats(name: "赵六", email: "zhaoliu@example.dev", commits: 402, additions: 39_770, deletions: 18_400, filesTouched: 688, firstCommitAt: daysAgo(118), lastCommitAt: daysAgo(0, hour: 9), activityByHour: hourCurve([0: 9, 10: 44, 11: 58, 16: 62, 17: 48]), topDirectories: ["server": 214, "infra": 96, "docs": 92]),
            AuthorStats(name: "陈七", email: "chenqi@example.dev", commits: 492, additions: 52_310, deletions: 21_090, filesTouched: 742, firstCommitAt: daysAgo(96), lastCommitAt: Date().addingTimeInterval(-4 * 3_600), activityByHour: hourCurve([0: 11, 13: 47, 14: 66, 15: 52, 20: 38, 21: 27]), topDirectories: ["web": 318, "app": 118, "shared": 106]),
        ]

        insights.commitsPerPeriod = (0..<12).map { index in
            CommitBucket(
                date: daysAgo(Double((11 - index) * 7) + 1),
                commits: 68 + (index.isMultiple(of: 3) ? 26 : 0) - index,
                additions: 18_400 - index * 640,
                deletions: 9_100 - index * 320,
                granularity: .week
            )
        }
        insights.activityByHour = [8, 4, 2, 1, 0, 0, 1, 3, 22, 96, 148, 121, 44, 88, 132, 118, 92, 61, 38, 27, 44, 58, 36, 14]
        insights.activityByWeekday = [212, 306, 318, 297, 268, 92, 49]
        insights.recentCommits = [
            CommitRecord(sha: "8f3c1a9", author: "张三", email: "zhangsan@example.dev", date: Date().addingTimeInterval(-2 * 3_600), subject: "fix(worker): 修复任务重试时线程池未回收", filesChanged: 6, additions: 214, deletions: 88),
            CommitRecord(sha: "b21d4ef", author: "陈七", email: "chenqi@example.dev", date: Date().addingTimeInterval(-6 * 3_600), subject: "feat(console): 指标看板支持按周聚合", filesChanged: 11, additions: 642, deletions: 190),
            CommitRecord(sha: "4a7e0c1", author: "王五", email: "wangwu@example.dev", date: daysAgo(1), subject: "refactor(sync): 抽出 SyncCoordinator，降低圈复杂度", filesChanged: 9, additions: 388, deletions: 412),
            CommitRecord(sha: "e93b77a", author: "赵六", email: "zhaoliu@example.dev", date: daysAgo(1, hour: 21), subject: "chore(deps): 升级 spring-boot 到 3.3.4", filesChanged: 3, additions: 42, deletions: 39),
            CommitRecord(sha: "71cc05b", author: "李四", email: "lisi@example.dev", date: daysAgo(2), subject: "test(user): 补齐 UserService 权限分支单测", filesChanged: 4, additions: 306, deletions: 12),
            CommitRecord(sha: "0d5fa22", author: "张三", email: "zhangsan@example.dev", date: daysAgo(2, hour: 10), subject: "perf(chat): 首屏渲染减少 1 次全量解码", filesChanged: 5, additions: 128, deletions: 233),
        ]
        return insights
    }()

    // MARK: Logs

    private static let logSummary: LogSummary = {
        var summary = LogSummary()
        summary.windowStart = daysAgo(1)
        summary.windowEnd = Date()
        summary.errorCount = 124
        summary.exceptionCount = 124
        summary.warningCount = 542
        summary.crashCount = 23
        summary.fatalCount = 9
        summary.infoLineCount = 48_920
        summary.totalLinesScanned = 62_480
        summary.scannedFiles = [
            ScannedLogFile(path: "Logs/error.log", sizeBytes: 8_421_300, lineCount: 41_220, modifiedAt: Date().addingTimeInterval(-600), role: .error),
            ScannedLogFile(path: "Logs/crash.log", sizeBytes: 1_204_800, lineCount: 8_930, modifiedAt: Date().addingTimeInterval(-1_800), role: .crash),
            ScannedLogFile(path: "Logs/application.log", sizeBytes: 22_480_100, lineCount: 12_330, modifiedAt: Date().addingTimeInterval(-120), role: .application),
        ]
        summary.topErrors = [
            ErrorCluster(signature: "NullPointerException", displayMessage: "java.lang.NullPointerException", count: 34, firstSeen: daysAgo(1), lastSeen: Date().addingTimeInterval(-600), sourceFile: "Logs/error.log", severity: .exception, sampleLines: ["at com.tcoder.service.UserService.bindAvatar(UserService.java:1904)"], stackTopFrames: ["UserService.bindAvatar:1904", "ProfileController.update:212"]),
            ErrorCluster(signature: "SQLException", displayMessage: "java.sql.SQLTransientConnectionException: HikariPool-1 - Connection is not available", count: 27, firstSeen: daysAgo(3), lastSeen: Date().addingTimeInterval(-1_800), sourceFile: "Logs/error.log", severity: .error, sampleLines: ["request timed out after 30000ms"], stackTopFrames: ["HikariPool.getConnection:217"]),
            ErrorCluster(signature: "EXC_BAD_ACCESS", displayMessage: "EXC_BAD_ACCESS (SIGSEGV) — ChatViewModel.deallocate", count: 21, firstSeen: daysAgo(2), lastSeen: Date().addingTimeInterval(-3_600), sourceFile: "Logs/crash.log", severity: .crash, sampleLines: ["Thread 0 Crashed :: Tcoder + 0x1a4f22"], stackTopFrames: ["Tcoder!ChatViewModel.deallocate + 34"]),
            ErrorCluster(signature: "TimeoutError", displayMessage: "TypeError: fetch failed — upstream timeout after 10s", count: 18, firstSeen: daysAgo(5), lastSeen: Date().addingTimeInterval(-7_200), sourceFile: "Logs/application.log", severity: .error, sampleLines: ["POST /api/v1/generate 504 in 10021ms"], stackTopFrames: []),
            ErrorCluster(signature: "Unauthorized", displayMessage: "io.jsonwebtoken.ExpiredJwtException: JWT expired", count: 12, firstSeen: daysAgo(6), lastSeen: Date().addingTimeInterval(-9 * 3_600), sourceFile: "Logs/error.log", severity: .exception, sampleLines: ["token exp 1758211200 < now"], stackTopFrames: []),
        ]
        summary.trend = (0..<7).map { index in
            LogBucket(
                date: daysAgo(Double(6 - index)),
                errors: [18, 24, 12, 31, 9, 22, 124][index],
                warnings: [88, 120, 64, 142, 51, 96, 542][index],
                exceptions: [12, 19, 8, 26, 6, 14, 124][index],
                crashes: [2, 4, 1, 5, 0, 3, 23][index]
            )
        }
        summary.affectedFiles = [
            "UserService.java": 41, "TaskDispatcher.java": 28, "ChatViewModel.swift": 21,
            "UploadController.java": 14, "report.ts": 7,
        ]
        return summary
    }()

    // MARK: Dependencies

    private static let dependencyReport: DependencyReport = {
        var report = DependencyReport()
        report.networkLookupPerformed = false
        report.networkLookupNote = "示例数据来自内置快照"
        report.ecosystems = [
            EcosystemReport(
                ecosystem: .npm,
                manifestPath: "web/package.json",
                lockfileName: "package-lock.json",
                dependencies: [
                    DependencyRecord(name: "react", version: "18.3.1", ecosystem: .npm, scope: .runtime, manifestPath: "web/package.json", latestKnownVersion: "18.3.1", versionCheckSource: .bundledSnapshot, knownVulnerabilities: []),
                    DependencyRecord(name: "react-dom", version: "18.3.1", ecosystem: .npm, scope: .runtime, manifestPath: "web/package.json", latestKnownVersion: "18.3.1", versionCheckSource: .bundledSnapshot, knownVulnerabilities: []),
                    DependencyRecord(name: "vite", version: "5.2.11", ecosystem: .npm, scope: .dev, manifestPath: "web/package.json", latestKnownVersion: "5.4.8", versionCheckSource: .bundledSnapshot, knownVulnerabilities: []),
                    DependencyRecord(name: "lodash", version: "4.17.15", ecosystem: .npm, scope: .runtime, manifestPath: "web/package.json", latestKnownVersion: "4.17.21", versionCheckSource: .bundledSnapshot, knownVulnerabilities: ["GHSA-35jh-r3h4-6jhm", "CVE-2020-8203", "CVE-2021-23337"]),
                    DependencyRecord(name: "axios", version: "1.6.8", ecosystem: .npm, scope: .runtime, manifestPath: "web/package.json", latestKnownVersion: "1.7.7", versionCheckSource: .bundledSnapshot, knownVulnerabilities: []),
                    DependencyRecord(name: "typescript", version: "5.4.5", ecosystem: .npm, scope: .dev, manifestPath: "web/package.json", latestKnownVersion: "5.6.2", versionCheckSource: .bundledSnapshot, knownVulnerabilities: []),
                ],
                frameworkMarkers: ["React", "Vite"]
            ),
            EcosystemReport(
                ecosystem: .maven,
                manifestPath: "server/pom.xml",
                lockfileName: nil,
                dependencies: [
                    DependencyRecord(name: "org.springframework.boot:spring-boot-starter-web", version: "3.3.4", ecosystem: .maven, scope: .runtime, manifestPath: "server/pom.xml", latestKnownVersion: "3.3.4", versionCheckSource: .bundledSnapshot, knownVulnerabilities: []),
                    DependencyRecord(name: "org.mybatis.spring.boot:mybatis-spring-boot-starter", version: "3.0.3", ecosystem: .maven, scope: .runtime, manifestPath: "server/pom.xml", latestKnownVersion: "3.0.4", versionCheckSource: .bundledSnapshot, knownVulnerabilities: []),
                    DependencyRecord(name: "io.jsonwebtoken:jjwt", version: "0.9.1", ecosystem: .maven, scope: .runtime, manifestPath: "server/pom.xml", latestKnownVersion: "0.12.6", versionCheckSource: .bundledSnapshot, knownVulnerabilities: ["CVE-2024-31638"]),
                    DependencyRecord(name: "com.alibaba:fastjson", version: "1.2.68", ecosystem: .maven, scope: .runtime, manifestPath: "server/pom.xml", latestKnownVersion: "2.0.52", versionCheckSource: .bundledSnapshot, knownVulnerabilities: ["CVE-2022-25845"]),
                    DependencyRecord(name: "org.projectlombok:lombok", version: "1.18.30", ecosystem: .maven, scope: .dev, manifestPath: "server/pom.xml", latestKnownVersion: "1.18.34", versionCheckSource: .bundledSnapshot, knownVulnerabilities: []),
                ],
                frameworkMarkers: ["Spring Boot", "MyBatis"]
            ),
            EcosystemReport(
                ecosystem: .swiftPM,
                manifestPath: "app/Package.swift",
                lockfileName: "Package.resolved",
                dependencies: [
                    DependencyRecord(name: "SwiftUI", version: "系统框架", ecosystem: .swiftPM, scope: .platform, manifestPath: "app/Package.swift", latestKnownVersion: nil, versionCheckSource: .none, knownVulnerabilities: []),
                    DependencyRecord(name: "GRDB.swift", version: "6.24.3", ecosystem: .swiftPM, scope: .runtime, manifestPath: "app/Package.swift", latestKnownVersion: "6.29.0", versionCheckSource: .bundledSnapshot, knownVulnerabilities: []),
                    DependencyRecord(name: "swift-log", version: "1.5.4", ecosystem: .swiftPM, scope: .runtime, manifestPath: "app/Package.swift", latestKnownVersion: "1.5.4", versionCheckSource: .bundledSnapshot, knownVulnerabilities: []),
                ],
                frameworkMarkers: ["SwiftUI", "GRDB"]
            ),
        ]
        report.advisories = [
            SecurityAdvisory(id: "GHSA-35jh-r3h4-6jhm", aliases: ["CVE-2020-8203"], summary: "lodash 原型污染导致代码注入", details: "影响 <4.17.21，升级到 4.17.21 修复", severity: .high, cvssScore: 7.4, affectedPackages: ["lodash"], ecosystem: .npm, publishedAt: daysAgo(40), source: "内置快照"),
            SecurityAdvisory(id: "CVE-2022-25845", aliases: [], summary: "fastjson 自动类型反序列化 RCE", details: "影响 1.2.83 之前版本，建议迁移到 fastjson2", severity: .critical, cvssScore: 9.8, affectedPackages: ["com.alibaba:fastjson"], ecosystem: .maven, publishedAt: daysAgo(120), source: "内置快照"),
            SecurityAdvisory(id: "CVE-2024-31638", aliases: [], summary: "jjwt 未校验密钥长度导致签名绕过", details: "0.9.1 使用了弱默认 HMAC 密钥处理", severity: .medium, cvssScore: 6.1, affectedPackages: ["io.jsonwebtoken:jjwt"], ecosystem: .maven, publishedAt: daysAgo(200), source: "内置快照"),
        ]
        return report
    }()
}
