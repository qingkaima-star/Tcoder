import Foundation
import XCTest
@testable import TcoderMonitor

/// WS-R26（RD-61 第二半）的另外三面：旧报告兼容 / 失败态 / 交付二进制对表。
/// 用例本体住在 `DuplicateCoordinatePortabilityTests.swift`（含立案事实与保留的边界），
/// 这一份只因为它守的是**产品路径出口**（`analyzeWithCoverage` 抛错、软链台账、
/// 无头 `scan` 落的盘）而单独成文件 —— 同一类型的第二个文件，判据不分家。
extension DuplicateCoordinatePortabilityTests {

    // MARK: - ⑤ 旧报告兼容面：绝对坐标照旧解得开、照旧开得动

    /// 旧报告里那批绝对坐标：**schema 一字未动**（`Models/**` 没碰），只有值形状是旧的，
    /// 所以这份 JSON 由当前编码器写出、绝对坐标按改前那一步的值填进去即可复现。
    func test_legacyAbsoluteCoordinatesStillDecodeAndStillResolve() throws {
        var metrics = CodeMetrics()
        metrics.duplicatedBlocks = [DuplicatedBlock(
            occurrences: [DuplicatedFragment(path: "/old/machine/checkout/pairs/a.swift", startLine: 12),
                          DuplicatedFragment(path: "/old/machine/checkout/pairs/b.swift", startLine: 34)],
            lineCount: 12, similarity: 0.95)]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metrics)
        let back = try JSONDecoder.tcoderReportDecoder().decode(CodeMetrics.self, from: data)

        // 旧形状不被改写（不补 0、不剪成相对、不判败）。
        let kept = try XCTUnwrap(back.duplicatedBlocks.first?.occurrences.map { $0.path })
        XCTAssertEqual(kept, ["/old/machine/checkout/pairs/a.swift", "/old/machine/checkout/pairs/b.swift"])
        // 两个消费点对旧形状仍然可用：绝对那一条分支不拼根。
        XCTAssertEqual(CodeViewFormat.resolvedURL("/old/machine/checkout/pairs/a.swift", root: "/new/root").path,
                       "/old/machine/checkout/pairs/a.swift")
        // 展示层的剥前缀对旧形状仍然有效（巨大/热点两榜还在给绝对路径，这条不许顺手拆）。
        XCTAssertEqual(CodeViewFormat.pathTail("/old/machine/checkout/pairs/a.swift",
                                              root: "/old/machine/checkout", keep: 1), "pairs/a.swift")
    }

    // MARK: - ⑥ 失败态与边界：读不到的根、软链、非 git 目录，一律不许静默降级

    func test_unreadableRootThrowsInsteadOfYieldingACleanEmptyReport() async throws {
        let missing = Self.packageRoot.appendingPathComponent(".scratch/r26-coords", isDirectory: true)
            .appendingPathComponent("absent-\(UUID().uuidString)", isDirectory: true)
        do {
            _ = try await FileSystemCodeAnalyzer().analyzeWithCoverage(root: missing, options: .default)
            XCTFail("读不到的被扫根必须出声，不许交出一份看起来正常的空报告")
        } catch {
            XCTAssertTrue(String(describing: error).contains(missing.path),
                          "失败原因里要能看出是哪个根，实得：\(error)")
        }
    }

    func test_symlinkedDirectoryIsNotFollowedAndTheLedgerSaysSo() async throws {
        let roots = try installRoots()
        defer { remove(roots) }
        // 根外再放一对克隆，并从根里挂一条软链接指过去：跟随它就会把根外文件写进坐标。
        let outside = roots.sandbox.appendingPathComponent("outside", isDirectory: true)
        try writePairs(1, into: outside)
        try fm.createSymbolicLink(at: roots.shallow.appendingPathComponent("linked"),
                                 withDestinationURL: outside)

        let outcome = try await FileSystemCodeAnalyzer()
            .analyzeWithCoverage(root: roots.shallow, options: .default)
        let coordinates = outcome.metrics.duplicateBlockCoordinatesOutsideBoard ?? []
        let paths = outcome.metrics.duplicatedBlocks.flatMap { $0.occurrences.map(\.path) } + coordinates
        XCTAssertFalse(paths.isEmpty, "一个坐标都没有 ⇒ 这条用例在空集上永真")
        XCTAssertTrue(paths.allSatisfy { $0.contains("linked/") == false },
                      "被剪掉的软链接子树里的文件长进了坐标里：\(paths.first ?? "")")
        XCTAssertEqual(outcome.metrics.scanSurface?.symbolicLinkDirectoryCount, 1,
                       "根里明明挂了一条目录软链接，台账却读成 0/缺席 ⇒ 静默降级")
    }

    /// 非 git 目录：坐标形状与「是不是仓库」无关（这条链不该依赖 provenance）。
    func test_nonGitTreeStillGivesRelativeCoordinates() async throws {
        let roots = try installRoots()
        defer { remove(roots) }
        XCTAssertFalse(fm.fileExists(atPath: roots.shallow.appendingPathComponent(".git").path),
                       "夹具不该带 .git，否则这条用例测的是仓库")
        let outcome = try await FileSystemCodeAnalyzer()
            .analyzeWithCoverage(root: roots.shallow, options: .default)
        let coordinates = try XCTUnwrap(outcome.metrics.duplicateBlockCoordinatesOutsideBoard)
        XCTAssertFalse(coordinates.isEmpty)
        XCTAssertTrue(coordinates.allSatisfy { $0.hasPrefix("/") == false }, coordinates.first ?? "")
        XCTAssertTrue(outcome.metrics.duplicatedBlocks.allSatisfy { block in
            block.occurrences.allSatisfy { $0.path.hasPrefix("/") == false }
        })
    }

    // MARK: - ⑦ CLI ↔ 进程内：交付二进制落的盘与屏上同一条链同形

    func test_headlessCLIWritesTheSameCoordinatesAsInProcessAnalysis() async throws {
        let roots = try installRoots()
        defer { remove(roots) }
        let inProcess = try await shape(in: roots.shallow)
        let cliShallow = try scanWithProductBinary(roots.shallow, in: roots.sandbox)
        let cliDeep = try scanWithProductBinary(roots.deep, in: roots.sandbox)

        XCTAssertFalse(cliShallow.coordinates.isEmpty, "CLI 那份没有榜外坐标 ⇒ 下面几条比的是两个空集")
        XCTAssertEqual(cliShallow.coordinates, cliDeep.coordinates,
                       "无头那一路落盘的坐标仍随检出目录变 ⇒ 生产点没改到")
        XCTAssertEqual(cliShallow.coordinates, inProcess.result.blocksOutsideBoard,
                       "CLI 与进程内不同形 ⇒ 两条路读数分叉")
        XCTAssertEqual(cliShallow.occurrencePaths, inProcess.occurrencePaths,
                       "CLI 落的 occurrences 与进程内不是同一个形状")
    }

    private struct CLIShape {
        let coordinates: [String]
        let occurrencePaths: [String]
    }

    private func scanWithProductBinary(_ root: URL, in sandbox: URL) throws -> CLIShape {
        let out = sandbox.appendingPathComponent("cli-\(UUID().uuidString).json")
        defer { try? fm.removeItem(at: out) }
        // 子进程的 stdout/stderr **必须落盘而不是塞进 Pipe**：这份夹具的 CLI 报告会打到 stdout，
        // 而没人读的管道一旦填满（约 64 KB）子进程就永远卡在写那一笔上。
        // 这不是假想：S1 sabotage 那一趟（坐标退回绝对）实测就把 `scan` 卡死在 11 分钟，
        // 而卡死点长得像「生产代码挂死」，其实缺的是这一行落盘。
        let log = sandbox.appendingPathComponent("cli-\(UUID().uuidString).log")
        defer { try? fm.removeItem(at: log) }
        FileManager.default.createFile(atPath: log.path, contents: Data())
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try CLIProcessTests.productBinary())
        process.arguments = ["scan", root.path, "--out=" + out.path, "--compact"]
        process.standardOutput = try FileHandle(forWritingTo: log)
        process.standardError = try FileHandle(forWritingTo: log)
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "无头 scan 没跑成（退出码 \(process.terminationStatus)）")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: out)) as? [String: Any]
        let code = try XCTUnwrap(json?["code"] as? [String: Any], "CLI 那份 JSON 里没有 code 段")
        return CLIShape(coordinates: code["duplicateBlockCoordinatesOutsideBoard"] as? [String] ?? [],
                        occurrencePaths: Self.occurrencePaths(from: code))
    }

    static func occurrencePaths(from code: [String: Any]) -> [String] {
        (code["duplicatedBlocks"] as? [[String: Any]] ?? []).flatMap { block in
            (block["occurrences"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
        }
    }
}
