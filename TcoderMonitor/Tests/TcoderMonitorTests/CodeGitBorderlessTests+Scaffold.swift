/// OWNER: WS-X3 TestSplit —— 自 CodeGitBorderlessTests.swift 拆出，单一脚手架：不另起第二套页面骨架、不手搓分组容器。用例本体未改，只是搬了家。
import Foundation
import XCTest
@testable import TcoderMonitor

extension CodeGitBorderlessTests {

    /// 页骨架只许一份，且必须住在 `Design/`（总工 `48443d9` 的裁定）。
    /// 本流原来那份 `DataPageScaffold` 是基座的逐字复制品，已由 WS-P 自删。
    /// 这条防的是"顺手又造一份"：`BorderlessSurfaceGuardTests` 那份要等 M2 闸门才生效，
    /// 在那之前本流目录里再长出第二份骨架是没人拦的。
    func test_thisStreamDeclinesNoSecondPageScaffold() throws {
        let hits = Self.pageScaffoldDeclarations(in: try Self.pageSourceFiles())
        XCTAssertTrue(hits.isEmpty,
                      "本流四目录里又出现了页骨架声明（只许 Design/ 那一份）：\(hits)")
    }

    /// 扫描器本身形状对不对 —— 基座那份必须能被它认出来，否则上面那条是永真绿。
    static func pageScaffoldDeclarations(in files: [(path: String, content: String)]) -> [String] {
        files.flatMap { file in
            numberedCodeLines(file.content).compactMap { entry in
                guard entry.text.hasPrefix("struct "), entry.text.contains(": View") else { return nil }
                return (entry.text.contains("Scaffold") || entry.text.contains("BorderlessPage"))
                    ? "\(file.path):\(entry.n)" : nil
            }
        }
    }

    func test_pagesDoNotHandRollTheirGroupContainers() throws {
        let hits = Self.handRolledGroupContainers(in: try Self.pageSourceFiles())
        XCTAssertTrue(hits.isEmpty,
                      "页面自己摆了个容器来排 GlassSection，组间距不受档位管辖：\n"
                          + hits.joined(separator: "\n"))
    }

    /// 每页必须真走骨架，否则上面几条对那一页全是空跑。
    func test_everyPageUsesTheScaffold() throws {
        let all = try Self.pageSourceFiles()
        for (page, owned) in Self.pageFiles {
            let entries = Self.files(forPage: page, in: all).filter {
                $0.path.hasSuffix("View.swift")
            }
            XCTAssertFalse(entries.isEmpty, "页面「\(page)」找不到入口文件：\(owned)")
            for entry in entries {
                XCTAssertTrue(entry.content.contains("Theme.Page.Scaffold"),
                              "页面「\(page)」的 \(entry.path) 没走基座唯一骨架 Theme.Page.Scaffold")
            }
        }
    }

}
