import Foundation
import XCTest
@testable import TcoderMonitor

/// WS-F 夹具实验室 · 日志与 Git：按账本核对条数/聚类/崩溃锚点，以及多位作者的真实历史。
/// 拆自 ManifestLabFixtureTests.swift，断言与用例一字未改（WS-V）。
final class ManifestLabLogAndGitTests: ManifestLabTestCase {
    // MARK: - 4. 日志

    func testLogCountsClustersAndCrashAnchorsMatchLedger() async throws {
        let logs = try await FileLogAnalyzer()
            .analyze(projectRoot: root, extraLogURLs: [], withinDays: 30)

        print("=== WS-F 夹具 · 日志实测 ===")
        print("文件 \(logs.scannedFiles.count) 行 \(logs.totalLinesScanned)"
            + " ERROR=\(logs.errorCount) WARN=\(logs.warningCount) FATAL=\(logs.fatalCount)"
            + " EXCEPTION=\(logs.exceptionCount) CRASH=\(logs.crashCount) INFO=\(logs.infoLineCount)")
        print("窗口 \(LogRecency.describe(logs.windowStart)) → \(LogRecency.describe(logs.windowEnd))"
            + " 分桶 \(logs.trend.count) 风险 \(logs.overallRisk.rawValue)")
        for bucket in logs.trend {
            print("  桶 \(bucket.date) errors=\(bucket.errors) warn=\(bucket.warnings)"
                + " exceptions=\(bucket.exceptions) crashes=\(bucket.crashes)")
        }
        for cluster in logs.topErrors {
            print("[\(cluster.severity.rawValue)] ×\(cluster.count)  \(cluster.signature)")
            print("    首次 \(cluster.firstSeenDescription) 最近 \(cluster.lastSeenDescription)"
                + " 栈顶 \(cluster.stackTopFrames.prefix(2).joined(separator: " ← "))")
        }
        print("受影响文件 \(logs.affectedFiles)")

        XCTAssertEqual(logs.scannedFiles.count, 2, "只有 Logs/ 下两份日志，不得混进别处的崩溃报告")
        XCTAssertEqual(Set(logs.scannedFiles.map { $0.path.components(separatedBy: "/").last! }),
                       ["error.log", "crash.log"])
        XCTAssertEqual(logs.scannedFiles.first { $0.path.hasSuffix("error.log") }?.role, .error)
        XCTAssertEqual(logs.scannedFiles.first { $0.path.hasSuffix("crash.log") }?.role, .crash)
        XCTAssertEqual(logs.totalLinesScanned, 32, "29 + 3 行")

        XCTAssertEqual(logs.errorCount, 5, "ERROR 前缀行 5 条")
        XCTAssertEqual(logs.warningCount, 3, "WARN 前缀行 3 条")
        XCTAssertEqual(logs.fatalCount, 2, "FATAL 前缀行 2 条")
        XCTAssertEqual(logs.infoLineCount, 4, "INFO 前缀行 4 条")
        // 口径记录：Java 异常头行（`java.lang.NullPointerException: …`）不单独产事件，
        // 而是折进上一条 ERROR 当作堆栈 continuation，所以 exceptionCount 对 Java 日志恒为 0；
        // 异常类名出现在该 ERROR 的签名里，计次正确、不会重复计数。
        // 影响面：LogInsights.swift:13 的「异常」指标与 WeightedHealthScorer.swift:145
        // 的 faults = errorCount + exceptionCount 都拿不到这部分信号。
        XCTAssertEqual(logs.exceptionCount, 0, "Java 异常头行被折进上一条 ERROR，见上方口径说明")
        XCTAssertEqual(logs.crashCount, 3, "crash.log 的 3 个 Fatal error 锚点各算一次崩溃")
        XCTAssertTrue(logs.hasData)
        XCTAssertEqual(logs.overallRisk, .medium, "5 + 0*2 + 3*5 = 20 -> 中风险")

        // 同一异常类、不同 orderId / UUID / 时间戳，必须聚成一条签名并计满 3 次
        let npe = logs.topErrors.filter { $0.signature.contains("NullPointerException") }
        XCTAssertEqual(npe.count, 1, "3 次 NPE 只能有一条签名，实得 \(npe.map(\.signature))")
        let cluster = try require(npe.first, "必须出现 NullPointerException 签名")
        XCTAssertEqual(cluster.count, 3)
        XCTAssertEqual(logs.topErrors.first?.signature, cluster.signature,
                       "计次最多的签名应当排在首位")
        XCTAssertTrue(cluster.signature.contains("orderId=N"),
                      "签名必须把 orderId 归一化，实得 \(cluster.signature)")
        XCTAssertTrue(cluster.signature.contains("user=<uuid>"),
                      "签名必须把 UUID 归一化，实得 \(cluster.signature)")
        XCTAssertFalse(cluster.signature.contains("77001"))
        XCTAssertNotNil(cluster.firstSeen)
        XCTAssertNotNil(cluster.lastSeen)
        XCTAssertTrue(cluster.stackTopFrames.contains { $0.contains("OrderService.java:123") },
                      "栈顶要落在真实抛出点，实得 \(cluster.stackTopFrames)")
        XCTAssertTrue(logs.affectedFiles.keys.contains("OrderService.java"))
        XCTAssertTrue(logs.affectedFiles.keys.contains("PayClient.java"))
        XCTAssertEqual(logs.affectedFiles["OrderService.java"], 3, "三次 NPE 事件的抛出点各计一次")
        if !strictContract {
            print("【口径备案】displayMessage 仍带原始 orderId=\(cluster.displayMessage)"
                + "；exceptionCount 对 Java 堆栈恒 0")
        }

        // Caused by 与 \tat 帧只能归到父事件，不得各自成一条 ERROR
        XCTAssertFalse(logs.topErrors.contains { $0.signature.contains("Caused by") },
                       "Caused by 链不得单独成签名")
        XCTAssertEqual(logs.topErrors.filter { $0.signature.contains("SocketTimeoutException") }.count, 1)

        // 三天的记录要分成三个桶；今天有记录
        XCTAssertEqual(logs.trend.count, 3, "D-2/D-1/D-0 三个自然日")
        XCTAssertEqual(logs.trend.reduce(0) { $0 + $1.errors }, logs.errorCount,
                       "分桶里的 ERROR 之和必须等于总 ERROR 数")
        XCTAssertEqual(logs.trend.reduce(0) { $0 + $1.warnings }, logs.warningCount)
        XCTAssertGreaterThan(logs.todayErrorCount, 0)
    }

    /// 结构化日志（JSON 采集器）里的堆栈帧常以「反斜杠 + t」转义形式落盘，而不是真制表符。
    /// 这条专门看：那种形态的帧被折进父事件之后，栈顶信息还在不在。
    func testStackFramesFromEscapedTabLog() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("acme-escaped-tab-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default
        try fm.createDirectory(at: base.appendingPathComponent("Logs", isDirectory: true),
                               withIntermediateDirectories: true)
        let day = LabDates.stamp("@D0@")
        let body = """
        \(day) 10:00:00,100 ERROR [orders-service] c.a.o.OrderService - 处理订单失败 orderId=88001
        java.lang.NullPointerException: Cannot invoke "com.acme.orders.Price.getTotal()" because "price" is null
        \\tat com.acme.orders.OrderService.pay(OrderService.java:123)
        \\tat com.acme.orders.OrderController.submit(OrderController.java:56)
        """
        try body.write(to: base.appendingPathComponent("Logs/error.log"), atomically: true, encoding: .utf8)

        let logs = try await FileLogAnalyzer().analyze(projectRoot: base, extraLogURLs: [], withinDays: 30)
        let cluster = logs.topErrors.first { $0.signature.contains("NullPointerException") }
        print("=== WS-F 夹具 · 转义制表符堆栈 ===")
        print("ERROR=\(logs.errorCount) EXCEPTION=\(logs.exceptionCount)"
            + " 签名=\(cluster?.signature ?? "无") 计次=\(cluster?.count ?? 0)"
            + " 栈顶=\(cluster?.stackTopFrames ?? [])")
        XCTAssertEqual(logs.errorCount, 1, "转义帧不得再多算一条 ERROR")
        XCTAssertEqual(cluster?.count, 1, "一条异常头 + 两行帧只能聚成一次")
        XCTAssertTrue(logs.affectedFiles.keys.contains("OrderService.java"),
                      "帧里的抛出点要进受影响文件榜，实得 \(logs.affectedFiles)")
    }

    // MARK: - 5. Git

    func testGitInsightsOnRealMultiAuthorHistory() async throws {
        let git = try await ShellGitAnalyzer().analyze(repositoryURL: root)

        print("=== WS-F 夹具 · Git 实测 ===")
        print("仓库=\(git.isRepository) 分支=\(git.branch) HEAD=\(git.headSHA)"
            + " remote=\(git.remoteURL)")
        print("提交 total=\(git.totalCommits) 解析=\(git.commitsAnalyzed) 截断=\(git.historyTruncated)"
            + " 增删=+\(git.totalAdditions)/-\(git.totalDeletions) 触及文件=\(git.filesTouched)")
        print("作者 \(git.authors.count) 位：")
        for author in git.authors {
            print("  \(author.name) <\(author.email)> 提交 \(author.commits)"
                + " +\(author.additions)/-\(author.deletions) 活跃\(author.lastActiveDescription)")
        }
        print("分桶 \(git.commitsPerPeriod.count) 个 日均 \(String(format: "%.2f", git.commitsPerDay))"
            + " 年龄 \(git.projectAgeDays) 天 单点风险 \(git.busFactorRisk.rawValue)"
            + " 模式=\(git.discoveryMode.rawValue) 解析根=\(git.resolvedRepositoryRoot ?? "nil")")

        XCTAssertTrue(git.isRepository)
        XCTAssertEqual(git.branch, "main")
        XCTAssertEqual(git.remoteURL, "https://git.acme.example/orders/acme-orders-lab.git")
        // 钉的是「走那一把缩短尺子」而不是某个宽度：写死 7 会把 `--short=7` 这个旧行为当契约，
        // 而它与覆盖率那一路的 12 位并存过一整天（同一份报告两个串）。
        XCTAssertEqual(git.headSHA.count, CommitIdentity.abbreviatedLength)

        XCTAssertEqual(git.totalCommits, 9)
        XCTAssertEqual(git.authors.count, 3)
        XCTAssertEqual(git.activeAuthorCount, 3)
        XCTAssertEqual(git.topAuthor?.commits, 5, "头号作者恰好 5 次提交")
        XCTAssertEqual(git.topAuthor?.name, "Liang Wei")
        XCTAssertEqual(git.busFactorRisk, .medium, "5/9 = 55.6% -> 中风险")
        XCTAssertEqual(git.filesTouched, tree.files.count,
                       "每个文件恰好提交一次，触及文件数必须等于夹具文件数")
        XCTAssertEqual(git.totalDeletions, 0, "只有新增提交，删除行数必须为 0")
        XCTAssertGreaterThanOrEqual(git.totalAdditions, 1200)
        XCTAssertEqual(git.recentCommits.count, 9)
        XCTAssertEqual(git.projectAgeDays, 2)
        XCTAssertEqual(git.commitsPerDay, 4.5, accuracy: 0.01)
        // 没被截断的仓库里，分桶与逐时/逐日分布必须覆盖全部提交
        XCTAssertEqual(git.commitsPerPeriod.reduce(0) { $0 + $1.commits }, git.totalCommits,
                       "分桶之和必须等于提交总数")
        XCTAssertEqual(git.activityByHour.reduce(0, +), git.totalCommits)
        XCTAssertEqual(git.activityByWeekday.reduce(0, +), git.totalCommits)

        // 窗口报数（WS-B bf71131 修好后的回归护栏）：
        // 夹具是我造的，真值就是 9 次提交、0 个 merge，所以窗口 == 全量、不得标记截断。
        // 这条与 RealRepositoryEvidenceTests 的 Homebrew 用例（50,666 提交 / 窗口 20,000 /
        // truncated = true）正好构成两个方向：小仓库不许虚报截断，大仓库不许把采样当全量。
        XCTAssertEqual(git.commitsAnalyzed, 9, "解析窗口必须报真实条数，不能回落到默认 0")
        XCTAssertEqual(git.totalCommits, git.commitsAnalyzed, "无 merge 的小仓库里两者应当相等")
        XCTAssertFalse(git.historyTruncated, "9 条提交全在窗口内，不得标记截断")

        // 探测回写：夹具目录自己就是仓库根 -> 必须是「所选目录即仓库」，
        // 且解析出的根与 0 跳都如实写进结果，UI 才能告诉用户「我分析的是哪个仓」。
        XCTAssertEqual(git.discoveryMode, .selectedDirectory,
                       "所选目录即仓库时 discoveryMode 必须是 .selectedDirectory")
        XCTAssertEqual(git.resolvedRepositoryRoot, root.path,
                       "解析出的仓库根必须就是夹具根")
        XCTAssertEqual(git.discoveryHops, 0)
        XCTAssertTrue(git.nestedCandidates.isEmpty,
                      "夹具里没有第二层仓库，嵌套候选必须为空，实得 \(git.nestedCandidates.map(\.path))")
    }

    /// 非仓库目录必须抛错，不能返回一个 totalCommits == 0 的「成功」对象冒充证据。
    func testNonRepositoryDirectoryThrowsInsteadOfFakingSuccess() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("acme-not-a-repo-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        do {
            _ = try await ShellGitAnalyzer().analyze(repositoryURL: base)
            XCTFail("非仓库目录必须抛 notGitRepository")
        } catch let error as AnalysisError {
            print("=== WS-F 夹具 · 非仓库 ===\n抛出 \(error)")
            guard case .notGitRepository = error else {
                XCTFail("期望 notGitRepository，实得 \(error)")
                return
            }
        }
    }

}
