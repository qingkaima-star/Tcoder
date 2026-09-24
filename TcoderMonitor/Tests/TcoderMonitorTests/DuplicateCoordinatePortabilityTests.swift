import Foundation
import XCTest
@testable import TcoderMonitor

/// OWNER: WS-R26（RD-61 第二半）—— 重复块坐标改成**相对被扫根**，并且要证明它还能用。
///
/// ## 立案事实（在 `b567a7b` 上实读原文，不是推测）
/// 坐标的唯一生产点 `DuplicationScanState.fragmentOf` 给的是 `files[i].url.path`（绝对），
/// 而 `ScannedSourceFile` 本来就带着 `SourceFileClassifier.relativePath(for:root:)` 算好的相对路径。
/// 后果三条，一条比一条坏：
/// 1. `DuplicatedBlock.id` 由 `occurrences` 的路径排序拼成 ⇒ **块身份里嵌着检出目录**：
///    同一段克隆在两台机器 / 两个 worktree 下有两个 id，RD-52 承诺的「可点名、可 diff」不成立。
/// 2. 榜外坐标那 6 条样本会进 `scanLimitations` 与落盘字段 ⇒ 一条上限说明的长度随仓库放在哪变
///    （台账卷三 §6.51.2 实测同一条 ≤1,200 字符的门：主树 1,060、`.worktrees/r21-backlog` 1,244）。
/// 3. 屏上、JSON、句子三处读者读的是同一个 `occurrences`，绝对形状等于让每处各自猜一遍前缀。
///
/// ## 两个消费点为什么必须同批看（改坏了就是功能坏）
/// `CodeRiskRows.reveal`（Finder 定位）与 `CodeOpenFileButton`（默认应用打开）都要能开出文件。
/// 实读结论：两处**本来**都走 `CodeViewFormat.resolvedURL(_:root:)`，而它有一条
/// 「不以 `/` 开头 ⇒ 按 root 拼回去」的分支 —— 所以还原入口已经只有一个，不需要新加字段。
/// 第 ③ 组用例就是在盘上证明它拼得对：两棵不同深度的根上，坐标都指向**同一个真实文件**，
/// 而且那份内容逐字节等于本文件自己写进去的夹具正文。
///
/// ## 保留的边界（这轮不顺手抹掉的东西）
/// · 巨大文件榜与复杂度热点榜**仍然**给绝对 `url.path`（那是别的链），所以
///   `CodeViewFormat.relativePath` / `pathTail` 的剥前缀与 `resolvedURL` 的绝对分支都还有真读者；
/// · `maxBlocks`、`outsideBoardSampleLimit`、≤1,200 那条长度门一字未动；
/// · 改前落盘的旧报告里那批绝对坐标不改写、不判败（第 ⑤ 组）。
///
/// 夹具落本树 `.scratch/`（已 gitignore、被自扫剪枝，AGENTS §1.6），即建即删。
final class DuplicateCoordinatePortabilityTests: XCTestCase {

    private var fm: FileManager { FileManager.default }

    /// 造 26 对 ⇒ 榜单（20 格）一定被截过，榜外坐标才有东西可点名。
    private static let pairCount = 26

    /// 一对逐字拷贝：12 行，正文里带 index 的字面量 ⇒「这条坐标说的是第几对」能从盘上读出来。
    private func pairBody(_ index: Int) -> String {
        """
        func probe\(index)(input: Int) -> Int {
            var total = 0
            var step = input + \(index)
            while step > 0 {
                total = total + step * 3
                step = step - 7
            }
            if total > 997 { total = total - 997 }
            let scaled = total * \(index + 2)
            return scaled + probeSeed
        }
        let probeSeed = 0
        """
    }

    private func write(_ text: String, to relative: String, in root: URL) throws {
        let url = root.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func writePairs(_ count: Int, into root: URL) throws {
        for index in 0..<count {
            let body = pairBody(index) + "\n"
            let tag = String(format: "%02d", index)
            try write(body, to: "pairs/pair_\(tag)_a.swift", in: root)
            try write(body, to: "pairs/pair_\(tag)_b.swift", in: root)
        }
    }

    // MARK: - 两棵深浅不同的临时根

    struct Roots {
        let sandbox: URL
        let shallow: URL
        let deep: URL
    }

    /// 浅根 `…/a` 与深根 `…/very/deep/inner/path/a`：**里面的相对布局逐字相同**，
    /// 只有各自的根差 20 来个字符 —— 这正是改前会把坐标撑开的量纲。
    private func installRoots() throws -> Roots {
        let sandbox = Self.packageRoot.appendingPathComponent(".scratch/r26-coords", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let shallow = sandbox.appendingPathComponent("a", isDirectory: true)
        let deep = sandbox.appendingPathComponent("very/deep/inner/path/a", isDirectory: true)
        try writePairs(Self.pairCount, into: shallow)
        try writePairs(Self.pairCount, into: deep)
        XCTAssertGreaterThan(deep.path.count - shallow.path.count, 15,
                             "两棵根的深度差不够 ⇒ 测不到「根前缀长度」这个量纲")
        return Roots(sandbox: sandbox, shallow: shallow, deep: deep)
    }

    private func remove(_ roots: Roots) { try? fm.removeItem(at: roots.sandbox) }

    private static let packageRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // TcoderMonitorTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // TcoderMonitor（包根，`.scratch/` 在它下面）

    /// 工作树根（与自扫那族同一个取法）：第 ④ 组要在真源码上复量不变式。
    private static let checkoutRoot: URL = packageRoot.deletingLastPathComponent()

    // MARK: - ① 正例 + 反例：坐标与块身份在两棵不同深度的根上完全相等

    func test_coordinatesAndBlockIDsAreIdenticalAcrossTwoRootDepths() async throws {
        let roots = try installRoots()
        defer { remove(roots) }
        let left = try await shape(in: roots.shallow)
        let right = try await shape(in: roots.deep)

        // 前提：榜真的被截过，否则「坐标相等」是在空集上成立（本仓点过名的那族假绿）。
        XCTAssertGreaterThan(left.result.blocksDroppedByCap, 0, "夹具没造成截断 ⇒ 这条用例是永真绿")
        XCTAssertEqual(left.result.blocksOutsideBoard.count, DuplicationScan.outsideBoardSampleLimit)
        XCTAssertFalse(left.occurrencePaths.isEmpty)

        XCTAssertEqual(left.result.blocksOutsideBoard, right.result.blocksOutsideBoard,
                       "同一批榜外块在两棵不同深度的根上给出不同坐标 ⇒ 身份里还混着检出目录")
        XCTAssertEqual(left.ids, right.ids, "DuplicatedBlock.id 随根变 ⇒ 换台机器求不出交集")
        XCTAssertEqual(left.occurrencePaths, right.occurrencePaths)
        XCTAssertTrue(left.occurrencePaths.allSatisfy { $0.hasPrefix("/") == false },
                      "坐标里出现了绝对形状：\(left.occurrencePaths.first ?? "")")

        // 反例：把改前那一步（拿 `url.path` 拼 id）在同一次扫描上重演 ⇒ 它必然不等。
        let oldLeft = legacyIDs(left, root: roots.shallow)
        let oldRight = legacyIDs(right, root: roots.deep)
        XCTAssertNotEqual(oldLeft, oldRight, "绝对形状本来就不随根变 ⇒ 这条立案是假的")
        XCTAssertTrue(oldLeft.joined().contains(roots.shallow.path),
                      "反例里该看到浅根的绝对前缀：\(oldLeft.first ?? "")")
        XCTAssertFalse(left.ids.joined().contains(roots.shallow.path),
                       "改后的身份串里还看得到根 ⇒ 生产点没改干净")
    }

    private struct Shape {
        let result: DuplicationResult
        let files: [ScannedSourceFile]
        var ids: [String] { result.blocks.map(\.id) + result.blocksOutsideBoard }
        var occurrencePaths: [String] { result.blocks.flatMap { $0.occurrences.map(\.path) } }
    }

    private func shape(in root: URL) async throws -> Shape {
        let scan = await SourceTreeScanner(options: .default).scan(root: root)
        XCTAssertEqual(scan.files.count, Self.pairCount * 2, "夹具没按预期落盘，后面的数字都无意义")
        return Shape(result: DuplicationEngine.analyze(scan.files), files: scan.files)
    }

    /// 改前形状的**复现**：与 `DuplicatedBlock.id` 同一公式，只把坐标换成 `url.path`。
    /// 它住在测试里而不是留在生产代码里，是为了让「改前必然不等」这句话可复跑，
    /// 而不是靠一次 git 差异口头承诺。
    private func legacyIDs(_ shape: Shape, root: URL) -> [String] {
        var absolute: [String: String] = [:]
        for file in shape.files where absolute[file.relativePath] == nil {
            absolute[file.relativePath] = file.url.path
        }
        XCTAssertFalse(absolute.isEmpty)
        return shape.result.blocks.map { block in
            block.occurrences.map { absolute[$0.path] ?? root.path + "/" + $0.path }.sorted()
                .joined(separator: "|") + ":\(block.lineCount)"
        }
    }

    // MARK: - ② 正例：最长那条限制说明在两棵树上逐字节等长

    func test_longestLimitationSentenceIsByteIdenticalAcrossTwoRootDepths() async throws {
        let roots = try installRoots()
        defer { remove(roots) }
        let left = try await productSentence(in: roots.shallow)
        let right = try await productSentence(in: roots.deep)

        XCTAssertEqual(left.text, right.text,
                       "同一段内容换个检出目录就拼出不同的一句 ⇒ 那条长度门随盘变")
        XCTAssertEqual(left.text.count, right.text.count, "逐字节相等而字符数不等 ⇒ 量纲先说清")
        // 这条门本身（≤1,200 是 RD-61 立的判据，此处一字未动，只换掉被量的那一串）。
        XCTAssertLessThan(left.text.count, 1_200, "改后仍撑破长度门：\(left.text.count) 字符")

        // 反例：把各自的前缀塞回同一句 ⇒ 两句立刻分叉，且深的那句明显更长。
        let oldLeft = left.text.replacingOccurrences(of: "pairs/", with: left.root.path + "/pairs/")
        let oldRight = right.text.replacingOccurrences(of: "pairs/", with: right.root.path + "/pairs/")
        XCTAssertNotEqual(oldLeft, oldRight, "旧形状本来不随根变 ⇒ 反例造错了")
        XCTAssertGreaterThan(oldRight.count - oldLeft.count, 60,
                             "两棵树的旧形状长度差不到 60 字符（\(oldLeft.count) vs \(oldRight.count)）")
    }

    private struct Sentence {
        let text: String
        let root: URL
    }

    /// 走**产品路径**（`analyzeWithCoverage`）拿能上屏的那份账，而不是只调引擎。
    private func productSentence(in root: URL) async throws -> Sentence {
        let outcome = try await FileSystemCodeAnalyzer().analyzeWithCoverage(root: root, options: .default)
        let coordinates = try XCTUnwrap(outcome.metrics.duplicateBlockCoordinatesOutsideBoard,
                                        "榜外有块 ⇒ 落盘坐标这一格不许缺席")
        XCTAssertFalse(coordinates.isEmpty)
        XCTAssertTrue(coordinates.allSatisfy { $0.hasPrefix("/") == false },
                      "落盘坐标里出现绝对路径：\(coordinates.first ?? "")")
        let limits = try XCTUnwrap(outcome.metrics.scanLimitations, "限制账整份缺席")
        let line = try XCTUnwrap(limits.first { $0.contains("榜外坐标") },
                                 "点名榜外坐标的那句不在账里 ⇒ 生产者措辞改了，这条判据在空转")
        XCTAssertEqual(limits.max(by: { $0.count < $1.count }), line,
                       "点名榜外坐标的那句不是最长那条 ⇒ 这里量的不是长度门盯的东西")
        return Sentence(text: line, root: root)
    }

    // MARK: - ③ 消费点：两棵树上 reveal / 打开按钮都指向同一个真实文件

    func test_revealAndOpenButtonResolveToTheSameRealFileOnBothRoots() async throws {
        let roots = try installRoots()
        defer { remove(roots) }
        let left = try await shape(in: roots.shallow)
        let right = try await shape(in: roots.deep)
        let twins = right.result.blocks.flatMap(\.occurrences)
        XCTAssertEqual(left.result.blocks.flatMap(\.occurrences).count, twins.count)

        var checked = 0
        for (offset, occurrence) in left.result.blocks.flatMap(\.occurrences).enumerated() {
            let twin = twins[offset]
            let leftURL = CodeViewFormat.resolvedURL(occurrence.path, root: roots.shallow.path)
            let rightURL = CodeViewFormat.resolvedURL(twin.path, root: roots.deep.path)
            XCTAssertTrue(fm.fileExists(atPath: leftURL.path),
                          "坐标 \(occurrence.path) 拼回浅根之后盘上没有这个文件")
            XCTAssertTrue(fm.fileExists(atPath: rightURL.path),
                          "坐标 \(twin.path) 拼回深根之后盘上没有这个文件")
            // 独立真值：坐标自己声称是哪一对，打开的文件就必须逐字节等于本文件写进去的那一段。
            let index = try XCTUnwrap(Self.pairIndex(of: occurrence.path), "坐标名里读不出对号：\(occurrence.path)")
            XCTAssertEqual(try String(contentsOf: leftURL, encoding: .utf8), pairBody(index) + "\n",
                           "坐标 \(occurrence.path) 打开的不是它声称的那一对")
            XCTAssertEqual(try String(contentsOf: rightURL, encoding: .utf8),
                           try String(contentsOf: leftURL, encoding: .utf8),
                           "两条坐标指向了两份不同内容 ⇒ 换检出目录改变了被打开的东西")
            let line = try XCTUnwrap(Self.lineNumber(of: leftURL, at: occurrence.startLine),
                                     "坐标 \(occurrence.path):\(occurrence.startLine) 指到了文件外面")
            XCTAssertTrue(line.isEmpty == false, "行号指到了空行上：\(occurrence.path)")
            checked += 1
        }
        XCTAssertEqual(checked, twins.count, "有一条坐标没验完 ⇒ 分母不对，这条用例不作数")
        XCTAssertGreaterThanOrEqual(checked, 20, "验的条数太少，覆盖不到榜内的形状：\(checked)")
    }

    /// `pairs/pair_07_a.swift` → 7；读不出对号返回 nil（调用方判红，不静默放过）。
    static func pairIndex(of coordinate: String) -> Int? {
        let name = coordinate.split(separator: "/").last.map(String.init) ?? coordinate
        guard name.hasPrefix("pair_"), name.hasSuffix(".swift") else { return nil }
        let digits = name.dropFirst("pair_".count).prefix(2)
        return Int(digits)
    }

    static func lineNumber(of url: URL, at startLine: Int) throws -> String? {
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n",
                                                                     omittingEmptySubsequences: false)
        guard startLine >= 1, startLine <= lines.count else { return nil }
        return String(lines[startLine - 1]).trimmingCharacters(in: .whitespaces)
    }

    /// 视图层与还原入口：同一条相对坐标在两棵树上给出同一串文本，且 `resolvedURL` 拼得对。
    func test_displayRowsAndRestoreEntryAgreeOnRelativeShape() throws {
        let block = DuplicatedBlock(occurrences: [
            DuplicatedFragment(path: "pairs/pair_00_a.swift", startLine: 4),
            DuplicatedFragment(path: "pairs/pair_00_b.swift", startLine: 4),
        ], lineCount: 11, similarity: 1)
        let shallow = CodeDuplicationBlockRow.occurrenceLines(block, root: "/tmp/a")
        let deep = CodeDuplicationBlockRow.occurrenceLines(block, root: "/tmp/very/deep/inner/path/a")
        XCTAssertEqual(shallow.map(\.text), deep.map(\.text), "单格文本随根深度变 ⇒ 展示层还在猜前缀")
        XCTAssertEqual(shallow.compactMap(\.help), deep.compactMap(\.help), "回读出口随根深度变")
        XCTAssertEqual(CodeViewFormat.resolvedURL("pairs/pair_00_a.swift", root: "/tmp/a").path,
                       "/tmp/a/pairs/pair_00_a.swift", "相对坐标的唯一还原入口必须拼回真实路径")
    }

    // MARK: - ④ 守卫本体两个方向（双向元测试）+ 真源码上的不变式

    func test_coordinateGuardReturnsRelativeOnlyForAGenuinePrefixStrip() throws {
        let url = URL(fileURLWithPath: "/scan/root/packages/app/File.swift")
        XCTAssertEqual(scannedFile(url: url, relativePath: "packages/app/File.swift").duplicationCoordinate,
                       "packages/app/File.swift", "真后缀剥离却被退回绝对 ⇒ 屏上又会长出检出目录")
        // 反方向：坐标根本不是这个 url 的后缀（口径漂移 / 手工构造）⇒ 必须退回绝对而不是硬给相对。
        XCTAssertEqual(scannedFile(url: url, relativePath: "elsewhere/Other.swift").duplicationCoordinate,
                       url.path, "这种形状拼回任何根之后都会指到别的文件上")
        XCTAssertEqual(scannedFile(url: url, relativePath: "").duplicationCoordinate, url.path,
                       "空坐标串不许当成「相对根」")
    }

    private func scannedFile(url: URL, relativePath: String) -> ScannedSourceFile {
        ScannedSourceFile(url: url, relativePath: relativePath, language: "Swift", lines: [],
                          blankLineCount: 0, commentLineCount: 0, codeLineCount: 0,
                          todoCount: 0, fixmeCount: 0)
    }

    /// 产品路径上这条不变式真的成立：扫本仓自己的源码树逐文件复量
    /// 「坐标 = 一次真后缀剥离、且不带根前缀」。分母 > 0，否则判据空转。
    func test_realRepositoryCoordinatesAreAllGenuineStrips() async throws {
        let files = await SourceTreeScanner(options: .default).scan(root: Self.checkoutRoot).files
        XCTAssertGreaterThan(files.count, 100, "本仓扫描面小到这个分母不作数：\(files.count)")
        let offenders = files.filter { file in
            file.duplicationCoordinate != file.relativePath
                || file.url.path.hasSuffix("/" + file.relativePath) == false
                || file.relativePath.hasPrefix("/")
        }
        XCTAssertTrue(offenders.isEmpty,
                      "\(offenders.count)/\(files.count) 个文件的坐标不是真后缀剥离：\(offenders.first?.url.path ?? "")")
    }

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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try CLIProcessTests.productBinary())
        process.arguments = ["scan", root.path, "--out=" + out.path, "--compact"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
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
