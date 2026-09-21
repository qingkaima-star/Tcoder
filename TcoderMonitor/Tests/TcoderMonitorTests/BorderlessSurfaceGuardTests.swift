import Foundation
import SwiftUI
import XCTest
@testable import TcoderMonitor

// MARK: - 「简约无界」风格契约守卫
//
// 权威 = `docs/superpowers/specs/2026-09-20-borderless-minimal-ui-redesign-design.md` §1 与 §6.1。
//
// 为什么需要这个文件：上一轮（WS-G/H/I）已经把**设计纪律**还清了 —— 实测全仓只有 1 处
// `.shadow(`、`Views/` 里 0 处硬编码 `.padding(_, N)`、只剩 2 处裸 `Font.system(size:)`。
// 也就是说「页面有没有守规范」这条线早就绿了，而界面照样难看。**病因在令牌的取值本身**：
// 内容层填 `.regularMaterial`，材质背后无内容时在 macOS 上退化成平涂半透明灰，
// 实测每层都比窗口白底更暗（`#FFFFFF → #E9EBED → #E3E5E7`，相邻只有 1.05:1，
// 低于人眼约 1.15:1 的分层阈值），叠三层就是「黑黢黢、很脏」。
//
// 所以旧守卫查不出这一类问题：它查「有没有散写魔法数」，而本轮的病灶恰恰是
// **令牌定义了却没人用**（`Theme.Palette.Surface.card` 早在 `controlBackgroundColor` 上
// 定义好了，全仓零引用）。本文件因此两个方向都查：画了不该画的、以及定义了没人用的。

final class BorderlessSurfaceGuardTests: XCTestCase {

    /// **M2 接线闸门**。三条页面流合完后，实施计划 Task 10 必须把它改成 `true`。
    ///
    /// 为什么要有这个东西而不是直接断言：`Surface.ground` 挂到滚动容器、以及
    /// `Spacing.group` / `pageMargin` / `section` 被页面引用，都是 M1 的活。
    /// 在 M0 就硬断言，会逼出「为了过门随手涂一个 background」的假接线；
    /// 而把测试整个删掉等 M2 再写，就会忘掉（上一轮的 `Spacing.section` 就是这么烂掉的）。
    /// `XCTSkipIf` 取的是中间那条路：**测试在场、当前不拦路、且在输出里显式报 skipped**。
    /// **已于 M2 翻成 `true`**（三家合完后由总工执行，实施计划 Task 10）。
    /// 翻 true 的依据不是"感觉接完了"，是下面两条硬断言当时真的跑起来了：
    /// `Surface.ground` 被 `ProjectDetailView` 引用（WS-O 接线）、
    /// `Spacing.group/section/pageMargin` 被 `Views/**` 引用（三家各自引用）。
    private static let m2WiringComplete = true

    // MARK: - 扫描器（纯函数，供合成输入元测试）

    /// `.shadow(` 的命中位置（整行注释豁免：文档里必须提到被禁的写法）。
    static func shadowHits(in files: [(path: String, content: String)]) -> [String] {
        files.flatMap { file in
            file.content
                .split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .compactMap { index, raw in
                    let line = String(raw)
                    guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { return nil }
                    return line.contains(".shadow(") ? "\(file.path):\(index + 1)" : nil
                }
        }
    }

    /// 定义了但全仓零引用的 `Theme.Palette.Surface.*` 成员名。
    static func unreferencedSurfaceMembers(defined: [String],
                                           references: Set<String>) -> [String] {
        defined.filter { !references.contains($0) }
    }

    /// 内容层/兜底层的**禁用材质**命中位置。整行注释豁免 —— 理由与 `shadowHits` 同：
    /// 表面系统的头注释必须能解释「旧写法是什么、为什么错」，否则这段历史一年后就没人知道。
    /// （本守卫第一次跑就抓到**自己**漏了这条豁免：注释里正当提到的 `.regularMaterial`
    /// 被判成违规。这就是扫描型守卫不带元测试的下场。）
    static func forbiddenMaterialUses(in files: [(path: String, content: String)]) -> [String] {
        files.flatMap { file in
            codeLines(file.content)
                .enumerated()
                .filter { _, line in
                    line.contains(".regularMaterial") || line.contains("ultraThinMaterial")
                        || line.contains(".thinMaterial")
                }
                .map { "\(file.path):\($0.offset + 1)" }
        }
    }

    /// 去掉整行注释后的代码行。判据本体在 `SurfaceScanKit`，两份守卫共用一把尺子。
    static func codeLines(_ content: String) -> [String] {
        SurfaceScanKit.codeLines(content)
    }

    /// 落在「承载测得值的 Text」上的 `.tertiary`。
    /// 判据形状：同一行里既有 `.tertiary` 又有取值表达式（`DataAbsence` / `NumberFormat` /
    /// `ByteFormat` / `value:`）—— 路径与时间戳不在此列，它们本来就是次要元数据。
    static func tertiaryOnMeasuredValues(in files: [(path: String, content: String)]) -> [String] {
        let markers = ["DataAbsence", "NumberFormat", "ByteFormat", "value:"]
        return files.flatMap { file in
            codeLines(file.content)
                .enumerated()
                .compactMap { index, line in
                    guard line.contains(".tertiary") else { return nil }
                    return markers.contains(where: line.contains)
                        ? "\(file.path):\(index + 1)" : nil
                }
        }
    }

    /// 绕过 `.typed(...)` 直接用 `.font(<token>.font)` 套**带字距令牌**的位置。
    /// `Font` 没有字距 API，字距只在 `Text`/`View` 层，所以这种写法会静默丢掉字距。
    static func trackingDroppingUses(in files: [(path: String, content: String)],
                                    tokenNamed name: String) -> [String] {
        files.flatMap { file in
            codeLines(file.content)
                .enumerated()
                .compactMap { index, line in
                    line.contains("Typo.\(name).font") ? "\(file.path):\(index + 1)" : nil
                }
        }
    }

    // MARK: - 真源码定位（尺子本体在 `SurfaceScanKit.swift`，两份守卫共用）

    static func sourceFiles(under subpath: String) throws -> [(path: String, content: String)] {
        try SurfaceScanKit.sourceFiles(under: subpath)
    }

    private static func surfaceReferences(in files: [(path: String, content: String)]) -> Set<String> {
        var found: Set<String> = []
        for file in files {
            for line in file.content.split(separator: "\n") {
                guard let range = line.range(of: "Surface.") else { continue }
                let name = String(line[range.upperBound...].prefix { $0.isLetter || $0.isNumber })
                if !name.isEmpty { found.insert(name) }
            }
        }
        return found
    }

    // MARK: - 契约 1/2/3：内容层不得画面

    func test_contentLayerDrawsNoMaterial() throws {
        let glass = try XCTUnwrap(
            Self.sourceFiles(under: "Design").first { $0.path.hasSuffix("Glass.swift") })
        let hits = Self.forbiddenMaterialUses(in: [glass])
        XCTAssertTrue(hits.isEmpty,
                      "表面系统里仍有材质填充（风格契约 1，实测会糊成 1.05:1 的脏灰）：\(hits)")
        XCTAssertTrue(glass.content.contains("case .content:"),
                      "内容层必须仍然存在（页面有 40 处靠它拿掉面板）")
    }

    /// **守卫补漏（2026-09-20 实拍抓到）**：原来只扫 `Design/`，于是
    /// `ContributorRows` 在页面里写 `.background(.regularMaterial, …)` 做一个悬停浮层，
    /// 本守卫**看不见**。材质被禁的理由是"它比页面底暗 1.05:1、糊成脏灰"，
    /// 这跟它写在哪个目录无关 —— 只扫基座等于漏掉 90% 的落点。
    /// 现在扫全仓 `Sources/**`。页面要浮层请用 `.surface(layer: .floating, …)`。
    func test_noMaterialAnywhereInSources() throws {
        let all = try Self.sourceFiles(under: "")
        let hits = Self.forbiddenMaterialUses(in: all)
        XCTAssertTrue(hits.isEmpty,
                      "全仓仍有材质填充（含页面里散写的）。悬停/浮层请用 "
                      + "`.surface(layer: .floating, shape: .rounded(Theme.Radius.sm))`。\(hits)")
    }

    // MARK: - 反「定义了没人用」：本轮病因的复发检测

    func test_surfaceTokensAreActuallyReferenced() throws {
        let all = try Self.sourceFiles(under: "")
        XCTAssertGreaterThan(all.count, 40, "只扫到 \(all.count) 个文件，路径口径可疑")

        let defined = ["card", "window", "separator", "ground", "well", "control", "ink"]
        let dead = Self.unreferencedSurfaceMembers(
            defined: defined, references: Self.surfaceReferences(in: all))

        // `ground` 在 M0 只定义不接线（挂到滚动容器是 WS-O 的活）。M2 必须连这条一起清。
        let m0Exempt: Set<String> = Self.m2WiringComplete ? [] : ["ground"]
        let real = dead.filter { !m0Exempt.contains($0) }
        XCTAssertTrue(real.isEmpty,
                      "定义了却全仓零引用的表面令牌（本轮病因原样复发）：\(real)")

        if Self.m2WiringComplete {
            XCTAssertTrue(Self.surfaceReferences(in: all).contains("ground"),
                          "M2 已宣告接线完成，但 ground 仍零引用")
        }
    }

    // MARK: - 契约 4：字号跨度、纯墨、字距不许被绕过

    func test_borderlessTypeLadder() {
        XCTAssertEqual(Theme.Typo.heroMetric.size, 56)
        XCTAssertEqual(Theme.Typo.metricNumber.size, 34)
        XCTAssertEqual(Theme.Typo.metricMid.size, 22)
        XCTAssertEqual(Theme.Typo.pageTitle.size, 20)
        XCTAssertEqual(Theme.Typo.groupLabel.size, 10)
        XCTAssertEqual(Theme.Typo.groupLabel.tracking, 0.6, accuracy: 0.001,
                       "分区标题靠字距从正文里拎出来，这是无界面里它唯一的分组手段")
        XCTAssertGreaterThan(Theme.Typo.heroMetric.size / Theme.Typo.microLabel.size, 5,
                             "跨度不足 5:1 → 回到「67% 文字挤在 10–12pt」的没有主次状态")
        XCTAssertTrue(Theme.Typo.all.contains { $0.name == "groupLabel" },
                      "groupLabel 没进 all，≥10pt 全仓下限扫不到它")
    }

    /// 旧链是 40/28/18/17/13（跨度 4:1）。抬 `pageTitle` 必须同步抬 `metricMid`，
    /// 否则 `DesignTokenTests` 的严格递减链会断，而它报的是「字号顺序」而不是「值不对」，
    /// 极易被误归因成别人改坏了。这条钉住这个坑。
    func test_typeScaleRemainsMonotonic() {
        XCTAssertGreaterThan(Theme.Typo.metricMid.size, Theme.Typo.pageTitle.size)
        XCTAssertGreaterThan(Theme.Typo.pageTitle.size, Theme.Typo.cardTitle.size)
    }

    func test_inkExistsAndIsNotJustPrimaryLabel() {
        // `Surface.ink` 存在的唯一理由是 `.primary`（labelColor = 85% 黑）不够黑：
        // 它铺在 ground 上合成出来约 #262626，实测正是重构前全页最暗像素 #2F2F2F 的来源。
        XCTAssertNotEqual(Theme.Palette.Surface.ink, Color.primary,
                          "ink 若等价于 .primary 就失去存在理由（见其注释）")
    }

    func test_groupLabelTrackingCannotBeDroppedByCallSites() throws {
        let design = try Self.sourceFiles(under: "Design")
        let views = try Self.sourceFiles(under: "Views")
        let dropped = Self.trackingDroppingUses(in: design + views, tokenNamed: "groupLabel")
        XCTAssertTrue(dropped.isEmpty,
                      "这些位置用 `.font(groupLabel.font)` 绕过了 `.typed`，0.6pt 字距已丢失：\(dropped)")
        XCTAssertTrue(design.contains { $0.content.contains(".typed(Theme.Typo.groupLabel)") },
                      "全仓没有一处经 `.typed` 套 groupLabel —— 那个入口成了死代码")
    }

    // MARK: - 契约 8：呼吸档

    func test_breathingRhythmTokensAreDistinct() {
        // 拥挤的机械成因不是东西多，是**组间与组内是同一个数**：旧总览主区块之间用
        // `md`=16、网格里用 `gutter`=12，卡内条目间距也是 12。所以先钉"它们必须不同"。
        XCTAssertGreaterThan(Theme.Spacing.group, Theme.Spacing.md)
        XCTAssertGreaterThan(Theme.Spacing.section, Theme.Spacing.group)
        XCTAssertEqual(Theme.Spacing.pageMargin, 24)
        XCTAssertEqual(Theme.Spacing.cardPadding, 24)
    }

    func test_breathingRhythmTokensAreUsed() throws {
        try XCTSkipIf(!Self.m2WiringComplete,
                      "待 M2 撤除跳过（实施计划 Task 10）：WS-O/P/W 尚未接线")
        let joined = try Self.sourceFiles(under: "Views").map(\.content).joined(separator: "\n")
        XCTAssertTrue(joined.contains("Spacing.group"))
        XCTAssertTrue(joined.contains("Spacing.section"),
                      "`Spacing.section`(40) 自定义起全仓零引用，这正是「拥挤」的机械成因")
        XCTAssertTrue(joined.contains("Spacing.pageMargin"))
    }

    /// 页骨架的**声明**位置：`struct Xxx(page)Scaffold…: View` 或 `Theme.Page.Scaffold`。
    /// 本轮实测发现过三份同职责骨架并存（基座 `Page.Scaffold`、
    /// `CodeGitDesignKit.DataPageScaffold` 逐字复制品、WS-W 的 `BorderlessPage`）——
    /// 用户原话「不要东一个系一个」在代码层面的形态就是这个。
    static func pageScaffoldDeclarations(in files: [(path: String, content: String)]) -> [String] {
        files.flatMap { file in
            codeLines(file.content)
                .enumerated()
                .compactMap { index, line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard trimmed.hasPrefix("struct "), trimmed.contains(": View") else { return nil }
                    let isScaffold = trimmed.contains("Scaffold") || trimmed.contains("BorderlessPage")
                    return isScaffold ? "\(file.path):\(index + 1)" : nil
                }
        }
    }

    /// 基座那份页骨架必须在 `Design/`，且用的是新呼吸档（不是 16）。
    /// 这条 M0 就能硬断言。
    func test_basePageScaffoldUsesTheBreathingRhythm() throws {
        let design = try Self.sourceFiles(under: "Design")
        let scaffold = design.filter { Self.pageScaffoldDeclarations(in: [$0]).isEmpty == false }
        XCTAssertFalse(scaffold.isEmpty, "Design/ 里没有页骨架了 —— 基座被拆了？")
        let body = scaffold.map(\.content).joined(separator: "\n")
        XCTAssertTrue(body.contains("Spacing.group"),
                      "基座页骨架的组间距没换成 `Spacing.group`(32)，还是 16 = 拥挤没修")
        XCTAssertTrue(body.contains("Spacing.pageMargin"),
                      "基座页骨架的页边距没换成 `Spacing.pageMargin`(24)")
        XCTAssertTrue(body.contains("Spacing.section"),
                      "基座页骨架的页级段落没换成 `Spacing.section`(40)")
    }

    /// 全仓只许存在**一份**页骨架。
    ///
    /// 现在挂 skip 是因为 `Views/CodeGit/CodeGitDesignKit.swift` 里还有一份
    /// `DataPageScaffold` —— 它是基座那份的**逐字复制品**（body 完全相同），
    /// 归 WS-P，且 WS-P 正在改那个文件。总工替它删会毁掉在途工作并造出冲突，
    /// 所以由 WS-P 自己删、M2 由总工强制。与 `m2WiringComplete` 同一套路子。
    func test_exactlyOnePageScaffold() throws {
        try XCTSkipIf(!Self.m2WiringComplete,
                      "待 M2 撤除跳过（实施计划 Task 10）：DataPageScaffold 归 WS-P 自删")
        let all = try Self.sourceFiles(under: "")
        let decls = Self.pageScaffoldDeclarations(in: all)
        XCTAssertEqual(decls.count, 1,
                       "页骨架有 \(decls.count) 份并存（只许 1 份）：\(decls)。"
                       + "页面流请改用 `Theme.Page.Scaffold`，不要各造一份。")
        XCTAssertTrue(decls.first?.hasPrefix("Design/") == true,
                      "唯一那份页骨架必须住在 Design/，实测：\(decls)")
    }

    /// 全仓图表取色规则只许存在**一份**，且住在 `Design/`。
    ///
    /// 起因（M1 集成时实测）：三家并行各长出一套图表取色约定 —— WS-W 用纯墨主线、
    /// WS-O 的总览曲线用 `Theme.Chart.color(at: 0)`（索引色板 = 蓝）、WS-P 的 Git 图
    /// 用第三套透明度组合。结果**同一条 CPU 历史曲线在总览上是蓝的、在性能页上是黑的**。
    /// 这是「东一个系一个」在代码层最后的形态，所以把它钉成机器断言。
    func test_chartColorRuleHasExactlyOneHome() throws {
        let all = try Self.sourceFiles(under: "")
        let decls = all.filter { file in
            Self.codeLines(file.content).contains { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return t.hasPrefix("enum ChartSeries") || t.hasPrefix("struct ChartSeries")
            }
        }.map(\.path)
        XCTAssertEqual(decls, ["Design/ChartTokens.swift"],
                       "`ChartSeries` 必须只有一份且住在 Design/（全仓图表取色唯一规则）。实测：\(decls)")
    }

    // MARK: - 元测试：确认四个扫描器都不是假绿

    func test_scannersCatchSyntheticViolations() {
        let dirtyShadow = [(path: "Design/Fake.swift",
                            content: "x\n    .shadow(color: .black, radius: 6)\n")]
        XCTAssertEqual(Self.shadowHits(in: dirtyShadow), ["Design/Fake.swift:2"],
                       "投影扫描器失灵：真违规没抓到")

        let commented = [(path: "Design/Fake.swift",
                          content: "// .shadow(color: .black, radius: 6)\n")]
        XCTAssertTrue(Self.shadowHits(in: commented).isEmpty,
                      "投影扫描器把注释误判成违规 —— 文档必须能提到被禁写法")

        XCTAssertEqual(Self.unreferencedSurfaceMembers(defined: ["well", "ink"],
                                                      references: ["well"]),
                       ["ink"], "零引用检测失灵：没被引用的成员被放过了")

        let plain = [(path: "Views/Fake.swift",
                      content: "Text(path).foregroundStyle(.tertiary)\n")]
        XCTAssertTrue(Self.tertiaryOnMeasuredValues(in: plain).isEmpty,
                      "非测得值的 .tertiary 不该算违规（路径/时间戳是合法用法）")
        let measured = [(path: "Views/Fake.swift",
                         content: "value: DataAbsence.x).foregroundStyle(.tertiary)\n")]
        XCTAssertEqual(Self.tertiaryOnMeasuredValues(in: measured).count, 1,
                       "测得值上的 .tertiary 没抓到")

        let dirtyMaterial = [(path: "Design/Fake.swift",
                              content: "x\n    shape.fill(.regularMaterial)\n")]
        XCTAssertEqual(Self.forbiddenMaterialUses(in: dirtyMaterial).count, 1,
                       "材质扫描器失灵：真违规没抓到")
        let materialInComment = [(path: "Design/Fake.swift",
                                  content: "// 旧写法是 .regularMaterial，会糊成一片灰\n")]
        XCTAssertTrue(Self.forbiddenMaterialUses(in: materialInComment).isEmpty,
                      "材质扫描器把注释误判成违规 —— 本守卫第一次跑正是栽在这里")

        let droppedFont = [(path: "Design/Fake.swift",
                            content: "Text(t).font(Theme.Typo.groupLabel.font)\n")]
        XCTAssertEqual(Self.trackingDroppingUses(in: droppedFont, tokenNamed: "groupLabel").count, 1,
                       "绕过 .typed 的写法没抓到 → 字距会静默丢失")

    }


    /// 反向自证：`sourceFiles` 真读到了文件。否则上面所有「扫不到就算通过」的断言
    /// 会集体假绿 —— 这是扫描型守卫最经典的死法。
    func test_sourceScannerActuallyFindsFiles() throws {
        let design = try Self.sourceFiles(under: "Design")
        XCTAssertGreaterThanOrEqual(design.count, 9, "Design/ 只扫到 \(design.count) 个文件")
        XCTAssertTrue(design.contains { $0.path.hasSuffix("Glass.swift") })
        XCTAssertEqual(Self.shadowHits(in: design).count, 2,
                       "元测试：真源码里的投影数必须与契约断言一致（`.card` + `.floating` 各一处）")
    }
}
