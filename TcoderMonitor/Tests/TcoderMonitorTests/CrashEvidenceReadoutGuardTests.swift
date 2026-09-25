import XCTest
@testable import TcoderMonitor

/// RD-60 ②③ 的守卫：崩溃证据那本细账必须有读者、屏上那两句必须逐字来自同一个生产者，
/// 而且被立掉的那把第二尺子不许回来。
///
/// 扫描型判据一律配**双向元测试**并断言分母 > 0（本仓吃过四次假绿：假零 / 永真绿 /
/// 门控绿灯 / 共享盲区）。
final class CrashEvidenceReadoutGuardTests: XCTestCase {

    // MARK: - 装配口的四态（正例 / 反例 / 未知态 / 失败态）

    /// 一份台账：三条原因分开算好（历史报告、无事件时间、去重合并）。
    private func ledgerWithHistory() -> CrashEvidenceLedger {
        let now = Date()
        return CrashEvidenceLedger.build(records: [
            CrashEvidenceRecord(path: "/r/current.ips", state: .confirmed, reason: nil,
                                eventDate: now, eventTimeSource: .reportField,
                                fileModifiedAt: now,
                                identity: AppBuildIdentity(processName: "ShopApp", bundleID: "com.example.ShopApp",
                                                           appVersion: "2.0 (9)", buildVersion: "9",
                                                           osVersion: nil, product: nil, terminationReason: nil),
                                signature: "EXC_BAD_ACCESS", incidentID: "CUR1", lineNumber: 1),
            CrashEvidenceRecord(path: "/r/old.ips", state: .confirmed, reason: nil,
                                eventDate: now.addingTimeInterval(-40 * 86_400),
                                eventTimeSource: .reportField, fileModifiedAt: now,
                                identity: AppBuildIdentity(processName: "ShopApp", bundleID: "com.example.ShopApp",
                                                           appVersion: "2.0 (9)", buildVersion: "9",
                                                           osVersion: nil, product: nil, terminationReason: nil),
                                signature: "EXC_CRASH", incidentID: "OLD1", lineNumber: 1),
            CrashEvidenceRecord(path: "/r/undated.log", state: .confirmed, reason: nil,
                                eventDate: nil, eventTimeSource: .unavailable, fileModifiedAt: now,
                                identity: AppBuildIdentity(processName: "ShopApp", bundleID: nil, appVersion: nil,
                                                           buildVersion: nil, osVersion: nil, product: nil,
                                                           terminationReason: nil),
                                signature: "EXC_CRASH", incidentID: nil, lineNumber: 3),
            CrashEvidenceRecord(path: "/r/copy.ips", state: .confirmed, reason: nil,
                                eventDate: now, eventTimeSource: .reportField, fileModifiedAt: now,
                                identity: AppBuildIdentity(processName: "ShopApp", bundleID: "com.example.ShopApp",
                                                           appVersion: "2.0 (9)", buildVersion: "9",
                                                           osVersion: nil, product: nil, terminationReason: nil),
                                signature: "EXC_BAD_ACCESS", incidentID: "CUR1", lineNumber: 1),
        ], windowCutoff: now.addingTimeInterval(-7 * 86_400))
    }

    private func summaryWithChannelFiles(_ n: Int) -> LogSummary {
        var summary = LogSummary()
        summary.crashCount = 1
        summary.totalLinesScanned = 100
        summary.crashReportCount = n
        summary.scannedFiles = (0..<n).map {
            ScannedLogFile(path: "/r/f\($0).ips", sizeBytes: 10, lineCount: 5,
                           modifiedAt: Date(), role: .crash)
        }
        return summary
    }

    /// ① 正例：接得上细账时，八种分开算好的原因**逐字**上屏，且假话那句已经不在。
    func testEvidenceBackedFootnoteQuotesTheLedgerVerbatim() {
        let ledger = ledgerWithHistory()
        let footnote = summaryWithChannelFiles(4)
            .crashEvidenceFootnote(windowDays: 7, evidence: ledger)
        print("正例脚注：\(footnote)")

        XCTAssertTrue(footnote.contains(ledger.statement),
                      "上屏那句必须把台账那句**原样**含进去，而不是重拼一遍：" + footnote)
        XCTAssertTrue(footnote.contains(ledger.unknownStatement ?? "@never@"),
                      "「哪些没测准」那句同样要逐字上来：" + footnote)
        XCTAssertTrue(footnote.contains("历史报告 1 次在窗口外"), footnote)
        XCTAssertTrue(footnote.contains("无事件时间 1 次单列"), footnote)
        XCTAssertTrue(footnote.contains("同一事件去重合并 1 份"), footnote)
        XCTAssertFalse(footnote.contains("待 LogSummary 落盘"),
                       "RD-60 ③：欠账那句是假话，不许以任何形式留在屏上：" + footnote)
    }

    /// ② 反例：统计过、真的什么都没有 ⇒ 一个字都不许多（不许冒出「另有 N 份」）。
    func testMeasuredButEmptyLedgerAddsNoClauses() {
        let ledger = CrashEvidenceLedger.build(records: [], windowCutoff: Date())
        let footnote = LogSummary().crashEvidenceFootnote(windowDays: 7, evidence: ledger)
        print("反例脚注：\(footnote)")
        XCTAssertEqual(footnote, "最近 7 天为窗口，逐条原因如下：确认崩溃 0 次计入"
            + " · 未测准：报告未自报构建版本，无法区分新旧构建。",
                       "零命中要说成零命中，既不许编原因也不许说未统计")
    }

    /// ③ 未知态（没统计）：拿不到台账 ⇒ 明说未统计，**绝不**回落到趋势桶估一个数。
    func testMissingLedgerSaysUnmeasuredAndNeverEstimates() {
        let footnote = summaryWithChannelFiles(3).crashEvidenceFootnote(windowDays: 7)
        print("未知态脚注：\(footnote)")
        XCTAssertTrue(footnote.contains("本次未统计"), footnote)
        XCTAssertTrue(footnote.contains("未产出可计数的证据"), footnote)
        XCTAssertFalse(footnote.contains("属历史报告"),
                       "没有细账就没有「历史报告 N 次」这句话 —— 那正是被立掉的第二把尺子：" + footnote)
        XCTAssertFalse(footnote.contains("待 LogSummary 落盘"), footnote)
    }

    /// ④ 失败态：读取失败的原因分布仍然说得出（这一格本就落在已盘上，不依赖细账）。
    func testReadFailuresKeepTheirOwnReasons() {
        var summary = summaryWithChannelFiles(1)
        summary.readFailedFiles = [
            ScannedLogFile(path: "/r/locked1.ips", sizeBytes: 10, lineCount: 0, modifiedAt: Date(),
                           role: .crash, readFailure: "权限不足"),
            ScannedLogFile(path: "/r/gone.ips", sizeBytes: 10, lineCount: 0, modifiedAt: Date(),
                           role: .crash, readFailure: "文件已不存在"),
            ScannedLogFile(path: "/r/locked2.ips", sizeBytes: 10, lineCount: 0, modifiedAt: Date(),
                           role: .crash, readFailure: "权限不足"),
        ]
        let footnote = summary.crashEvidenceFootnote(windowDays: 7, evidence: ledgerWithHistory())
        print("失败态脚注：\(footnote)")
        XCTAssertTrue(footnote.contains("权限不足 ×2"), footnote)
        XCTAssertTrue(footnote.contains("文件已不存在 ×1"), footnote)
    }

    // MARK: - 守卫 1：被立掉的那把尺子不许回来（Services 侧不得用趋势桶当崩溃计数）

    /// 判据形状：`Services/**` 里同一行**同时**出现 `trend` 与 `.crashes`。
    /// 这正是 `historicalCrashCount` 的签名形状（从已落盘的趋势桶求和当崩溃次数）。
    static func trendAsCrashRulerLines(in content: String) -> [String] {
        SurfaceScanKit.codeLines(content).filter { line in
            line.contains("trend") && line.contains(".crashes")
        }
    }

    static func serviceSideTrendCrashRulers() throws -> [(path: String, hits: [String])] {
        let files = try SurfaceScanKit.sourceFiles(under: "Services")
        XCTAssertFalse(files.isEmpty, "Services 侧一个文件都没扫到 = 扫描面坏了，这条判据是永真绿")
        return files.compactMap { file in
            let hits = Self.trendAsCrashRulerLines(in: file.content)
            return hits.isEmpty ? nil : (file.path, hits)
        }
    }

    func testNoServiceSumsTrendBucketsIntoACrashCount() throws {
        let offenders = try Self.serviceSideTrendCrashRulers()
        print("趋势桶当崩溃尺子的现量：\(offenders.count) / 上限 0（扫到 Services 文件若干）")
        XCTAssertTrue(offenders.isEmpty,
                      "RD-60 立的第二把尺子回来了 —— 窗口外历史崩溃只能由 CrashEvidenceLedger 说出口：\n"
                        + offenders.flatMap { o in o.hits.map { "\(o.path)：\($0)" } }.joined(separator: "\n"))
    }

    /// 双向元测试：用错形状的必须抓到、用对形状的不许误伤。
    func testMetaTrendRulerScannerSeparatesBothShapes() {
        let bad = "        return trend.filter { $0.date < cutoff }.reduce(0) { $0 + $1.crashes }"
        XCTAssertEqual(Self.trendAsCrashRulerLines(in: bad).count, 1,
                       "旧尺子那一行都不抓到 ⇒ 这条判据数不出东西")
        let goodErrorOnly = "        return trend.filter { $0.date < cutoff }.reduce(0) { $0 + $1.errors }"
        XCTAssertTrue(Self.trendAsCrashRulerLines(in: goodErrorOnly).isEmpty, "只数 errors 的被误伤")
        let chartSeries = #"LogSeries(name: "崩溃", severity: .crash, value: \.crashes)"#
        XCTAssertTrue(Self.trendAsCrashRulerLines(in: chartSeries).isEmpty,
                      "画趋势图用的 .crashes 不是尺子，不该误伤（它同一行里没有 trend）")
        let commented = "// 旧写法是 trend … $1.crashes"
        XCTAssertTrue(Self.trendAsCrashRulerLines(in: commented).isEmpty, "注释被当成代码")
    }

    /// 分母自证：判据对象确实存在过 —— 把已删除的那一行喂进扫描器必须抓到，
    /// 而真树里现在是 0 处（两者缺一就是永真绿）。
    func testMetaThePinnedRulerIsGoneFromTheTreeButWasOnceScannable() throws {
        XCTAssertEqual(try Self.serviceSideTrendCrashRulers().count, 0)
        let resurrected = "    func historicalCrashCount(windowDays: Int) -> Int {\n"
            + "        return trend.filter { $0.date < cutoff }.reduce(0) { $0 + $1.crashes }\n    }"
        XCTAssertFalse(Self.trendAsCrashRulerLines(in: resurrected).isEmpty,
                       "把删掉的尺子原样贴回来却抓不到 ⇒ 守卫没有牙")
    }

    // MARK: - 守卫 2：细账必须有生产读者（RD-34 的复发位）

    /// 只认**台账在场**的代码行：文件里既出现 `CrashEvidenceLedger`、又有代码行读到 `.statement`。
    /// 两处边界都是本仓踩过的：
    /// · 少了前半个条件，覆盖率那族 `CoverageMergeLedger.statement` 会把这条顶成永真绿
    ///   （`Sources/**` 里 `.statement` 的命中历史上全是覆盖率家的）；
    /// · 不剥注释，本装配口的头注正是靠写出被禁写法来解释为什么禁 ——
    ///   判据会被自己的文档教成绿（main 上 `fix(P57)` 就是这一课）。
    static func ledgerReaders(of member: String) throws -> [String] {
        let files = try SurfaceScanKit.sourceFiles(under: "")
        XCTAssertGreaterThanOrEqual(files.count, 40, "只扫到 \(files.count) 个实现文件 ⇒ 分母不对")
        return files
            .filter { $0.path.hasSuffix("Services/Logs/CrashEvidence.swift") == false }
            .filter { file in
                file.content.contains("CrashEvidenceLedger")
                    && SurfaceScanKit.codeLines(file.content).contains { $0.contains("." + member) }
            }
            .map { $0.path }
    }

    func testLedgerStatementsHaveProductionReaders() throws {
        for member in ["statement", "unknownStatement"] {
            let readers = try Self.ledgerReaders(of: member)
            print("`CrashEvidenceLedger.\(member)` 的读者：\(readers.joined(separator: "、"))")
            XCTAssertFalse(readers.isEmpty,
                           "`CrashEvidenceLedger.\(member)` 又变回有写无读了（RD-34 同族）")
        }
    }

    /// 三向元测试：真读者必须扫到、把读者换掉必须扫不到、**只写在注释里也必须扫不到**。
    func testMetaLedgerReaderScannerSeparatesAllThreeStates() throws {
        let files = try SurfaceScanKit.sourceFiles(under: "Services/Logs")
        XCTAssertFalse(files.isEmpty, "扫描面为空 ⇒ 元测试本身失效")
        let withReader = files.filter { $0.content.contains("CrashEvidenceLedger")
            && SurfaceScanKit.codeLines($0.content).contains { $0.contains(".unknownStatement") } }
        XCTAssertFalse(withReader.isEmpty, "真树里已经没有代码级读者了，上面那条守卫应该正在红")
        let emptied = withReader.map {
            (path: $0.path,
             content: $0.content.replacingOccurrences(of: ".unknownStatement", with: ".nothing"))
        }
        XCTAssertTrue(emptied.filter { $0.content.contains(".unknownStatement") }.isEmpty,
                      "把读者换掉之后还能扫到 ⇒ 判据在数别的东西")
        let commentOnly = """
        //  旧写法：evidence.unknownStatement 拼在脚注里。（讲给维护者看的话，不是读者）
        enum Holder { static func use(_ ledger: CrashEvidenceLedger) -> String { ledger.statement } }
        """
        XCTAssertTrue(SurfaceScanKit.codeLines(commentOnly).filter { $0.contains(".unknownStatement") }.isEmpty,
                      "注释里的写法被当成读者 ⇒ 这条判据会被自己的文档教绿")
    }

    // MARK: - 守卫 3：视图只接不改写

    func testViewsOnlyForwardTheCrashFootnote() throws {
        let files = try SurfaceScanKit.sourceFiles(under: "Views/Logs")
        XCTAssertGreaterThanOrEqual(files.count, 3, "只扫到 \(files.count) 个日志视图文件 ⇒ 扫描面坏了")
        let offenders = files.filter { file in
            let code = SurfaceScanKit.codeLines(file.content).joined(separator: "\n")
            return code.contains("未产出可计数") || code.contains("属历史报告")
                || code.contains("逐条原因")
        }
        XCTAssertTrue(offenders.isEmpty,
                      "崩溃证据那几句只能在 Services 侧拼一次；视图里出现即为第二把尺子："
                          + offenders.map { $0.path }.joined(separator: "、"))
        let forwarders = files.filter { file in
            SurfaceScanKit.codeLines(file.content).contains { $0.contains("crashEvidenceFootnote") }
        }
        XCTAssertEqual(forwarders.count, 1,
                       "上屏出口应当只有一个：" + forwarders.map { $0.path }.joined(separator: "、"))
    }

    // MARK: - §114 答：ⓘ 那格从「原因 × 份数」补上**是哪几份**

    /// 五份读失败 ⇒ ⓘ 只点三条（与散文预算同源），**余数出声**，且旧那句「原因分布」一字不动。
    /// 长度也量：这一格今天原本没有长度守卫，而它印的是绝对路径。
    func test_skipHelpNamesTheUnreadableFilesWithinProseBudget() throws {
        var summary = summaryWithChannelFiles(1)
        let files = Self.fiveUnreadableFiles()
        summary.readFailedFiles = files
        let lines = LogReading.skippedReasonLines(summary)
        let joined = lines.joined(separator: "\n")
        XCTAssertTrue(joined.contains("已跳过 5 份读取失败，原因分布："), "旧那句被挤掉了：\(joined)")

        let named = Self.linesNaming(lines, from: files)
        XCTAssertEqual(named.count, DuplicationResult.proseCoordinateBudget,
                       "点名条数不在散文预算上（预算 \(DuplicationResult.proseCoordinateBudget)）：\(joined)")
        XCTAssertTrue(joined.contains("（另有 2 份未点名）"),
                      "削了清单却不点名余数 ⇒ 读的人以为只有 3 份：\(joined)")
        for line in lines {
            XCTAssertLessThan(line.count, 1_200, "ⓘ 有一行 \(line.count) 字符 ⇒ 这格今天第一次有长度尺")
        }
    }

    /// 顺序可复现（RD-54 那族）：点名清单按路径排，与扫描回来的顺序无关。
    func test_skipHelpNamesFilesInAReproducibleOrder() throws {
        let files = Self.fiveUnreadableFiles()
        var forward = summaryWithChannelFiles(1)
        forward.readFailedFiles = files
        var backward = summaryWithChannelFiles(1)
        backward.readFailedFiles = Array(files.reversed())
        XCTAssertEqual(LogReading.skippedReasonLines(forward), LogReading.skippedReasonLines(backward),
                       "同一批文件换个扫描顺序就换句子 ⇒ 榜单不可复现")
    }

    /// 没量到读失败就一句不出（不许替没发生的事造句）。
    func test_skipHelpIsSilentWithoutReadFailures() throws {
        var summary = summaryWithChannelFiles(1)
        XCTAssertTrue(LogReading.skippedReasonLines(summary).isEmpty, "没这一格却造了句子")
        summary.readFailedFiles = []
        XCTAssertTrue(LogReading.skippedReasonLines(summary).isEmpty, "空清单也造句子")
    }

    /// 元测试：点名那把尺有牙。把「五份全抄」那版喂给同一个读数器，它必须报 5 条（> 预算 3）。
    /// ⚠️ 那句 `line.count < 1_200` **不在这条元测试的射程里**，也不装作在：这批真实形状的路径
    /// 五条全抄也只 610 字符，量不出牙。它是这格**有史以来第一把**长度尺（§114 答点名的缺口），
    /// 粗、只在句子被撑到异常时长时开火，将来更长的路径（用户目录、沙箱嵌套）才会咬到它。
    func test_meta_skipHelpRulersHaveTeeth() throws {
        let files = Self.fiveUnreadableFiles()
        var summary = summaryWithChannelFiles(1)
        summary.readFailedFiles = files
        let greedy = "读不到的这几份：" + files.map(\.path).joined(separator: "、") + "。"
        let named = LogReading.skippedReasonLines(summary).joined(separator: "\n")
        XCTAssertEqual(Self.linesNaming([greedy], from: files).count, files.count,
                       "认不出「全抄」⇒ 上面那条预算断言是空的")
        XCTAssertGreaterThan(files.count, DuplicationResult.proseCoordinateBudget,
                             "夹具条数不超过预算 ⇒ 「削清单」这个形状根本没被造出来")
        XCTAssertLessThan(named.count, greedy.count, "点名版不比全抄短 ⇒ 预算根本没削任何东西")
    }

    /// 五份**真实形状**的读失败：崩溃报告在 `DiagnosticReports` 下，路径长而互不相同。
    private static func fiveUnreadableFiles() -> [ScannedLogFile] {
        (1...5).map { index in
            ScannedLogFile(path: "/Users/one/Library/Logs/DiagnosticReports/com.tcoder.monitor-"
                            + "2026-09-2\(index)-0000\(index)-worker-thread-0x00000000.crash.report.ips",
                           sizeBytes: 4_096, lineCount: 0, modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
                           role: .crash, readFailure: "权限不足")
        }
    }

    /// 数 ⓘ 里点名了**几份**：按"这个路径整串出现在某一格里"数（分隔符随语言，不数分隔符）。
    private static func linesNaming(_ lines: [String], from files: [ScannedLogFile]) -> [String] {
        files.map(\.path).filter { path in lines.contains { $0.contains(path) } }
    }
}
