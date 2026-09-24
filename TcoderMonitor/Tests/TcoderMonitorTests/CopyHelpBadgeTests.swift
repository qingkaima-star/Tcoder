import Foundation
import XCTest
@testable import TcoderMonitor

/// OWNER: WS-X8 CopyTooltips —— ⓘ「帮助图标 + tooltip」组件（`Design/CopyHelp.swift`）的守卫。
///
/// 三条判据，每条都配"注入坏样例必须红"的元测试（本仓规矩：**只出 0 处违例却抓不住坏样例的
/// 守卫比没有守卫更危险**，所以每条都另外断言分母 > 0）：
///   ① 全站「问号图标 + tooltip」这一种画法只有 `CopyHelpBadge` 一份实现；
///   ② 组件真的查本地化表 —— 判据形状与 `LocalizationGuardTests` 守卫 5 同一条尺子；
///   ③ 组件默认态零版面成本（无投影 / 无材质 / 不占定宽列 / 零 `#available` / 零新造色值）。
///
/// 扫描面读的是**真源码**（`SurfaceScanKit.sourceFiles`，与全站扫描型守卫同一把读盘尺子）。
final class CopyHelpBadgeTests: XCTestCase {

    /// 组件的宿主文件（相对 `Sources/TcoderMonitor`）。
    static let componentPath = "Design/CopyHelp.swift"

    /// ①「画法唯一」的**点名挂账**（只减不增）。
    ///
    /// 这两处是历史形状：把一枚问号徽标当宿主、tooltip 匿名挂在**整枚徽标**上，
    /// 鼠标得先猜"这枚胶囊能 hover 吗"。它们不归本流写（`Views/Dependencies/**` 属 WS-L），
    /// 所以按**文件**点名而不是静默排除。还掉的那一天守卫会自己变红，提醒把条目划掉 ——
    /// 与 `SourcesSizeAuditTests.hugeFileWorkList` 同一种写法。
    ///
    /// ⚠️ 2026-09-24 RD-70 换过一次**宿主文件名**（条目数没变、画法一个字没变）：
    /// 生态卡头那一格连同它上面的 `.help(...)` 从 `DependenciesView.swift` 搬进
    /// `DependencyAdvisoryRows.swift` —— 搬的原因是 `SourcesSizeAuditTests` 的 400 行线，
    /// **不是**这笔债还掉了。守卫按"文件"点名，所以宿主搬家必须同步改名；
    /// 留着旧名就是让这条守卫对旧文件永远不再说话（同一形状见台账 RD-72「锚点活着、判据搬家」）。
    /// 真正还掉它的动作是改走 `CopyHelpBadge`，那属 WS-X8 与设计那一页的账。
    static let knownAdHocHelpIconFiles: Set<String> = [
        "Views/Dependencies/DependencyAdvisoryRows.swift",
    ]

    // MARK: - 判据 ①：画法全仓唯一

    /// 图标那一行往下 ≤3 行内出现 `.help(` ⇒ 就是"帮助图标 + tooltip"的手写形状。
    /// 只看行号邻域而不是整文件：`NoteLine(…, icon: .unverified)` 那种
    /// 「问号只是状态图标、旁边写着可见文字」不是 tooltip 宿主，误伤就会逼人改组件名绕守卫。
    static func adHocHelpIconDraws(in files: [(path: String, content: String)],
                                   sanctioned: Set<String>) -> (markers: Int, offenders: [String]) {
        var markers = 0
        var offenders: [String] = []
        for file in files where !sanctioned.contains(file.path) {
            let lines = file.content.components(separatedBy: "\n")
            for (index, raw) in lines.enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.hasPrefix("//"),
                      line.contains(".unverified") || line.contains("\"questionmark.circle\"")
                else { continue }
                markers += 1
                let window = lines.dropFirst(index + 1).prefix(3)
                if window.contains(where: { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                    && $0.contains(".help(") }) {
                    offenders.append("\(file.path):\(index + 1): \(line.prefix(60))")
                }
            }
        }
        return (markers, offenders)
    }

    func test_helpIconPlusTooltipDrawingExistsExactlyOnceInDesign() throws {
        let files = try SurfaceScanKit.sourceFiles(under: "")
        let hit = Self.adHocHelpIconDraws(in: files, sanctioned: [Self.componentPath])
        // 分母：问号图标在真源码里确实被引用着（扫不到东西 = 判据空转）。
        XCTAssertGreaterThan(hit.markers, 0, "一个问号图标都没扫到 —— 判据或读盘坏了，这条绿没有含义")

        let unexpected = hit.offenders.filter { path in
            !Self.knownAdHocHelpIconFiles.contains { path.hasPrefix($0 + ":") }
        }
        XCTAssertTrue(unexpected.isEmpty,
                      "页面里又手写了一遍「问号图标 + .help」。请改用 CopyHelpBadge(解释句)：\n"
                        + unexpected.joined(separator: "\n"))
        let stillThere = Self.knownAdHocHelpIconFiles.filter { host in
            hit.offenders.contains { $0.hasPrefix(host + ":") }
        }
        XCTAssertEqual(stillThere, Self.knownAdHocHelpIconFiles,
                       "挂账清单里有文件已经不手写这种画法了，把条目划掉（清单只减不增，不许留着冒充有账）")
        print("【ⓘ 画法唯一】问号图标引用 \(hit.markers) 处 / 挂账手写形状 \(hit.offenders.count) 处"
              + "（\(Self.knownAdHocHelpIconFiles.sorted().joined(separator: ", "))）"
              + " · 唯一实现 \(Self.componentPath)")
    }

    /// 元测试：坏样例必须抓到、合法写法不许误伤。
    func test_adHocScannerCatchesInjectedDrawsAndSparesLegalShapes() {
        let badThemed = [(path: "Views/Fake/A.swift", content: """
        ThemedIcon(.unverified, role: .badge)
            .help("口径：分母是有效代码行")
        """)]
        let badRawSymbol = [(path: "Views/Fake/B.swift", content: """
        Image(systemName: "questionmark.circle")
            .frame(maxWidth: .infinity)
            .accessibilityLabel("说明")
            .help("口径：分母是有效代码行")
        """)]
        XCTAssertEqual(Self.adHocHelpIconDraws(in: badThemed, sanctioned: []).offenders.count, 1,
                       "散写 ThemedIcon(.unverified) + .help 没被抓到")
        XCTAssertEqual(Self.adHocHelpIconDraws(in: badRawSymbol, sanctioned: []).offenders.count, 1,
                       "散写裸符号串 + .help 没被抓到（判据不许只认登记表写法）")

        let legalBadge = [(path: "Views/Fake/C.swift", content: """
        NoteLine("重复率 3.1%", help: "分母是有效代码行数，不含空行与注释。")
        CopyHelpBadge("这一列只统计非合并提交。")
        """)]
        XCTAssertTrue(Self.adHocHelpIconDraws(in: legalBadge, sanctioned: []).offenders.isEmpty,
                      "走组件的合法写法被误伤")
        let legalStateIcon = [(path: "Views/Fake/D.swift", content: """
        NoteLine("本轮未取到线程数", icon: .unverified)
        Spacer(minLength: 0)
        EmptyView()
        EmptyView()
        .help("这句离图标已经超出邻域，不算同一种画法")
        """)]
        XCTAssertTrue(Self.adHocHelpIconDraws(in: legalStateIcon, sanctioned: []).offenders.isEmpty,
                      "问号只当状态图标、不挂 tooltip 的写法被误伤")
    }

    // MARK: - 判据 ②：组件确实查本地化表

    /// 组件里承载 tooltip / 读屏的行必须过 `localizedCopy`。
    /// `help(_:)` 与 `accessibilityLabel(_:)` 收的都是**成品 String**，不会自己查表
    /// （双语方案 §7.1）—— 与守卫 5 抓 `Text(变量)` 是同一件事的另一个出口。
    ///
    /// 出口只有两种形状：`.help(`，以及把标签交给 `ThemedIcon(label:)` 的调用行。
    /// 判据不认裸的 `label:` 字样 —— 那是形参声明与 `init` 签名，不是上屏出口。
    static func unlocalizedHelpSlots(in content: String) -> (slots: Int, offenders: [String]) {
        var slots = 0
        var offenders: [String] = []
        for (index, raw) in content.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let isSlot = !line.hasPrefix("//")
                && (line.contains(".help(") || (line.contains("ThemedIcon(") && line.contains("label:")))
            guard isSlot else { continue }
            slots += 1
            if !line.contains("localizedCopy(") && !line.contains("localizedFormat(") {
                offenders.append("\(index + 1): \(line.prefix(60))")
            }
        }
        return (slots, offenders)
    }

    static func componentSource() throws -> (path: String, content: String) {
        let files = try SurfaceScanKit.sourceFiles(under: "Design")
        return try XCTUnwrap(files.first { $0.path == componentPath },
                             "扫不到 \(componentPath) —— 组件被搬走而守卫还绿着")
    }

    func test_componentLooksUpTheLocalizationCatalog() throws {
        let file = try Self.componentSource()
        let hit = Self.unlocalizedHelpSlots(in: file.content)
        XCTAssertGreaterThanOrEqual(hit.slots, 2,
                                   "组件里 tooltip + 读屏两处出口都没扫到（实扫 \(hit.slots) 处），判据已空转")
        XCTAssertTrue(hit.offenders.isEmpty,
                      "ⓘ 组件把没查表的串直接挂上 tooltip/读屏，英文态会永远吐中文：\(hit.offenders)")
        // 与任务 1 同一把尺子：组件里不许有 `Text(变量)` 那种不查表的渲染点。
        XCTAssertEqual(LocalizationGuardTests.unlocalizedRenderPoints(in: [file]), [],
                       "组件里出现了 Text(变量) 直出的渲染点")
    }

    func test_unlocalizedHelpJudgeCatchesBadComponentAndSparesGoodOne() {
        let bad = """
        struct FakeBadge: View {
            var body: some View {
                ThemedIcon(.unverified, role: .badge, label: text)
                    .help(text)
            }
        }
        """
        let hit = Self.unlocalizedHelpSlots(in: bad)
        XCTAssertEqual(hit.slots, 2, "两处出口都该被数进分母")
        XCTAssertEqual(hit.offenders.count, 2, "没查表的 tooltip/读屏没被抓到，这条判据是假的")
        let good = """
        ThemedIcon(.unverified, role: .badge, label: localizedCopy(text))
            .help(localizedCopy(text))
        """
        let ok = Self.unlocalizedHelpSlots(in: good)
        XCTAssertEqual(ok.slots, 2, "合规写法也该进分母（否则 0 命中看着像通过）")
        XCTAssertTrue(ok.offenders.isEmpty, "查了表的被误判")
    }

    // MARK: - 判据 ③：默认态零版面成本

    /// 版面成本禁则：投影 / 材质 / 定宽列 / 新造色值 / 散写可用性判断。
    static let layoutCostForbidden: [(name: String, needle: String)] = [
        ("投影", ".shadow("),
        ("材质", "Material"),
        ("定宽列", ".frame(width:"),
        ("最小列宽", ".frame(minWidth:"),
        ("裸色值", "Color(red:"),
        ("十六进制色", "0x"),
        ("散写可用性判断", "#available"),
        ("裸字号", "Font.system"),
        ("背景铺色", "background("),
    ]

    static func layoutCostHits(_ content: String) -> [String] {
        content.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
            .flatMap { line in
                Self.layoutCostForbidden.filter { line.contains($0.1) }.map { "\($0.name)：\(line.prefix(60))" }
            }
    }

    func test_componentCostsNothingOnScreenByDefault() throws {
        let content = try Self.componentSource().content
        XCTAssertTrue(Self.layoutCostHits(content).isEmpty,
                      "ⓘ 组件带上了版面成本（本仓实拍教训：占定宽列会让读数带中间空一段版心）："
                        + Self.layoutCostHits(content).joined(separator: "\n"))
        // 分母：禁则表本身不许是空表（新增一条禁则就要有一个坏样例，见下一个用例）。
        XCTAssertEqual(Self.layoutCostForbidden.count, 9, "禁则表被改动，元测试要跟着补坏样例")
    }

    func test_layoutCostScannerCatchesInjectedShapes() {
        for (name, needle) in Self.layoutCostForbidden {
            let dirty = "struct X: View {\n    var body: some View {\n        \(needle)\n    }\n}\n"
            XCTAssertTrue(Self.layoutCostHits(dirty).contains { $0.hasPrefix(name) },
                          "禁则「\(name)」抓不到自己那条写法，等于没有这条禁则")
        }
        XCTAssertTrue(Self.layoutCostHits("    ThemedIcon(.unverified, role: .badge)\n").isEmpty,
                      "合规写法被误伤")
    }

    // MARK: - 判据 ④：三个渲染点的调用形状没被改动（本轮的硬约束）

    func test_renderPointCallShapesAreUnchanged() throws {
        let files = try SurfaceScanKit.sourceFiles(under: "Views")
        let footnote = Self.codeLines(of: "DataFootnote(", in: files)
        let caption = Self.codeLines(of: "DataCaption(", in: files)
        let note = Self.codeLines(of: "NoteLine(", in: files)
        XCTAssertGreaterThan(footnote.count, 0, "一处 DataFootnote 调用点都没扫到，读盘坏了")
        XCTAssertGreaterThan(caption.count, 0, "一处 DataCaption 调用点都没扫到，读盘坏了")
        XCTAssertGreaterThan(note.count, 0, "一处 NoteLine 调用点都没扫到，读盘坏了")
        // 脚注与说明句这两个组件本轮**没动签名**：页面必须仍然只用 `text:` 标签形状。
        for (name, lines) in [("DataFootnote", footnote), ("DataCaption", caption)] {
            for line in lines where line.contains("\"") {
                XCTAssertTrue(line.contains("text:"),
                              "\(name) 出现了位置参数写法，本轮「调用形状不许变」的约束已破：\(line)")
            }
        }
        print("【ⓘ 前置·调用形状】DataFootnote \(footnote.count) 处 / DataCaption \(caption.count) 处"
              + " / NoteLine \(note.count) 处 均保持原形状")
    }

    /// 留短藏长槽：`NoteLine` 的 `help != nil` 那一支必须渲染 `CopyHelpBadge`（唯一那份画法）。
    func test_noteLineHelpSlotMountsTheComponent() throws {
        let kit = try XCTUnwrap(SurfaceScanKit.sourceFiles(under: "Views/PerfLogs")
            .first { $0.path == "Views/PerfLogs/NumberText.swift" }, "扫不到 NoteLine 的宿主文件")
        XCTAssertTrue(kit.content.contains("CopyHelpBadge(help)"),
                      "NoteLine 的 help 槽不再走 CopyHelpBadge —— 页面会拿不到全站唯一的画法")
        XCTAssertTrue(kit.content.contains("if let help"),
                      "help 槽不再走条件渲染：默认态（help == nil）会白白多挂一枚问号")
        // 第一参仍是**位置参数**：`NoteLine(text:` 这种写法一出现就说明签名被动过了。
        let relabeled = Self.codeLines(of: "NoteLine(text:", in: [kit])
        XCTAssertTrue(relabeled.isEmpty, "NoteLine 的首参被改成了带标签形状：\(relabeled)")
    }

    static func codeLines(of needle: String, in files: [(path: String, content: String)]) -> [String] {
        files.flatMap { file in
            file.content.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("//") && $0.contains(needle) }
        }
    }
}
