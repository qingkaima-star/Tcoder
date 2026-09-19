import SwiftUI

// MARK: - Hero：健康评分环 + 结论区
//
// 首屏第一眼。两处旧写法直接误导用户，本轮一并修：
//   1. `score ?? 0` 让「没评分」画成 0 分红色满环（WS-I §3.4 / WS-D #6）；
//   2. 优点 / 问题用 `plus.circle` / `minus.circle`，读起来像「加钱 / 减分」，
//      换成登记表里的对勾与三角，才是「已确认」与「需注意」的双通道。

struct HealthRing: View {
    /// nil = 未评分。必须画成空心灰环 + `--`，不能画成 0 分。
    var score: Int?
    var grade: HealthGrade?
    var trend: Int?

    var body: some View {
        let role = Theme.Semantic.role(forScore: score)
        ZStack {
            Circle()
                .stroke(Theme.Palette.Surface.separator,
                        lineWidth: ShellLayout.ringLineWidth)
            if let score {
                Circle()
                    .trim(from: 0, to: CGFloat(min(max(score, 0), 100)) / 100)
                    .stroke(role.graphicColor,
                            style: StrokeStyle(lineWidth: ShellLayout.ringLineWidth,
                                               lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.smooth, value: score)
            }
            readout(role: role)
        }
        .padding(Theme.Spacing.md)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("健康评分")
        .accessibilityValue(score.map { "\($0) 分" } ?? Theme.Placeholder.missingValue)
    }

    private func readout(role: Theme.SemanticRole) -> some View {
        VStack(spacing: Theme.Spacing.xs) {
            Text(score.map(String.init) ?? Theme.Placeholder.missingValue)
                .font(Theme.Typo.heroMetric.font)
                .foregroundStyle(score == nil ? Theme.Semantic.neutral.textColor
                                              : role.textColor)
            subline(role: role)
        }
    }

    @ViewBuilder
    private func subline(role: Theme.SemanticRole) -> some View {
        HStack(spacing: Theme.Spacing.xxs) {
            Text("/100")
                .font(Theme.Typo.microLabel.font.monospacedDigit())
                .foregroundStyle(.tertiary)
            if let grade {
                Text(grade.rawValue)
                    .font(Theme.Typo.microLabel.font)
                    .foregroundStyle(role.textColor)
            }
            if let trend, trend != 0 {
                // 双通道：箭头符号 + 有符号数字，不只靠红绿（WS-H §4.3 / §10）
                HStack(spacing: Theme.Spacing.xxs) {
                    ThemedIcon(trend > 0 ? .trendUp : .trendDown, role: .badge)
                    Text(NumberFormat.signed(trend))
                        .font(Theme.Typo.microLabel.font.monospacedDigit())
                }
                .foregroundStyle(trend > 0 ? Theme.Semantic.success.textColor
                                           : Theme.Semantic.danger.textColor)
            }
        }
    }
}

/// Hero 卡：左环右结论。属**内容层**，所以吃标准材质而不是玻璃（[HIG-M]）。
struct HealthHeroCard: View {
    var health: HealthScore?

    var body: some View {
        GlassCard(spacing: nil) {
            HStack(alignment: .top, spacing: DashboardLayout.heroGap) {
                HealthRing(score: health?.overall,
                           grade: health?.grade,
                           trend: health?.trendDelta)
                    .frame(width: DashboardLayout.heroRingWidth,
                           height: DashboardLayout.heroRingHeight)
                narrative
            }
        }
    }

    @ViewBuilder
    private var narrative: some View {
        if let health {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("工程健康评分")
                    .font(Theme.Typo.label.font)
                    .foregroundStyle(.secondary)
                findings(health)
                if !health.narrative.isEmpty {
                    Text(health.narrative)
                        .font(Theme.Typo.narrative.font)
                        .lineSpacing(Theme.Typo.narrative.lineSpacing)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Spacer(minLength: Theme.Spacing.xs)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            EmptyStateView(
                icon: IconName.emptyUnknown.rawValue,
                title: ShellCopy.notAnalyzed("该项目"),
                message: "点击右上角「重新分析」，扫描代码规模、Git 历史、日志与依赖之后这里会出现评分与结论。"
            )
        }
    }

    /// 优点与问题各取 3 条（WS-H §8.1）。两条都空时明说，而不是留一块空白让人以为没渲染。
    @ViewBuilder
    private func findings(_ health: HealthScore) -> some View {
        let strengths = Array(health.strengths.prefix(3))
        let issues = Array(health.issues.prefix(3))
        if strengths.isEmpty && issues.isEmpty {
            Text(ShellCopy.scannedButFoundNone("优点与风险项"))
                .font(Theme.Typo.narrative.font)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                ForEach(strengths, id: \.self) { item in
                    findingRow(item, icon: .noRisk, role: Theme.Semantic.success)
                }
                ForEach(issues, id: \.self) { item in
                    findingRow(item, icon: .riskWarning, role: Theme.Semantic.warning)
                }
            }
        }
    }

    private func findingRow(_ text: String, icon: IconName, role: Theme.SemanticRole) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xxs) {
            ThemedIcon(icon, role: .inlineText, selected: true)
                .foregroundStyle(role.textColor)
            Text(text)
                .font(Theme.Typo.narrative.font)
                .lineLimit(1)
        }
    }
}
