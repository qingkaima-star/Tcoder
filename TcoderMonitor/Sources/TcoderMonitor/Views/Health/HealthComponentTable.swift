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
                     subtitle: "综合分 = Σ（得分 × 归一化权重） · 按拖累程度排序，贡献最低者在前",
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
                    NoteLine("分量合计 \(Live.fixed(sum, digits: 1)) 与综合分 \(score) 有出入，通常是评分器的归一化或取整口径不同。",
                             role: Theme.Semantic.warning, icon: .riskWarning)
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
                Text(row.name).font(Theme.Typo.label.font).lineLimit(1)
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
                .help(Text(localizedFormat("满分可得 %1$@，这一维度拖了 %2$@ 分",
                            Live.fixed(row.fullMarks, digits: 1),
                            Live.fixed(row.lostPoints, digits: 1))))

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
                        Text("\(DimensionDisplay.name(dimension))：")
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
