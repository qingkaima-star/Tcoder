//
//  #26：读取失败必须带着原因到场
//
//  WS-R 把读失败的文件从 `scannedFiles` 里剔掉，挡住了「权限不足换一张 all-clear」；
//  本文件钉的是这件事的后半段：被剔掉的每一份要能报出**数量与原因**，
//  并且两个新契约字段都必须是 Optional —— 这条不是风格偏好，是用第 6、7 例
//  实测出来的（Swift 合成的 `Codable` 不会为缺失的 key 套用属性默认值）。
//
import XCTest
@testable import TcoderMonitor

final class LogReadFailureTests: XCTestCase {

    private var tempRoot: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        tempRoot = fm.temporaryDirectory
            .appendingPathComponent("ws-c-readfail-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // 夹具只用本会话在 /tmp 下自己建的目录，验完删。
        try? fm.removeItem(at: tempRoot)
    }

    @discardableResult
    private func write(_ text: String, named name: String, unreadable: Bool = false) throws -> URL {
        let url = tempRoot.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        if unreadable { try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path) }
        return url
    }

    private func discovered(_ url: URL) throws -> DiscoveredLog {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        return DiscoveredLog(url: url, role: .application, sizeBytes: Int64(size), modifiedAt: Date())
    }

    private func read(_ url: URL) throws -> LogFileReading {
        LogReader.read(try discovered(url), maxBytes: 2_000_000, maxLines: 5_000)
    }

    // MARK: - 1. 原因翻译

    func testPermissionAndMissingFileErrorsGetTheirOwnShortReason() {
        XCTAssertEqual(LogReader.readFailureReason(for: posixError(EACCES)), "权限不足")
        XCTAssertEqual(LogReader.readFailureReason(for: posixError(EPERM)), "权限不足")
        XCTAssertEqual(LogReader.readFailureReason(for: cocoaError(.fileNoSuchFile)), "文件已不存在")
        XCTAssertEqual(LogReader.readFailureReason(for: cocoaError(.fileReadNoSuchFile)), "文件已不存在")
        XCTAssertEqual(LogReader.readFailureReason(for: cocoaError(.fileReadNoPermission)), "权限不足")
    }

    /// 权限失败的 errno 藏在 `NSUnderlyingError` 里：外层是 Cocoa 513，既不在 POSIX 域、
    /// 也不是 257。不往下走一层就会掉进兜底文案——这是本机编译产物探针实测出来的形状。
    func testPermissionReasonIsFoundInsideTheWrappedUnderlyingError() {
        let outer = NSError(domain: NSCocoaErrorDomain, code: 513, userInfo: [
            NSUnderlyingErrorKey: posixError(EACCES),
        ])
        XCTAssertEqual(LogReader.readFailureReason(for: outer), "权限不足",
                       "实得 \(LogReader.readFailureReason(for: outer))")
        let unrelated = NSError(domain: NSCocoaErrorDomain, code: 513, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSCocoaErrorDomain, code: 999),
        ])
        XCTAssertTrue(LogReader.readFailureReason(for: unrelated).hasPrefix("无法读取（"),
                      "链上找不到已知成因时才允许用系统描述兜底")
    }

    func testUnrecognizedErrorKeepsSystemDescriptionNotAGenericWord() {
        let reason = LogReader.readFailureReason(for: cocoaError(.fileReadCorruptFile))
        XCTAssertFalse(reason.isEmpty, "空原因等于 UI 上什么也说不了")
        XCTAssertNotEqual(reason, "读取失败",
                          "一律兜成「读取失败」会把可修的（权限）与不可修的混成同一句话")
        XCTAssertTrue(reason.hasPrefix("无法读取（") && reason.hasSuffix("）"),
                      "未知成因必须带上系统描述，实得 \(reason)")
    }

    private func posixError(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    private func cocoaError(_ code: CocoaError.Code) -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: code.rawValue)
    }

    // MARK: - 2. 真读不动的文件：失败 + 原因，且不含猜测

    func testUnreadableFileIsReportedAsFailedWithItsReason() throws {
        let url = try write("ERROR boom\n", named: "locked.log", unreadable: true)
        let reading = try read(url)
        XCTAssertTrue(reading.readFailed, "打不开的文件必须算读取失败，不能算核对过")
        XCTAssertEqual(reading.readFailure, "权限不足",
                       "原因必须是真原因，实得 \(reading.readFailure ?? "nil")")
    }

    // MARK: - 3. 反向保护：别把「本来就是空的」和「没有换行尾」也算成失败

    func testReadableEmptyFileIsVerifiedZeroHitNotAFailure() throws {
        let reading = try read(write("", named: "empty.log"))
        XCTAssertFalse(reading.readFailed,
                       "0 字节且读成功的文件是「已核对、零命中」，不是没核对")
        XCTAssertNil(reading.readFailure)
    }

    func testLastLineWithoutTrailingNewlineIsStillRead() throws {
        let reading = try read(write("ERROR 最后一行没有换行符", named: "no-newline.log"))
        XCTAssertFalse(reading.readFailed, "无结尾换行的尾行必须照读，否则会被误判成读取失败")
        XCTAssertEqual(reading.totalLines, 1, "实得 \(reading.totalLines) 行")
        XCTAssertNil(reading.readFailure)
    }

    // MARK: - 4. 契约兼容：两个新字段为什么必须 Optional（实测，不是援引）

    /// 旧报告（升级前的构建真写到磁盘上的那种形状：两个新 key 根本不存在）必须照样解得开。
    /// 载荷是**编码后再抠掉新 key** 得到的，不是手写 JSON——手写会漏掉必填的
    /// `exceptionCount` 之类，那测的就不是本字段而是 `LogSummary` 的整体形状了。
    func testPersistedReportWithoutTheNewKeysStillDecodes() throws {
        var summary = LogSummary()
        summary.totalLinesScanned = 120
        summary.errorCount = 3
        summary.scannedFiles = [ScannedLogFile(path: "Logs/a.log", sizeBytes: 10, lineCount: 2,
                                               modifiedAt: Date(timeIntervalSince1970: 0), role: .application)]

        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(summary))
            as? [String: Any]
        guard var files = object?["scannedFiles"] as? [[String: Any]] else {
            return XCTFail("编码结果里没有 scannedFiles 数组，测试前提变了")
        }
        for index in files.indices { files[index].removeValue(forKey: "readFailure") }
        object?["scannedFiles"] = files
        object?.removeValue(forKey: "readFailedFiles")
        let legacyData = try JSONSerialization.data(withJSONObject: object!)

        let decoded = try JSONDecoder().decode(LogSummary.self, from: legacyData)
        XCTAssertEqual(decoded.scannedFiles.count, 1)
        XCTAssertNil(decoded.scannedFiles.first?.readFailure, "缺 key 必须解成 nil 而不是抛错")
        XCTAssertNil(decoded.readFailedFiles)
        XCTAssertEqual(decoded.errorCount, 3, "兼容旧报告不能以丢数据为代价")
        XCTAssertTrue(decoded.hasData)
    }

    /// 反向：新字段写得出去也读得回来，否则 UI 重新加载项目时「已跳过 N 份」会凭空消失。
    func testFailureLedgerSurvivesThePersistenceRoundTrip() throws {
        var summary = LogSummary()
        summary.totalLinesScanned = 10
        summary.readFailedFiles = [
            ScannedLogFile(path: "Logs/locked.log", sizeBytes: 10, lineCount: 0,
                           modifiedAt: Date(timeIntervalSince1970: 0), role: .error,
                           readFailure: "权限不足"),
        ]
        let decoded = try JSONDecoder().decode(LogSummary.self, from: JSONEncoder().encode(summary))
        XCTAssertEqual(decoded.readFailedFiles?.count, 1)
        XCTAssertEqual(decoded.readFailedFiles?.first?.readFailure, "权限不足")
        XCTAssertEqual(decoded.readFailedFiles?.first?.role, .error)
    }

    /// 反面对照：**同样形状**下非可选字段就是会抛 `keyNotFound`。
    /// 这条存在是为了让「必须 Optional」这个要求可被复查，而不是靠引用某人的结论。
    func testNonOptionalNewFieldWouldHaveSilentlyDroppedTheWholeReport() {
        struct WithRequiredField: Codable { var present: Int = 0; var addedLater: Int = 7 }
        XCTAssertThrowsError(
            try JSONDecoder().decode(WithRequiredField.self, from: Data(#"{"present":1}"#.utf8)),
            "如果合成 Codable 真会套用属性默认值，那 Optional 就不是硬要求，本测试应当通过"
        ) { error in
            guard let key = (error as? DecodingError)?.isKeyNotFound else {
                return XCTFail("期望 keyNotFound，实得 \(error)")
            }
            XCTAssertEqual(key, "addedLater")
        }
        // 而 try? 会把这个抛错咽成 nil —— 这就是「整份历史报告静默丢失」的机制。
        XCTAssertNil(try? JSONDecoder().decode(WithRequiredField.self, from: Data(#"{"present":1}"#.utf8)))
    }

    // MARK: - 5. 端到端：份数与原因要能走到 UI

    func testAnalyzerPutsFailedFilesInTheirOwnLedgerAndKeepsVerifiedOnes() async throws {
        let good = try write("ERROR 一条真错误\n", named: "good.log")
        let bad = try write("ERROR 读不到\n", named: "bad.log", unreadable: true)

        let summary = try await FileLogAnalyzer().analyze(projectRoot: tempRoot,
                                                      extraLogURLs: [good, bad], withinDays: 30)
        XCTAssertEqual(summary.scannedFiles.count, 1, "读成功的才进已扫描：\(summary.scannedFiles.map(\.path))")
        XCTAssertTrue(summary.scannedFiles.allSatisfy { $0.readFailure == nil },
                      "已扫描的那一份不该带失败原因")
        XCTAssertEqual(summary.readFailedFiles?.count, 1, "被跳过的一份必须单独在场")
        XCTAssertEqual(summary.readFailedFiles?.first?.readFailure, "权限不足")
        XCTAssertTrue(summary.hasData, "有一份核对成功，整体就该算有数据")
    }

    func testAllUnreadableLeavesNoDataInsteadOfAnAllClear() async throws {
        let bad = try write("ERROR 读不到\n", named: "only-bad.log", unreadable: true)
        let summary = try await FileLogAnalyzer().analyze(projectRoot: tempRoot,
                                                      extraLogURLs: [bad], withinDays: 30)
        XCTAssertTrue(summary.scannedFiles.isEmpty, "读不动的文件不得回流到已扫描")
        XCTAssertEqual(summary.readFailedFiles?.count, 1)
        XCTAssertFalse(summary.hasData,
                       "全读不动就是没数据；这里给 true 等于把 0 份核对说成核对过了")
    }
}

private extension DecodingError {
    /// 只关心「哪个 key 缺失」，用于上面的反面对照。
    var isKeyNotFound: String? {
        guard case let .keyNotFound(codingKey, _) = self else { return nil }
        return codingKey.stringValue
    }
}
