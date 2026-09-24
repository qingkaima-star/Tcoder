import Foundation

/// 依赖健康这一维（清单 + 漏洞核对）从 `HealthRuntimeDimensions.swift` 整块搬来，**内容一字未改**。
/// 为什么搬：RD-83/RD-84 两条都要动这一维的建议句（点名目标），而宿主文件当时已 402 行、
/// 越过 `SourcesSizeAuditTests` 的 400 行口径——本仓的规矩是「超线就拆，不是挂账」。
/// 为什么是这一维先走：它是宿主里唯一一段自成一体、且**只被 `WeightedHealthScorer` 自己调用**的
/// 三维证据装配口（`dependenciesOutcome` 由 `WeightedHealthScorer.evaluate` 那一侧点名调用）。
/// 三态口径的说明仍留在宿主文件顶部那段（`VulnerabilityEvidence` / `coverage.hasData` 那一套），
/// 这里只搬实现，不搬口径文字——避免同一份解释长两处（守卫失效第 2 类）。

extension WeightedHealthScorer {

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
            let reasons = VulnerabilityEvidence.degradationReasons(deps).joined(separator: localizedCopy("、"))
            return DimensionOutcome(curve: nil,
                recommendations: [localizedFormat("漏洞核对未完成（%1$@），依赖健康本维度暂不计分；补齐锁文件或重跑联网核对后再计。",
                                                   reasons.isEmpty ? localizedCopy("存在未覆盖项") : reasons)])
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
            ? localizedCopy("未做在线漏洞核对，依赖健康本维度暂不计分；开启「联网核对」后重扫才有结论。")
            : localizedFormat("未做在线漏洞核对，依赖健康本维度暂不计分（内置规则未覆盖：%1$@）。",
                              uncovered.joined(separator: localizedCopy("、")))
    }

    private func dependencyStrengths(_ deps: DependencyReport) -> [String] {
        // 走到这里说明确实核对过，这句安全背书才有依据。
        // 背书必须带**已成功核对的条数与数据源**（RD-11）：只说"N 个依赖零命中"
        // 与只说"没查到漏洞"是同一种懒惰 —— 读的人分不清"查过干净"和"没查"。
        guard deps.vulnerableCount == 0 else { return [] }
        let ledger = DependencyEvidence.ledger(for: deps)
        let source = DependencyEvidence.sourcesPhrase(ledger)
        return [localizedFormat("已完成漏洞核对，%1$@/%2$@ 个依赖零命中%3$@",
                                HealthCurves.whole(ledger.vulnerabilityCheckedCount),
                                HealthCurves.whole(ledger.totalCount),
                                source.isEmpty ? "" : localizedFormat("（数据源：%1$@）", source))]
    }

    private func dependencyIssues(_ deps: DependencyReport) -> [String] {
        guard deps.vulnerableCount > 0 else { return [] }
        return [localizedFormat("%1$@ 个已知漏洞，%2$@ 个版本过旧",
                                HealthCurves.whole(deps.vulnerableCount),
                                HealthCurves.whole(deps.outdatedCount))]
    }

    /// RD-84：要点的那一个必须与 `vulnerableCount` **同源**——计数走的是
    /// `advisories[].affectedPackages` 与 `offlineVulnerabilities[].affectedDependencies`，
    /// 所以点名也只能从这两处取（拿 `DependencyRecord.knownVulnerabilities` 去点会变成第三个口径，
    /// 那是本仓「跨口径读数不可进同一统计量」点名过的错）。
    /// 三条都落不到具体名字时才退回泛泛一句——数说"有命中"但两处来源都点不出名字，
    /// 这本身就是"没查准"，不许编一个组件名上去。
    private func dependencyAdvice(_ deps: DependencyReport) -> [String] {
        guard deps.vulnerableCount > 0 else { return [] }
        if let advisory = deps.advisories.first(where: { $0.affectedPackages.isEmpty == false }),
           let package = advisory.affectedPackages.first {
            return [localizedFormat("先升级这一个：%1$@（%2$@，公告 %3$@），再统一处理过期版本",
                                    package, advisory.ecosystem.displayName, advisory.id)]
        }
        if let offline = deps.offlineVulnerabilities.first(where: { $0.affectedDependencies.isEmpty == false }) {
            return [localizedFormat("先升级这一个：%1$@（%2$@，命中 %3$@ 个依赖），再统一处理过期版本",
                                    offline.package, offline.ecosystem.displayName,
                                    String(offline.affectedDependencies.count))]
        }
        return [localizedCopy("先升级带严重漏洞的依赖，再统一处理过期版本")]
    }

}
