import XCTest
@testable import TcoderMonitor

/// R33 · **RD-62** —— 「没标注类别」不得渲染成「没有报告」（台账卷四 §58.5）。
///
/// # 为什么这条缺陷长这样
/// RD-39 结案后 `CoverageAnalyzer.classify(url:root:)` 只看**被扫根之内**的相对路径，
/// 路径里没有 `unit`/`integration`/`e2e` 那些目录段就一律 `.combined`（**不猜**）。
/// 于是「有报告、没标注类别」成了常态，而总览那张卡的两格原先只有两种取值
/// （有该类报告 ⇒ 百分数；否则 ⇒ 写死「无报告」）⇒ 一份普通的 `coverage/lcov.info`
/// 会让「单元测试 / 集成测试」两格写「无报告」，而同一张卡的总覆盖率那格有数。
///
/// # 真值从哪来（不拿实现输出当期望）
/// 三句期望（「未标注类别」/「未产出该类报告」/「无报告」）与两个百分数
/// （`78%`、`78.0%`）全是**本文件自己写的字面量**：夹具的 `LF:100 / LH:78` 由我写下，
/// 百分数是我手算的（78/100），不是从实现里读回来再断言的。
/// 夹具落 `NSTemporaryDirectory()` 下**每趟唯一**的目录、`tearDown` 删干净并复查已删
/// （本仓两类残迹都踩过：/tmp 夹具喂假绿、仓库内沙箱喂假红 —— 所以两头都不留在被扫树里）。
///
/// # 四个方向
/// * **正例**：未标注的 `coverage/lcov.info` ⇒ 两格不得出现「无报告」，总覆盖率那格有数；
/// * **反例**：一份报告都没有 ⇒ 必须还说「无报告」那一类，不许被翻成「未标注」；
/// * **第三态**：只有一份标注成 unit 的报告 ⇒ integration 那格与「有别的报告但未标注」**分得开**；
/// * **结构钉**：全仓除那一处装配口外不许有第二处现算这三态（配元测试证明扫描面非空）。
final class CoverageCategoryAbsenceReadoutTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rd62-covcategory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        let path = root.path
        try? FileManager.default.removeItem(at: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path),
                       "夹具没删干净就是留下了下一趟假绿的口：\(path)")
    }

    // MARK: - 夹具（内容自己写，数字自己数）

    /// 在 `directory` 下写一份 lcov。`covered/total` 是调用方手写的两个数，
    /// 屏上那格期望的百分数也是调用方自己算的 —— 不经由实现。
    private func writeLcov(under directory: URL, relative: String,
                           covered: Int, total: Int) throws {
        let url = directory.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "SF:src/a.js\nLF:\(total)\nLH:\(covered)\nend_of_record\n"
            .write(to: url, atomically: true, encoding: .utf8)
    }

    private func scanned(_ directory: URL) async throws -> CoverageMetrics {
        try await CoverageAnalyzer().analyze(projectRoot: directory, options: .default)
    }

    /// 只有一棵「未标注」的树：`coverage/lcov.info` ⇒ `.combined`，78/100。
    private func unlabeledTree(in directory: URL) async throws -> CoverageMetrics {
        try writeLcov(under: directory, relative: "coverage/lcov.info", covered: 78, total: 100)
        return try await scanned(directory)
    }

    private func unlabeledTree() async throws -> CoverageMetrics {
        try await unlabeledTree(in: root)
    }

    // MARK: - 正例：未标注的报告不许长成「无报告」

    func testUnlabeledReportNeverRendersAsNoReport() async throws {
        let metrics = try await unlabeledTree()
        // 先自证夹具落成了我以为的形状（这三条与屏上那格无关，是判据的输入侧）。
        XCTAssertEqual(metrics.reports.count, 1, "一份 lcov 就该读到一份报告")
        XCTAssertEqual(metrics.reports.first?.kind, .combined,
                       "相对路径里没有 unit/integration/e2e 目录段 ⇒ 不猜，判 .combined")
        XCTAssertFalse(metrics.absenceClaimIsSound,
                       "报告在场时「这个项目没有覆盖率报告」这句话根本不成立")

        // 两格：不得出现「无报告」，必须说「未标注类别」（这句是我写的，不是实现里读来的）。
        let unit = CoverageCategoryReadout.text(for: metrics.unit, in: metrics)
        let integration = CoverageCategoryReadout.text(for: metrics.integration, in: metrics)
        XCTAssertEqual(unit, "未标注类别")
        XCTAssertEqual(integration, "未标注类别")
        XCTAssertFalse(unit.contains("无报告"), "「没标注」又长成「没有」：\(unit)")
        XCTAssertFalse(integration.contains("无报告"), "「没标注」又长成「没有」：\(integration)")

        // 同一张卡的总覆盖率那一格必须有数：78/100 是我手写的两个数。
        XCTAssertEqual(try XCTUnwrap(metrics.overallLinePercent), 78.0)
        let overallCell = DataAbsence.optional(metrics.overallLinePercent.map {
            DashboardView.percentOf100($0, precision: 1) }).display
        XCTAssertEqual(overallCell, "78.0%",
                       "总覆盖率那一格必须仍然有数 —— 这一格本来没病，钉住别改坏")
    }

    // MARK: - 反例：一份报告都没有 ⇒ 「无报告」才是真话

    func testEmptyTreeStillSaysThereIsNoReport() async throws {
        let metrics = try await scanned(root)          // 空目录，一份报告都没有
        XCTAssertTrue(metrics.reports.isEmpty)
        XCTAssertTrue(metrics.absenceClaimIsSound, "什么都没扫到 ⇒ 这句这次是成立的")

        for kind in [metrics.unit, metrics.integration] {
            let readout = CoverageCategoryReadout.text(for: kind, in: metrics)
            XCTAssertEqual(readout, "无报告", "真「没有报告」那一支不许被翻成别的")
            XCTAssertFalse(readout.contains("未标注"),
                           "把「没有」说成「没标注」＝把缺陷反向藏起来：\(readout)")
        }
    }

    // MARK: - 第三态：标了别的类别 ≠ 没标注类别

    /// 同一个测试里并排量两棵树（两棵都在 `root` 之下、各自独立扫），
    /// 因为这一条判据要的就是**两种成因分得开**，各测一半等于没测。
    func testLabeledOtherKindStaysApartFromUnlabeledReport() async throws {
        let labeledRoot = root.appendingPathComponent("labeled", isDirectory: true)
        let unlabeledRoot = root.appendingPathComponent("unlabeled", isDirectory: true)
        try writeLcov(under: labeledRoot, relative: "unit/coverage/lcov.info",
                      covered: 78, total: 100)
        try writeLcov(under: unlabeledRoot, relative: "coverage/lcov.info",
                      covered: 78, total: 100)

        let labeled = try await scanned(labeledRoot)
        let unlabeled = try await scanned(unlabeledRoot)
        XCTAssertEqual(labeled.unit?.kind, .unit, "夹具没被标注成 unit ⇒ 这一例在测空气")
        XCTAssertNil(labeled.integration, "这份夹具只该有一份 unit 报告")
        XCTAssertEqual(unlabeled.reports.first?.kind, .combined, "对照组必须是未标注那一支")

        // unit 那一格：有该类报告 ⇒ 百分数（现行为逐字不变，78/100 是我写的）。
        XCTAssertEqual(CoverageCategoryReadout.text(for: labeled.unit, in: labeled), "78%")
        // integration 那一格：说「未产出该类报告」，而不是「未标注类别」。
        let integration = CoverageCategoryReadout.text(for: labeled.integration, in: labeled)
        XCTAssertEqual(integration, "未产出该类报告")
        XCTAssertFalse(integration.contains("未标注"),
                       "报告明明标了类别，却说没标注 ⇒ 这一格是假话：\(integration)")
        // 对照组：同一种"没有该类报告"，未标注那一支必须长成另一句话。
        let counterpart = CoverageCategoryReadout.text(for: unlabeled.integration, in: unlabeled)
        XCTAssertEqual(counterpart, "未标注类别")
        XCTAssertNotEqual(integration, counterpart, "两支混成一句 = 三态又塌回两态")
    }

    // MARK: - 一把尺子：装配口与视图那处百分数不许分叉

    func testAssemblyPointAndViewShareOnePercentRuler() async throws {
        let root = self.root!.appendingPathComponent("ruler", isDirectory: true)
        try writeLcov(under: root, relative: "unit/coverage/lcov.info", covered: 78, total: 100)
        let metrics = try await scanned(root)
        let unit = try XCTUnwrap(metrics.unit, "夹具标注成 unit 了，取不到就是夹具没落地")
        // ① 屏上那一格与视图原来那处**逐字相同**（现行为不变）。
        XCTAssertEqual(CoverageCategoryReadout.text(for: unit, in: metrics),
                       DashboardView.percentOf100(unit.linePercent))
        XCTAssertEqual(CoverageCategoryReadout.text(for: unit, in: metrics), "78%",
                       "78/100 是我自己写的两个数，期望句也是我自己算的")
        // ② 两把尺子对同一批读数必须处处相等（谁改了精度这里就红）。
        for raw in [0.0, 55.0, 91.6667, 100.0] {
            XCTAssertEqual(CoverageCategoryReadout.percentOf100(raw),
                           DashboardView.percentOf100(raw), "\(raw)")
            XCTAssertEqual(CoverageCategoryReadout.percentOf100(raw, precision: 1),
                           DashboardView.percentOf100(raw, precision: 1), "\(raw)")
        }
    }

    // MARK: - 第三个出口：无头 `score` 文本走同一句

    func testCLIScoreTextCarriesTheSameThreeSentences() async throws {
        var report = ProjectReport(project: MonitoredProject(name: "夹具", path: "/tmp/rd62"))
        // 三态各用**一棵自己的树**：都写在 `root` 里的话，后一趟会扫到前一趟的夹具，
        // 「一份报告都没有」那一支就永远测不到（这一条是本文件第一次跑就踩到的）。
        let unlabeledRoot = root.appendingPathComponent("cli-unlabeled", isDirectory: true)
        let emptyRoot = root.appendingPathComponent("cli-empty", isDirectory: true)
        let labeledRoot = root.appendingPathComponent("cli-labeled", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)

        // ① 未标注 ⇒ 两格都念「未标注类别」，一处「无报告」都不许有。
        report.coverage = try await unlabeledTree(in: unlabeledRoot)
        let unlabeledText = CLIScoreText.render(report, exit: .ok)
        XCTAssertTrue(unlabeledText.contains("单元测试：未标注类别"), unlabeledText)
        XCTAssertTrue(unlabeledText.contains("集成测试：未标注类别"), unlabeledText)
        XCTAssertFalse(unlabeledText.contains("单元测试：无报告"),
                       "CLI 那一路也犯同一个错：\(unlabeledText)")

        // ② 一份报告都没有 ⇒ CLI 仍说「无报告」（这一支在界面上走不到，见装配口的注释）。
        report.coverage = try await scanned(emptyRoot)
        let emptyText = CLIScoreText.render(report, exit: .ok)
        XCTAssertTrue(emptyText.contains("单元测试：无报告"), emptyText)
        XCTAssertFalse(emptyText.contains("未标注"), "真「没有」不许说成「没标注」：\(emptyText)")

        // ③ 标注了别的类别 ⇒ CLI 念的是第三句，且这一格给的是百分数。
        try writeLcov(under: labeledRoot, relative: "unit/coverage/lcov.info",
                      covered: 78, total: 100)
        report.coverage = try await scanned(labeledRoot)
        let labeledText = CLIScoreText.render(report, exit: .ok)
        XCTAssertTrue(labeledText.contains("单元测试：78%"), labeledText)
        XCTAssertTrue(labeledText.contains("集成测试：未产出该类报告"), labeledText)
    }

    // MARK: - 结构钉：三态的句子只许住在那一处装配口

    /// 三态那几句的**字面量特征**（按名字扫，不按调用形状 —— 换个调用形状就扫不到正是教训）。
    private static let sentenceMarkers = ["无报告", "未标注类别", "未产出该类报告"]

    /// 装配口本体的相对路径（唯一合法落点）。
    private static let producerPath = "Services/Coverage/CoverageDisplayShape.swift"

    /// 剥掉整行注释再找：注释里**讲**这句话不算第二把尺子，代码里写出来才算。
    static func sentenceHits(in text: String) -> [String] {
        var hits: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.drop(while: { $0 == " " || $0 == "\t" })
            if line.starts(with: "//") { continue }
            for marker in sentenceMarkers where line.contains(Substring(marker)) {
                hits.append(marker)
            }
        }
        return hits
    }

    func testOnlyTheAssemblyPointWritesTheseSentences() throws {
        let files = try Self.surfaceFiles()
        XCTAssertGreaterThan(files.count, 60, "扫不到 `Sources/**` ⇒ 这条守卫在空跑")
        var offenders: [String] = []
        var producerHits = 0
        for (path, content) in files {
            let hits = Self.sentenceHits(in: content)
            if path.hasSuffix(Self.producerPath) { producerHits += hits.count }
            else if !hits.isEmpty { offenders.append("\(path) → \(hits.sorted())") }
        }
        // 分母自证：尺子在装配口本身必须数得到三句，否则"只有一处"是空的。
        XCTAssertGreaterThanOrEqual(producerHits, 3,
                                    "装配口一处都没命中 ⇒ 判据字面写错了，整条在空转")
        XCTAssertTrue(offenders.isEmpty,
                      "全仓出现了第二处现算这三态的地方（第二把尺子）：\n\(offenders.sorted().joined(separator: "\n"))")
    }

    /// 界面那两格必须**接在那个装配口上**（只扫"没有第二处"不够：一处都没有也是绿的）。
    func testBothDashboardCellsGoThroughTheAssemblyPoint() throws {
        let dashboard = try Self.source("Views/DashboardView.swift")
        XCTAssertNotNil(dashboard.range(of: "GlassSection(\"测试覆盖率\")"),
                        "覆盖率那张卡不在了，下面两条接点断言就没意义")
        for kind in ["coverage.unit", "coverage.integration"] {
            XCTAssertTrue(dashboard.contains("CoverageCategoryReadout.text(for: \(kind), in: coverage)"),
                          "总览那格没走唯一装配口：\(kind)")
        }
        XCTAssertFalse(dashboard.contains("无报告"),
                       "视图里还留着一句写死的话术 = 第二把尺子（RD-62 原地复活）")
        let cli = try Self.source("Services/CLI/CLIScoreText.swift")
        XCTAssertTrue(cli.contains("CoverageCategoryReadout.text(for:"), "CLI 没读同一把尺子")
        XCTAssertTrue(Self.sentenceHits(in: cli).isEmpty,
                      "CLI 里手写了三态的句子 = 第二把尺子：\(Self.sentenceHits(in: cli))")
    }

    /// 元测试（本仓规矩：扫描守卫不配元测试迟早永真绿）：
    /// 写进代码的要抓到、只在注释里提的不算、干净文件不报。
    func testTheSentenceRulerCatchesAnInjectedSecondCopy() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rd62-ruler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "enum Bad { static let s = localizedCopy(\"未标注类别\") }\n".write(
            to: dir.appendingPathComponent("Bad.swift"), atomically: true, encoding: .utf8)
        try "// 这句注释里讲「未标注类别」，不该被抓\nenum Clean { let x = 1 }\n".write(
            to: dir.appendingPathComponent("Clean.swift"), atomically: true, encoding: .utf8)

        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
        XCTAssertEqual(files.count, 2, "两份夹具没都落到盘上，元测试自身失效")
        let hits = files.flatMap { Self.sentenceHits(in: (try? String(contentsOf: $0, encoding: .utf8)) ?? "") }
        XCTAssertEqual(hits, ["未标注类别"],
                       "写进代码的那处必须抓到、只写在注释里的那处不许算")
    }

    // MARK: - 小工具

    /// 动态枚举 `Sources/TcoderMonitor/**`（与双语守卫同一张扫描面，不另抄目录名）。
    private static func surfaceFiles() throws -> [(path: String, content: String)] {
        let base = packageRoot.appendingPathComponent("Sources/TcoderMonitor").path
        let paths = walkFiles(in: base)
        XCTAssertGreaterThan(paths.count, 60, "扫描面只有 \(paths.count) 个文件 ⇒ 分母不对")
        return paths.map { ($0, (try? String(contentsOfFile: $0, encoding: .utf8)) ?? "") }
    }

    private static func source(_ relative: String) throws -> String {
        try String(contentsOf: packageRoot.appendingPathComponent("Sources/TcoderMonitor/" + relative),
                   encoding: .utf8)
    }

    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/TcoderMonitorTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // TcoderMonitor
    }

    private static func walkFiles(in dir: String) -> [String] {
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: dir) else { return [] }
        return en.compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") }
            .map { "\(dir)/\($0)" }
    }
}
