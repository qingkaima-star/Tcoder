import SwiftUI
import Charts

/// OWNER: Workstream C / 子代理「健康评分视图」—— 工程健康评分页。
///
/// 口径：综合分是「各维度得分 × 归一化权重」的加权和，全部由本机规则算出，
/// 不访问网络、不调用任何外部模型（契约里 `HealthScore.generatedByAI` 恒为 false，
/// 界面文案也就固定写「启发式加权计算，未调用外部模型」）。
/// 缺数据一律走 `EmptyStateView`，不用 0 分冒充真实结果。
struct HealthView: View {
    var report: ProjectReport?

    @Environment(AppState.self) private var state

    // MARK: 布局常量（不是指标）

    private static let dimensionWidth: CGFloat = 118
    private static let scoreNumberWidth: CGFloat = 26
    private static let scoreGaugeWidth: CGFloat = 44
    private static let weightColumnWidth: CGFloat = 44
    private static let contributionColumnWidth: CGFloat = 44
    private static let listColumns = [GridItem(.adaptive(minimum: 232), spacing: 12)]

    /// 等级 B 的分数线，与 `HealthGrade.init(score:)` 保持一致。
    private static let gradeBLine = 70.0

    static let heuristicClaim = "启发式加权计算，未调用外部模型"
    /// 参与计分的维度数（`defaultWeight == 0` 的维度本来就不计分）。
    private static var scorableDimensionCount: Int {
        HealthDimension.allCases.filter { $0.defaultWeight > 0 }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let health = report?.health {
                    if health.components.isEmpty {
                        noInputCard(health)
                    } else {
                        heroRow(health)
                        componentTable(health)
                        overviewRow(health)
                    }
                    trendCard(health)
                } else {
                    missingScoreState
                }
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: - 尚未评分

    private var missingScoreState: some View {
        VStack(alignment: .leading, spacing: 10) {
            EmptyStateView(
                icon: "checkmark.shield",
                title: "尚未计算健康评分",
                message: "选择项目目录后点「重新分析」，会综合代码规模、复杂度、重复度、Git 活跃度、运行日志与依赖状况给出 0~100 分。"
            )
            .frame(maxWidth: .infinity, minHeight: 250)

            heuristicLine
        }
    }

    // MARK: - Hero

    private func heroRow(_ health: HealthScore) -> some View {
        HStack(alignment: .top, spacing: 14) {
            HealthRing(
                score: health.overall,
                grade: health.grade,
                trend: health.trendDelta
            )
            .frame(width: 200, height: 180)
            .frame(maxWidth: .infinity)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.gridLine, lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    Text("工程健康评分").font(.caption).foregroundStyle(.secondary)
                    Text("等级 \(health.grade.rawValue)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.color(forScore: health.overall))
                    Spacer(minLength: 4)
                    trendText(health)
                }

                if !health.narrative.isEmpty {
                    Text(health.narrative)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("本次评分没有附带文字结论。")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                heuristicLine

                HStack(spacing: 14) {
                    StatLine(label: "本次", value: "\(health.overall)")
                    StatLine(label: "上次", value: health.previousOverall.map(String.init) ?? "无记录")
                    StatLine(label: "维度", value: "\(health.components.count)/\(Self.scorableDimensionCount)")
                    StatLine(label: "计算于", value: DateFormat.sinceDescription(health.computedAt))
                    Spacer(minLength: 4)
                }
                .font(.caption)

                Text(DateFormat.full.string(from: health.computedAt))
                    .font(Theme.monoSmall)
                    .foregroundStyle(.tertiary)

                if health.generatedByAI {
                    // 与本页口径冲突时才出现：不掩盖，也不改口去声称调用过模型。
                    BannerRow(
                        text: "上游把这条评分标记为模型生成，与本页的启发式口径不一致，请重新分析后再看。",
                        style: .warning
                    )
                }

                scanRow
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.gridLine, lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private func trendText(_ health: HealthScore) -> some View {
        if let delta = health.trendDelta {
            let tint = delta > 0 ? Theme.healthy : (delta < 0 ? Theme.danger : Theme.neutral)
            HStack(spacing: 3) {
                Image(systemName: delta > 0 ? "arrow.up.right" : (delta < 0 ? "arrow.down.right" : "arrow.right"))
                    .font(.system(size: 9, weight: .bold))
                Text("较上次 \(NumberFormat.signed(delta)) 分")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(tint)
            .help("上次综合分 \(health.previousOverall.map(String.init) ?? "无记录") → 本次 \(health.overall)")
        }
    }

    private var heuristicLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "info.circle")
                .font(.system(size: 9))
                .foregroundStyle(Theme.neutral)
            Text(Self.heuristicClaim)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .help("综合分 = Σ(维度得分 × 归一化权重)，全部由本机规则从扫描结果算出，不访问网络，也不调用任何外部模型。")
    }

    private var scanRow: some View {
        HStack(spacing: 8) {
            Button {
                state.scanSelected()
            } label: {
                Label("重新分析", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            .disabled(state.isScanning || state.selectedProject == nil)
            .help("重新扫描当前项目并按同一口径重算评分")

            if state.isScanning {
                ProgressView().controlSize(.small)
                Text(state.phase.label).font(.system(size: 10)).foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - 无可用输入（评分为 0 且没有任何分量）

    private func noInputCard(_ health: HealthScore) -> some View {
        SectionCard(
            "工程健康评分",
            subtitle: "本次没有任何维度输入，综合分 0 只代表「无数据」",
            icon: IconName.health.rawValue
        ) {
            VStack(alignment: .leading, spacing: 10) {
                EmptyStateView(
                    icon: "circle.dotted",
                    title: "无可用输入",
                    message: "代码、Git、日志与依赖四类数据都没能取到，因此一个维度也没算出来。这里不显示 0 分环，以免被当成真实的健康度。"
                )
                .frame(maxWidth: .infinity, minHeight: 120)

                if !health.narrative.isEmpty {
                    Text(health.narrative)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 14) {
                    StatLine(label: "计算于", value: DateFormat.sinceDescription(health.computedAt))
                    StatLine(label: "维度", value: "0/\(Self.scorableDimensionCount)")
                    Spacer(minLength: 4)
                }
                .font(.caption)

                heuristicLine
                scanRow
            }
        }
    }

    // MARK: - 维度分量表

    private func componentTable(_ health: HealthScore) -> some View {
        // 拖累最大的排最前：贡献分越低越靠前。
        let rows = health.components.sorted { lhs, rhs in
            if lhs.weightedContribution != rhs.weightedContribution {
                return lhs.weightedContribution < rhs.weightedContribution
            }
            return lhs.score < rhs.score
        }
        let sum = health.components.reduce(0) { $0 + $1.weightedContribution }
        let weightSum = health.components.reduce(0) { $0 + $1.weight }
        let missing = missingDimensions(of: health)
        let notes = normalizationNotes(for: health)

        return SectionCard(
            "维度分量",
            subtitle: "综合分 = Σ(得分 × 归一化权重) · 按拖累程度排序，贡献最低者在前",
            icon: IconName.health.rawValue,
            trailing: AnyView(StatLine(label: "合计", value: String(format: "%.1f", sum)))
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 7) {
                    GridRow {
                        headerCell("维度", width: Self.dimensionWidth, alignment: .leading)
                        headerCell("得分", width: nil, alignment: .trailing)
                            .gridColumnAlignment(.trailing)
                        headerCell("权重", width: nil, alignment: .trailing)
                            .gridColumnAlignment(.trailing)
                        headerCell("贡献", width: nil, alignment: .trailing)
                            .gridColumnAlignment(.trailing)
                        headerCell("详情", width: nil, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Divider().gridCellColumns(5).opacity(0.5)

                    ForEach(rows) { component in
                        GridRow {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(component.name)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                                RiskBadge(risk: component.risk, showIcon: false)
                            }
                            .frame(width: Self.dimensionWidth, alignment: .leading)

                            HStack(spacing: 5) {
                                MiniBarGauge(
                                    fraction: Double(component.score) / 100,
                                    tint: Theme.color(forScore: component.score),
                                    height: 4
                                )
                                .frame(width: Self.scoreGaugeWidth)

                                Text("\(component.score)")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Theme.color(forScore: component.score))
                                    .frame(width: Self.scoreNumberWidth, alignment: .trailing)
                            }

                            Text(NumberFormat.percent(component.weight, precision: 0))
                                .font(Theme.monoSmall)
                                .foregroundStyle(.secondary)
                                .frame(minWidth: Self.weightColumnWidth, alignment: .trailing)
                                .help(weightHelp(for: component, in: health))

                            Text(String(format: "%.1f", component.weightedContribution))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Theme.color(forScore: component.score))
                                .frame(minWidth: Self.contributionColumnWidth, alignment: .trailing)
                                .help("满分可得 \(String(format: "%.1f", component.weight * 100))，这次少了 \(String(format: "%.1f", component.weight * Double(100 - component.score)))")

                            Text(component.detail)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .help(component.detail)
                        }
                    }
                }

                Divider().opacity(0.5)

                if missing.isEmpty {
                    Text("参与计分的 \(Self.scorableDimensionCount) 个维度全部有输入；测试覆盖按口径权重为 0，不计入总分。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("缺失维度：\(missing.map(\.rawValue).joined(separator: "、"))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.caution)
                    Text("缺失维度不参与计分，权重已按比例归一到其余维度。\(notes)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if abs(weightSum - 1) > 0.02 {
                    // 权重合计不是 100% 时说明清楚，不假装合计等于满分。
                    Text("各维度权重合计 \(NumberFormat.percent(weightSum, precision: 1))，贡献分按实际权重计，因此合计与综合分可能有舍入差。")
                        .font(.caption2)
                        .foregroundStyle(Theme.caution)
                }
            }
        }
    }

    private func headerCell(_ title: String, width: CGFloat?, alignment: Alignment) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: alignment)
    }

    // MARK: 权重口径

    /// 维度名就是 `HealthDimension.rawValue`，匹配上才有「原始权重」可比。
    private func baseWeight(of component: ScoreComponent) -> Double? {
        guard let dimension = HealthDimension(rawValue: component.name), dimension.defaultWeight > 0 else { return nil }
        return dimension.defaultWeight
    }

    /// 有默认权重、但这次没算出来的维度。
    private func missingDimensions(of health: HealthScore) -> [HealthDimension] {
        let present = Set(health.components.map(\.name))
        return HealthDimension.allCases.filter { $0.defaultWeight > 0 && !present.contains($0.rawValue) }
    }

    /// 缺失维度的权重被等比摊到在场维度之后应有的权重。
    private func renormalizedWeight(of component: ScoreComponent, in health: HealthScore) -> Double? {
        guard let base = baseWeight(of: component) else { return nil }
        let presentSum = health.components.reduce(0) { $0 + (baseWeight(of: $1) ?? 0) }
        guard presentSum > 0 else { return nil }
        return base / presentSum
    }

    private func normalizationNotes(for health: HealthScore) -> String {
        let notes: [String] = health.components.compactMap { component in
            guard let base = baseWeight(of: component) else { return nil }
            guard abs(base - component.weight) >= 0.005 else { return nil }
            return "\(component.name) \(NumberFormat.percent(base, precision: 0))→\(NumberFormat.percent(component.weight, precision: 0))"
        }
        return notes.isEmpty ? "" : "（\(notes.joined(separator: " · "))）"
    }

    private func weightHelp(for component: ScoreComponent, in health: HealthScore) -> String {
        guard let base = baseWeight(of: component) else {
            return "该维度不在内置权重表里，直接采用评分器给出的权重。"
        }
        let text = "原始权重 \(NumberFormat.percent(base, precision: 0)) → 本次使用 \(NumberFormat.percent(component.weight, precision: 0))"
        guard let renormalized = renormalizedWeight(of: component, in: health) else { return text }
        return text + "（缺失维度等比归一后约 \(NumberFormat.percent(renormalized, precision: 0))）"
    }

    // MARK: - 优点 / 问题 / 建议

    private func overviewRow(_ health: HealthScore) -> some View {
        LazyVGrid(columns: Self.listColumns, spacing: 12) {
            itemCard(
                "优点",
                items: health.strengths,
                symbol: "plus.circle.fill",
                tint: Theme.healthy,
                subtitle: health.strengths.isEmpty ? "没有识别到突出项" : "本次评分里做得好的地方"
            )
            itemCard(
                "问题",
                items: health.issues,
                symbol: "minus.circle.fill",
                tint: Theme.danger,
                subtitle: health.issues.isEmpty ? "没有识别到风险项" : "拉低综合分的地方"
            )
            itemCard(
                "建议",
                items: health.recommendations,
                symbol: "arrow.right.circle.fill",
                tint: Theme.accent,
                subtitle: health.recommendations.isEmpty ? "没有派生建议" : "由上面的数字按规则派生"
            )
        }
    }

    private func itemCard(
        _ title: String,
        items: [String],
        symbol: String,
        tint: Color,
        subtitle: String
    ) -> some View {
        SectionCard(title, subtitle: subtitle) {
            if items.isEmpty {
                Text("本次无")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        Label(item, systemImage: symbol)
                            .font(.caption)
                            .foregroundStyle(tint)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    // MARK: - 历史趋势

    private var projectID: UUID? {
        report?.project.id ?? state.selectedProject?.id
    }

    private var historyPoints: [ScoreHistoryPoint] {
        guard let projectID else { return [] }
        return state.store.scoreHistory(for: projectID)
    }

    private func trendCard(_ health: HealthScore) -> some View {
        let points = historyPoints
        let scores = points.map { Double($0.score) }
        let average = scores.isEmpty ? 0 : scores.reduce(0, +) / Double(scores.count)
        let span = points.count >= 2
            ? (Calendar.current.dateComponents([.day], from: points.first!.date, to: points.last!.date).day ?? 0)
            : 0

        return SectionCard(
            "评分趋势",
            subtitle: "共 \(points.count) 个历史点",
            icon: "chart.line.uptrend.xyaxis"
        ) {
            if points.count >= 2 {
                HealthTrendChart(points: points, gradeBLine: Self.gradeBLine)
                    .frame(height: 150)

                HStack(spacing: 14) {
                    StatLine(label: "最高", value: String(format: "%.0f", scores.max() ?? 0))
                    StatLine(label: "最低", value: String(format: "%.0f", scores.min() ?? 0))
                    StatLine(label: "均值", value: String(format: "%.1f", average))
                    StatLine(label: "跨度", value: "\(span) 天")
                    Spacer(minLength: 4)
                }
                .font(.caption)

                if let last = points.last, last.score != health.overall {
                    Text("历史末点 \(last.score) 与本次 \(health.overall) 不一致：可能是旧记录，或本次评分尚未落盘。")
                        .font(.caption2)
                        .foregroundStyle(Theme.caution)
                }
            } else {
                EmptyStateView(
                    icon: "chart.line.uptrend.xyaxis",
                    title: "历史点不足",
                    message: "至少完成两次分析后可以看到趋势。"
                )
                .frame(maxWidth: .infinity, minHeight: 100)
            }
        }
    }
}

// MARK: - 趋势图

/// 历史点全部来自本机落盘的评分记录；这里只连线，不做任何外推。
private struct HealthTrendChart: View {
    let points: [ScoreHistoryPoint]
    let gradeBLine: Double

    var body: some View {
        Chart(points) { point in
            LineMark(
                x: .value("时间", point.date),
                y: .value("分数", Double(point.score))
            )
            .interpolationMethod(.monotone)
            .foregroundStyle(Theme.accent)
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))

            PointMark(
                x: .value("时间", point.date),
                y: .value("分数", Double(point.score))
            )
            .foregroundStyle(Theme.color(forScore: point.score))
            .symbolSize(32)

            RuleMark(y: .value("及格", gradeBLine))
                .foregroundStyle(Theme.caution.opacity(0.75))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .annotation(position: .top, alignment: .leading) {
                    Text("B 级线")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 40, 55, 70, 85, 100]) { _ in
                AxisGridLine().foregroundStyle(Theme.gridLine)
                AxisValueLabel().font(.system(size: 8))
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Theme.gridLine)
                // 固定 POSIX locale，避免中文系统下刻度被写成「月」字挤压间距。
                AxisValueLabel(format: .dateTime.locale(Locale(identifier: "en_US_POSIX")).month(.defaultDigits).day(), centered: false)
                    .font(.system(size: 8))
            }
        }
    }
}
