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

    // MARK: - G7 取证窗口不许把"没拍到"混成"复核通过"

    /// 取证尺寸覆盖点：**没设环境变量必须还是产品默认值**。
    /// 否则这条"复核通过"的证据可以被人悄悄换成一个刚好把问题裁掉的窗口。
    func test_captureWindowOverrideDefaultsToTheProductSize() {
        XCTAssertEqual(CaptureWindow.defaultWidth, 1280)
        XCTAssertEqual(CaptureWindow.defaultHeight, 820)
        XCTAssertEqual(CaptureWindow.dimension(from: nil, fallback: CaptureWindow.defaultHeight), 820,
                       "没给环境变量时改了默认值 —— 取证口径与产品口径分家")
        // 越界与乱输入一律退回默认，而不是接受一个会产出废图的尺寸。
        for bad in ["1", "99999", "abc", ""] {
            XCTAssertEqual(CaptureWindow.dimension(from: bad, fallback: 820), 820,
                           "非法值 `\(bad)` 被接受了：会拍出一张看起来通过、其实什么都看不见的图")
        }
        XCTAssertEqual(CaptureWindow.dimension(from: "1000", fallback: 820), 1000)
        XCTAssertEqual(CaptureWindow.dimension(from: "680", fallback: 820), 680, "下界必须可达")
        XCTAssertEqual(CaptureWindow.dimension(from: "4000", fallback: 820), 4000, "上界必须可达")
    }

    /// 取证滚动开关：不设 = 完全不生效；只有字面量 `bottom` 生效。
    /// 拼错的值必须按"没设"处理 —— 取证宁可少拍一趟，也不要按猜出来的语义滚动，
    /// 那会让"拍到的到底是哪一屏"无法复述。
    func test_captureScrollOnlyHonoursTheExactValue() {
        XCTAssertFalse(CaptureScroll.isBottom(nil), "没设环境变量时不该滚动")
        XCTAssertFalse(CaptureScroll.isBottom(""), "空串不等于 bottom")
        XCTAssertFalse(CaptureScroll.isBottom("Bottom"), "大小写不敏感等于给拼写错误开门")
        XCTAssertFalse(CaptureScroll.isBottom("top"), "未定义的值不该被当成有效档位")
        XCTAssertTrue(CaptureScroll.isBottom("bottom"))
    }

    // MARK: - 元测试：每条尺子都必须抓得住合成违规，且不误伤合法写法

    // MARK: - G6 三档按钮必须真的不一样（同链两个 buttonStyle，内层赢）

    /// `GlassButton` 里不得再出现裸 `.buttonStyle(`：样式一律经 `glassButtonStyle(_:)` 给。
    ///
    /// 起因（2026-09-21 实拍）：`GlassButton.body` 原先写
    /// `Button { … }.buttonStyle(.plain).glassButtonStyle(style)`。
    /// SwiftUI 解析环境值时**离 `Button` 最近的那个 style 赢**，于是 `.plain` 把
    /// 外面三档全压掉 —— 主行动（墨填充胶囊）、次级（玻璃）、文字按钮在界面上
    /// 长成同一个灰字。九张实拍里没有一个按钮有底色，用户判词「没有主次」
    /// 「按钮跟参考图不一样」在控件层的根因就是这一行，而它躲过了全部既有守卫。
    static func doubleButtonStyles(in files: [(path: String, content: String)]) -> [String] {
        hits([".buttonStyle("], in: files)
    }

    /// 取 `struct <Name>` 到第一个顶格 `}` 之间的正文。
    static func structBody(named name: String, in content: String) -> String {
        var collecting = false
        var out: [String] = []
        for line in content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if !collecting {
                if line.hasPrefix("struct \(name)") { collecting = true }
                continue
            }
            if line == "}" { break }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    func test_glassButtonDoesNotShadowItsOwnStyle() throws {
        let glass = try XCTUnwrap(
            try sources().first { $0.path.hasSuffix("Design/GlassComponents.swift") })
        let body = Self.structBody(named: "GlassButton", in: glass.content)
        XCTAssertFalse(body.isEmpty, "没读到 GlassButton 的 body，这条判据在空转")
        XCTAssertTrue(Self.doubleButtonStyles(in: [(path: "Design/GlassComponents.swift",
                                                   content: body)]).isEmpty,
                      "GlassButton 在同一条链上又写了裸 `.buttonStyle(`，它会盖掉 "
                      + "glassButtonStyle 的三档 —— 主行动与文字按钮长成同一个灰字。")
        XCTAssertTrue(body.contains(".glassButtonStyle(style)"),
                      "GlassButton 不再经 glassButtonStyle 分档 —— 三档样式成了死代码")
    }

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

    /// G8：覆盖率那一维的「没数据」必须说清是**哪一种**没数据。
    /// 三档合成一句「该项目没有产出覆盖率报告」= 拿「没读到」冒充「没有」（§S2）。
    func test_coverageAbsenceNamesTheActualInputState() {
        XCTAssertEqual(MissingDimensionReason.testingAbsence(coverage: nil), "尚未分析覆盖率报告，不参与计分。",
                       "没跑过分析 = 状态未知，不能替项目下「没有产出报告」的结论")

        let foundButUnreadable = CoverageMetrics(reports: [], scannedFileCount: 2)
        let unreadable = MissingDimensionReason.testingAbsence(coverage: foundButUnreadable) ?? ""
        XCTAssertTrue(unreadable.contains("扫到 2 个"), "扫到了报告文件这件事必须上屏：\(unreadable)")
        XCTAssertFalse(unreadable.contains("没有产出覆盖率报告"),
                       "读不出数字被说成没有报告：\(unreadable)")

        let nothingFound = CoverageMetrics(reports: [], scannedFileCount: 0)
        let note = MissingDimensionReason.testingAbsence(coverage: nothingFound) ?? ""
        XCTAssertTrue(note.contains("没有产出覆盖率报告"), "真的没有报告时这句必须还在：\(note)")
    }

    /// G6 的两向元测试：老写法必须被抓到，`AnalysisSectionRow` 那种
    /// "只有一个 style" 的合法写法不许误伤（它本来就该是 plain 的导航行）。
    func test_buttonStyleScannerCatchesTheShadowingShape() {
        let shadowing = [(path: "Design/GlassComponents.swift", content: """
        Button(action: action) { Text(t) }
        .buttonStyle(.plain)
        .glassButtonStyle(style)
        """)]
        XCTAssertEqual(Self.doubleButtonStyles(in: shadowing).count, 1,
                       "同链两个 style 没抓到 → 三档按钮又会全部退成 plain 而没人知道")

        let legal = [(path: "Design/GlassComponents.swift", content: """
        Button(action: action) { Text(t) }
        .glassButtonStyle(style)
        """)]
        XCTAssertTrue(Self.doubleButtonStyles(in: legal).isEmpty,
                      "只经 glassButtonStyle 分档的合法写法被误伤")
    }

    func test_enumCaseScannerHandlesBothShapes() {        let withValues = "enum E: String {\n    case idle\n    case scanning = \"s\"\n    case done(x: Int)\n}\n"
        XCTAssertEqual(Self.enumCaseNames(enum: "E", in: withValues), ["idle", "scanning", "done"])
        XCTAssertTrue(Self.enumCaseNames(enum: "Missing", in: "struct S {}").isEmpty)
    }

    // MARK: - 交付包自己的文案里不许留模板占位（P25 抓到的一条）

    /// 模板残留的词。命中即视为"这份包在对外说一件不成立的事"。
    static let bundlePlaceholderWords = ["示例项目", "示例数据", "YourCompany", "TEMPLATE", "TODO"]

    static func bundlePlaceholderHits(_ text: String, words: [String] = bundlePlaceholderWords) -> [String] {
        words.filter { text.localizedCaseInsensitiveContains($0) }
    }

    /// `NSHumanReadableCopyright` 一度是模板留下的 `Tcoder 示例项目` ——
    /// 它在「关于 Tcoder」面板里当着用户的面写"示例项目"，而本批刚把示例数据整条退役（P7-A）。
    /// 这条守卫钉的是**交付包自己的元数据**，不在九页取证面里，所以只能这样钉。
    func test_shippedInfoPlistHasNoTemplatePlaceholder() throws {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TcoderMonitorTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // TcoderMonitor
            .appendingPathComponent("Resources/Info.plist").path
        let text = try XCTUnwrap(String(contentsOfFile: path, encoding: .utf8), "读不到 Info.plist")
        XCTAssertTrue(text.count > 200, "Info.plist 只读到 \(text.count) 字符，八成是路径变了 ⇒ 这条守卫数不出东西")
        let hits = Self.bundlePlaceholderHits(text)
        XCTAssertTrue(hits.isEmpty, "交付包元数据里留着模板占位词 \(hits)——关于面板会当着用户说假话")
    }

    func test_bundlePlaceholderScannerCatchesSyntheticLeftover() {
        XCTAssertEqual(Self.bundlePlaceholderHits("<string>Tcoder 示例项目</string>"), ["示例项目"],
                       "模板残留没被抓到 ⇒ 上面那条守卫是永真绿")
        XCTAssertTrue(Self.bundlePlaceholderHits("<string>© 2026 Tcoder</string>").isEmpty, "正常文案被误伤")
    }
}
