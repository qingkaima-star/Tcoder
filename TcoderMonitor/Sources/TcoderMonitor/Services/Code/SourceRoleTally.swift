import Foundation

// OWNER: WS-R6 文件角色与扫描范围（RD-14）—— 角色分档的累计与出声。
//
// 判据本体在 `SourceFileRoleRules.swift`；这里只做两件事：
// 1. 把逐文件判定累计成「哪一档几个文件、几码行、判据分布」；
// 2. 把**只有本档能回答的问题**写成句子交给 `CodeScanCoverage.limitationSummary`。
//
// 为什么不把整张分档表直接塞进 `scanLimitations`：那张列表的语义是「哪些没量准」，
// 而「生产码 40 个 / 测试码 12 个」是一条**读数**，读数要有自己的落盘字段才能上屏与评分。
// `Models/**` 是冻结区 ⇒ 字段清单已写进 `docs/R6-契约字段清单.md` 交总工落。
// 在字段落地之前，这里只出**边界句**（未识别 / 弱判定 / 非生产内容仍在分母里）——
// 那三句不需要新字段，也不需要改任何既有口径，同一笔里就带着两个读者
// （界面 `CodeMetricsView` 的扫描边界 ⓘ + CLI `score` 的「未量准」段）。

/// 一个角色档的累计量。
struct SourceRoleShare: Sendable, Equatable {
    var files = 0
    var codeLines = 0
    var totalLines = 0
    /// 可点名的相对路径样本（有上限）。样本的意义是"能被反驳"：
    /// 只给一个总数的分档，读的人无从核对。
    var examples: [String] = []

    var isEmpty: Bool { files == 0 }
}

/// 一次扫描的角色分档累计。不可变对外，只经 `init` 填充。
struct SourceRoleTally: Sendable, Equatable {

    /// 每一档最多留几个可点名样本。6 个够人肉核对，又不会把一行限制撑成一段散文。
    static let exampleLimit = 6

    private(set) var shares: [SourceFileRole: SourceRoleShare] = [:]
    /// 弱判定（只有语言证据的生产码）样本路径。**单独一份**而不是从生产码档里筛：
    /// 筛的话得重新跑一遍判据，那份判定就有了第二个入口（本仓既有教训：一处判据两处入口）。
    private(set) var weakEvidenceExamples: [String] = []
    /// 判据分布：回答「这一档是靠什么判出来的」。生成物那一档必须有这个数，
    /// 否则"我们认出了生成码"这句话拿不出线索（RD-14 点名要说的就是它）。
    private(set) var criterionCounts: [SourceRoleCriterion: Int] = [:]

    init() {}

    /// 逐文件累计。`files` 是**已经进入统计**的那批（`SourceScanResult.files`）；
    /// 被剔除的条目没有角色可言，它们的去向由 `SourceSkipLedger` 与
    /// `SourceScanScopeReadout` 回答，不在这里重复记账。
    ///
    /// **按相对路径升序累计**，而不是按递进来的顺序：样本是"取前 N 个"，
    /// 按遇到顺序取就等于让并发调度的偶然决定屏上点谁的名（RD-63 实测：同一棵夹具树
    /// GUI 与 CLI 各点一枚，三趟里两趟对不表、方向还会反过来）。
    /// 累计量本身与顺序无关（都是加法），所以这条排序只改"点哪几条名"，不改任何数。
    init(of files: [ScannedSourceFile], exampleLimit: Int = SourceRoleTally.exampleLimit) {
        for file in files.sorted(by: { $0.relativePath < $1.relativePath }) {
            let decision = Self.decision(for: file)
            var share = shares[decision.role] ?? SourceRoleShare()
            share.files += 1
            share.codeLines += file.codeLineCount
            share.totalLines += file.totalLineCount
            if share.examples.count < exampleLimit { share.examples.append(file.relativePath) }
            shares[decision.role] = share
            criterionCounts[decision.criterion, default: 0] += 1
            if decision.criterion == .productionLanguageOnly, weakEvidenceExamples.count < exampleLimit {
                weakEvidenceExamples.append(file.relativePath)
            }
        }
    }

    /// 单个文件的角色判定（含文件头判据）。产品路径与单测走这**同一份**取行逻辑。
    static func decision(for file: ScannedSourceFile) -> SourceFileRoleDecision {
        SourceFileRoleRule.decide(relativePath: file.relativePath, language: file.language,
                                  headerLines: headerLines(of: file))
    }

    /// 判"生成物"要看文件头，但只许看前几行（`SourceFileRoleRule.generatedHeaderScanLines`）。
    static func headerLines(of file: ScannedSourceFile) -> [String] {
        file.lines.prefix(SourceFileRoleRule.generatedHeaderScanLines).map(\.text)
    }

    func share(_ role: SourceFileRole) -> SourceRoleShare { shares[role] ?? SourceRoleShare() }
    func files(_ role: SourceFileRole) -> Int { share(role).files }
    func codeLines(_ role: SourceFileRole) -> Int { share(role).codeLines }
    func count(_ criterion: SourceRoleCriterion) -> Int { criterionCounts[criterion] ?? 0 }

    /// 参与分档的文件总数。恒等式：各档文件数之和 == 本数（单测钉这条）。
    var attributedFileCount: Int { shares.values.map(\.files).reduce(0, +) }
    var attributedCodeLines: Int { shares.values.map(\.codeLines).reduce(0, +) }

    /// **弱判定**那一档：只有语言证据、路径没有任何角色线索，却被归进生产源码的文件数。
    var weakEvidenceFiles: Int { count(.productionLanguageOnly) }

    /// 整张分档表（每档一行）。**当前只有单测在读**：屏上那一句不走这里，走
    /// `ProductionCodeScaleReadout`（它读的是同一份累计**落盘**之后的 `code.fileRoles`）。
    /// 旧注释写的是「这一份要等 `Models` 的承接字段才能上屏」—— 那是一句**过期理由**：
    /// 字段 09-23 已落地（RD-14），09-24 起界面卡与健康分 ⓘ 也各自接上了
    /// （RD-67 · 台账卷四 §73），不许再拿「等字段」当这一份没接线的说法。
    var roleLines: [String] {
        SourceFileRole.allCases.filter { !share($0).isEmpty }.map { role in
            let value = share(role)
            var line = "\(role.displayName) · \(NumberFormat.grouped(value.files)) 个 · "
                + "\(NumberFormat.grouped(value.codeLines)) 代码行"
            if !value.examples.isEmpty {
                line += "；例：\(value.examples.joined(separator: localizedListSeparator()))"
            }
            if role == .production, let weak = weakEvidenceNote { line += "；\(weak)" }
            return line
        }
    }

    /// 进入 `scanLimitations` 的句子：只说**边界**，不说读数。
    /// 一条都没有时返回空数组（零命中不出声），但"这一路根本没跑"不在此列 ——
    /// 那种情况由调用方的 `unmeasuredScope` 负责出声。
    var notes: [String] {
        var lines: [String] = []
        appendUnknownRoleNote(into: &lines)
        // 弱判定那句**不进** `scanLimitations`，但留在这里的理由换过（RD-67 复核）：
        // 原先写的是「那一档要等 `Models.fileRoles` 才上屏」—— 那枚字段今天已经落地，
        // 那一档也确实上了屏（`CLIScoreText.fileRoleStatement` 逐字点名「弱判定 N 个」），
        // 所以旧理由已经不成立。现在只剩一条真理由：同一个数已经在两处出声，
        // 再挂一条边界提示等于把"已量到并公开的东西"重复计成"又一条没量准"
        // （`CodeAnalyzerPrecisionTests.testFileCapCoverageIsExposed` 那条既有断言也容不下多出来的一行）。
        // 那一段「下一步：读 `code.fileRoles` 时一并带出」**已经做掉了**（RD-67 · WS-R40）：
        // 「读这一档要按它打折」现在由 `ProductionCodeScaleReadout.weakEvidenceHint` 读落盘的
        // `fileRoles.share(for: .production)?.weakEvidenceFiles`，并到上屏那一句末尾
        // （代码规模页那一格 + 健康分 ⓘ 两处）。接的是**上屏那一路**，仍不是 `scanLimitations`
        // 这本账 —— 上面那两条理由一条没变，别把这次接线读成「该把它挪进未量准清单」。
        appendNonProductionInsideTotalsNote(into: &lines)
        appendGeneratedEvidenceNote(into: &lines)
        return lines
    }

    // MARK: - 四条边界句

    private func appendUnknownRoleNote(into lines: inout [String]) {
        let value = share(.unrecognized)
        guard !value.isEmpty else { return }
        lines.append("文件角色：\(NumberFormat.grouped(value.files)) 个文件（"
            + "\(NumberFormat.grouped(value.codeLines)) 代码行）认不出角色 —— "
            + "它们仍在 `codeLines` 分母里，但**不许**被读成生产源码；"
            + "未覆盖的语言/形状：\(examplesText(value.examples))。")
    }

    /// 弱判定那句（带**样本路径**的那一份）：进 `roleLines`，**不进** `scanLimitations`
    /// （理由见 `notes` 里那段）。屏上那一句不读这里 —— 它读落盘的 `weakEvidenceFiles`，
    /// 生产者只有这一处：`ProductionCodeScaleReadout.weakEvidenceHint(_:)`。
    var weakEvidenceNote: String? {
        guard weakEvidenceFiles > 0 else { return nil }
        return "生产源码判定里 \(NumberFormat.grouped(weakEvidenceFiles)) 个文件**只有语言证据**、"
            + "路径没有任何角色线索（既不在 src/ 这类目录，也不像测试/生成物）："
            + "\(examplesText(weakEvidenceExamples))。这是弱判定，与有路径证据的那批分开计数，"
            + "读「生产码规模」时按它打折。"
    }

    private func appendNonProductionInsideTotalsNote(into lines: inout [String]) {
        let outsiders: [SourceFileRole] = [.documentation, .configuration, .buildArtifact,
                                           .backupEvidence, .generated, .test]
        let outsiderFiles = outsiders.map { files($0) }.reduce(0, +)
        guard outsiderFiles > 0 else { return }
        let outsiderLines = outsiders.map { codeLines($0) }.reduce(0, +)
        let detail = outsiders
            .filter { !share($0).isEmpty }
            .map { "\($0.displayName) \(NumberFormat.grouped(files($0)))" }
            .joined(separator: localizedListSeparator())
        lines.append("代码规模的分母本轮**未按角色收窄**：\(NumberFormat.grouped(outsiderFiles)) 个非生产源码文件"
            + "（\(NumberFormat.grouped(outsiderLines)) 代码行：\(detail)）与生产码同分母。"
            + "角色分档本身已经落盘并可读（`code.fileRoles` 八档全量、CLI 那一行读的就是它），"
            + "所以这一条**不是能力缺口**，是评分与规模的分母还没接上这枚字段；"
            + "要不要收窄属产品裁定（台账 RD-67），不许读成工具量不到。")
    }

    private func appendGeneratedEvidenceNote(into lines: inout [String]) {
        let value = share(.generated)
        guard !value.isEmpty else { return }
        let evidence = generatedEvidenceText
        lines.append("生成物按判据分列：\(evidence)；共 \(NumberFormat.grouped(value.files)) 个 / "
            + "\(NumberFormat.grouped(value.codeLines)) 代码行。"
            + "注意 `yarn.lock`、`Cargo.lock` 这类锁文件因为语言表不认后缀，"
            + "走的是「剔除」而不是「识别为生成物」—— 同一种东西两条路。")
    }

    /// 生成物那一档的判据分布（只列真的命中过的）。
    var generatedEvidenceText: String {
        let parts = [
            (SourceRoleCriterion.lockFileName, "锁文件"),
            (.generatedFileSuffix, "生成物后缀（.pb.swift 等）"),
            (.generatedPathSegment, "生成目录"),
            (.generatedHeaderLine, "文件头声明生成"),
            (.migrationShape, "迁移文件"),
        ].compactMap { criterion, label -> String? in
            let hits = count(criterion)
            return hits > 0 ? "\(label) \(NumberFormat.grouped(hits))" : nil
        }
        return parts.isEmpty ? "无" : parts.joined(separator: localizedListSeparator())
    }

    /// 样本串：最多点 3 个名字，剩下的只报条数 —— 限制说明要能一眼读完，
    /// 但**必须留名**，只给一个总数的句子无从反驳。
    private func examplesText(_ examples: [String]) -> String {
        guard examples.isEmpty == false else { return "（未取样）" }
        let shown = examples.prefix(3).joined(separator: localizedListSeparator())
        let rest = examples.count > 3 ? "…（另 \(examples.count - 3) 条样本）" : ""
        return shown + rest
    }
}
