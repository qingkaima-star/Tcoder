import XCTest
@testable import TcoderMonitor

/// R40 · **RD-67 双分母并排** —— 「生产码 N 行 / 全量 M 行」这一句的四态与独立真值
/// （台账卷四 §73；需求方 2026-09-24 18:16 拍的是「维持现状 + 两个数并排给」）。
///
/// # 这一句必须把四件事分开说（本单的硬要求）
/// | 盘上形状 | 上屏 | 不许长成 |
/// |---|---|---|
/// | `fileRoles == nil`（本次没做角色分档） | **整句不出声** | 「生产码 0 行」或一个「/ 全量」 |
/// | 有分档、生产码那一档缺席（没数出来） | `生产码 --` | 折成 0 |
/// | 生产码档 `codeLines == 0`（真的一个生产文件都没有） | 照 0 打 + 一句「这次量到的是零」 | 「该项目没有源码」 |
/// | 生产码档里有弱判定文件 | 再并一句「读这一档要按它打折」 | 静默不提 |
///
/// # 真值从哪来（不拿实现返回值当期望）
/// `corpus` 那五行文件内容是本文件自己写的，`Truth` 里每个数都是**照那几行手数的**
/// （一条产出一行、不留空行也不写注释）。实现与这里不一致时先怀疑实现。
/// 夹具落包内 `.scratch/`（AGENTS §1.6 的落点、被自扫剪枝点名），`addTeardownBlock`
/// 删掉并复查已删 —— /tmp 夹具喂假绿、仓库内沙箱喂假红两类残迹本仓都踩过。
final class ProductionScaleReadoutTests: XCTestCase {

    private static let packageRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Tests/TcoderMonitorTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // TcoderMonitor（包根）

    // MARK: - 独立真值（手写的账，一个数都不是从实现里读回来的）

    private enum Truth {
        /// 生产码：`src/App.swift` 6 行 + `src/Widget.swift` 4 行 + `tools/Counter.swift` 3 行。
        /// `tools/` 不是测试/生成/配置目录 ⇒ 那一枚只有**语言证据**（弱判定），仍算生产码。
        static let productionCodeLines = 6 + 4 + 3                            // 13
        static let weakEvidenceFiles = 1                                      // tools/Counter.swift
        /// 测试与夹具 5 行 + 文档 4 行 —— 需求方裁定它们**与生产码同分母**，不摘出去。
        static let nonProductionCodeLines = 5 + 4                             // 9
        /// 全量代码行 = 分母维持不变的那一个数。
        static let allCodeLines = productionCodeLines + nonProductionCodeLines   // 22

        /// 屏上那一句的**完整期望串**：主句 + 弱判定打折句（` · ` 是装配口那条分隔符）。
        static let sentence = "生产码 13 行 / 全量 22 行"
            + " · 生产码里 1 个文件只有语言证据、路径没有线索，读这一档要按它打折"
    }

    /// 手写语料：五枚文件、三档有数（生产 / 测试 / 文档）。
    private var corpus: [String: [String]] {
        [
            "src/App.swift": code("let a", 6),
            "src/Widget.swift": code("let w", 4),
            "tools/Counter.swift": code("let c", 3),
            "tests/AppTests.swift": code("let t", 5),
            "docs/guide.md": prose(4),
        ]
    }

    private func code(_ stem: String, _ n: Int) -> [String] { (1...n).map { "\(stem)\($0) = \($0)" } }
    private func prose(_ n: Int) -> [String] { (1...n).map { "Paragraph line \($0)" } }

    // MARK: - 取数：写夹具 → 走产品侧同一条扫描口（不在测试里另装配一次）

    private func scan(_ files: [String: [String]], tag: String) async throws -> CodeMetrics {
        let fm = FileManager.default
        let root = Self.packageRoot.appendingPathComponent(
            ".scratch/r40-dualnumber-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? fm.removeItem(at: root)
            XCTAssertFalse(fm.fileExists(atPath: root.path), "夹具没删干净就是留下假绿：\(root.path)")
        }
        for (path, content) in files {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((content.joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)
        }
        return try await FileSystemCodeAnalyzer().analyze(root: root, options: .default)
    }

    // MARK: - ⓪ 先自证手写账没数错（数错了下面的断言都不作数）

    func testHandCountedTruthAgreesWithTheFixtureItself() {
        var counted = 0
        for (path, content) in corpus {
            XCTAssertFalse(content.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty },
                           "\(path) 里有空行，手写账是按没有空行数的")
            counted += content.filter { $0.hasPrefix("//") == false }.count
        }
        XCTAssertEqual(counted, Truth.allCodeLines, "逐行数出来的代码行与手写账不等，先修夹具")
    }

    // MARK: - ① 正例：真扫一次，上屏那一句里两个数都是手写的

    func testRealScanSentenceCarriesTheHandCountedNumbers() async throws {
        let metrics = try await scan(corpus, tag: "sentence")
        // 先自证分档落成了我以为的形状（这三条是判据的**输入侧**，与上屏那句无关）。
        let roles = try XCTUnwrap(metrics.fileRoles, "真扫过一次却没落角色分档 ⇒ 写字段那一行没生效")
        let production = try XCTUnwrap(roles.share(for: .production))
        XCTAssertEqual(production.codeLines, Truth.productionCodeLines, "生产码那一档不是手写的 13")
        XCTAssertEqual(metrics.codeLines, Truth.allCodeLines, "全量分母不是手写的 22")
        XCTAssertEqual(production.weakEvidenceFiles, Truth.weakEvidenceFiles)

        XCTAssertEqual(ProductionCodeScaleReadout.reading(metrics), Truth.sentence,
                       "上屏那一句与手写账分叉（或装配口自己另算了一遍分档）")
        // 「并排给」而不是「折进去」：两个数本来就不同，句子里的分母仍是全量那一个。
        XCTAssertNotEqual(Truth.productionCodeLines, Truth.allCodeLines,
                          "夹具没造出差额 ⇒ 上面那句在测空气")
    }

    // MARK: - ② 缺席态一：本次没做角色分档 ⇒ 整句不出声

    func testAbsentRoleBucketingKeepsTheWholeSentenceSilent() throws {
        let metrics = CodeMetrics(totalFiles: 4, totalLines: 5_000, codeLines: 4_000)
        XCTAssertNil(metrics.fileRoles, "夹具本身必须真的没有这一格")
        XCTAssertNil(ProductionCodeScaleReadout.reading(metrics), "没做分档却出声了")
        XCTAssertNil(ProductionCodeScaleReadout.pairedLines(metrics))
        XCTAssertNil(ProductionCodeScaleReadout.measuredZeroNotice(metrics))
        XCTAssertNil(ProductionCodeScaleReadout.weakEvidenceHint(metrics))
        // 整条代码路没跑（`report.code == nil`）走的是同一枚入参形状：也不许出声。
        XCTAssertNil(ProductionCodeScaleReadout.reading(nil))
    }

    /// 旧报告（落盘 JSON 里没有 `fileRoles` 这个键）必须解成 `nil` 而不是补一个空台账，
    /// 并且上屏那一句照旧不出声。
    func testLegacyReportWithoutTheKeyStillDecodesAsNilAndStaysSilent() throws {
        var metrics = CodeMetrics(totalFiles: 4, totalLines: 5_000, codeLines: 4_000)
        metrics.fileRoles = ProductionScaleFixtures.roles(production: 1_200, weak: 0)
        var report = ProjectReport(project: MonitoredProject(name: "旧报告", path: "/tmp/r40"))
        report.code = metrics
        let json = try CLIScan.json(report, compact: true)
        XCTAssertTrue(json.contains("\"fileRoles\""), "夹具没落成带这一格的形状，下面删键就没有意义")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        var code = try XCTUnwrap(object["code"] as? [String: Any])
        code.removeValue(forKey: "fileRoles")
        object["code"] = code
        let decoded = try JSONDecoder.tcoderReportDecoder()
            .decode(ProjectReport.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.code?.fileRoles, "缺键被补成了台账 ⇒ 「没做分档」会长成「做了而全是 0」")
        XCTAssertEqual(decoded.code?.codeLines, 4_000, "删一枚键不该把别人的格子一起弄坏")
        XCTAssertNil(ProductionCodeScaleReadout.reading(decoded.code))
    }

    // MARK: - ③ 缺席态二：做了分档而生产码那一档没数出来 ⇒ `--`，不许折成 0

    func testMissingProductionBucketReadsDashesAndNeverZero() throws {
        let metrics = ProductionScaleFixtures.metrics(
            roles: ProductionScaleFixtures.roles(without: .production, weak: nil, production: 0))
        let line = try XCTUnwrap(ProductionCodeScaleReadout.pairedLines(metrics))
        XCTAssertTrue(line.contains("生产码 --"), "没数出来那一支没打 --：\(line)")
        XCTAssertFalse(line.contains("生产码 0"), "把「没数出来」折成了 0：\(line)")
        XCTAssertTrue(line.contains("这一档没数出来"), "缺数那句说明没出来：\(line)")
        // 全量那一个数照常给（它是量到的，与生产档在不在无关），并且千分位仍走同一把尺子。
        XCTAssertTrue(line.contains("全量 3,000 行"), "全量分母没带上或没分组：\(line)")

        // 「没数出来」与「真的是 0」必须长成两句话 —— 本单最容易被抹平的一对。
        let reallyZero = ProductionScaleFixtures.metrics(
            roles: ProductionScaleFixtures.roles(production: 0, weak: nil))
        let zeroLine = try XCTUnwrap(ProductionCodeScaleReadout.reading(reallyZero))
        XCTAssertNotEqual(line, zeroLine, "两支塌回同一句 = 又一次语义塌陷")
        XCTAssertTrue(zeroLine.contains("生产码 0 行"), "真 0 那一支不许打 --：\(zeroLine)")
    }

    // MARK: - ④ 缺席态三：生产码档真的是 0 ⇒ 明说是零，并且不许下「没有源码」的结论

    func testMeasuredZeroBucketSaysZeroAndDrawsNoConclusion() throws {
        let metrics = ProductionScaleFixtures.metrics(
            roles: ProductionScaleFixtures.roles(production: 0, weak: 0))
        let line = try XCTUnwrap(ProductionCodeScaleReadout.reading(metrics))
        XCTAssertTrue(line.hasPrefix("生产码 0 行 / 全量 3,000 行"), "真 0 的主句：\(line)")
        XCTAssertTrue(line.contains("生产码这一档这次量到的是零，不是没数出来"),
                      "量到的 0 是结论，这一句必须跟着出来：\(line)")
        for conclusion in ["没有源码", "没有有效代码", "不是项目", "空仓库", "无源码", "没有一行代码"] {
            XCTAssertFalse(line.contains(conclusion),
                           "顺势下了一个「这个项目没有源码」式结论 ⇒ 越界：\(conclusion) / \(line)")
        }
        // 弱判定记过了而真的是 0 ⇒ 打折那句不许出来（零命中不出声）。
        XCTAssertFalse(line.contains("按它打折"), "弱判定 0 个却念了打折那句：\(line)")
    }

    // MARK: - ⑤ 弱判定那一格：> 0 才出声，nil 与 0 都不许冒充「有」

    func testWeakEvidenceHintSpeaksOnlyWhenRecorded() throws {
        let recorded = ProductionScaleFixtures.metrics(
            roles: ProductionScaleFixtures.roles(production: 900, weak: 7))
        let hint = try XCTUnwrap(ProductionCodeScaleReadout.weakEvidenceHint(recorded))
        XCTAssertEqual(hint, "生产码里 7 个文件只有语言证据、路径没有线索，读这一档要按它打折")
        XCTAssertTrue(try XCTUnwrap(ProductionCodeScaleReadout.reading(recorded)).hasSuffix(hint),
                      "打折那句没并到上屏那一行末尾")

        // `nil` = 这一格没记（契约里它只挂生产档）⇒ 不许补 0 后说成「一个弱判定都没有」。
        let unrecorded = ProductionScaleFixtures.metrics(
            roles: ProductionScaleFixtures.roles(production: 900, weak: nil))
        XCTAssertNil(ProductionCodeScaleReadout.weakEvidenceHint(unrecorded))
        // `0` = 记过了而真的没有 ⇒ 同样不出声，但主句照旧要响。
        let zero = ProductionScaleFixtures.metrics(
            roles: ProductionScaleFixtures.roles(production: 900, weak: 0))
        XCTAssertNil(ProductionCodeScaleReadout.weakEvidenceHint(zero))
        XCTAssertNotNil(ProductionCodeScaleReadout.reading(zero))
    }

    // MARK: - ⑥ 分数一点没动（这一单的边界：只加一句上屏话，不碰评分）

    /// 同一份夹具，`fileRoles` 不给 / 给一份「生产码只占 1 行」的极端形状 ——
    /// 综合分与每一维的分数必须**一字不变**。谁哪天把生产档接成分母，这里当场红。
    func testScoringIgnoresTheNewSentenceEntirely() throws {
        var plain = CodeMetrics(totalFiles: 40, totalLines: 26_000, commentLines: 3_000,
                                codeLines: 20_000)
        plain.fileRoles = nil
        var bucketed = plain
        bucketed.fileRoles = ProductionScaleFixtures.roles(production: 1, weak: 0)

        let scorer = WeightedHealthScorer()
        let before = scorer.score(HealthInputs(code: plain))
        let after = scorer.score(HealthInputs(code: bucketed))
        XCTAssertEqual(before.overall, after.overall,
                       "综合分被这一句动了：\(String(describing: before.overall)) vs \(String(describing: after.overall))")
        XCTAssertEqual(before.components.map { "\($0.name):\($0.score)" },
                       after.components.map { "\($0.name):\($0.score)" },
                       "某一维的分数或依据被动了")
        // 而这一句本身给的分母仍是 `codeLines`（不是被换小的那一个）。
        let line = try XCTUnwrap(ProductionCodeScaleReadout.reading(bucketed))
        XCTAssertTrue(line.contains("全量 20,000 行"), "句子里的分母不是 codeLines 本身：\(line)")
        XCTAssertTrue(line.contains("生产码 1 行"), "生产码那一档没并进这一句：\(line)")
    }
}

// MARK: - 夹具装配（本文件与守卫文件共用；只造 `CodeMetrics`，不造句子）

/// 手工搭一枚 `CodeMetrics` + 八档台账，用于测「上屏那句」而不测「分档怎么判」——
/// 判据那一侧由 `CodeFileRoleContractTests` 与 `SourceRoleTruthTests` 各自钉着。
enum ProductionScaleFixtures {

    /// 八档全量、生产档 `codeLines = production`、弱判定只挂生产档。
    static func roles(production: Int, weak: Int?) -> CodeFileRoles {
        roles(without: nil, weak: weak, production: production)
    }

    /// 同上，但可以**摘掉某一档**（那是「这一档没数出来」的形状，不是「这一档是 0」）。
    static func roles(without missing: SourceFileRole?, weak: Int?, production: Int) -> CodeFileRoles {
        let shares = SourceFileRole.allCases.compactMap { role -> CodeFileRoleShare? in
            guard role != missing else { return nil }
            let isProduction = role == .production
            let lines = isProduction ? production : 0
            return CodeFileRoleShare(role: role.rawValue, fileCount: isProduction ? 1 : 0,
                                     codeLines: lines, totalLines: lines,
                                     weakEvidenceFiles: isProduction ? weak : nil,
                                     samplePaths: isProduction ? ["src/App.swift"] : [])
        }
        return CodeFileRoles(shares: shares, criterionCounts: nil,
                             attributedFileCount: shares.map(\.fileCount).reduce(0, +))
        // 其余七档给 0 是本夹具的简化：本文件测的是生产档那三条态，别的档不参与。
    }

    /// 全量分母固定 3,000 行（够大，能把千分位那把尺子也一并走到）。
    static func metrics(roles: CodeFileRoles?) -> CodeMetrics {
        var metrics = CodeMetrics(totalFiles: 12, totalLines: 4_000, commentLines: 500,
                                  codeLines: 3_000)
        metrics.fileRoles = roles
        return metrics
    }
}
