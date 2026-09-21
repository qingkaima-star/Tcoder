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
        Theme.Page.Scaffold {
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

    /// 页内小标题（页头归 WS-O：项目名 / 路径 / 分析时间在 `ProjectDetailView`）。
    /// 图标灰阶；本页的口径声明常驻在 `HeuristicClaimLine`（分数旁边），不重复写在这里。
    private var header: some View {
        Theme.Page.Header(title: "健康评分",
                          icon: .health,
                          isDemo: report?.project.isDemo == true,
                          actions: { ScanControls() })
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
        .help("综合分 = Σ（维度得分 × 归一化权重），全部由本机规则从扫描结果算出，不访问网络，也不调用任何外部模型。")
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

/// Hero：分数环 + 结论。
///
/// **环上不再套井**：旧写法给 `HealthRing` 加了一层 `.contentInset` 实心灰盒 ——
/// 契约 3 里井只给表格 / 日志列表 / 代码块，一个环不是井；而它套在唯一的地面色上，
/// 就是「整个界面黑黢黢很脏」在这一页的具体落点。拿掉之后 56pt 的分数直接坐在
/// `ground` 上，全页最暗的墨与最重的字号第一次对上位置（风格契约 4）。
struct HealthHero: View {
    let health: HealthScore

    var body: some View {
        GlassSection("综合评分", subtitle: subtitle, icon: .health) {
            HStack(alignment: .top, spacing: Theme.Spacing.lg) {
                HealthRing(score: health.overall,
                                grade: health.grade,
                                trend: health.trendDelta)
                    .frame(width: DashboardLayout.heroRingWidth, height: DashboardLayout.heroRingHeight)
                narrativeColumn
            }
            if health.generatedByAI {
                // 契约里这个标记恒为 false；真出现时如实提示口径冲突，绝不把本页说成调用过外部模型。
                BannerRow(text: "上游把这条评分标记为外部模型产物，与本页口径不一致：Tcoder 只做本机启发式加权计算，不调用外部模型。请重新分析后再看。",
                          style: .warning)
            }
        }
    }

    /// 小标题只留**环里没有的那一件**信息。
    ///
    /// 旧文案是「综合分 82 /100 · 等级 B · 6/9 个维度参与计分」，而它下面 8pt 就是
    /// 56pt 的 `82`、环心里还写着 `/100` 和 `B` —— 同一张卡里一个数念三遍，
    /// 这就是「不规整拥挤」在文字侧的定义。分数、/100、等级三件由环承担（字号与
    /// 位置都在交代它们最重要），这里只交代参与计分的维度数。信息总量一项未减。
    private var subtitle: String {
        let scorable = HealthDimension.allCases.filter { $0.defaultWeight > 0 }.count
        return "\(health.components.count)/\(scorable) 个维度参与计分"
    }

    private var narrativeColumn: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            if health.narrative.isEmpty {
                // 一句结论缺位的说明，不是元数据：`.tertiary` 会让它像被灰掉的占位符，
                // 而它恰恰是「这次没有文字结论」这个事实本身。
                Text("本次评分没有附带文字结论。")
                    .font(Theme.Typo.narrative.font)
                    .foregroundStyle(.secondary)
                    .lineSpacing(Theme.Typo.narrative.lineSpacing)
            } else {
                Text(health.narrative)
                    .font(Theme.Typo.narrative.font)
                    .foregroundStyle(.secondary)
                    .lineSpacing(Theme.Typo.narrative.lineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HeuristicClaimLine()

            // 两件事的调整：
            //   ① 不再用 `Theme.Readout.Bar` —— 它内部自带 `.contentInset`，给一行键值
            //      读数画了一口非表格的井（`Design/**` 归总工，改不动，已报契约缺口）；
            //      `Readout.Field` 自己什么都不画，直接排。
            //   ② 「本次 X」删掉，因为 56pt 的环心里就是同一个 X（连同 /100 与等级），
            //      同一张卡里第三个副本只会挤掉版面的呼吸。「上次」与「计算于」环里没有，
            //      一律保留。
            if let codeScope = health.codeScope {
                HealthCodeScopeReadout(scope: codeScope)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
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

// MARK: - 工程质量（代码口径）副读数

/// 与综合分**同源、同批分量、同权重**的第二个数：只把「改本仓库代码就能抬起来」的维度算进来。
///
/// 为什么必须把成员名单与排除项一起画出来：只多报一个更好看的数，读者无从判断它是不是
/// 「挑对自己有利的口径」。这里连「不含提交活跃度、协作分布」一起写明，理由交给 `scope.note`。
/// 缺 `codeScope`（本次没有任何代码维度参与计分）时整块不出现 —— 不画一个 0 分冒充"代码很差"。
struct HealthCodeScopeReadout: View {
    let scope: HealthSubScore

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Theme.Readout.Field(scope.label, "\(scope.overall) · \(scope.grade.rawValue) 级", help: scope.note)
            Text(membershipLine)
                .typed(Theme.Typo.narrative)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var membershipLine: String {
        let included = "计入 \(scope.includedDimensions.joined(separator: "、"))"
        guard !scope.excludedDimensions.isEmpty else { return included + "（与综合分同一批分量）" }
        return included + "；不含 \(scope.excludedDimensions.joined(separator: "、"))"
    }
}
