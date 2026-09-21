import SwiftUI

// MARK: - 分量表的算术（纯函数，单测直接钉）
//
// 评分器给的 `weight` 可能是原始权重、也可能已归一，两者都要能落地：
// 缺失维度不参与，所以在场维度的权重按 Σ 归一 —— 那才是综合分真正乘的数。
// 这套口径以前散在视图里，现在集中成一处，页面只负责画。

struct ScoreRow: Identifiable {
    let component: ScoreComponent
    /// 内置权重表里的原始权重（自定义维度为 nil）。
    let baseWeight: Double?
    /// 本次实际乘数（归一化后）。
    let effectiveWeight: Double
    let contribution: Double

    var id: String { component.name }
    var score: Int { component.score }
    var name: String { DimensionDisplay.name(component.name) }
    /// 这一维度满分可得多少。
    var fullMarks: Double { effectiveWeight * 100 }
    /// 它把综合分拖下去多少。
    var lostPoints: Double { effectiveWeight * Double(100 - component.score) }
}

enum HealthBreakdown {
    /// 维度名就是 `HealthDimension.rawValue`，匹配上才有「原始权重」可比。
    static func baseWeight(of component: ScoreComponent) -> Double? {
        guard let dimension = HealthDimension(rawValue: component.name), dimension.defaultWeight > 0 else { return nil }
        return dimension.defaultWeight
    }

    static func effectiveWeight(_ component: ScoreComponent) -> Double {
        component.weight > 0 ? component.weight : (baseWeight(of: component) ?? 0)
    }

    /// 按拖累程度升序：贡献最低者在前，和 Xcode / Instruments 的排序习惯一致。
    static func rows(for health: HealthScore) -> [ScoreRow] {
        let present = health.components.reduce(0) { $0 + effectiveWeight($1) }
        guard present > 0 else { return [] }
        return health.components.map { component in
            let weight = effectiveWeight(component) / present
            return ScoreRow(component: component,
                            baseWeight: baseWeight(of: component),
                            effectiveWeight: weight,
                            contribution: Double(component.score) * weight)
        }.sorted { lhs, rhs in
            if abs(lhs.contribution - rhs.contribution) > 0.001 { return lhs.contribution < rhs.contribution }
            return lhs.score < rhs.score
        }
    }

    static func sumOfContributions(_ rows: [ScoreRow]) -> Double {
        rows.reduce(0) { $0 + $1.contribution }
    }

    /// 分量之和与综合分对不上（>1.5）说明归一化或取整口径不同，必须写出来而不是假装能加出来。
    static func isSumConsistent(_ sum: Double, with overall: Int) -> Bool {
        abs(sum - Double(overall)) <= 1.5
    }

    /// 有默认权重、但这次没算出来的维度。
    static func missingDimensions(of health: HealthScore) -> [HealthDimension] {
        let present = Set(health.components.map(\.name))
        return HealthDimension.allCases.filter { $0.defaultWeight > 0 && !present.contains($0.rawValue) }
    }

    /// 内置权重表里所有可计分维度的合计。**实测是 1.10 而不是 1.00**，
    /// 所以「九维全在场」时每个乘数也已经被整体折算过 —— 不能拿它当「没摊分」的证据。
    static var tableWeightSum: Double {
        HealthDimension.allCases.reduce(0) { $0 + $1.defaultWeight }
    }

    /// 本次在场维度的表权重合计（缺席的那些不在里面）。
    static func presentTableSum(_ rows: [ScoreRow]) -> Double {
        rows.compactMap(\.baseWeight).reduce(0, +)
    }

    /// 「本次乘数与设计占比不一致」的**原因**，判不出来就说判不出来。
    ///
    /// 这里曾是总工点出的那条矛盾：`weightHelp` 无条件写「缺失维度的权重已摊到在场维度」，
    /// 而同一页另一句又写「权重未做摊分」——两句在 `defaultWeight` 合计 110% 的事实下
    /// 都不必然成立。现在文案由下面这个枚举驱动，每种原因各说各的话。
    static func shiftCause(for row: ScoreRow, rows: [ScoreRow], missingCount: Int) -> WeightShiftCause {
        guard let base = row.baseWeight else { return .scorerOnly }
        let tableSum = Self.tableWeightSum
        let presentSum = Self.presentTableSum(rows)
        guard tableSum > 0, presentSum > 0 else { return .unexplained }

        let asIntended = base / tableSum          // 无缺席时应有的占比（含整体折算）
        let renormalized = base / presentSum      // 缺席摊分后应有的占比
        let eps = Self.shareTolerance

        let tableNormalized = abs(base - row.effectiveWeight) > eps
        let matchesAsIntended = abs(asIntended - row.effectiveWeight) <= eps
        let matchesRenormalized = abs(renormalized - row.effectiveWeight) <= eps

        if missingCount > 0 { return matchesRenormalized ? .missingDimensions : .unexplained }
        if matchesAsIntended { return tableNormalized ? .tableNormalization : .asIntended }
        return .unexplained
    }

    /// 权重格 hover 的唯一文案出口。每句只陈述这一行能证实的部分。
    static func weightTooltip(for row: ScoreRow, rows: [ScoreRow], missingCount: Int) -> String {
        let published = NumberFormat.percent(row.effectiveWeight, precision: 1)
        // 「表里没有这一档」在两个分支里是同一句话（无 `baseWeight` / 有 `baseWeight`
        // 但判据归因到 scorerOnly），写两遍就有两份改漏的机会。
        let notInTable = "该维度不在内置权重表里，直接采用评分器给出的权重 \(published)。"
        guard let base = row.baseWeight else { return notInTable }
        let raw = NumberFormat.percent(base, precision: 1)
        let tableSumText = NumberFormat.percent(Self.tableWeightSum, precision: 0)
        switch shiftCause(for: row, rows: rows, missingCount: missingCount) {
        case .scorerOnly:
            return notInTable
        case .asIntended:
            return "本次乘数 \(published)，与内置表原始权重 \(raw) 一致。"
        case .tableNormalization:
            return "内置权重表合计 \(tableSumText)，评分器发布前整体折算：原始 \(raw) → 本次乘数 \(published)。本次没有维度缺席。"
        case .missingDimensions:
            // 两个合计数一起给：在场合计里已经含着「表本身不到 100%」这一层，不再为它单开一个分支。
            return "\(missingCount) 个维度缺席，份额按在场维度等比摊入：原始 \(raw) → 本次乘数 \(published)"
                + "（在场维度表权重合计 \(NumberFormat.percent(Self.presentTableSum(rows), precision: 0))，全表合计 \(tableSumText)）。"
        case .unexplained:
            return "本次乘数 \(published) 与内置表口径（原始 \(raw)、表合计 \(tableSumText)、缺席 \(missingCount) 项）对不上，界面以评分器发布值为准。"
        }
    }

    /// 卡底那行总结。措辞随「有没有缺席」「表合计是不是 100%」两个事实变，
    /// 不再固定宣称任何一种。
    static func normalizationSummary(rows: [ScoreRow], missingCount: Int) -> String {
        let tableSum = Self.tableWeightSum
        let notes = shiftNotes(rows, missingCount: missingCount)
        if missingCount == 0 {
            let head = "输入覆盖全部 \(rows.count) 个可计分维度，没有维度缺席"
            if abs(tableSum - 1) > shareTolerance {
                return head + "；但内置权重表合计 \(NumberFormat.percent(tableSum, precision: 0))，评分器发布前已整体折算，故各乘数不等于表内原始值。"
            }
            return head + "；权重未做摊分，乘数即表内原始值。"
        }
        return "缺失 \(missingCount) 个维度不参与计分、也不按 0 计入，其份额已按在场维度等比摊入。"
            + (notes.isEmpty ? "" : "（\(notes.joined(separator: " · "))）")
    }

    /// 折算说明列表：只列乘数确实偏离表内原始值的维度。
    static func shiftNotes(_ rows: [ScoreRow], missingCount: Int) -> [String] {
        rows.compactMap { row in
            guard let base = row.baseWeight,
                  abs(base - row.effectiveWeight) > shareTolerance else { return nil }
            return "\(row.name) \(NumberFormat.percent(base, precision: 0))→\(NumberFormat.percent(row.effectiveWeight, precision: 0))"
        }
    }

    /// 占比比对容差：0.5 个百分点。小于它的差异不值得在文案里单独归因。
    static let shareTolerance = 0.005

    /// 权列表头的口径说明。**只陈述对整列恒成立的不变量**。
    ///
    /// 上一轮这里写死了「缺失维度的权重已摊到在场维度」——列头是整列静态文案，
    /// 而偏移原因逐行不同（九维全在场时真实原因是表合计 110% 的整体折算，与缺席无关），
    /// 所以那种写法必然在某些场景下说谎。原因交给每行自己的 `weightTooltip`。
    static let weightColumnHelp = "本次实际乘数：在场维度的乘数合计恒为 100%，故 Σ（得分 × 乘数）可复现综合分。与内置表原始值不一致的原因见各行提示。"
}

/// `weightTooltip` 的分支依据。每种原因一句不同的话，避免「无条件宣称」。
enum WeightShiftCause: Hashable {
    case scorerOnly
    case asIntended
    case tableNormalization
    case missingDimensions
    case unexplained
}

// MARK: - 显示名映射

/// 模型里的 `HealthDimension.duplication.rawValue` 是「重复度」（冻结契约），
/// 规范词是「重复代码率」——所以在视图层建映射，不动模型（《40 WS-H》§13.2）。
enum DimensionDisplay {
    static let overrides: [String: String] = ["重复度": "重复代码率"]

    static func name(_ raw: String) -> String { overrides[raw] ?? raw }
    static func name(_ dimension: HealthDimension) -> String { name(dimension.rawValue) }
}

// MARK: - 缺失维度的原因

enum MissingDimensionReason {
    /// 维度 ↔ 产出它的分析器中文名（与 `AppState.failedSections` 写入的字面量一致）。
    static let analyzerLabel: [HealthDimension: String] = [
        .codeQuality: "代码扫描", .complexity: "代码扫描", .duplication: "代码扫描", .documentation: "代码扫描",
        .activity: "Git 分析", .busFactor: "Git 分析",
        .stability: "错误日志",
        .dependencies: "依赖分析",
        .testing: "测试覆盖率",
    ]

    /// 未评分**不参与也不得按 0 显示**，所以这里给的是原因，不是一个分数（验收点 6）。
    ///
    /// 拆成三段不是为了凑复杂度数（本 App 自扫点名本函数 CC 21）：
    /// 「扫描失败」「还没扫」「扫了但这一维没产出」本来就是三类原因，
    /// 混在一个函数里读，谁也看不出界面为什么是这句话。
    static func text(for dimension: HealthDimension, report: ProjectReport?) -> String {
        guard let analyzer = analyzerLabel[dimension] else {
            return "该维度不在内置口径里，本次未参与计分。"
        }
        if let absent = scanAbsenceReason(analyzer: analyzer, report: report) { return absent }
        return dimensionAbsenceReason(dimension, analyzer: analyzer, report: report)
            ?? "「\(analyzer)」完成但该分量未产出。"
    }

    /// 整体缺席：整次扫描没跑、或这一维所属的分析器报过失败。
    private static func scanAbsenceReason(analyzer: String, report: ProjectReport?) -> String? {
        if let report, report.failedSections.contains(analyzer) {
            return "上次扫描「\(analyzer)」失败，本维度没有输入。"
        }
        if report == nil { return "还没有扫描结果，「\(analyzer)」未运行。" }
        return nil
    }

    /// 逐维判据：扫过了，但这一维缺哪样输入。返回 nil = 输入齐了却没算出分量（走兜底句）。
    /// 逐维判据：扫过了，但这一维缺哪样输入。返回 nil = 输入齐了却没算出分量（走兜底句）。
    ///
    /// 拆的理由是机械的：原来一个 switch 里塞五段三元加一个 guard，被本 App 自扫点名 CC 16
    /// ——它自己正是「缺证据不给分」那条判据的守门人，本身不该是热点。
    /// 每维的措辞搬进各自的小函数，**文案与判据一字未动**。
    private static func dimensionAbsenceReason(_ dimension: HealthDimension, analyzer: String,
                                               report: ProjectReport?) -> String? {
        switch dimension {
        case .codeQuality, .complexity, .duplication, .documentation:
            return codeAbsence(analyzer: analyzer, code: report?.code)
        case .activity, .busFactor:
            return gitAbsence(git: report?.git)
        case .stability:
            return stabilityAbsence(logs: report?.logs)
        case .dependencies:
            return dependencyAbsence(dependencies: report?.dependencies)
        case .testing:
            return testingAbsence(coverage: report?.coverage)
        }
    }

    private static func codeAbsence(analyzer: String, code: CodeMetrics?) -> String? {
        code == nil ? "「\(analyzer)」没有产出代码指标。" : nil
    }

    private static func gitAbsence(git: GitInsights?) -> String? {
        git == nil ? "该目录不是 Git 仓库，或未取到提交历史。" : nil
    }

    /// 唯一要分两档的一维：`logs == nil`（没分析过）与「分析了但一行没读到」是两件事，
    /// 合成一句就把输入状态弄丢了。
    private static func stabilityAbsence(logs: LogSummary?) -> String? {
        guard let logs else { return "尚未分析日志。" }
        return logs.hasData ? nil : "未发现可读的日志文件。"
    }

    private static func dependencyAbsence(dependencies: DependencyReport?) -> String? {
        dependencies == nil ? "未识别到依赖清单。" : nil
    }

    private static func testingAbsence(coverage: CoverageMetrics?) -> String? {
        coverage?.hasData == true ? nil : "该项目没有产出覆盖率报告，不参与计分。"
    }

    private static func coverageHasData(_ report: ProjectReport?) -> Bool {
        report?.coverage?.hasData == true
    }
}

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
                if !HealthBreakdown.isSumConsistent(sum, with: health.overall) {
                    NoteLine("分量合计 \(Live.fixed(sum, digits: 1)) 与综合分 \(health.overall) 有出入，通常是评分器的归一化或取整口径不同。",
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
