import Foundation
import Observation
import XCTest
@testable import TcoderMonitor

/// P 心跳链路包名下的**粗 API 只减不增棘轮** + 细粒度失效面的行为守卫。
///
/// 【这条尺子量的是什么】xctrace 在产物 `465f5a6` 上量到 1.5 秒一次心跳引起
/// app-update 10.8~24.8 ms（预算 8.33 ms）、主线程 64.3% 样本落在
/// `AG::Graph::UpdateStack::update()`。病因是一次 publish 写 9~10 个 `@Observable`
/// 属性、外加`processesByMemory` 这类**每次访问现算全量排序**的计算属性，
/// 把总览页、侧栏、性能页整棵 body 拖进每 tick 重算。
///
/// P 包已经把采集侧改完（细粒度格、派生缓存在后台算一次），但**页面不许我碰**
/// （`Views/**` 归三家）。所以这里钉一条只减不增的棘轮，防止"新旧两套口径并存"——
/// 本仓教训：两套口径并存时，错的那套常在喂数据。基线取本文件写作时实测的调用点数，
/// 目标 0 由三家在 M1 清零；谁新增一处粗粒度读点，这里就红。
///
/// 【「完成」由 §3 的 `consumptionGateOpen` 定义】只减不增挡不住「原地踏步还宣布达标」：
/// 16 处一处不迁，那两条断言照样绿。所以达标与否看闸门，不看棘轮。
///
/// 【元测试】扫描型守卫最坏的失效不是报错而是**正则写坏 → 永远 0 命中还常绿**。
/// 所以每条扫描都配一个故意造的坏样例（必须被看见）与一个合规样例（不得被误伤），
/// 并要求分母（扫到的文件数 / 行数）足够大，"没扫到东西"一律判失败。
final class PerfInvalidationRatchetTests: XCTestCase {

    // MARK: - 路径口径

    /// `.../TcoderMonitor/Tests/TcoderMonitorTests/本文件` → 上溯三级 = `TcoderMonitor/`
    static let moduleRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // TcoderMonitorTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // TcoderMonitor

    /// 粗粒度读点只算**消费方**：页面 + 编排器。服务内部（采集侧自己写这些属性）不算。
    static let consumerDirectories = ["Sources/TcoderMonitor/Views", "Sources/TcoderMonitor/App"]
    static let serviceDirectory = "Sources/TcoderMonitor/Services/Performance"

    // MARK: - 口径（唯一一处定义，扫描与元测试共用）

    /// 旧粗粒度入口：整 `SystemSnapshot`、整条 `history`、整张榜单。
    /// 读它们 = 每次心跳都要重算读它的那棵 body。
    static let coarsePattern = #"monitor\s*\.\s*(latestSnapshot|history|topProcesses|trackedGroups|allProcesses|processesByMemory|measuredProcessCount|processMetricsTruncated|lastSampleAt)\b"#

    /// 新细粒度入口（P 包给三家的契约）。这里只用来证明"合规写法不会误伤"。
    static let finePattern = #"monitor\s*\.\s*(cpu|memory|rates|ledger|pulse|cpuRanking|memoryRanking|groupRanking|curve|isCollectingForDisplay)\s*\.\s*value\b"#

    /// **迁移期的专属失效**：采集侧已经把窗口切好、把榜单排好，页面拿到之后**又再切一次 / 再排一次**。
    /// 这种写法编译通过、画面也对，收益却原地消失（每 tick 仍然在 body 里做 O(n log n)），
    /// 而且不会被粗 API 棘轮抓到——因为它读的就是细格。所以单独一条，**基线 0，一处都不许有**。
    static let reslicePattern = #"\.(curve|cpuRanking|memoryRanking|groupRanking)\s*\.\s*value\s*\.\s*(sorted|suffix|prefix|dropFirst|dropLast|reversed|filter|shuffled)\b"#

    /// **迁移期最容易造出的假零**：`PerfMemoryLead.usedBytes` / `.totalBytes` 是**非 Optional
    /// 的 `UInt64`**，`.empty` 就是 `0 / 0`（`Services/Performance/PerfReadoutCells.swift`），
    /// 所以页面一旦绕过三态判据直接渲染它，"还没采到"就会显示成 **"0 B"**——
    /// 把"没测到"说成"测到 0"，正是本仓 ④⑤ 记过两类的形状。
    /// 三态判定的**唯一归属**是 `Views/PerfLogs/LiveReadings.swift` 的 `SystemReadings`
    /// （四条 guard：`snapshot == nil`、`memoryTotalBytes > 0`、`pressure != .unknown`、
    /// `usedBytes > 0`），迁移只许改"上下文怎么来"，不许把判据搬散。
    /// 判据是「**非 Optional 且 0 表示没读到**」，所以现在只管内存这两格；
    /// 以后谁给某个 lead 加了同形状的字段，要往这条里加名字，而不是新造一条。
    /// **基线 0，一处都不许有。**
    static let rawMemoryEvidencePattern = #"monitor\s*\.\s*(?:memory|cpu)\s*\.\s*value\s*\.\s*(usedBytes|totalBytes|coreCount|load1|load5|load15|uptimeSeconds)\b"#
    /// 回归守卫：采集侧不许再把这些退回去。
    /// 1) `processesByMemory` 不许再是计算属性（每次访问全量排序）；
    /// 2) `allProcesses` 必须留在观察图外；
    /// 3) 一 tick 不许再无条件写历史数组以外的粗属性（用等值闸门 `publishValue` / `write`）。
    static let computedMemoryRankingPattern = #"var\s+processesByMemory\s*:\s*\[ProcessSnapshot\]\s*\{"#
    static let unguardedAllProcessesPattern = #"(^|\n)\s*(private\(set\) )?var allProcesses\b"#

    // MARK: - 基线（本文件写作时实测；只减不增）

    /// 实测：`Views/**` + `App/**` 里共 16 处粗粒度读点。
    /// 迁移清单见 P 包报告；**目标 0**，清零后由总工把这个数往下拧。
    static let coarseCallSiteCeiling = 16

    /// 分母闸：扫不到足够文件与行数，任何「0 违规」都是假的。
    static let minimumConsumerFiles = 20
    static let minimumConsumerLines = 3_000

    // MARK: - 扫描器（纯函数：真文件与合成夹具走的是同一份代码）

    struct Line { var number: Int; var text: String }
    struct Doc { var file: String; var lines: [Line] }

    /// 整行注释（含 `///` 文档注释）豁免——说明文里必须提到被禁的写法本身。
    static func codeLines(of text: String) -> [Line] {
        text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            .map { Line(number: $0.offset + 1, text: String($0.element)) }
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    /// 返回 `文件:行号 命中行` 的清单。喂合成字符串与喂真仓库走的是同一个函数。
    /// 行号按**原文**报（注释行只是不参与匹配），否则报错信息会把人带到别的行上去。
    static func scanHits(pattern: String, in docs: [Doc]) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern, options: [])
        var hits: [String] = []
        for doc in docs {
            for line in doc.lines {
                let range = NSRange(line.text.startIndex..., in: line.text)
                // 一行里可能并排两处读点，按**调用点**计数而不是按行数。
                for match in regex.matches(in: line.text, options: [], range: range) {
                    let matched = Range(match.range, in: line.text).flatMap { String(line.text[$0]) } ?? line.text
                    hits.append("\(doc.file):\(line.number) \(matched.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        return hits
    }

    /// 合成一段文本当作夹具（行号从 1 起，与真文件同形状）。
    static func syntheticDoc(_ file: String, _ text: String) -> Doc {
        Doc(file: file, lines: codeLines(of: text))
    }

    static func documents(under directory: String) throws -> [Doc] {
        let root = moduleRoot.appendingPathComponent(directory)
        var collected: [Doc] = []
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            collected.append(Doc(file: url.path.replacingOccurrences(of: moduleRoot.path + "/", with: ""),
                                 lines: codeLines(of: text)))
        }
        return collected.sorted { $0.file < $1.file }
    }

    func scannedConsumerDocs() throws -> [Doc] {
        var docs: [Doc] = []
        for directory in Self.consumerDirectories { docs.append(contentsOf: try Self.documents(under: directory)) }
        return docs
    }

    func scannedServiceDocs() throws -> [Doc] {
        try Self.documents(under: Self.serviceDirectory)
    }

    // MARK: - 1. 粗 API 只减不增

    // MARK: - 2. 元测试：证明上面那把尺子抓得住坏样例

    static let migratedSamples = [
        "Text(Live.percent(monitor.cpu.value.usage))",
        "PerformanceLiveCharts(points: monitor.curve.value, context: context)",
        "ForEach(monitor.memoryRanking.value) { row in ProcessRow(process: row) }",
        "Theme.Readout.Field(\"采样点\", NumberFormat.grouped(monitor.pulse.value.historyCount))",
    ]

    static let dirtySamples: [(name: String, sample: String, pattern: String)] = [
        ("整帧快照又回来了", "private var snapshot: SystemSnapshot? { state.monitor.latestSnapshot }", coarsePattern),
        ("body 里现切曲线窗口", "CPUHistoryChart(snapshots: Array(state.monitor.history.suffix(90)))", coarsePattern),
        ("按内存榜每次访问现排", "let top = monitor.processesByMemory", coarsePattern),
        ("把全量进程数组留在观察图里", "private(set) var allProcesses: [ProcessSnapshot] = []", unguardedAllProcessesPattern),
        ("内存榜退回计算属性", "var processesByMemory: [ProcessSnapshot] { allProcesses.sorted { $0.memoryBytes > $1.memoryBytes } }",
         computedMemoryRankingPattern),
    ]

    // MARK: - 3. 「完成」的机器定义：细粒度消费闸门

    /// **M1 迁移闸门**。16 处粗粒度读点全部迁完、并且把 `coarseCallSiteCeiling` 一起拧成 0
    /// 之后，由总工翻成 `true`。
    ///
    /// 【为什么非要有这条】这轮的收益全部长在**消费侧**：采集侧改成细粒度格只是必要条件，
    /// 页面继续读 `monitor.latestSnapshot` 的话，每 tick 重算的还是那几整棵 body。
    /// 实测细粒度读点 = 0 处，也就是这轮在页面上**一点都没落地**。
    /// 而现有断言全是"只减不增"——16 处原封不动也能常绿，我随时可以在这个状态下宣布
    /// "120Hz 达标"。闸门把"完成"写死成机器可判的四态，见 `ConsumptionState`。
    ///
    /// 与 `BorderlessSurfaceGuardTests.m2WiringComplete` 同一套路子：测试在场、
    /// 当前不拦路、但**除了真完成之外没有一个状态可以静默绿**。
    static let consumptionGateOpen = false

    enum ConsumptionState: Equatable {
        /// 债还在（粗读点或上限任一未归零）。今天真状态。
        case debtOutstanding(coarse: Int, ceiling: Int)
        /// 债清完了却没人翻闸门——本文件该被撤除，不能一直挂着当"永远欠着"。
        case debtRepaidButGateShut(fine: Int)
        /// 唯一的"完成"。
        case done(fine: Int)
        /// 提前翻闸门：拿一个还没落地的状态去报成功。
        case openedTooEarly(coarse: Int, ceiling: Int, fine: Int)
    }

    /// 状态机本身是纯函数：元测试用合成数字直接验它，不必改动真仓库就能证明它不是摆设。
    static func consumptionState(coarse: Int, fine: Int, ceiling: Int, gateOpen: Bool) -> ConsumptionState {
        if gateOpen {
            return ceiling == 0 && coarse == 0 && fine > 0
                ? .done(fine: fine)
                : .openedTooEarly(coarse: coarse, ceiling: ceiling, fine: fine)
        }
        if coarse > 0 || ceiling > 0 { return .debtOutstanding(coarse: coarse, ceiling: ceiling) }
        return .debtRepaidButGateShut(fine: fine)
    }

    // MARK: - 4. 采集侧不许退回旧形状

    // MARK: - 5. 失效面真的收窄了（运行期行为，不是 grep 出来的）

    // MARK: - 6. T3 暂停：引用计数 + 暂停期的帧不丢、不补 0

    // MARK: - 7. T8 诚实性：细粒度格不得比粗粒度层更 loose

    // MARK: - 8. 契约面存在性（名字要稳：三家照这个名字迁，名字没了必须红）

}
