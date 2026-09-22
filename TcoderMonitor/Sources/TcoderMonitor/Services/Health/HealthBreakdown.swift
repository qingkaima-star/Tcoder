import Foundation

// MARK: - 分量表的算术、显示名映射、缺席原因（自 `Views/Health/HealthComponentTable.swift` 整块搬来）
//
// 为什么搬：这三段是**判据与口径**，不是画法，却被住在 View 层 —— 于是无头 CLI
// 读不到"哪些维度缺席、为什么缺席"，只能自己再造一份原因表（= 第二把尺子，本仓明令禁止）。
// 同时 `Design/DataTable.swift` 的权重列头一直在反向引用 `HealthBreakdown.weightColumnHelp`
// （Design → Views），搬进 Services 之后方向才是对的。
// 界面与 CLI 从此共用同一份：`CLIScoreText` 只调这里的公开成员，一个字都不重写。
//
// 搬动是逐字节的，判据与文案一字未改；两处例外见提交说明：
// 删掉一个零调用的私有函数 `coverageHasData`，并去掉一行重复两遍的文档注释。

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

    /// 排序键 = `contribution`（得分 × 本次归一乘数）**升序**，贡献最低者在前。
    ///
    /// ⚠ 这条**不是**按 `lostPoints`（乘数 ×（100 − 得分））排的，两个键在低权重维度上会分叉：
    /// 权重 0.05 / 得分 20 只拖 4 分，权重 0.30 / 得分 60 拖 12 分，前者却排在前面。
    /// 上一轮这里与页面上的副标题都写成"按拖累程度排序"，等于给一个不是拖累的键起了拖累的名字
    /// （台账 RD-28）。修法选的是**改名字**而不是改键：换键会同时改到这张表的既有读法，
    /// 而"哪一维拖得最多"本来就在贡献列的提示里逐行给着，不需要靠行序去暗示。
    /// 界面副标题与这里必须由同一条守卫盯着（`ScoreWordingTests`）。
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

    /// Git 那一路的缺席要分**三档**，合成一句就把输入状态弄丢了：
    /// ① `git == nil` = 不是仓库 / 没取到历史；② 是仓库但一笔提交都没有；
    /// ③ 有提交，但非合并口径一笔都没有 ⇒ 作者分布没有总体。
    /// 第③档以前落到兜底句「「Git 分析」完成但该分量未产出」，读分的人看不出
    /// "这一维为什么不参与计分"（工单 R9 靶子 1 要求上屏能看出这件事）。
    /// ⚠ 这句只对「协作分布」成立：活跃度那一维的缺席条件是 `totalCommits == 0`，
    /// 走到第③档时它已经在计分、不会来问原因（`WeightedHealthScorer.busFactorOutcome`）。
    private static func gitAbsence(git: GitInsights?) -> String? {
        guard let git else { return "该目录不是 Git 仓库，或未取到提交历史。" }
        guard git.totalCommits > 0 else { return "该仓库没有任何提交，Git 两维都没有输入。" }
        guard git.authorBasisCommits > 0 else {
            return "含合并共 \(NumberFormat.grouped(git.totalCommits)) 笔提交里没有一笔非合并提交，"
                + "作者分布没有可算的总体，本维度不参与计分。"
        }
        return nil
    }

    /// 唯一要分**三档**的一维：`logs == nil`（没分析过）、分析了但一行没读到、
    /// 以及"列到了文件却一行都没读出来"是三件事，合成一句就把输入状态弄丢了。
    /// ⚠ `hasData` 自己只看"有没有文件"（`totalLinesScanned > 0 || !scannedFiles.isEmpty`），
    /// 所以第三种形状下它会说"有数据"，而评分器按 `totalLinesScanned > 0` 判的是"没有证据"——
    /// 这一档要是落到兜底句，界面就变成"扫过了但没说为什么没分"。
    private static func stabilityAbsence(logs: LogSummary?) -> String? {
        guard let logs else { return "尚未分析日志。" }
        guard logs.hasData else { return "未发现可读的日志文件。" }
        guard logs.totalLinesScanned > 0 else {
            return "列到 \(NumberFormat.grouped(logs.scannedFiles.count)) 个日志文件，"
                + "但一行都没读出来（空文件 / 编码不认识 / 读取失败），本维度不参与计分。"
        }
        return nil
    }

    private static func dependencyAbsence(dependencies: DependencyReport?) -> String? {
        dependencies == nil ? "未识别到依赖清单。" : nil
    }

    /// 覆盖率这一维要分**三档**，合成一句就把输入状态弄丢了：
    /// `nil` = 这一趟根本没跑过覆盖率分析；跑过了但 `scannedFileCount == 0` = 真的没有报告文件；
    /// 跑过了、也扫到了报告文件、`hasData` 却是 false = **报告读不出可用数字**
    /// （格式不认识 / 空文件 / 超过 20 MiB 上限 / 不是 UTF-8）。
    /// 原来三档共用一句「该项目没有产出覆盖率报告」，等于拿"没读到"冒充"没有"
    /// （功能真实性清单 §S2：缺证据不得冒充结论）。
    static func testingAbsence(coverage: CoverageMetrics?) -> String? {
        guard let coverage else { return "尚未分析覆盖率报告，不参与计分。" }
        if coverage.hasData { return nil }
        let base: String
        if coverage.scannedFileCount > 0 {
            base = "扫到 \(NumberFormat.grouped(coverage.scannedFileCount)) 个覆盖率报告文件，"
                + "但里面没有可用的行覆盖数字，不参与计分。"
        } else {
            base = "该项目没有产出覆盖率报告，不参与计分。"
        }
        // 「没找到」与「没看到」是两件事：有目录读不动时，"没有产出报告"这句站不住，
        // 必须把扫描面不完整这件事一起说出来（`unreadableDirectoryCount == 0` 才是一句真话，
        // 而 `nil` = 那次分析根本没统计过，也不许替它下结论）。
        // 披露口径只有一套：§6.1 那几格（`unmeasuredScope` / `droppedByCap`）由
        // `CoverageDisplayShape` 一处生产，这里只负责接在结论后面。
        // 旧报告没有那几格（`nil` = 没统计过，**不许**替它下结论）⇒ 退回 `unreadableDirectoryCount` 那句。
        if let disclosure = coverage.displayDisclosureText {
            return base + disclosure + "上面的结论只覆盖看得见的部分。"
        }
        guard let unreadable = coverage.unreadableDirectoryCount, unreadable > 0 else { return base }
        return base + "另有 \(NumberFormat.grouped(unreadable)) 个目录没能读取（权限或已消失），"
            + "上面的结论只覆盖读得动的部分。"
    }

}
