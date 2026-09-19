import SwiftUI

/// 健康评分页的分数环。**未评分走空心 + --**，绝不落进 0 分红色档。
///
/// 旧实现借用了总览页的 `HealthRing`，那一版把 `score == nil` 折算成 0 再取色，
/// 于是「还没分析」显示成一个刺眼的红环。本页是收费点的门面，这个错最不能留，
/// 所以自建在 `Views/Health/` 内（不动 WS-K 名下的 DashboardView）。
struct HealthScoreRing: View {
    /// nil = 未评分 / 无可用输入。
    let score: Int?
    let grade: HealthGrade?
    let trend: Int?
    var lineWidth: CGFloat = 12

    /// 环的画布尺寸。门面级元素，尺寸集中在这里，页面不再各写一个魔法数。
    static let canvasWidth: CGFloat = 216
    static let canvasHeight: CGFloat = 196

    var body: some View {
        let role = Theme.Semantic.role(forScore: score)
        ZStack {
            Circle()
                .stroke(Theme.Palette.Surface.separator, lineWidth: lineWidth)
            if let score {
                Circle()
                    .trim(from: 0, to: CGFloat(min(max(score, 0), 100)) / 100)
                    .stroke(role.graphicColor,
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.smooth(duration: 0.6), value: score)
            } else {
                // 空心虚线环：形状本身就把「没算过」和「算了是 0 分」分开。
                Circle()
                    .stroke(Theme.Semantic.neutral.graphicColor,
                            style: StrokeStyle(lineWidth: lineWidth, dash: [4, 4]))
            }
            VStack(spacing: Theme.Spacing.xxs) {
                LiveNumber(Self.scoreText(score), tier: Theme.Typo.heroMetric,
                           tint: role.textColor)
                HStack(spacing: Theme.Spacing.xxs) {
                    Text("/100")
                        .font(Theme.Typo.microLabel.font)
                        .foregroundStyle(.tertiary)
                    if let grade {
                        Text(grade.rawValue)
                            .font(Theme.Typo.microLabel.font)
                            .foregroundStyle(role.textColor)
                    }
                    trendMark
                }
            }
        }
        .padding(Theme.Spacing.md)
        .accessibilityLabel(accessibilityText(role: role))
    }

    /// 分数一律走 `--` 通路，不把 nil 变成数字。
    static func scoreText(_ score: Int?) -> String {
        guard let score else { return Live.missing }
        return String(score)
    }

    static func forcesNeutral(for score: Int?) -> Bool { score == nil }

    @ViewBuilder
    private var trendMark: some View {
        if let trend, trend != 0 {
            let role = trend > 0 ? Theme.Semantic.success : Theme.Semantic.danger
            HStack(spacing: 0) {
                ThemedIcon(trend > 0 ? .trendUp : .trendDown, role: .badge)
                    .foregroundStyle(role.textColor)
                Text(NumberFormat.signed(trend))
                    .font(Theme.Typo.microLabel.font)
                    .foregroundStyle(role.textColor)
            }
            .help("上次 \(score.map { $0 - trend }.map(String.init) ?? Live.missing) → 本次 \(score.map(String.init) ?? Live.missing)")
        }
    }

    private func accessibilityText(role: Theme.SemanticRole) -> String {
        guard let score else { return "健康评分尚未计算" }
        let gradeText = grade.map { " 等级 \($0.rawValue)" } ?? ""
        let trendText = trend.map { " 较上次 \(NumberFormat.signed($0)) 分" } ?? ""
        return "综合分 \(score) /100\(gradeText)\(trendText)，\(role.name)"
    }
}
