import SwiftUI

// MARK: - 页面模型（九页导航的「页」这一侧）
//
// **本轮（WS-O / M1）删掉的是顶部那 9 枚 chip 条，不是这九页。**
//
// 旧文件在这里还有一个 `SectionNavBar` + `SectionNavChip`：一横排玻璃胶囊，选中一枚
// 升到 `.chrome` 吃真玻璃。它有两个毛病（spec §0 根因 ②⑤ / §1 风格契约 7）：
//   · 每个控件层胶囊都带一份材质边界，与侧栏选中行、顶栏按钮混成三种「谁是导航」；
//   · 它横在页头下面吃掉 44pt 纵向空间，而九页的**页名**本来就该住在侧栏。
// 现在九页进了侧栏的 `Section("分析视图")`（`Views/Shell/ProjectSidebar.swift`）。
//
// 文件与 `DetailSection` 的名字**都不动**：README 与 `docs/使用说明.md` 用
// `SectionNav.DetailSection` 定位九页清单，`DocReferenceRatchetTests` 会钉这个锚点。
//
// 图标一律走 `IconName` 登记表（WS-I §7.2 的工单：页面禁止裸符号串）。这修掉两处旧的语义漂移：
//   · 「复杂度风险」原来用 `exclamationmark.triangle.fill`，把风险徽标符号当成了页图标；
//     现在走 `IconName.complexity`（ƒ），三角留给真正的风险徽标。
//   · 「性能监控」原来借用 `IconName.pulse`（心电图），现在走登记表里的仪表符号，
//     macOS 14 上由 `IconAvailability` 自动退回心电图，不会画成空白。

enum DetailSection: String, CaseIterable, Identifiable, Sendable {
    case overview = "总览"
    case code = "代码规模"
    case risk = "复杂度风险"
    case git = "Git 洞察"
    case contributors = "贡献者"
    case performance = "性能监控"
    case logs = "错误日志"
    case dependencies = "依赖分析"
    case health = "健康评分"

    var id: String { rawValue }

    var title: String { rawValue }

    var iconName: IconName {
        switch self {
        case .overview: return .dashboard
        case .code: return .code
        case .risk: return .complexity
        case .git: return .git
        case .contributors: return .people
        case .performance: return .performance
        case .logs: return .logs
        case .dependencies: return .package
        case .health: return .health
        }
    }

    /// 性能页读的是实时采样，没有报告也能看；其余八页都要先扫一次。
    var requiresReport: Bool {
        switch self {
        case .overview, .code, .risk, .git, .contributors, .logs, .dependencies, .health: return true
        case .performance: return false
        }
    }

    /// 没有报告时把需要报告的页禁掉，而不是让用户点进一张空卡。
    /// 纯函数，供单测钉住「性能页永远可达、其余页要先扫」。
    ///
    /// 落点从 chip 条**平移**到侧栏视图行（`ProjectSidebar.AnalysisSectionRow`），语义一字未改。
    func isReachable(reportAvailable: Bool) -> Bool {
        reportAvailable || !requiresReport
    }
}
