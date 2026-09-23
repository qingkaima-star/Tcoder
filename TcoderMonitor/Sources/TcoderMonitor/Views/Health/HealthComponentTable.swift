import SwiftUI

// MARK: - 分量表视图

struct HealthComponentTable: View {
    let health: HealthScore
    let report: ProjectReport?


    private var rows: [ScoreRow] { HealthBreakdown.rows(for: health) }
    private var missingCount: Int { HealthBreakdown.missingDimensions(of: health).count }
    private var sum: Double { HealthBreakdown.sumOfContributions(rows) }

    var body: some View {
        GlassSection("维度分量",
                     // ⚠ 这句必须说**真的排序键**（台账 RD-28）：`HealthBreakdown.rows` 排的是
                     // `contribution = 得分 × 本次乘数`，不是 `lostPoints = 乘数 × (100 − 得分)`。
                     // 旧写法「按拖累程度排序」会在"低权重低分"与"高权重中分"并存时撒谎：
                     // 前者排第一被叫作最大拖累，而后者的失分其实是它的三倍。
                     subtitle: "按「贡献」列升序，最低在前",
                     // 公式与"拖累在哪一列"一起进 ⓘ：整列静态文案不许宣称逐行不同的结论。
                     // ⚠ 必须是**一整条字面量**：目录键与它逐字相等，拼成两半就会同时撞
                     // `LocalizationGuardTests` 的守卫 3（源码里找不到整键 ⇒ 判烂尾）。
                     // ⚠️ R7 与 R9 修过同一句假话（派单时 §十 的归属重叠了，总工的调度错误）。
                     //    副标题取 R7 那版短句：常驻长句棘轮只减不增；
                     //    而「说清按什么排、拖累为什么不是第一行」由下面那条 ⓘ 承担，更完整也不占常驻版面。
                     subtitleHelp: "综合分 = Σ（得分 × 归一化权重）。「这一维拖了多少分」看贡献列的提示（乘数 ×（100 − 得分）），它不必是本页第一行 —— 两个键在低权重维度上会分叉。",
                     icon: .health,
                     // 卡头 trailing 位只有一行，没有"第二行的值要竖向对齐"这回事，
                     // 所以标签不占 160pt 列宽 —— 占了就变成「合计 ………… 60.1」
                     // 中间一段空版心（1240 版框实拍）。
                     trailing: AnyView(Theme.Readout.Field("合计", Live.fixed(sum, digits: 1),
                                                           labelWidth: nil))) {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                table
                DataRowSeparator()
                missingBlock
                if let score = health.verdict, !HealthBreakdown.isSumConsistent(sum, with: score) {
                    // 两个数必须留在屏上（它们就是"对不上"这件事的证据），归因进 ⓘ。
                    NoteLine("分量合计 \(Live.fixed(sum, digits: 1)) 与综合分 \(score) 有出入。",
                             role: Theme.Semantic.warning, icon: .riskWarning,
                             help: "出入通常来自评分器的归一化或取整口径不同，界面以评分器发布值为准。")
                }
            }
        }
    }

    /// 表头与行共用 `DataColumns.healthComponents` 一份列定义（#34）。
    /// 行间距沿用原 `Grid` 的 `verticalSpacing: .xs`（分量名与详情是两行文本，比另两页松）。
    private var table: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            DataTableHeader(columns: DataColumns.healthComponents)
            ForEach(rows) { row in
                rowView(row)
            }
        }
    }

    private func rowView(_ row: ScoreRow) -> some View {
        let role = Theme.Semantic.role(forScore: row.score)
        return HStack(alignment: .top, spacing: DataRowMetrics.cellGap) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                // 维度名住在契约里（`HealthScore` 的中文 `name`），`Text(String)` 不查表，
                // 所以英文态这一列整片是中文 —— 键其实早就登记好了（协作分布 = Collaboration Spread…）。
                Text(localizedCopy(row.name)).font(Theme.Typo.label.font).lineLimit(1)
                RiskBadge(risk: row.component.risk, showIcon: false)
            }
            .tableCell(DataColumns.column(DataColumns.healthComponents, 0))

            HStack(spacing: Theme.Spacing.xxs) {
                MiniBarGauge(fraction: Double(row.score) / 100,
                             tint: role.graphicColor,
                             height: Theme.Layout.gaugeInline)
                    .frame(width: DataColumns.healthScoreGauge)
                // 分数不再跟着涂语义色（批次 P5）：同一行里"这一维度好不好"
                // 已经由左边那根量条说了一遍，数字再涂一次就是三重上色 ——
                // 浅色态实拍里这一屏同时出现红/橙/两绿/灰共 6 种彩色，
                // 是全站最"脏"的一屏。一个语义一处着色：色流量条，数字吃墨。
                LiveNumber(String(row.score), tier: Theme.Typo.monoSmall)
                    .numberCell(DataColumns.healthScoreNumber)
            }
            .tableCell(DataColumns.column(DataColumns.healthComponents, 1))

            LiveNumber(NumberFormat.percent(row.effectiveWeight, precision: 0),
                       tier: Theme.Typo.monoSmall)
                .tableCell(DataColumns.column(DataColumns.healthComponents, 2))
                .help(weightHelp(row))

            LiveNumber(Live.fixed(row.contribution, digits: 1), tier: Theme.Typo.monoSmall)
                .tableCell(DataColumns.column(DataColumns.healthComponents, 3))
                // 与上一格 `weightHelp(row)` 同一形状（`.help` 收 `String` 的重载）。
                // 原来多套一层 `Text(` —— 悬停上没有任何区别，但收纳尺子认不出这一格
                // 是 hover 承载位，于是把一句真 ⓘ 算成了常驻长句（`+HelpSlots` 那条
                // "换壳不换读数"的元测试钉的就是这一族形状，只是它当时没覆盖到
                // `.help(Text(localizedFormat("…")))` 这一种夹法，已记进本轮汇报的盲区）。
                .help(localizedFormat("满分可得 %1$@，这一维度拖了 %2$@ 分",
                                      Live.fixed(row.fullMarks, digits: 1),
                                      Live.fixed(row.lostPoints, digits: 1)))

            Text(row.component.detail)
                .font(Theme.Typo.narrative.font)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .tableCell(DataColumns.column(DataColumns.healthComponents, 4))
                .help(row.component.detail)
        }
    }

    private func weightHelp(_ row: ScoreRow) -> String {
        HealthBreakdown.weightTooltip(for: row, rows: rows, missingCount: missingCount)
    }

    // MARK: 缺失维度

    @ViewBuilder
    private var missingBlock: some View {
        let missing = HealthBreakdown.missingDimensions(of: health)
        if missing.isEmpty {
            NoteLine(HealthBreakdown.normalizationSummary(rows: rows, missingCount: 0)
                     + "测试覆盖只在项目真的产出了覆盖率报告时参与计分。")
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(localizedFormat("缺失维度 %1$@ 项", NumberFormat.grouped(missing.count)))
                    // 组内小标题全站一档：`groupLabel`（10pt medium + 0.6 字距）。
                    // 这里原来是 `cardTitle`(13 semibold)，与它上面那行节标题只差一档字重，
                    // 而日志页同一角色又用 `microLabel + .tertiary` —— 三种画法（清单 3.9）。
                    // 必须走 `.typed`：`Font` 没有字距 API，直接 `.font(...)` 会静默丢字距。
                    .typed(Theme.Typo.groupLabel)
                    .foregroundStyle(.secondary)
                ForEach(missing, id: \.rawValue) { dimension in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xxs) {
                        ThemedIcon(.unverified, role: .badge)
                            .foregroundStyle(Theme.Semantic.warning.textColor)
                        // 整句键：`名字 + "："` 是守卫 1d【拼了查不中】点名的形状 ——
                        // 拼完那一串没有键，英文态就永远铺着「运行稳定性：」这种半中半英。
                        Text(localizedFormat("%1$@：", DimensionDisplay.name(dimension)))
                            .font(Theme.Typo.label.font)
                        Text(MissingDimensionReason.text(for: dimension, report: report))
                            .font(Theme.Typo.label.font)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                }
                Text(HealthBreakdown.normalizationSummary(rows: rows, missingCount: missing.count))
                    .font(Theme.Typo.microLabel.font)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
