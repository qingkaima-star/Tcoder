import XCTest
@testable import TcoderMonitor

/// WS-R 关闭 #25：内置快照的切数据日期 `DependencySnapshot.snapshotDate`
/// 此前**生产代码零消费**（只有 `DependencyAnalysisTests` 断言它是个合法日期），
/// 于是一天前的快照和一年前的快照在界面上长得一模一样——
/// 「未联网核对：漏洞判定只依据内置快照」这句话没有告诉用户那份快照是哪天的。
///
/// 本文件钉两件事：
/// ① 离线判据与「未核对」磁贴副标题必须带上**快照日期 + 距今时长**；
/// ② 这句话只是加信息，**不得动任何判定**。
///
/// ⚠ ②的写法在 2026-09-22 被 R3 整条改过（AGENTS §8.1 给的窄口径豁免，台账 §7.2 末行点名）：
/// 原来这里钉的是"note 里不许出现『失败』两个字，否则 `classify` 会把成功的在线核对读成降级"
/// —— 那句**本身就是**被删掉的文案判据（`networkLookupNote.contains("失败")`），
/// 于是每条中文都得先问它撞不撞词，方向是反的。
/// 现在钉的是同一件事的合法形状：**补句前后 `classify` 的三个状态一个都不许动**，
/// 而措辞含不含"失败"与状态**无关**（`testClassificationIsImmuneToWording`）。
/// 语义一条没丢：只是"凭什么不变"从措辞换成了账本。
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

    /// ## RD-13（2026-09-22，R3 按 AGENTS §8.1 豁免改正这两条用例）
    ///
    /// 这两条原来钉的是「措辞里不许出现『失败』，否则 `classify` 会把成功的在线核对读成降级」
    /// —— 那是**让中文文案给业务判定让路**：判据本身是 `networkLookupNote.contains("失败")`，
    /// 于是每加一句人话都得先问它会不会撞词。方向是反的，所以修法不是继续维护这套兼容，
    /// 而是把判定换成读结构化状态、再把这里改写成"判据对措辞**免疫**"。
    /// 语义一条没丢：补句仍然不许改变任何状态，只是现在它**凭什么**不改变换成了账本。
    func testClassificationIsImmuneToWording() {
        // 同一份账本，五种措辞（含"失败"、不含、纯英文、空、超长）都必须同一个状态。
        let base = onlineCheckedCleanReport()
        let wordings = ["", "OSV：52 个包中 3 个查询失败", "在线查询已完成（OSV + npm registry）",
                        "OSV lookup finished without failures", DependencySnapshot.asOfText,
                        "未联网核对：漏洞判定只依据内置快照（覆盖 npm / Maven / Python），"
                            + "快照截至 2026-09-19（很久以前）、很久以前、很久以前、很久以前"]
        for note in wordings {
            var report = base
            report.networkLookupNote = note
            report.networkLookupPerformed = !note.isEmpty
            XCTAssertEqual(VulnerabilityEvidence.classify(report), .verified,
                           "措辞影响了判定（RD-13 的原始症状）：\(note.prefix(24))")
        }
        // 快照那句本身含不含"失败"从此与判定无关 —— 但日期粒度那条纪律仍然成立。
        XCTAssertFalse(DependencySnapshot.asOfText.contains(":"), "整句披露不该带时分")
    }

    /// 三态判定的输入输出在补句前后必须一模一样（补句只加信息，不动判定）。
    func testEvidenceClassificationIsUnchangedByTheDisclosure() {
        var blind = offlineReport()
        XCTAssertEqual(VulnerabilityEvidence.classify(blind), .unchecked, "没联网仍然是未核对")
        blind.networkLookupNote = DependencySnapshot.noteAppended(to: blind.networkLookupNote)
        XCTAssertEqual(VulnerabilityEvidence.classify(blind), .unchecked,
                       "给离线说明补日期不许改变证据状态：\(blind.networkLookupNote)")

        // 「查过且干净」= 逐条漏洞核对全部成功，而不是 note 里没出现"失败"两个字。
        let checked = onlineCheckedCleanReport()
        XCTAssertEqual(VulnerabilityEvidence.classify(checked), .verified, "查过且干净仍然是已核对")
        XCTAssertEqual(VulnerabilityEvidence.classify(notePatched(checked)), .verified,
                       "补日期不许把已核对改成降级")

        // 「降级」= 发起了但没查完 —— 这里用**结构化事实**造，不再靠句子里有没有"失败"。
        var degraded = onlineCheckedCleanReport()
        degraded.ecosystems[0].dependencies[0].vulnerabilityCheckState = .failed
        XCTAssertEqual(VulnerabilityEvidence.classify(degraded), .degraded)
        XCTAssertEqual(VulnerabilityEvidence.classify(notePatched(degraded)), .degraded,
                       "降级说明补日期后必须还是降级")
        // 被单次上限挡在门外的那批同样是"试了没查完"，绝不是"压根没查"。
        var deferred = onlineCheckedCleanReport()
        deferred.ecosystems[0].dependencies[0].vulnerabilityCheckState = .budgetExcluded
        XCTAssertEqual(VulnerabilityEvidence.classify(deferred), .degraded)
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
        // 这一行原来钉的是「补进去的句子不许出现『失败』，否则触发降级判据」——
        // 那句判据（读中文里有没有"失败"）已随 RD-13 删除，约束本身换成**状态不许被措辞改动**：
        XCTAssertEqual(VulnerabilityEvidence.classify(report), .unchecked,
                       "离线一条都没核对成 ⇒ 只能是未核对")
        var withExtraWording = report
        withExtraWording.networkLookupNote += "；OSV：本次有包查询失败"
        XCTAssertEqual(VulnerabilityEvidence.classify(withExtraWording), .unchecked,
                       "措辞里出现「失败」也不再授权任何状态（这自由度是删掉文案判据之后才有的）："
                    + withExtraWording.networkLookupNote)
        XCTAssertEqual(VulnerabilityEvidence.classify(notePatched(report)),
                       VulnerabilityEvidence.classify(report), "补句（再追加一次日期）不许改状态")
    }

    // MARK: - 夹具

    private func notePatched(_ report: DependencyReport) -> DependencyReport {
        var copy = report
        copy.networkLookupNote = DependencySnapshot.noteAppended(to: copy.networkLookupNote)
        return copy
    }

    /// 一份"在线查过且全部零命中"的报告：逐条漏洞核对状态都落成 `.checked`。
    /// RD-13 之后这是**唯一**能让 `classify` 给出 `.verified` 的形状 —— 光把 note 写得
    /// 不含"失败"两个字不再算数（那正是被删掉的旧判据）。
    private func onlineCheckedCleanReport() -> DependencyReport {
        var report = offlineReport()
        for index in report.ecosystems[0].dependencies.indices {
            report.ecosystems[0].dependencies[index].vulnerabilityCheckState = .checked
        }
        report.networkLookupPerformed = true
        report.networkLookupNote = "在线查询已完成（OSV + npm registry）"
        return report
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
