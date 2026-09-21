/// OWNER: WS-X3 TestSplit —— 自 DesignAbsenceStateTests.swift 拆出，扫描面/上限/元守卫：空扫描不能当通过。用例本体未改，只是搬了家。
import Foundation
import XCTest
@testable import TcoderMonitor

extension DesignAbsenceStateTests {

    func testScanActuallyFindsEnoughFilesToBeMeaningful() throws {
        XCTAssertGreaterThan(Self.viewFiles.count, Self.minimumScannedViews,
                             "只扫到 \(Self.viewFiles.count) 个 Views 文件，口径坏了")
        XCTAssertGreaterThan(Self.allSourceFiles.count, Self.minimumScannedSources,
                             "只扫到 \(Self.allSourceFiles.count) 个源文件，口径坏了")
    }

    func testHandWrittenPlaceholderBypassesNeverIncrease() throws {
        let files = Self.viewFiles
        XCTAssertGreaterThan(files.count, Self.minimumScannedViews,
                             "扫不到 Views，下面那条上限断言就是永真绿")
        let hits = try Self.scan(Self.bypassPattern, in: files)
        let unexpected = hits.filter { !Self.excludedBypassSites.contains($0.file) }
        XCTAssertTrue(unexpected.isEmpty,
                      """
                      《42》§14.2 之外还有 \(unexpected.count) 处手写 `Theme.Placeholder.missingValue`，
                      它们绕开了 `Design/DataAbsence.swift` 这个单点，请改成取某一态的 `display`：
                      \(Self.describe(unexpected))
                      基线：改前 15 处 → 本轮改完实测 \(hits.count) 处（上限 \(Self.bypassCeiling)）。
                      """)
        XCTAssertLessThanOrEqual(hits.count, Self.bypassCeiling,
                                 "绕过单点的写法从 \(Self.bypassCeiling) 处涨到 \(hits.count) 处：\n"
                                     + Self.describe(hits))
    }

    /// 排除项也要被钉住：§14.2 那处是「字段缺失」，它若消失说明有人顺手改了不该改的，
    /// 若变多说明有人拿它当挡箭牌塞新的。
    func testTheExcludedFieldMissingSiteStaysExactlyOne() throws {
        let hits = try Self.scan(Self.bypassPattern, in: Self.viewFiles)
        let excluded = hits.filter { Self.excludedBypassSites.contains($0.file) }
        XCTAssertEqual(excluded.count, 1,
                       "《42》§14.2 的排除项应当恰好 1 处，实际 \(excluded.count) 处：\n"
                           + Self.describe(excluded))
    }

    /// 单点必须仍是单点：`enum DataAbsence` 全仓恰好一个定义，
    /// 且它住在 `Design/`（#47 上提的理由就是别再让页面各留一份）。
    func testAbsenceEnumIsDefinedExactlyOnceInsideDesign() throws {
        let files = Self.allSourceFiles
        XCTAssertGreaterThan(files.count, Self.minimumScannedSources, "扫不到源码，这条恰好一个的断言会空转")
        let definitions = try Self.scan(Self.absenceDefinitionPattern, in: files)
        XCTAssertEqual(definitions.count, 1,
                       "缺数据态的定义必须全仓唯一，实际定义处：\n" + Self.describe(definitions))
        XCTAssertTrue(definitions.first?.file.hasSuffix("Design/DataAbsence.swift") == true,
                      "唯一那份应在 Design/DataAbsence.swift，实际在 \(definitions.first?.file ?? "nil")")
    }

    /// 这一族不许长出第三份实现（历史上正是「基座一份 / WS-L 一份 / WS-M 一份」并存，
    /// 结果同一个「空」在三页有三种说法）。`GitDataAbsence` 是 Git 页的空态**文案**枚举，
    /// 不管数字位，允许并存；再冒第三个名字就要报总工，别默默加进白名单。
    func testAbsenceEnumFamilyHasNoThirdImplementation() throws {
        let files = Self.allSourceFiles
        XCTAssertGreaterThan(files.count, Self.minimumScannedSources, "扫不到源码，这条白名单断言会空转")
        let names = Set(try Self.scanNames(Self.absenceFamilyPattern, in: files).map(\.text))
        XCTAssertEqual(names, Self.allowedAbsenceEnums,
                       "缺数据枚举这一族的成员变了：期望 \(Self.allowedAbsenceEnums.sorted())，"
                           + "实际 \(names.sorted())——多出来的那份就是第二套语义")
    }

    private static func synthetic(_ path: String, _ lines: String...) -> (path: String, content: String) {
        (path: path, content: lines.joined(separator: "\n"))
    }

    /// 坏例抓得住：合成输入里埋 4 处绕过写法（含同文件多处），必须全数到并指到文件。
    func testMetaBypassDetectorCatchesSyntheticHits() throws {
        let bad = [Self.synthetic("Views/X/FakeA.swift",
                                  "import SwiftUI",
                                  "    Text(snapshot.map { \"\\($0)\" } ?? Theme.Placeholder.missingValue)",
                                  "    guard let read else { return Theme.Placeholder.missingValue }",
                                  "// 注释里再提一次 Theme.Placeholder.missingValue 不算违规",
                                  "    static let missing = Theme.Placeholder.missingValue"),
                   Self.synthetic("Views/Y/FakeB.swift",
                                  "        ?? Theme.Placeholder.missingValue")]
        let hits = try Self.scan(Self.bypassPattern, in: bad)
        XCTAssertEqual(hits.count, 4, "埋了 4 处代码违规（另有 1 行注释要放过），数错就是尺子坏了")
        XCTAssertEqual(Set(hits.map(\.file)), ["Views/X/FakeA.swift", "Views/Y/FakeB.swift"],
                       "报错必须指到文件，不然谁来修")
    }

    /// 好例不误伤：真·改完的 Views 扫出来必须只剩排除项那 1 处；
    /// 同时 `term` 之类的合规引用、注释里的历史提法都不该被抓。
    func testMetaBypassDetectorIgnoresCompliantSites() throws {
        let good = [Self.synthetic("Views/X/Compliant.swift",
                                   "// 以前这里写 `?? Theme.Placeholder.missingValue`，#47 改走单点",
                                   "    Text(DataAbsence.notAnalysed.display)",
                                   "    let term = DataAbsence.indeterminate.term",
                                   "    .help(absence.help(denominator: \"总行数\"))")]
        let hits = try Self.scan(Self.bypassPattern, in: good)
        XCTAssertTrue(hits.isEmpty, "合规写法被误伤，守卫撑不过一轮就会被人为删掉：\n" + Self.describe(hits))
        let real = try Self.scan(Self.bypassPattern, in: Self.viewFiles)
        XCTAssertEqual(Set(real.map(\.file)), Self.excludedBypassSites,
                       "改完的真实文件里只剩 §14.2 那 1 处，多一个就是本轮没做完")
        XCTAssertEqual(try Self.scan(Self.singlePointUsePattern, in: good).count, 2,
                       "单点调用计数扫不动，那条下限断言就是摆设")
    }

    /// 假绿防线：**空输入必须判失败**，不能因为「一条违规都没找到」就通过。
    func testMetaEmptyScanCanNeverSatisfyTheGuards() throws {
        let none: [(path: String, content: String)] = []
        let bypasses = try Self.scan(Self.bypassPattern, in: none)
        let definitions = try Self.scan(Self.absenceDefinitionPattern, in: none)
        let uses = try Self.scan(Self.singlePointUsePattern, in: none)
        XCTAssertTrue(bypasses.isEmpty, "空输入下绕过写法当然是空的——正因如此才要下面三条")
        XCTAssertNotEqual(definitions.count, 1, "空输入不该满足「恰好一个定义」")
        XCTAssertLessThan(uses.count, Self.minimumSinglePointUseSites,
                          "空输入不该满足单点调用下限，否则那条守卫是永真绿")
        XCTAssertLessThan(Self.swiftFiles(under: "NoSuchDirectory").count, Self.minimumScannedViews,
                          "路径写错却扫到「足够多」文件，分母闸就是假的")
        XCTAssertGreaterThan(Self.viewFiles.count, Self.minimumScannedViews,
                             "真源码扫不到文件 = 路径坏了，上面所有元测试通过也没意义")
    }

    /// 元测试的元测试：检测表与基线本身不许被清空 / 放宽。
    func testMetaGuardInputsAreStillLoadBearing() {
        XCTAssertFalse(Self.excludedBypassSites.isEmpty,
                       "排除集被清空的话，§14.2 那处会天天判红，守卫只会被删")
        XCTAssertEqual(Self.bypassCeiling, 1,
                       "基线当前应当恰好等于 §14.2 排除项的 1 处；往上调就是给绕过写法开口子")
        XCTAssertGreaterThanOrEqual(Self.minimumSinglePointUseSites, 12,
                                    "12 个锚点是这张工单的最低产出，下限被调低就等于活没干")
        XCTAssertGreaterThan(Self.minimumScannedViews, 0)
        XCTAssertGreaterThan(Self.minimumScannedSources, 0)
    }

}
