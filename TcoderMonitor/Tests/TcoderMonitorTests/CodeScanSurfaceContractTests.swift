import Foundation
import XCTest
@testable import TcoderMonitor

// MARK: - 独立真值：自建语料 + 手写账（两个测试文件共用一份，复制一份下次就分叉）

/// OWNER: WS-R17（RD-15 · 申请单 R6 §3）。语料与手写账的唯一来源。
///
/// 语料落本树 `.scratch/r17-surface/`（已 gitignore、且在自扫剪枝清单里），即建即删。
/// 期望值全部手写在 `truth` / `ledgerByReason` 里：夹具里每写一个条目就在表里加一行，
/// 数字就是那次写入的行数（内容一律 `v = 1`，逐行都是代码）；「纳入 / 落哪一格台账 /
/// 在被剪的子树里根本见不到」是按 `ScanOptions.default` 那两份名单**人工**判一遍写下来的，
/// 不是从实现输出抄回来的。`CodeScanSurfaceContractTests` 的第一例先自证这张表与盘上相符。
enum CodeScanSurfaceFixture {

    /// 一个条目在遍历里的下场（五态互斥）。`passedThroughDirectory` = 路过但没记账。
    enum Fate: Equatable {
        case included(lines: Int)
        case ledgerDir(SourceSkipReason)
        case ledgerFile(SourceSkipReason, lines: Int)
        case ledgerLink(SourceSkipReason)
        case prunedAway(lines: Int)
        case passedThroughDirectory
    }

    /// 夹具里**每一个**条目一行。少一行、多一行、下场判错，自证那例就红。
    static let truth: [String: Fate] = [
        // 纳入统计的 6 个文件（共 15 行）。两枚"嵌套仓库里"的源码按口径**并入本仓**，不另算一份。
        "src/App.swift": .included(lines: 3),
        "src/Core.swift": .included(lines: 2),
        "src/Deep/Util.swift": .included(lines: 4),
        "docs/Readme.md": .included(lines: 2),
        "pkg/borrowed/Main.swift": .included(lines: 2),
        "nested/inner-repo/Inside.swift": .included(lines: 2),
        // 只是路过的目录（枚举器交出、不记账、不进任何计数）
        "src": .passedThroughDirectory, "src/Deep": .passedThroughDirectory,
        "docs": .passedThroughDirectory, "assets": .passedThroughDirectory,
        "pkg": .passedThroughDirectory, "pkg/borrowed": .passedThroughDirectory,
        "nested": .passedThroughDirectory, "nested/inner-repo": .passedThroughDirectory,
        "Resources": .passedThroughDirectory,
        // 落台账的 14 条（= 排除总数；每一格归哪个原因桶就写死在这里）
        "notes.txt": .ledgerFile(.unsupportedExtension, lines: 1),   // 语言表没有 .txt
        "LICENSE": .ledgerFile(.missingExtension, lines: 1),          // 无后缀
        "assets/logo.png": .ledgerFile(.binaryExtension, lines: 1),   // .png 在二进制名单里
        ".git": .ledgerDir(.hiddenEntry),                    // 根自己是工作树 ⇒ 只置 rootRepositoryDetected
        ".hidden": .ledgerDir(.hiddenEntry),
        "nested/inner-repo/.git": .ledgerDir(.hiddenEntry),  // 嵌套仓库标记（目录形状）
        "pkg/borrowed/.git": .ledgerFile(.hiddenEntry, lines: 1),   // 嵌套标记（**文件**形状 ⇒ submodule）
        "node_modules": .ledgerDir(.skippedDirectory),
        "Resources/en.lproj": .ledgerDir(.prunedPackageDir),        // 名单内包状目录
        "Tool.app": .ledgerDir(.prunedPackageDir),                  // 名单内包状目录
        "Archive.xcarchive": .ledgerDir(.prunedPackageDir),         // ⑥ **名单外**、被 bundle 判定剪掉
        "alias.swift": .ledgerLink(.symbolicLink),                   // ③ 文件软链接（指向 src/App.swift）
        "mirror": .ledgerLink(.symbolicLink),                        // 目录软链接（指向 src/，刻意不跟随）
        // 在被剪掉的子树里 ⇒ 本次一个都见不到（它们不进任何计数）
        ".git/config": .prunedAway(lines: 1),
        ".hidden/secret.swift": .prunedAway(lines: 1),
        "nested/inner-repo/.git/config": .prunedAway(lines: 1),
        "node_modules/left-pad": .prunedAway(lines: 0),
        "node_modules/left-pad/index.js": .prunedAway(lines: 2),
        "Resources/en.lproj/Main.strings": .ledgerFile(.unsupportedExtension, lines: 1),
        "Tool.app/Info.plist": .prunedAway(lines: 1),
        "Archive.xcarchive/Info.plist": .prunedAway(lines: 1),
        "Archive.xcarchive/deep": .prunedAway(lines: 0),
        "Archive.xcarchive/deep/Inner.swift": .prunedAway(lines: 2),
    ]

    /// 14 条台账按原因桶分好组（`displayed = Σ min(桶内条数, sampleLimit)`）。
    static let ledgerByReason: [SourceSkipReason: Int] = [
        .unsupportedExtension: 2, .missingExtension: 1, .binaryExtension: 1,
        .hiddenEntry: 4, .skippedDirectory: 1, .prunedPackageDir: 3, .symbolicLink: 2,
    ]

    static let links: [(name: String, target: String)] = [
        ("alias.swift", "src/App.swift"), ("mirror", "src"),
    ]

    static var includedFiles: Int { truth.values.filter { if case .included = $0 { return true }; return false }.count }
    static var ledgerEntries: Int { truth.values.reduce(0) { $0 + (isLedger($1) ? 1 : 0) } }
    static var includedLines: Int { truth.values.reduce(0) { total, fate in
        if case let .included(n) = fate { return total + n }; return total } }
    static var ledgerTotal: Int { ledgerByReason.values.reduce(0, +) }
    /// 走到「已看到」这一层的文件数：纳入 6 个 + 命中后缀 / 无后缀 / 二进制那 4 条。
    static var visitedFiles: Int { includedFiles + 4 }
    /// 顶格读数 = 上两者相加。⚠️ 那 3 条被规则剔除的文件因此**各被数了两遍** ——
    /// 这是判据侧既有的口径（`encounteredEntryTotal = visitedFileCount + skippedFileTotal`），
    /// 本流只把数**接出来**、不擅自改判据；写死在这里，将来谁修口径就必须重新对一次账。
    static var seenEntryTotal: Int { visitedFiles + ledgerTotal }
    static var displayedTotal: Int {
        ledgerByReason.values.map { min($0, SourceSkipLedger.sampleLimit) }.reduce(0, +)
    }
    /// 被剪掉的子树根数：mirror + Resources/en.lproj + Tool.app + Archive.xcarchive。
    static var prunedSubtreeRoots: Int { 4 }

    private static func isLedger(_ fate: Fate) -> Bool {
        switch fate { case .ledgerDir, .ledgerFile, .ledgerLink: return true; default: return false }
    }

    static func body(_ lines: Int) -> String { String(repeating: "v = 1\n", count: lines) }

    // MARK: - 摆夹具

    static func makeCorpus(tag: String) throws -> URL {
        let root = packageRoot.appendingPathComponent(".scratch/r17-surface/\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// 收尾必须把权限还回来：还不回来 `removeItem` 就删不掉夹具，
    /// 残骸会喂下一轮扫描当"真实数据"（`blocked/` 那一例设的是 0o000）。
    static func restoreAndRemove(_ root: URL) {
        let fm = FileManager.default
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("blocked").path)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? fm.removeItem(at: root)
    }

    /// 按手写账逐条摆出来。
    static func build(in root: URL) throws {
        let fm = FileManager.default
        for (path, fate) in truth {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            switch fate {
            case let .included(n): try Data(body(n).utf8).write(to: url)
            case let .ledgerFile(_, n): try Data(body(n).utf8).write(to: url)
            case let .prunedAway(n):
                if n == 0 { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
                else { try Data(body(n).utf8).write(to: url) }
            case .ledgerDir, .passedThroughDirectory:
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            case .ledgerLink:
                break
            }
        }
        for (name, target) in links {
            let link = root.appendingPathComponent(name)
            try? fm.removeItem(at: link)
            try fm.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent(target))
        }
    }

    static func write(_ text: String, to path: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    // MARK: - 自证：自己走一遍盘上的树（不经过分析器）

    /// 盘上条目的**结构**（普通文件带真实行数）。手写账与它双向对账，谁漂了谁红。
    enum Disk: Equatable { case directory, file(lines: Int), link }

    static func walk(root: URL, at prefix: String = "") throws -> [String: Disk] {
        let fm = FileManager.default
        var seen: [String: Disk] = [:]
        for name in (try? fm.contentsOfDirectory(atPath: root.path))?.sorted() ?? [] {
            let relative = prefix.isEmpty ? name : "\(prefix)/\(name)"
            let url = root.appendingPathComponent(name)
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { seen[relative] = .link; continue }
            if values?.isDirectory == true {
                seen[relative] = .directory
                for (child, entry) in try walk(root: url, at: relative) { seen[child] = entry }
                continue
            }
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            seen[relative] = .file(lines: text.filter { $0 == "\n" }.count)
        }
        return seen
    }

    static func expected(_ fate: Fate) -> Disk {
        switch fate {
        case let .included(n), let .ledgerFile(_, n): return .file(lines: n)
        case let .prunedAway(n): return n == 0 ? .directory : .file(lines: n)
        case .ledgerDir, .passedThroughDirectory: return .directory
        case .ledgerLink: return .link
        }
    }

    static let packageRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

extension XCTestCase {
    /// 建语料 + 挂收尾（权限还回来、树删掉）。两个测试文件都走它，免得有人忘了 teardown
    /// 把 0o000 的残骸留在盘上喂下一轮扫描。
    func r17Corpus(tag: String) throws -> URL {
        let root = try CodeScanSurfaceFixture.makeCorpus(tag: tag)
        addTeardownBlock { CodeScanSurfaceFixture.restoreAndRemove(root) }
        return root
    }
}

/// RD-15 落契约的**语料侧**守卫：手写账自证 + 12 格逐格对账 + 未知态 / 失败态。
/// 三态渲染、反例、读者点名与结构守卫住在
/// `CodeScanSurfaceReadoutTests` / `CodeScanSurfaceProductPathTests`（另一个文件）——
/// 拆文件是 Tests 侧 400 行闸门逼的，不是藏断言。**本类 6 例。**
final class CodeScanSurfaceContractTests: XCTestCase {

    private func scan(_ root: URL, options: ScanOptions = .default) async throws
        -> (surface: CodeScanScope, metrics: CodeMetrics) {
        let metrics = try await FileSystemCodeAnalyzer().analyzeWithCoverage(root: root, options: options).metrics
        return (try XCTUnwrap(metrics.scanSurface, "产品扫描必须落范围台账，不许留 nil"), metrics)
    }

    // MARK: - ⓪ 自证：手写账 == 我自己物理写下的那棵树

    func testHandWrittenLedgerAgreesWithTheFilesIPhysicallyWrote() throws {
        typealias F = CodeScanSurfaceFixture
        XCTAssertEqual(F.includedFiles, 6)
        XCTAssertEqual(F.includedLines, 15)
        XCTAssertEqual(F.ledgerEntries, 14)
        XCTAssertEqual(F.ledgerTotal, 14, "手写账的条目数与按桶分组后的条数必须一致")
        XCTAssertEqual(F.visitedFiles, 10)
        XCTAssertEqual(F.seenEntryTotal, 24, "被规则剔除的 4 个文件在顶格里各被数了两遍（判据既有口径）")
        XCTAssertEqual(F.displayedTotal, 14)
        XCTAssertEqual(F.prunedSubtreeRoots, 4)
        let root = try r17Corpus(tag: "selfcheck")
        try F.build(in: root)
        let disk = try F.walk(root: root)
        let onDisk = Set(disk.keys), onPaper = Set(F.truth.keys)
        XCTAssertEqual(onDisk, onPaper,
                       "盘上与手写账不是同一批条目：多 \(onDisk.subtracting(onPaper).sorted())"
                       + " / 少 \(onPaper.subtracting(onDisk).sorted())")
        for (path, fate) in F.truth {
            XCTAssertEqual(disk[path], F.expected(fate), "\(path) 的形状或行数与手写账不符")
        }
        // 归因名单当场复核：每格"为什么落那里"的依据来自产品侧那两份名单，不是我猜的。
        XCTAssertTrue(ScanOptions.default.skipDirectories.contains("node_modules"))
        XCTAssertTrue(ScanOptions.default.binaryExtensions.contains("png"))
        XCTAssertNil(SourceLanguageCatalog.language(forExtension: "txt"), ".txt 必须真的不在语言表里")
        XCTAssertTrue(SourceTreeScanner.packageExtensions.contains("lproj"))
        XCTAssertTrue(SourceTreeScanner.packageExtensions.contains("app"))
        XCTAssertFalse(SourceTreeScanner.packageExtensions.contains("xcarchive"),
                       "xcarchive 必须在名单外，它才是那条 bundle 判据的现场")
    }

    // MARK: - ① 正例：12 格逐格对手写账

    func testEverySurfaceFieldMatchesTheHandWrittenLedger() async throws {
        typealias F = CodeScanSurfaceFixture
        let root = try r17Corpus(tag: "positive")
        try F.build(in: root)
        let (surface, metrics) = try await scan(root)
        XCTAssertEqual(metrics.totalFiles, F.includedFiles, "分母不对，下面所有读数都不作数")
        XCTAssertEqual(metrics.totalLines, F.includedLines)
        XCTAssertEqual(surface.totalCount, F.seenEntryTotal, "顶格 = 看到过 10 个文件 + 台账 14 条")
        XCTAssertEqual(surface.displayedCount, F.displayedTotal, "14 条逐条点得到名")
        XCTAssertEqual(surface.undisplayedCount, 0, "全都点到了名 ⇒ 这是量到的 0，不是没数")
        XCTAssertEqual(surface.reportedExcludedEntryCount, F.ledgerTotal)
        XCTAssertEqual(surface.linesCounted, false)
        XCTAssertNil(surface.excludedLineCount, "没数过就不许给数（给 0 是把没数写成没有）")
        XCTAssertEqual(surface.nestedRepositoryCount, 2, "nested/inner-repo/.git + pkg/borrowed/.git")
        XCTAssertEqual(surface.submoduleMarkerCount, 1, "只有 pkg/borrowed/.git 是文件形状")
        XCTAssertEqual(surface.symbolicLinkFileCount, 1, "alias.swift")
        XCTAssertEqual(surface.symbolicLinkDirectoryCount, 1, "mirror")
        XCTAssertEqual(surface.unlistedPrunedDirectoryCount, 1, "Archive.xcarchive（名单外，靠 Info.plist 被剪）")
        XCTAssertEqual(surface.unreadableDirectoryCount, 0, "这份语料没有读不动的目录 ⇒ 量到的 0")
    }

    func testUnmeasuredScopeNamesThePrunedSubtreesAndTheUnCountedLines() async throws {
        typealias F = CodeScanSurfaceFixture
        let root = try r17Corpus(tag: "scope")
        try F.build(in: root)
        let (surface, _) = try await scan(root)
        let scope = surface.unmeasuredScope ?? []
        XCTAssertEqual(scope.count, 2, "\(scope)")
        XCTAssertTrue(scope.contains { $0.contains("4 棵被剪枝的目录子树") }, "\(scope)")
        XCTAssertTrue(scope.contains { $0.contains("14 个被剔除条目的行数未统计") }, "\(scope)")
    }

    // MARK: - ② 恒等式：同一分母的两半相加；天然不平的那条不许写死

    func testDisplayedPlusUndisplayedEqualsTheExcludedTotalWhileTotalCountIsAnotherDenominator() async throws {
        typealias F = CodeScanSurfaceFixture
        let root = try r17Corpus(tag: "identity")
        try F.build(in: root)
        let (surface, _) = try await scan(root)
        XCTAssertEqual(surface.reportedExcludedEntryCount,
                       (surface.displayedCount ?? 0) + (surface.undisplayedCount ?? 0),
                       "同一分母（被排除条目）的两半相加必须等于排除总数")
        XCTAssertEqual(surface.reportedExcludedEntryCount, F.ledgerTotal)
        // ⚠️ `totalCount` 量的是"遍历看到的条目"，与上面那个分母不是一回事 ⇒
        // `totalCount == displayed + undisplayed` 在这一族**天然不平**，按 RD-48 的教训不许写死。
        // 这里钉成"确实不相等"：谁哪天拿顶格当排除总数上屏，这条会红。
        XCTAssertNotEqual(surface.totalCount, surface.reportedExcludedEntryCount)
    }

    // MARK: - ③ 未知态：命中文件上限没下潜 ⇒ 顶格是一个量到的低估数

    /// 申请单 §3 没给这一格承接字段（内部 `build(...)` 收了 `cappedRemaining` 却一个字没用），
    /// 事实只在 `scanLimitations` 第一句里 —— 这条把"字段侧数不出它"如实钉住并交回总工。
    func testFileCapUndercountsTotalCountAndTheContractHasNoCellForIt() async throws {
        typealias F = CodeScanSurfaceFixture
        let root = try r17Corpus(tag: "filecap")
        for name in ["One", "Two", "Three"] { try F.write(F.body(1), to: "src/\(name).swift", in: root) }
        var capped = ScanOptions.default
        capped.maxFiles = 2
        let (surface, metrics) = try await scan(root, options: capped)
        XCTAssertEqual(surface.totalCount, 2, "看到 2 个候选就进探测模式 ⇒ 读数偏小")
        XCTAssertLessThan(surface.totalCount ?? 0, 3, "手写账：盘上其实有 3 份源码")
        XCTAssertFalse((surface.unmeasuredScope ?? []).contains { $0.contains("文件上限") },
                       "字段侧没有承接格 ⇒ 句子与字段各说各话（已知缺口，不是实现坏了）")
        XCTAssertTrue((metrics.scanLimitations ?? []).contains { $0.contains("达到单次扫描文件上限") },
                      "这一格今天只能靠句子说：\(metrics.scanLimitations ?? [])")
    }

    // MARK: - ④ 失败态：目录读不动 ⇒ 一格 measured 的盲点数

    func testUnreadableDirectoryBecomesOneMeasuredBlindSpot() async throws {
        typealias F = CodeScanSurfaceFixture
        let root = try r17Corpus(tag: "unreadable")
        try F.write(F.body(2), to: "src/One.swift", in: root)
        try F.write(F.body(1), to: "src/Two.swift", in: root)
        try F.write(F.body(1), to: "notes.txt", in: root)
        let blocked = root.appendingPathComponent("blocked")
        try F.write(F.body(3), to: "blocked/Hidden.swift", in: root)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blocked.path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blocked.path)
        let (surface, metrics) = try await scan(root)
        guard (surface.unreadableDirectoryCount ?? 0) > 0 else {
            throw XCTSkip("本机允许枚举 0o000 目录（测试进程带着绕过权限的位）⇒ 计数为 0 才是正确行为，不硬判")
        }
        XCTAssertEqual(metrics.totalFiles, 2, "被挡住的那份源码不许算成扫到过")
        XCTAssertEqual(surface.unreadableDirectoryCount, 1)
        // 手写账：走到"已看到"这一层的文件 3 个（src/One + src/Two + notes.txt）+ 台账 1 条 = 顶格 4。
        XCTAssertEqual(surface.totalCount, 4)
        XCTAssertEqual(surface.displayedCount, 1)
        XCTAssertTrue((surface.unmeasuredScope ?? []).contains { $0.contains("没看完") },
                      "\(surface.unmeasuredScope ?? [])")
    }
}
