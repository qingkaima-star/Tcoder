import Foundation
import XCTest

/// OWNER: 总工（性能线）—— 渲染路径台账里的**读数**（不是债）。
///
/// 为什么单独成一块：`PerfHitchGuardTests` 的 `knownBaseline` 那个循环做的是
/// `now > 上限 ⇒ 红`，而它遍历的是"所有登记过的规则名"。把一条**读数**放在那张表里，
/// 就等于给它套上零余量上限——于是**写更多正确代码会被门禁拦住**。
/// 这个形状不是推测：2026-09-22 把 `dynamicNSColor` 改名成 `tokenReference` 时，
/// 注释已经改口"这条是读数、终点不是 0、不该挡路"，但**机制里的上限原封没动**
/// （#68：改了名字没改尺子）。今天把它真的搬出来。
extension PerfHitchGuardTests {

    /// 读数 → **下限**。低于下限先怀疑扫描器退化，而不是"页面变健康了"。
    ///
    /// `tokenReference`（旧名 `dynamicNSColor`）量的是"渲染路径里引用了多少次令牌成员"
    /// （`.textColor` / `.graphicColor` / `.badgeFill` / `.onFillColor`）。令牌从"每次访问现造"
    /// 改成缓存 `let` 之后，这条**不再是分配次数**：引用越密只说明每 tick 的重算面越大。
    /// 打到 0 等于要求页面不给任何东西着色，而往上涨是**本站鼓励的方向**
    /// （#19 那两笔"现造动态色 → 令牌"就是它）。
    ///
    /// 历史读数 107 → 86 → 59 → 58 → 56 →（扩面到 `Design/`）64 → 62。
    /// ⚠ **别拿这条去做"缓存化改造"**：那 8 处 `Design/**` 曾是诱饵——把它们改成存 `let`
    /// 会把数字从 62 抬到 54 而**运行时一个字节都没省**（2026-09-22 记过一次"假还债"念头）。
    /// 【下限为什么取 40】不是拍脑袋：单是 `.graphicColor` 一个成员历史上就占 **19** 处
    /// （107 → 86 那次就是它），所以四成员里丢任何一个、或模式被改窄，都会先掉破 40；
    /// 而"真的少到 40 以下"这种事需要有人重新看这条判据该不该存在，不该由一次改动悄悄发生。
    static let readings: [String: Int] = ["tokenReference": 40]

    /// 规则名的覆盖面 = 债 ∪ 读数。**这条等式是防"某个名字没人管"的**：
    /// 基线取不到的名字在旧实现里退化成 -1、永远不超 ⇒ 那条规则从闸门上消失。
    static var ruleNamesCovered: Set<String> { Set(knownBaseline.keys).union(readings.keys) }

    /// 读数越界＝**掉到下限以下**（方向与债相反）。话术必须先指向尺子，
    /// 因为最常见的成因是模式退化，而"0 处引用"看起来像"页面不依赖令牌了"，比红更难发现。
    static func readingFloorProblems(counts: [String: Int]) -> [String] {
        readings.compactMap { rule, floor in
            let now = counts[rule] ?? -1
            guard now < floor else { return nil }
            return "读数「\(rule)」现量 \(now) 已低于下限 \(floor) ⇒ **先复核扫描器**"
                + "（模式被改窄/改名会让它静默变 0），确认不是尺子坏了才允许改这个数"
        }
    }

    /// 闸门唯一的判定处：**债看上限、读数看下限**。
    /// 必须**只此一处**——元测试和被跑的那条走同一个函数，否则测试绿着而闸门是另一套逻辑
    /// （本仓为"同一判据两处入口"记过账）。
    static func ratchetProblems(counts: [String: Int], hits: [String: [String]] = [:]) -> [String] {
        var problems: [String] = []
        for (rule, baseline) in knownBaseline.sorted(by: { $0.key < $1.key }) {
            let now = counts[rule] ?? -1
            guard now > baseline else { continue }
            let detail = hits[rule, default: []].prefix(12).joined(separator: "\n    ")
            problems.append("「\(rule)」从基线 \(baseline) 涨到 \(now)（新增 \(now - baseline) 处）\n"
                            + "    负责人/终点：\(ownerNotes[rule] ?? "未写")\n    \(detail)")
        }
        problems += readingFloorProblems(counts: counts)
        for rule in PerfHitchScan.rules.map(\.name) where counts[rule] == nil {
            problems.append("规则「\(rule)」没有计数结果，扫描器漏了一条")
        }
        return problems
    }

    /// 台账打印：债与读数**分两栏、方向说清**。混在一行打"现量/上限"，
    /// 下一个改代码的人不知道该往哪边拧——那正是这条缺陷能活下来的原因。
    static func readoutSummary(counts: [String: Int]) -> String {
        let debt = knownBaseline.keys.sorted().map { rule -> String in
            let baseline = knownBaseline[rule] ?? 0
            let now = counts[rule] ?? -1
            return now < baseline ? "\(rule) \(now)/\(baseline)（可拧到 \(now)）" : "\(rule) \(now)/\(baseline)"
        }.joined(separator: "  ")
        let reading = readings.keys.sorted().map { rule -> String in
            "\(rule) \(counts[rule] ?? -1)/下限 \(readings[rule] ?? 0)"
        }.joined(separator: "  ")
        return "现量/上限 —— \(debt)   读数（只许在上限之上自由增长）—— \(reading)"
    }

    /// 双向元测试（合成计数，不扫盘）：**新增一处正确的令牌引用不许红**，
    /// 读数塌陷必须红且指向尺子，真债涨一处仍然红。
    func testReadingGrowthIsAllowedButCollapseIsNot() {
        // 基线数**从 knownBaseline / readings 取，不在这里抄第二份**：
        // 我 09-25 把 `syncFileIO` 的上限从 2 拧到 1（#72 那处事件路径改记成具名豁免），
        // 这个夹具当场红——正好证明"把数抄一份"是错的（本仓为两份副本两个数记过好几回）。
        var healthy = Self.knownBaseline
        healthy["tokenReference"] = (Self.readings["tokenReference"] ?? 0) + 1   // 多一处正确取色
        XCTAssertTrue(Self.ratchetProblems(counts: healthy).isEmpty,
                      "多一处正确的令牌引用就把门禁打红 ⇒ 这条尺子在惩罚它最想鼓励的写法：\(Self.ratchetProblems(counts: healthy))")

        let degraded = healthy.merging(["tokenReference": 0]) { _, new in new }
        let collapsed = Self.ratchetProblems(counts: degraded)
        XCTAssertEqual(collapsed.count, 1, "读数静默变 0 必须出声：\(collapsed)")
        XCTAssertTrue(collapsed[0].contains("先复核扫描器"),
                      "话术要先指向尺子，不是指向'页面变健康了'：\(collapsed[0])")

        let debtRule = "dynamicColorConstruction"
        let newDebt = healthy.merging([debtRule: (Self.knownBaseline[debtRule] ?? 0) + 1]) { _, new in new }
        XCTAssertTrue(Self.ratchetProblems(counts: newDebt).contains { $0.contains("dynamicColorConstruction") },
                      "把读数搬出去之后，真债那条必须照样管得住")
    }

    /// 覆盖面必须是"债 ∪ 读数 == 规则名"，且**两栏不许有交集**——
    /// 一条规则同时被当债和读数管，就会出现"两个方向互相掩护"。
    func testDebtAndReadingTablesPartitionTheRuleNames() {
        XCTAssertEqual(Self.ruleNamesCovered, Set(PerfHitchScan.rules.map(\.name)),
                       "有规则没进账，或者有名字对不上规则（改名最容易留这种洞）")
        XCTAssertTrue(Set(Self.knownBaseline.keys).isDisjoint(with: Self.readings.keys),
                      "一条规则只能属于一栏：债（有上限）或读数（有下限）")
    }

    /// 仓库根（本文件 → TcoderMonitorTests → Tests → TcoderMonitor → 工作树根）。
    /// 与 `DocReferenceRatchetTests.repoRoot` 同一把定位法：**不写绝对路径**，
    /// 否则换一棵 worktree 这条测试就随 checkout 位置变色（第 12 类）。
    private static let specRelPath = "docs/superpowers/specs/2026-09-20-performance-120hz-design.md"

    /// spec 那张 T5 规则表必须**逐条点名**词表里的每条禁则，且不许留着已改名/删掉的旧规则。
    ///
    /// 为什么要（2026-09-27 #131）：那张表此前抄了"现量/上限"两个数，于是它从 09-22 起就在说谎
    /// （抄的是 `fullSort 9/9`、`syncFileIO 2/2`，守卫现量已是 `8/8` 与 `1/1`），而全仓没有一条测试
    /// 读过它 ⇒ 文档与尺子各说各话、两边都自洽（第 37 类那句"数抄进文档那天起开始倒计时"的又一实例）。
    /// 数已经搬回守卫那一行；这里补**名字级**对账——它是可机检的，而"数字对不对"不是。
    func testSpecRuleTableNamesEveryRule() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(Self.specRelPath)
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        // **只取 T5 那一张表**：表头行往后、连续以 `|` 开头的行段。
        // 第一版我把整份文档的表格行都收进来，当场误报四行别的表
        // （`CVDisplayLinkCreateWithActiveCGDisplays`／`CADisplayLink`／`GlassEffectContainer`／`onScrollPhaseChange`）
        // ——那是我的解析窗口太宽，不是规范过期：**报"名单过期"之前要先确认数的是哪张表**。
        guard let header = lines.firstIndex(where: { $0.contains("| 规则 | 终点 | 为什么 |") }) else {
            XCTFail("spec 里找不到 T5 那张规则表（表头改了吗？）⇒ 这条对账没有对象，不许当通过")
            return
        }
        var documented = Set<String>()
        var idx = header + 1
        while idx < lines.count {
            let row = lines[idx].trimmingCharacters(in: .whitespaces)
            guard row.hasPrefix("|") else { break }
            idx += 1
            guard !row.contains("---"), row.hasPrefix("| `") else { continue }
            let cells = row.split(separator: "|")
            guard let first = cells.first.map({ $0.trimmingCharacters(in: .whitespaces) }),
                  first.hasPrefix("`"), first.contains("`") else { continue }
            let name = first.dropFirst().split(separator: "`").first.map(String.init) ?? ""
            if !name.isEmpty { documented.insert(name) }
        }
        let declared = Set(PerfHitchScan.rules.map(\.name))
        XCTAssertFalse(documented.isEmpty, "T5 表里一条规则名都没数到 ⇒ 表格形状变了，这条对账在空转")
        XCTAssertEqual(documented.subtracting(declared), [],
                       "spec 的 T5 表里点着词表已经没有的规则名 ⇒ 名单过期（改名或删规则没同步文档）")
        XCTAssertEqual(declared.subtracting(documented), [],
                       "词表里有 \(declared.subtracting(documented).sorted()) 这条禁则没写进 spec 的 T5 表"
                       + "——新加判据不写进这张表，读规范的人就以为终点不是 0")
    }
}
