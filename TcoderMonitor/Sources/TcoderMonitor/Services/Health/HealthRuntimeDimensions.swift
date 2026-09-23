import Foundation

/// 运行时与外部证据的三维：运行稳定性（日志）、依赖健康（清单+漏洞核对）、测试覆盖（报告）。
/// 共同点：每一维都可能「压根没采到证据」，而没证据在本项目里**不等于好证据**——
/// 判据统一走 `VulnerabilityEvidence` / `coverage.hasData` / `StabilityZeroDenominatorShape` 这类
/// 显式三态，缺席就整维度不计分（**不按 0 计入**），并把原因写进建议里。
///
/// 运行稳定性这一维现在有**两道**门槛，都在 `stabilityOutcome` 里、按顺序走：
/// ① `totalLinesScanned == 0` ⇒ 分母无定义 ⇒ **整维缺席**，三态各说一句（RD-49）；
/// ② `0 < totalLinesScanned < 下限` ⇒ 分母太薄 ⇒ **保留分数但强制降档 + 上屏标「证据太薄·未判定」**（RD-46）。
/// 两道门槛的处理方式**故意不同**，理由写在 `StabilityEvidence` 的注释里（一句话：
/// ② 若也做成缺席，就会把已确认崩溃的扣分一起抹掉 —— 那正是 RD-49 的病灶，不能重犯）。
extension WeightedHealthScorer {

    // MARK: - 运行稳定性

    func stabilityOutcome(_ inputs: HealthInputs) -> DimensionOutcome {
        guard let logs = inputs.logs else { return .absent }
        // 一行真日志都没扫到＝这一维**没有分母**。以前这里只有一个出口、一句
        // 「没有可扫描的日志」，而 RD-46b 把崩溃正文移出分母之后，
        // 「只有崩溃报告、零真日志行」的项目也走进来了 —— 那句话对它就是假的
        // （崩溃报告不但扫到了，还认了归属），并且那 N 次确认崩溃随整维缺席一起不再扣分。
        // 现在拆成三态（`StabilityZeroDenominatorShape`），三态**都不给分、都不按 0 计入**，
        // 但各说各的话。建议句与界面/CLI 的缺席原因共用同一个判据，不留第二把尺子。
        guard logs.totalLinesScanned > 0 else {
            return DimensionOutcome(curve: nil,
                                    recommendations: StabilityAdvice.noDenominatorAdvice(logs))
        }
        // **分母是本次扫到的日志行数，不是源码行数**（RD-24）。
        // 源码行数答的是"这个项目写了多少代码"，与"程序跑了多久、接了多少请求"无关；
        // 拿它当分母会出现"多写代码 = 运行更稳"这种完全反掉的结论
        // （`HealthStabilityDenominatorTests` 钉住：同一批错误读数、代码行数从 1 万翻到 10 万，
        // 分数必须一字不动）。
        let faults = logs.errorCount + logs.exceptionCount
        let perKiloLogLines = Double(faults) / Double(logs.totalLinesScanned) * 1_000
        var curve = HealthCurves.stability(errorsPerKiloLogLines: perKiloLogLines,
                                           crashCount: logs.crashCount,
                                           fatalCount: logs.fatalCount,
                                           exceptionCount: logs.exceptionCount,
                                           totalLinesScanned: logs.totalLinesScanned)
        // RD-46：**分母 > 0 不等于分母够用**。门槛原先只有 `> 0` 这一道，于是
        // 一份 3 行的空日志 ⇒ 每千行 0 个错误 ⇒ 曲线满分（实测综合分 66 → 81），
        // 「几乎没跑过」与「跑了半年没出错」拿同一个数。现在低于最小证据量时强制降档。
        let thin = StabilityEvidence.isThin(logs)
        if thin { curve = StabilityEvidence.downgraded(curve, logs: logs) }
        var recommendations = stabilityAdvice(logs)
        if thin { recommendations.append(StabilityAdvice.thinEvidenceAdvice(logs)) }
        // 「证据不足」那几句走 recommendations：detail 有 60 字硬顶（评分卡那一行），
        // 而缺什么证据恰恰是最不能因为放不下就不说的一段。
        recommendations.append(contentsOf: stabilityEvidenceGaps(logs).map { "证据不足：\($0)" })
        return DimensionOutcome(curve: curve,
                                strengths: stabilityStrengths(logs, perKiloLogLines),
                                issues: stabilityIssues(logs),
                                recommendations: recommendations)
    }

    /// 这一维**缺**哪些证据。缺了不许默默按"没问题"处理，也不许按"最坏情况"处理 ——
    /// 它进分量的 `detail`，读分的人与读建议的人都能看到同一句。
    ///
    /// 源码行数密度只作为**辅助观察**留在界面上（`LogsMetricGrid` 那一格），
    /// 它不进这里的任何计数与扣分。
    private func stabilityEvidenceGaps(_ logs: LogSummary) -> [String] {
        var gaps: [String] = []
        // 运行时长 / 请求量：本 App 从未采集，任何"稳定性"结论都只是日志窗口内的读数。
        gaps.append("未采集运行时长与请求量，分母只是已扫描的日志行")
        // 份数只从 `StabilityZeroDenominatorShape` 那一个口子取（RD-49：不留第二把尺子）。
        // ⚠ 这一格数的是**读成功却没产出事件证据**的那几份（内容损坏 / 无可用事件时间 / 只有文件名像）；
        // "读不动"的那些走 `readFailedFiles` 另一本账，由第③态单独说一句 ——
        // 原先这句把"读不动"也算进来，等于让一本账认领另一本账的数。
        let crashChannelFiles = StabilityZeroDenominatorShape.readableCrashReportCount(logs)
        if crashChannelFiles > logs.crashCount {
            gaps.append("另有 \(crashChannelFiles - logs.crashCount) 份崩溃通道文件未产出可用事件证据"
                + "（内容损坏 / 无可用事件时间 / 只有文件名像），未计入崩溃数")
        }
        return gaps
    }

    private func stabilityStrengths(_ logs: LogSummary, _ perKiloLogLines: Double) -> [String] {
        // 一行日志都没扫到时不得写「近期无崩溃」——那是把「没看到」说成「没有」。
        // 真日志行读到过、但**少于证据下限**时同样不配这句（RD-46 的同一道门槛）：
        // 3 行日志的"零错误"与 3 万行的"零错误"不是一回事，优点卡不许把它们说成一回事。
        //
        // RD-24 的措辞修正：这里能说出口的上限是"**已扫描的这些行里**未见确认崩溃"，
        // 不是"运行期没有崩溃"。旧写法那句「未见崩溃」没有任何时间/暴露量边界，
        // 读者会当成一份运行期健康证明（而运行时长与请求量我们根本没采）。
        guard StabilityEvidence.isThin(logs) == false else { return [] }
        guard logs.crashCount == 0, perKiloLogLines < 0.5 else { return [] }
        return ["已扫描 \(NumberFormat.grouped(logs.totalLinesScanned)) 行日志，窗口内未见确认崩溃"
            + "（不等于运行期无崩溃：未采运行时长与请求量）"]
    }

    private func stabilityIssues(_ logs: LogSummary) -> [String] {
        guard let worst = logs.topErrors.first, worst.count >= 10 else { return [] }
        return ["\(worst.displayMessage)出现 \(worst.count) 次（最近 \(worst.lastSeenDescription)）"]
    }

    private func stabilityAdvice(_ logs: LogSummary) -> [String] {
        guard let worst = logs.topErrors.first, worst.count >= 10 else { return [] }
        return ["优先修复 Top Errors 首位，它通常掩盖了下游连锁异常"]
    }

    private enum StabilityAdvice {
        /// 第①态（真的什么都没有）。这一句**一个字都不许改**：旧报告与三条现存用例都靠它，
        /// 而它只有在"确实一份崩溃证据都没有"的时候才是真话（RD-49 的病根就是说错了对象）。
        static let missingLogAdvice = "没有可扫描的日志，运行稳定性不参与本次评分；"
            + "把日志文件放进项目目录或 ~/Library/Logs，或在「错误日志」页点「附加日志」，这个维度才会出现。"

        /// 第②态：有崩溃证据、零真日志行 ⇒ 分子有数、分母无定义。
        /// 崩溃一次都不许被抹掉（RD-49 后果 2），所以这份证据必须点名；
        /// 但**分子侧一行不许动** —— 这里只是把已经量到的数说出来，不折算成密度。
        static func crashesWithoutLogLinesAdvice(crashes: Int, reports: Int) -> String {
            "读到 \(crashes) 次确认崩溃"
                + (reports > 0 ? "（\(reports) 份崩溃报告）" : "（崩溃通道零份，来自日志行本身）")
                + "，但零真日志行 ⇒ 错误密度算不出分母，本维度不参与本次评分；"
                + "崩溃明细见「错误日志」页。"
        }

        /// 第③态：崩溃报告读不动 ⇒ 证据**不确定**。
        /// 它既不许冒充"有崩溃证据"（那是第②态），也不许被说成"没有可扫描的日志"（那是第①态）。
        /// ⚠ 括号里只列 `readFailedFiles` 这一本账**真的**装得下的原因（读失败的具体原因
        /// 逐份存在 `ScannedLogFile.readFailure` 里）；"内容损坏 / 只有文件名像"是
        /// **读成功但没产出事件证据**的那些，走 `stabilityEvidenceGaps` 另一句，两本账不许互串。
        static func unreadableCrashAdvice(reports: Int) -> String {
            "有 \(reports) 份崩溃报告没能读出来（权限不足 / 文件已消失 / 读取失败），"
                + "崩溃证据不确定：本维度不参与本次评分，也不得读成「没有崩溃」。"
        }

        /// 第②态里"另有读不动的那些"的补句 —— 与 `stabilityEvidenceGaps` 同一件事，
        /// 但那一格只在**参与计分**时才出声，这里补上缺席时的同一句。
        static func unreadableExtraAdvice(reports: Int) -> String {
            "另有 \(reports) 份崩溃报告没能读出来，未计入上面的份数。"
        }

        /// RD-46：证据太薄的降档说明（与 detail 里那句同源，两个出口都得看得见）。
        /// ⚠ 这一支**不是缺席**（缺席是三态那一支的事），所以这句里不许出现"不参与计分/不按 0 计入"
        /// 那套只属于缺席的说法 —— 它说的是：分数还在、但只到普通水位，且明写"未判定"。
        static func thinEvidenceAdvice(_ logs: LogSummary) -> String {
            "只读到 \(NumberFormat.grouped(logs.totalLinesScanned)) 行真日志，低于评这一维所需的 "
                + "\(NumberFormat.grouped(StabilityEvidence.minimumLogLines)) 行下限 ⇒ 证据太薄，"
                + "本维度按 \(GitCadenceEvidence.fixed(StabilityEvidence.thinEvidenceScoreCeiling)) 分封顶、"
                + "标「证据太薄·未判定」（薄不等于稳，也不等于运行不稳）；跑够一次真实运行后重扫即可解锁。"
        }

        /// 零分母那一支的**唯一**出口：三态各一句，都不给分。
        static func noDenominatorAdvice(_ logs: LogSummary) -> [String] {
            switch StabilityZeroDenominatorShape.assess(logs) {
            case .nothingAtAll:
                return [missingLogAdvice]
            case let .crashesWithoutLogLines(crashes, reports):
                let unreadable = StabilityZeroDenominatorShape.unreadableCrashReportCount(logs)
                return [crashesWithoutLogLinesAdvice(crashes: crashes, reports: reports)]
                    + (unreadable > 0 ? [unreadableExtraAdvice(reports: unreadable)] : [])
            case let .unreadableCrashReports(reports):
                return [unreadableCrashAdvice(reports: reports)]
            }
        }
    }

    // MARK: - 依赖健康

    func dependenciesOutcome(_ inputs: HealthInputs) -> DimensionOutcome {
        guard let deps = inputs.dependencies, deps.totalDependencies > 0 else { return .absent }
        // 「零漏洞」有两种可能：查过之后干净，或者压根没查。没查过就不参与评分，
        // 绝不能把「没核对」渲染成「依赖零风险」——那是拿收费点换假绿灯。
        switch VulnerabilityEvidence.classify(deps) {
        case .unchecked: return DimensionOutcome(curve: nil, recommendations: [uncheckedAdvice(deps)])
        case .degraded:
            // 原因逐条点名（旧文案写死"部分包查询失败"，可"版本没解析出来"和"生态不支持"
            // 根本不该被说成"查询失败" —— 那是另一种口径混用）。
            let reasons = VulnerabilityEvidence.degradationReasons(deps).joined(separator: "、")
            return DimensionOutcome(curve: nil,
                                    recommendations: ["漏洞核对未完成（\(reasons.isEmpty ? "存在未覆盖项" : reasons)），"
                                        + "依赖健康本维度暂不计分；补齐锁文件或重跑联网核对后再计。"])
        case .verified:
            let curve = HealthCurves.dependencyHealth(vulnerableCount: deps.vulnerableCount,
                                                      outdatedCount: deps.outdatedCount,
                                                      totalDependencies: deps.totalDependencies)
            return DimensionOutcome(curve: curve,
                                    strengths: dependencyStrengths(deps),
                                    issues: dependencyIssues(deps),
                                    recommendations: dependencyAdvice(deps))
        }
    }

    private func uncheckedAdvice(_ deps: DependencyReport) -> String {
        let uncovered = deps.uncoveredEcosystemNames
        return uncovered.isEmpty
            ? "未做在线漏洞核对，依赖健康本维度暂不计分；开启「联网核对」后重扫才有结论。"
            : "未做在线漏洞核对，依赖健康本维度暂不计分（内置规则未覆盖：\(uncovered.joined(separator: "、"))）。"
    }

    private func dependencyStrengths(_ deps: DependencyReport) -> [String] {
        // 走到这里说明确实核对过，这句安全背书才有依据。
        // 背书必须带**已成功核对的条数与数据源**（RD-11）：只说"N 个依赖零命中"
        // 与只说"没查到漏洞"是同一种懒惰 —— 读的人分不清"查过干净"和"没查"。
        guard deps.vulnerableCount == 0 else { return [] }
        let ledger = DependencyEvidence.ledger(for: deps)
        let source = DependencyEvidence.sourcesPhrase(ledger)
        return ["已完成漏洞核对，\(ledger.vulnerabilityCheckedCount)/\(ledger.totalCount) 个依赖零命中"
            + (source.isEmpty ? "" : "（数据源：\(source)）")]
    }

    private func dependencyIssues(_ deps: DependencyReport) -> [String] {
        guard deps.vulnerableCount > 0 else { return [] }
        return ["\(deps.vulnerableCount) 个已知漏洞，\(deps.outdatedCount) 个版本过旧"]
    }

    private func dependencyAdvice(_ deps: DependencyReport) -> [String] {
        deps.vulnerableCount > 0 ? ["先升级带严重漏洞的依赖，再统一处理过期版本"] : []
    }

    // MARK: - 测试覆盖

    func testingOutcome(_ inputs: HealthInputs) -> DimensionOutcome {
        // 覆盖率没有锚点曲线（数据只有行/分支两个百分比），保持分段计分。
        guard let coverage = inputs.coverage, coverage.hasData,
              let line = coverage.overallLinePercent else { return .absent }
        var outcome = DimensionOutcome(curve: CurveResult(score: Double(testingScore(line)),
                                                          detail: testingDetail(coverage, line),
                                                          risk: coverage.riskLevel))
        if line >= 75 {
            outcome.strengths.append(String(format: "测试覆盖率 %.1f%%", line))
        } else {
            outcome.recommendations.append(String(format: "将行覆盖率从 %.1f%% 提升到 75%% 以上", line))
        }
        return outcome
    }

    private func testingScore(_ linePercent: Double) -> Int {
        switch linePercent {
        case ..<20: return 20
        case ..<40: return 40
        case ..<60: return 62
        case ..<75: return 78
        case ..<85: return 90
        default: return 100
        }
    }

    private func testingDetail(_ coverage: CoverageMetrics, _ line: Double) -> String {
        String(format: "行覆盖 %.1f%%，分支覆盖 %@", line,
               coverage.overallBranchPercent.map { String(format: "%.1f%%", $0) } ?? "无数据")
    }
}

// MARK: - 零真日志行的三态（RD-49）

/// 一行真日志都没扫到时，输入其实有**三种**形状，它们各自该说的话不一样。
///
/// 病根：`LogInsights.hasData` 的定义是 `totalLinesScanned > 0 || !scannedFiles.isEmpty`，
/// 所以"只读到几份崩溃报告"这种项目 `hasData == true` 而分母是 0 ——
/// RD-46b 之前分母被崩溃正文灌大、这一支进不来；RD-46b 把它摘干净之后，
/// 原来那一句「没有可扫描的日志」对这类项目就成了假话，
/// 而且那 N 次确认崩溃随整维一起不再扣分（台账 RD-49 的两层后果）。
///
/// **判据只此一处**：`WeightedHealthScorer.stabilityOutcome`（建议句）与
/// `HealthBreakdown.stabilityAbsence`（界面与 CLI 的缺席原因）共用它，不留第二把尺子。
enum StabilityZeroDenominatorShape: Equatable {
    /// ① 真的什么都没有：没有确认崩溃、崩溃通道一份没读到、也没有读不动的崩溃报告。
    case nothingAtAll
    /// ② 有崩溃证据（确认次数或已读到的报告份数），但零真日志行 ⇒ 密度没有分母。
    case crashesWithoutLogLines(confirmedCrashes: Int, readableReports: Int)
    /// ③ 只有读不动的崩溃报告：证据**不确定**，既不算"有崩溃"也不算"没有日志"。
    case unreadableCrashReports(Int)

    /// ⚠ 判"有没有崩溃证据"只读**次数与份数**，一律不碰行数：
    /// 行数正是这一支已经确定为 0 的东西，拿它当判据就是循环定义（工单 §0 明令）。
    static func assess(_ logs: LogSummary) -> StabilityZeroDenominatorShape {
        let readable = readableCrashReportCount(logs)
        if logs.crashCount > 0 || readable > 0 {
            return .crashesWithoutLogLines(confirmedCrashes: logs.crashCount, readableReports: readable)
        }
        let unreadable = unreadableCrashReportCount(logs)
        return unreadable > 0 ? .unreadableCrashReports(unreadable) : .nothingAtAll
    }

    /// 读成功的崩溃报告份数。`crashReportCount` 是 RD-46b 落的直传格；
    /// 旧报告没有这一格（`nil`）时退回**同一集合**的计数（`scannedFiles` 里 role == .crash）：
    /// 两者在 `FileLogAnalyzer` 里出自同一次 `readFailed == false` 过滤，
    /// 所以不是两把尺子，而是一把尺子的新格与旧算法。这个"同集合"由
    /// `ScoreEvidenceFloorCrashStatesTests` 在盘上夹具上逐份对账，不许漂移。
    static func readableCrashReportCount(_ logs: LogSummary) -> Int {
        logs.crashReportCount ?? logs.scannedFiles.filter { $0.role == .crash }.count
    }

    /// 读不动的崩溃报告：它们走 `readFailedFiles` 单独一本账，**不许冒充崩溃证据**。
    static func unreadableCrashReportCount(_ logs: LogSummary) -> Int {
        (logs.readFailedFiles ?? []).filter { $0.role == .crash }.count
    }

    /// 界面与 CLI 共用的缺席原因（`MissingDimensionReason.text` 读这一份）。
    /// ①那一句与整改前逐字相同 —— 旧文案不许因为加了新态就消失。
    static func absenceReason(logs: LogSummary) -> String {
        switch assess(logs) {
        case .nothingAtAll:
            return "列到 \(NumberFormat.grouped(logs.scannedFiles.count)) 个日志文件，"
                + "但一行都没读出来（空文件 / 编码不认识 / 读取失败），本维度不参与计分。"
        case let .crashesWithoutLogLines(crashes, reports):
            return "崩溃通道读到 \(reports) 份报告、确认 \(crashes) 次崩溃，但一行真日志都没有 ⇒ "
                + "错误密度没有分母，本维度不参与计分（这也不等于「零错误」）。"
        case let .unreadableCrashReports(reports):
            return "\(reports) 份崩溃报告没能读出来，崩溃证据不确定，本维度不参与计分。"
        }
    }
}

// MARK: - 运行稳定性的最小证据量（RD-46）

/// 运行稳定性这一维"多少行才算够证据"。这条线**只许往紧拧**，放宽要先向总工交代。
enum StabilityEvidence {
    /// 曲线的**最小可分辨台阶**：每千行日志 0.5 个错误（`HealthCurves.stability` 锚点表
    /// 0 → 0.5 那一级，100 分 → 92 分）。它是本文件之外唯一存在过的数，
    /// 与锚点表的对账由 `ScoreEvidenceFloorTests` 逐字盯着（两处一旦分叉立刻红）。
    static let finestDensityStepPerKiloLogLines: Double = 0.5

    /// 评这一维所需的最小真日志行数 = **2,000 行**。推导只有两条前提，都是仓里已有的数：
    ///
    /// 1. 一次错误在一份 N 行日志里的密度量子是 `1000 / N` 每千行（这是恒等式，不是选择）；
    /// 2. 要让**一次**错误不至于跨过曲线的最小台阶（0.5 每千行），需要 `1000 / N ≤ 0.5`
    ///    ⇒ **N ≥ 2000**。
    ///
    /// 边界是算出来的、不是挑出来的：N = 1999 时一次错误 = 0.50025 每千行，
    /// 单条事件就足以把人从「干净」档推到下一档；N = 2000 时一次错误正好落在台阶上、不越过去。
    /// 也就是说 **2000 是"一次错误不左右结论"的最小整数**，取 1999 会让这条线自己失去意义，
    /// 取 2500 / 1000 都只是把同一个判据挪到没有依据的位置上。
    /// 三组边界夹具（1,999 / 2,000 / 10,000）与这条推导一起在 `ScoreEvidenceFloorTests` 里。
    ///
    /// ⚠ 为什么不复用 `GitCadenceEvidence.minimumSpanDays`（7）：那把尺子量的是**时间跨度**
    /// （够不够说"节奏"），这一把量的是**分母的分辨力**（够不够算"每千行几个"），
    /// 两者互不蕴含——一个 5,000 行日志只跑了一秒钟的项目分母够用、跨度不够；
    /// 反过来跨了三年、只留下 20 行日志的项目跨度够、分母不够。
    static let minimumLogLines: Int = 2_000

    /// 太薄时的**封顶值**：直接引用 `GitCadenceEvidence.shortHistoryScoreCeiling`（60 分），
    /// 一个新数字都不造。两处的语义同一件事：「样本不足 ⇒ 最多只能拿到普通稳定仓库的水位」，
    /// 而且 60 落在稳定性自己的风险梯级（`graded(score, 85, 65, 45, 20)`）的
    /// 「低风险」下沿 65 之下 —— 与活跃度那一维当年选 60 的理由是同一条。
    static let thinEvidenceScoreCeiling: Double = GitCadenceEvidence.shortHistoryScoreCeiling

    /// 有分母、但分母太薄。**故意不等于缺席**：
    /// 缺席会把已确认崩溃的扣分一起抹掉（RD-49 的病灶 2），封顶不会 ——
    /// 崩溃与致命的扣分在曲线里已经扣完，`min` 只削掉"没证据撑住的上行"那部分。
    static func isThin(_ logs: LogSummary) -> Bool {
        logs.totalLinesScanned > 0 && logs.totalLinesScanned < minimumLogLines
    }

    /// 推导用的那个量子（测试拿它独立复算 2000 这条线，不重新抄一遍式子）。
    static func errorQuantumPerKilo(logLines: Int) -> Double {
        guard logLines > 0 else { return .infinity }
        return 1_000 / Double(logLines)
    }

    /// 降档：`min` 只会压低、绝不抬高（这条方向性由 `ScoreEvidenceFloorTests` 钉住）。
    /// 标记与封顶**分开判**：分数本来就低于封顶时（例如已有 4 次确认崩溃），
    /// 封顶是空操作，但「证据太薄·未判定」这句照样得上屏 —— 薄是真，分数低也是真。
    static func downgraded(_ curve: CurveResult, logs: LogSummary) -> CurveResult {
        let capped = Swift.min(curve.score, thinEvidenceScoreCeiling)
        let risk = capped < curve.score ? GitCadenceEvidence.risk(afterCappingTo: capped) : curve.risk
        return CurveResult(score: capped, detail: curve.detail + thinNote(logs), risk: risk)
    }

    /// 评分卡那一行后面的标记：这一维**未判定**，不是"判定为普通"。
    static func thinNote(_ logs: LogSummary) -> String {
        "（证据太薄·未判定：仅 \(NumberFormat.grouped(logs.totalLinesScanned)) 行 < "
            + "\(NumberFormat.grouped(minimumLogLines)) 行下限，封顶 "
            + "\(GitCadenceEvidence.fixed(thinEvidenceScoreCeiling)) 分）"
    }
}
