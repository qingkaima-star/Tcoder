import XCTest
@testable import TcoderMonitor

/// CLI 的 `score` 文本必须把「哪些没量准」逐条打出来（整改意见 §五 / §十）。
///
/// 立案现场（总工 19:04 实读，不是推测）：
/// `git grep scanLimitations -- Views Services/CLI` **只有一处**命中
/// （`Views/Code/CodeMetricsView.swift`），于是"部分测量"这类句子
/// 只有打开界面的人才看得到；`score` 的文本读数一个字都没有，而 JSON 里有
/// ⇒ 看界面的人、读 CLI 的人、拿 JSON 的 AI 拿到**三种诚实度**。
/// 本文件钉的就是"三个出口同一句真话"，并配反例防它退回一个出口。
final class CLIPrecisionCaveatTests: XCTestCase {

    private func report(code: CodeMetrics?) -> ProjectReport {
        var report = ProjectReport(project: MonitoredProject(name: "夹具", path: "/tmp/cliprecision"))
        report.code = code
        return report
    }

    private func metrics(_ limits: [String]?) -> CodeMetrics {
        var metrics = CodeMetrics()
        metrics.scanLimitations = limits
        return metrics
    }

    // MARK: - 正例：每一条都要原样上屏

    func testEveryLimitationLineAppearsInScoreText() {
        let limits = ["块注释到文件末尾仍未闭合，其后的代码没有进入统计。",
                      "明细榜单截断到 20 块、未列出 72 个块 / 478 行。",
                      "隐藏条目 · 4 个条目 · 行数不适用（不是被读的文件）。"]
        let text = CLIScoreText.render(report(code: metrics(limits)), exit: .ok)

        for (index, limit) in limits.enumerated() {
            XCTAssertTrue(text.contains(limit), "第 \(index + 1) 条边界没上屏：\n\(text)")
        }
        XCTAssertTrue(text.contains("未量准 3 条"), "条数句必须与行数一一对得上：\n\(text)")
    }

    func testCaveatSitsBeforeAnyScoreLine() {
        // 「先说没量准，再给分」——与"失败路在分数之前"同一条理由。
        let text = CLIScoreText.render(report(code: metrics(["只测了一半。"])), exit: .ok)
        let lines = text.components(separatedBy: "\n")
        let caveat = lines.firstIndex { $0.hasPrefix("未量准") }
        let verdict = lines.firstIndex { $0.hasPrefix("综合健康分") || $0.hasPrefix("没有评分结果") }
        XCTAssertNotNil(caveat, "整段没打出来：\n" + text)
        XCTAssertNotNil(verdict, "没有分数行，这条顺序断言不作数：\n" + text)
        if let caveat, let verdict {
            XCTAssertLessThan(caveat, verdict, "未量准必须排在分数之前：\n" + text)
        }
    }

    // MARK: - 反例：不许凭空出声，也不许只打第一条

    func testNoCaveatSectionWhenNothingWasImprecise() {
        XCTAssertFalse(CLIScoreText.render(report(code: metrics(nil)), exit: .ok).contains("未量准"),
                       "没有边界却打「未量准 0 条」会被读成「有这一类信息」")
        XCTAssertFalse(CLIScoreText.render(report(code: metrics([])), exit: .ok).contains("未量准"))
    }

    func testDroppingAnyOneLimitationLineTurnsRed() throws {
        // 元测试（反例方向）：把三条里的任意一条从输出里删掉，本文件的正例必须抓得住。
        // 这里直接验"少打一条"这种最可能的退化形态：只保留首条的实现会留下两条缺失。
        let limits = ["甲。", "乙。", "丙。"]
        let rendered = CLIScoreText.precisionCaveat(report(code: metrics(limits)))
        XCTAssertEqual(rendered.count, limits.count + 1, "一段标题 + 逐条原样，少一条就是被折叠了")
        XCTAssertTrue(Array(rendered.suffix(limits.count)) == limits.map { "  边界：\($0)" },
                      "逐条内容必须原样，不许改写或只留第一条")
    }

    // MARK: - 结构钉：三个出口不许退回一个出口

    func testScanLimitationsHasBothGUIAndCLIReaders() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let code = packageRoot.appendingPathComponent("Sources/TcoderMonitor")
        let enumerator = FileManager.default.enumerator(at: code, includingPropertiesForKeys: nil)
        let swiftFiles = (enumerator?.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? [])
        XCTAssertFalse(swiftFiles.isEmpty, "扫描面为空 —— 这条断言不作数")

        var readers: Set<String> = []
        for url in swiftFiles {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            // 只数**代码行**：注释里点名这处缺陷的文字不该给自己凑证据。
            let hit = text.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .contains { $0.hasPrefix("//") == false && $0.contains("scanLimitations") }
            if hit { readers.insert(url.deletingPathExtension().lastPathComponent) }
        }
        XCTAssertTrue(readers.contains("CodeMetricsView"), "界面那格读数被摘掉了：\(readers)")
        XCTAssertTrue(readers.contains("CLIScoreText"), "CLI 文本不再读它 ⇒ 三个诚实度那格又回来了：\(readers)")
    }
}
