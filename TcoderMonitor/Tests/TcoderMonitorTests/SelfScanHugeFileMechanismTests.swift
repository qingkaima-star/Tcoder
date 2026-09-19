import XCTest
@testable import TcoderMonitor

/// OWNER: WS-J 自食其果（dogfooding）。文件名以 `SelfScan` 开头，仍归 WS-J 的口径。
///
/// 目的：给 800 行这道闸门补上**机制测试**——不问「仓库现在有没有超长文件」，
/// 只问「工具有没有能力看见超长文件」。
///
/// 为什么单独一个文件：`SelfScanDogfoodTests` 里原先那条
/// `XCTAssertFalse(over.isEmpty, "本仓库有 800 行以上的 Swift 文件是既定事实")`
/// 把「还有债」当成了工具正常的必要条件，债还清即误报故障（WS-V 拆分当天踩中）。
/// 非空断言已换成双向一致性，而「失明」这件事必须由与仓库状态无关的合成夹具来验：
/// 造一个确定 850 行的 `.swift`，报不出来就是瞎了；将来谁把阈值抬到 900、
/// 或让扫描器漏掉某类文件，这条都会立刻变红——而它不依赖仓库里恰好有个烂文件。
///
/// 两个点一起钉死阈值边界：850 行必须算超限，500 行必须不算
/// （500 仍 >400，所以它照样进 hugeFiles，只是不该被当成 800+）。
final class SelfScanHugeFileMechanismTests: XCTestCase {

    /// 高于闸门一个可辨识的量：越过 `highFileLines`(800)，但远不到 `criticalFileLines`(1500)。
    private static let overBarLines = 850
    /// 低于闸门、但高于 `mediumFileLines`(400)：证明「进 hugeFiles」与「算 800+」是两件事。
    private static let underBarLines = 500

    func testSyntheticFileOverTheBarIsSeenWhileUnderBarIsNot() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tcoder-selfscan-mech-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // 闭包里现取 FileManager，别把 non-Sendable 的 `fm` 捕获进 @Sendable 的 teardown。
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        // 逐行真写，不用 String(repeating:)：行数必须由「实际落盘的换行」决定，
        // 否则我钉的就是自己拼出来的字符串长度，而不是工具数出来的东西。
        func makeFile(_ name: String, lines: Int) throws -> (URL, Int) {
            let body = (1...lines).map { "let wsvMechanism\($0) = \($0)" }.joined(separator: "\n")
            let url = dir.appendingPathComponent(name)
            try (body + "\n").write(to: url, atomically: true, encoding: .utf8)
            return (url, body.components(separatedBy: "\n").count)
        }

        let (giant, giantLines) = try makeFile("GiantOverBar.swift", lines: Self.overBarLines)
        let (small, _) = try makeFile("MediumUnderBar.swift", lines: Self.underBarLines)

        // 路径必须先归一：NSTemporaryDirectory() 给 `/var/folders/…`，而扫描器回的是
        // 解析过软链的 `/private/var/folders/…`——同一份东西，直接 == 会永远不相等。
        // （LogAnalysisTests 的 isUnder 早就踩过同一个坑，注释写在那里。）
        func canon(_ path: String) -> String {
            URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        }

        let metrics = try await FileSystemCodeAnalyzer().analyze(root: dir, options: .default)
        let reported = Set(metrics.hugeFiles.map { canon($0.path) })
        let claimedOverBar = metrics.hugeFiles.filter { $0.lineCount > FileSystemCodeAnalyzer.highFileLines }

        // 机制必须活着：850 行的合成夹具一定被看见。
        XCTAssertTrue(reported.contains(canon(giant.path)),
                      "工具看不见 \(giantLines) 行的合成超限文件，等于自我失明。hugeFiles=\(metrics.hugeFiles.map(\.path))")
        let hotspot = try XCTUnwrap(metrics.hugeFiles.first { canon($0.path) == canon(giant.path) },
                                    "hugeFiles 里没有那个 850 行的夹具")
        XCTAssertEqual(hotspot.lineCount, giantLines,
                       "工具数出的行数与独立复检不符（换行口径漂移）")
        XCTAssertEqual(hotspot.risk, .medium,
                       ">800 行应判 .medium（criticalFileLines=\(FileSystemCodeAnalyzer.criticalFileLines) 才升 .high）")

        // 边界不许糊：500 行进了榜，但不能被冒充成 800+。
        XCTAssertTrue(reported.contains(canon(small.path)),
                      "500 行 > mediumFileLines(\(FileSystemCodeAnalyzer.mediumFileLines))，本该进 hugeFiles")
        XCTAssertNil(metrics.hugeFiles.first { canon($0.path) == canon(small.path) && $0.lineCount > FileSystemCodeAnalyzer.highFileLines },
                     "500 行的文件被当成 800+ 行，阈值失效")
        XCTAssertEqual(claimedOverBar.map { canon($0.path) }, [canon(giant.path)],
                       "自称超限的文件必须恰好只有那一个 850 行夹具")

        print("【机制测试】合成超限夹具 \(giantLines) 行 → 工具报 hugeFiles \(metrics.hugeFiles.count) 个、"
            + "自称 >\(FileSystemCodeAnalyzer.highFileLines) 行 \(claimedOverBar.count) 个；"
            + "仓库有没有真债不影响这条的结论")
    }
}
