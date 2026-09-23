import XCTest
@testable import TcoderMonitor

/// 提交号那一把缩短尺子的守卫（R5c 收尾，整改意见 §十一「同一件事只许一个口径」）。
///
/// 立案缘由（不是假想，是 2026-09-22 实测抓到的分叉）：
/// Git 那一路存 `git rev-parse --short=7` 的 7 位，覆盖率那一路自己 `prefix(12)` 存 12 位，
/// 于是**同一份报告**里 Git 页写 `d9b4347`、覆盖率卡写「扫描时源码在 d9b43478f30c」，
/// 溯源块 `sourceCommit` 又跟着 Git 那一路走 7 位。
/// 对表用例 `CoverageChainProofTests.testCoverageFingerprintAndProvenanceCommitShareOneRuler`
/// 就是那次抓现场留下的，本文件钉的是它**不再长回第二把尺子**。
final class CommitIdentityRulerTests: XCTestCase {

    private func codeLinesOfSources() throws -> [URL: [String]] {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = packageRoot.appendingPathComponent("Sources")
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        let swiftFiles = (enumerator?.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? [])
        XCTAssertFalse(swiftFiles.isEmpty, "扫描面为空 —— 下面几条断言不作数")
        var result: [URL: [String]] = [:]
        for url in swiftFiles {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            // 只数代码行：讲这段历史的注释里出现了旧写法，剥注释才有牙。
            result[url] = text.components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        }
        XCTAssertFalse(result.isEmpty, "一个 Sources 文件都没读进来 ⇒ 这条守卫是永真绿")
        return result
    }

    // MARK: - 尺子本身

    func testAbbreviatedTakesFixedWidthOfAFullSHA() {
        let full = String(repeating: "a", count: 40)
        XCTAssertEqual(CommitIdentity.abbreviated(full).count, CommitIdentity.abbreviatedLength)
        XCTAssertEqual(CommitIdentity.abbreviated(full), String(repeating: "a", count: 12))
    }

    /// 已经短过的串再喂一次不许变短、也不许补长（两路各自缩短一步就会分叉）。
    func testAbbreviatingIsIdempotent() {
        let full = "d9b43478f30c1234567890abcdef01234567890"
        let once = CommitIdentity.abbreviated(full)
        XCTAssertEqual(CommitIdentity.abbreviated(once), once)
        XCTAssertEqual(CommitIdentity.abbreviated("abc1234"), "abc1234", "短于宽度时原样给出")
    }

    // MARK: - 不许长出第二把尺子

    func testCommitShorteningHasExactlyTwoCallSites() throws {
        let hits = try codeLinesOfSources().compactMap { url, lines -> (String, Int)? in
            let count = lines.filter { $0.contains("CommitIdentity.abbreviated(") }.count
            return count > 0 ? (url.lastPathComponent, count) : nil
        }
        let names = Set(hits.map(\.0))
        XCTAssertEqual(names, ["ShellGitPureHelpers.swift", "CoverageSourceBinding.swift"],
                       "缩短提交号的地方必须只有装配口与覆盖率那一路：\(hits)")
        XCTAssertGreaterThanOrEqual(hits.map(\.1).reduce(0, +), 2, "一处都没扫到 ⇒ 扫描面坏了，不算通过")
    }

    /// 旧写法不许回来：让 git 替我们缩短（`--short=7`）就是分叉的另一半。
    func testGitIsNeverAskedToShortenTheHeadHash() throws {
        let offenders = try codeLinesOfSources().flatMap { url, lines -> [String] in
            lines.filter { $0.contains("--short") }.map { "\(url.lastPathComponent): \($0.trimmingCharacters(in: .whitespaces))" }
        }
        XCTAssertEqual(offenders, [], "git 只许给全长，缩短由 CommitIdentity 做：\n\(offenders.joined(separator: "\n"))")
    }
}
