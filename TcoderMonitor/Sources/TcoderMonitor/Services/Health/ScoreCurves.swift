import Foundation

/// 健康评分标定曲线：每个维度的分数都由显式锚点线性折算，保证「分数可解释、依据可对外承诺」。
/// 纯函数、无 I/O、无状态；加权与文案派生由调用方（`WeightedHealthScorer`）负责。
///
/// 接线状态（WS-C 记录）：本文件在产线评分路径上 —— `WeightedHealthScorer.evaluate(...)`
/// 的 9 个维度全部调用这里的曲线（`e676fad` 起），`HealthScoreTests` A~G 是它的回归契约。
/// 锚点表是产品规约点名要的那份（重复度 12.5%→75、注释 2%~15% 最佳、一人包揽 70%+ 重扣、
/// narrative 40~80 字）。改锚点等于改对外承诺，必须连测试一起改。
///
/// ## 本文件的分片（收官轮 WS-X6，2026-09-21）
///
/// 本文件曾被自己的 App 扫成「巨大文件」（>400 行）。修法是**按维度族把 `HealthCurves` 的
/// 函数切到同目录两个分片文件**，用 `extension HealthCurves` 拼回同一个类型：
/// - `ScoreCurvesCode.swift` —— 复杂度 / 重复度 / 代码质量 / 注释与可维护性
/// - `ScoreCurvesTeamRuntime.swift` —— 提交活跃度 / 协作分布 / 运行稳定性 / 依赖健康
///
/// **锚点数字、detail 文案、`VulnerabilityEvidence` 判据、`smallSampleCodeLines` 一个字符都没改**，
/// 搬的只是「哪个函数住在哪个文件」。留在这里的是：证据三态判定、插值原语、标定常量、
/// 总评 narrative、以及所有分片共用的格式化与分档工具。
/// 下面那六个工具原先是 `private`：`private` 只到文件作用域，跨文件的同类型扩展看不见它们，
/// 而把 `joined` / `decimal` 抄第二份正是本仓记过无数次的死法（两份口径并存时错的那套常在喂数据）。
/// 所以它们放成了 internal —— **不要改回 private，那会让两个分片文件编不过。**

/// 漏洞核对的证据状态。依赖健康这一维最容易虚报：
/// 「没查过漏洞库」和「查了、确实零命中」在数据上长得一样（都是 0 个漏洞），
/// 但只有后者配计分。与 `.testing` 的 `coverage.hasData`、
/// `.complexity` 的「无函数证据不参与评分」是同一条原则：**没有证据 ≠ 好证据**。
///
/// 判据一律走契约里的派生态 `DependencyReport.hasVulnerabilityCoverage`，
/// 不去猜 `networkLookupNote` 的文案。
enum VulnerabilityEvidence: String, Sendable, Equatable {
    /// 已核对且零命中，或内置规则已有命中 —— 结论可信，参与评分。
    case verified
    /// 压根没核对（未联网且内置规则无命中）—— 本维度不参与评分。
    case unchecked
    /// 尝试过但没查完（部分包查询失败）—— 零命中时不敢说干净，不参与评分。
    case degraded

    /// 从服务层产出判定证据状态。纯函数，便于单测钉住三种输入。
    static func classify(_ report: DependencyReport) -> VulnerabilityEvidence {
        // 已有正向发现时绝不缺席：把已知漏洞整个维度摘掉会让带 CVE 的仓库分数反而变高。
        if report.vulnerableCount > 0 { return .verified }
        guard report.hasVulnerabilityCoverage else { return .unchecked }
        return report.networkLookupNote.contains("失败") ? .degraded : .verified
    }
}

struct CurveResult: Sendable, Equatable {
    var score: Double
    var detail: String
    var risk: RiskLevel
}

enum ScoreCurve {
    /// 唯一的插值原语：所有分数只能由锚点表插值得出，便于逐条标定与回归测试。
    static func piecewise(_ value: Double, through points: [(x: Double, score: Double)]) -> Double {
        guard value.isFinite else { return 0 }
        let anchors = points.filter { $0.x.isFinite && $0.score.isFinite }
        guard let first = anchors.first, let last = anchors.last else { return 0 }
        if value <= first.x { return first.score }
        if value >= last.x { return last.score }
        for index in 1..<anchors.count {
            let high = anchors[index]
            guard value <= high.x else { continue }
            let low = anchors[index - 1]
            let span = high.x - low.x
            guard span > 0 else { return high.score }
            let t = (value - low.x) / span
            return low.score + (high.score - low.score) * t
        }
        return last.score
    }

    static func clamped(_ value: Double, _ low: Double = 0, _ high: Double = 100) -> Double {
        guard low.isFinite, high.isFinite else { return 0 }
        let lower = Swift.min(low, high)
        let upper = Swift.max(low, high)
        guard value.isFinite else { return lower }
        if value <= lower { return lower }
        if value >= upper { return upper }
        return value
    }
}

enum HealthCurves {

    // MARK: - 标定常量（曲线共用，锚点之外唯一住在这里的数）

    /// 曲线自己承认的置信度下限：低于这个代码行数，重复率只能按小样本估计，detail 会标「置信度低」。
    /// 评分器引用同一个常量来决定「重复代码率低」这句优点能不能写 —— 两处必须同源，防止各写一个数。
    /// 消费方 `HealthCurves.duplication` 现在住在 `ScoreCurvesCode.swift`（分片只搬函数体，数没动）。
    static let smallSampleCodeLines = 200

    // MARK: - 总评

    /// 由各分量真实分数拼装的一句总评，长度收敛到 40~80 字。
    static func narrative(overall: Int, components: [(name: String, score: Int)]) -> String {
        let score = Int(ScoreCurve.clamped(Double(overall), 0, 100).rounded())
        let grade = HealthGrade(score: score).rawValue
        let ranked = components.sorted {
            if $0.score != $1.score { return $0.score < $1.score }
            return $0.name < $1.name
        }
        var candidate = "综合 \(score) 分（\(grade) 级）。"
        switch ranked.count {
        case 0:
            candidate += "当前没有任何维度可供评估，评分依据缺失，建议先完成代码分析与 Git 采集，再来查看总分。"
        case 1:
            let only = ranked[0]
            candidate += "目前只有\(only.name)（\(only.score) 分）这一个维度有可用数据，它同时也是当前最低项，建议优先\(advice(for: only.name))。"
        case 2:
            let low = ranked[0]
            let high = ranked[1]
            candidate += "主要拖累来自\(low.name)（\(low.score) 分），\(high.name)（\(high.score) 分）是目前相对最好的一项；建议优先\(advice(for: low.name))。"
        default:
            let first = ranked[0]
            let second = ranked[1]
            let best = ranked[ranked.count - 1]
            candidate += "主要拖累来自\(first.name)（\(first.score) 分）与\(second.name)（\(second.score) 分）；"
            candidate += "\(best.name)（\(best.score) 分）是当前最稳的一项。建议优先\(advice(for: first.name))。"
        }
        return fittedNarrative(candidate)
    }

    /// 长度收敛：超 80 字按子句边界丢弃，不足 40 字补固定后缀，最后再兜底截断。
    private static func fittedNarrative(_ candidate: String) -> String {
        var clauses: [String] = []
        var current = ""
        for character in candidate {
            current.append(character)
            if character == "。" || character == "；" || character == "，" {
                clauses.append(current)
                current = ""
            }
        }
        if !current.isEmpty { clauses.append(current) }

        var result = ""
        for clause in clauses {
            if result.count + clause.count > 80 { break }
            result += clause
        }
        if result.isEmpty { result = String(Array(candidate).prefix(79)) }
        if let last = result.last, last == "，" || last == "；" || last == "、" {
            result.removeLast()
            result.append("。")
        }
        if !result.hasSuffix("。") { result += "。" }

        let pads = ["其余维度处于可接受区间。", "建议保持观察，待各维度数据补齐后复核。"]
        var padIndex = 0
        while result.count < 40, padIndex < pads.count, result.count + pads[padIndex].count <= 80 {
            result += pads[padIndex]
            padIndex += 1
        }

        let characters = Array(result)
        if characters.count > 80 { return String(characters.prefix(79)) + "。" }
        return result
    }

    private static func advice(for dimensionName: String) -> String {
        switch dimensionName {
        case HealthDimension.complexity.rawValue: return "拆解高复杂度函数"
        case HealthDimension.duplication.rawValue: return "抽取重复代码块"
        case HealthDimension.codeQuality.rawValue: return "拆分超大文件与超长函数"
        case HealthDimension.documentation.rawValue: return "补齐关键注释并清理待办标记"
        case HealthDimension.activity.rawValue: return "保持稳定提交节奏"
        case HealthDimension.busFactor.rawValue: return "分摊单点作者的改动评审"
        case HealthDimension.stability.rawValue: return "排查崩溃与高频错误"
        case HealthDimension.dependencies.rawValue: return "升级有已知漏洞的依赖"
        case HealthDimension.testing.rawValue: return "补充自动化测试"
        default: return "处理「\(dimensionName)」"
        }
    }

    // MARK: - 内部工具（分片共用：见文件头「不要改回 private」）

    static func graded(_ score: Double, _ noneAt: Double, _ lowAt: Double, _ mediumAt: Double, _ highAt: Double) -> RiskLevel {
        if score >= noneAt { return .none }
        if score >= lowAt { return .low }
        if score >= mediumAt { return .medium }
        if score >= highAt { return .high }
        return .critical
    }

    /// 文案预算 60 字：核心数字段在前，放不下的段直接舍弃，宁可少说也不截断数字或换行。
    static func joined(_ segments: [String]) -> String {
        var result = ""
        for segment in segments {
            if segment.isEmpty { continue }
            let candidate = result.isEmpty ? segment : result + "，" + segment
            if candidate.count > 60 { continue }
            result = candidate
        }
        return result.isEmpty ? bounded(segments.first ?? "") : result
    }

    private static func bounded(_ text: String) -> String {
        let characters = Array(text)
        guard characters.count > 60 else { return text }
        return String(characters.prefix(60))
    }

    /// 手写定点格式化，不走 Locale，保证任何系统语言下 detail 里的数字都一致。
    static func decimal(_ value: Double, _ digits: Int = 1) -> String {
        guard value.isFinite else { return "0" }
        let fractionDigits = Swift.max(0, Swift.min(4, digits))
        let boundedValue = Swift.max(-9_999_999_999.0, Swift.min(9_999_999_999.0, value))
        let scale = pow(10.0, Double(fractionDigits))
        let negative = boundedValue < 0
        var text = String(Int((Swift.abs(boundedValue) * scale).rounded()))
        if fractionDigits > 0 {
            while text.count <= fractionDigits { text = "0" + text }
            let characters = Array(text)
            let split = characters.count - fractionDigits
            var fraction = String(characters[split...])
            while fraction.hasSuffix("0") { fraction.removeLast() }
            text = fraction.isEmpty
                ? String(characters[0..<split])
                : String(characters[0..<split]) + "." + fraction
        }
        return (negative && text != "0") ? "-" + text : text
    }

    static func percent(_ ratio: Double, _ digits: Int = 1) -> String {
        decimal(Swift.max(0, ratio) * 100, digits) + "%"
    }

    /// 整数读数**必须与全站同一把尺子**：以前这里是 `String(value)`，
    /// 于是健康页详情写"源码 63909 行"，而代码规模/复杂度风险两页写"63,909" ——
    /// 同一个量两套记法（批次 P5 实拍点名）。收成 `NumberFormat.grouped` 的薄包装。
    static func whole(_ value: Int) -> String {
        NumberFormat.grouped(Swift.max(0, value))
    }
}
