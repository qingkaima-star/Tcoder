/// OWNER: WS-X3 TestSplit —— 自 ShellBorderlessTests.swift 拆出，chip 条符号已全站消失、九页模型仍在、isReachable 的测试覆盖。用例本体未改，只是搬了家。
import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import TcoderMonitor

extension ShellBorderlessTests {

    func test_chipBarSymbolsAreGoneFromEverywhere() throws {
        let files = try Self.allSources()
        XCTAssertGreaterThan(files.count, 100, "只扫到 \(files.count) 个文件，路径口径可疑")
        for symbol in ["SectionNavBar", "SectionNavChip"] {
            let hits = Self.symbolUses(symbol, in: files)
            XCTAssertTrue(hits.isEmpty,
                          "九页导航已搬进侧栏，\(symbol) 还在被引用：\(hits)")
        }
    }

    /// 删的是**呈现层**，不是九页模型。这三样是九页取证的承重墙：
    /// `capture_pages_isolated.sh` 靠 `-selectedDetailSection <中文页名>` 传页，
    /// 键名或页名一改，拍出来的九张图会全是同一页。
    func test_ninePageModelSurvivedTheChipBarRemoval() throws {
        let sources = try Self.shellSources()
        let sectionNav = try XCTUnwrap(
            sources.first { $0.path == "SectionNav.swift" },
            "SectionNav.swift 不能删：README 与 docs 用 `SectionNav.DetailSection` 定位九页")
        XCTAssertTrue(sectionNav.content.contains("enum DetailSection"),
                      "DetailSection 枚举必须还在原文件里")
        XCTAssertTrue(sectionNav.content.contains("func isReachable(reportAvailable: Bool)"),
                      "isReachable 纯函数不许跟着 chip 条一起删掉")

        for name in ["ProjectDetailView.swift", "ProjectSidebar.swift"] {
            let text = try XCTUnwrap(sources.first { $0.path == name }).content
            XCTAssertTrue(text.contains(#""selectedDetailSection""#),
                          "\(name) 丢了 @AppStorage(\"selectedDetailSection\") 键名 → 取证传页失效")
        }

        let expected = ["总览", "代码规模", "复杂度风险", "Git 洞察", "贡献者",
                        "性能监控", "错误日志", "依赖分析", "健康评分"]
        XCTAssertEqual(DetailSection.allCases.map(\.rawValue), expected,
                       "中文页名顺序就是取证脚本的拍图顺序，动一个字九页图就错位")
    }

    /// 两把尺子：源码枚举与取证脚本各自的页名清单必须逐条相等。
    /// 只在源码里自查的话，脚本那一侧改了一页名字我们永远看不见。
    func test_captureScriptPageNamesMatchTheSourceEnum() throws {
        let script = Self.packageRoot.appendingPathComponent("scripts/capture_pages_isolated.sh")
        let text = try String(contentsOf: script, encoding: .utf8)
        let names = try Self.scriptPageNames(in: text)
        XCTAssertEqual(names, DetailSection.allCases.map(\.rawValue),
                       "脚本页名与 DetailSection 不再一一对应")
    }

    /// 从脚本里抠出默认页名清单，**两种写法都认**（都是同一件事的载体）：
    ///   旧：`SECTIONS=("总览" "代码规模" …)`
    ///   新：`read -r -a SECTIONS <<< "${CAPTURE_PAGES:-总览:代码规模:…}"`
    ///     （2026-09-21 加了 `CAPTURE_PAGES` 补拍口子，页名里有空格所以用冒号分隔）
    /// 两种都找不到就判败 —— 这条守卫的失效方式正是"脚本改了写法，测试还在按老形状找"。
    static func scriptPageNames(in text: String) throws -> [String] {
        if let line = text.split(separator: "\n").first(where: { $0.contains("SECTIONS=(") }),
           let head = line.range(of: "SECTIONS=(") {
            return line[head.upperBound...].split(separator: "\"")
                .filter { $0.count >= 2 }.map(String.init)
        }
        if let range = text.range(of: "CAPTURE_PAGES:-") {
            let tail = text[range.upperBound...]
            let end = tail.firstIndex(of: "}") ?? tail.endIndex
            let list = String(tail[..<end])
            let parts = list.split(separator: ":").map(String.init)
            XCTAssertFalse(parts.isEmpty, "CAPTURE_PAGES 默认值是空的？")
            return parts
        }
        XCTFail("取证脚本里既没有 SECTIONS=( ……) 也没有 CAPTURE_PAGES:-…… —— 判据失效，"
            + "改写法的人请同步这条测试，别让它静默空转")
        return []
    }

    /// 元测试：上面那个抠名函数必须**两种写法都认**，且各自抠出顺序一致的两页。
    /// （"两种都找不到就判败"那一支不单独测 —— 它一跑就会 `XCTFail` 把这次测试弄红，
    ///   而它真正的用武之地是主门：脚本改成第三种写法时，主门必须喊而不是空转。）
    func test_scriptPageNamesParserAcceptsBothSpellings() throws {
        XCTAssertEqual(try Self.scriptPageNames(in: #"SECTIONS=("总览" "代码规模")"#),
                       ["总览", "代码规模"])
        XCTAssertEqual(try Self.scriptPageNames(in:
                        #"read -r -a SECTIONS <<< "${CAPTURE_PAGES:-总览:代码规模:Git 洞察}"#),
                       ["总览", "代码规模", "Git 洞察"])
    }

    func test_isReachableStillHasTestCoverage() throws {
        let dir = Self.packageRoot.appendingPathComponent("Tests/TcoderMonitorTests")
        let urls = try FileManager.default.contentsOfDirectory(at: dir,
                                                               includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThanOrEqual(urls.count, 50, "只扫到 \(urls.count) 个测试文件")
        let files: [(path: String, content: String)] = urls.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return (url.lastPathComponent, text)
        }
        let callers = Self.isReachableCallers(in: files)
        XCTAssertFalse(callers.isEmpty,
                       "没有任何测试再调 isReachable(reportAvailable:) —— 那条「性能页永远可达、"
                       + "其余页要先扫」的口径失去守卫；chip 条一删，连禁用逻辑都可能被顺手删干净")
    }

    /// 反向自证：判据写错形状（漏参数标签、或把注释也算成调用）时，上一条会假绿。
    func test_isReachableCoverageProbeActuallyDiscriminates() {
        XCTAssertEqual(Self.isReachableCallers(in: [("A.swift",
                         "section.isReachable(reportAvailable: false)")]),
                       ["A.swift"], "探针失灵：真调用没认出来")
        XCTAssertTrue(Self.isReachableCallers(in: [("B.swift",
                        "// section.isReachable(reportAvailable:) 的历史说明")]).isEmpty,
                      "把注释也算成调用 → 删掉测试、只留一段说明文字，守卫照样绿")
        XCTAssertTrue(Self.isReachableCallers(in: [("C.swift",
                        "func isReachable(_ available: Bool) { }")]).isEmpty,
                      "重新签名而不带参数标签，也算失去了这条口径")
    }

}
