import Foundation
import XCTest
@testable import TcoderMonitor

// OWNER: WS-R31 GuardLedger（台账卷三 §62 · RD-64）
//
// # 这条助手解决的真事（不是重新证明缺陷存在，是给那条缺陷的第二条出口）
// 全量跑（`locked_build.sh test`，无 `--filter`）会**安静地丢掉一部分守卫的出声读数**：
// `ConflictMarkerGuardTests`、`BoardLengthReadoutRatchetTests`、`EvidenceFreshnessTests` 三家的
// 类在全量里执行并通过，可它们那几条 `print` 读数在全量日志里 grep 命中 0（机制未定位）。
// 后果：读日志的人只看得到「1702 例 / 0 失败」，看不到这些判据**这次到底量到了什么**——
// 那句「全量绿」不带任何测量证据。⇒ 把「只 print」的关键读数同时落一份到仓库内的文件台账，
// 并**写完立刻读回来断言相等**，让「这条判据这次真跑过」这件事不再依赖 stdout。
//
// # 口径边界（撞了就返工的那条）
// 被测头 sha **复用已有装配口** `CoverageSourceState.read(at:)`：它内部就是 `git rev-parse HEAD`
// 再走 `CommitIdentity.abbreviated`（与 ScanProvenance / 覆盖率那一路同一个提交号尺子）。
// 本助手**不另起一把缩短尺子、不自拼 rev-parse**——那正是 `CommitIdentityRulerTests` 拦的「两把尺子」。
// 产物目录：`${TCODER_SCRATCH:-<仓库根>/.scratch}`（AGENTS §1.6：一次性产物不进 `$TMPDIR`）。

/// 一个 Tests 侧的落账助手：把守卫的关键读数**一行一条、整行含被测头**写进 `.scratch/` 下的台账，
/// 写完立即读回、断言与写入逐字相等。写不进去 / 读不回 / 内容不对 ⇒ 当场红。
enum GuardLedger {

    /// 台账子目录：所有守卫的账都落在这里，汇总脚本按目录扫。
    static let ledgerSubdir = "guard-ledger"

    /// 台账文件后缀（不是 `.swift`，避免被任何源码扫描器当成代码收进分母）。
    static let ledgerSuffix = ".ledger"

    /// 仓库根：本助手与所有守卫同住在 `Tests/TcoderMonitorTests/` 下，从自身路径上溯三层即仓库根。
    /// 与 `EvidenceFreshnessTests.repoRoot`、`git rev-parse --show-toplevel` 同址（工作树里就是工作树根）。
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TcoderMonitorTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // TcoderMonitor
            .deletingLastPathComponent()   // 仓库根
    }

    /// `${TCODER_SCRATCH:-<仓库根>/.scratch}`：与 `perf_harness.sh` 那一行公共头同一口径。
    static var scratchDir: URL {
        if let override = ProcessInfo.processInfo.environment["TCODER_SCRATCH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return repoRoot.appendingPathComponent(".scratch")
    }

    /// 某守卫的台账文件路径（文件名带守卫名）。
    static func ledgerURL(guard name: String) -> URL {
        scratchDir.appendingPathComponent(ledgerSubdir)
            .appendingPathComponent("\(name)\(ledgerSuffix)")
    }

    /// 本进程里已经「开过账」的守卫：第一次落账**整份重写**（清掉上一趟跑的残迹），
    /// 之后同一守卫再落账是**追加**（一趟跑里多条读数都要在）。跨趟靠进程隔离自然归零。
    private static var reopened: Set<String> = []

    /// 落一条账 + 立刻读回断言相等。`readings` 是这次判据量到的读数原文（每条一行入账）。
    /// 任何一步不成立即 `XCTFail`（写不进去、读不回、内容不对、取不到被测头），当场红。
    static func record(guard name: String, readings: [String],
                       file: StaticString = #file, line: UInt = #line) {
        XCTAssertFalse(readings.isEmpty,
                       "守卫「\(name)」这次没有任何读数可落 ⇒ 第二条出口在空转", file: file, line: line)

        // 被测头：复用已有装配口，读不到就是读不到——**不许拿空串冒充「量过了」**。
        let source = CoverageSourceState.read(at: repoRoot)
        guard let head = source.headCommit, !head.isEmpty else {
            XCTFail("取不到被测头（\(source.readFailure ?? "未知原因")）⇒ 这条台账不带被测头，"
                    + "与缺陷本身同形（读数不带可复核性）", file: file, line: line)
            return
        }

        let url = ledgerURL(guard: name)
        let stamp = ISO8601DateFormatter().string(from: Date())
        let prior: String
        if reopened.contains(name), let existing = try? String(contentsOf: url, encoding: .utf8) {
            prior = existing
        } else {
            prior = ""    // 本进程首次落这一家：整份重写，清掉上一趟的残迹
        }
        reopened.insert(name)
        var content = prior
        for reading in readings {
            content += "\(stamp)\t\(head)\t\(name)\t\(reading)\n"
        }
        writeAndVerify(url: url, expected: content, guard: name, head: head,
                       readings: readings, file: file, line: line)
    }

    /// 落盘 + 立刻读回断言相等。拆出来是为了不把 `record` 顶过 `X3TestSizeAuditTests` 的 50 行函数线。
    private static func writeAndVerify(url: URL, expected: String, guard name: String, head: String,
                                       readings: [String], file: StaticString, line: UInt) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try expected.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            XCTFail("台账写不进去 \(url.path)：\(error.localizedDescription)", file: file, line: line)
            return
        }
        // 写完之后**立刻读回来**：读不回 / 少一行 / 内容被改动都当场红。
        // 这条「写回读等」断言就是「这条判据这次真跑过」的证据，不依赖 stdout。
        guard let readBack = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("台账写得出去却读不回来 \(url.path) ⇒ 第二条出口不可信", file: file, line: line)
            return
        }
        XCTAssertEqual(readBack, expected,
                       "台账「\(name)」写回读不等 ⇒ 落进去的不是这次量到的东西", file: file, line: line)
        for reading in readings {
            XCTAssertTrue(readBack.contains(reading),
                          "台账「\(name)」读回来之后少了这条读数：\(reading)", file: file, line: line)
            XCTAssertTrue(readBack.contains(head),
                          "台账「\(name)」整行必须含被测头 \(head)", file: file, line: line)
        }
    }
}
