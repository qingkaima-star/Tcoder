import XCTest
@testable import TcoderMonitor

/// OWNER: 总工程师（RD-53 同族：我自己的工具要说真话）—— 提交正文 ASCII 双引号自检尺子的守卫。
///
/// 为什么要给一支"提交前跑一下"的脚本再配一条测试：
/// AGENTS §1.5 让它成为纪律，但**纪律没有读者就会腐烂**（本仓反复处理过同一族：
/// 证据标记要有读者、有写无读的老 RD 家族）。我在 18:53 手工量过一次四向对照，
/// 那次读数不会自己重跑 ⇒ 判据一改就可能永真绿而无人知。
/// 抄的先例：`ProvenanceParityToleranceTests` 用真子进程跑 `scripts/report_parity.py` 钉方向。
///
/// 四个方向都必须有：真违规要报（且**行号列号指得到**）、反引号里的命令不许误伤、
/// 纯英文不许误伤、**空输入不许被读成「干净」**（产物为空也印 ✓ 是同族老毛病）。
final class CommitMsgQuoteCheckTests: XCTestCase {

    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // TcoderMonitorTests
        .deletingLastPathComponent()      // Tests
        .deletingLastPathComponent()      // TcoderMonitor
        .deletingLastPathComponent()      // 工作树根

    private var script: URL {
        Self.repoRoot.appendingPathComponent("TcoderMonitor/scripts/commit_msg_quote_check.py")
    }

    /// 用真子进程跑一遍（不是把判据在 Swift 里重写一份——那正好造出第二把尺子）。
    private func run(_ input: String) throws -> (status: Int32, output: String) {
        XCTAssertTrue(FileManager.default.fileExists(atPath: script.path),
                      "守卫的判据对象不见了：\(script.path)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, "-"]
        let inPipe = Pipe()
        let outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = outPipe
        try process.run()
        inPipe.fileHandleForWriting.write(Data(input.utf8))
        inPipe.fileHandleForWriting.closeFile()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(data: data, encoding: .utf8) ?? "")
    }

    func test_violationInChineseIsReportedWithLocation() throws {
        let result = try run("docs(x): 不再把合并报成\"已合入\"——这一枚该报\n")
        XCTAssertEqual(result.status, 1, "真违规没判败：\n" + result.output)
        XCTAssertTrue(result.output.contains(":1:"),
                      "没报行号 ⇒ 拿到红也无处下手：\(result.output)")
        XCTAssertTrue(result.output.contains("1 处"), result.output)
    }

    func test_commandInsideBackticksIsNotAFalsePositive() throws {
        let result = try run("用法：把 `--out=\"x\"` 这个参数写清楚，它紧挨中文但在反引号里\n")
        XCTAssertEqual(result.status, 0,
                      "反引号豁免坏了 ⇒ 以后没法在提交正文里引用任何带引号的命令：\n" + result.output)
    }

    func test_plainAsciiLineIsNotFlagged() throws {
        let result = try run("pure english line with \"quotes\" inside, should not be flagged\n")
        XCTAssertEqual(result.status, 0, result.output)
    }

    /// 空输入必须**出声**：一支在"没读到东西"时印 ✓ 的尺子，会把坏管道读成"提交正文干净"。
    func test_emptyInputRefusesToClaimClean() throws {
        let result = try run("   \n")
        XCTAssertEqual(result.status, 2, "空输入被读成干净 ⇒ 这条判据会给坏管道发假证：\n" + result.output)
        XCTAssertTrue(result.output.contains("读不到任何正文"), result.output)
    }

    /// 尺子必须有读者：纪律段里要点名它，否则它就是另一件"写了没人用"的工具。
    func test_scriptIsNamedWhereTheDisciplineLives() throws {
        let agents = Self.repoRoot.appendingPathComponent("TcoderMonitor/AGENTS.md")
        let text = try String(contentsOf: agents, encoding: .utf8)
        XCTAssertTrue(text.contains("commit_msg_quote_check.py"),
                      "AGENTS §1.5 不再点名这支尺子 ⇒ 提交纪律与工具脱钩了")
    }
}
