import Foundation

// MARK: - WS-T 时间口径 #43：提交节奏的「证据够不够」分档
//
// 冻结区 `Models/GitInsights.swift` 的 `commitsPerDay` 分母是
// `max(1, Int(跨度秒 / 86_400))`：整段历史不足 24 小时时 `Int(...)` 为 0、被兜成 1 天，
// 于是「日均」直接等于「提交总数」。本工作树实拍（main `9757722`）：
// 非合并窗口首末相隔 51,709 秒 = 14.36 小时、含合并总数 271 →
// 界面写「提交节奏稳定（日均 271.0 次）」，而 271 恰好就是提交总数本身。
// 这个退化数还往两处下游流：`WeightedHealthScorer` 拿 `>= 8` 当**加分项**，
// `HealthCurves.activity` 拿它当速率喂进曲线（80~95 分档）。
//
// `commitsPerDay` 在冻结区，**一个字节都不改**（AGENTS §3）：本文件按同一个
// `GitInsights` 里已有的字段**重算**一个浮点跨度的速率，并把「这段历史够不够说节奏」
// 做成三态交给评分器。新增的只有派生量，**没有任何落盘字段**。

/// 提交节奏这一结论的证据状态。纯派生、无 IO、可在 `Task.detached` 里算。
struct GitCadenceEvidence: Equatable, Sendable {

    enum Status: String, Sendable {
        /// 跨度够说「节奏」这个词。
        case sufficient
        /// 有首末时刻但跨度不足门槛：速率算得出，**节奏不能评**，也不配当优点。
        case shortHistory
        /// 缺首末时刻（或首末同一瞬间）：分母无定义，速率本身都不能编。
        case unknown
    }

    // MARK: - 冻结的判据（只许往紧拧，改数字要先向总工交代）

    /// 判「提交节奏稳定」所需的最小历史跨度：**7 天**。
    ///
    /// 为什么是 7 而不是别的数，三条实测/机制依据：
    /// 1. **残余量化误差**：冻结区那个整数分母 `D = max(1, Int(跨度))` 对真跨度 `S`
    ///    的高估倍数是 `S/D ∈ [1, (D+1)/D)`。`S < 1` 天时它是**无上界**的
    ///    （本仓 0.598 天 → 日均被写成 271/1，虚高 452 倍于真速率 0.6 次/天）；
    ///    `D = 6` 时仍有 17% 余量，`D = 7` 起降到 ≤ 14%，与曲线锚点间距
    ///    （1 次/天 80 分、2 次/天 90 分）同量级，不再左右结论。
    /// 2. **短于一个自然周，「稳定」这两个字没有可分辨对象**：一次连续 14 小时的
    ///    集中提交（就是本仓的形态）和「每天写一点、写了七天」在这把尺子上无法区分。
    /// 3. **与同一维度已有的那把尺子对齐**：`HealthCurves.activity` 的陈旧扣分从
    ///    `days > 7` 起算。判「样本够」也用 7 天，就不出现「三天历史既算满勤、
    ///    又还没开始扣陈旧」的空档。
    static let minimumSpanDays: Double = 7

    /// 「提交节奏稳定」这句优点的速率门槛：**沿用评分器原本就有的 8 次/天**，
    /// 本流只是在它前面加了「证据够不够」这一层，数值门槛一个字没放宽。
    static let steadyCadenceCommitsPerDay: Double = 8

    /// 样本不足时活跃度分量的**封顶值**：60 分。
    ///
    /// 为什么是 60：`HealthCurves.activity` 的风险边界是 `graded(score, 85, 65, 45, 25)`，
    /// 65 才是「低风险」下沿、85 以上才是「无风险」，而 ≥8 次/天还会再触发优点句。
    /// 60 分正好卡在低风险门槛之下，意思是「一个还没跑满一周的仓库，
    /// 最多只能拿到普通稳定仓库的水位」，92/95 那档「节奏很好」的高分它拿不到。
    /// 这是个**上限**（`min`），只会压低不会抬高。
    static let shortHistoryScoreCeiling: Double = 60

    // MARK: - 派生结果

    let status: Status
    /// 浮点跨度口径的日均提交数；`unknown` 时为 0（那是「没数」，不是「很慢」）。
    let ratePerDay: Double
    /// 首末提交之间的跨度（天）；`unknown` 时为 0。
    let spanDays: Double
    /// 分子是否与跨度同窗口。false = 只能退回含合并的 `totalCommits`，比值口径更粗。
    let numeratorSharesSpanWindow: Bool

    /// 喂给曲线/文案的速率：`unknown` 时给 0，绝不把 `Int(0.4)=0` 兜出来的退化值递下去。
    var rateForCurve: Double { status == .unknown ? 0 : ratePerDay }

    /// 「提交节奏稳定」这句优点能不能写。
    var supportsSteadyCadenceClaim: Bool { status == .sufficient }

    /// 从契约里已有的字段派生，不新增任何落盘字段。
    static func assess(_ git: GitInsights) -> GitCadenceEvidence {
        let rawSpan: Double
        if let first = git.firstCommitAt, let last = git.lastCommitAt {
            rawSpan = last.timeIntervalSince(first) / 86_400
        } else {
            rawSpan = -1
        }
        // 跨度为 0（首末同一秒）与「没有首末」是同一件事：分母无定义，不许折算成 1 天。
        guard rawSpan.isFinite, rawSpan > 0 else { return unknown }

        // 分母口径必须与跨度口径同源：首末时刻来自**已解析的非合并窗口**
        // （`ShellGitAnalyzer.makeInsights` 取的是 `commits.map(\.date)` 的最小/最大值），
        // 所以分子优先用同一窗口的 `commitsAnalyzed`。
        // 冻结区的 `commitsPerDay` 拿**含合并**的 `totalCommits` 去除这个跨度，
        // 等于把两把尺子的读数拼成一个比值（本仓 271 vs 152，凭空高 78%）。
        // 旧报告没有 `commitsAnalyzed`（缺字段 = 0）时退回 `totalCommits`，
        // 但必须把「口径更粗」这件事带出去，让 detail 里说得出依据。
        let windowNumerator = git.commitsAnalyzed
        let numerator = windowNumerator > 0 ? windowNumerator : git.totalCommits
        guard numerator > 0 else { return unknown }

        let rate = Double(numerator) / rawSpan
        return GitCadenceEvidence(status: rawSpan >= minimumSpanDays ? .sufficient : .shortHistory,
                                 ratePerDay: rate,
                                 spanDays: rawSpan,
                                 numeratorSharesSpanWindow: windowNumerator > 0)
    }

    static let unknown = GitCadenceEvidence(status: .unknown, ratePerDay: 0,
                                            spanDays: 0, numeratorSharesSpanWindow: false)

    // MARK: - 文案与降档

    /// 封顶之后的风险必须跟着降档（边界与 `HealthCurves.activity` 的
    /// `graded(score, 85, 65, 45, 25)` 同一组数；只在封顶真的压低过时才重算，
    /// 否则会把一个本来 .high 的风险"修"成 .medium，那是往好看方向改口径）。
    static func risk(afterCappingTo score: Double) -> RiskLevel {
        if score >= 85 { return .none }
        if score >= 65 { return .low }
        if score >= 45 { return .medium }
        if score >= 25 { return .high }
        return .critical
    }

    /// 写进分量 detail 的口径注记：先说结论（样本不足）、再说跨度、最后说封顶值。
    ///
    /// ⚠ **不带括号、也不与 detail 相加**：括号由 `HealthCurves.noted` 那一族整句键给出。
    /// 这里要是写成 `detail + "（中文）"`，拼完的整串查不中任何键，
    /// 英文态会长成半英半中（P58 收的就是这一族）。
    var shortHistoryNote: String {
        HealthCurves.joined([
            localizedFormat("历史仅 %1$@ 天 < %2$@ 天门槛，样本不足不评估节奏，本维度封顶 %3$@ 分",
                            Self.fixed(spanDays), Self.fixed(Self.minimumSpanDays),
                            Self.fixed(Self.shortHistoryScoreCeiling)),
            numeratorSharesSpanWindow ? "" : localizedCopy("速率分子按含合并总数折算")
        ])
    }

    var unknownNote: String {
        localizedCopy("首末提交时间缺失或同一瞬间，日均分母无定义，速率按 0 计")
    }

    /// 定点格式化（一位小数，尾随 0 省掉）：跟随 `ScoreCurves.decimal` 的立场不依赖 Locale，
    /// 免得系统语言换成逗号小数点后 detail 里的数读不出。
    static func fixed(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        let tenths = Int((Swift.abs(value) * 10).rounded())
        let sign = value < 0 ? "-" : ""
        guard tenths % 10 != 0 else { return sign + String(tenths / 10) }
        return sign + String(tenths / 10) + "." + String(tenths % 10)
    }
}
