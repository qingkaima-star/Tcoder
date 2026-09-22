import Foundation
import XCTest
@testable import TcoderMonitor

// MARK: - 渲染点必须真的查表（守卫 5）
//
// 从 `LocalizationGuardTests.swift` 拆出来住：主文件 423 行，超了
// `X3TestSizeAuditTests` 与产品同口径的 400 行线。判据、合成样例与数字一字未改。

extension LocalizationGuardTests {

    // MARK: - 守卫 5：组件渲染点必须真的查表

    /// 双语最容易的空转不是"没翻"，而是**翻了但界面不查表**：
    /// `Text(变量)` 走 verbatim 初始化，目录里翻了也一个字不动（《中英双语方案》§7.1）。
    /// 2026-09-21 用 `-AppleLanguages "(en)"` 实跑抓到这个空转：页头出英文，
    /// 侧栏九条页名仍是中文，因为 `SidebarRows` 写的是 `Text(section.title)`。
    ///
    /// 判据：`Design/` 里承载组件文案的 `Text(<已知参数名>)` 必须过 `localizedCopy`。
    ///
    /// ⚠ 2026-09-22 改过一次判据形状，理由与实测都在下面，别按旧说明改回去：
    /// 原来只认**整名相等**（`label`、`section.title` 这种逐条点名），
    /// 并写明"避免把 `Text(item.name)` 这类卷进来"。而正文台账（`scripts/ax_body_audit.py`）
    /// 用进程外 AX 实测到：健康评分页分量表那一列整片是中文，落点正是
    /// `HealthComponentTable.rowView` 的 `Text(row.name)` —— **被豁免的那个形状就是漏点本身**，
    /// 而它需要的键早就登记好了（"协作分布" = "Collaboration Spread"）。
    /// 现在按**末段相等**判（`row.name` → `name`），并把 `name` 加进名单。
    /// 放宽的作用域实测过：同一判据跑在 `Design/` 全量上**新暴露 0 处**，
    /// 所以这不是把噪声放进来，是把一个已经造成 6 句漏网的豁免撤掉。
    /// 仍然排除 `Text("\(x)")`：插值串取不出标识符前缀，形状上就进不来。
    private static let copyParameterNames: Set<String> = [
        "label", "value", "caption", "unit", "title", "subtitle", "text", "message",
        "section.title", "column.title", "name",
    ]

    /// **扫描面名单（只许变长，不许变短）**。
    ///
    /// 原来这条守卫只看 `Design/`，于是住在页面基座里的三个渲染点
    /// （`DataFootnote`、`DataCaption`、`NoteLine`）一直是漏网的：它们是 `Text(text)` 直出、
    /// 根本不调 `localizedCopy`，英文态原样吐中文（《九页解释性文案盘点表》Y 节缺口 1，
    /// 实测分布 `DataFootnote` 9 处 / `DataCaption` 4 处 / `NoteLine` 16 处调用点）。
    /// 后果不是"少一句译文"，而是**往目录里加这些串的任何键都不生效** ——
    /// 看起来在还债，实际一个字节都没动。
    ///
    /// 按**文件**纳入而不是按视图名点名：判据本体（`copyParameterNames` + `Text(变量)` 形状）
    /// 一字未改，点名具体视图等于给"下一个新增的 `Text(变量)`"留免检额度。
    /// 因此 `Views/PerfLogs/NumberText.swift` 里的 `LiveNumber` 也一并受同一判据管 ——
    /// 它收的是带单位的读数串（`42 次`、`5 分钟前`），查表对纯数字是 no-op，
    /// 而"数字位就不该查表"这种豁免一旦写下，判据就从"按参数名"退化成"按我觉得像不像文案"。
    static let renderPointHosts: Set<String> = [
        "Views/CodeGit/CodeGitDesignKit.swift",
        "Views/PerfLogs/NumberText.swift",
        "Views/Performance/PerformanceProcessGroups.swift",
        // 2026-09-22 正文台账（进程外 AX）抓到的两处：`StatLine` 的九个调用点全是中文短标签、
        // 分量表的维度名整列不查表。纳管按文件，不按视图名点名。
        "Views/Shell/DashboardReadouts.swift",
        "Views/Health/HealthComponentTable.swift",
    ]

    static func unlocalizedRenderPoints(in files: [(path: String, content: String)]) -> [String] {
        files.flatMap { file -> [String] in
            file.content.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .compactMap { index, raw -> String? in
                    let line = String(raw)
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.hasPrefix("//"), trimmed.contains("Text(") else { return nil }
                    guard let open = line.range(of: "Text(") else { return nil }
                    let rest = line[open.upperBound...]
                    let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
                    let ident = String(name)
                    // 必须是"整颗标识符直接进 Text(...)"，中间不许有别的东西：
                    // `Text(localizedCopy(label))` 的前缀是 `localizedCopy` 且后面不是 `)`，
                    // `Text("\(x)")` 取不出标识符 —— 两种都自然落在判据外。
                    guard rest.hasPrefix(ident + ")") else { return nil }
                    let leaf = ident.split(separator: ".").last.map(String.init) ?? ident
                    guard copyParameterNames.contains(ident)
                            || copyParameterNames.contains(leaf) else { return nil }
                    return "\(file.path):\(index + 1)"
                }
        }
    }

    func test_designRenderPointsActuallyLookUpTheCatalog() throws {
        let all = try Self.sourceFiles()
        let offenders = Self.unlocalizedRenderPoints(in: all
            .filter { $0.path.hasPrefix("Design/") || Self.renderPointHosts.contains($0.path) })
        XCTAssertTrue(offenders.isEmpty,
                      "这些组件渲染点还在走 Text(变量)（不查表），请包 localizedCopy：\(offenders)")
    }

    /// 扩进去的名单必须**真的被扫到**：`hasPrefix("Design/")` 写错成 `Design`、
    /// 或页面基座文件改了名而名单没跟着改，都会得到"0 处违例 = 很干净"的假绿。
    /// 这里断言名单里每个文件都存在、且它们各自至少有一个 `Text(` 渲染点。
    func test_renderPointHostListIsActuallyOnTheScanSurface() throws {
        let all = try Self.sourceFiles()
        let byPath = Dictionary(uniqueKeysWithValues: all.map { ($0.path, $0.content) })
        for host in Self.renderPointHosts.sorted() {
            let content = try XCTUnwrap(byPath[host], "名单里的 \(host) 不在扫描面上（路径口径变了）")
            XCTAssertTrue(content.contains("Text("), "\(host) 里一个 Text( 都没有，名单该删条目而不是留着空转")
        }
    }

    func test_renderPointScannerCatchesBareTextButSparesWrapped() {
        let bare = [(path: "Design/Fake.swift", content: "    Text(label)\n")]
        XCTAssertEqual(Self.unlocalizedRenderPoints(in: bare), ["Design/Fake.swift:1"],
                       "没查表的渲染点没被抓到")
        let wrapped = [(path: "Design/Fake.swift",
                        content: "    Text(localizedCopy(label))\n")]
        XCTAssertTrue(Self.unlocalizedRenderPoints(in: wrapped).isEmpty, "查了表的被误判")
        let interpolated = [(path: "Design/Fake.swift",
                             content: "    Text(\(name)) 拼出来的串由调用方负责\n")]
        XCTAssertTrue(Self.unlocalizedRenderPoints(in: interpolated).isEmpty, "插值写法被误判")
        // 末段相等这一支是 2026-09-22 为 `Text(row.name)` 补的（正文台账实测：
        // 分量表那一列的 6 个维度名就是这么漏网的）。三向都要立住：
        // 漏网的抓到、包了查表的放过、非文案的末段（`width`）不误伤。
        let dotted = [(path: "Views/Fake.swift", content: "    Text(row.name)\n")]
        XCTAssertEqual(Self.unlocalizedRenderPoints(in: dotted), ["Views/Fake.swift:1"],
                       "点号写法的文案渲染点没被抓到（末段判据失效）")
        let dottedWrapped = [(path: "Views/Fake.swift",
                              content: "    Text(localizedCopy(row.name))\n")]
        XCTAssertTrue(Self.unlocalizedRenderPoints(in: dottedWrapped).isEmpty, "点号写法包了查表仍被误判")
        let dottedGeometry = [(path: "Views/Fake.swift", content: "    Text(item.width)\n")]
        XCTAssertTrue(Self.unlocalizedRenderPoints(in: dottedGeometry).isEmpty,
                      "非文案末段被卷进来了（名单里不该有 width）")
    }
}
