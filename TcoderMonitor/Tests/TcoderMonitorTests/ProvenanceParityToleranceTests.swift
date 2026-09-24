import XCTest
@testable import TcoderMonitor

/// 对表尺子 `scripts/report_parity.py` 的**容忍清单**自身的守卫（R5c 收尾）。
///
/// 为什么单独守这个：`report_parity.py` 是"CLI↔GUI 读数一致"这句话唯一的机器证据，
/// 而它有一个 `TOLERATED_NAMES` 的口子 —— 往口子里塞一个键，就能让任何不等**安静地**变成绿。
/// 本轮已经吃过一次这个形状（对表刚跑就报「provenance: 只有 GUI 有」，
/// 加容忍是最省事的错路）。⇒ 规矩：**能容忍，但每条要写清为什么天然不同，且不许吞掉判定**。
final class ProvenanceParityToleranceTests: XCTestCase {

    private func parityScriptText() throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = packageRoot.appendingPathComponent("scripts/report_parity.py")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "对表脚本不在 \(url.path)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// 抠出 `TOLERATED_NAMES = { … }` 里的 `"键": "理由"` 对。
    private func toleratedEntries(in text: String) -> [(key: String, reason: String)] {
        guard let start = text.range(of: "TOLERATED_NAMES = {") else { return [] }
        let body = text[start.upperBound...]
        guard let end = body.range(of: "\n}") else { return [] }
        var entries: [(String, String)] = []
        for line in body[..<end.lowerBound].components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\""), let colon = trimmed.range(of: "\": ") else { continue }
            let keyStart = trimmed.index(trimmed.startIndex, offsetBy: 1)
            let key = String(trimmed[keyStart..<colon.lowerBound])
            let reasonPart = trimmed[colon.upperBound...]
            let reason = reasonPart.replacingOccurrences(of: ",", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            entries.append((key, reason))
        }
        return entries
    }

    func testEveryToleratedKeyCarriesAReasonAndTheListIsNotEmpty() throws {
        let entries = toleratedEntries(in: try parityScriptText())
        XCTAssertFalse(entries.isEmpty, "一条容忍项都没扫到 ⇒ 解析坏了，这条守卫是永真绿")
        for entry in entries {
            XCTAssertGreaterThanOrEqual(entry.reason.count, 8,
                                        "容忍项 \(entry.key) 没写清为什么天然不同：\(entry.reason)")
            XCTAssertTrue(entry.reason.hasPrefix("\"") && entry.reason.hasSuffix("\""),
                          "容忍项 \(entry.key) 的理由必须是一句写下来的话，不是空着或注释：\(entry.reason)")
        }
        print("【对表容忍清单】\(entries.count) 条：" + entries.map { "\($0.key)" }.joined(separator: " · "))
    }

    /// 容忍只许给"计时读数 / 身份 / 哪个入口产的"，不许给**判定**。
    /// 反例形状（真被判红过的那种）：把 `score`、`failedSections`、`scanLimitations` 塞进来当"天然不同"。
    func testToleranceListNeverSwallowsAJudgement() throws {
        let judgementFragments = ["score", "count", "risk", "rank", "limitation", "failed", "severity", "status"]
        for entry in toleratedEntries(in: try parityScriptText()) {
            let hit = judgementFragments.filter { entry.key.lowercased().contains($0) }
            XCTAssertTrue(hit.isEmpty,
                          "容忍项 \(entry.key) 命中判定类字段 \(hit) —— 把判定容忍掉等于把对表尺子锯短")
        }
    }

    // MARK: - 缺席那两句读数必须点名对的那一侧

    /// 喂两份**形状已知**的合成报告给真脚本：GUI 少一键、CLI 少一键，各自的读数要说对是谁缺。
    ///
    /// 为什么单独钉：RD-31 × RD-60 那次对表被这两句带偏了整轮排查 —— 真缺键的是 GUI 侧
    /// 那份测试自带的装配副本，脚本却打印成「只有 GUI 有（CLI 缺）」，于是排查从
    /// "CLI 没量到"起步（复现读数见 Obsidian `138`）。判败/判容忍的**分类与计数**都不受影响，
    /// 改的只是这条读数说谁 ⇒ 这里连计数一起钉，免得下次连判定被顺手改掉还自以为是措辞。
    func testAbsenceLabelsNameTheSideThatActuallyMisses() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let gui = scratch.appendingPathComponent("gui.json")
        let cli = scratch.appendingPathComponent("cli.json")
        try writeProvenance(to: gui, keeping: ["shared": 1, "onlyInGui": 2])
        try writeProvenance(to: cli, keeping: ["shared": 1, "onlyInCli": 3])

        let output = try runParity(gui: gui, cli: cli, target: scratch)
        XCTAssertTrue(output.contains("onlyInGui: 只有 GUI 有（CLI 缺）"),
                      "GUI 侧独有一键却被说成 CLI 缺 ⇒ 两句读数写反了：\n" + output)
        XCTAssertTrue(output.contains("onlyInCli: 只有 CLI 有（GUI 缺）"),
                      "CLI 侧独有一键却被说成 GUI 缺 ⇒ 两句读数写反了：\n" + output)
        XCTAssertTrue(output.contains("逐项不等（判败）：2 处"),
                      "判败计数跟着变了 ⇒ 被改的不止措辞：\n" + output)
    }

    /// 一次性产物落仓库内 `.scratch/`（AGENTS §1.6），且量完就删。
    private func makeScratch() throws -> URL {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = packageRoot.deletingLastPathComponent()
            .appendingPathComponent(".scratch/r34-parity-label-\(UUID().uuidString)", isDirectory: true)
        XCTAssertTrue(dir.path.contains("/.scratch/"), "夹具不在仓库内 .scratch：\(dir.path)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeProvenance(to url: URL, keeping slots: [String: Int]) throws {
        try JSONSerialization.data(withJSONObject: ["provenance": slots]).write(to: url)
    }

    /// 真跑那把脚本（不是把它重抄一遍 Swift —— 那会变成第二把尺子）。
    private func runParity(gui: URL, cli: URL, target: URL) throws -> String {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/report_parity.py")
        XCTAssertTrue(FileManager.default.fileExists(atPath: script.path), "对表脚本不在 \(script.path)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, gui.path, cli.path, target.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 1, "两边各缺一键，脚本必须判败（rc=1）：\n" + output)
        return output
    }
}
