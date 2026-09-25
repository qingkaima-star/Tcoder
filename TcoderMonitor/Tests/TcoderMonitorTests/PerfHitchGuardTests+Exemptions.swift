import Foundation
import XCTest

/// OWNER: 总工（性能线）—— 禁则台账里的**具名逐点豁免**（口子本身也要被量）。
///
/// 为什么允许存在：`body/Mark 内零同步 I/O` 这句话的适用范围是**渲染求值路径**。
/// 现场样本：`Views/Logs/LogsView.swift` 的 `fileExists(atPath: project.path)` 在
/// `private func chooseLogFiles()` 里、紧接着 `panel.runModal()` ——
/// 用户点一次"附加日志"才跑一次，而且当场还要弹一个模态面板。
/// 它之所以被算进渲染路径，是因为 `PerfHitchScan.expand()` 是**纯文本跳**：
/// 跨度里整词提到某个同文件声明，就把那个声明整段并进来（:94 `GlassButton("附加日志") { chooseLogFiles() }`）。
///
/// 为什么用"逐点名单"而不是"教会扫描器分辨闭包"（这个选择要留档，否则下次又有人走回头路）：
/// `GlassButton("…") { action }` 的尾随闭包是**动作**，而系统 `Button(action: {…}) { label }`
/// 的尾随闭包是**视图内容**，`contextMenu { }` / `Menu { }` / `alert { }` 的又都是内容。
/// 要做对就得解析闭包归属；**分类写错的方向是"静默少报"**（真实债扫不出来），
/// 代价远大于省掉一处已知误定位。名单错了则会当场红——**要那个会响的**。
extension PerfHitchGuardTests {

    /// 逐点豁免名单：`规则 + 文件（相对各自扫描根）+ 命中行里必须含的 needle` 三者同时吻合才生效。
    /// ⚠ 不豁免整条规则、不豁免整文件——那正是"给未来的 I/O 开门"的形状。
    static let eventPathWaivers: [(rule: String, file: String, needle: String, reason: String)] = [
        (rule: "syncFileIO", file: "Logs/LogsView.swift", needle: "fileExists(",
         reason: "在 `chooseLogFiles()` 内、下一行就 `panel.runModal()`：一次点击跑一次的模态前置检查，"
             + "不是每帧求值；同文件另一处 `attributesOfItem`（经 body 读的 `attachedItems`）照旧算债"),
    ]

    static var eventPathExemptions: [PerfHitchScan.Exemption] {
        eventPathWaivers.map { PerfHitchScan.Exemption(rule: $0.rule, file: $0.file, needle: $0.needle) }
    }

    /// 口子自己要有牙：每条豁免必须**理由够长、文件还在、needle 还在、且真的命中过一处**。
    /// "装饰性豁免"（名单里写着、扫描器一条都没免掉）是最阴的一种——它看起来在被维护，其实早已失效。
    func testEventPathWaiversAreJustifiedAliveAndEffective() throws {
        let ruleNames = Set(PerfHitchScan.rules.map(\.name))
        let scan = try Self.scanRenderSurface()
        for waiver in Self.eventPathWaivers {
            XCTAssertTrue(ruleNames.contains(waiver.rule), "豁免指向一条不存在的规则：\(waiver.rule)")
            XCTAssertGreaterThanOrEqual(waiver.reason.count, 20,
                                        "豁免理由没写够，读的人无从判断免的是什么：\(waiver.file)")
            let url = Self.viewsRoot.appendingPathComponent(waiver.file)
            let source = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(source.contains(waiver.needle),
                          "豁免点名的 \(waiver.needle) 已经不在 \(waiver.file) 里 ⇒ 这条豁免要当场删掉，"
                            + "留着就是给未来的同形代码开门")
            XCTAssertTrue((scan.exempted[waiver.rule] ?? []).contains { $0.contains(waiver.file) },
                          "豁免「\(waiver.rule) @ \(waiver.file)」一条都没免到 ⇒ 它已经名存实亡"
                            + "（needle 写错/代码搬走了），要么修要么删")
        }
        XCTAssertLessThanOrEqual(Self.eventPathWaivers.count, 2,
                                 "口子只能保持小：超过两处就说明该改的是判据的射程说明，而不是继续堆豁免")
    }

    /// **守恒**：豁免只许把命中从"债"搬到"已豁免"那一栏，一条都不许消失。
    /// 这条断言不依赖任何具体数字，所以它不会因为还掉一笔债而需要有人来改它。
    func testWaivingMovesHitsWithoutLosingAny() throws {
        let strict = try Self.scanRenderSurface(waiving: [])
        let waived = try Self.scanRenderSurface()
        for rule in PerfHitchScan.rules.map(\.name) {
            XCTAssertEqual(strict.counts[rule] ?? -1,
                           (waived.counts[rule] ?? 0) + (waived.exempted[rule]?.count ?? 0),
                           "规则「\(rule)」在加豁免前后总数变了 ⇒ 豁免在**消灭**命中而不是改分类，"
                             + "这是最贵的那种静默失效")
        }
    }

    /// 双向：真债形状必须照样红，豁免必须绑死在同一个文件上。
    func testRealDebtShapeIsStillCountedAndWaiverIsFileBound() {
        // 合成形状必须与现场同构：body 里**调用**一个同文件函数/计算属性，
        // 那里头再做 stat()——`expand()` 就是靠这个整词提及把跨度并进来的。
        // （第一版我写成"函数体里 stat、但没人调用它"，扫到 0 处，
        //   差点把"跳展开坏了"当成"豁免生效了"——反例要先证明它有牙。）
        let source = """
        struct Panel {
            var items: [String] = []
            var sortedItems: [String] { items.sorted { $0 < $1 } }
            var body: some View {
                let rows = sortedItems
                let size = fileSize("x")
                Table(rows) { Text("x").help(String(size)) }
            }
            private func fileSize(_ path: String) -> Int {
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                      let n = attrs[.size] as? NSNumber else { return 0 }
                return n.intValue
            }
        }
        """
        let needle = "attributesOfItem("
        let strict = PerfHitchScan.scanWithExemptions(source: source, relativePath: "Logs/LogsView.swift")
        XCTAssertEqual(strict.counts["syncFileIO"] ?? 0, 1, "真债形状（body 里读到的计算属性链）必须数到 1")
        let sameFile = PerfHitchScan.scanWithExemptions(
            source: source, relativePath: "Logs/LogsView.swift",
            exempt: [PerfHitchScan.Exemption(rule: "syncFileIO", file: "Logs/LogsView.swift", needle: needle)])
        XCTAssertEqual(sameFile.counts["syncFileIO"] ?? 0, 0, "给了匹配的豁免就该免掉这一处")
        XCTAssertEqual(sameFile.exempted["syncFileIO"]?.count, 1, "免掉的必须留在 exempted 里，能点名")
        let otherFile = PerfHitchScan.scanWithExemptions(
            source: source, relativePath: "Other/LogsView.swift",
            exempt: [PerfHitchScan.Exemption(rule: "syncFileIO", file: "Logs/LogsView.swift", needle: needle)])
        XCTAssertEqual(otherFile.counts["syncFileIO"] ?? 0, 1,
                       "换个文件就照样算债 ⇒ 豁免没有变成整规则或整目录的口子")
        let otherNeedle = PerfHitchScan.scanWithExemptions(
            source: source, relativePath: "Logs/LogsView.swift",
            exempt: [PerfHitchScan.Exemption(rule: "syncFileIO", file: "Logs/LogsView.swift",
                                             needle: "fileExists(")])
        XCTAssertEqual(otherNeedle.counts["syncFileIO"] ?? 0, 1,
                       "needle 不同形就不能免 ⇒ 免的是那一格，不是那个文件里所有 I/O")
    }
}
