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
}
