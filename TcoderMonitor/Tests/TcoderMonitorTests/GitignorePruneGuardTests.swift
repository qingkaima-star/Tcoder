import Foundation
import XCTest
@testable import TcoderMonitor

// MARK: - 仓库遍历剪枝与 .gitignore 必须同步
//
// OWNER: 总工程师（批次 P6-D 收尾时立的规矩）
//
// 为什么单独一条守卫：2026-09-21 一天内连踩两次同一件事。
// ① 我把取证沙箱写进 `.inflight/`，自扫把它算成"仓库新增一个超 800 行的巨大文件"，
//    三条无关测试一起判红；② 另一条流把落点规矩改成 `.scratch/` 并写进 AGENTS §1.6，
//    但**三处仓库遍历的剪枝表一处都不知道它** —— 下一个用默认路径取证的人必然重演①。
// 根因不是"忘了加某一行"，是**清单有两处真相**：`.gitignore` 说"这是产物目录"，
// 而守卫各自另抄一份"哪些目录不走进来"。所以这次不只把两处对齐，
// 而是让这条守卫去读 `.gitignore` 本体：新增产物目录时，忘了改剪枝表就直接判红。

final class GitignorePruneGuardTests: XCTestCase {

    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // TcoderMonitorTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // TcoderMonitor（包根）
        .deletingLastPathComponent()   // 工作树根

    /// `.gitignore` 里以 `/` 结尾的行 = 明确声明为**目录**的条目。
    /// 不收 `*.o` / `Package.resolved` 这类文件条目：它们不会让目录遍历走错地方。
    ///
    /// 取**最后一段路径**：三把尺子的剪枝都是拿 `url.lastPathComponent` 比对的，
    /// 而 `.gitignore` 允许写 `TcoderMonitor/coverage/` 这种带前缀的形式 ——
    /// 不折算就会拿 "TcoderMonitor/coverage" 去比一个名叫 "coverage" 的目录，永远比不中。
    static func ignoredDirectoryNames(from gitignore: String) -> Set<String> {
        var names: Set<String> = []
        for raw in gitignore.split(separator: "\n") {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            guard line.hasSuffix("/"), !line.hasPrefix("!"), !line.contains("*") else { continue }
            let path = String(line.dropLast())
            // `split` 对空串返回空数组，`last` 会是 nil —— 显式兜住，别让整条守卫崩掉。
            if let leaf = path.split(separator: "/").last { names.insert(String(leaf)) }
        }
        return names
    }

    /// 反向自证：解析器读不到东西时，上面那条断言会永真绿。
    func test_parserActuallyReadsTheIgnoreFile() throws {
        let text = try readGitignore()
        let names = Self.ignoredDirectoryNames(from: text)
        XCTAssertGreaterThanOrEqual(names.count, 4,
                                    "只解析出 \(names.count) 个目录条目：\(names)。口径或文件位置不对，这条守卫在空转")
        XCTAssertTrue(names.contains(".build") && names.contains("dist"),
                      "解析结果连构建产物目录都没有，判据形状可疑：\(names)")
        // 文件条目不许混进来。
        XCTAssertFalse(names.contains("Package.resolved"), "无斜杠的文件条目不该算目录")
    }

    func test_everyIgnoredDirectoryIsPrunedByRepoWalks() throws {
        let names = Self.ignoredDirectoryNames(from: try readGitignore())
        let pruned = SelfScanHarnessCase.skipDirectoryNames
        let missing = names.subtracting(pruned).sorted()
        XCTAssertTrue(missing.isEmpty,
                      """
                      `.gitignore` 声明了这些产物目录，但仓库遍历不剪它们：\(missing)。
                      后果不是脏，是**门禁结果取决于这一刻有没有人留着取证产物**：
                      一份沙箱里的 reports/*.json 会被算成"仓库新增一个巨大文件"。
                      往 `SelfScanHarnessCase.skipDirectoryNames` 补一行即可（那是唯一来源，
                      可达性普查与文档引用棘轮都引用它）。
                      """)
    }

    /// 三把尺子必须量同一棵树 —— 现在靠"只有一个来源"成立，这条守住它没被改回三份。
    func test_repoWalksShareOnePruneList() {
        XCTAssertEqual(SourceFileReachabilityTests.prunedDirectories,
                       SelfScanHarnessCase.skipDirectoryNames,
                       "可达性普查又抄了一份剪枝表：两把尺子量的树不一样时，一边绿一边红无法归因")
        XCTAssertEqual(DocReferenceRatchetTests.prunedDirectories,
                       SelfScanHarnessCase.skipDirectoryNames,
                       "文档引用棘轮又抄了一份剪枝表，同上")
    }

    private func readGitignore() throws -> String {
        let url = Self.repoRoot.appendingPathComponent(".gitignore")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.isEmpty, ".gitignore 是空的，这条守卫在空转")
        return text
    }
}
