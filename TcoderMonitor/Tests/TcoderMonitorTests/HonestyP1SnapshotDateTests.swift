import XCTest
@testable import TcoderMonitor

/// WS-R 关闭 #25：内置快照的切数据日期 `DependencySnapshot.snapshotDate`
/// 此前**生产代码零消费**（只有 `DependencyAnalysisTests` 断言它是个合法日期），
/// 于是一天前的快照和一年前的快照在界面上长得一模一样——
/// 「未联网核对：漏洞判定只依据内置快照」这句话没有告诉用户那份快照是哪天的。
///
/// 本文件钉两件事：
/// ① 离线判据与「未核对」磁贴副标题必须带上**快照日期 + 距今时长**；
/// ② 这句话只是加信息，**不得动任何判定**——尤其 `VulnerabilityEvidence.classify`
///    是拿 `networkLookupNote.contains("失败")` 当降级判据的，新文案里混进「失败」
///    就会把一次成功的在线核对读成降级（阈值与判据属冻结区）。
final class HonestyP1SnapshotDateTests: XCTestCase {

    // MARK: - ① 日期必须出现在用户看到的两句离线文案里

    func testOfflineCaveatNamesTheSnapshotDayAndItsAge() {
        let note = ManifestDependencyAnalyzer.offlineCaveat(for: offlineReport())
        print("【#25 现场】离线判据文案：\(note)")
        print("【#25 现场】未核对副标题：\(DependencySafetyVerdict(offlineReport()).summaryCaption)")

        XCTAssertTrue(note.contains("未联网核对"), "既有判据不能丢：\(note)")
        XCTAssertTrue(note.contains("快照截至"), "必须说明内置快照是哪天的：\(note)")
        XCTAssertTrue(note.contains(DependencySnapshot.snapshotDayText),
                      "文案里的日期必须就是 snapshotDate 那一天：\(note)")
        XCTAssertTrue(note.contains("（\(DateFormat.sinceDescription(DependencySnapshot.snapshotDate))）"),
                      "光有日期还不够，必须紧跟距今时长（复用 DateFormat.sinceDescription）：\(note)")
    }

    // MARK: - #35 假精度：快照只有天粒度，不许渲染出分钟

    /// 用户看到 `17:05` 会以为我们掌握分钟级采集时刻，而那个数只是当初写代码那一下的挂钟。
    func testSnapshotDisclosureCarriesNoInventedTimeOfDay() {
        XCTAssertFalse(DependencySnapshot.snapshotDayText.contains(":"),
                       "日期段里不许出现时分：\(DependencySnapshot.snapshotDayText)")
        XCTAssertFalse(DependencySnapshot.asOfText.contains(":"),
                       "整句披露都不该带时分冒号：\(DependencySnapshot.asOfText)")
        XCTAssertEqual(DependencySnapshot.snapshotDayText.count, 10,
                       "到日的日期就是 yyyy-MM-dd 十个字符：\(DependencySnapshot.snapshotDayText)")
        let characters = Array(DependencySnapshot.snapshotDayText)
        guard characters.count >= 8 else {
            return XCTFail("日期段短到不能按 年-月-日 检查，实际：\(DependencySnapshot.snapshotDayText)")
        }
        XCTAssertEqual(String(characters[4]), "-", "必须是 年-月-日 的形状：\(DependencySnapshot.snapshotDayText)")
        XCTAssertEqual(String(characters[7]), "-", "同上：\(DependencySnapshot.snapshotDayText)")
        XCTAssertTrue(characters[0...3].allSatisfy { $0.isNumber },
                      "年份段必须是四位数字：\(DependencySnapshot.snapshotDayText)")

        let calendar = Calendar(identifier: .gregorian)
        let stamp = calendar.dateComponents([.hour, .minute], from: DependencySnapshot.snapshotDate)
        XCTAssertEqual(stamp.hour, 0, "snapshotDate 本身必须落在日首，不是某个月的第 17 小时")
        XCTAssertEqual(stamp.minute, 0, "同上：分钟没有依据就该是 0")
    }

    /// 面向用户的文案里不许出现那个年份写错的兜底常量（2025-09-19 17:05）。
    func testNoUserFacingTextLeaksTheWrongYearFallbackConstant() {
        let year = Calendar(identifier: .gregorian).component(.year, from: DependencySnapshot.snapshotDate)
        XCTAssertGreaterThan(year, 2025, "快照年份本身就是这条的对照")
        let expected = String(year)
        for text in [DependencySnapshot.asOfText,
                     ManifestDependencyAnalyzer.offlineCaveat(for: offlineReport()),
                     DependencySafetyVerdict(offlineReport()).summaryCaption] {
            XCTAssertTrue(text.contains(expected), "文案里的年份必须来自 snapshotDate：\(text)")
            XCTAssertFalse(text.contains("2025"), "兜底常量的错误年份不得显形：\(text)")
        }
    }

    func testUncheckedVerdictCaptionNamesTheSnapshotDay() {
        let caption = DependencySafetyVerdict(offlineReport()).summaryCaption

        XCTAssertTrue(caption.contains("未联网核对"), caption)
        XCTAssertTrue(caption.contains("快照截至"), "磁贴副标题也要带快照日期：\(caption)")
        XCTAssertTrue(caption.contains(DependencySnapshot.snapshotDayText),
                      "视图侧的日期必须与分析器同一天、同一个粒度：\(caption)")
        XCTAssertFalse(caption.contains(":") || caption.contains("："),
                       "副标题里不该出现任何时分（内置快照没有分钟级依据）：\(caption)")
        XCTAssertFalse(caption.contains("未发现已知漏洞"),
                       "加了日期不等于给出 all-clear：\(caption)")
    }

    // MARK: - ② 只加信息，不动判定

    /// `classify` 拿 `contains("失败")` 当降级判据；新文案必须对这个词免疫。
    func testSnapshotDisclosureNeverCarriesTheDegradedKeyword() {
        XCTAssertFalse(DependencySnapshot.asOfText.contains("失败"),
                       "这句话一旦被拼进 note，就会把成功的在线核对误判成降级：\(DependencySnapshot.asOfText)")
        XCTAssertFalse(ManifestDependencyAnalyzer.offlineCaveat(for: offlineReport()).contains("失败"),
                       "离线判据同理：\(ManifestDependencyAnalyzer.offlineCaveat(for: offlineReport()))")
    }

    /// 三态判定的输入输出在加日期前后必须一模一样。
    func testEvidenceClassificationIsUnchangedByTheDisclosure() {
        var blind = DependencyReport()
        blind.ecosystems = offlineReport().ecosystems
        XCTAssertEqual(VulnerabilityEvidence.classify(blind), .unchecked, "没联网仍然是未核对")

        blind.networkLookupNote = DependencySnapshot.noteAppended(to: blind.networkLookupNote)
        XCTAssertEqual(VulnerabilityEvidence.classify(blind), .unchecked,
                       "给离线说明补日期不许改变证据状态：\(blind.networkLookupNote)")

        var checked = DependencyReport()
        checked.networkLookupPerformed = true
        XCTAssertEqual(VulnerabilityEvidence.classify(checked), .verified, "查过且干净仍然是已核对")

        var degraded = DependencyReport()
        degraded.networkLookupPerformed = true
        degraded.networkLookupNote = "OSV 查询失败 1 个包"
        XCTAssertEqual(VulnerabilityEvidence.classify(degraded), .degraded)
        XCTAssertEqual(VulnerabilityEvidence.classify(
            notePatched(degraded)
        ), .degraded, "降级说明补日期后必须还是降级")
    }

    /// 降级说明补句：空 note 不无中生有，非空 note 原句保留、只往后追加。
    func testNoteAppendKeepsTheOriginalSentenceAndSkipsEmptyNotes() {
        XCTAssertEqual(DependencySnapshot.noteAppended(to: ""), "",
                       "在线全部成功时不该凭空多出一句说明")
        let original = "OSV 查询超过 5 秒硬超时，本次在线漏洞结果整体放弃"
        let patched = DependencySnapshot.noteAppended(to: original)
        XCTAssertTrue(patched.hasPrefix(original), "原句必须一字不动：\(patched)")
        XCTAssertTrue(patched.contains("快照截至"), "补的必须是日期那一句：\(patched)")
        XCTAssertEqual(DependencySnapshot.noteAppended(to: patched), patched,
                       "重复补句会拼出两遍日期，说明文案越读越乱")
    }

    /// 端到端接线：默认离线跑一次真实分析，落到报告上的 note 必须自带快照日期。
    func testOfflineAnalyzeWritesSnapshotDateIntoTheReportNote() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ws-r-snapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"dependencies":{"left-pad":"1.3.0"}}"#.utf8)
            .write(to: root.appendingPathComponent("package.json"))

        let report = try await ManifestDependencyAnalyzer().analyze(projectRoot: root, allowNetwork: false)

        XCTAssertFalse(report.networkLookupPerformed, "默认离线，不得声称查过")
        XCTAssertTrue(report.networkLookupNote.contains("未联网核对"), report.networkLookupNote)
        XCTAssertTrue(report.networkLookupNote.contains(DependencySnapshot.asOfText),
                      "报告里的离线说明必须带上快照日期那一句：\(report.networkLookupNote)")
        XCTAssertFalse(report.networkLookupNote.contains("失败"),
                      "补进去的句子不许触发降级判据：\(report.networkLookupNote)")
    }

    // MARK: - 夹具

    private func notePatched(_ report: DependencyReport) -> DependencyReport {
        var copy = report
        copy.networkLookupNote = DependencySnapshot.noteAppended(to: copy.networkLookupNote)
        return copy
    }

    /// 一份典型的离线 npm 报告：一条可比对、一条 `workspace:*` 不可比对。
    private func offlineReport() -> DependencyReport {
        let records: [DependencyRecord] = [
            DependencyRecord(name: "lodash", version: "4.17.21", ecosystem: .npm, scope: .runtime,
                             manifestPath: "package.json", latestKnownVersion: nil,
                             versionCheckSource: .none, knownVulnerabilities: []),
            DependencyRecord(name: "@tcoder/local", version: "workspace:*", ecosystem: .npm,
                             scope: .unknown, manifestPath: "package.json",
                             latestKnownVersion: nil, versionCheckSource: .none,
                             knownVulnerabilities: []),
        ]
        var report = DependencyReport()
        report.ecosystems = [EcosystemReport(ecosystem: .npm, manifestPath: "package.json",
                                             lockfileName: nil, dependencies: records,
                                             frameworkMarkers: [])]
        return report
    }
}
