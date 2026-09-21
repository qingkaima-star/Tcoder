import Foundation
import XCTest
@testable import TcoderMonitor

/// 规则：**卡里的说明句必须挂在它解释的那一行旁边**（同一行行尾，或卡头 `trailing:`），
/// 不许在卡片里独占一行。
///
/// 为什么这条值得钉：批次 P6 把长句收进 ⓘ 之后，出现了"卡片左下角一枚没邻居的灰点"——
/// 页尾配对取证（`.scratch/evidence-8de2d17/light-tail/`）第一次拍到折叠线以下才看见三处
/// （重复与复杂度概览、复杂度风险热点表、评分趋势），
/// 而这条守卫自己第一次跑又点到三处（重复代码率条、综合评分空态、仓库来源）。
/// 六处全部改完，所以判据是**零容忍**而不是棘轮：全站已经没有任何一枚 ⓘ 独占一行。
/// 它不是重叠也不是溢出，是**层级**：一个悬浮控件长得像掉进去的脏点，
/// 读者不会去 hover 一个看起来不像控件的东西。
///
/// 判据形状（静态代理，不起 App）：从 `CopyHelpBadge(` 那一行往回找最近的容器开口，
/// 落在 `HStack(` 或 `trailing:` 上才算挂在旁边；落在 `VStack {` 上就是独占一行。
final class CaliberBadgePlacementGuardTests: XCTestCase {

    /// 已经在这一批里改好的落点：钉住它们不许退回"独立一行"，也不许被顺手删掉说明句。
    private static let pinnedSites: [(file: String, fragment: String)] = [
        ("CodeMetricsSections.swift", "重复块 %1$@ 个"),
        ("CodeRiskView.swift", "点击行在 Finder 中定位源文件"),
        ("CodeRiskView.swift", "duplicationCaption(code)"),
        ("HealthAdviceCards.swift", "至少完成两次分析后可以看到趋势"),
        ("HealthView.swift", "评分综合代码规模"),
        ("GitInsightsSections.swift", "Self.discoveryDetail(git)"),
    ]

    /// 返回"最近的容器开口是 VStack"的那些 ⓘ 落点。
    static func detachedBadges(in files: [(path: String, content: String)]) -> [String] {
        files.flatMap { file in
            let lines = file.content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var hits: [String] = []
            for (index, raw) in lines.enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("//") || line.hasPrefix("///") { continue }
                guard line.hasPrefix("CopyHelpBadge(") else { continue }
                var offset = index - 1
                while offset >= 0 && index - offset <= 14 {
                    let probe = lines[offset].trimmingCharacters(in: .whitespaces)
                    if probe.hasPrefix("HStack") || probe.contains("trailing:") { break }
                    if probe.hasPrefix("VStack") {
                        hits.append("\(file.path):\(index + 1)")
                        break
                    }
                    offset -= 1
                }
            }
            return hits
        }
    }

    func test_caliberBadgesAreAttachedToTheRowTheyExplain() throws {
        let views = try SurfaceScanKit.sourceFiles(under: "Views")
        let detached = Self.detachedBadges(in: views)
        XCTAssertTrue(detached.isEmpty,
                      "这些 ⓘ 在卡片里独占一行（会长成一枚没邻居的灰点）：\(detached)")
    }

    /// 逐处钉：这三处必须**还在**（不被人顺手删掉说明句）且**还挂在对的地方**。
    /// 全局那条守卫只报"有没有违规"，这一条保证钉子指向的确实是这三处。
    func test_pinnedBadgeSitesKeepTheirAttachedShape() throws {
        let views = try SurfaceScanKit.sourceFiles(under: "Views")
        for site in Self.pinnedSites {
            let body = views.first { $0.path.hasSuffix(site.file) }?.content ?? ""
            XCTAssertFalse(body.isEmpty, "读不到 \(site.file) —— 判据在空转")
            XCTAssertTrue(body.contains(site.fragment),
                          "\(site.file) 里找不到那枚 ⓘ 的原文：说明句被删了还是改写了？")
            XCTAssertTrue(Self.detachedBadges(in: [("\(site.file)", body)]).isEmpty,
                          "\(site.file) 的那枚 ⓘ 又退回独立一行了")
        }
    }

    /// 两向元测试：VStack 里独占一行要抓到，挂进行尾或卡头不许误伤。
    func test_placementRulerCatchesSyntheticAndSparesAttached() {
        let detached = [(path: "Views/Fake/Fake.swift", content: """
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            MiniBarGauge(fraction: 0.2, tint: .blue, height: 4)
            CopyHelpBadge("重复块 20 个")
        }
        """)]
        XCTAssertEqual(Self.detachedBadges(in: detached).count, 1, "独立成行的 ⓘ 没抓到 → 守卫是摆设")

        let inlineRow = [(path: "Views/Fake/Fake.swift", content: """
        HStack(alignment: .center, spacing: Theme.Spacing.xxs) {
            MiniBarGauge(fraction: 0.2, tint: .blue, height: 4)
            CopyHelpBadge("重复块 20 个")
        }
        """)]
        XCTAssertTrue(Self.detachedBadges(in: inlineRow).isEmpty, "挂在行尾的合法写法被误伤")

        let headerSlot = [(path: "Views/Fake/Fake.swift", content: """
        GlassSection("评分趋势",
                     icon: .chartLine,
                     trailing: AnyView(CopyHelpBadge("至少完成两次分析后可以看到趋势。"))) {
            EmptyStateView(title: "历史点不足")
        }
        """)]
        XCTAssertTrue(Self.detachedBadges(in: headerSlot).isEmpty, "卡头 trailing 是官方挂载点，不许判红")
    }
}
