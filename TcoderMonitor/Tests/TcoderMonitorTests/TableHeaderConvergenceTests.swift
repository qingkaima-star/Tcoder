import Foundation
import XCTest
@testable import TcoderMonitor

// MARK: - #34「列头三套并存」收敛守卫
//
// 现场普查结论（本轮开工时实测，推导过程见 Obsidian《68 WS-Q 列头收敛》）：
// 三套里的**基座那套 `Theme.Table.Header`（`Design/TableKit.swift`）在开工前就已不存在**
// —— 提交 `ed58dd5`（WS-G #28）判它零引用、且是「与页面两套不兼容的第三条路」，整文件删除。
// 所以 #34 剩下的活是把**活着的两套并成一套**：
//   留 `Design/DataTable.swift` 的列数组系统
//   （`DataGridColumn` / `DataColumns` / `DataTableHeader` / `.tableCell`）；
//   删 `Views/PerfLogs/NumberText.swift` 的逐格系统（`TableHeaderCell` + `DataColumn` 标量列宽）。
// 留哪套不是手感：被删的基座自己的头注释写着「并集形状，与 WS-L 那套字段一一对应」，
// 即基座认的就是这一套。
//
// 本文件钉四件事：
// 1. 全仓只有**一个**列头组件定义，且它住在列系统那一侧；
// 2. 退役符号（`TableHeaderCell` / `DataColumn` / `Theme.Table` / `GridRow` /
//    `gridColumnAlignment`）不许回来——AGENTS §4 对基座那套写明「别再往回加」；
// 3. 每张表的列头都经 `DataTableHeader(columns:)`，**分母掉到 0 即判失败**（防假绿）；
// 4. 三页迁移是等价迁移：列名、列序、列宽、悬停口径与迁移前逐字一致（快照断言）。
//
// 扫描判据一律写成**纯函数**（喂字符串进、吐违规出），这样下面能用合成输入双向元测试它。

final class TableHeaderConvergenceTests: XCTestCase {

    // MARK: - 扫描器（纯函数）

    /// 「一个列头组件的定义」：`struct <名字含 TableHeader / HeaderCell / ColumnHeader>: View`。
    static let headerDefinitionPattern =
        #"struct\s+([A-Za-z]\w*(?:TableHeader|HeaderCell|ColumnHeader)\w*)\s*:\s*View"#

    /// `DataTableHeader(columns:` 的调用点（列头唯一的合法出口）。
    static let headerCallPattern = #"DataTableHeader\(\s*columns:"#

    /// 已经退场、代码里不许再出现的符号（整词匹配，`DataColumns` / `DataGridColumn` 不受牵连）。
    static let retiredSymbols = [
        "TableHeaderCell",       // WS-M 那套逐格列头（#34 删除）
        "DataColumn",            // WS-M 那套标量列宽表（#34 改名 PerfLogWidths，只留非列头宽度）
        "Theme.Table",           // WS-G 基座那套（#28 删除，AGENTS §4 明令别再往回加）
        "GridRow",               // 「Grid + 逐格手写表头」这套写法的地基
        "gridColumnAlignment",
    ]

    struct Hit: Equatable {
        let file: String
        let line: Int
        let text: String
    }

    private static func isComment(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
    }

    private static func regex(_ pattern: String) throws -> NSRegularExpression {
        try NSRegularExpression(pattern: pattern, options: [])
    }

    /// 按行扫正则。**整行注释豁免**：文档里必须提到被禁的写法，不能因此判违规。
    static func scan(_ pattern: String,
                     in files: [(path: String, content: String)]) throws -> [Hit] {
        let expression = try regex(pattern)
        var hits: [Hit] = []
        for file in files {
            for (index, raw) in file.content.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated() {
                let line = String(raw)
                guard !isComment(line) else { continue }
                let range = NSRange(line.startIndex..., in: line)
                if expression.firstMatch(in: line, options: [], range: range) != nil {
                    hits.append(Hit(file: file.path, line: index + 1,
                                    text: line.trimmingCharacters(in: .whitespaces)))
                }
            }
        }
        return hits
    }

    /// 整词扫描退役符号：前后都不能再接字母数字下划线，
    /// 否则 `DataColumn` 会把 `DataColumns` / `DataGridColumn` 全误伤一遍。
    static func retiredSymbolHits(in files: [(path: String, content: String)]) throws -> [Hit] {
        var hits: [Hit] = []
        for symbol in retiredSymbols {
            let pattern = "(?<!\\w)" + NSRegularExpression.escapedPattern(for: symbol) + "(?!\\w)"
            hits.append(contentsOf: try scan(pattern, in: files))
        }
        return hits.sorted { ($0.file, $0.line) < ($1.file, $1.line) }
    }

    static func describe(_ hits: [Hit]) -> String {
        hits.map { "  \($0.file):\($0.line) \($0.text)" }.joined(separator: "\n")
    }

    /// 真源码。路径按 `#filePath` 上溯到包根再进 `Sources/TcoderMonitor`。
    private static func swiftFiles(under subdirectory: String) -> [(path: String, content: String)] {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TcoderMonitorTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // TcoderMonitor（包根）
        let sourcesRoot = packageRoot.appendingPathComponent("Sources/TcoderMonitor")
        let root = subdirectory.isEmpty ? sourcesRoot
                                        : sourcesRoot.appendingPathComponent(subdirectory)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        var result: [(path: String, content: String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            // 相对 `Sources/TcoderMonitor` 的路径，报错信息才读得懂。
            let path = url.path.hasPrefix(root.path)
                ? String(url.path.dropFirst(root.path.count).drop(while: { $0 == "/" }))
                : url.lastPathComponent
            result.append((path: path.isEmpty ? url.lastPathComponent : path, content: content))
        }
        return result.sorted { $0.path < $1.path }
    }

    private static var allSourceFiles: [(path: String, content: String)] { swiftFiles(under: "") }
    private static var viewFiles: [(path: String, content: String)] { swiftFiles(under: "Views") }

    // MARK: - 守卫 1 / 2：唯一列头定义 + 退役符号不许回来

    /// 分母闸：扫不到足够文件就说明路径口径坏了，此时任何「0 违规」都是假的。
    private static let minimumScannedSources = 40

    func testSourcesDefineExactlyOneColumnHeaderComponent() throws {
        let files = Self.allSourceFiles
        XCTAssertGreaterThan(files.count, Self.minimumScannedSources,
                             "只扫到 \(files.count) 个源文件——路径口径变了，本文件所有正则断言都会空转")
        let definitions = try Self.scan(Self.headerDefinitionPattern, in: files)
        XCTAssertEqual(definitions.count, 1,
                       "列头组件必须全仓唯一，实际定义处：\n" + Self.describe(definitions))
        XCTAssertTrue(definitions.first?.file.hasSuffix("Design/DataTable.swift") == true,
                      "唯一的列头组件应当与列定义同处一文件，实际在 \(definitions.first?.file ?? "nil")")
    }

    func testRetiredHeaderSymbolsHaveNoCodeReferences() throws {
        let hits = try Self.retiredSymbolHits(in: Self.allSourceFiles)
        XCTAssertTrue(hits.isEmpty,
                      "这些写法已被 #34 / #28 判退场，回来就等于重新发散：\n" + Self.describe(hits))
    }

    // MARK: - 守卫 3：调用点全部走唯一组件

    /// 下限 = 收敛完成时的真实列头数（WS-L 五页 8 张 + WS-M 三表 3 张 = 11）。
    /// 只设下限不设上限：删掉任何一张表的列头都会红，新加表不受限。
    static let minimumHeaderCallSites = 11

    func testEveryTableHeaderGoesThroughTheOneComponent() throws {
        let files = Self.viewFiles
        XCTAssertGreaterThan(files.count, 20, "Views 扫不到文件，下面那条下限断言就是永真绿")
        let calls = try Self.scan(Self.headerCallPattern, in: files)
        XCTAssertGreaterThanOrEqual(calls.count, Self.minimumHeaderCallSites,
                                    "列头调用点只剩 \(calls.count) 处（下限 \(Self.minimumHeaderCallSites)）——"
                                        + "分母掉下来意味着有表绕开了唯一组件，或者列头被悄悄删了：\n"
                                        + Self.describe(calls))
    }

    // MARK: - 守卫 4：三页迁移是等价迁移（拿数据比对，不靠正则）

    private struct TableSnapshot {
        let name: String
        let columns: [DataGridColumn]
        let titles: [String]
        let helpByTitle: [String: String]
    }

    /// 标题与 `help` 逐字抄自迁移前的 `TableHeaderCell(...)` 调用点。
    private static let migratedSnapshots: [TableSnapshot] = [
        TableSnapshot(name: "进程占用排行", columns: DataColumns.processes,
                      titles: ["进程名称", "PID", "CPU 核", "内存", "线程", "打开文件"],
                      helpByTitle: ["PID": "进程号，只读展示",
                                    "CPU 核": "单核等价：1.00 = 占满一个核心，可大于 1",
                                    "内存": "常驻内存 RSS",
                                    "线程": "task_info 返回的线程数",
                                    "打开文件": "进程当前持有的描述符数量"]),
        TableSnapshot(name: "已扫描文件", columns: DataColumns.scannedLogFiles,
                      titles: ["类型", "文件", "大小", "行数", "修改"],
                      helpByTitle: ["大小": "文件字节数（1024 进制）"]),
        TableSnapshot(name: "维度分量", columns: DataColumns.healthComponents,
                      titles: ["维度", "得分", "权重", "贡献", "详情"],
                      helpByTitle: ["得分": "该维度 0~100 分，条形按同一比例",
                                    "权重": HealthBreakdown.weightColumnHelp,
                                    "贡献": "得分 × 归一化权重"]),
    ]

    func testMigratedTablesKeepTheirColumnsVerbatim() throws {
        XCTAssertEqual(Self.migratedSnapshots.count, 3, "三页迁移一张都不能少")
        for snapshot in Self.migratedSnapshots {
            XCTAssertEqual(snapshot.columns.map(\.title), snapshot.titles,
                           "\(snapshot.name) 的列名或列序与迁移前不一致")
            XCTAssertEqual(Set(snapshot.titles).count, snapshot.titles.count,
                           "\(snapshot.name) 快照本身列名重复，这条测试就白写了")
            XCTAssertEqual(snapshot.columns.filter { $0.width == nil }.count, 1,
                           "\(snapshot.name) 必须恰好一个弹性列，否则表头与行会错位")
            for column in snapshot.columns where column.width == nil {
                XCTAssertEqual(column.alignment, .leading,
                               "\(snapshot.name) 的弹性列（名称列）必须显式左对齐")
            }
            for column in snapshot.columns {
                XCTAssertFalse(column.title.isEmpty, "\(snapshot.name) 有列名为空")
                if let width = column.width {
                    XCTAssertGreaterThan(width, 0, "\(snapshot.name) 定宽列宽度必须为正")
                }
                if let expected = snapshot.helpByTitle[column.title] {
                    XCTAssertEqual(column.help, expected,
                                   "\(snapshot.name)「\(column.title)」列的口径文案变了")
                }
            }
        }
    }

    /// 复合列（量表 + 数字）的表头宽度必须把行内间距算进来，
    /// 否则定宽列会比行内容窄 4pt，列头与数字错位（`Grid` 时代是靠列自撑吸收的）。
    func testHealthScoreColumnWidthIncludesInnerSpacing() {
        XCTAssertEqual(DataColumns.healthScoreColumn,
                       DataColumns.healthScoreGauge + Theme.Spacing.xxs + DataColumns.healthScoreNumber)
    }

    /// `help` 是纯增量字段：三参数老写法（WS-L 全部现存调用）必须逐字照旧。
    func testColumnHelpIsAdditiveAndDefaultsToNil() {
        let legacy = DataGridColumn("行数", 56)
        XCTAssertNil(legacy.help)
        XCTAssertEqual(legacy.alignment, .trailing)
        XCTAssertEqual(legacy, DataGridColumn("行数", 56, .trailing, help: nil))
        XCTAssertEqual(DataGridColumn("文件", nil, .leading).width, nil)
        XCTAssertEqual(DataGridColumn("权重", 50, help: "整列口径").help, "整列口径")
    }

    /// 零调用实现不留：`DataColumns` 里每张列数组都必须有页面在用。
    func testEverySharedColumnArrayIsConsumed() throws {
        let shared: [(name: String, columns: [DataGridColumn])] = [
            ("duplicationBlocks", DataColumns.duplicationBlocks),
            ("complexityFunctions", DataColumns.complexityFunctions),
            ("hugeFiles", DataColumns.hugeFiles),
            ("dependencies", DataColumns.dependencies),
            ("recentCommits", DataColumns.recentCommits),
            ("shareBar", DataColumns.shareBar),
            ("processes", DataColumns.processes),
            ("scannedLogFiles", DataColumns.scannedLogFiles),
            ("healthComponents", DataColumns.healthComponents),
        ]
        XCTAssertEqual(shared.count, 9, "列宽表新增一张就要在这里登记一条，否则守卫会漏看")
        let files = Self.viewFiles
        XCTAssertGreaterThan(files.count, 20, "扫不到 Views，这条「有消费者」断言会永真绿")
        for entry in shared {
            XCTAssertGreaterThanOrEqual(entry.columns.count, 2,
                                        "\(entry.name) 只有 \(entry.columns.count) 列，不像一张表")
            let used = files.contains { $0.content.contains("DataColumns.\(entry.name)") }
            XCTAssertTrue(used, "DataColumns.\(entry.name) 没有任何页面在用——零调用实现不留")
        }
    }

    // MARK: - 元测试：证明上面这把尺子量得动东西
    //
    // 扫描型守卫最坏的失效不是报错，而是**正则写坏 / 路径打错 → 永远 0 命中还常绿**。
    // 所以每条判据都要三个方向都验到：坏例抓得住、好例不误伤、空输入判失败。

    private static func synthetic(_ path: String, _ lines: String...) -> (path: String, content: String) {
        (path: path, content: lines.joined(separator: "\n"))
    }

    func testMetaHeaderDefinitionDetectorCatchesSyntheticSecondImplementation() throws {
        let bad = [Self.synthetic("Views/X/FakeHeaderKit.swift",
                                  "import SwiftUI",
                                  "struct FancyTableHeader: View {",
                                  "    var body: some View { Text(\"列\") }",
                                  "}",
                                  "struct AnotherHeaderCell: View { let title: String }",
                                  "struct ThirdColumnHeader: View { let title: String }"),
                   Self.synthetic("Views/Y/OneMore.swift",
                                  "struct YetAnotherTableHeader: View {}")]
        let hits = try Self.scan(Self.headerDefinitionPattern, in: bad)
        XCTAssertEqual(hits.count, 4, "合成输入里埋了 4 处再造列头（三个同文件 + 一个另文件），抓不全就是尺子坏了")
        XCTAssertEqual(Set(hits.map(\.file)), ["Views/X/FakeHeaderKit.swift",
                                              "Views/Y/OneMore.swift"],
                       "报错要能指到文件，不然谁来修")
    }

    func testMetaHeaderDefinitionDetectorIgnoresCompliantCodeAndProse() throws {
        let good = [Self.synthetic("Design/DataTable.swift",
                                   "/// 注释与文档里提到 TableHeaderCell 不算再造组件",
                                   "struct DataTableHeader: View {",
                                   "    let columns: [DataGridColumn]",
                                   "}",
                                   "struct DataRowSeparator: View {",
                                   "    var body: some View { Rectangle() }",
                                   "}"),
                    Self.synthetic("Views/Performance/PerformanceProcessTable.swift",
                                   "            DataTableHeader(columns: DataColumns.processes)",
                                   "struct PerformanceProcessTableCard: View {}")]
        let hits = try Self.scan(Self.headerDefinitionPattern, in: good)
        XCTAssertEqual(hits.count, 1, "唯一那处合规定义被漏掉、或调用点被误判成定义，都说明尺子坏了")
        XCTAssertEqual(hits.first?.file, "Design/DataTable.swift")
    }

    func testMetaRetiredSymbolDetectorCatchesBadAndIgnoresCommentsAndLongerNames() throws {
        let bad = [Self.synthetic("Views/X/Bad.swift",
                                  "    TableHeaderCell(\"PID\", width: 52)",
                                  "    GridRow { Text(\"x\") }",
                                  "    Theme.Table.Header(columns: [])",
                                  "    let w = DataColumn.pid")]
        let hits = try Self.retiredSymbolHits(in: bad)
        XCTAssertEqual(hits.count, 4, "四个退役符号各必须被抓到一次，少一个就是检测表空转")

        // 关键误伤面：活着的 `DataColumns` / `DataGridColumn` 含有 `DataColumn` 这几个字母，
        // 整词匹配必须把它们放过——否则全仓每一次列引用都判违规，守卫只会被人为删掉。
        let good = [Self.synthetic("Views/X/Good.swift",
                                   "// 原先这里的 TableHeaderCell 与 DataColumn 已随 #34 删除",
                                   "/// 基座那套 `Theme.Table` 别再往回加",
                                   "    DataTableHeader(columns: DataColumns.healthComponents)",
                                   "    let column = DataGridColumn(\"行数\", 56)",
                                   "    func tableCell(_ column: DataGridColumn) {}",
                                   "    .frame(width: PerfLogWidths.sortPicker)")]
        let clean = try Self.retiredSymbolHits(in: good)
        XCTAssertTrue(clean.isEmpty,
                      "豁免宽窄失当，误伤了合规写法：\n" + Self.describe(clean))
    }

    func testMetaCallSiteDetectorCountsRealCallsNotProse() throws {
        var calls: [(path: String, content: String)] = []
        for index in 1...12 {
            calls.append(Self.synthetic("Views/P/Table\(index).swift",
                                        "            DataTableHeader(columns: DataColumns.shareBar) // #\(index)"))
        }
        XCTAssertEqual(try Self.scan(Self.headerCallPattern, in: calls).count, 12,
                       "调用点数不动，下限断言就是摆设")
        let prose = [Self.synthetic("Views/P/Note.swift",
                                    "// 这里以前写 DataTableHeader(columns: …)，现在改走 Theme 了。")]
        XCTAssertEqual(try Self.scan(Self.headerCallPattern, in: prose).count, 0,
                       "注释里的历史说明被数进分母，等于给人留了条凑数的路")
    }

    /// 假绿防线：**分母为 0 必须判失败**，不能因为「一条违规都没找到」就通过。
    func testMetaEmptyScanCanNeverSatisfyTheGuard() throws {
        let none: [(path: String, content: String)] = []
        let definitions = try Self.scan(Self.headerDefinitionPattern, in: none)
        let calls = try Self.scan(Self.headerCallPattern, in: none)
        let retired = try Self.retiredSymbolHits(in: none)
        XCTAssertTrue(retired.isEmpty, "空输入下退役符号扫描当然是空的——正因如此才要下面两条")
        XCTAssertNotEqual(definitions.count, 1, "空输入不该满足「恰好一个定义」")
        XCTAssertLessThan(calls.count, Self.minimumHeaderCallSites,
                          "空输入不该满足调用点下限，否则这条守卫是永真绿")
        XCTAssertGreaterThan(Self.allSourceFiles.count, Self.minimumScannedSources,
                             "真源码扫描拿到空列表 = 路径坏了，上面所有元测试通过也没意义")
        // 真源码里必须至少扫到那 11 处调用与 1 处定义（元测试与真实世界对齐的锚）。
        XCTAssertGreaterThanOrEqual(
            try Self.scan(Self.headerCallPattern, in: Self.viewFiles).count,
            Self.minimumHeaderCallSites)
    }

    /// 元测试自身的元测试：`retiredSymbols` 若被清空，守卫 2 就变成空转。
    func testMetaRetiredSymbolListIsNotEmptyAndNamesNothingLive() throws {
        XCTAssertGreaterThanOrEqual(Self.retiredSymbols.count, 5, "检测表被清空的话，守卫 2 就是装饰")
        // 表里不许写活着的名字（写进去就会把全仓合规代码判成违规）。
        let live = ["DataColumns", "DataGridColumn", "DataTableHeader", "tableCell", "PerfLogWidths"]
        for retired in Self.retiredSymbols {
            XCTAssertFalse(live.contains(retired), "「\(retired)」还活着，不该进退役表")
        }
    }
}
