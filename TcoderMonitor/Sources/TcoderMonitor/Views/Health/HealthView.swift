import SwiftUI

/// OWNER: WS-M / 健康评分页（未来收费点，视觉分量最重的一页）。
///
/// 口径：综合分是「各维度得分 × 归一化权重」的加权和，全部由本机规则算出，
/// 不访问网络、不调用任何外部模型（契约里 `HealthScore.generatedByAI` 恒为 false）。
/// 这条声明在本页**常驻**，因为它决定用户敢不敢为这个分数付费。
///
/// 缺数据的维度不参与计分也不得显示 0 分，必须在原位说明原因（验收点 6）。
struct HealthView: View {
    var report: ProjectReport?

    @Environment(AppState.self) private var state

    var body: some View {
        Theme.Page.Scaffold(maxWidth: Theme.Layout.maxWidthDense) {
            header
            if let health = report?.health {
                if health.components.isEmpty {
                    HealthNoInputCard(health: health)
                } else {
                    HealthHero(health: health)
                    HealthComponentTable(health: health, report: report)
                    HealthAdviceGrid(health: health)
                }
                HealthTrendCard(health: report?.health, points: historyPoints)
            } else {
                HealthNotScoredCard()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
            ThemedIcon(.health, role: .navigation)
                .foregroundStyle(Theme.Semantic.accent.textColor)
            Text("健康评分").font(Theme.Typo.pageTitle.font)
            if report?.project.isDemo == true {
                SemanticBadge("示例", role: Theme.Semantic.info)
            }
            Spacer(minLength: Theme.Spacing.sm)
            ScanControls()
        }
    }

    private var historyPoints: [ScoreHistoryPoint] {
        guard let projectID = report?.project.id ?? state.selectedProject?.id else { return [] }
        return state.store.scoreHistory(for: projectID)
    }
}

// MARK: - 口径声明与重算入口

/// 「启发式加权、未调用外部模型」这句声明。三处复用，所以只写一遍。
struct HeuristicClaimLine: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xxs) {
            ThemedIcon(.info, role: .badge).foregroundStyle(Theme.Semantic.neutral.textColor)
            Text(Self.claim)
                .font(Theme.Typo.label.font)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .help("综合分 = Σ(维度得分 × 归一化权重)，全部由本机规则从扫描结果算出，不访问网络，也不调用任何外部模型。")
    }

    static let claim = "启发式加权计算，未调用外部模型"
}

struct ScanControls: View {
    @Environment(AppState.self) private var state

    var body: some View {
        GlassToolbar {
            GlassButton("重新分析", icon: .reanalyze,
                        isEnabled: !state.isScanning && state.selectedProject != nil) {
                state.scanSelected()
            }
            if state.isScanning {
                HStack(spacing: Theme.Spacing.xxs) {
                    ProgressView().controlSize(.small)
                    Text(state.phase.label).font(Theme.Typo.label.font).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Hero：分数环 + 结论

struct HealthHero: View {
    let health: HealthScore

    var body: some View {
        GlassSection("综合评分", subtitle: subtitle, icon: .health) {
            HStack(alignment: .top, spacing: Theme.Spacing.lg) {
                HealthRing(score: health.overall,
                                grade: health.grade,
                                trend: health.trendDelta)
                    .frame(width: DashboardLayout.heroRingWidth, height: DashboardLayout.heroRingHeight)
                    .surface(layer: .contentInset, shape: .rounded(Theme.Radius.md))
                narrativeColumn
            }
            if health.generatedByAI {
                // 契约里这个标记恒为 false；真出现时如实提示口径冲突，绝不把本页说成调用过外部模型。
                BannerRow(text: "上游把这条评分标记为外部模型产物，与本页口径不一致：Tcoder 只做本机启发式加权计算，不调用外部模型。请重新分析后再看。",
                          style: .warning)
            }
        }
    }

    private var subtitle: String {
        let scorable = HealthDimension.allCases.filter { $0.defaultWeight > 0 }.count
        return "综合分 \(health.overall) /100 · 等级 \(health.grade.rawValue) · \(health.components.count)/\(scorable) 个维度参与计分"
    }

    private var narrativeColumn: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            if health.narrative.isEmpty {
                Text("本次评分没有附带文字结论。")
                    .font(Theme.Typo.narrative.font)
                    .foregroundStyle(.tertiary)
                    .lineSpacing(Theme.Typo.narrative.lineSpacing)
            } else {
                Text(health.narrative)
                    .font(Theme.Typo.narrative.font)
                    .foregroundStyle(.secondary)
                    .lineSpacing(Theme.Typo.narrative.lineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HeuristicClaimLine()

            Theme.Readout.Bar {
                Theme.Readout.Field("本次", String(health.overall))
                Theme.Readout.Field("上次", health.previousOverall.map(String.init) ?? "无记录")
                Theme.Readout.Field("计算于", DateFormat.sinceDescription(health.computedAt))
            }
            Text(DateFormat.full.string(from: health.computedAt))
                .font(Theme.Typo.monoSmall.font)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 两种「没有分数」必须分开

struct HealthNotScoredCard: View {
    var body: some View {
        GlassSection("综合评分", subtitle: "尚未计算，不给分也不着色", icon: .health) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                EmptyStateView(icon: IconName.health.rawValue,
                               title: "尚未计算健康评分",
                               message: "选择项目目录后点「重新分析」，会综合代码规模、复杂度、重复代码率、Git 活跃度、运行日志与依赖状况给出 0~100 分。")
                HeuristicClaimLine()
            }
        }
    }
}

/// 跑完了但一个维度都没算出来：0 分是「没数据」，不是「很差」。
struct HealthNoInputCard: View {
    let health: HealthScore

    var body: some View {
        GlassSection("综合评分", subtitle: "无可用输入", icon: .health) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack(alignment: .top, spacing: Theme.Spacing.lg) {
                    HealthRing(score: nil, grade: nil, trend: nil)
                        .frame(width: DashboardLayout.heroRingWidth, height: DashboardLayout.heroRingHeight)
                        .surface(layer: .contentInset, shape: .rounded(Theme.Radius.md))
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text("本次没有任何维度输入，因此不给综合分。")
                            .font(Theme.Typo.body.font)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("这里刻意不画一个 0 分红环：0 分会被读成「这个项目很差」，而事实是「没有可算的数据」。")
                            .font(Theme.Typo.narrative.font)
                            .foregroundStyle(.secondary)
                            .lineSpacing(Theme.Typo.narrative.lineSpacing)
                            .fixedSize(horizontal: false, vertical: true)
                        Theme.Readout.Field("计算于", DateFormat.sinceDescription(health.computedAt))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !health.narrative.isEmpty {
                    Text(health.narrative)
                        .font(Theme.Typo.narrative.font)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HeuristicClaimLine()
            }
        }
    }
}
