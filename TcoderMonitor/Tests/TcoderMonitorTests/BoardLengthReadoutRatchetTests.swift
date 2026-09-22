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
    private static let budget: [String: Int] = [
        "Views/Code/CodeRiskView.swift": 5,           // 复杂度榜 / 重复块榜的读数、未展示数、"共 N 处"
        "Views/Code/CodeMetricsSections.swift": 3,    // 重复块读数与其页尾句
        "Views/Code/CodeRiskRows.swift": 2,           // 两枚 tooltip 里的"共 N 个"
        "Views/Code/CodeRiskAdvice.swift":  1,         // 建议句里的重复块数
        "Services/Health/HealthCodeDimensions.swift": 1,  // 评分 detail「共 %d 处重复块」
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
        // 反向样本：这两类写法**必须不被计入**，否则逼人写绕路代码。
        let legal = """
            if code.duplicatedBlocks.count > Self.rowLimit {
                let curve = hugeCount > code.hugeFiles.count
                          detail: raw.detail + "（榜内只列 \\(code.hugeFiles.count) 个，实际 \\(hugeCount) 个）",
            """
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
