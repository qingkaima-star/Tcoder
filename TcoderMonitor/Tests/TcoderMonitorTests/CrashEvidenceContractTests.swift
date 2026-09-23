import XCTest
@testable import TcoderMonitor

/// 总工落 `LogSummary.crashEvidence` 那一格时自带的守卫（AGENTS §3：冻结区 additive 必须自带守卫）。
///
/// 只钉两件本层能钉的事：**旧报告不能因为这一格而解不开**，以及**逐字段往返不丢值**。
/// 「谁写谁读」「屏上那句逐字来自装配口」由 R24 接完写者/读者之后在同一文件里补
/// ——在那之前这一格是**有契约没读者**的状态，台账 §52 明写着，不许被当成已完成。
final class CrashEvidenceContractTests: XCTestCase {

    /// 反例（最重要的一条）：把整键删掉，旧 JSON 必须照常解码，且这一格读成 `nil`。
    /// 非 Optional（哪怕带默认值）会让**整份**用户报告 `try?` 失败 ⇒ 静默丢档。
    func testReportWithoutTheCrashEvidenceKeyStillDecodesAsNil() throws {
        let json = try JSONSerialization.data(withJSONObject: [
            "errorCount": 3, "crashCount": 1, "totalLinesScanned": 42,
        ])
        let summary = try JSONDecoder().decode(LogSummary.self, from: json)
        XCTAssertNil(summary.crashEvidence, "这一格缺席必须读成「没统计」，不是零值")
        XCTAssertEqual(summary.crashCount, 1, "旧报告其余字段不许被牵连")
    }

    /// 正例：九格逐字段往返，值原样回来（装配口将来按名字接回，任何一格被吞都算违约）。
    func testSnapshotRoundTripKeepsEveryField() throws {
        let snapshot = CrashEvidenceSnapshot(
            countedCrashCount: 2, historicalConfirmedCount: 1, staleBuildConfirmedCount: 3,
            undatedConfirmedCount: 4, suspectedCount: 5, parseFailedCount: 6,
            readFailedCount: 7, duplicateCount: 8, filesWithCountedEvidence: 9)
        var summary = LogSummary()
        summary.crashEvidence = snapshot
        let decoded = try JSONDecoder().decode(LogSummary.self, from: JSONEncoder().encode(summary))
        XCTAssertEqual(decoded.crashEvidence, snapshot)
    }

    /// 三态线：整枚快照在场、但某一格缺席 ⇒ 那一格必须是 `nil`，
    /// 不许被解成 0（0 是"查过了、真的是 0"，两种话不一样）。
    func testAbsentSlotInsideTheSnapshotStaysNilNotZero() throws {
        let partial = CrashEvidenceSnapshot(countedCrashCount: 1, historicalConfirmedCount: nil,
                                            staleBuildConfirmedCount: nil, undatedConfirmedCount: nil,
                                            suspectedCount: nil, parseFailedCount: nil,
                                            readFailedCount: nil, duplicateCount: nil,
                                            filesWithCountedEvidence: nil)
        let decoded = try JSONDecoder().decode(CrashEvidenceSnapshot.self,
                                               from: JSONEncoder().encode(partial))
        XCTAssertEqual(decoded, partial)
        XCTAssertNil(decoded.historicalConfirmedCount, "缺席被补成 0 ⇒ 把「没数」说成「没有」")
        XCTAssertEqual(decoded.countedCrashCount, 1)
    }

    /// 这一格的键名也必须缺席（而不是写出 `null`）—— 与 `encodeIfPresent` 的整键缺席口径一致。
    func testEncodingOmitsTheWholeKeyWhenAbsent() throws {
        let data = try JSONEncoder().encode(LogSummary())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertFalse(object.keys.contains("crashEvidence"),
                       "没统计过时整键必须缺席；写出 null 会让读 JSON 的人分不出「没跑」与「跑了没结果」")
    }
}
