import Foundation
import XCTest
@testable import TcoderMonitor

/// OWNER: WS-R6 文件角色与扫描范围（RD-14/15）—— 工单点名形状的**独立真值**用例 + 范围台账四态。
///
/// 与 `SourceScanScopeTests` 的分工：那份对「八档各一枚」的大夹具做全量对账；这一份补两件它没管的事：
/// 1. **工单原文点名的形状**（`spec/`、`__tests__/`、`*IT.ts`、`*E2E.spec.ts`、`*.pb.swift`、
///    二进制、`.build`、符号链接、嵌套 `.git`）逐枚落到自己那一格；
/// 2. **RD-15 四态**里的反例 / 未知 / 失败三态（正例那份已有，这里另补一枚「全跟」的正例）。
///
/// 走 `extension CodeAnalyzerTests` 的理由与那份相同：夹具根归一化（`/var → /private/var`）
/// 与写文件的辅助全仓只许有一份，复制一份下次就分叉。
///
/// **独立真值 = 下面 `ticketTruth` / `ticketExcludedTruth` 两张手写表**。怎么数的：
/// 夹具里每写一个文件就在表里加一行，`lines` 就是那次写入的行数（内容一律 `v = 1`，逐行都是代码）；
/// 「纳入 / 排除」按 `ScanOptions.default` 那两份名单**人工**判一遍写下来。
/// 落盘后又用 `find` + `wc -l` 现场核过一次（应纳入 12 个 / 37 行、排除面 8 条记录，
/// 真实输出见 Obsidian `116` 第 1 节）。没有任何一条期望是从实现输出抄回来的。
extension CodeAnalyzerTests {

    /// 应进统计的文件 → (角色, 行数, 判据)。
    static let ticketTruth: [String: (role: SourceFileRole, lines: Int, criterion: SourceRoleCriterion)] = [
        "src/App.swift": (.production, 3, .productionPathSegment),
        "pkg/inner/src/Core.swift": (.production, 3, .productionPathSegment),
        "pkg/borrowed/Main.swift": (.production, 2, .productionPathSegment),
        "scratch/Helper.swift": (.production, 2, .productionLanguageOnly),
        "src/PaymentIT.ts": (.test, 4, .testFileNameShape),
        "ui/CheckoutE2E.spec.ts": (.test, 5, .testFileNameShape),
        "spec/models/user_spec.rb": (.test, 3, .testPathSegment),
        "__tests__/login.test.js": (.test, 3, .testPathSegment),
        "proto/Thing.pb.swift": (.generated, 4, .generatedFileSuffix),
        "src/Widget.pb.swift": (.generated, 2, .generatedFileSuffix),
        "docs/Notes.md": (.documentation, 3, .documentationPathSegment),
        "analytics/report.sql": (.unrecognized, 3, .noRoleEvidence),
    ]

    /// 台账里该出现的那 8 条记录 → 原因桶。**记的是"被剪掉的那一层"**：
    /// `.build` 与 `node_modules` 各记目录本身一条（子树随之消失，产品模式不逐个见文件），
    /// 两枚仓库标记 `.git` 走 `hiddenEntry`（名字以 `.` 开头 ⇒ 隐藏那条分支先命中，
    /// 这一格是读 `SourceScanTrail.consume` 的分支顺序读出来的，钉住它是因为挪顺序会悄悄换掉归因）。
    static let ticketExcludedTruth: [String: SourceSkipReason] = [
        ".build": .hiddenEntry,
        "pkg/inner/.git": .hiddenEntry,
        "pkg/borrowed/.git": .hiddenEntry,
        "node_modules": .skippedDirectory,
        "assets/logo.png": .binaryExtension,
        "LICENSE": .missingExtension,
        "mirror": .symbolicLink,
        "alias.swift": .symbolicLink,
    ]

    /// 藏在被剪子树里的文件：产品模式**一个都见不到**，它们只随父目录那一条记录消失。
    private static let ticketPrunedContents = [
        ".build/checkouts/Dep.swift": 2,
        "node_modules/left-pad/index.js": 2,
        "pkg/inner/.git/config": 1,
    ]

    /// 条目级排除：两枚都会被枚举器**亲手交到**判定链上、再各自落一格账。
    /// （第一版真值表把它们当成"已存在"却没往夹具里写，于是台账少了两格、
    /// 断言当场红 —— 这条记录留着，说明红的是夹具不是判据。）
    private static let ticketEntryExcluded = [
        "assets/logo.png": 1,
        "LICENSE": 1,
    ]

    /// 把工单点名的形状一次摆齐。
    func writeTicketShapeFixture(in root: URL) throws {
        for (path, truth) in CodeAnalyzerTests.ticketTruth {
            _ = try write(String(repeating: "v = 1\n", count: truth.lines), to: path, in: root)
        }
        for pruned in [CodeAnalyzerTests.ticketPrunedContents, CodeAnalyzerTests.ticketEntryExcluded] {
            for (path, lines) in pruned {
                _ = try write(String(repeating: "v = 1\n", count: lines), to: path, in: root)
            }
        }
        // 嵌套仓库的 `.git` 是目录、submodule 的 `.git` 是写着 gitdir 的文件：两种形状分开数
        _ = try write("gitdir: ../inner/.git/modules/borrowed\n", to: "pkg/borrowed/.git", in: root)
        // 目录软链接（跟进去会把 src/ 数第二遍）+ 文件软链接（跟进去会读到同一份源码）
        try fm.createSymbolicLink(at: root.appendingPathComponent("mirror"),
                                  withDestinationURL: root.appendingPathComponent("src"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("alias.swift"),
                                  withDestinationURL: root.appendingPathComponent("src/App.swift"))
    }

    // MARK: - RD-14：每个文件被算进哪一格

    /// 全量对账：纳入集合、逐文件角色与判据、八档的文件数与行数，一次钉死。
    func testTicketShapesLandInExactlyTheHandCountedBuckets() async throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        try writeTicketShapeFixture(in: root)
        let scan = await scan(root, options: .default)
        XCTAssertEqual(Set(scan.files.map(\.relativePath)), Set(CodeAnalyzerTests.ticketTruth.keys),
                       "纳入集合与独立真值不一致：\(scan.files.map(\.relativePath).sorted())")
        let truthLineTotal = CodeAnalyzerTests.ticketTruth.values.map(\.lines).reduce(0, +)
        XCTAssertEqual(truthLineTotal, 37, "真值表本身要先能被口算复核")
        XCTAssertEqual(scan.files.reduce(0) { $0 + $1.totalLineCount }, truthLineTotal, "纳入行数必须逐行对上")
        for file in scan.files {
            guard let truth = CodeAnalyzerTests.ticketTruth[file.relativePath] else {
                XCTFail("\(file.relativePath) 不在真值表里"); continue
            }
            let decision = SourceRoleTally.decision(for: file)
            XCTAssertEqual(decision.role, truth.role, "\(file.relativePath) → \(decision.role.rawValue)")
            XCTAssertEqual(decision.criterion, truth.criterion,
                           "\(file.relativePath) 判据是 \(decision.criterion.rawValue)，期望 \(truth.criterion.rawValue)")
            XCTAssertFalse(decision.evidence.isEmpty, "\(file.relativePath) 的判定没留可点名的线索")
        }
        let tally = SourceRoleTally(of: scan.files)
        var wantFiles: [SourceFileRole: Int] = [:]
        var wantLines: [SourceFileRole: Int] = [:]
        for truth in CodeAnalyzerTests.ticketTruth.values {
            wantFiles[truth.role, default: 0] += 1
            wantLines[truth.role, default: 0] += truth.lines
        }
        for role in SourceFileRole.allCases {
            XCTAssertEqual(tally.files(role), wantFiles[role] ?? 0, "\(role.rawValue) 档文件数不符")
            XCTAssertEqual(tally.share(role).totalLines, wantLines[role] ?? 0, "\(role.rawValue) 档行数不符")
        }
        // 守恒：分档之和 == 全量（少归一档、或同一文件归两处，都会在这里断掉）
        XCTAssertEqual(tally.attributedFileCount, scan.files.count)
        XCTAssertEqual(SourceFileRole.allCases.map { tally.share($0).totalLines }.reduce(0, +), truthLineTotal)
    }

    /// 红线：认不出角色的文件必须**出声**，且不许并进生产码那一格。
    func testUnrecognizedRoleSpeaksUpAndIsNotFoldedIntoProduction() async throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        try writeTicketShapeFixture(in: root)
        let outcome = try await FileSystemCodeAnalyzer().analyzeWithCoverage(root: root, options: .default)
        let tally = outcome.coverage.roleTally
        XCTAssertEqual(tally.files(.unrecognized), 1)
        XCTAssertEqual(tally.share(.unrecognized).examples, ["analytics/report.sql"], "未识别要能点名")
        XCTAssertEqual(tally.files(.production), 4, "生产码那格只许是真值表里那四个")
        XCTAssertEqual(tally.codeLines(.production), 10, "生产码行数 = 3+3+2+2，未识别的 3 行不许进来")
        let notes = tally.notes.joined(separator: "\n")
        XCTAssertTrue(notes.contains("认不出角色"), notes)
        XCTAssertTrue(notes.contains("analytics/report.sql"), "边界句要点名是哪个文件：\(notes)")
        XCTAssertTrue((outcome.metrics.scanLimitations ?? []).contains { $0.contains("认不出角色") },
                      "这句必须一路带到落盘字段，不许停在内存里：\(outcome.metrics.scanLimitations ?? [])")
        // 弱判定（只有语言证据）与硬证据分开：它落生产码档，但必须单独有数、有名字
        XCTAssertEqual(tally.weakEvidenceFiles, 1)
        XCTAssertEqual(tally.weakEvidenceExamples, ["scratch/Helper.swift"])
        XCTAssertTrue(tally.roleLines.contains { $0.contains("scratch/Helper.swift") }, "\(tally.roleLines)")
    }

    /// 每条排除都要落在一格账上，一条都不许"静默消失"。
    func testEveryExcludedEntryIsBookedByAKnownRule() async throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        try writeTicketShapeFixture(in: root)
        let scan = await scan(root, options: .default)
        let ledger = scan.skipLedger
        for (path, reason) in CodeAnalyzerTests.ticketExcludedTruth {
            XCTAssertTrue(scan.files.contains { $0.relativePath == path } == false, "\(path) 不该在统计里")
            let bucket = ledger.buckets[reason]
            XCTAssertNotNil(bucket, "\(path) 该记在 \(reason.rawValue) 却一格都没有")
            XCTAssertTrue(bucket?.samples.contains { $0.hasSuffix("/" + path) } ?? false,
                          "\(path) 要在 \(reason.rawValue) 里点到名：\(bucket?.samples ?? [])")
        }
        XCTAssertEqual(ledger.skippedFileTotal, 8,
                       "排除面与手写表不一致：\(ledger.buckets.mapValues(\.files))")
        // 根因归属：`.build` 走隐藏项分支、`node_modules` 走名单分支、png 走二进制后缀
        XCTAssertEqual(ledger.buckets[.skippedDirectory]?.rules["node_modules"], 1)
        XCTAssertEqual(ledger.buckets[.hiddenEntry]?.files, 3, ".build + 两枚 .git")
        XCTAssertEqual(ledger.buckets[.binaryExtension]?.rules["png"], 1)
        // 被剪子树里的文件确实一个都没进统计（否则上面那句"排除"就是假的）
        for path in CodeAnalyzerTests.ticketPrunedContents.keys {
            XCTAssertTrue(scan.files.contains { $0.relativePath == path } == false, "\(path) 不该被看到")
        }
    }

    // MARK: - RD-15 正例（全跟）与反例（不跟 ⇒ 读数变小，且说清为什么小）

    /// 正例：一棵没有排除面、没有软链接、没有产物的树 —— 这里的 0 与"没有未量准"都是可信的。
    func testFullyFollowedScanReportsMeasuredZeroes() async throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        for name in ["One", "Two", "Three"] {
            _ = try write("v = 1\n", to: "src/\(name).swift", in: root)
        }
        let outcome = try await FileSystemCodeAnalyzer().analyzeWithCoverage(root: root, options: .default)
        let readout = outcome.coverage.scopeReadout
        XCTAssertTrue(readout.observed)
        XCTAssertEqual(readout.totalCount.measuredValue, 3, "数过了，读数必须是具体的 3")
        XCTAssertEqual(readout.excludedFileTotal, 0, "这一份的 0 是真 0")
        XCTAssertTrue(readout.unmeasuredScope.isEmpty, "\(readout.unmeasuredScope)")
        XCTAssertTrue(readout.blocksAbsenceClaims == false, "看完了才有资格说「这个项目没有 X」")
        XCTAssertNil(outcome.metrics.scanLimitations)
    }

    /// 反例：同一棵内容相同的树，只多一枚指向 `src/` 的目录软链接 ——
    /// 纳入读数**不许**变大（跟进去就是把同一份源码数第二遍），而句子必须解释这个数是"选择不看"。
    func testNotFollowingSymlinksKeepsTheReadingSmallerAndSaysWhy() async throws {
        let plain = try makeFixtureRoot()
        let linked = try makeFixtureRoot()
        defer { try? fm.removeItem(at: plain); try? fm.removeItem(at: linked) }
        for url in [plain, linked] {
            _ = try write("v = 1\n", to: "src/One.swift", in: url)
            _ = try write("v = 2\n", to: "src/Two.swift", in: url)
            _ = try write("v = 3\n", to: "src/Three.swift", in: url)
        }
        try fm.createSymbolicLink(at: linked.appendingPathComponent("mirror"),
                                  withDestinationURL: linked.appendingPathComponent("src"))
        let without = try await FileSystemCodeAnalyzer().analyzeWithCoverage(root: plain, options: .default)
        let with = try await FileSystemCodeAnalyzer().analyzeWithCoverage(root: linked, options: .default)
        XCTAssertEqual(without.metrics.totalFiles, 3, "独立真值：src/ 之下三枚")
        XCTAssertEqual(with.metrics.totalFiles, 3, "跟着目录软链接下去就会报 6 —— 那一遍是重复计数")
        XCTAssertEqual(with.metrics.codeLines, without.metrics.codeLines, "行数同理，不许翻倍")
        XCTAssertEqual(with.metrics.totalLines, without.metrics.totalLines)
        // 零命中不出声 ⇒ 证明"刻意不跟随"那句是数出来的，不是常驻模板
        XCTAssertTrue(without.coverage.treeFollowing.notes.isEmpty, "\(without.coverage.treeFollowing.notes)")
        XCTAssertEqual(with.coverage.treeFollowing.symbolicLinkDirectoryCount, 1)
        let note = with.coverage.treeFollowing.notes.joined(separator: "\n")
        XCTAssertTrue(note.contains("刻意不跟随"), note)
        XCTAssertTrue(note.contains("符号链接 1 条"), "句子要带现场数字：\(note)")
        XCTAssertTrue(note.contains("内部文件数未统计"), "变小了就得说清少看的是哪一片：\(note)")
        XCTAssertTrue(with.coverage.scopeReadout.blocksAbsenceClaims, "有没看过的子树时「没有 X」不成立")
        XCTAssertTrue(without.coverage.scopeReadout.blocksAbsenceClaims == false, "全看完了，0 才是可信的 0")
    }

    // MARK: - RD-15 未知：读不动的目录 ⇒ 计数 + 一句「没看完」

    func testUnreadableDirectoryCountsItselfAndBlocksAbsenceClaims() async throws {
        let root = try makeFixtureRoot()
        let locked = root.appendingPathComponent("locked")
        defer {
            // 权限不还回去，`removeItem` 就删不掉这棵夹具；残骸会喂下一轮扫描当真实数据。
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? fm.removeItem(at: root)
        }
        _ = try write("v = 1\n", to: "src/Kept.swift", in: root)
        _ = try write("v = 2\n", to: "locked/Hidden.swift", in: root)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        let outcome = try await FileSystemCodeAnalyzer().analyzeWithCoverage(root: root, options: .default)
        guard outcome.coverage.unreadableDirectoryCount > 0 else {
            throw XCTSkip("本机允许枚举 0o000 目录（以 root 跑测试）—— 计数为 0 是正确行为，不硬判")
        }
        XCTAssertEqual(outcome.metrics.totalFiles, 1, "被挡住的那份源码不许算成扫到过")
        XCTAssertTrue(outcome.coverage.isPartial)
        XCTAssertTrue(outcome.coverage.limitationSummary.contains { $0.contains("读不动") },
                      "\(outcome.coverage.limitationSummary)")
        // 这一格是本流补的门：读不动的目录必须同时进 `unmeasuredScope`，
        // 否则「这个项目没有测试码」在一棵被挡住一半的树上会被当成"量过了、真的没有"。
        let readout = outcome.coverage.scopeReadout
        XCTAssertTrue(readout.unmeasuredScope.contains { $0.contains("没看完") }, "\(readout.unmeasuredScope)")
        XCTAssertTrue(readout.blocksAbsenceClaims, "没见过 ≠ 没有")
        XCTAssertTrue((outcome.metrics.scanLimitations ?? []).contains { $0.contains("读不动") })
    }

    // MARK: - RD-15 失败：整个根读不了，不许出一份像真的空报告

    func testUnreadableRootNeverYieldsAPlausibleEmptyReport() async throws {
        // ① 根存在却读不到内容（悬空软链接）：必须抛错，而不是交出一份全 0 的报告
        let parent = try makeFixtureRoot()
        defer { try? fm.removeItem(at: parent) }
        let dangling = parent.appendingPathComponent("project")
        try fm.createSymbolicLink(at: dangling, withDestinationURL: parent.appendingPathComponent("nowhere"))
        do {
            _ = try await FileSystemCodeAnalyzer().analyzeWithCoverage(root: dangling, options: .default)
            XCTFail("读不到的根必须失败得看得见，不许返回一份空报告")
        } catch let error as AnalysisError {
            guard case let .notDirectory(path) = error else {
                return XCTFail("该报「路径不是有效目录」，实际 \(error.localizedDescription)")
            }
            XCTAssertEqual(path, dangling.path)
        }
        // ② 扫描器**自己**给不出任何"我没看完"的证据：文件空、计数空、台账也空。
        //    这条不是"通过"，是把责任落在哪里写清楚 —— 装配点那道 `fileExists` 守卫一旦被人挪掉，
        //    下面这些 0 就会长成一份"这个仓库 0 行代码"的真报告。①③ 两条一起守着这个顺序。
        let blind = await SourceTreeScanner(options: .default).scan(root: dangling)
        XCTAssertTrue(blind.files.isEmpty)
        XCTAssertEqual(blind.visitedFileCount, 0)
        XCTAssertTrue(blind.skipLedger.buckets.isEmpty, "\(blind.skipLedger.buckets)")
        XCTAssertEqual(blind.treeFollowing, SourceTreeFollowingLedger())
        // ③ 真空目录：这一份的 0 可信，与 ①② 必须长成两个样子（对照才证明 ① 不是"真的没有"）
        let empty = try makeFixtureRoot()
        defer { try? fm.removeItem(at: empty) }
        let clean = try await FileSystemCodeAnalyzer().analyzeWithCoverage(root: empty, options: .default)
        XCTAssertEqual(clean.metrics.totalFiles, 0)
        XCTAssertTrue(clean.coverage.scopeReadout.observed)
        XCTAssertEqual(clean.coverage.scopeReadout.totalCount.measuredValue, 0, "数过了，0 就写 0")
        XCTAssertTrue(clean.coverage.scopeReadout.unmeasuredScope.isEmpty)
        XCTAssertTrue(clean.coverage.scopeReadout.blocksAbsenceClaims == false)
    }

    // MARK: - 「跟不跟」不许看运气：现场计数变了，句子必须跟着变

    func testFollowingSentencesAreDerivedFromCountsNotHardcoded() {
        var ledger = SourceTreeFollowingLedger()
        XCTAssertTrue(ledger.notes.isEmpty, "零命中不许出声")
        XCTAssertEqual(ledger.prunedSubtreeRootCount, 0)
        ledger.observeSymbolicLink(isDirectory: true, targetResolvable: true)
        var joined = ledger.notes.joined(separator: "\n")
        XCTAssertTrue(joined.contains("符号链接 1 条"), joined)
        XCTAssertTrue(joined.contains("1 棵被链接进来的子树内部文件数未统计"), joined)
        XCTAssertTrue(joined.contains("悬空") == false, "目标还在时不许报悬空：\(joined)")
        ledger.observeSymbolicLink(isDirectory: true, targetResolvable: false)
        joined = ledger.notes.joined(separator: "\n")
        XCTAssertTrue(joined.contains("符号链接 2 条"), joined)
        XCTAssertTrue(joined.contains("其中 1 条目标不存在"), joined)
        XCTAssertTrue(joined.contains("2 棵被链接进来的子树"), joined)
        // 仓库边界那句：是不是工作树、几个标记、几个是 submodule 形状，三格都得跟着现场值动
        var bare = SourceTreeFollowingLedger()
        bare.observeRepositoryMarker(isDirectory: false, isAtScanRoot: false)
        bare.observeRepositoryMarker(isDirectory: true, isAtScanRoot: false)
        XCTAssertTrue(bare.notes.joined().contains("自身不是"), "\(bare.notes)")
        XCTAssertTrue(bare.notes.joined().contains("又发现 2 个仓库标记"), "\(bare.notes)")
        XCTAssertTrue(bare.notes.joined().contains("submodule 形状 1 个"), "\(bare.notes)")
        var more = bare
        more.observeRepositoryMarker(isDirectory: false, isAtScanRoot: true)
        more.observeRepositoryMarker(isDirectory: false, isAtScanRoot: false)
        XCTAssertTrue(more.notes.joined().contains("自身是"), "\(more.notes)")
        XCTAssertTrue(more.notes.joined().contains("又发现 3 个仓库标记"), "\(more.notes)")
        XCTAssertTrue(more.notes.joined().contains("submodule 形状 2 个"),
                      "根自己那枚 .git 只该置 rootRepositoryDetected，不许混进 nested 计数：\(more.notes)")
        // 包状目录：名单内 / 名单外分开点名，两格的数字各自要能动
        var packed = SourceTreeFollowingLedger()
        packed.observePackageDirectory(listed: true, name: "Tool.app")
        packed.observePackageDirectory(listed: false, name: "Out.xcarchive")
        let packedNote = packed.notes.joined(separator: "\n")
        XCTAssertTrue(packedNote.contains("包状目录不下潜 1 个（按名单）"), packedNote)
        XCTAssertTrue(packedNote.contains("1 个（按系统 bundle 判定"), packedNote)
        XCTAssertTrue(packedNote.contains("Out.xcarchive"), packedNote)
        XCTAssertEqual(packed.prunedSubtreeRootCount, 2)
    }

    /// 未量准范围的三条来源各自要有名字，也各自都能关掉缺席型结论。
    func testUnmeasuredScopeNamesEachBlindSpotSeparately() {
        let emptyLedger = SourceSkipLedger()
        var withSymlink = SourceTreeFollowingLedger()
        withSymlink.observeSymbolicLink(isDirectory: true, targetResolvable: true)
        let blind = SourceScanScopeReadout.build(ledger: emptyLedger, encounteredEntryTotal: 5,
                                                 cappedRemaining: false, unreadableDirectoryCount: 3,
                                                 following: withSymlink)
        XCTAssertTrue(blind.unmeasuredScope.contains { $0.contains("3 个目录本次读不动") },
                      "\(blind.unmeasuredScope)")
        XCTAssertTrue(blind.unmeasuredScope.contains { $0.contains("1 棵被剪枝的目录子树") },
                      "\(blind.unmeasuredScope)")
        XCTAssertTrue(blind.blocksAbsenceClaims)
        // 零命中：一条都不出声 —— 这时"没有 X"才允许说（否则这句永远为真，等于没有门）
        let clean = SourceScanScopeReadout.build(ledger: emptyLedger, encounteredEntryTotal: 5,
                                                 cappedRemaining: false, unreadableDirectoryCount: 0,
                                                 following: SourceTreeFollowingLedger())
        XCTAssertTrue(clean.unmeasuredScope.isEmpty, "\(clean.unmeasuredScope)")
        XCTAssertTrue(clean.blocksAbsenceClaims == false)
    }
}
