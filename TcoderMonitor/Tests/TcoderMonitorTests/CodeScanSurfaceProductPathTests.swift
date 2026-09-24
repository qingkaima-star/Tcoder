import Foundation
import XCTest
@testable import TcoderMonitor

/// OWNER: WS-R17（RD-15 · 申请单 R6 §3）。落盘那一族读数的**三态渲染、反例、读者点名、结构守卫**。
///
/// 语料与手写账住在 `CodeScanSurfaceContractTests.swift` 的 `CodeScanSurfaceFixture`（一份，不复制）。
/// 本文件三个类共 9 例：`CodeScanSurfaceReadoutTests` 5 例、`CodeScanSurfaceGuardTests` 2 例、
/// `CodeScanSurfaceProductPathTests` 2 例。按类名 filter 时请**三类都跑**。
///
/// ⚠️ 拆成两个文件是 Tests 侧 400 行闸门（`X3TestSizeAuditTests`，与 Sources 同口径）逼的，
/// 不是藏断言：判据、真值、反例一条没少。

// MARK: - ① 三态渲染与反例

final class CodeScanSurfaceReadoutTests: XCTestCase {

    private func metricsOf(_ surface: CodeScanScope?) -> CodeMetrics {
        var metrics = CodeMetrics()
        metrics.scanSurface = surface
        return metrics
    }

    private func report(_ metrics: CodeMetrics) -> ProjectReport {
        var full = ProjectReport(project: MonitoredProject(name: "r17夹具", path: "/scratch/r17"))
        full.code = metrics
        return full
    }

    private func rendered(_ surface: CodeScanScope?) -> String {
        CodeScanSurfaceReadout.accountingLines(metricsOf(surface)).joined(separator: "\n")
    }

    /// 母判据：`linesCounted == false` 时那一格必须为 nil，且渲染出的中文与"量到的 0 行"永远不同。
    func testMeasuredZeroAndNotCountedNeverRenderTheSameWords() async throws {
        let root = try r17Corpus(tag: "threestate")
        try CodeScanSurfaceFixture.build(in: root)
        let metrics = try await FileSystemCodeAnalyzer()
            .analyzeWithCoverage(root: root, options: .default).metrics
        let product = try XCTUnwrap(metrics.scanSurface)
        XCTAssertEqual(product.linesCounted, false)
        XCTAssertNil(product.excludedLineCount)
        let blind = CodeScanSurfaceReadout.accountingLines(metricsOf(product)).joined(separator: "\n")
        XCTAssertTrue(blind.contains("行数未统计"), "没数过就得写没数过：\n\(blind)")
        var counted = product
        counted.linesCounted = true
        counted.excludedLineCount = 0
        let countedText = rendered(counted)
        XCTAssertTrue(countedText.contains("0 行"), "量到的 0 必须读得出 0：\n\(countedText)")
        XCTAssertNotEqual(blind, countedText, "两种读数渲染出一样的话，等于把它们压回一态")
    }

    /// `scanSurface == nil`（旧报告 / 这一路没跑）⇒ 只能是一句缺席话，绝不许长成"排除了 0 个"。
    func testAbsentSurfaceRendersAbsenceRatherThanZeroExclusions() {
        let lines = CodeScanSurfaceReadout.accountingLines(metricsOf(nil))
        XCTAssertEqual(lines.count, 1, "缺席那一档必须出声，沉默会被读成无需交代")
        XCTAssertTrue(lines[0].contains("没有范围台账"), lines[0])
        XCTAssertFalse(lines[0].contains("排除了 0"), "缺席不许长成一个具体的排除数：\(lines[0])")
        var noTotal = CodeScanScope()
        noTotal.displayedCount = 0
        noTotal.undisplayedCount = 0
        XCTAssertTrue(CodeScanSurfaceReadout.accountingLines(metricsOf(noTotal))
                        .allSatisfy { $0.contains("没有范围台账") },
                      "顶格缺席与整枚缺席同属「没有台账」那一态，不许按 0 装配")
    }

    /// 一次干净的扫描：每一格都是量到的 0 ⇒ 一个字都不许多（常驻的"范围说明"等于把噪声当诚实）。
    func testCleanScanStaysCompletelySilent() async throws {
        let root = try r17Corpus(tag: "clean")
        try CodeScanSurfaceFixture.write(CodeScanSurfaceFixture.body(2), to: "src/Only.swift", in: root)
        let metrics = try await FileSystemCodeAnalyzer()
            .analyzeWithCoverage(root: root, options: .default).metrics
        let surface = try XCTUnwrap(metrics.scanSurface)
        XCTAssertEqual(surface.totalCount, 1, "量到了 1 个条目")
        XCTAssertEqual(surface.displayedCount, 0)
        XCTAssertEqual(surface.undisplayedCount, 0)
        XCTAssertEqual(surface.unmeasuredScope, [], "空数组 = 看完了，与 nil 是两件事")
        XCTAssertEqual(CodeScanSurfaceReadout.accountingLines(metricsOf(surface)), [], "干净的扫描一个字都不许多")
    }

    /// 三条反例，各自说明抓得住什么。
    func testCounterfeitsAreAllVisibleFromTheFieldPairing() throws {
        // 反例一：拿 `unmeasuredScope = []` 冒充"看完了"，却同时承认排除了 9 条。
        // 抓得住的形状是"两句并存"：读者一眼能看到「排除 9 个」与「没量到的范围 0 条」同屏矛盾，
        // 而写者侧给不出这个组合（真被剪过子树的语料必然非空，见 contract 那一例）。
        let underreported = CodeScanScope(totalCount: 22, displayedCount: 9, undisplayedCount: 0,
                                          unmeasuredScope: [], linesCounted: false)
        let one = rendered(underreported)
        XCTAssertTrue(one.contains("按规则排除 9 个") && one.contains("没量到的范围 0 条"),
                      "造假组合必须原样摆出来给人看见：\n\(one)")
        // 反例二：`linesCounted = true` 与 `excludedLineCount = nil` 拼在一起。
        // 抓得住：渲染只认那一格读数，矛盾组合不许产出一个具体行数。
        var contradictory = underreported
        contradictory.unmeasuredScope = ["13 个被剔除条目的行数未统计"]
        contradictory.linesCounted = true
        let two = rendered(contradictory)
        XCTAssertTrue(two.contains("行数未统计"), "矛盾组合被读成具体行数就是「把没数当真数」：\n\(two)")
        XCTAssertFalse(two.contains("0 行"), "这种组合不许产出行数：\n\(two)")
        // 反例三：把 nil 一律补成 0（0 与"没量到"是两个读数）。
        // 抓得住：除这六格之外两份台账一模一样，渲染必须不同 —— 补 0 之后占位符全部消失。
        let nilHalf = CodeScanScope(totalCount: 22, displayedCount: 9, undisplayedCount: 0,
                                    unmeasuredScope: ["2 条"], linesCounted: false)
        var countedHalf = nilHalf
        countedHalf.nestedRepositoryCount = 0
        countedHalf.submoduleMarkerCount = 0
        countedHalf.symbolicLinkFileCount = 0
        countedHalf.symbolicLinkDirectoryCount = 0
        countedHalf.unlistedPrunedDirectoryCount = 0
        countedHalf.unreadableDirectoryCount = 0
        let three = rendered(nilHalf), four = rendered(countedHalf)
        XCTAssertNotEqual(three, four, "「没记」与「记了是 0」渲染成同一句话，就等于压回一态")
        XCTAssertTrue(three.contains(Theme.Placeholder.missingValue), "没量的格子必须留占位：\n\(three)")
        XCTAssertTrue(four.contains("0 个"), "量到的 0 要读得出 0：\n\(four)")
        XCTAssertFalse(four.contains(Theme.Placeholder.missingValue),
                       "补齐成 0 之后占位符消失 ⇒ 这份报告看起来什么都量过了：\n\(four)")
    }

    /// 读者 (a)：CLI `score` 文本里那一行的数字**来自字段**，且排在分数之前。
    func testScoreTextCarriesTheNumbersThatComeFromTheFields() async throws {
        let root = try r17Corpus(tag: "cli")
        try CodeScanSurfaceFixture.build(in: root)
        let metrics = try await FileSystemCodeAnalyzer()
            .analyzeWithCoverage(root: root, options: .default).metrics
        let surface = try XCTUnwrap(metrics.scanSurface)
        let text = CLIScoreText.render(report(metrics), exit: .ok)
        XCTAssertTrue(text.contains("扫描范围台账：遍历看到 \(NumberFormat.grouped(surface.totalCount ?? -1)) 个条目"),
                      "CLI 那一行的条目数不是从字段来的：\n\(text)")
        XCTAssertTrue(text.contains("读不动的目录 0 个"), "接手点名要的那格必须上屏：\n\(text)")
        let lines = text.components(separatedBy: "\n")
        let surfaceAt = lines.firstIndex { $0.hasPrefix("扫描范围台账") }
        let verdictAt = lines.firstIndex { $0.hasPrefix("综合健康分") || $0.hasPrefix("没有评分结果") }
        XCTAssertNotNil(surfaceAt, "整段没上屏：\n\(text)")
        if let surfaceAt, let verdictAt { XCTAssertLessThan(surfaceAt, verdictAt, "范围交代必须排在分数之前") }
        let legacy = CLIScoreText.render(report(CodeMetrics()), exit: .ok)
        XCTAssertTrue(legacy.contains("没有范围台账"),
                      "旧结构里没有这一格时，CLI 只能报缺席，不许沉默也不许报 0：\n\(legacy)")
        var noCode = ProjectReport(project: MonitoredProject(name: "x", path: "/tmp/x"))
        noCode.code = nil
        XCTAssertFalse(CLIScoreText.render(noCode, exit: .ok).contains("扫描范围"),
                       "代码那一路整路失败时，不许由这里补一句「没有台账」")
    }
}

// MARK: - ② 结构守卫：一处写者、真实读者（扫描型，配元测试）

final class CodeScanSurfaceGuardTests: XCTestCase {

    private var fm = FileManager.default

    private func sources() throws -> [(path: String, body: String)] {
        let root = CodeScanSurfaceFixture.packageRoot.appendingPathComponent("Sources/TcoderMonitor")
        let urls = (fm.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }) ?? []
        XCTAssertGreaterThanOrEqual(urls.count, 40, "扫描面只有 \(urls.count) 个文件，分母不对")
        return urls.map { url in
            let relative = String(url.path.dropFirst(CodeScanSurfaceFixture.packageRoot.path.count + 1))
            return (relative, (try? String(contentsOf: url, encoding: .utf8)) ?? "")
        }
    }

    private func witnesses(_ files: [(path: String, body: String)])
        -> (writers: [String], assembler: [String], exits: [String]) {
        var writers: [String] = [], assembler: [String] = [], exits: [String] = []
        for file in files {
            // 剥注释在尺子**内部**做：不然喂进坏样例时（元测试那条"注释凑证据"）就漏掉了这一类。
            let lines = file.body.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("//") == false }
            if lines.contains(where: { $0.contains("metrics.scanSurface =") }) { writers.append(file.path) }
            if lines.contains(where: { $0.contains("static func accountingLines(_ code: CodeMetrics)") }) {
                assembler.append(file.path)
            }
            if lines.contains(where: { $0.contains("CodeScanSurfaceReadout.accountingLines(") }) {
                exits.append(file.path)
            }
        }
        return (writers, assembler, exits)
    }

    func testSurfaceHasExactlyOneWriterAndARealReader() throws {
        let found = witnesses(try sources())
        XCTAssertEqual(found.writers, ["Sources/TcoderMonitor/Services/Code/FileSystemCodeAnalyzer.swift"],
                       "写这一族的只能有一处直传。多一处就是第二把尺子，没有就是回到有读无写：\(found.writers)")
        XCTAssertEqual(found.assembler, ["Sources/TcoderMonitor/Services/Code/CodeScanSurfaceReadout.swift"],
                       "上屏那两句的唯一装配口必须真的存在：\(found.assembler)")
        XCTAssertTrue(found.exits.contains("Sources/TcoderMonitor/Services/CLI/CLIScoreText.swift"),
                      "CLI 不再读它 ⇒ 看界面的人与读终端的人拿到两种诚实度：\(found.exits)")
    }

    /// 元测试（有牙证明）：摘掉写者 / 摘掉 CLI 读者 / 拿注释凑证据，三种坏形状各红一次。
    func testMeta_witnessScannerCatchesEveryBrokenShape() throws {
        let real = try sources()
        let base = witnesses(real)
        XCTAssertEqual(base.writers.count, 1, "真源码连基线都不成立，元测试不作数")
        XCTAssertTrue(base.exits.contains { $0.hasSuffix("CLIScoreText.swift") })
        let analyzer = "Sources/TcoderMonitor/Services/Code/FileSystemCodeAnalyzer.swift"
        let cli = "Sources/TcoderMonitor/Services/CLI/CLIScoreText.swift"
        XCTAssertEqual(witnesses(real.filter { $0.path != analyzer }).writers, [],
                       "擦掉唯一的直传处却没报 ⇒ 守卫没牙")
        let lostCLI = witnesses(real.map { file in
            file.path == cli
                ? (file.path, file.body.replacingOccurrences(of: "CodeScanSurfaceReadout.accountingLines(code)",
                                                             with: "somethingElse(code)"))
                : file
        })
        XCTAssertFalse(lostCLI.exits.contains(cli), "摘掉 CLI 读者没被抓到 ⇒ 这条守卫永真绿")
        let commentOnly = witnesses([("Sources/TcoderMonitor/Views/Dummy.swift",
                                      "import Foundation\n// CodeScanSurfaceReadout.accountingLines(code)")])
        XCTAssertEqual(commentOnly.exits, [], "注释凑成了读者 ⇒ 守卫会在文档里找证据")
    }
}

// MARK: - ③ 产品那一路：无头 `scan` 落盘 JSON 往返 + 自扫本仓对账

final class CodeScanSurfaceProductPathTests: SelfScanHarnessCase {

    /// 读者 (b)：真走无头装配拿报告 → 产品同款 coder 往返 → 键真在场 → 整枚删掉 ⇒ 解出 nil。
    func testProductScanJSONRoundTripKeepsEveryFieldAndKeyAbsenceDecodesAsNil() async throws {
        let root = try r17Corpus(tag: "scan-json")
        try CodeScanSurfaceFixture.write(CodeScanSurfaceFixture.body(2), to: "src/One.swift", in: root)
        try CodeScanSurfaceFixture.write("no extension\n", to: "LICENSE", in: root)
        let outcome = await CLIScan().outcome(path: root.path, allowNetwork: false)
        let full = try XCTUnwrap(outcome.report)
        let surface = try XCTUnwrap(full.code?.scanSurface, "无头装配没落范围台账")
        let json = try CLIScan.json(full, compact: true)
        XCTAssertTrue(json.contains("\"scanSurface\""), "落盘里根本没有这个键：\n\(json.prefix(400))")
        let back = try JSONDecoder.tcoderReportDecoder().decode(ProjectReport.self, from: Data(json.utf8))
        XCTAssertEqual(back.code?.scanSurface, surface, "逐字段往返对账不平")
        let stripped = json.replacingOccurrences(of: surfaceChunk(in: json) ?? "", with: "")
        // 只查"这一格还在不在"，不查整份文本里有没有这个词 ——
        // 提交信息里本来就可能出现字段名（那是用户数据，不是这一格）。
        XCTAssertFalse(stripped.contains("\"scanSurface\":{"), "键没删干净，下面那条不作数")
        let gone = try JSONDecoder.tcoderReportDecoder().decode(ProjectReport.self, from: Data(stripped.utf8))
        XCTAssertNil(gone.code?.scanSurface, "删掉整枚键必须解出 nil，而不是补一个空台账")
        XCTAssertTrue(CodeScanSurfaceReadout.accountingLines(gone.code ?? CodeMetrics())
                        .allSatisfy { $0.contains("没有范围台账") }, "旧 JSON 只能读成缺席")
    }

    /// 从 JSON 文本里定位 `"scanSurface":{…}` 那一段（手写括号配对，不引第三方解析器）。
    /// 连**邻着的那枚逗号**一起摘掉，否则删完剩 `,,` 或尾逗号，解不出 JSON 而不是解出 nil。
    private func surfaceChunk(in json: String) -> String? {
        guard let start = json.range(of: "\"scanSurface\":{") else { return nil }
        var depth = 1
        var index = start.upperBound
        var end = start.upperBound
        while index < json.endIndex {
            switch json[index] {
            case "{": depth += 1
            case "}": depth -= 1
            default: break
            }
            index = json.index(after: index)
            if depth == 0 { end = index; break }
        }
        guard depth == 0 else { return nil }
        var from = start.lowerBound, to = end
        if json.index(after: to) < json.endIndex, json[to] == "," { to = json.index(after: to) }
        else if from > json.startIndex, json[json.index(before: from)] == "," {
            from = json.index(before: from)
        }
        return String(json[from..<to])
    }

    /// 真语料：自扫本仓一次，钉"每格都是量到的数（含 0）、三态没塌、字段与句子同一个数"。
    /// 刻意**不**断言具体数字 —— 本仓的树每几分钟被推进一次，钉数就是把今天的形状写成契约。
    func testSelfScanKeepsEverySurfaceCellMeasuredAndTheThreeStatesApart() async throws {
        let metrics = try await selfScan().code
        let surface = try XCTUnwrap(metrics.scanSurface, "产品扫描必须落范围台账")
        XCTAssertNotNil(surface.totalCount)
        XCTAssertEqual(surface.reportedExcludedEntryCount,
                       (surface.displayedCount ?? 0) + (surface.undisplayedCount ?? 0), "同一分母的两半必须相加")
        XCTAssertEqual(surface.linesCounted, false, "产品默认路径不开审计")
        XCTAssertNil(surface.excludedLineCount, "既然没数过，这一格就不许有数")
        for (name, value) in [("nested", surface.nestedRepositoryCount), ("submodule", surface.submoduleMarkerCount),
                              ("symlinkFile", surface.symbolicLinkFileCount),
                              ("symlinkDir", surface.symbolicLinkDirectoryCount),
                              ("unlistedPruned", surface.unlistedPrunedDirectoryCount),
                              ("unreadable", surface.unreadableDirectoryCount)] {
            XCTAssertNotNil(value, "真扫描里这一格必须是量到的数（含 0），不许留 nil：\(name)")
        }
        // 对账（RD-48 同款）：落盘字段与 `scanLimitations` 那句中文必须是同一次测量。
        let scopeLine = try XCTUnwrap(
            (metrics.scanLimitations ?? []).first { $0.hasPrefix("扫描范围：遍历看到") },
            "本仓有排除面 ⇒ 顶格那句必须在限制账里：\(metrics.scanLimitations ?? [])")
        let numbers = numbersIn(scopeLine)
        XCTAssertGreaterThanOrEqual(numbers.count, 4, "那句里数不出四个数：\(scopeLine)")
        XCTAssertEqual(numbers[0], surface.totalCount, "字段与句子给出的条目数不一致：\(scopeLine)")
        XCTAssertEqual(numbers[1], surface.displayedCount, "字段与句子给出的点名数不一致：\(scopeLine)")
        XCTAssertEqual(numbers[2], surface.undisplayedCount, "字段与句子给出的未点名数不一致：\(scopeLine)")
        XCTAssertEqual(numbers[3], surface.unmeasuredScope?.count, "未量准条数两边不一致：\(scopeLine)")
        print("【RD-15 真语料】本仓 scanSurface：条目 \(surface.totalCount ?? -1)"
            + " · 排除 \(surface.reportedExcludedEntryCount ?? -1)（点名 \(surface.displayedCount ?? -1)）"
            + " · 未量到的范围 \(surface.unmeasuredScope?.count ?? -1) 条"
            + " · 读不动目录 \(surface.unreadableDirectoryCount ?? -1) 个")
    }

    /// 从一句中文读数里按出现顺序取出所有数字。只为"字段 == 句子"这一次对账服务，
    /// 不拿来从散文里抠数当读数（那正是 RD-48 反对的形状）。
    private func numbersIn(_ text: String) -> [Int] {
        let re = try! NSRegularExpression(pattern: "\\d[\\d,]*")
        let range = NSRange(text.startIndex..., in: text)
        return re.matches(in: text, options: [], range: range).compactMap { match in
            guard let span = Range(match.range, in: text) else { return nil }
            return Int(String(text[span]).replacingOccurrences(of: ",", with: ""))
        }
    }
}
