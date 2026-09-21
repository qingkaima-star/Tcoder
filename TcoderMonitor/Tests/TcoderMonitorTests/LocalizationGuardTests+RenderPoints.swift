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
        let offenders = Self.unlocalizedRenderPoints(in: try Self.sourceFiles()
            .filter { $0.path.hasPrefix("Design/") })
        XCTAssertTrue(offenders.isEmpty,
                      "这些组件渲染点还在走 Text(变量)（不查表），请包 localizedCopy：\(offenders)")
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
