import XCTest
@testable import TcoderMonitor

/// OWNER: WS-X2 RuntimeServices真修。
///
/// 本包（`Services/Logs/**`、`Services/Git/**`、`Services/Dependencies/**`）的
/// **热点函数圈复杂度 / 函数行数 / 文件行数** 只减不增棘轮。
///
/// 尺子不是我自己写的：直接调产品侧的 `SourceTreeScanner` + `ComplexityEngine`，
/// 也就是 Tcoder 给自己打分用的那一把。所以这条门报的数与真机自扫报告同源，
/// 不存在「测试口径比工具松」的空间。
///
/// 阈值写死为字面量，口径来源：
/// - 16 = `SelfScanHarnessCase.complexFunctionBar`（工具报「高复杂度」的那条线）；
/// - 50 = 本轮收口判据「函数 ≤ 50 行」；
/// - 400 = `FileSystemCodeAnalyzer.mediumFileLines`，即工具「巨大文件」口径。
/// **要放宽必须先向总工说明理由。**
///
/// 名单是**点名制**：每个热点函数按 `文件名.函数名` 钉住。
/// 有人把函数改名、或把它挪进别的文件，这里会当场数不到 → 判红，
/// 而不是悄悄变绿（改名逃脱棘轮是这类榜单最容易掉的坑）。
final class LogHotspotRatchetTests: XCTestCase {

    // MARK: - 冻结口径

    /// `SelfScanHarnessCase.complexFunctionBar` 的字面量副本。
    static let complexityBar = 16
    /// 本轮收口判据：单个函数不超过 50 行。
    static let functionLineBar = 50
    /// 工具「巨大文件」口径。
    static let fileLineBar = 400

    /// 真机自扫 2026-09-20 21:01 报给本包的热点，键 = `文件名.函数名`，值 = 报告当时读数。
    /// 报告读数只用于失败信息里说明「这是原来那笔债」，不参与判定。
    ///
    /// `parseAuthorTimestamp` 的键写的是 `GitTimestampParsing` 而不是报告里的
    /// `GitLogParser`：本轮为把该函数 CC 27 降下来，把它连同时间戳段整体搬到了
    /// GitTimestampParsing.swift（仍是 `GitLogParser` 的成员，函数名一字未改）。
    /// 这条门按「文件名.函数名」点名，搬家必须显式改键——**改的是文件归属，
    /// 不是判定阈值**，函数还在榜上、上限仍是 16 与 50。
    static let hotspots: [String: (reportedCC: Int, reportedLines: Int)] = [
        "CrashReportParser.parseDiagnosticReport": (43, 116),
        "GitTimestampParsing.parseAuthorTimestamp": (27, 78),
        "CrashTextParsing.parseTextSegment": (26, 107),
        "ManifestParsersPython.pyprojectDependencies": (26, 78),
        "LogParsing.read": (25, 113),
        "ManifestParsersNative.goModDependencies": (25, 38),
        // R3（2026-09-22 C 组）把 `performOsvLookup` 整块搬进了它的新落点
        // `OsvAnswerAccounting.swift`（OsvClient.swift 已被 400 行口径点死，"没能查到底"的
        // 结构化出口只能另起文件）。**键跟着函数搬家，读数与阈值一字未动**：
        // 这张表是历史"报告点名值"，上限仍是 CC 16 / 50 行，反逃跑的兜底数的是全量函数。
        "OsvAnswerAccounting.performOsvLookup": (21, 65),
    ]

    /// 报告点名之外、本包同一把尺子数出来的其余高复杂度函数，本轮一并清零。
    /// 留这张表是为了让「清零」这件事可核对：名单里任意一个回潮都会撞上面试。
    static let extraHotspotsCleared: Set<String> = [
        "CrashIpsValueReading.flattenASI", "CrashIpsValueReading.ipsFrame",
        "CrashIpsValueReading.stringOrJoined", "GitLogParser.unquotePath",
        "LogClustering.aggregate", "LogClustering.cluster",
        "LogDiscovery.projectLogCandidates", "ManifestDependencyAnalyzer.discoverManifests",
        "ManifestParsers.parse", "ManifestParsers.tokens",
        "ManifestParsersApple.podfileDependencies", "ManifestParsersJava.route",
        "ManifestParsersScripting.gemfileDependencies",
    ]

    /// 本包三个目录（相对 `Sources/TcoderMonitor/`）。
    static let packageDirectories = ["Services/Logs", "Services/Git", "Services/Dependencies"]

    /// 包根（`TcoderMonitor/`）：本文件 → TcoderMonitorTests → Tests → TcoderMonitor。
    static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TcoderMonitorTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // TcoderMonitor
    }

    /// 被扫的那一层是 `Sources/TcoderMonitor/`，**不是包根**：
    /// 少写一段会扫到一个不存在的目录，`enumerator` 直接返回空，
    /// 「巨大文件」那条当场变成一条永真绿守卫（第一版就是这么踩的）。
    static var sourcesRoot: URL { packageRoot.appendingPathComponent("Sources/TcoderMonitor") }

    /// 与 `SelfScanHarnessCase.wcStyleLineCount` 同一把尺子：数换行符，末尾不成行的一段算一行。
    static func wcStyleLineCount(_ text: String) -> Int {
        let newlines = text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        return text.hasSuffix("\n") ? newlines : newlines + 1
    }

    // MARK: - 取证

    struct HotspotReading {
        var file: String
        var name: String
        var complexity: Int
        var lines: Int
    }

    /// 本包每个函数，带它所在的文件名（`ComplexityEngine` 不给文件名，只能在这里挂上）。
    struct ScannedFunction {
        var fileBaseName: String
        var candidate: FunctionCandidate

        var complexity: Int { candidate.complexity }
        var lines: Int { candidate.lineCount }
        var key: String { "\(fileBaseName).\(candidate.name)" }
    }

    /// 用工具自己的引擎把本包每个函数过一遍。
    func packageFunctions() async throws -> [ScannedFunction] {
        let scanner = SourceTreeScanner(options: .default)
        var all: [ScannedFunction] = []
        for directory in Self.packageDirectories {
            let root = Self.sourcesRoot.appendingPathComponent(directory)
            let result = await scanner.scan(root: root)
            XCTAssertFalse(result.files.isEmpty, "扫描 \(directory) 一个文件都没有 = 路径解析静默失效")
            for file in result.files {
                let base = file.url.deletingPathExtension().lastPathComponent
                for candidate in ComplexityEngine.functions(in: file) {
                    all.append(ScannedFunction(fileBaseName: base, candidate: candidate))
                }
            }
        }
        return all
    }

    /// `文件名.函数名` → 该键下**最大**复杂度的那条读数（同名重载取最坏）。
    func readingsByKeys(_ functions: [ScannedFunction]) -> [String: HotspotReading] {
        var best: [String: HotspotReading] = [:]
        for scanned in functions {
            let reading = HotspotReading(file: scanned.fileBaseName, name: scanned.candidate.name,
                                         complexity: scanned.complexity, lines: scanned.lines)
            guard let current = best[scanned.key] else { best[scanned.key] = reading; continue }
            if reading.complexity > current.complexity { best[scanned.key] = reading }
        }
        return best
    }

    func testPackageHotspotFunctionsStayBelowTheComplexityBar() async throws {
        let functions = try await packageFunctions()
        let readings = readingsByKeys(functions)
        // 分母门：本包三个目录实际有几百个函数，数到个位数就说明扫描面塌了。
        XCTAssertGreaterThan(functions.count, 150,
                             "本包只认出 \(functions.count) 个函数，分母异常，热点榜数不到东西不能算通过")

        var lines: [String] = []
        var failures: [String] = []
        for key in Self.hotspots.keys.sorted() {
            let reported = Self.hotspots[key]!
            guard let reading = readings[key] else {
                failures.append("\(key)：本包函数榜里数不到了（被改名或挪出本包，棘轮不能靠它逃脱）")
                continue
            }
            lines.append("  \(key) CC \(reported.reportedCC)→\(reading.complexity) · "
                + "行数 \(reported.reportedLines)→\(reading.lines)")
            if reading.complexity >= Self.complexityBar {
                failures.append("\(key) 圈复杂度 \(reading.complexity) 仍 ≥ \(Self.complexityBar)")
            }
            if reading.lines > Self.functionLineBar {
                failures.append("\(key) 函数 \(reading.lines) 行，仍 > \(Self.functionLineBar)")
            }
        }
        print("【WS-X2 热点前后】\n" + lines.joined(separator: "\n"))
        // 报告点名之外的 13 个：逐个报当前读数，让「本包 CC≥16 已清零」这句话可核对。
        // 反逃跑设计不在这里，在下面那条 strays 面试——它数的是**全量函数**，
        // 改名或搬文件都躲不过，只要还在本包且仍 ≥16 就当场判红。
        var extras: [String] = []
        for key in Self.extraHotspotsCleared.sorted() {
            let base = key.split(separator: ".").last.map(String.init) ?? key
            let found = functions.filter { $0.candidate.name == base }
            let worst = found.map(\.complexity).max()
            extras.append("  \(key) → \(worst.map { "现 CC \($0)" } ?? "本包已无数同名函数")")
        }
        print("【WS-X2 加练热点现状】\n" + extras.joined(separator: "\n"))

        // 兜底：整个包里任何函数都不许新长出 ≥16 的圈复杂度。
        let strays = functions.filter { $0.complexity >= Self.complexityBar }
            .map { "\($0.key) CC\($0.complexity)" }
        XCTAssertTrue(strays.isEmpty, "本包出现名单内外的高复杂度函数：\(Set(strays).sorted().joined(separator: ", "))")
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testPackageFilesStayAtOrBelowFourHundredLines() throws {
        let fm = FileManager.default
        var over: [String] = []
        var roster: [String] = []
        for directory in Self.packageDirectories {
            let root = Self.sourcesRoot.appendingPathComponent(directory)
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let count = Self.wcStyleLineCount(text)
                let relative = url.path.dropFirst(Self.sourcesRoot.path.count + 1)
                roster.append("  \(relative) \(count)")
                if count > Self.fileLineBar { over.append("\(relative) \(count) 行") }
            }
        }
        XCTAssertGreaterThan(roster.count, 20,
                             "分母只有 \(roster.count) 个文件：路径解析静默失效，这条门会永真绿")
        print("【WS-X2 文件行数】分母 \(roster.count) 个文件\n" + roster.sorted().joined(separator: "\n"))
        XCTAssertTrue(over.isEmpty, "仍有巨大文件：\(over.sorted().joined(separator: ", "))")
    }
}
