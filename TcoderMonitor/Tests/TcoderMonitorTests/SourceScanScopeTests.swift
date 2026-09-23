import Foundation
import XCTest
@testable import TcoderMonitor

/// OWNER: WS-R6 文件角色与扫描范围 —— `CodeAnalyzerTests` 的续篇（RD-14/15 的夹具侧证据）。
///
/// 走 `extension CodeAnalyzerTests` 只为一件事：夹具根的归一化（`/var → /private/var`）
/// 与写文件的辅助在本仓**只允许有一份**（`makeFixtureRoot` 的注释就是这条理由），
/// 复制一份就会在下一次改动里分叉。
///
/// 独立真值 = 下面 `roleTruth` / `lineTruth` 两张**手写**表（与 `.scratch/r6/make_fixture.sh`
/// 打印的分组同源；那份 shell 侧真值用来对 CLI 读数，这张表用来对 in-process 读数）。
extension CodeAnalyzerTests {

    /// 应进入统计的文件 → (角色, 行数)。少一个文件、多一个文件、角色判错都会红。
    static let roleTruth: [String: (role: SourceFileRole, lines: Int)] = [
        "src/App.swift": (.production, 3),
        "src/PaymentService.java": (.production, 6),
        "src/LegacyHelper.swift": (.production, 4),
        "src/Inner.swift": (.production, 3),
        "nested/inner-repo/src/InnerRepo.swift": (.production, 3),
        "spec/user_spec.rb": (.test, 3),
        "__tests__/login.test.js": (.test, 3),
        "e2e/checkout.spec.ts": (.test, 3),
        "it/ping.py": (.test, 3),
        "src/test_upload.py": (.test, 3),
        "tests/RunnerTests.swift": (.test, 3),
        "qa/manual/checks.swift": (.test, 3),
        "Generated/Widget.pb.swift": (.generated, 4),
        "gen/api.pb.go": (.generated, 4),
        "src/db/migrations/0001_add_users.sql": (.generated, 4),
        "package-lock.json": (.generated, 5),
        "pnpm-lock.yaml": (.generated, 4),
        "config/app.yml": (.configuration, 3),
        "docker-compose.yaml": (.configuration, 3),
        "docs/guide.md": (.documentation, 5),
        "README.md": (.documentation, 5),
        "compileout/packed.js": (.buildArtifact, 3),
        "backup/legacy_dump_2023.sql": (.backupEvidence, 4),
        "analytics/top_customers.sql": (.unrecognized, 4),
        "tools/scratchpad.swift": (.production, 3),
    ]

    /// 一次摆齐：五种命名生态的测试目录、生成物、锁文件、产物目录、备份、未识别、
    /// 软链接（文件 + 目录）、嵌套仓库（`.git` 目录）、submodule（`.git` 文件）、
    /// 以及两棵**被剪枝**的目录（`.app` 走名单、`.xcarchive` 走 bundle 判定）。
    func writeRoleFixture(in root: URL) throws {
        for (path, truth) in CodeAnalyzerTests.roleTruth {
            _ = try write(String(repeating: "v = 1\n", count: truth.lines), to: path, in: root)
        }
        // 被排除的（各有各的理由，逐条对台账）
        _ = try write("let vendored = 1\n", to: "vendor/External.swift", in: root)
        _ = try write("build output\n", to: "build/out.swift", in: root)
        _ = try write("no extension\n", to: "LICENSE", in: root)
        _ = try write("prose\n", to: "notes.txt", in: root)
        _ = try write("secret = 1\n", to: ".hidden/secret.swift", in: root)
        _ = try write("package data\n", to: "Resources/en.lproj/Main.strings", in: root)
        // 名单外却被枚举器当 bundle 剪掉的那棵：判据 = 目录里住着 Info.plist
        _ = try write("<plist/>\n", to: "MyApp.xcarchive/Info.plist", in: root)
        _ = try write("let hiddenInsideArchive = 1\n", to: "MyApp.xcarchive/dSYMs/x.swift", in: root)
        _ = try write("<plist/>\n", to: "MyApp.xcarchive/Products/Applications/Tcoder.app/Info.plist",
                      in: root)
        // 仓库标记：根自己的、嵌套仓库的（目录）、submodule 的（文件）
        _ = try write("config\n", to: ".git/config", in: root)
        _ = try write("config\n", to: "nested/inner-repo/.git/config", in: root)
        _ = try write("gitdir: ../.git/modules/borrowed\n", to: "modules/borrowed/.git", in: root)
        let fileLink = root.appendingPathComponent("alias.swift")
        try? fm.removeItem(at: fileLink)
        try fm.createSymbolicLink(at: fileLink, withDestinationURL: root.appendingPathComponent("src/App.swift"))
        let dirLink = root.appendingPathComponent("symdir")
        try? fm.removeItem(at: dirLink)
        try fm.createSymbolicLink(at: dirLink, withDestinationURL: root.appendingPathComponent("src"))
        let dangling = root.appendingPathComponent("gone.swift")
        try? fm.removeItem(at: dangling)
        try fm.createSymbolicLink(at: dangling,
                                  withDestinationURL: root.appendingPathComponent("nowhere/absent.swift"))
    }

    private func roleFixtureOptions() -> ScanOptions {
        options(skipDirectories: ["vendor", "build"], binaryExtensions: ["gz"])
    }

    // MARK: - 正例：整棵夹具对独立真值

    func testRoleFixtureScansExactlyTheTruthSet() async throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        try writeRoleFixture(in: root)
        let scan = await scan(root, options: roleFixtureOptions())
        let paths = Set(scan.files.map(\.relativePath))
        XCTAssertEqual(paths, Set(CodeAnalyzerTests.roleTruth.keys),
                       "纳入集合与独立真值不一致（多/少文件）")
        XCTAssertEqual(scan.files.reduce(0) { $0 + $1.totalLineCount },
                       CodeAnalyzerTests.roleTruth.values.map(\.lines).reduce(0, +),
                       "纳入行数必须与独立真值逐行对上")
    }

    func testRoleTallyMatchesHandWrittenTruth() async throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        try writeRoleFixture(in: root)
        let scan = await scan(root, options: roleFixtureOptions())
        let tally = SourceRoleTally(of: scan.files)
        var expectedFiles: [SourceFileRole: Int] = [:]
        var expectedLines: [SourceFileRole: Int] = [:]
        for truth in CodeAnalyzerTests.roleTruth.values {
            expectedFiles[truth.role, default: 0] += 1
            expectedLines[truth.role, default: 0] += truth.lines
        }
        for role in SourceFileRole.allCases {
            XCTAssertEqual(tally.files(role), expectedFiles[role] ?? 0, "\(role.rawValue) 档文件数不符")
            XCTAssertEqual(tally.share(role).totalLines, expectedLines[role] ?? 0, "\(role.rawValue) 档行数不符")
        }
        XCTAssertEqual(tally.weakEvidenceFiles, 1, "只有 tools/scratchpad.swift 是弱判定")
        XCTAssertEqual(tally.count(.lockFileName), 2, "package-lock.json 与 pnpm-lock.yaml 都走锁文件判据")
        XCTAssertEqual(tally.count(.generatedFileSuffix), 2, ".pb.swift 与 .pb.go")
        XCTAssertEqual(tally.count(.migrationShape), 1)
        XCTAssertEqual(tally.count(.noRoleEvidence), 1, "analytics/top_customers.sql")
    }

    // MARK: - 反例：被剪枝的子树不许静默消失（修前就是这里一个字都没有）

    func testEnumeratorPrunedSubtreeIsNowRecordedAndNotSilentlyGone() async throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        try writeRoleFixture(in: root)
        let scan = await scan(root, options: roleFixtureOptions())
        XCTAssertEqual(scan.treeFollowing.unlistedPackageDirectoryCount, 1,
                       "只有 MyApp.xcarchive 是名单外被剪的（.app 走名单）")
        XCTAssertTrue(scan.treeFollowing.unlistedPackageDirectoryExamples.contains("MyApp.xcarchive"),
                      "被剪的目录要能点名：\(scan.treeFollowing.unlistedPackageDirectoryExamples)")
        let packageBucket = scan.skipLedger.buckets[.prunedPackageDir]
        XCTAssertEqual(packageBucket?.rules["xcarchive"], 1, "台账里要有 xcarchive 这一条命中")
        XCTAssertEqual(packageBucket?.rules["lproj"], 1, "en.lproj 仍按名单记账")
        // `.app` 这一层**看不见**：它的父目录 `MyApp.xcarchive` 先被剪掉了，枚举器根本不会
        // 交出 `Products/Applications/Tcoder.app`。这是"剪枝记账只到被看到的那一层"的
        // 保留边界 —— 已写进 R6 交回汇报，审计模式展开子树时才数得到里面的文件。
        XCTAssertNil(packageBucket?.rules["app"], "父目录先被剪时，内层包状目录不该出现：\(packageBucket?.rules ?? [:])")
        // 反向确认：这些文件确实**没有**进统计（否则"被剪掉"这句就是假的）
        XCTAssertTrue(scan.files.contains { $0.relativePath.hasPrefix("MyApp.xcarchive") } == false,
                      "枚举器剪掉了子树，纳入集合里就不该有它")
    }

    /// 审计模式要把"被剪掉的子树里到底有几个文件、多少行"数出来 —— 不数就明说是没数。
    func testAuditModeCountsPrunedSubtreeContents() async throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        try writeRoleFixture(in: root)
        let plain = await SourceTreeScanner(options: roleFixtureOptions()).scan(root: root)
        let readout = SourceScanScopeReadout.build(ledger: plain.skipLedger,
                                                   encounteredEntryTotal: plain.visitedFileCount
                                                       + plain.skipLedger.skippedFileTotal,
                                                   cappedRemaining: plain.truncatedByMaxFiles,
                                                   unreadableDirectoryCount: plain.unreadableDirectoryCount,
                                                   following: plain.treeFollowing)
        XCTAssertTrue(readout.unmeasuredScope.contains { $0.contains("内部文件数未统计") },
                      "\(readout.unmeasuredScope)")
        XCTAssertTrue(readout.blocksAbsenceClaims, "有未量准的范围时，「这个项目没有 X」不许成立")

        let audited = await SourceTreeScanner(options: roleFixtureOptions(),
                                             auditLineBudget: SourceSkipLedger.defaultAuditBudget)
            .scan(root: root)
        let auditedReadout = SourceScanScopeReadout.build(ledger: audited.skipLedger,
                                                          encounteredEntryTotal: audited.visitedFileCount
                                                              + audited.skipLedger.skippedFileTotal,
                                                          cappedRemaining: audited.truncatedByMaxFiles,
                                                          unreadableDirectoryCount: audited.unreadableDirectoryCount,
                                                          following: audited.treeFollowing)
        XCTAssertNotNil(auditedReadout.excludedLineCount.measuredValue, "审计模式必须给出真实行数读数")
        XCTAssertTrue(audited.skipLedger.buckets[.prunedPackageContents]?.files ?? 0 >= 3,
                      "xcarchive 里 2 个文件 + .app 里 1 个 Info.plist 要归因得到")
        // 审计与否都不许改变纳入集合（剪枝行为一字未动，只是多记了账）
        XCTAssertEqual(Set(audited.files.map(\.relativePath)), Set(plain.files.map(\.relativePath)))
    }

    // MARK: - 三态：「排除了 0 个」与「没统计排除」必须是两个读数

    func testZeroExcludedAndNotCountedExcludedAreDifferentReadings() {
        let measured = SourceScopeCount.measured(0)
        let blind = SourceScopeCount.notCounted(reason: "非审计模式")
        // ⚠ 参数是**整句量词键**（`%lld …`）而不是量词（批次 P69a）：
        // 传 `"行"` 时 `String(format:)` 会**静默把数字丢掉**（渲染成光一个「行」字），
        // 中文侧看着只差一个数，英文侧连数都没了。下面那条判据钉的就是这个形状。
        XCTAssertEqual(measured.describe(unit: "%lld 行"), "0 行")
        XCTAssertEqual(blind.describe(unit: "%lld 行"), "未统计（非审计模式）")
        XCTAssertNotEqual(measured.describe(unit: "%lld 行"), blind.describe(unit: "%lld 行"),
                          "两句话必须不同，否则「没数」会被读成「没有」")
        XCTAssertNil(blind.measuredValue)
        XCTAssertEqual(measured.measuredValue, 0)
    }

    // MARK: - 判据：`describe(unit:)` 的实参必须是**登记过的整句复数键**（P69a）

    /// 为什么单独立一条：`unit:` 位上的字面量本来就站在双语守卫 1b 的入口前缀里，
    /// 所以「没登记」它会红 —— 但 `"行"` **在 `.strings` 里是一条合法键**（它是列头标签），
    /// 于是"传了半截量词"这一类错**尺子看不见**，运行时却把测得值整个吃掉：
    /// `String(format: "行", 1234)` == `"行"`。缺一条判据的话，下一次有人加一个量纲
    /// （`"棵"`、`"份"`）就是又一次「把数写成没有数」。
    ///
    /// 判据两半：① 字面量必须含 `%lld`（`localizedCount` 只有拿到数字才选得了一/other），
    /// ② 必须是 `.stringsdict` 的顶层键（不是 `.strings` 的单数键）。
    static func malformedCountKeys(in files: [(path: String, content: String)],
                                   pluralKeys: Set<String>) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"describe\(unit:\s*"((?:[^"\\]|\\.)*)"\)"#)
        var offenders: [String] = []
        var seen = 0
        for file in files {
            let code = SurfaceScanKit.codeLines(file.content).joined(separator: "\n")
            let range = NSRange(code.startIndex..., in: code)
            for match in regex.matches(in: code, range: range) {
                guard let span = Range(match.range(at: 1), in: code) else { continue }
                let key = String(code[span])
                seen += 1
                if !key.contains("%lld") {
                    offenders.append("\(file.path) → \"\(key)\" 不是 %lld 整句键（数字会被静默丢掉）")
                } else if !pluralKeys.contains(key) {
                    offenders.append("\(file.path) → \"\(key)\" 不在 .stringsdict 顶层键里")
                }
            }
        }
        // 分母自证：扫不到任何调用点 = 这条判据在空转（本仓当前有 3 处）。
        XCTAssertGreaterThanOrEqual(seen, 3, "只数到 \(seen) 个 describe(unit:) 调用点 ⇒ 先怀疑扫描面")
        return offenders
    }

    func test_describeUnitArgumentIsAlwaysARegisteredPluralKey() throws {
        let files = try SurfaceScanKit.sourceFiles(under: "")
        XCTAssertFalse(files.isEmpty, "一个源码文件都没扫到 ⇒ 这条判据在空转")
        let offenders = Self.malformedCountKeys(in: files,
                                                pluralKeys: LocalizationGuardTests.registeredStringsDictKeys())
        XCTAssertTrue(offenders.isEmpty,
                      "这些 `describe(unit:)` 传的不是登记过的 `%lld` 整句量词键：\n  "
                        + offenders.sorted().joined(separator: "\n  "))
    }

    /// 双向元测试：坏形状（半截量词、没登记的键）必须各抓到一次，合法形状不许误伤。
    func test_meta_countKeyRulerCatchesBothBadShapesAndSparesTheGoodOne() {
        let badUnit = [(path: "Services/Code/Fake.swift",
                        content: #"x.describe(unit: "行")"#)]
        XCTAssertEqual(Self.malformedCountKeys(in: badUnit + Self.countKeyFloorSample,
                                               pluralKeys: ["%lld 行"]).count, 1,
                       "半截量词（它在 .strings 里可是合法键！）没被抓到 ⇒ 判据没有牙")
        let unregistered = [(path: "Services/Code/Fake.swift",
                             content: #"x.describe(unit: "%lld 棵子树")"#)]
        XCTAssertEqual(Self.malformedCountKeys(in: unregistered + Self.countKeyFloorSample,
                                               pluralKeys: ["%lld 行"]).count, 1,
                       "含 %lld 但没进 .stringsdict 的没被抓到")
        let good = [(path: "Services/Code/Fake.swift", content: #"x.describe(unit: "%lld 行")"#)]
        XCTAssertTrue(Self.malformedCountKeys(in: good + Self.countKeyFloorSample,
                                              pluralKeys: ["%lld 行"]).isEmpty,
                      "合法写法被误报 ⇒ 下次没人信这条")
        // 注释里必须能写被禁的写法本身（与全站扫描型判据同一道边界）。
        let documented = [(path: "Services/Code/Fake.swift",
                           content: "// 旧写法 describe(unit: \"行\")\n")]
        XCTAssertTrue(Self.malformedCountKeys(in: documented + Self.countKeyFloorSample,
                                              pluralKeys: ["%lld 行"]).isEmpty,
                      "注释里的那一条不该算")
    }

    /// 元测试夹具：分母自证要求至少 3 个调用点，这里补三份合法样例，
    /// 让"抓到几条"这个数只反映被测那一条，而不是夹具凑数。
    static let countKeyFloorSample: [(path: String, content: String)] = [
        (path: "Services/Code/Floor.swift", content: #"a.describe(unit: "%lld 行")"#),
        (path: "Services/Code/Floor.swift", content: #"b.describe(unit: "%lld 行")"#),
        (path: "Services/Code/Floor.swift", content: #"c.describe(unit: "%lld 行")"#),
    ]

    /// 一份没有范围台账的报告（旧 JSON / 只拿到 `CodeMetrics` 的下游）：句子必须自带"没统计"。
    func testReportWithoutLedgerSaysNotCountedRatherThanZero() {
        let readout = SourceScanScopeReadout.notObserved
        XCTAssertFalse(readout.observed)
        XCTAssertTrue(readout.blocksAbsenceClaims)
        let note = readout.notes.joined(separator: " ")
        XCTAssertTrue(note.contains("没统计排除"), "\(note)")
        XCTAssertTrue(note.contains("不成立"), "要明确否掉「排除了 0 个」这句：\(note)")
        XCTAssertFalse(note.contains("0 个条目"), "不许把没台账写成 0：\(note)")
    }

    /// 干净仓库（真的没有任何排除）：这时"0"才是可信的 0。
    func testCleanScanReportsMeasuredZeroNotBlindZero() async throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        _ = try write("let a = 1\n", to: "src/Only.swift", in: root)
        let outcome = try await FileSystemCodeAnalyzer().analyzeWithCoverage(root: root, options: options())
        XCTAssertTrue(outcome.coverage.skipLedger.buckets.isEmpty, "不该有剔除：\(outcome.coverage.skipLedger.buckets)")
        let readout = outcome.coverage.scopeReadout
        XCTAssertEqual(readout.totalCount.measuredValue, 1, "数过了，读数必须是具体的 1")
        XCTAssertTrue(readout.observed)
        XCTAssertTrue(readout.unmeasuredScope.isEmpty, "\(readout.unmeasuredScope)")
        XCTAssertFalse(readout.blocksAbsenceClaims)
        XCTAssertTrue((outcome.metrics.scanLimitations ?? []).isEmpty,
                      "一个上限都没碰到、也没未量准范围时不许常驻提示：\(outcome.metrics.scanLimitations ?? [])")
    }

    // MARK: - 符号链接 / 嵌套仓库 / submodule：跟不跟要有数、有句子

    func testSymlinkAndRepositoryPolicyIsCountedAndSaid() async throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        try writeRoleFixture(in: root)
        let scan = await scan(root, options: roleFixtureOptions())
        let policy = scan.treeFollowing
        XCTAssertEqual(policy.rootRepositoryDetected, true, "根下有 .git ⇒ 自身是工作树")
        XCTAssertEqual(policy.nestedRepositoryCount, 2, "嵌套仓库目录 + submodule 的 .git 文件")
        XCTAssertEqual(policy.submoduleMarkerCount, 1, "`.git` 是文件时才算 submodule 形状")
        XCTAssertEqual(policy.symbolicLinkFileCount, 2, "alias.swift + gone.swift")
        XCTAssertEqual(policy.symbolicLinkDirectoryCount, 1, "symdir")
        XCTAssertEqual(policy.danglingSymbolicLinkCount, 1, "gone.swift 的目标不存在")
        // 不跟随 = 不重复计数：symdir 指向 src/，src 下 4 个文件只应出现一次
        // src/ 之下独立真值就是 6 个文件（含 test_upload.py 与那条迁移）；
        // 跟着 symdir 下去会变成 12 —— 这一条就是"不跟随 ⇒ 不重复计数"的证据。
        XCTAssertEqual(scan.files.filter { $0.relativePath.hasPrefix("src/") }.count, 6,
                       "跟着目录软链接下去就会把 src/ 数第二遍")
        let notes = policy.notes.joined(separator: "\n")
        XCTAssertTrue(notes.contains("刻意不跟随"), notes)
        XCTAssertTrue(notes.contains("内部文件数未统计"), "被链接进来的子树要说明没数：\(notes)")
        XCTAssertTrue(notes.contains("已并入本次统计"), "嵌套仓库的口径要写死：\(notes)")
        XCTAssertTrue(notes.contains("submodule"), notes)
        XCTAssertTrue(notes.contains("不下潜"), "包状目录为什么止步要说清：\(notes)")
    }

    /// 关掉隐藏项过滤时（includeHidden = true），`.git` 不再走隐藏分支，仓库标记仍要被数到。
    func testRepositoryMarkersAreCountedRegardlessOfHiddenSwitch() async throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        try writeRoleFixture(in: root)
        let showHidden = await scan(root, options: options(skipDirectories: ["vendor", "build"],
                                                           includeHidden: true))
        XCTAssertEqual(showHidden.treeFollowing.nestedRepositoryCount, 2)
        XCTAssertEqual(showHidden.treeFollowing.rootRepositoryDetected, true)
    }

    // MARK: - 第二个读者：同一批句子必须一路带到 `scanLimitations`

    func testSurfaceNotesReachBothReadersThroughOneField() async throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        try writeRoleFixture(in: root)
        let files = await scan(root, options: roleFixtureOptions()).files
        let outcome = try await FileSystemCodeAnalyzer().analyzeWithCoverage(root: root,
                                                                            options: roleFixtureOptions())
        let surface = outcome.coverage.surfaceNotes
        XCTAssertFalse(surface.isEmpty)
        let onScreen = outcome.metrics.scanLimitations ?? []
        for note in surface {
            XCTAssertTrue(onScreen.contains(note), "surfaceNotes 里的每一句都要出现在落盘字段：\(note)")
        }
        XCTAssertTrue(onScreen.contains { $0.contains("认不出角色") }, "\(onScreen)")
        XCTAssertTrue(onScreen.contains { $0.contains("扫描范围：遍历看到") }, "\(onScreen)")
        // 三段拼一条链，一段都不能掉：范围账 + 角色账 + Java 识别账。
        XCTAssertEqual(onScreen,
                       outcome.coverage.limitationSummary + surface
                           + ComplexityEngine.JavaSignatureDeclines.notes(for: files),
                       "scanLimitations 必须等于三段拼接的结果，顺序与内容都不许改")
        // 第二个读者：落盘 → 解码回来还是同一串（CLI 与界面读的都是这个字段）
        let decoded = try JSONDecoder().decode(CodeMetrics.self,
                                              from: try JSONEncoder().encode(outcome.metrics))
        XCTAssertEqual(decoded.scanLimitations, onScreen)
    }

}
