import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import TcoderMonitor

// MARK: - WS-O 外壳与总览的「简约无界」守卫
//
// 权威 = `docs/superpowers/specs/2026-09-20-borderless-minimal-ui-redesign-design.md`
// §1 风格契约 1/4/6/7/8、§3 导航、§4.1 总览病灶，与实施计划 Task 6 的四条验收判据。
//
// 与 `BorderlessSurfaceGuardTests`（基座侧）的分工：那套管 `Design/**` 的画法，
// 这套管**外壳与总览这两片页面**。两边的尺子刻意不共用同一套判据形状 ——
// 同一个病灶用两把不同的尺子量，一把瞎了另一把还在（证据见
// `test_tertiaryScannerSeesWhatTheBaseLineScannerMisses`）。
//
// 每条扫描型断言都配元测试：造违规样本确认它会红、造合法样本确认它不误伤。
// 理由见记忆《扫描型测试要配元测试》——本轮病因之一就是「令牌定义了但零引用」，
// 只查「有没有散写魔法数」的守卫查不出「改了但没生效」，也查不出「扫不到东西」。

final class ShellBorderlessTests: XCTestCase {

    // MARK: - 路径与扫描面

    /// 包根。测试文件在 `Tests/TcoderMonitorTests/` 下，回溯三级（与 `ShellDesignTests` 同一套写法）。
    static let packageRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // TcoderMonitorTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // TcoderMonitor

    static var viewsDir: URL {
        packageRoot.appendingPathComponent("Sources/TcoderMonitor/Views")
    }

    /// 本流名下文件：3 个外壳页面 + `Shell/` 下 5 个分件。
    /// 分母钉死：扫不到文件时，下面所有「没扫到就算通过」的断言会集体假绿。
    static func shellSources() throws -> [(path: String, content: String)] {
        let pages = ["RootView.swift", "ProjectDetailView.swift", "DashboardView.swift"]
        let shellDir = viewsDir.appendingPathComponent("Shell")
        let shell = try FileManager.default.contentsOfDirectory(
            at: shellDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .map(\.lastPathComponent)
            .sorted()
        let names = pages + shell
        // 8 → 9（收官轮 WS-X7）：自扫点名 `Shell/ProjectSidebar.swift` 486 行 >400，
        // 两枚侧栏行内构件搬进同目录新分件 `Shell/SidebarRows.swift`；归属没动，仍是外壳层。
        XCTAssertEqual(names.count, PageScanDenominators.shellLayerFiles,
                       "外壳扫描集分母变了（\(PageScanDenominators.shellRosterText)）：\(names)")
        return try names.map { name in
            let url = pages.contains(name)
                ? viewsDir.appendingPathComponent(name)
                : shellDir.appendingPathComponent(name)
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(text.isEmpty, "\(name) 读出来是空的，扫描等于没扫")
            return (path: name, content: text)
        }
    }

    /// 全仓实现文件（相对 `Sources/TcoderMonitor`）。
    static func allSources() throws -> [(path: String, content: String)] {
        let root = packageRoot.appendingPathComponent("Sources/TcoderMonitor")
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        let urls = walker?.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(urls.isEmpty, "扫不到 \(root.path) —— 路径口径变了，这条守卫会假绿")
        return urls.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return (url.path.replacingOccurrences(of: root.path + "/", with: ""), text)
        }
    }

    // MARK: - 扫描器（纯函数，喂合成输入即可双向元测试）

    /// ③ 落在「承载测得值的 Text 块」上的 `.tertiary`。
    ///
    /// 判据形状比基座那把尺子**更严**：基座要求 marker 与 `.tertiary` 在**同一行**，
    /// 而 SwiftUI 的 modifier 天生一行一条，`Text(NumberFormat.grouped(n))` 换行再
    /// `.foregroundStyle(.tertiary)` 是页面里最常见的写法 —— 那种形状基座扫不到。
    static let measuredMarkers = ["DataAbsence", "NumberFormat", "ByteFormat",
                                  "percentOf100", "value:", "codeLines", "linePercent"]

    /// 真调用了 `isReachable(reportAvailable:)` 的文件名。整行注释不算 ——
    /// 否则「把测试删了、换一段说明文字」这条最容易走的回头路会一路绿灯。
    static func isReachableCallers(in files: [(path: String, content: String)]) -> [String] {
        files.filter { file in
            file.content.split(separator: "\n", omittingEmptySubsequences: false)
                .contains { !isComment(String($0)) && String($0).contains("isReachable(reportAvailable:") }
        }.map(\.path)
    }

    /// `Theme.Spacing.<成员>` 的字面量解算表。不把阈值写死在测试里：
    /// 令牌的真实取值改了，守卫必须跟着变，而不是冻成一个和源码无关的数字。
    static let spacingValues: [String: CGFloat] = [
        "xxs": Theme.Spacing.xxs, "xs": Theme.Spacing.xs, "sm": Theme.Spacing.sm,
        "md": Theme.Spacing.md, "lg": Theme.Spacing.lg, "xl": Theme.Spacing.xl,
        "xxl": Theme.Spacing.xxl, "section": Theme.Spacing.section,
        "gutter": Theme.Spacing.gutter, "chip": Theme.Spacing.chip,
        "cardPadding": Theme.Spacing.cardPadding, "tilePadding": Theme.Spacing.tilePadding,
        "group": Theme.Spacing.group, "pageMargin": Theme.Spacing.pageMargin,
    ]

    /// 总览页面级布局的三段：页 body + 两个段落装配器。
    /// 只量 `body` 会让「把拥挤挪进 scaleSegment」也算通过。
    /// 总览的**页面级分段**（批次 P31 起页面级一律单列，所以只有这两段）。
    /// 原来那三档里含 `var body`，但 `body` 自己不带 `spacing:`（组间距由基座 Scaffold 定），
    /// 数它会让"每段声明一处组间距"这条判据对不上号。
    static let overviewPageSegments = [
        "private var scaleSegment: some View {",
        "private var listSegment: some View {",
    ]

    // MARK: - ① chip 条已删，而取证依赖的那几样东西原样在场

    // MARK: - ② `isReachable` 仍有测试钉住

    // MARK: - ③ 测得值上不得有 `.tertiary`

    // MARK: - ④ 组间必须有呼吸

    // MARK: - 风格契约 6/7：外壳层零投影、零材质胶囊

    // MARK: - 元测试：①④ 两把尺子都不是摆设

    // MARK: - 排版令牌必须经 `.typed`（字距不许静默丢失）

    // MARK: - ⑤ 倾向色不许当数据色用（总工 2026-09-20 补的硬要求）
    //
    // 病灶的**形状**比病灶本身值得记下来：M0 已经把 `MetricTile.tint` 的默认值改成纯墨，
    // 但「改默认值」救不了「调用点显式传参」—— 总工在 main `415f0f0` 实拍上仍然看到
    // CPU `16%`、内存 `28.4 GB`、最近提交 `15 分钟前` 三个蓝数。
    // 所以基座换默认值之后，必须回头把每个显式覆盖点扫一遍，这条守卫就是那一次扫的回执。
    //
    // **只禁「把信息色/交互色涂在读数上」这一件事**。accent 作为**交互语义**是合法的，
    // 不在禁用之列：侧栏选中行的淡底胶囊、拖放落点高亮、`SemanticBadge("示例")` 的 role、
    // 按钮 —— 那些是「可点/可选中」的意思，不是数据。一律砍 accent 会把导航做哑。

    /// 读数被涂信息色/倾向色的两种落地形状。
    static let dataHueNeedles = [
        "tint: Theme.Semantic.info",
        "tint: Theme.Semantic.accent",
        ".foregroundStyle(Theme.Semantic.info",
        ".foregroundStyle(Theme.Semantic.accent",
    ]

    // MARK: - 定宽格必须真的量过（18:00 实拍逼出来的）

    // MARK: - 今日错误的着色（语义色只留给真有危险的那一态）

}
