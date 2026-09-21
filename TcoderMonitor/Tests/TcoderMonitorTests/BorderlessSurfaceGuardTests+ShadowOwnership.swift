import XCTest
@testable import TcoderMonitor

// MARK: - 契约 6 的批次 P6 重写：投影只许长在"真的离开纸面"的那两层
//
// 拆成独立文件是**被尺子逼的**，不是洁癖：`BorderlessSurfaceGuardTests.swift` 加完这段
// 之后 421 行、元测试函数 55 行，同时踩了 `X3TestSizeAuditTests` 的 400/50 两条线。
// 本仓规矩是**拆文件、不抬阈值**。
//
// 权威 = `docs/界面语言-对齐AiX.md` §4。原判据"全仓唯一一处投影且必须在 `.floating` 分支里"
// 的成立前提是**地面纯白**：白纸上再压一张白纸，任何投影都是脏。
// 本轮地面换成 `#F7F7F7` 之后前提没了 —— 卡与画布是两个面，而实测两者只有
// **1.085:1**（低于人眼约 1.15:1 的分层阈值），分层必须靠发丝边 + 一层软影补上。
//
// 所以判据从"数量=1"改成"**两层各一处、且每一处都待在自己那一层的画法函数里**"。
// 这不是放宽：挂回 `surface()` 公共尾巴（三个层各吃一份影）仍然判红，
// 而那正是上一版"滥用投影"的原始形态。

extension BorderlessSurfaceGuardTests {

    func test_shadowsLiveOnlyInCardAndFloatingBranches() throws {
        let design = try Self.sourceFiles(under: "Design")
        let hits = Self.shadowHits(in: design)
        XCTAssertEqual(hits.count, 2,
                       "投影必须只有两处合法落点（`.card` 与 `.floating`）。实测 \(hits.count) 处：\(hits)")

        let glass = try XCTUnwrap(design.first { $0.path.hasSuffix("Glass.swift") })
        let owners = Self.enclosingFunctions(of: ".shadow(", in: glass.content)
        XCTAssertEqual(owners.sorted(), ["cardSurface", "floatingSurface"],
                       """
                       每一处投影都必须待在一个"只服务一个层"的函数里。实测归属：\(owners)。
                       挂回 `surface()` 的公共尾巴、或塞进 `outlined`/`chromeSurface`，
                       就等于让三个层各吃一份影。
                       """)
    }

    /// 每个 `needle` 命中行**往上最近的函数名**。
    ///
    /// 判据形状选"函数归属"而不是"case 分支区间"：画法函数本来就在 `surface()` 外面，
    /// 按 case 区间找会得到"投影不在任何分支里"这种看着对、其实是误判的结论
    /// （本条守卫的第一版就是这么红的）。
    static func enclosingFunctions(of needle: String, in content: String) -> [String] {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var found: [String] = []
        for (index, line) in lines.enumerated() where line.contains(needle) {
            guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
            let owner = lines[0...index].reversed().first {
                $0.contains("func ") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
            } ?? ""
            let name = owner.components(separatedBy: "func ").last?
                .split(whereSeparator: { $0 == "(" || $0 == "<" || $0 == " " })
                .first.map(String.init) ?? "?"
            found.append(name)
        }
        return found
    }

    /// 反向元测试：这把新尺子必须既能抓到公共尾巴，也不会把"没有投影"读成"全对"。
    func test_shadowOwnershipRulerCatchesTheSharedTail() {
        let sharedTail = """
        func surface(layer: GlassLayer) -> some View {
            self.background { shape.fill(color) }
                .shadow(color: .black.opacity(0.08), radius: 12, y: 2)
        }
        private func cardSurface<S: Shape>(in shape: S) -> some View {
            background { shape.fill(.white).shadow(color: .black, radius: 12, y: 2) }
        }
        """
        XCTAssertEqual(Self.enclosingFunctions(of: ".shadow(", in: sharedTail),
                       ["surface", "cardSurface"],
                       "投影归属判据失灵：挂在公共尾巴上那份没被认出来，重写后的守卫等于没写")
        XCTAssertTrue(Self.enclosingFunctions(of: ".shadow(", in: "func a() {}\nlet x = 1").isEmpty,
                      "没有投影时必须返回空集，否则这条元测试自己就是假绿")
    }
}
