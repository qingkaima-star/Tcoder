import XCTest
@testable import TcoderMonitor

// OWNER: WS-R39 DepVerdict · RD-68（闸门唯一：全仓只许一处判「能不能说没有已知漏洞」）
//
// # 这条守卫钉的是哪件真事
// RD-68 的形状不是"某句话写错了"，是**同一件事实有两道闸**：
//   · 账本那把 `DependencyEvidence.mayClaimNoKnownVulnerabilities` 要求严格相等；
//   · 总览那把 `DependencySafetyVerdict.init` 只问 `> 0`。
// 两道闸各自演化、互不知情，于是同一份账在界面上是绿、在无头出口是"没查全"。
// ⇒ 修法必须留下**一把尺子**并让下一位作者不能悄悄再种一把：本次改动之后
// 「漏洞核对成功条数 == 依赖总条数」这条算式在 `Sources/**` 只许存在一处，
// 「没查全 / 已完成核对」那两族句子也只许各由一处写出。
//
// # 先例与判据形状
// 抄 `CoverageCategoryAbsenceReadoutTests.testOnlyTheAssemblyPointWritesTheseSentences`：
// 按**字面特征**扫（换个调用形状就扫不到正是本仓记过无数次的教训）、
// 剥掉整行注释再判（注释里**讲**这句话不算第二把尺子）、
// 并配 `producerHits` 自证"装配口一处都没命中"时整条守卫当场红而不是空转。
//
// # 第二条出口（AGENTS §8 第 6.1 条）
// 现量读数除了 `print` 还同时落 `GuardLedger` 那套文件账（写完读回断言相等），
// 由 `scripts/guard_ledger_summary.sh` 汇总成表。

final class DependencyGateUniquenessTests: XCTestCase {

    /// 唯一合法落点：闸门算式与三档话术都住在这里。
    private static let gatePath = "Services/Dependencies/DependencyEvidence.swift"
    /// 唯一合法落点：「已完成核对」这一句只许由结论枚举的 `.clean` 分支写出。
    private static let allClearPath = "Views/Dependencies/DependencyVerdictRows.swift"

    /// 闸门算式的**字面特征**：`*CheckedCount` 与 `*totalCount` 之间的相等/不等比较，两个方向都算。
    /// 按字面扫而不按语义抽象 —— RD-68 的教训正是"抽象的判据在第二个写法面前失效"；
    /// 反过来也不放宽成"凡出现 CheckedCount 就算"，否则 `== 0` 那种判零会被误报。
    private static let gatePattern =
        "CheckedCount\\s*(?:==|!=)\\s*[A-Za-z.]*totalCount"
        + "|[A-Za-z.]*totalCount\\s*(?:==|!=)\\s*[A-Za-z.]*CheckedCount"

    /// 三档话术的字面特征（装配口那一枚 `statement` 独家产出）。
    private static let sentenceMarkers = ["个没查", "一条都没核对", "个依赖，未发现已知漏洞"]

    /// 「已完成核对」这一族 all-clear 断言短语的特征。
    private static let allClearMarkers = ["已完成核对"]

    // MARK: - ① 闸门算式：`Sources/**` 只许一处

    func testTheGateExpressionExistsInExactlyOnePlace() throws {
        let files = try Self.surfaceFiles()
        XCTAssertGreaterThan(files.count, 60, "扫不到 `Sources/**` ⇒ 这条守卫在空跑")

        var offenders: [String] = []
        var gateHits = 0
        for (path, content) in files {
            let hits = Self.gateHits(in: content)
            if path.hasSuffix(Self.gatePath) { gateHits += hits.count }
            else if !hits.isEmpty { offenders.append("\(path) → \(hits)") }
        }
        // 分母自证：尺子在闸门本身必须数得到那条算式，否则"只有一处"是空的。
        XCTAssertGreaterThanOrEqual(gateHits, 1,
                                    "闸门算式在装配口一处都没命中 ⇒ 判据字面写错了，整条在空转")
        XCTAssertTrue(offenders.isEmpty,
                      "全仓出现了第二条「已核对条数 == 总条数」算式（RD-68 原地复活）：\n"
                          + offenders.sorted().joined(separator: "\n"))
        // 第二条出口：现量落账（写完读回断言相等）。
        GuardLedger.record(guard: "DependencyGateUniquenessTests", readings: [
            "闸门算式：装配口现量 \(gateHits) 处 / 全仓其它文件现量 \(offenders.count) 处",
            "没查全话术：装配口现量 \(Self.sentenceHits(in: try Self.source(Self.gatePath)).count) 处",
            "扫描面：\(files.count) 个 Sources 文件",
        ])
    }

    /// 装配口必须**真的**还写着那条算式（防止"把算式删了换取守卫变绿"这种假修）。
    func testTheGateStillOwnsTheExpressionItIsGuarding() throws {
        let gate = try Self.source(Self.gatePath)
        XCTAssertTrue(gate.contains("vulnerabilityCheckedCount == ledger.totalCount"),
                      "闸门不再自己算覆盖度 ⇒ 要么判据被搬走、要么被悄悄删掉")
        // 判据本身（全覆盖才算数）不许被放宽成「核对过就算」。
        // ⚠ 只看代码行：本文件的注释里**逐字引用**过这个错误形状（就是在解释这次修的是什么），
        // 按整份文本找会先被自己的说明文字打死。
        XCTAssertTrue(Self.codeLines(gate).contains { $0.contains("func vulnerabilityCoverage") },
                      "唯一分档入口不见了")
        XCTAssertFalse(Self.codeLines(gate).contains { $0.contains("vulnerabilityCheckedCount > 0") },
                       "闸门被放宽回「核对成功过就算」= RD-68 的原始缺陷形状")
    }

    // MARK: - ② 话术：「没查全」三句与「已完成核对」各只许一处

    func testOnlyTheAssemblyPointWritesTheCoverageSentences() throws {
        let files = try Self.surfaceFiles()
        var offenders: [String] = []
        var producerHits = 0
        for (path, content) in files {
            let hits = Self.sentenceHits(in: content)
            if path.hasSuffix(Self.gatePath) { producerHits += hits.count }
            else if !hits.isEmpty { offenders.append("\(path) → \(hits.sorted())") }
        }
        XCTAssertGreaterThanOrEqual(producerHits, 3,
                                    "装配口一处都没命中这三句 ⇒ 判据字面写错了，整条在空转")
        XCTAssertTrue(offenders.isEmpty,
                      "全仓出现了第二处现写覆盖度话术（第二把尺子）：\n"
                          + offenders.sorted().joined(separator: "\n"))
    }

    func testOnlyTheVerdictWritesTheFinishedSweepSentence() throws {
        let files = try Self.surfaceFiles()
        var offenders: [String] = []
        var producerHits = 0
        for (path, content) in files {
            let hits = Self.allClearHits(in: content)
            if path.hasSuffix(Self.allClearPath) { producerHits += hits.count }
            else if !hits.isEmpty { offenders.append("\(path) → \(hits)") }
        }
        // 恰好一处：`.clean` 那一支。多于说明有人又写了一遍，等于 0 说明这句被删了。
        XCTAssertEqual(producerHits, 1, "「已完成核对」在结论枚举里不再恰好一处")
        XCTAssertTrue(offenders.isEmpty,
                      "「已完成核对」被第二处写出（视图自己判档位的形状）：\(offenders)")
    }

    /// 视图侧不许再比一次条数：三处出口全部由枚举分派，这是 (a) 方案的形状契约。
    /// 双向自证：先证明"视图里确实还在用结论枚举"（否则下面两条是永真绿），
    /// 再证明"视图与结论文件都没有第二次比条数"。
    func testViewsNeverReCompareTheCoveredCount() throws {
        let view = Self.codeLines(try Self.source("Views/Dependencies/DependenciesView.swift"))
        let verdicts = Self.codeLines(try Self.source(Self.allClearPath))
        XCTAssertTrue(view.contains { $0.contains("advisoryEmptyCaption") },
                      "安全公告空态不再走结论枚举 ⇒ 视图自己判档位，RD-68 复活")
        XCTAssertTrue(view.contains { $0.contains("DependencySafetyVerdict") },
                      "依赖页已经不构造结论了 ⇒ 下面两条在空跑")
        let viewOffenders = view.filter { Self.viewComparesCounts($0) }
        XCTAssertTrue(viewOffenders.isEmpty,
                      "依赖页视图里出现了自己比条数的代码：第二把尺子 \(viewOffenders)")
        let verdictOffenders = verdicts.filter { Self.viewComparesCounts($0) }
        XCTAssertTrue(verdictOffenders.isEmpty,
                      "结论枚举里又比了一次条数而不是读档位：\(verdictOffenders)")
    }

    // MARK: - ③ 爆炸半径钉：评分侧不读这枚判定（本次改动为什么不必动评分）

    /// `Services/Health/**` 读的是 `DependencyEvidence` 的**结构化状态**，不是 `DependencySafetyVerdict`。
    /// 本条把这件事钉成机读事实：一旦有人把总览判定接进评分输入，这里当场红 ——
    /// 那时改的就不是文案，必须先报总工。
    func testHealthScoringDoesNotReadTheOverviewVerdict() throws {
        let files = try Self.surfaceFiles()
        let health = files.filter { $0.path.contains("/Services/Health/") }
        XCTAssertGreaterThanOrEqual(health.count, 4, "评分那一路的文件没扫到 ⇒ 这条在空跑")
        let readers = health.filter {
            Self.codeLines($0.content).contains { $0.contains("DependencySafetyVerdict")
                || $0.contains("mayClaimSafe") }
        }.map { $0.path }
        XCTAssertTrue(readers.isEmpty,
                      "评分侧开始读总览判定，本次修法的影响面就不再是文案：\(readers)")
        // 反向自证：Health 确实在读同一份账本（不是"两边都没读"造成的永真绿）。
        let sharedBook = health.filter {
            Self.codeLines($0.content).contains { $0.contains("DependencyEvidence.ledger") }
        }
        XCTAssertGreaterThanOrEqual(sharedBook.count, 1,
                                    "评分侧根本没读账本 ⇒ 上面那条断言的分母是空的")
    }

    /// CLI 这一出口必须仍然接在同一把闸门上（不是"改完只剩界面一把尺"）。
    func testCLIExitReadsTheSameGate() throws {
        let cli = Self.codeLines(try Self.source("Services/CLI/CLIScoreText.swift"))
        XCTAssertTrue(cli.contains { $0.contains("DependencyEvidence.vulnerabilityCoverage") },
                      "无头出口不再走唯一分档入口 ⇒ 它自己判了一档")
        XCTAssertTrue(cli.contains { $0.contains("mayClaimNoKnownVulnerabilities") },
                      "无头出口不再读那把闸门")
        XCTAssertTrue(cli.contains { $0.contains("coverage.statement") },
                      "无头出口又自己写了一遍话术")
    }

    // MARK: - 元测试（本仓规矩：扫描守卫不配元测试迟早永真绿）

    /// 注入第二处算式必须当场被抓、只在注释里提不算、干净文件不报。
    func testTheGateRulerCatchesAnInjectedSecondCopy() throws {
        let dirty = """
        enum Bad { func ok(_ ledger: DependencyEvidenceLedger) -> Bool {
            ledger.vulnerabilityCheckedCount == ledger.totalCount } }
        """
        XCTAssertEqual(Self.gateHits(in: dirty).count, 1, "写进代码的第二处算式没被抓到")
        let commented = "// 这里讲 vulnerabilityCheckedCount == ledger.totalCount，不算第二把尺子\n"
        XCTAssertTrue(Self.gateHits(in: commented).isEmpty, "注释里提一句就被判红 = 粗尺上闸")
        let clean = "enum Clean { let x = 1 }\n"
        XCTAssertTrue(Self.gateHits(in: clean).isEmpty, "干净文件被误报")
        // 反向形状（总条数在左）也要抓得住，否则换个写法就绕过去了。
        XCTAssertEqual(Self.gateHits(in: "if ledger.totalCount == ledger.versionCheckedCount { }\n").count, 1)
    }

    /// 话术那把尺子同样双向。
    func testTheSentenceRulerCatchesAnInjectedSecondCopy() throws {
        let dirty = "enum Bad { static let s = localizedCopy(\"另外 2 个没查\") }\n"
        XCTAssertEqual(Self.sentenceHits(in: dirty), ["个没查"], "写进代码的第二份话术没被抓到")
        let commented = "// 这句注释里讲「另外 2 个没查」，不该被抓\nenum Clean { let x = 1 }\n"
        XCTAssertTrue(Self.sentenceHits(in: commented).isEmpty, "注释里讲这句话被误判成第二把尺子")
        XCTAssertEqual(Self.allClearHits(in: "Text(\"已完成核对，未发现已知漏洞。\")").count, 1)
        XCTAssertTrue(Self.allClearHits(in: "// 「已完成核对」这句现在只由 .clean 分支写出").isEmpty)
    }

    // MARK: - ④ 评分侧（RD-73：字面扫不到的那把第二尺子，改按行为钉）

    /// 评分侧必须**改读**唯一分档入口，而不是再抄一遍"查全了没有"。
    /// 它原先的形状是 `let checked = counts[.checked] ?? 0` 之后 `checked == ledger.totalCount` ——
    /// 换成局部变量写法就逃过上面那把 `gatePattern`，所以这里两头都钉：
    /// 既要求它调那一处，也要求它别再自己比条数。
    func testScoringReadsTheSingleCoverageTier() throws {
        let curves = Self.codeLines(try Self.source("Services/Health/ScoreCurves.swift"))
        XCTAssertTrue(curves.contains { $0.contains("DependencyEvidence.vulnerabilityCoverage") },
                      "评分侧不再读唯一分档入口 ⇒ 它自己又判了一次「查全了没有」")
        let copied = Self.legacyCoverageComparisons(in: try Self.source("Services/Health/ScoreCurves.swift"))
        XCTAssertTrue(copied.isEmpty, "评分侧又抄了一遍覆盖度算式：\(copied)")
    }

    /// 上面那把尺子的双向元测试：注入旧形状必须抓到、注释里提一句不算、否则那条断言就是永真绿。
    func testTheScoringRulerCatchesTheLegacyExpression() throws {
        let dirty = "    if checked == ledger.totalCount { return .verified }\n"
        XCTAssertEqual(Self.legacyCoverageComparisons(in: dirty).count, 1,
                       "抓不到评分侧那把旧尺子的字面形状 ⇒ 上一条断言在空跑")
        let commented = "        // 旧实现写的是 checked == ledger.totalCount，现在不这么判\n"
            + "        if DependencyEvidence.vulnerabilityCoverage(ledger).isFull { return .verified }\n"
        XCTAssertTrue(Self.legacyCoverageComparisons(in: commented).isEmpty,
                      "注释里讲这句就被判红 = 会误报的粗尺上了闸")
    }

    /// 评分侧旧尺子的形状：任何拿 `totalCount` 右操作数的相等比较（注释行已被剥掉）。
    static func legacyCoverageComparisons(in text: String) -> [String] {
        SurfaceScanKit.codeLines(text).filter {
            $0.contains("== ledger.totalCount") || $0.contains("== report.totalCount")
        }
    }

    // MARK: - 小工具

    /// 闸门算式：按正则抓，两个方向都算，剥掉整行注释。
    static func gateHits(in text: String) -> [String] {
        let re = try! NSRegularExpression(pattern: gatePattern, options: [])
        var out: [String] = []
        for line in SurfaceScanKit.codeLines(text) {
            let range = NSRange(line.startIndex..., in: line)
            for m in re.matches(in: line, options: [], range: range) {
                if let r = Range(m.range, in: line) { out.append(String(line[r])) }
            }
        }
        return out
    }

    static func sentenceHits(in text: String) -> [String] {
        hits(in: text, markers: sentenceMarkers)
    }

    static func allClearHits(in text: String) -> [String] {
        hits(in: text, markers: allClearMarkers)
    }

    /// 剥掉整行注释再按字面找：注释里**讲**这句话不算第二把尺子（先例同形）。
    private static func hits(in text: String, markers: [String]) -> [String] {
        var out: [String] = []
        for line in SurfaceScanKit.codeLines(text) {
            for marker in markers where line.contains(Substring(marker)) { out.append(marker) }
        }
        return out
    }

    /// 一行里是不是"自己比条数"（`covered` 与 `total` 之间的相等或大小比较）。
    static func viewComparesCounts(_ line: String) -> Bool {
        ["covered < total", "covered >= total", "covered == total", "coveredCount < total",
         "covered > 0", "coveredCount > 0", "total < covered", "total <= covered"]
            .contains { line.contains($0) }
    }

    static func codeLines(_ text: String) -> [String] {
        SurfaceScanKit.codeLines(text)
    }

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
