import XCTest
@testable import TcoderMonitor

// OWNER: 总工（检测正确性整改轮 · RD-18/19 的棘轮面）
//
// 「榜长冒充总数」这一族在巨大文件上已经修完（见 `HugeFileReadoutGuardTests`），
// 但同一个形状在**高复杂度榜**与**重复块榜**上还有 12 处：引擎早就算出了丢弃数
// （`DuplicationScan.rankedBlocks` 的 `droppedByCap` / `linesOutsideReportedBlocks`），
// 可这些数**从没上过屏、也没进评分detail** —— 有写无读，等于那半边工作白做。
// 本文件是**只减不增棘轮**：新增一处"把榜长当总数显示"当场红；还掉债要把上限一起拧下来。

final class BoardLengthReadoutRatchetTests: XCTestCase {

    /// 三张被 `prefix(N)` 截过的榜。读它们的 `.count` 当"数量"就是 RD-18 说的那件事。
    private static let boards = ["hugeFiles", "topComplexFunctions", "duplicatedBlocks"]

    /// 08:30 由总工本人实测填的基线（**只减不增**；还完一条就把这里划掉一条）。
    ///
    /// 22:0x 由 R7（建议与榜长真修）按 `--filter BoardLengthReadoutRatchetTests` 的**实扫现量**
    /// 往下拧了一格，数字就是从那次打印来的（同一趟：`榜长冒充总数：全仓现量 7 / 上限 12`）：
    ///   CodeRiskView 5→2 · CodeMetricsSections 3→2 · CodeRiskRows 2→1 · CodeRiskAdvice 1→0
    ///   新增一格 `CodeViewSupport.swift: 1` —— **不是漏网，是收口**：重复块榜长的取法
    ///   从四页各自 `code.duplicatedBlocks.count` 改成只读 `CodeBoardTruth.duplicationBoardCount`，
    ///   那一处原始读数因此搬了家；上限总和跟着它记，别让它变成隐形余量。
    /// **还剩下的 6 处是什么**（逐条点名，免得下一位去"修"一句诚实的话）：
    /// - `CodeRiskView.swift` 2 处 + `CodeRiskRows.swift` 的 `complexitySubtitle` 那处，读的是
    ///   **复杂度榜**，标签/句式已写明「复杂度上榜」「上榜 N 个」——按 §五 的裁定（`0a2e474`）
    ///   "榜的读数标签本身是诚实的，不动"，真总数走 `reportedHighRiskHotspotCount` 那一格；
    /// - `CodeMetricsSections.swift` 的 ⓘ（`重复块 %1$@ 个 · 复杂度上榜 %2$@ 个函数`）：
    ///   这条键被 `CodeGitTooltipTests` 逐字钉着，改文案要连那份账一起改，两家不同名 ⇒ 报总工；
    /// - `HealthCodeDimensions.swift` 1 处：`Services/Health/**` 不归 R7（工单的可写面只有
    ///   `Views/Code`、`Views/Health`、`Services/Code/CodeRisk*`），已列进 R7 的交回汇报。
    /// 重复块那一族真正还债的是 `AdviceWordingBoardTests`：它断言的是**页尾那句话**在
    /// 截断/未截断/台账缺席三态下各说什么，比"数原始读数"更接近这件事的本体。
    private static let budget: [String: Int] = [
        "Views/Code/CodeRiskView.swift": 2,           // 复杂度榜的读数与展开算术（标签已写明「上榜」）
        "Views/Code/CodeMetricsSections.swift": 2,    // ⓘ 里那句「重复块 N 个 · 复杂度上榜 M 个函数」
        "Views/Code/CodeRiskRows.swift": 1,           // complexitySubtitle 的「上榜 N 个」
        "Views/Code/CodeRiskAdvice.swift":  0,        // 已还：低档那句改成「榜内 N 个重复块」
        "Views/Code/CodeViewSupport.swift": 1,        // 榜长的唯一取法 `duplicationBoardCount` 本体
        "Services/Health/HealthCodeDimensions.swift": 1,  // 评分 detail「共 %d 处重复块」（归 WS-C）
    ]

    /// 两种**合法形状**，不许被算成违例（各配一条反向元测试钉着，见下）。
    private static let allowedShapes: [(marker: String, why: String)] = [
        (">", "门槛比较：`榜.count > rowLimit` 决定要不要出展开按钮，不是把榜长当总数"),
        ("<", "同上，反方向的比较"),
        ("榜内只列", "披露句式：真总数与榜长**并排**写出来（榜内只列 N 个，实际 M 个），正解形状"),
    ]

    // MARK: - 棘轮本体

    func test_boardLengthReadsNeverGrowBeyondBudget() throws {
        let files = try scannedFiles()
        XCTAssertFalse(files.isEmpty, "扫不到 Views/Services  ⇒ 这条棘轮一声不吭地通过")

        let counts = hitsByFile(files)
        for (file, cap) in Self.budget.sorted(by: { $0.key < $1.key }) {
            let now = counts[file] ?? 0
            XCTAssertLessThanOrEqual(now, cap,
                "\(file) 的「榜长当总数」从 \(cap) 涨到 \(now) —— 新增一处即判红；"
                + "命中明细：\n" + detailLines(files, file: file))
            // 余量必须出声：不还账的人看不见账，还了账的人忘了划基线。
            if now < cap {
                print("榜长棘轮：\(file) 现量 \(now) / 上限 \(cap) —— 已还 \(cap - now) 处，**请把上限拧到 \(now)**")
            } else {
                print("榜长棘轮：\(file) 现量 \(now) / 上限 \(cap)")
            }
        }
    }

    /// 结构钉：基线点名的文件必须都还在场。搬走/改名而不同批改这里 ⇒ 红，
    /// 否则"榜长冒充总数"会跟着文件一起消失，棘轮白绿。
    func test_everyBudgetedFileIsStillThere() throws {
        let paths = Set(try scannedFiles().map(\.path))
        for file in Self.budget.keys.sorted() {
            XCTAssertTrue(paths.contains(file), "基线点名的 \(file) 不在扫描面里了 —— 搬去哪了？同批改本表")
        }
    }

    func test_totalDebtIsReportedNotHidden() throws {
        let counts = hitsByFile(try scannedFiles())
        let total = counts.values.reduce(0, +)
        let cap = Self.budget.values.reduce(0, +)
        print("榜长冒充总数：全仓现量 \(total) / 上限 \(cap)")
        XCTAssertLessThanOrEqual(total, cap)
    }

    // MARK: - 元测试（证明这把尺子有牙、且不咬合法形状）

    func test_meta_flagsReadoutsBeyondBudget() {
        let three = """
            DataReadout(label: "重复块", value: NumberFormat.grouped(code.duplicatedBlocks.count), unit: "个")
            let total = code.topComplexFunctions.count
            let n = code.hugeFiles.count
            """
        XCTAssertEqual(countHits(in: three, path: "Synthetic.swift"), 3,
                       "三处都在把榜长当数用，抓不满 3 处就是这把尺子瞎了")
    }

    func test_meta_sparesGateAndDisclosureShapes() {
        // 反向样本：这三类写法**必须不被计入**，否则逼人写绕路代码。
        // 注意每行花括号都要配平 —— 本仓 `X3TestSizeAuditTests` 按花括号切函数，
        // 字符串里留一个不闭合的 `{` 会让这个用例被数成 67 行长函数（2026-09-22 实测踩过）。
        let legal = [
            "if code.duplicatedBlocks.count > Self.rowLimit { expanded.toggle() }",
            "let curve = hugeCount > code.hugeFiles.count",
            "detail: raw.detail + \"（榜内只列 \\(code.hugeFiles.count) 个，实际 \\(hugeCount) 个）\",",
        ].joined(separator: "\n")
        XCTAssertEqual(countHits(in: legal, path: "Synthetic.swift"), 0,
                       "合法形状被误判 —— 守卫开始咬自己人")
    }

    func test_meta_ignoresNeedlesSittingInComments() {
        let commented = """
            // 这里以前写着 code.hugeFiles.count，现在改走 reportedHugeFileCount
            let value = code.reportedHugeFileCount
            """
        XCTAssertEqual(countHits(in: commented, path: "Synthetic.swift"), 0,
                       "剥注释没生效：讲代码的话会被数成债")
    }

    // MARK: - 判据本体

    private func scannedFiles() throws -> [(path: String, content: String)] {
        try ["Views", "Services/Health", "Services/CLI"]
            .flatMap { try SurfaceScanKit.sourceFiles(under: $0) }
    }

    private func hitsByFile(_ files: [(path: String, content: String)]) -> [String: Int] {
        var result: [String: Int] = [:]
        for file in files {
            let n = countHits(in: file.content, path: file.path)
            if n > 0 { result[file.path] = n }
        }
        return result
    }

    private func countHits(in content: String, path: String) -> Int {
        codeLines(content).reduce(0) { acc, line in
            acc + Self.boards.filter { needle in
                line.contains("code.\(needle).count") && !isAllowed(line)
            }.count
        }
    }

    private func isAllowed(_ line: String) -> Bool {
        Self.allowedShapes.contains { line.contains($0.marker) }
    }

    private func detailLines(_ files: [(path: String, content: String)], file: String) -> String {
        guard let content = files.first(where: { $0.path == file })?.content else { return "（读不到内容）" }
        let lines = content.components(separatedBy: "\n")
        return codeLines(content).enumerated().compactMap { (_, line) in
            guard Self.boards.contains(where: { line.contains("code.\($0).count") }), !isAllowed(line) else {
                return nil
            }
            let number = lines.firstIndex(of: line).map { $0 + 1 } ?? 0
            return "  \(file):\(number) " + line.trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
    }

    /// 只剥整行注释；行号按原文报，避免命中信息把人指到错的地方。
    private func codeLines(_ content: String) -> [String] {
        content.components(separatedBy: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
        }
    }
}
