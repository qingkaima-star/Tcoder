import XCTest
@testable import TcoderMonitor

/// OWNER: WS-J 自食其果。共享取证管道，本身没有 test 方法。
///
/// 为什么单独一个基类而不是全塞进 `SelfScanDogfoodTests`：那个文件本身就是全仓
/// 只减不增棘轮盯着的成员之一——拆它之前先拆自己，不给自己的规则留豁免。
/// 仓库形态门与口径/普查门各成一个类，公共的走树、扫描缓存与 git 真值放这里。
///
/// 成员一律 `internal`（不写 `private`），两个子类靠继承直接复用，调用点不用改。
///
/// 阈值写成**字面量**而不是引用 `FileSystemCodeAnalyzer.highFileLines`：
/// 一旦有人抬高阈值来刷分，超限清单会变小、这些门当场变红。
/// **改这些字面量必须先向总工说明理由。**
class SelfScanHarnessCase: XCTestCase {
    // MARK: - 冻结的复检口径（不得为了变好看而修改）

    /// 工具自己的 `FileSystemCodeAnalyzer.highFileLines`，此处按字面量复检。
    static let toolHighFileLines = 800
    /// "巨大文件" 的常识线：四位数行数的单文件没有任何辩护空间。
    static let thousandLineBar = 1_000
    /// WS-C 报过 "20 个函数圈复杂度 ≥ 16"，按同一口径复检。
    static let complexFunctionBar = 16

    /// 产品侧 `FileSystemCodeAnalyzer.mediumFileLines` 的字面量副本：
    /// "巨大文件占比"这条维度用的就是它，同样只许按字面量复检。
    static let mediumFileLines = 400

    /// 本仓库根：从测试文件自身位置往上三层
    /// （Tests/TcoderMonitorTests/本文件 → TcoderMonitor → 工作树根）。
    /// 用 `#filePath` 而不是硬编码绝对路径：这样主树和各 worktree 都能跑。
    static let repoRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TcoderMonitorTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // TcoderMonitor
            .deletingLastPathComponent()   // 工作树根
    }()

    static let skipDirectoryNames: Set<String> = [
        ".git", ".build", ".swiftpm", "dist", "build", "node_modules", ".worktrees",
    ]

    // MARK: - 一次性扫描缓存（六个分析器都跑一遍，多个测试复用）

    struct SelfScan {
        var code: CodeMetrics
        var git: GitInsights
        var logs: LogSummary
        var dependencies: DependencyReport
        var coverage: CoverageMetrics
        var health: HealthScore
    }

    static let cacheStore = ScanCacheStore()

    /// 用 actor 而不是 NSLock 做缓存门：`NSLock.lock()` 在 async 上下文里不可用。
    actor ScanCacheStore {
        private var cached: SelfScan?

        func value(orMake make: @Sendable () async throws -> SelfScan) async rethrows -> SelfScan {
            if let cached { return cached }
            let fresh = try await make()
            cached = fresh
            return fresh
        }
    }

    func selfScan() async throws -> SelfScan {
        try await Self.cacheStore.value {
            let root = Self.repoRoot
            let code = try await FileSystemCodeAnalyzer().analyze(root: root, options: .default)
            let git = try await ShellGitAnalyzer().analyze(repositoryURL: root)
            let logs = try await FileLogAnalyzer()
                .analyze(projectRoot: root, extraLogURLs: [], withinDays: 30)
            let dependencies = try await ManifestDependencyAnalyzer()
                .analyze(projectRoot: root, allowNetwork: false)
            let coverage = try await CoverageAnalyzer().analyze(projectRoot: root, options: .default)
            let health = WeightedHealthScorer().score(
                HealthInputs(code: code, git: git, logs: logs,
                             dependencies: dependencies, coverage: coverage))

            return SelfScan(code: code, git: git, logs: logs,
                            dependencies: dependencies, coverage: coverage, health: health)
        }
    }

    // MARK: - 独立取证：不依赖任何分析器，自己数行数

    struct GroundTruthFile {
        var path: String
        var lines: Int
    }

    /// 自己走一遍目录树，按换行数数 `.swift` 文件行数。
    /// 与分析器无关，所以分析器漏文件 / 抬阈值都会被这里抓到。
    ///
    /// 手写递归而不是 `enumerator(at:)`：`FileManager.DirectoryEnumerator` 没有
    /// `skipSubtree`，而剪枝必须发生在下潜之前，否则会把 `.build` 整个走一遍。
    /// `wc -l` 口径：数换行符，末尾不成行的一段算一行。
    /// 三个来源（`wc`、分析器的 `lines.count`、这里的独立复检）必须共用这一把尺子，
    /// 所以它只允许有一份——内联副本会在下一次改动里悄悄分叉。
    static func wcStyleLineCount(_ text: String) -> Int {
        let newlines = text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        return text.hasSuffix("\n") ? newlines : newlines + 1
    }

    func independentSwiftLineCounts() throws -> [GroundTruthFile] {
        var result: [GroundTruthFile] = []
        try collectSwiftFiles(in: Self.repoRoot, into: &result)
        return result
    }

    /// #49：工具的"巨大文件榜"按 `SourceLanguageCatalog` 的扩展名表收文件（含 `.md`），
    /// 而上面那把尺子只数 `.swift`。两把尺子量的不是同一个总体，于是
    /// 任何一份超过 800 行的文档都会让"独立复检数不到"判红——今天就是
    /// `docs/使用说明.md` 涨到 819 行时现形的。
    /// 这条按**目录本身**判定归属，绝不另抄一份扩展名清单（一抄就会再次漂移）。
    static func isToolScannedExtension(_ ext: String) -> Bool {
        SourceLanguageCatalog.language(forExtension: ext) != nil
    }

    /// 与分析器同一总体的独立复检：凡是被 `SourceLanguageCatalog` 认作源码的扩展名都数。
    func independentSourceLineCounts() throws -> [GroundTruthFile] {
        var result: [GroundTruthFile] = []
        try collectSourceFiles(in: Self.repoRoot, into: &result)
        return result
    }

    func collectSourceFiles(in directory: URL, into result: inout [GroundTruthFile]) throws {
        let fm = FileManager.default
        let children = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        for url in children.sorted(by: { $0.path < $1.path }) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values.isDirectory == true {
                guard !Self.skipDirectoryNames.contains(url.lastPathComponent) else { continue }
                try collectSourceFiles(in: url, into: &result)
                continue
            }
            guard values.isRegularFile == true,
                  Self.isToolScannedExtension(url.pathExtension.lowercased()) else { continue }
            guard let data = fm.contents(atPath: url.path),
                  let text = String(data: data, encoding: .utf8) else { continue }
            result.append(GroundTruthFile(path: url.path, lines: Self.wcStyleLineCount(text)))
        }
    }

    func collectSwiftFiles(in directory: URL, into result: inout [GroundTruthFile]) throws {
        let fm = FileManager.default
        let children = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        for url in children.sorted(by: { $0.path < $1.path }) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values.isDirectory == true {
                guard !Self.skipDirectoryNames.contains(url.lastPathComponent) else { continue }
                try collectSwiftFiles(in: url, into: &result)
                continue
            }
            guard values.isRegularFile == true, url.pathExtension == "swift" else { continue }
            guard let data = fm.contents(atPath: url.path),
                  let text = String(data: data, encoding: .utf8) else { continue }
            // 行数按 `wc -l` 的口径数换行符，末尾不成行的一段算一行；
            // 这样三个来源（wc、分析器的 lines.count、这里）能对上同一个数。
            // 早先用 components(separatedBy:"\n").count 会整体 +1，
            // 因为结尾换行会多出一个空段——差 1 行看起来就像两边在量不同的文件。
            result.append(GroundTruthFile(path: url.path, lines: Self.wcStyleLineCount(text)))
        }
    }

    // MARK: - 独立复核：绕开 top-20 截断，数全量函数

    struct ComplexityCensus {
        var functionCount: Int
        var repoMean: Double
        var atLeast16: Int
        var atLeast21: Int
        var atLeast31: Int
        var maxValue: Int
        var hotspotMean: Double
    }

    /// 自己调 `ComplexityEngine` 把**全仓每个函数**过一遍。
    /// 这是为了复核一句要进汇报的话："20 个函数圈复杂度 ≥ 16"。
    /// `topComplexFunctions` 被 `prefix(20)` 截断过，所以它的条数既可能是巧合，
    /// 也可能是"只数了榜单"——只有去截断之外数才知道。
    func complexityCensus() async throws -> ComplexityCensus {
        let files = await SourceTreeScanner(options: .default).scan(root: Self.repoRoot).files
        let all = files.map { ComplexityEngine.functions(in: $0) }.flatMap { $0 }
        let complexities = all.map(\.complexity)
        let sum = complexities.reduce(0, +)
        let hotspots = all.filter { $0.complexity >= Self.complexFunctionBar }
            .sorted { $0.complexity > $1.complexity }
            .prefix(20)
            .map(\.complexity)
        return ComplexityCensus(
            functionCount: all.count,
            repoMean: all.isEmpty ? 0 : Double(sum) / Double(all.count),
            atLeast16: complexities.filter { $0 >= 16 }.count,
            atLeast21: complexities.filter { $0 >= 21 }.count,
            atLeast31: complexities.filter { $0 >= 31 }.count,
            maxValue: complexities.max() ?? 0,
            hotspotMean: hotspots.isEmpty ? 0 : Double(hotspots.reduce(0, +)) / Double(hotspots.count)
        )
    }

    // MARK: - 复杂度引擎口径探针（最小可复现夹具，建在 /tmp 下用完即删）

    /// 5 个函数，每个只含一种语法。手算期望：plain=1、oneIf=2、nilCoalesce=2、
    /// failableCast=4、oneTernary=2 → 合计 11，均值 11÷5=2.2。
    static let probeFixture = #"""
        import Foundation
        func plain() -> Int {
            return 1
        }
        func oneIf(_ flag: Bool) -> Int {
            if flag { return 2 }
            return 1
        }
        func oneNilCoalesce(_ dict: [String: Int]) -> Int {
            return dict["k"] ?? 0
        }
        func failableCast(_ raw: Any) -> Int {
            let box = raw as? [String: Int]
            return box?.count ?? 0
        }
        func oneTernary(_ flag: Bool) -> Int {
            return flag ? 1 : 2
        }
        """#

    /// 把那份夹具写到 /tmp（AGENTS.md 允许的临时夹具位置）下，返回目录。
    /// 先整目录删掉再建，保证"这里只有 5 个函数"这个手算前提不被上一轮污染。
    func makeComplexityProbeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tcoder-wsj-cc-probe", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.probeFixture.write(to: dir.appendingPathComponent("Probe.swift"),
                                    atomically: true, encoding: .utf8)
        return dir
    }

    /// 从评分 detail 里解析"平均圈复杂度 X"的那个数，**连带它写出来的原文**——
    /// 原文里有没有小数点决定我们允许多大的比对容差。
    /// 这样实现方爱保留几位就保留几位，测试只管"这个数是不是全仓均值"。
    func reportedRepoMean(in detail: String) -> (value: Double, text: String)? {
        let pattern = "平均圈复杂度\\s*([0-9]+(?:\\.[0-9]+)?)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: detail, range: NSRange(detail.startIndex..., in: detail)),
              match.numberOfRanges >= 2,
              let captured = Range(match.range(at: 1), in: detail),
              let value = Double(detail[captured]) else { return nil }
        return (value, String(detail[captured]))
    }

    // MARK: - 超限文件归人（只用于失败信息，不参与判定）

    /// 总工 2026-09-19 派给 WS-V 拆的测试文件名单。
    static let splitByWSV: Set<String> = [
        "ManifestLabFixtureTests.swift", "HealthScoreTests.swift",
        "LogAnalysisTests.swift", "GitDependencyTests.swift",
    ]

    /// `AGENTS.md` §7 扩充流表里**按文件名**指派（不是 glob）的归属。
    static let namedTestOwners: [String: String] = [
        "ManifestLabFixtureTests.swift": "WS-F（§7 扩充流表点名）",
        "DesignTokenTests.swift": "WS-G（§7 扩充流表点名）",
        "SelfScanHarness.swift": "WS-J（本流）",
        "SelfScanDogfoodTests.swift": "WS-J（本流）",
        "SelfScanConventionGates.swift": "WS-J（本流）",
        "SelfScanCoverageRegressionTests.swift": "WS-J（本流）",
        "RealRepositoryEvidenceTests.swift": "总工（§3 记名）",
        "CoverageAnalyzerTests.swift": "总工（§3 记名）",
    ]

    // MARK: - git 独立基线（只读命令）

    /// `git rev-list --count HEAD`，可带 `--no-merges` / `--merges` 取不同口径。
    func revListCount(_ filter: [String]) throws -> Int {
        let output = try runGit(["rev-list", "--count"] + filter + ["HEAD"])
        guard let count = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw AnalysisError.empty("git rev-list --count \(filter) 输出不可解析：\(output)")
        }
        return count
    }

    /// 按**作者邮箱**独立算最大作者占比：`%aE` + `--no-merges`，与分析器同口径。
    /// 刻意不用 `git shortlog -sn`——那个按**姓名**分组，而本仓库有两个姓名
    /// （`Tcoder Team` 与 `WS-B Git与依赖`）共用 `dev@tcoder.local`。
    /// 用姓名口径量出来的 top 是 68%，工具按邮箱归并给的是 72%，
    /// 差 4 个点会被 5 个点的容差吞掉——等于这条门白设。
    func independentTopAuthorShare() throws -> Double {
        let output = try runGit(["log", "--no-merges", "--format=%aE", "HEAD"])
        var counts: [String: Int] = [:]
        for line in output.split(separator: "\n") {
            let email = line.trimmingCharacters(in: .whitespaces)
            guard !email.isEmpty else { continue }
            counts[email, default: 0] += 1
        }
        guard let top = counts.values.max(), !counts.isEmpty else { return 0 }
        return Double(top) / Double(counts.values.reduce(0, +))
    }

    func runGit(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", Self.repoRoot.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
