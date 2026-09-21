import Foundation
import XCTest
@testable import TcoderMonitor

// MARK: - 功能真实性守卫（验收主诉第⑦条）
//
// 权威 = `docs/功能真实性清单.md`。用户 2026-09-21 的原话：
// **「所有功能都要正常使用，不能有假数据 或者假的死页面」**
//
// 为什么这些判据要成机器断言：本批的三条病灶都不是"写坏了"，而是**写对了形状、内容却是空的**
// —— 示例数据首启自动装载（首屏九页全是编的）、无证据时 `overall` 留 0 被总览画成"0 分 E 级"、
// `AnalysisPhase` 五档进度从未被赋值所以五路并行时一直说"正在扫描代码规模"、
// 正则编译失败退回一个永不匹配的表达式于是函数数静默归零。
// 这四种失效**都能通过既有的全部观感与结构守卫**，因为守卫查的是"有没有画错"，
// 而这里是"画的那件事根本没发生"。

final class FunctionalHonestyGuardTests: XCTestCase {

    // MARK: - 尺子（纯函数，供合成输入元测试）

    /// 整行注释豁免。理由与 `BorderlessSurfaceGuardTests.shadowHits` 同：
    /// 退役历史必须能在代码里被读到，否则一年后就没人知道为什么少了五个枚举 case。
    ///
    /// **行号取的是原文件行号**：这里一度改用 `SurfaceScanKit.codeLines`（先去掉注释行
    /// 再 enumerated），于是报出来的行号是"过滤后第几行"，四条命中里三条指向无关代码。
    /// 扫描器报错过行 = 把每条工单变成一次考古（本仓既有规矩：扫描器必须报原始行号）。
    static func hits(_ needles: [String], in files: [(path: String, content: String)]) -> [String] {
        files.flatMap { file in
            file.content.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .compactMap { index, raw in
                    let line = String(raw)
                    guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { return nil }
                    return needles.contains(where: line.contains) ? "\(file.path):\(index + 1)" : nil
                }
        }
    }

    /// 直接读 `health.overall` / `.grade` 而不走 `verdict` 的位置。
    /// 只认"评分对象 + 点号 + overall/grade"这一族写法，`codeScope.overall`（子分数，
    /// 它自己带 Optional 语义）与 `last.score` 不在其列。
    static func rawHealthVerdictReads(in files: [(path: String, content: String)]) -> [String] {
        hits(["health?.overall", "health.overall", "health?.grade", "health.grade"], in: files)
    }

    /// 编造数据的形状：整条示例链路 + 示例专属字面量。
    static let fabricationNeedles = [
        "DemoData", "isDemo", "demo://", "DemoBadge", "@example.dev", "张三", "李四",
    ]

    /// 永不匹配的正则兜底 —— 它把"规则坏了"伪装成"这个项目真的没有"。
    static let silentRegexFallbackNeedles = ["\"(?!x)x\""]

    // MARK: - 真源码

    private func sources() throws -> [(path: String, content: String)] {
        let all = try SurfaceScanKit.sourceFiles(under: "")
        // 反向自证：扫不到足够文件就说明路径口径失效，下面所有"没扫到=通过"会集体假绿。
        XCTAssertGreaterThan(all.count, 60, "只扫到 \(all.count) 个源文件，扫描口径可疑")
        return all
    }

    // MARK: - G1 假数据不得回潮

    func test_noFabricatedProjectDataAnywhereInSources() throws {
        let hits = Self.fabricationNeedles.isEmpty ? [] : Self.hits(Self.fabricationNeedles, in: try sources())
        XCTAssertTrue(hits.isEmpty,
                      "内置示例数据已于批次 P7-A 退役；这些位置又把它请回来了：\(hits)。"
                      + "需要演示数据请用取证沙箱指向一个真实仓库（scripts/capture_pages_isolated.sh）。")
    }

    func test_demoServiceDirectoryIsGone() throws {
        let paths = try SurfaceScanKit.sourceFiles(under: "").map(\.path)
        XCTAssertTrue(paths.contains { $0.hasPrefix("Services/") }, "扫描口径可疑")
        let back = paths.filter { $0.contains("Demo") }
        XCTAssertTrue(back.isEmpty, "示例数据服务又长回来了：\(back)")
    }

    // MARK: - G2 无证据不得成结论

    /// 行为断言：分量全缺席时，模型**拿不出**一个分、一个等级、一条趋势。
    func test_scoreWithoutComponentsYieldsNoVerdictNoGradeNoTrend() {
        let noEvidence = HealthScore(computedAt: Date(), overall: 0, previousOverall: 81,
                                     components: [], narrative: "缺证据")
        XCTAssertNil(noEvidence.verdict, "0 分被当成结论交出去了（总览会画红环 + E 级）")
        XCTAssertNil(noEvidence.verdictGrade)
        XCTAssertNil(noEvidence.trendDelta,
                     "占位 0 减上次 81 会画出一个\"暴跌 81 分\"的箭头 —— 那是编的")

        let one = ScoreComponent(name: "代码复杂度", score: 62, weight: 0.3,
                                 detail: "平均 CC 6.2", risk: .low)
        let withVerdict = HealthScore(computedAt: Date(), overall: 62, previousOverall: 58,
                                      components: [one])
        XCTAssertEqual(withVerdict.verdict, 62, "有分量时 verdict 必须原样放行，否则这条守卫只是禁言")
        XCTAssertEqual(withVerdict.trendDelta, 4)
        XCTAssertNotNil(withVerdict.verdictGrade)
    }

    /// 静态断言：视图与落盘只许读 `verdict`。`overall` 是评分器的内部量，
    /// 直接读它就等于绕开"有没有证据"这一问。
    func test_viewsAndPersistenceReadVerdictNotOverall() throws {
        let watched = try sources().filter {
            $0.path.hasPrefix("Views/") || $0.path.hasPrefix("App/")
        }
        let hits = Self.rawHealthVerdictReads(in: watched)
        XCTAssertTrue(hits.isEmpty,
                      "这些位置直接读 `health.overall`/`.grade`，缺证据时会渲染成 0 分：\(hits)。"
                      + "请改走 `HealthScore.verdict` / `verdictGrade`。")
        // 元测试的另一半：判据必须真的能命中真源码里的 verdict 写法（否则是空转）。
        XCTAssertTrue(watched.contains { $0.content.contains("health?.verdict") },
                      "全仓没有一处 `health?.verdict` —— 上面那条断言就成了永真绿")
    }

    /// 依赖页：没有核对覆盖就不许出现"无风险"着色。
    func test_dependencyOfflineStateIsNotClaimedSafe() throws {
        let offline = DependencyReport()
        XCTAssertFalse(offline.hasVulnerabilityCoverage,
                       "默认离线态必须判为\"没查\"，否则下面这条守卫在空转")
        XCTAssertEqual(offline.riskLevel, .none,
                       "`riskLevel` 仍按数说话（评分与排序要它），这条钉住它的语义没被顺手改掉")
        XCTAssertTrue(DependencySafetyVerdict(offline) == .unchecked(coveredCount: 0, total: 0,
                                                                    uncoveredEcosystems: []),
                      "同一份离线报告在两个判定处给出不同结论")

        let depsDir = try sources().filter { $0.path.contains("/Views/Dependencies/") }
        let bypass = Self.hits(["role(for: deps.riskLevel)"], in: depsDir)
        XCTAssertTrue(bypass.isEmpty,
                      "依赖页又拿 `riskLevel` 直接着色了（零命中≠已核对）：\(bypass)")
    }

    // MARK: - G3 降级必须可观测

    func test_noNeverMatchingRegexFallback() throws {
        let hits = Self.hits(Self.silentRegexFallbackNeedles, in: try sources())
        XCTAssertTrue(hits.isEmpty,
                      "正则编译失败退回\"永不匹配\"的表达式 = 把规则坏了伪装成\"这个项目真的没有\"：\(hits)。"
                      + "要兜底就必须同时把降级记进台账并上屏（见 docs/功能真实性清单.md 2-6/2-7）。")
    }

    // MARK: - G4 枚举不得只定义不使用

    /// `AnalysisPhase` 的每一档都必须有生产赋值点。
    ///
    /// 这条守卫的来历就是它自己查的那种病：原来 `.git/.logs/.dependencies/.health`
    /// 四档从未被赋值（五路是 `async let` 并行的，压根没有"现在在做哪一路"），
    /// 于是并行扫描期间界面恒说"正在扫描代码规模…"，五路全失败也说"分析完成"。
    func test_everyAnalysisPhaseCaseIsActuallyReached() throws {
        let all = try sources()
        let enumFile = try XCTUnwrap(
            all.first { $0.path.hasSuffix("Models/Project.swift") }, "找不到 AnalysisPhase 所在文件")
        let cases = Self.enumCaseNames(enum: "AnalysisPhase", in: enumFile.content)
        XCTAssertEqual(Set(cases), ["idle", "scanning", "finished", "failed"],
                     "枚举成员变了：现量 \(cases)。新增一档就必须同时给出它的赋值点与文案")

        let unassigned = Self.unassignedCases(cases, in: all)
        XCTAssertTrue(unassigned.isEmpty,
                      "这些阶段只有定义、没有生产赋值点，界面上的进度文案就是在编：\(unassigned)")
    }

    /// 哪些枚举成员**在 App/ 里从未出现在任何一行含 `phase` 的代码上**。
    /// 写成纯函数是为了能被合成输入喂到"非空"那一侧（见元测试），否则这条判据是永真绿。
    static func unassignedCases(_ cases: [String],
                                in files: [(path: String, content: String)]) -> [String] {
        let lines = files.filter { $0.path.hasPrefix("App/") }
            .flatMap { SurfaceScanKit.codeLines($0.content) }
            .filter { $0.contains("phase") }
        return cases.filter { name in !lines.contains { $0.contains(".\(name)") } }
    }

    static func enumCaseNames(enum name: String, in content: String) -> [String] {
        guard let range = content.range(of: "enum \(name)") else { return [] }
        var found: [String] = []
        for raw in content[range.lowerBound...].split(separator: "\n").prefix(24) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("case ") else {
                if line.hasPrefix("}") { break }
                continue
            }
            let head = line.dropFirst(5)
                .split(whereSeparator: { $0 == ":" || $0 == "=" || $0 == " " || $0 == "(" })
                .first.map(String.init) ?? ""
            if !head.isEmpty { found.append(head) }
        }
        return found
    }

    /// 死代码不得靠"以后会接"留在仓里：`markPhase` 是那条假进度的落盘端，已删。
    func test_deadPhasePersisterStaysDeleted() throws {
        let store = try sources().first { $0.path.hasSuffix("Services/ProjectStore.swift") }
        XCTAssertFalse((store?.content ?? "").contains("func markPhase"),
                       "`markPhase` 回来了但依然没有调用者 —— 那就是第二套口径的起点")
    }

    // MARK: - 元测试：每条尺子都必须抓得住合成违规，且不误伤合法写法

    func test_scannersCatchSyntheticViolationsAndSpareLegalOnes() {
        let dirty = [(path: "Services/Demo/Fake.swift",
                      content: "let p = MonitoredProject(path: \"demo://x\", isDemo: true)\n")]
        XCTAssertFalse(Self.hits(Self.fabricationNeedles, in: dirty).isEmpty,
                       "假数据扫描器失灵：示例项目回来了也不会红")

        let legal = [(path: "Views/Shell/ProjectSidebar.swift",
                      content: "HealthDot(score: report?.health?.verdict)\n")]
        XCTAssertTrue(Self.rawHealthVerdictReads(in: legal).isEmpty,
                      "合法写法被误伤 → 下次有人直接把整条守卫删掉")
        let dirtyVerdict = [(path: "Views/Shell/DashboardHero.swift",
                             content: "HealthRing(score: health?.overall)\n")]
        XCTAssertEqual(Self.rawHealthVerdictReads(in: dirtyVerdict).count, 1,
                       "0 分冒充结论的那条路没抓到")

        let dirtyRegex = [(path: "Services/Code/Fake.swift",
                           content: "let re = try? NSRegularExpression(pattern: \"(?!x)x\")\n")]
        XCTAssertEqual(Self.hits(Self.silentRegexFallbackNeedles, in: dirtyRegex).count, 1,
                       "静默正则兜底扫描器失灵")

        let commented = [(path: "App/AppState.swift",
                          content: "// 原来这里 `loadDemoProject()`，于是首屏九页全是编造读数\n")]
        XCTAssertTrue(Self.hits(Self.fabricationNeedles, in: commented).isEmpty,
                      "注释里交代退役历史就被判红 → 一年后没人记得它为什么错")
    }

    func test_enumCaseScannerHandlesBothShapes() {
        let withValues = "enum E: String {\n    case idle\n    case scanning = \"s\"\n    case done(x: Int)\n}\n"
        XCTAssertEqual(Self.enumCaseNames(enum: "E", in: withValues), ["idle", "scanning", "done"])
        XCTAssertTrue(Self.enumCaseNames(enum: "Missing", in: "struct S {}").isEmpty)
    }
}
