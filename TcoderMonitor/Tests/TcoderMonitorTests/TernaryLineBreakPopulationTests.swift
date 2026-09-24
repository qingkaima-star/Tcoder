import Foundation
import XCTest
@testable import TcoderMonitor

/// RD-80 的**总体**读数（§97 只交了 63 处静态代理计数，这一条才是分析器自己的数）。
///
/// 不变式不是"我觉得分数应该多少"，而是本次修复的定义本身：
/// **同一批代码，三元换行写与一行写完，函数数与判定总分必须一模一样。**
///
/// 两腿怎么走：把 `Sources`+`Tests` 的 Swift 同源拷进 `.scratch` 下两个目录，
/// 唯一区别是一腿把"上一行有 `?` 且整行没有冒号、下一行行首是 `:`"这一对**并成一行**
/// （改判据之前，只有并起来的这一种写法数得对）。两腿各扫一次，逐项相等才算通过；
/// 并且**必须真的并过至少一处**，否则这条断言是永真绿 ⇒ 分母归零直接判败。
///
/// ⚠ 第一版这条设计是错的，错法值得留着：一腿扫 `repoRoot/TcoderMonitor`（含 `Resources`
/// 与非 Swift），一腿扫只拷出来的 Swift 子集，读出「函数 −397」——那是**我自己的总体错位**，
/// 不是 RD-80 的效应。两腿必须同源同批。
///
/// 长度与复杂度也走过一遍正规门：第一版把两腿、拷贝、断言、落盘全塞进一个 51 行 / CC 16
/// 的函数里，被 `X3TestSizeAuditTests` 两条线一起判红（它说的就是我）。拆成
/// `stageTwoCopies` / `joinBrokenTernaries` / `write` / `scan` 之后每条都在口径内。
final class TernaryLineBreakPopulationTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TcoderMonitorTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // TcoderMonitor
            .deletingLastPathComponent()   // <worktree>
    }

    /// 只抄实现与测试这两层，和分析器自扫的口径一致（文档、脚本里的 `?` 不算代码）。
    private var scannedSubpaths: [String] { ["TcoderMonitor/Sources", "TcoderMonitor/Tests"] }

    private struct Reading {
        var functions: Int
        var totalComplexity: Int
    }

    private struct Staged {
        var plain: URL
        var joined: URL
        var sites: Int
        var files: Int
    }

    private func scan(_ root: URL) async throws -> Reading {
        let metrics = try await FileSystemCodeAnalyzer().analyze(root: root, options: .default)
        return Reading(functions: metrics.analyzedFunctionCount,
                       totalComplexity: metrics.topComplexFunctions.reduce(0) { $0 + $1.cyclomaticComplexity })
    }

    /// 同一批 `.swift` 拷两份：一份原样，一份把断行的三元并成一行。
    private func stageTwoCopies() throws -> Staged {
        let fm = FileManager.default
        let plain = repoRoot.appendingPathComponent(".scratch/ternary-ab-plain")
        let joinedRoot = repoRoot.appendingPathComponent(".scratch/ternary-ab-joined")
        for dir in [plain, joinedRoot] { try? fm.removeItem(at: dir) }
        var sites = 0, files = 0
        for sub in scannedSubpaths {
            let swiftFiles = try swiftFiles(under: repoRoot.appendingPathComponent(sub))
            for url in swiftFiles {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let (joined, count) = joinBrokenTernaries(in: text)
                sites += count
                files += count > 0 ? 1 : 0
                let relative = url.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
                try write(text, to: plain.appendingPathComponent(relative))
                try write(joined, to: joinedRoot.appendingPathComponent(relative))
            }
        }
        return Staged(plain: plain, joined: joinedRoot, sites: sites, files: files)
    }

    private func swiftFiles(under origin: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: origin,
                                                             includingPropertiesForKeys: nil,
                                                             options: [.skipsHiddenFiles]) else {
            throw XCTSkip("扫不到 \(origin.lastPathComponent) ⇒ 这一腿根本没跑，报错而不是判过")
        }
        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
            return url
        }
    }

    private func write(_ payload: String, to target: URL) throws {
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try payload.write(to: target, atomically: true, encoding: .utf8)
    }

    /// 只动 RD-80 那一种形状，其余字节一字不改。
    private func joinBrokenTernaries(in text: String) -> (String, Int) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var kept: [String] = []
        var joins = 0
        var index = 0
        while index < lines.count {
            let current = lines[index]
            let opensWithColon = index + 1 < lines.count
                && lines[index + 1].drop(while: { $0 == " " || $0 == "\t" }).first == ":"
            if opensWithColon, current.contains("?"), !current.contains(":"), !current.contains("://") {
                kept.append(current + " " + lines[index + 1].trimmingCharacters(in: .whitespaces))
                joins += 1
                index += 2
            } else {
                kept.append(current)
                index += 1
            }
        }
        return (kept.joined(separator: "\n"), joins)
    }

    func testBrokenTernaryReadsTheSameAsSameLineAcrossTheWholeRepository() async throws {
        let staged = try stageTwoCopies()
        defer {
            for dir in [staged.plain, staged.joined] { try? FileManager.default.removeItem(at: dir) }
        }
        XCTAssertGreaterThan(staged.sites, 0,
                             "一处都没并出来 ⇒ 这条不变式没吃到任何输入（分母归零＝没测）")
        let before = try await scan(staged.plain.appendingPathComponent("TcoderMonitor"))
        let after = try await scan(staged.joined.appendingPathComponent("TcoderMonitor"))
        let report = """
        RD-80 总体对表（同一批文件，唯一差别是把断行的三元并成一行）
        并行处数 \(staged.sites) / 涉及文件 \(staged.files)
        原样扫：函数 \(before.functions) · 榜内 ΣCC \(before.totalComplexity)
        并行扫：函数 \(after.functions) · 榜内 ΣCC \(after.totalComplexity)
        差量：函数 \(after.functions - before.functions) · ΣCC \(after.totalComplexity - before.totalComplexity)
        """
        // 读数落文件：只 print 等于没测（RD-64 那条）。
        try? report.write(to: repoRoot.appendingPathComponent(".scratch/tcoder-ternary-ab.txt"),
                          atomically: true, encoding: .utf8)
        print(report)
        XCTAssertEqual(after.functions, before.functions,
                       "把三元并回一行不该改变函数数（\(staged.sites) 处并前并后不一致，就是识别被换行影响）")
        XCTAssertEqual(after.totalComplexity, before.totalComplexity,
                       "RD-80 的不变式：换行写法与同行写法必须同分，差 \(after.totalComplexity - before.totalComplexity)")
    }
}
