import XCTest
@testable import TcoderMonitor

/// RD-60 第二半的**扫描型**守卫（R24）。每条都配双向元测试、都走 `SurfaceScanKit.codeLines`
/// 剥注释（R20 踩过：不剥注释会被自己的文档注释教绿），并且**分母 > 0** 自己作证。
///
/// 钉的是四件事：
/// · **一个台账、一次遍历**：写者不许为凑九格再 build 一遍台账（RD-38/43 同族）；
/// · **同刻同源**：`crashCount` 与 `crashEvidence.countedCrashCount` 取自同一个表达式；
/// · **措辞只有一个生产者**：八种原因那句话只许住在一处，屏上与 CLI 都只转发；
/// · **假话不许长回来**：那句"欠账已经欠出去了"的写法在源码里也不许再出现。
final class CrashEvidenceWiringGuardTests: XCTestCase {

    // MARK: - 守卫 1：写者只有一个台账，两枚读数同指一格

    /// `FileLogAnalyzer.swift` 里崩溃那一段写者的形状。
    struct WriterShape: Equatable {
        var ledgerBuilds: Int
        var crashCountSource: String?
        var snapshotCountedSource: String?
        /// 快照里**不是**从台账直传的那些格子（直传要求每一格都写 `ledger.<读数>`）。
        var slotsNotFromLedger: [String]
    }

    /// 取赋值右侧那个表达式：`;` 之后到行尾，去掉 Swift 源码里必然带的逗号与右括号。
    static func rhs(of line: String, separator: String) -> String? {
        line.components(separatedBy: separator).last?
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,)"))
    }

    static func writerShape(in content: String) -> WriterShape {
        let code = SurfaceScanKit.codeLines(content)
        var shape = WriterShape(ledgerBuilds: 0, crashCountSource: nil,
                                snapshotCountedSource: nil, slotsNotFromLedger: [])
        shape.ledgerBuilds = code.filter { $0.contains("CrashEvidenceLedger.build(") }.count
        shape.crashCountSource = code.first { $0.contains("summary.crashCount =") }
            .flatMap { rhs(of: $0, separator: "=") }
        shape.snapshotCountedSource = code.first { $0.contains("countedCrashCount:") }
            .flatMap { rhs(of: $0, separator: ":") }
        let slotNames = ["historicalConfirmedCount", "staleBuildConfirmedCount", "undatedConfirmedCount",
                         "suspectedCount", "parseFailedCount", "readFailedCount", "duplicateCount",
                         "filesWithCountedEvidence"]
        shape.slotsNotFromLedger = slotNames.filter { name in
            guard let line = code.first(where: { $0.contains(name + ":") }),
                  let value = rhs(of: line, separator: ":") else { return true }
            return value.hasPrefix("ledger.") == false
        }
        return shape
    }

    /// 写者所在的实现文件（走 `sourceFiles`，读不到就 XCTFail —— 不许返回空串让断言空转）。
    static func writerSource() throws -> String {
        let files = try SurfaceScanKit.sourceFiles(under: "Services/Logs")
        XCTAssertFalse(files.isEmpty, "Services/Logs 一个文件都没扫到 ⇒ 扫描面坏了")
        return try XCTUnwrap(files.first { $0.path.hasSuffix("FileLogAnalyzer.swift") }?.content,
                             "扫不到写者所在的文件（改名？挪走？）⇒ 这条判据覆盖不到任何东西")
    }

    func test_writerFeedsTheSnapshotFromOneLedgerInOnePass() throws {
        let shape = Self.writerShape(in: try Self.writerSource())
        print("【写者形状】台账 build \(shape.ledgerBuilds) 次 · crashCount 取 \(shape.crashCountSource ?? "nil")"
            + " · 快照第一格取 \(shape.snapshotCountedSource ?? "nil") · 非直传格 \(shape.slotsNotFromLedger)")
        XCTAssertEqual(shape.ledgerBuilds, 1, "同一件事开了第二次遍历（或一次都没跑）⇒ 两把尺子的胚胎")
        XCTAssertEqual(shape.crashCountSource, shape.snapshotCountedSource,
                       "crashCount 与 countedCrashCount 不同刻同源 ⇒ 两格迟早各说一样话")
        XCTAssertTrue(shape.slotsNotFromLedger.isEmpty,
                      "这些格子不是从本次台账直传的：" + shape.slotsNotFromLedger.joined(separator: "、"))
    }

    /// 分母自证：写者所在文件必须真被扫到、且它确实带着崩溃赋值行（否则上面那条是永真绿）。
    func test_metaWriterScannerDenominatorIsNotEmpty() throws {
        let files = try SurfaceScanKit.sourceFiles(under: "Services/Logs")
        XCTAssertFalse(files.isEmpty, "Services/Logs 一个文件都没扫到 ⇒ 扫描面坏了")
        let writer = try XCTUnwrap(files.first { $0.path.hasSuffix("FileLogAnalyzer.swift") }?.content)
        XCTAssertGreaterThanOrEqual(SurfaceScanKit.codeLines(writer)
                                    .filter { $0.contains("summary.") }.count, 10, "写者行数为 0 ⇒ 判据在空转")
    }

    /// 元测试：三种坏形状每种都要抓到，正确写法不误伤，注释里的写法不算。
    func test_metaWriterScannerSeparatesGoodBadAndCommentShapes() {
        let good = """
        let ledger = CrashEvidenceLedger.build(records: records, windowCutoff: cutoff)
        summary.crashCount = ledger.countedCrashCount
        summary.crashEvidence = CrashEvidenceSnapshot(countedCrashCount: ledger.countedCrashCount,
        historicalConfirmedCount: ledger.historicalConfirmedCount)
        """
        XCTAssertEqual(Self.writerShape(in: good).ledgerBuilds, 1)
        let rebuilt = good + "\nlet again = CrashEvidenceLedger.build(records: records, windowCutoff: cutoff)\n"
        XCTAssertEqual(Self.writerShape(in: rebuilt).ledgerBuilds, 2, "第二次遍历抓不到 ⇒ 没有牙")
        let substituted = good.replacingOccurrences(of: "countedCrashCount: ledger.countedCrashCount",
                                                   with: "countedCrashCount: aggregate.crashCount")
        let shape = Self.writerShape(in: substituted)
        XCTAssertNotEqual(shape.crashCountSource, shape.snapshotCountedSource,
                          "拿 aggregate 顶替本次台账却看不出来")
        let commented = "// summary.crashCount = ledger.countedCrashCount"
        XCTAssertNil(Self.writerShape(in: commented).crashCountSource, "注释被当成写者")
    }

    // MARK: - 守卫 2：八种原因那句话只有一个生产者

    /// 那句「确认崩溃 N 次计入」的**签名尾巴**：只许住在一个文件里。
    static func statementProducers(in files: [(path: String, content: String)]) -> [String] {
        files.filter { file in
            SurfaceScanKit.codeLines(file.content).contains { $0.contains("次计入") }
        }.map { $0.path }
    }

    func test_separatedReasonSentenceHasExactlyOneProducer() throws {
        let files = try SurfaceScanKit.sourceFiles(under: "")
        XCTAssertGreaterThanOrEqual(files.count, 40, "只扫到 \(files.count) 个实现文件 ⇒ 分母不对")
        let producers = Self.statementProducers(in: files)
        XCTAssertEqual(producers, ["Services/Logs/CrashEvidenceReadout.swift"],
                       "措辞长回台账、或在视图/CLI 里另拼一份，都是第二把尺子：" + producers.joined(separator: "、"))
    }

    func test_metaStatementProducerScannerSeparatesShapes() {
        let fake = [(path: "Views/Fake.swift",
                     content: "Text(\"确认崩溃 3 次计入\")\n// 台账那句也叫「确认崩溃 3 次计入」\n")]
        XCTAssertEqual(Self.statementProducers(in: fake), ["Views/Fake.swift"], "视图自己拼话抓不到")
        let commentedOnly = [(path: "Views/Fake.swift",
                              content: "// 旧写法是把「确认崩溃 3 次计入」自己拼一遍\n")]
        XCTAssertTrue(Self.statementProducers(in: commentedOnly).isEmpty, "注释被当成生产者")
    }

    // MARK: - 守卫 3：两个出口都只转发，不另拼一份中文

    /// 崩溃那几句的字面量（装配口专用；出现在别处就是第二处拼话）。
    static let crashPhrases = ["逐条原因如下", "次计入", "属历史报告", "本次未统计", "未产出可计数"]

    static func phraseOffenders(in files: [(path: String, content: String)]) -> [String] {
        files.flatMap { file in
            SurfaceScanKit.codeLines(file.content).filter { line in
                Self.crashPhrases.contains { line.contains($0) }
            }.map { "\(file.path)：\($0)" }
        }
    }

    func test_viewsAndCliOnlyForwardTheCrashFootnote() throws {
        let views = try SurfaceScanKit.sourceFiles(under: "Views/Logs")
        let cli = try SurfaceScanKit.sourceFiles(under: "Services/CLI")
        XCTAssertGreaterThanOrEqual(views.count + cli.count, 5, "两个出口都扫不到文件 ⇒ 判据在空转")
        let offenders = Self.phraseOffenders(in: views + cli)
        XCTAssertTrue(offenders.isEmpty,
                      "崩溃那几句只能在唯一装配口里拼一次：\n  " + offenders.joined(separator: "\n  "))
        let forwarders = (views + cli).filter { file in
            SurfaceScanKit.codeLines(file.content).contains { $0.contains("crashEvidenceFootnote") }
        }.map { $0.path }
        XCTAssertEqual(Set(forwarders).count, 2,
                       "上屏出口应当只有界面 ⓘ 与 CLI 的文本读数各一处：" + forwarders.joined(separator: "、"))
    }

    func test_metaPhraseScannerSeparatesShapes() {
        let bad = [(path: "Services/CLI/Fake.swift",
                    content: "return [\"逐条原因如下：一个合成数\"]\n")]
        XCTAssertEqual(Self.phraseOffenders(in: bad).count, 1, "出口自己拼话抓不到")
        let commented = [(path: "Views/Logs/Fake.swift",
                          content: "// 这里以前写「逐条原因如下」，现在只转发\n")]
        XCTAssertTrue(Self.phraseOffenders(in: commented).isEmpty, "注释被当成拼话处")
    }

    // MARK: - 守卫 4：那句假话在源码里也不许长回来

    static func retiredLiabilityLines(in files: [(path: String, content: String)]) -> [String] {
        files.flatMap { file in
            SurfaceScanKit.codeLines(file.content)
                .filter { $0.contains("待 LogSummary 落盘") }
                .map { "\(file.path)：\($0)" }
        }
    }

    func test_retiredLiabilityNoticeIsGoneFromTheSource() throws {
        let files = try SurfaceScanKit.sourceFiles(under: "")
        XCTAssertGreaterThanOrEqual(files.count, 40, "分母不对：只扫到 \(files.count) 个文件")
        let hits = Self.retiredLiabilityLines(in: files)
        XCTAssertTrue(hits.isEmpty, "RD-60 ③ 立掉的那句又长回来了：\n  " + hits.joined(separator: "\n  "))
    }

    func test_metaRetiredLineScannerSeparatesShapes() {
        let bad = "lines.append(\"还有 3 份未产出可计数的证据，待 LogSummary 落盘后展示\")"
        XCTAssertEqual(Self.retiredLiabilityLines(in: [(path: "Views/Fake.swift", content: bad)]).count, 1)
        XCTAssertTrue(Self.retiredLiabilityLines(in: [(path: "Views/Fake.swift",
                                                        content: "// 旧句尾是「待 LogSummary 落盘后展示」")]).isEmpty,
                      "注释里的历史说明被当成代码")
    }

    // MARK: - 守卫 5：CLI 的窗口天数必须传到那一句

    static func scoreRenderLines(in content: String) -> [String] {
        SurfaceScanKit.codeLines(content).filter { $0.contains("CLIScoreText.render(") }
    }

    func test_scoreCallCarriesTheWindowItActuallyScanned() throws {
        let router = try XCTUnwrap(SurfaceScanKit.sourceFiles(under: "Services/CLI")
                                   .first { $0.path.hasSuffix("CLIRouter.swift") }?.content,
                                   "扫不到 CLIRouter.swift")
        let renders = Self.scoreRenderLines(in: router)
        XCTAssertEqual(renders.count, 1, "score 的渲染入口应当只有一处：" + renders.joined(separator: " | "))
        XCTAssertTrue(renders[0].contains("windowDays:"),
                      "没把本次窗口天数传下去 ⇒ 那句「最近 N 天为窗口」会说出与扫描范围不同的话：" + renders[0])
    }

    func test_metaRenderScannerSeparatesShapes() {
        XCTAssertEqual(Self.scoreRenderLines(in: "CLIOutput.line(CLIScoreText.render(report, exit: exit))").count, 1)
        XCTAssertTrue(Self.scoreRenderLines(in: "// CLIScoreText.render(report, exit: exit)").isEmpty,
                      "注释里的写法被当成调用点")
    }
}
