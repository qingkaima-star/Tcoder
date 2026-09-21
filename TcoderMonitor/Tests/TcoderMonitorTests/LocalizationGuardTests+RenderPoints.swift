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
    /// 只认白名单里的参数名，避免把 `Text("\(x)")`、`Text(item.name)` 这类
    /// 由调用方自己负责语言形态的写法一起卷进来。
    private static let copyParameterNames: Set<String> = [
        "label", "value", "caption", "unit", "title", "subtitle", "text", "message",
        "section.title", "column.title",
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
                    guard copyParameterNames.contains(String(name)),
                          rest.hasPrefix(String(name) + ")") else { return nil }
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
    }
}
