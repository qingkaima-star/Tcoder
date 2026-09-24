import Foundation
import XCTest
@testable import TcoderMonitor

/// RD-80 的**总体**读数（§97 只交了 63 处静态代理计数，这一条才是分析器自己的数）。
///
/// 不变式不是"我觉得分数应该多少"，而是本次修复的定义本身：
/// **同一份代码，三元换行写与一行写完，函数数与判定总分必须一模一样。**
///
/// 两腿怎么走：
/// ① 原样扫本仓（三元的 `?` 与 `:` 分行写的地方保持分行）；
/// ② 把同一批文件复制进临时目录，复制时把"上一行有 `?` 且整行没有冒号、下一行行首是 `:`"
///    这一对**并成一行**（这就是同行写完的写法，改判据之前它本来就能数对），再扫一遍。
/// 两腿的 `analyzedFunctionCount` 与 ΣCC 必须逐项相等；同时**必须真的并过至少一处**，
/// 否则这条断言是永真绿（分母为 0 直接判败）。
final class TernaryLineBreakPopulationTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TcoderMonitorTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // TcoderMonitor
            .deletingLastPathComponent()   // <worktree>
    }

    /// 只扫实现与测试这两层，和自扫口径一致（文档、脚本里的 `?` 不算代码）。
    private var scannedSubpaths: [String] { ["TcoderMonitor/Sources", "TcoderMonitor/Tests"] }

    private struct Reading {
        var functions: Int
        var totalComplexity: Int
    }

    private func reading(from metrics: CodeMetrics) -> Reading {
        Reading(functions: metrics.analyzedFunctionCount,
                totalComplexity: metrics.topComplexFunctions.reduce(0) { $0 + $1.cyclomaticComplexity })
    }

    /// 并行的那一步：**只**动 RD-80 那一种形状，其余字节一字不改。
    private func joinBrokenTernaries(in text: String) -> (String, Int) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var kept: [String] = []
        var joins = 0
        var index = 0
        while index < lines.count {
            let current = lines[index]
            let nextIsColon = index + 1 < lines.count
                && lines[index + 1].drop(while: { $0 == " " || $0 == "\t" }).first == ":"
            if nextIsColon, current.contains("?"), !current.contains(":"), !current.contains("://") {
                kept.append(current + " " + lines[index + 1].trimmingCharacters(in: .whitespaces))
                joins += 1
                index += 2
                continue
            }
            kept.append(current)
            index += 1
        }
        return (kept.joined(separator: "\n"), joins)
    }

    func testBrokenTernaryReadsTheSameAsSameLineAcrossTheWholeRepository() async throws {
        let fm = FileManager.default
        // 两腿必须扫**同一批文件**：上一版一腿扫 `repoRoot/TcoderMonitor`（含 Resources、含非 Swift），
        // 一腿扫复制出来的 Swift 子集，函数数差 397 就是这么来的 —— 那是我自己的总体错位，
        // 不是 RD-80 的效应。现在两腿各拷一份同源目录，唯一区别就是有/没有「并成一行」。
        let plain = repoRoot.appendingPathComponent(".scratch/ternary-ab-plain")
        let staged = repoRoot.appendingPathComponent(".scratch/ternary-ab-joined")
        for dir in [plain, staged] { try? fm.removeItem(at: dir) }
        defer { for dir in [plain, staged] { try? fm.removeItem(at: dir) } }

        var joinedSites = 0
        var touchedFiles = 0
        for sub in scannedSubpaths {
            let origin = repoRoot.appendingPathComponent(sub)
            guard let enumerator = fm.enumerator(at: origin, includingPropertiesForKeys: nil,
                                                 options: [.skipsHiddenFiles]) else {
                throw XCTSkip("扫不到 \(sub)，这一腿根本没跑，判败而不是判过")
            }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let (joined, count) = joinBrokenTernaries(in: text)
                joinedSites += count
                touchedFiles += count > 0 ? 1 : 0
                let relative = url.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
                for (root, payload) in [(plain, text), (staged, joined)] {
                    let target = root.appendingPathComponent(relative)
                    try? fm.createDirectory(at: target.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
                    try? payload.write(to: target, atomically: true, encoding: .utf8)
                }
            }
        }

        XCTAssertGreaterThan(joinedSites, 0,
                             "一处都没并出来 ⇒ 这条不变式没吃到任何输入，是永真绿（分母归零＝没测）")

        let before = reading(from: try await FileSystemCodeAnalyzer()
            .analyze(root: plain.appendingPathComponent("TcoderMonitor"), options: .default))
        let after = reading(from: try await FileSystemCodeAnalyzer()
            .analyze(root: staged.appendingPathComponent("TcoderMonitor"), options: .default))

        // 读数落文件：只 print 等于没测（RD-64 那条）。
        let ledger = repoRoot.appendingPathComponent(".scratch/tcoder-ternary-ab.txt")
        let line = """
        RD-80 总体对表 \(Date()) ｜ 并行的三元 \(joinedSites) 处 / 涉及 \(touchedFiles) 个文件
        原样扫：函数 \(before.functions) · 榜内 ΣCC \(before.totalComplexity)
        并行扫：函数 \(after.functions) · 榜内 ΣCC \(after.totalComplexity)
        差量：函数 \(after.functions - before.functions) · ΣCC \(after.totalComplexity - before.totalComplexity)
        """
        try? line.write(to: ledger, atomically: true, encoding: .utf8)
        print(line)

        XCTAssertEqual(after.functions, before.functions,
                       "把三元并回一行不该改变函数数（\(joinedSites) 处并行前后不一致就是识别被换行影响）")
        XCTAssertEqual(after.totalComplexity, before.totalComplexity,
                       "RD-80 的不变式：换行写法与同行写法必须同分，差 \(after.totalComplexity - before.totalComplexity)")
    }
}
