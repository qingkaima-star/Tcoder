import Foundation
import XCTest
@testable import TcoderMonitor

/// 热点榜的**可复现性**。dogfooding 撞出来的：新老两条路对同一总体逐项对表时，
/// 唯一对不上的一项是 `topComplexFunctions[19]` —— 榜单**尾部**在两次运行之间换人。
///
/// 判据不测私有函数，测的是调用方真正拿到的那两份读数：
/// ① 同一台机器上扫同一个仓库两次，榜必须逐项相等；
/// ② 榜必须**全序**（相邻两项比较，五把键里至少有一把严格往下走），
///    否则"谁在第 20 名"仍然由输入顺序决定；
/// ③ 分母：本次扫描必须**真的存在并列**（复杂度与行数都相同的两项），
///    不然 ② 是一条永真断言 —— 本仓在"分不清没有和没查"上栽过太多次。
final class HotspotRankingDeterminismTests: XCTestCase {

    /// 被扫总体 = 本仓库根（dogfooding 是长期要求）。
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TcoderMonitorTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // TcoderMonitor
            .deletingLastPathComponent()   // <worktree>
    }

    /// 榜的排序键。**元组不能当泛型实参**（`XCTAssertEqual` 要 `T: Equatable`），
    /// 所以这里是一个自带 `Comparable` 的小结构，而不是 `(Int, Int, String, Int, String)`。
    private struct Rank: Comparable, Equatable {
        let complexity: Int
        let lines: Int
        let path: String
        let start: Int
        let name: String

        static func < (lhs: Rank, rhs: Rank) -> Bool {
            if lhs.complexity != rhs.complexity { return lhs.complexity > rhs.complexity }
            if lhs.lines != rhs.lines { return lhs.lines > rhs.lines }
            if lhs.path != rhs.path { return lhs.path < rhs.path }
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            return lhs.name < rhs.name
        }
    }

    /// 「a 该排在 b 前面」。**`Rank` 的 `<` 读作"名次更靠前"（复杂度大的在前）**，
    /// 所以下面所有断言都用这个函数，不直接写 `<=`，免得方向在脑子里翻一次就翻错。
    private static func precedes(_ a: Rank, _ b: Rank) -> Bool { a < b }

    private static func rank(_ h: FunctionHotspot) -> Rank {
        Rank(complexity: h.cyclomaticComplexity, lines: h.lineCount,
             path: h.filePath, start: h.startLine, name: h.name)
    }

    /// ①+②+③ 一次跑齐：两次独立扫描的榜逐项相等，且榜内全序、并且确有并列。
    func test_hotspotLeaderboardIsReproducibleAndTotallyOrdered() async throws {
        let analyzer = FileSystemCodeAnalyzer()
        let first = try await analyzer.analyze(root: repoRoot, options: .default)
        let second = try await analyzer.analyze(root: repoRoot, options: .default)

        let a = first.topComplexFunctions
        let b = second.topComplexFunctions
        XCTAssertFalse(a.isEmpty, "一条热点都没扫出来 —— 分母坏了，下面的断言全是永真")
        XCTAssertEqual(a.count, b.count, "两次扫描的榜长度都不一样（\(a.count) vs \(b.count)）")
        XCTAssertEqual(a.map(\.id), b.map(\.id),
                       "同一个仓库扫两次，热点榜换人了 ⇒ 截断线仍由输入顺序决定："
                       + "\n  第一次尾部：\(a.suffix(3).map(\.id))"
                       + "\n  第二次尾部：\(b.suffix(3).map(\.id))")

        var ties = 0
        for (left, right) in zip(a, a.dropFirst()) {
            // 相邻两项：后面的**不该**排在前面之前 —— 这就是"榜序单调"。
            XCTAssertFalse(Self.precedes(Self.rank(right), Self.rank(left)),
                           "榜序不单调：\(right.id) 该排在 \(left.id) 之前，却排在了它后面")
            if left.cyclomaticComplexity == right.cyclomaticComplexity,
               left.lineCount == right.lineCount {
                ties += 1
                // 两把主键全等 ⇒ 只能由 tie-break 定序，于是必须"前面的确实在前"。
                XCTAssertTrue(Self.precedes(Self.rank(left), Self.rank(right)),
                              "并列项没有按 路径→起始行→函数名 往下排：\(left.id) / \(right.id)")
            }
        }
        XCTAssertGreaterThan(ties, 0,
                             "整份榜没有一个并列项 ⇒ 全序判据是空的，换一个有并列的总体再测")
        print("【热点榜可复现】两次扫描逐项相等（\(a.count) 项），"
              + "其中 \(ties) 对由 路径→起始行→函数名 定序")
    }

    /// 反向自证：判据抓得住"主键并列就听输入顺序"的坏榜。
    func test_rankingOrderingCatchesAReversedLeaderboardOfTies() {
        let alpha = FunctionHotspot(name: "alpha", filePath: "Sources/a.swift", startLine: 3,
                                    lineCount: 30, cyclomaticComplexity: 14, parameterCount: 1, risk: .medium)
        let zeta = FunctionHotspot(name: "zeta", filePath: "Sources/z.swift", startLine: 9,
                                   lineCount: 30, cyclomaticComplexity: 14, parameterCount: 1, risk: .medium)
        // 并列前提：两把主键必须一字不差地相同，否则这条测不到 tie-break。
        XCTAssertEqual(alpha.cyclomaticComplexity, zeta.cyclomaticComplexity)
        XCTAssertEqual(alpha.lineCount, zeta.lineCount)
        XCTAssertTrue(Self.precedes(Self.rank(alpha), Self.rank(zeta)),
                      "路径 a < z，正序榜该判 alpha 在前")
        XCTAssertFalse(Self.precedes(Self.rank(zeta), Self.rank(alpha)),
                       "把并列两项倒过来排，必须被同一条相邻比较判负")
        // 旧写法（只有两把主键）在这里返回 `false` —— 也就是"谁也不许判谁输"，
        // 于是并列项的先后完全交给输入顺序。这条断言留在这里，是为了让人看见
        // **为什么"看起来一样"的两项仍然需要一个全序**。
        XCTAssertNotEqual(alpha.id, zeta.id)
    }
}
