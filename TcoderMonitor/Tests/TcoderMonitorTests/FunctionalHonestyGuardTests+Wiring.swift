import Foundation
import XCTest
@testable import TcoderMonitor

/// 「两头都要在」这一族静态守卫：G9 诚实字段的写入点与读点、G10 折叠提示的入口。
///
/// 从 `FunctionalHonestyGuardTests.swift` 拆出来是因为主文件越过本仓 Tests 400 行口径 ——
/// 按规矩**拆片，不动阈值**。两把尺子都是"扫描面 + 合成输入元测试"的形状，
/// 与主文件里的 G1/G3 共用同一套 `SurfaceScanKit` 读盘入口。
extension FunctionalHonestyGuardTests {

    /// G9（P7-C 3-2）：诚实字段必须**两头都在** —— 分析器写它、视图读它。
    /// `CodeScanCoverage` 就是反面教材：上限算得清清楚楚，但契约里没有承接字段，
    /// 于是"只读了前 3 个文件"的报告在屏上与全量报告长得一模一样。
    static func deadHonestyFields(_ fields: [String],
                                  written: [(path: String, content: String)],
                                  read: [(path: String, content: String)]) -> [String] {
        let writeText = written.map(\.content).joined(separator: "\n")
        let readText = read.map(\.content).joined(separator: "\n")
        return fields.filter { field in
            !(writeText.contains("\(field) =") && readText.contains(field))
        }
    }

    func test_honestyFieldsAreBothWrittenAndDisplayed() throws {
        let services = try SurfaceScanKit.sourceFiles(under: "Services")
        let views = try SurfaceScanKit.sourceFiles(under: "Views")
        let dead = Self.deadHonestyFields(["analyzerRuleFailures", "scanLimitations"],
                                          written: services, read: views)
        XCTAssertTrue(dead.isEmpty, "这些诚实字段有写无读（或缺写入点）：\(dead)")
    }

    func test_deadFieldScannerCatchesSyntheticAndSparesWired() {
        let writtenOnly = [(path: "Services/Code/Fake.swift", content: "metrics.scanLimitations = limits\n")]
        XCTAssertEqual(Self.deadHonestyFields(["scanLimitations"], written: writtenOnly, read: []),
                       ["scanLimitations"], "只写不读没抓到 → 守卫是摆设")
        let wired = [(path: "Views/Code/Fake.swift", content: "code.scanLimitations\n")]
        XCTAssertTrue(Self.deadHonestyFields(["scanLimitations"], written: writtenOnly, read: wired).isEmpty,
                      "两头都在的合法写法被误伤")
    }

    /// G10（P7-C §S4）：**报数必须给入口**。屏上写「另有 N 个未列出 / 未展示」的地方，
    /// 同一个文件里必须出现 `DataDisclosureButton` —— 否则那句话是一条死路：
    /// 读者看完什么也做不了。性能页进程表原来正是这样（一句 `NoteLine` + 20 行里
    /// 19 行排序键相同），页尾实拍抓到后换成展开按钮。
    static func truncationNotesWithoutDisclosure(in files: [(path: String, content: String)]) -> [String] {
        files.compactMap { file in
            let hit = file.content.split(separator: "\n").contains { raw in
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.hasPrefix("//"), !line.hasPrefix("///") else { return false }
                return line.contains("未列出") || line.contains("未展示")
            }
            guard hit, !file.content.contains("DataDisclosureButton") else { return nil }
            return file.path
        }
    }

    func test_truncationIsAlwaysActionable() throws {
        let views = try SurfaceScanKit.sourceFiles(under: "Views")
        let dead = Self.truncationNotesWithoutDisclosure(in: views)
        XCTAssertTrue(dead.isEmpty, "这些文件只报「还有多少没列」却不给入口：\(dead)")
    }

    func test_truncationDisclosureRulerCatchesSyntheticAndSparesWired() {
        let deadEnd = [(path: "Views/Fake/Fake.swift",
                        content: "NoteLine(\"另有 3 个进程未列出。\")\n")]
        XCTAssertEqual(Self.truncationNotesWithoutDisclosure(in: deadEnd), ["Views/Fake/Fake.swift"],
                       "只报数不给入口没抓到 → 守卫是摆设")
        let wired = [(path: "Views/Fake/Fake2.swift", content: """
        if rows.count > rowLimit { DataDisclosureButton(expanded: expanded, hiddenCount: 3) {} }
        NoteLine("另有 3 个进程未列出。")
        """)]
        XCTAssertTrue(Self.truncationNotesWithoutDisclosure(in: wired).isEmpty, "配了入口的合法写法被误伤")
        let commented = [(path: "Views/Fake/Fake3.swift",
                          content: "// 原来这里只写「另有 3 个进程未列出」\n")]
        XCTAssertTrue(Self.truncationNotesWithoutDisclosure(in: commented).isEmpty,
                      "注释里交代旧写法就被判红")
    }
}
