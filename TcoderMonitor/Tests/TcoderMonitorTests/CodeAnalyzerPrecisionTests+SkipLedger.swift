/// OWNER: WS-X3 TestSplit —— 自 CodeAnalyzerPrecisionTests.swift 拆出，跳过台账逐条归因、清零对账与行/文件上限上报。用例本体未改，只是搬了家。
import Foundation
import XCTest
@testable import TcoderMonitor

extension CodeAnalyzerTests {

    /// 夹具根里一次摆齐七种剔除理由，台账必须逐条对上，且「纳入 + 剔除 == 遍历到的文件数」。
    /// 台账夹具：一个纳入文件 + 七种剔除原因各一条（含一棵被剔除目录与其嵌套层）。
    /// 三条用例共用同一份形状，只是断言的侧面不同（WS-X3 拆分：原
    /// `testSkipLedgerAttributesEveryRejectedEntry` 58 行 / CC 21，CC 全部来自
    /// `buckets[x]?.files ?? 0` 这类可选链——每条在复杂度引擎眼里都是一个分支。
    /// 取数收进 `files(_:_:)` / `lines(_:_:)` 之后判据一个字没松。）
    private func makeSkipLedgerFixture() throws -> URL {
        let root = try makeFixtureRoot()
        _ = try write("let kept = 1\n", to: "Keep.swift", in: root)
        _ = try write("no extension at all\n", to: "LICENSE", in: root)
        _ = try write("plain prose\n", to: "notes.txt", in: root)
        _ = try write("fake image bytes\n", to: "logo.png", in: root)
        _ = try write("let hidden = 1\n", to: ".secret.swift", in: root)
        _ = try write(String(repeating: "let line = 1\n", count: 300), to: "huge.swift", in: root)
        _ = try write("let vendored = 1\n", to: "vendor/Pkg.swift", in: root)
        _ = try write("let deep = 1\nlet two = 2\n", to: "vendor/nested/Deep.swift", in: root)
        let link = root.appendingPathComponent("link.swift")
        try? fm.removeItem(at: link)
        try fm.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("Keep.swift"))
        return root
    }

    private func skipLedgerOptions() -> ScanOptions {
        options(maxFileBytes: 2_000, skipDirectories: ["vendor"],
                binaryExtensions: ["png"], includeHidden: false)
    }

    private func files(_ ledger: SourceSkipLedger, _ reason: SourceSkipReason) -> Int {
        ledger.buckets[reason]?.files ?? 0
    }

    private func lines(_ ledger: SourceSkipLedger, _ reason: SourceSkipReason) -> Int {
        ledger.buckets[reason]?.lines ?? 0
    }

    func testSkipLedgerAttributesEveryRejectedEntry() async throws {
        let root = try makeSkipLedgerFixture()
        defer { try? fm.removeItem(at: root) }
        // —— 正常扫描（不审计）：零额外读盘，只记条数与字节
        let plain = await SourceTreeScanner(options: skipLedgerOptions()).scan(root: root)
        XCTAssertEqual(plain.scannedFileCount, 1, "只有 Keep.swift 应被纳入：\(plain.files.map(\.relativePath))")
        XCTAssertEqual(plain.skippedFileCount + plain.scannedFileCount, plain.visitedFileCount,
                       "visited 必须等于纳入 + 剔除")
        let ledger = plain.skipLedger
        XCTAssertEqual(files(ledger, .missingExtension), 1, "LICENSE 无后缀")
        XCTAssertEqual(files(ledger, .unsupportedExtension), 1, "notes.txt 语言表里没有")
        XCTAssertEqual(files(ledger, .binaryExtension), 1, "logo.png 命中二进制后缀")
        XCTAssertEqual(files(ledger, .oversize), 1, "huge.swift 超过 maxFileBytes")
        XCTAssertEqual(files(ledger, .hiddenEntry), 1, ".secret.swift 是隐藏项")
        XCTAssertEqual(files(ledger, .symbolicLink), 1, "link.swift 是软链接")
        XCTAssertEqual(files(ledger, .skippedDirectory), 1, "vendor 整棵被剔除（根因只记一次）")
        XCTAssertEqual(files(ledger, .excludedDirectoryNested), 0,
                       "正常扫描掐了子树，vendor/nested 这一层根本不该被看到")
        XCTAssertEqual(files(ledger, .excludedDirectoryContent), 0,
                       "正常扫描对被剔除目录掐子树，子树里的文件不该被逐个看到")
        XCTAssertEqual(ledger.skippedFileTotal, 7, "台账覆盖的条目数（含 visited 之外的隐藏/软链接/目录）")
        XCTAssertFalse(ledger.cappedRemaining, "maxFiles 未命中，不得谎报截断")
        XCTAssertEqual(ledger.buckets[.binaryExtension]?.rules["png"], 1, "规则项要落到具体后缀上")
    }

    func testSkipLedgerAuditExpandsExcludedDirectoryContent() async throws {
        let root = try makeSkipLedgerFixture()
        defer { try? fm.removeItem(at: root) }
        // —— 审计模式：额外数出被剔除文件的真实行数，把「少掉的行数」完整解释掉
        let audited = await SourceTreeScanner(options: skipLedgerOptions(),
                                              auditLineBudget: SourceSkipLedger.defaultAuditBudget).scan(root: root)
        let audit = audited.skipLedger
        XCTAssertEqual(files(audit, .excludedDirectoryContent), 2, "审计模式要展开被剔除目录逐文件归因")
        XCTAssertEqual(lines(audit, .excludedDirectoryContent), 3,
                       "vendor/Pkg.swift 1 行 + vendor/nested/Deep.swift 2 行")
        XCTAssertEqual(files(audit, .excludedDirectoryNested), 1, "vendor/nested 记成嵌套目录，根因仍是 vendor")
        XCTAssertEqual(files(audit, .skippedDirectory), 1, "根因条数不能被嵌套目录稀释")
        XCTAssertEqual(lines(audit, .oversize), 300, "超限文件的 300 行要能对上")
        XCTAssertEqual(lines(audit, .hiddenEntry), 0, "隐藏项一律不读内容（可能是 .env 之类）")
        XCTAssertFalse(audit.linesBudgetExhausted, "夹具远小于预算，不得报预算耗尽")
        XCTAssertEqual(audit.skippedLineTotal,
                       (audit.buckets.values.map(\.lines).reduce(0, +)), "台账自洽")
        XCTAssertGreaterThan(audit.auditedBytes, 0)
    }

    func testAuditModeLeavesTheScannedSetUnchanged() async throws {
        let root = try makeSkipLedgerFixture()
        defer { try? fm.removeItem(at: root) }
        // 同一份夹具：审计与否，纳入集合必须完全一致（审计只多加统计，不改判定）
        let plain = await SourceTreeScanner(options: skipLedgerOptions()).scan(root: root)
        let audited = await SourceTreeScanner(options: skipLedgerOptions(),
                                             auditLineBudget: SourceSkipLedger.defaultAuditBudget).scan(root: root)
        XCTAssertEqual(Set(audited.files.map(\.relativePath)), Set(plain.files.map(\.relativePath)))
    }

    /// 「比 `find` 少 22%」这类质疑的唯一正经答法：纳入行 + 各条原因剔除行 == 磁盘真实行，逐行对上。
    func testSkipClearingReconcilesEveryLine() async throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        _ = try write("let kept = 1\nlet more = 2\n", to: "Keep.swift", in: root)                       // 2 行，纳入
        _ = try write("puts 1\nputs 2\nputs 3\n", to: "vendor/Deep.rb", in: root)                     // 3 行，排除目录
        _ = try write("project(x)\ninstall(FILES a)\n", to: "sub/CMakeLists.cmake", in: root)         // 2 行，后缀未收录
        _ = try write("MIT\nLicense\n", to: "LICENSE", in: root)                                       // 2 行，无后缀
        let symlink = root.appendingPathComponent("alias.swift")
        try? fm.removeItem(at: symlink)
        try fm.createSymbolicLink(at: symlink, withDestinationURL: root.appendingPathComponent("Keep.swift"))
        // 软链接刻意不跟随：它进台账但没有行数，正是「行数不适用」与「0 行」必须区分的那一类

        let opts = options(skipDirectories: ["vendor"], binaryExtensions: ["png"])
        let outcome = try await FileSystemCodeAnalyzer().analyzeWithCoverage(root: root, options: opts)
        XCTAssertEqual(outcome.metrics.totalLines, 2, "只有 Keep.swift 进入指标")

        let ledger = try await FileSystemCodeAnalyzer()
            .skipLedger(root: root, options: opts, countSkippedLines: true)
        XCTAssertTrue(ledger.linesCounted, "审计模式必须声明自己数过行数")
        XCTAssertEqual(ledger.skippedLineTotal, 7, "3 + 2 + 2 行")
        let diskLines = outcome.metrics.totalLines + ledger.skippedLineTotal
        XCTAssertEqual(diskLines, 9, "纳入 + 剔除 == 磁盘真实行数，一行不差")

        let clearing = ledger.clearing(linesCounted: true)
        XCTAssertEqual(clearing.count, ledger.buckets.count, "每条生效过的原因都要出一行")
        XCTAssertTrue(clearing.contains { $0.contains("排除目录里的文件") && $0.contains("3 行")
            && $0.contains("vendor 3 行") }, "\(clearing)")
        XCTAssertTrue(clearing.contains { $0.contains("语言表未收录的后缀") && $0.contains("cmake") }, "\(clearing)")
        XCTAssertTrue(clearing.contains { $0.contains("无后缀文件") && $0.contains("（无后缀） 2 行") }, "\(clearing)")

        // 非审计模式：行数没数过就必须如实说没数，不许显示 0 行。
        let plain = try await FileSystemCodeAnalyzer().skipLedger(root: root, options: opts)
        XCTAssertFalse(plain.linesCounted)
        let plainLines = plain.clearing(linesCounted: false)
        XCTAssertTrue(plainLines.allSatisfy { !$0.contains(" 0 行") && !$0.contains("· 0 行") },
                      "未审计时不得出现「0 行」这种把缺数据当零的写法：\(plainLines)")
        XCTAssertTrue(plainLines.contains { $0.contains("行数未统计") }, "没数过的桶必须明说：\(plainLines)")
        // 审计模式下也一样：目录/符号链接/隐藏项这些从不读内容的桶，不得显示「0 行」
        let audited = try await FileSystemCodeAnalyzer()
            .skipLedger(root: root, options: opts, countSkippedLines: true)
        let auditedLines = audited.clearing(linesCounted: true)
        XCTAssertTrue(auditedLines.contains { $0.contains("符号链接") && $0.contains("行数不适用") },
                      "\(auditedLines)")
        XCTAssertFalse(auditedLines.contains { $0.contains("符号链接") && $0.contains(" 0 行") },
                       "\(auditedLines)")
    }

    /// 被 20 万行/文件上限切过的文件必须留痕，否则 `totalLines` 看起来像全量。
    func testLineCapTruncationIsReported() async throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        _ = try write(String(repeating: "1\n", count: 200_001), to: "huge.swift", in: root)
        _ = try write("let ok = 1\n", to: "normal.swift", in: root)

        let file = try XCTUnwrap(classify(root.appendingPathComponent("huge.swift"), root: root))
        XCTAssertEqual(file.totalLineCount, 200_000, "只保留前 20 万行")
        XCTAssertTrue(file.lineCountTruncated, "必须留痕：这个文件被行数上限切过")
        XCTAssertFalse(try XCTUnwrap(classify(root.appendingPathComponent("normal.swift"), root: root)).lineCountTruncated,
                       "正常文件不得被标成截断")

        let outcome = try await FileSystemCodeAnalyzer().analyzeWithCoverage(root: root, options: options())
        XCTAssertEqual(outcome.coverage.lineTruncatedFileCount, 1)
        XCTAssertTrue(outcome.coverage.isPartial, "有上限生效过 ⇒ 这是部分测量")
        XCTAssertTrue(outcome.coverage.limitationSummary.contains { $0.contains("20 万行") },
                      "限制说明要带真实数字：\(outcome.coverage.limitationSummary)")
    }

    /// `maxFiles` 生效后，覆盖率事实必须能从 `analyze` 的返回值里拿到（原先四个字段全被丢弃）。
    func testFileCapCoverageIsExposed() async throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        for index in 0..<6 { _ = try write("let v\(index) = 1\n", to: "f\(index).swift", in: root) }
        var opts = options(maxFiles: 3)
        let outcome = try await FileSystemCodeAnalyzer().analyzeWithCoverage(root: root, options: opts)
        XCTAssertTrue(outcome.coverage.truncatedByMaxFiles, "6 个文件、上限 3，必须报截断")
        XCTAssertEqual(outcome.coverage.includedFileCount, 3)
        XCTAssertEqual(outcome.metrics.totalFiles, 3, "指标本身只统计进入的部分")
        XCTAssertTrue(outcome.coverage.isPartial)
        XCTAssertTrue(outcome.coverage.limitationSummary.contains { $0.contains("上限") },
                      "\(outcome.coverage.limitationSummary)")
        // 承接字段（P7-C 3-2）：光算出来不发出去等于没算 —— 视图读的是 `metrics`。
        XCTAssertEqual(outcome.metrics.scanLimitations?.count, outcome.coverage.limitationSummary.count,
                       "边界条数没随指标一起交出去，代码规模页就挂不出提示")
        XCTAssertTrue(outcome.metrics.scanLimitations?.contains { $0.contains("上限") } == true)
        opts.maxFiles = 100
        let whole = try await FileSystemCodeAnalyzer().analyzeWithCoverage(root: root, options: opts)
        XCTAssertFalse(whole.coverage.truncatedByMaxFiles)
        XCTAssertFalse(whole.coverage.isPartial, "一个上限都没碰到时不得谎称部分测量")
        XCTAssertTrue(whole.coverage.limitationSummary.isEmpty, "\(whole.coverage.limitationSummary)")
        XCTAssertNil(whole.metrics.scanLimitations, "没有被切过却带边界字段，提示条会常驻，等于把全量说成部分")
    }

    /// 读不动的目录必须自己报名（F12 的另一半）。`enumerator` 的 `errorHandler`
    /// 原本一律返回 `true`，于是"这个子树我们根本没看过"与"这个子树里没有源码"
    /// 在结果里长得一模一样 —— 缺陷不在渲染层，在"谁替『读不到』说了句话"。
    func testUnreadableDirectoryIsReportedAsIncompleteScanSurface() async throws {
        let root = try makeFixtureRoot()
        let locked = root.appendingPathComponent("locked")
        defer {
            // 权限不还回去，`removeItem` 就删不掉这棵夹具；残骸会喂下一轮扫描当真实数据。
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? fm.removeItem(at: root)
        }
        _ = try write("let a = 1\n", to: "Keep.swift", in: root)
        _ = try write("let b = 2\n", to: "locked/Hidden.swift", in: root)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)

        let outcome = try await FileSystemCodeAnalyzer().analyzeWithCoverage(root: root, options: options())
        if outcome.coverage.unreadableDirectoryCount == 0 {
            throw XCTSkip("本机允许枚举 0o000 目录（例如以 root 跑测试），此时计数为 0 是正确行为")
        }
        XCTAssertGreaterThanOrEqual(outcome.coverage.unreadableDirectoryCount, 1)
        XCTAssertTrue(outcome.coverage.isPartial, "有子树压根没看过，这份数字不许当全量")
        XCTAssertTrue(outcome.coverage.limitationSummary.contains { $0.contains("读不动") },
                      "\(outcome.coverage.limitationSummary)")
        XCTAssertEqual(outcome.metrics.totalFiles, 1, "被挡住的那份源码不该算成扫到过")
        XCTAssertTrue(outcome.metrics.scanLimitations?.contains { $0.contains("读不动") } == true,
                      "这一维必须一路带到界面上，不许停在 coverage 结构里")
    }

}
