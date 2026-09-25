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
/// ## RD-13（2026-09-22，R3）：判据从中文文案换成结构化账本
///
/// 旧实现最后一行是 `report.networkLookupNote.contains("失败") ? .degraded : .verified`
/// —— 用一句**给人看的中文里有没有"失败"两个字**决定业务状态。它有三个必然的坏结局：
///   ① 文案改一个字（或被补进别的句子）判定就翻；`DependencySnapshot.asOfText` 的注释
///      早就承认"这句话会被拼进那个 note，所以措辞里刻意不出现「失败」" —— 那是让文案
///      给判定让路，方向完全反了；
///   ② 英文态整句换词，判定直接失效；
///   ③ "OSV 不支持该生态 / 版本没解析出来 / 预算没覆盖到"这些**同样不该给绿灯**的结局
///      句子里不含"失败"，于是全被判成 `.verified`。
/// 现在只读 `DependencyEvidence` 的结构化状态。**保守方向一条不许松**：
/// 原来判 `.degraded` 的样本改完仍不许变 `.verified`（由
/// `DependencyEvidenceTests.testStructuredStatesKeepTheConservativeDirection` 钉住）。
enum VulnerabilityEvidence: String, Sendable, Equatable {
    /// 已核对且零命中，或内置规则已有命中 —— 结论可信，参与评分。
    case verified
    /// 压根没核对（未联网且内置规则无命中）—— 本维度不参与评分。
    case unchecked
    /// 尝试过但没查完（失败 / 版本未解析 / 生态不支持 / 预算未覆盖，任意一种）——
    /// 零命中时不敢说干净，不参与评分。
    case degraded

    /// 从服务层产出判定证据状态。判据是**逐条落账后的核对状态**，不是任何一句中文说明。
    static func classify(_ report: DependencyReport) -> VulnerabilityEvidence {
        // 已有正向发现时绝不缺席：把已知漏洞整个维度摘掉会让带 CVE 的仓库分数反而变高。
        if report.vulnerableCount > 0 { return .verified }
        let ledger = DependencyEvidence.ledger(for: report)
        guard ledger.totalCount > 0 else { return .unchecked }
        let counts = ledger.vulnerabilityStateCounts
        let checked = counts[.checked] ?? 0
        // RD-73：「每一条都核对成了没有」只由 `DependencyEvidence.vulnerabilityCoverage` 判一次。
        // 这里原先自己写了一遍 `checked == ledger.totalCount` —— 与那把闸门**同一件事实的第二把尺子**，
        // 而且因为换了个局部变量的写法，`DependencyGateUniquenessTests` 按字面扫**看不见它**。
        // ⚠ 只搬"全覆盖"这一支：`.degraded` 与 `.unchecked` 的分界是**另一根轴**
        //   （这一路到底发没发起过），三档覆盖度里放不下它，不许为了"收成一个家"把保守方向折掉。
        // 两把尺子今天算的是同一个数（`isCovered` 就是 `== .checked`），所以这次改动**不动任何分数**。
        if DependencyEvidence.vulnerabilityCoverage(ledger).isFull { return .verified }
        // `.degraded` 与 `.unchecked` 的分界是"这一路发没发起过"：
        // 有失败、有被预算挡在门外的 ⇒ 发起了但没走到底 ⇒ degraded（旧文案判据正是这一支，
        // 保守方向不许松）；一条都没发起（全 notAttempted / 版本未解析 / 生态不支持）才是 unchecked。
        let attemptedButIncomplete = (counts[.failed] ?? 0) + (counts[.budgetExcluded] ?? 0) > 0
        // 旧报告（R3 之前落盘的那些，没有逐条状态可解）只留了一句 `networkLookupPerformed = true`：
        // 它**发起过**却收不齐账 ⇒ 只能说"没查完"，永远不许升成 `.verified`。
        // 这一支比被删掉的文案判据更保守：旧实现在这里读 note 有没有"失败"两个字，
        // note 不含就发绿；现在不含也只到 degraded。
        let attemptedWithoutAccounting = report.networkLookupPerformed
            && ledger.records.allSatisfy { $0.vulnerabilityState == .notAttempted }
        return checked > 0 || attemptedButIncomplete || attemptedWithoutAccounting ? .degraded : .unchecked
    }

    /// `.degraded` 到底是哪一种"没查完"——给建议文案用，同样只读结构化计数。
    static func degradationReasons(_ report: DependencyReport) -> [String] {
        let ledger = DependencyEvidence.ledger(for: report)
        let counts = ledger.vulnerabilityStateCounts
        var reasons: [String] = []
        for (state, label) in [(DependencyCheckState.failed, localizedCopy("查询失败")),
                               (.versionUnresolved, localizedCopy("版本未解析")),
                               (.ecosystemUnsupported, localizedCopy("生态不支持")),
                               (.budgetExcluded, localizedCopy("未进查询批次")),
                               (.notAttempted, localizedCopy("未发起核对"))] {
            if let value = counts[state], value > 0 {
                reasons.append(localizedFormat("%1$@ %2$@ 条", label, HealthCurves.whole(value)))
            }
        }
        return reasons
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
        // 四条分支各是**一条整句键**（不是碎片拼接）：英文词序与中文相反、
        // 且 "Start by …" 这类尾巴要能自己就位。碎片键是双语方案 §7.3 明令禁止的形态。
        // **每条分支是一整句键，不做二次拼接。**
        // 上一版把"综合 75 分（B 级）。"与分支句相加：中文里不空格是对的，
        // 英文里就成了 `(grade B).The main drag…` —— 句号后少一个空格，
        // 属于"机制都对、读起来是机翻"的形态（批次 P5 英文实拍抓到）。
        var candidate: String
        switch ranked.count {
        case 0:
            candidate = localizedFormat("综合 %1$@ 分（%2$@ 级）。当前没有任何维度可供评估，评分依据缺失，建议先完成代码分析与 Git 采集，再来查看总分。",
                                        String(score), grade)
        case 1:
            let only = ranked[0]
            candidate = localizedFormat("综合 %1$@ 分（%2$@ 级）。目前只有%3$@（%4$@ 分）这一个维度有可用数据，它同时也是当前最低项，建议优先%5$@。",
                                        String(score), grade, localizedCopy(only.name),
                                        String(only.score), advice(for: only.name))
        case 2:
            let low = ranked[0]
            let high = ranked[1]
            candidate = localizedFormat("综合 %1$@ 分（%2$@ 级）。主要拖累来自%3$@（%4$@ 分），%5$@（%6$@ 分）是目前相对最好的一项；建议优先%7$@。",
                                        String(score), grade, localizedCopy(low.name), String(low.score),
                                        localizedCopy(high.name), String(high.score), advice(for: low.name))
        default:
            let first = ranked[0]
            let second = ranked[1]
            let best = ranked[ranked.count - 1]
            candidate = localizedFormat("综合 %1$@ 分（%2$@ 级）。主要拖累来自%3$@（%4$@ 分）与%5$@（%6$@ 分）；%7$@（%8$@ 分）是当前最稳的一项。建议优先%9$@。",
                                        String(score), grade, localizedCopy(first.name), String(first.score),
                                        localizedCopy(second.name), String(second.score),
                                        localizedCopy(best.name), String(best.score), advice(for: first.name))
        }
        return fittedNarrative(candidate)
    }

    /// 长度收敛：超 80 字按子句边界丢弃，不足 40 字补固定后缀，最后再兜底截断。
    ///
    /// 拆成四个小函数是因为这一整块原本 CC 17，被本 App 自扫点名成
    /// 「高圈复杂度」热点（`complexFunctionBar` = 16）。拆分**没有改任何一条判断**：
    /// 子句边界、80/40 两个预算、垫句顺序、末尾标点改写全部原样。
    private static func fittedNarrative(_ candidate: String) -> String {
        guard containsHan(candidate) else { return candidate }
        return fitted(clauses: splitClauses(candidate), candidate: candidate)
    }

    /// **只对中文文本做长度收敛。** 下面全部常量都是中文假设：
    /// 子句边界是 `。；，`、上限是 80 **字**、不足 40 字要补的垫句也是中文。
    /// 直接喂英文的后果是实测出来的：英文整句里没有 `。`，于是 clauses 只有一段、
    /// 超 80 就 `break` ⇒ result 空 ⇒ 走 `prefix(79)` **从单词中间截断**，
    /// 再补一个中文句号 `。` 和两句中文垫句 —— 比不翻还糟。
    /// 英文侧的预算由模板本身保证（四条分支各 ≤ 240 字符），版面是散文区、会换行。
    private static func containsHan(_ text: String) -> Bool {
        text.contains { "\u{4E00}" <= $0 && $0 <= "\u{9FFF}" }
    }

    /// 按子句边界切分；末尾不成句的一段也算一条，免得丢字。
    private static func splitClauses(_ text: String) -> [String] {
        var clauses: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == "。" || character == "；" || character == "，" {
                clauses.append(current)
                current = ""
            }
        }
        if !current.isEmpty { clauses.append(current) }
        return clauses
    }

    /// 逐子句累加到 80 字预算；一条都放不下时退回"整句截断"，再把结尾标点收成正文句号。
    private static func fitted(clauses: [String], candidate: String) -> String {
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
        return padded(result)
    }

    /// 不足 40 字补固定垫句（补满即停，绝不为凑长度把总预算顶破 80），最后再兜底截断。
    private static func padded(_ text: String) -> String {
        var result = text
        let pads = [localizedCopy("其余维度处于可接受区间。"),
                    localizedCopy("建议保持观察，待各维度数据补齐后复核。")]
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
        case HealthDimension.complexity.rawValue: return localizedCopy("拆解高复杂度函数")
        case HealthDimension.duplication.rawValue: return localizedCopy("抽取重复代码块")
        case HealthDimension.codeQuality.rawValue: return localizedCopy("拆分超大文件与超长函数")
        case HealthDimension.documentation.rawValue: return localizedCopy("补齐关键注释并清理待办标记")
        case HealthDimension.activity.rawValue: return localizedCopy("保持稳定提交节奏")
        case HealthDimension.busFactor.rawValue: return localizedCopy("分摊单点作者的改动评审")
        case HealthDimension.stability.rawValue: return localizedCopy("排查崩溃与高频错误")
        case HealthDimension.dependencies.rawValue: return localizedCopy("升级有已知漏洞的依赖")
        case HealthDimension.testing.rawValue: return localizedCopy("补充自动化测试")
        default: return localizedFormat("处理「%@」", dimensionName)
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

    /// 文案预算按**显示宽度**算，不按字符数：中日韩全角一格折 2、拉丁与数字折 1。
    /// 中文态 120 格 = 60 个整字，与改造前那条「60 字」线是**同一条物理线**，评分卡那一行不动；
    /// 英文态拿到的因此是同样的**宽度**而不是同样的**字符数** —— 旧写法给英文也只数 60 格，
    /// 一行塞得下三四个词，后面的口径段整段被舍弃（P58 的动机）。
    static let detailWidthBudget = 120

    /// 分隔符本身也必须查表。它挂在 `joined` 这一处，而不是散在每条文案里各写一遍：
    /// 拼出来的整串永远查不中（守卫 1d），所以能查表的只有这些**片段之间**的标点。
    static var detailSeparator: String { localizedCopy("，") }

    /// 核心数字段在前，放不下的段直接舍弃，宁可少说也不截断数字或换行。
    ///
    /// ⚠ **一段都放不下时也不截**：留整段，让渲染层用 `lineLimit` + `.help` 去裁
    /// （健康评分那一列本来就挂着 `.help`，P54 立的口径：被裁掉的那半必须有去处）。
    /// 这里拦腰截断会把英文词切成半个 —— 实测交付头英文态打出
    /// `…tallied only over the top 20 hotspo)`，一个"h" 在全站任何地方都读不到，
    /// 而那正是"P58 把 60 字换成 120 格"想修掉的那族病，**换算法则不等于删掉截断**：
    /// 旧尺子在英文上会截，新尺子还是会，只是阈值挪高了 60 个字符而已。
    static func joined(_ segments: [String]) -> String {
        var result = ""
        for segment in segments {
            if segment.isEmpty { continue }
            let candidate = result.isEmpty ? segment : result + detailSeparator + segment
            if displayWidth(candidate) > detailWidthBudget { continue }
            result = candidate
        }
        return result.isEmpty ? (segments.first { !$0.isEmpty } ?? "") : result
    }

    /// 把**口径注记**挂到一条已经翻好的 detail 后面。
    ///
    /// ⚠ 这里只能是整句键：`curve.detail + "（中文）"` 拼完的那一串查不中任何键，
    /// 英文态会长成「前半英文 + 后半中文」—— 比整句中文更难读，而三条静态键守卫全是绿的。
    /// 括号本身也在模板里（中文「（）」、英文「()」），所以注记一律给**不带括号**的片段。
    static func noted(_ detail: String, _ notes: [String]) -> String {
        let note = joined(notes)
        guard !note.isEmpty else { return detail }
        return localizedFormat("%1$@（%2$@）", detail, note)
    }

    /// 榜单被截断时的披露注记：**榜长与真总数并排**写出来，谁都不许单独充当对方。
    ///
    /// 为什么要有这个具名助手（而不是一处一行 `localizedFormat`）：
    /// `BoardLengthReadoutRatchetTests` 数的是"把 `code.<榜>.count` 当总数用"的原始读数，
    /// 而它认合法披露句的办法是**同一行上有标记**。P58 把注记改成整句键之后，
    /// 参数换行会把标记与读数分到两行去 ⇒ 一句诚实的话被判成新增违例。
    /// 名字本身就是那个标记，调用点必须写成一行。
    static func boardOnlyNote(_ detail: String, listed: Int, total: Int) -> String {
        noted(detail, [localizedFormat("榜内只列 %1$@ 个，实际 %2$@ 个", whole(listed), whole(total))])
    }

    /// 一个字符占几格：CJK 全角（含汉字、全角标点、假名、韩文音节）算 2，其余算 1。
    static func displayWidth(_ text: String) -> Int {
        text.reduce(0) { $0 + (isFullWidth($1) ? 2 : 1) }
    }

    private static func isFullWidth(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        let value = scalar.value
        return (0x1100...0x115F).contains(value)      // 韩文字母
            || (0x2E80...0x303E).contains(value)      // 中日韩部首、标点、假名补充
            || (0x3041...0x33FF).contains(value)      // 平假名/片假名/中日韩符号
            || (0x3400...0x4DBF).contains(value)      // 扩展 A
            || (0x4E00...0x9FFF).contains(value)      // 汉字
            || (0xA000...0xA4CF).contains(value)      // 彝文
            || (0xAC00...0xD7A3).contains(value)      // 韩文音节
            || (0xF900...0xFAFF).contains(value)      // 兼容汉字
            || (0xFE30...0xFE6F).contains(value)      // 兼容标点
            || (0xFF00...0xFF60).contains(value)      // 全角形式
            || (0xFFE0...0xFFE6).contains(value)      // 全角符号
            || (0x1F300...0x1FAFF).contains(value)    // 表情符号
            || (0x20000...0x2FFFD).contains(value)    // 扩展 B 及以上
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
