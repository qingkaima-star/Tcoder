import Foundation

/// `score` 的文本读数。两件事是这份文件的全部设计：
///
/// 1. **失败路在分数之前**。反过来打就等于让读它的人（人或 AI）先信了那个分，
///    再看到"有两路其实没跑出来"。
/// 2. **综合分只从 `HealthScore.verdict` 读**。`overall` 在没有任何维度拿到可计分证据时
///    是个占位 0，直接打它会读出"综合健康分 = 0"这种看着最确定的假账
///    （`Models/HealthScore.swift` 里 `verdict` 的注释就是为这条立的）。
enum CLIScoreText {

    /// 溯源一行，打在**任何读数之前**（与「失败路在分数之前」同一条理由）：
    /// 读的人得先知道自己看的是哪个提交、哪把尺子，后面的每个数字才有归属。
    /// 旧报告没有溯源块时整行照样打，只把内容写成「未记录」——静默消失会被读成「无需溯源」。
    private static func provenanceLine(_ report: ProjectReport) -> String {
        guard let p = report.provenance else {
            return "溯源：未记录（这份报告出自没有溯源块的结构）"
        }
        return "溯源：\(p.oneLineSummary) · 范围 \(p.scannedRoot ?? "未记录") · 入口 \(p.producedBy ?? "未记录")"
    }

    static func render(_ report: ProjectReport, exit: CLIExit) -> String {
        var lines: [String] = [openingLine(report)]
        lines.append(provenanceLine(report))
        if exit == .allFailed {
            lines.append("五路全部失败，本次不出结论 —— 这条读作「什么都没量到」，不是「这个仓库没有代码」。")
            lines.append(contentsOf: report.failedSections.map { "  失败：\($0)" })
            return lines.joined(separator: "\n")
        }

        if !report.failedSections.isEmpty {
            lines.append("失败路 \(report.failedSections.count)/\(CLIScan.sectionLabels.count)："
                         + report.failedSections.joined(separator: "、")
                         + " —— 下面的分是在这些维度缺席时算出来的")
        }
        // 「哪些没量准」必须在**分数之前**出声，与"失败路在分数之前"同一条理由。
        // 立这条的现场（19:04 实读）：`scanLimitations` 全仓只有
        // `Views/Code/CodeMetricsView.swift` 一处消费方 ⇒
        // 那些「明细榜单截断到 20 块」「块注释未闭合 ⇒ 只能当部分测量读」的句子
        // 只有打开界面的人才看得到，而 JSON 里有、文本读数里没有 ——
        // 看界面的人、读 CLI 的人、拿 JSON 的 AI 于是拿到三种诚实度。
        lines.append(contentsOf: precisionCaveat(report))
        // RD-42：分区归位是**口径**、不是"没量准" ⇒ 另起一行，**绝不并进**上面那条
        // 「未量准 N 条」（那条的分母就是 `scanLimitations.count`，塞进去等于把"没量准"灌虚高）。
        lines.append(contentsOf: regionCaliberLines(report))

        guard let health = report.health else {
            lines.append("没有评分结果：五路都没给出可评的输入。")
            return lines.joined(separator: "\n")
        }

        lines.append("综合健康分 = " + (health.verdict.map(String.init) ?? "无（没有任何维度拿到可计分的证据）"))
        lines.append(contentsOf: absentDimensionLines(health, report: report))
        lines.append(contentsOf: codeScopeLines(health.codeScope))
        lines.append("结论：\(health.narrative)")
        lines.append(contentsOf: networkCaveat(report))
        lines.append("  分  权重  维度        依据")
        for component in health.components.sorted(by: { $0.score < $1.score }) {
            lines.append("  " + pad(String(component.score), width: 3) + "  "
                         + String(format: "%.4f", component.weight) + "  "
                         + pad(component.name, width: 10) + " " + component.detail)
        }
        lines.append(contentsOf: health.issues.map { "  问题：\($0)" })
        lines.append(contentsOf: health.recommendations.map { "  建议：\($0)" })
        return lines.joined(separator: "\n")
    }

    /// 本次"没量准 / 只是部分测量"的句子，**逐条原样**打出来。
    ///
    /// 三条硬规矩（都是这一轮立的）：
    /// 1. **不许折叠成"若干限制，详见界面"** —— 那等于把诚实性内容降级成一个指针；
    /// 2. **不许只打第一条**（榜上有 3 条就得有 3 行，条数与行数一一对得上）；
    /// 3. 空集合时**整段不出声**，不许打"未量准 0 条"去占位（那会被读成"有这一类信息"）。
    static func precisionCaveat(_ report: ProjectReport) -> [String] {
        guard let limits = report.code?.scanLimitations, limits.isEmpty == false else { return [] }
        return ["未量准 \(limits.count) 条（下面每一条都是工具自己声明的边界，读数请按它打折）："]
            + limits.map { "  边界：\($0)" }
    }

    /// 混合语言文件的**分区归位**口径（RD-42）：与上面那段分家打，一句话也不并进「未量准」。
    ///
    /// 判据来源是 `CodeMetrics.nonCodeRegionLineCount`（引擎直传的那一枚数），句子本身
    /// **复用界面的那一个装配口** `MixedLanguageRegionCaliber.note(_:)` —— CLI 不许另写一份
    /// 中文（那是第二把尺子，与"缺席维度复用 `HealthBreakdown`"同一条纪律）。
    /// 字段缺席（旧报告）或为 0（没有混合语言文件）⇒ **一行都不打**。
    static func regionCaliberLines(_ report: ProjectReport) -> [String] {
        guard let code = report.code, let note = MixedLanguageRegionCaliber.note(code) else { return [] }
        return ["口径：\(note)"]
    }

    // MARK: - 首行：总体

    private static func openingLine(_ report: ProjectReport) -> String {
        let code = report.code
        let head = report.git?.headSHA
        return "被扫对象 = \(report.project.path)"
            + " · 文件 " + (code.map { "\($0.totalFiles)" } ?? "未量到")
            + " · 码行 " + (code.map { "\($0.codeLines)" } ?? "未量到")
            + " · HEAD " + ((head?.isEmpty == false) ? String(head!.prefix(8)) : "无")
    }

    // MARK: - 缺席维度与核对口径

    /// 缺席维度**复用界面的那两个函数**（`HealthBreakdown.missingDimensions` +
    /// `MissingDimensionReason.text`）：界面向用户解释"这一维为什么没有分"的那份口径，
    /// CLI 不许另写一遍（那会是第二把尺子）。
    /// 唯一不照抄的是措辞归属 —— 原因表里那句「上次扫描「X」失败」讲的是"上一次扫描"，
    /// 而 CLI 一次性的报告里失败就是**本次**，所以这一类改成指回上面的「失败路」那一行。
    private static func absentDimensionLines(_ health: HealthScore, report: ProjectReport) -> [String] {
        let missing = HealthBreakdown.missingDimensions(of: health)
        guard !missing.isEmpty else { return [] }
        let failed = missing.filter { dimension in
            guard let analyzer = MissingDimensionReason.analyzerLabel[dimension] else { return false }
            return report.failedSections.contains(analyzer)
        }
        let explained = missing.filter { !failed.contains($0) }
        var parts = explained.map {
            DimensionDisplay.name($0) + " — " + MissingDimensionReason.text(for: $0, report: report)
        }
        if !failed.isEmpty {
            parts.append(failed.map(DimensionDisplay.name).joined(separator: "、")
                         + " — 所属分析路本次失败，原因见上面「失败路」那一行")
        }
        return ["缺席维度 \(missing.count) 项（不参与计分、也不按 0 计入）：" + parts.joined(separator: " · ")]
    }

    /// "没查 ≠ 没有病"这句在界面上是常驻提示，CLI 里以前只把
    /// `networkLookupPerformed=false` 埋在 JSON 里 —— AI 不翻那个键就会把"0 条漏洞"当结论。
    ///
    /// RD-11 之后这一行还要把**状态**说出来：逐条核对结果的六态分档、已成功核对的条数、
    /// 数据源，一次讲清；没核对成时明确写"这不是没有漏洞"。
    ///
    /// 两个落点各管一件事，顺序固定：
    ///   1. 分析器自述的那句中文**原样**跟在 `漏洞核对：` 后面（界面上常驻的就是它，
    ///      WS-CL 的契约是"CLI 必须带上分析器那句话"，不在这里另写一份口径）；
    ///   2. 结构化账本另起一行 `漏洞核对状态：` / `版本核对状态：`，给 AI 与脚本读。
    /// 分析器这一路什么都没产出（既没有说明也没有任何一条依赖）时**一行都不打** ——
    /// 凭空造一句"没查"就是把 CLI 写成第二个真值来源。
    private static func networkCaveat(_ report: ProjectReport) -> [String] {
        guard let deps = report.dependencies else { return ["漏洞核对：无（依赖分析这一路没有产出）"] }
        let ledger = DependencyEvidence.ledger(for: deps)
        guard !deps.networkLookupNote.isEmpty || ledger.totalCount > 0 else { return [] }
        var lines: [String] = []
        if !deps.networkLookupNote.isEmpty { lines.append("漏洞核对：\(deps.networkLookupNote)") }
        guard ledger.totalCount > 0 else { return lines }

        var status = "漏洞核对状态：已核对 \(NumberFormat.grouped(ledger.vulnerabilityCheckedCount))"
            + "/\(NumberFormat.grouped(ledger.totalCount))"
        let tail = DependencyEvidence.tailPieces(ledger)
        if !tail.isEmpty { status += "，未覆盖：\(tail.joined(separator: localizedCopy("、")))" }
        let source = DependencyEvidence.sourcesPhrase(ledger)
        if !source.isEmpty { status += "；数据源：\(source)" }
        status += DependencyEvidence.mayClaimNoKnownVulnerabilities(ledger)
            ? "（全量覆盖且零命中）"
            : (ledger.vulnerabilityCheckedCount == ledger.totalCount
                ? "（全量覆盖）" : " —— 这是「没查全」，不是「没有漏洞」")
        lines.append(status)
        lines.append("版本核对状态：已核对 \(NumberFormat.grouped(ledger.versionCheckedCount))"
            + "/\(NumberFormat.grouped(ledger.totalCount))"
            + "，未覆盖：\(DependencyEvidence.tailOfVersionStates(for: ledger))")
        if ledger.lowerBoundQueryCount > 0 {
            lines.append("其中 \(NumberFormat.grouped(ledger.lowerBoundQueryCount)) 条按**声明范围的下界**查询"
                + "（实际安装版本没量到，结论只到「这一版有公告」，不到「你装的这版」）")
        }
        lines.append(contentsOf: DependencyScopeLines.lines(deps))
        return lines
    }

    private static func codeScopeLines(_ scope: HealthSubScore?) -> [String] {
        guard let scope else {
            return ["工程质量（代码口径） = 无（没有代码维度参与计分）"]
        }
        return ["工程质量（代码口径） = \(scope.overall)",
                "  计入：\(scope.includedDimensions.joined(separator: "、"))",
                "  不含：\(scope.excludedDimensions.isEmpty ? "（无）" : scope.excludedDimensions.joined(separator: "、"))",
                "  口径：\(scope.note)"]
    }

    private static func pad(_ text: String, width: Int) -> String {
        let gap = width - displayWidth(text)
        return gap > 0 ? String(repeating: " ", count: gap) + text : text
    }

    /// 维度名是中文，终端里一个汉字占两格。按 `count` 补空格会把整张分量表排歪。
    private static func displayWidth(_ text: String) -> Int {
        text.reduce(0) { $0 + ($1.isASCII ? 1 : 2) }
    }
}
