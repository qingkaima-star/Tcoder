import Foundation

/// 运行时与外部证据的三维：运行稳定性（日志）、依赖健康（清单+漏洞核对）、测试覆盖（报告）。
/// 共同点：每一维都可能「压根没采到证据」，而没证据在本项目里**不等于好证据**——
/// 判据统一走 `VulnerabilityEvidence` / `coverage.hasData` / `totalLinesScanned == 0` 这类
/// 显式三态，缺席就整维度不计分，并把原因写进建议里。
extension WeightedHealthScorer {

    // MARK: - 运行稳定性

    func stabilityOutcome(_ inputs: HealthInputs) -> DimensionOutcome {
        guard let logs = inputs.logs else { return .absent }
        // 一行日志都没扫到＝这个维度**没有证据**。以前它按默认值 85 分计入，
        // 而 85 × 权重 0.178 是全表最高的一项贡献（15.1 分），等于用"没查"换分（缺陷 #46）。
        // 现在与依赖健康、测试覆盖同一处理：缺席、不参与归一化，并把原因写进建议里。
        guard logs.totalLinesScanned > 0 else {
            return DimensionOutcome(curve: nil, recommendations: [StabilityAdvice.missingLogAdvice])
        }
        // 密度需要代码规模做分母；没有 code 时退化成「按绝对值当每千行计」，
        // 宁可偏严也不把证据缺失算成满分（availableDimensions 承诺了这个维度在场）。
        let lines = inputs.code?.codeLines ?? 0
        let faults = logs.errorCount + logs.exceptionCount
        let perKloc = lines > 0 ? Double(faults) / Double(lines) * 1000 : Double(faults)
        let curve = HealthCurves.stability(errorsPerKLoc: perKloc, crashCount: logs.crashCount,
                                           fatalCount: logs.fatalCount, exceptionCount: logs.exceptionCount,
                                           totalLinesScanned: logs.totalLinesScanned)
        return DimensionOutcome(curve: curve,
                                strengths: stabilityStrengths(logs, perKloc),
                                issues: stabilityIssues(logs),
                                recommendations: stabilityAdvice(logs))
    }

    private func stabilityStrengths(_ logs: LogSummary, _ perKloc: Double) -> [String] {
        // 一行日志都没扫到时不得写「近期无崩溃」——那是把「没看到」说成「没有」。
        // 曲线那边已经如实标了「未扫描到运行日志，本维度按默认值计」，
        // 优点卡必须跟它一个口径，否则同一份报告自己打自己脸。
        guard logs.crashCount == 0, perKloc < 0.5 else { return [] }
        return ["已扫描 \(NumberFormat.grouped(logs.totalLinesScanned)) 行日志，未见崩溃"]
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
        static let missingLogAdvice = "没有可扫描的日志，运行稳定性不参与本次评分；"
            + "把日志文件放进项目目录或 ~/Library/Logs，或在「错误日志」页点「附加日志」，这个维度才会出现。"
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
