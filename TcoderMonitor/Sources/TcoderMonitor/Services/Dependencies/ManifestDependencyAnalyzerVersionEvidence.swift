// OWNER: R3 依赖证据链 · 分析器的「版本证据」侧（自 ManifestDependencyAnalyzer.swift 整块搬出）
//
// 搬动理由：`SourcesSizeAuditTests` / `LogHotspotRatchetTests` 的 400 行口径。
// 本文件只有两类东西：① 把锁文件解析出的**实际版本**写回记录；
// ② 离线/在线各自"我们没做什么"的那句说明与生态覆盖判据。
// 逐字搬动，未改任何取义；跨文件可见的成员由 private 升为 internal（同模块内部类型）。
import Foundation

extension ManifestDependencyAnalyzer {

    // MARK: - 锁文件 / 已解析产物回填（RD-10 的"实际版本"）

    /// 把同目录锁文件里解析出的**确切版本**写进 `DependencyRecord.resolvedVersion`。
    ///
    /// 只做一件事：给"这条依赖到底装的是哪个版本"补上证据。做不到就留 nil ——
    /// 留 nil 会一路长成「版本未解析」的诚实状态（行状态 / 总览 / 评分同一份证据），
    /// 而不是拿声明范围的下界冒充安装版本。
    /// 只回填清单里**直接声明**的那些名字：传递依赖不在这页的口径里
    /// （`DependenciesView` 的主读数 note 已经写了"不含锁文件解析出的传递依赖"）。
    func applyLockResolutions(_ report: inout DependencyReport, root: URL) {
        for ecoIndex in report.ecosystems.indices {
            let ecosystem = report.ecosystems[ecoIndex]
            let directory = root.appendingPathComponent(ecosystem.manifestPath)
                .deletingLastPathComponent().standardizedFileURL
            let listed: [String] = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
            let names = Set(listed)
            let manifestDirectory = (ecosystem.manifestPath as NSString).deletingLastPathComponent
            // 先读锁文件，再读"已解析产物"（effective-POM / 依赖树 / SBOM）：
            // 两边写进同一个 `resolvedVersion` 字段，但 `resolvedVersionSource` 必须点名是哪份文件，
            // 因为这两类证据的强度不同（锁文件 = 装了什么；产物 = 上次解析出什么，可能过期）。
            let isLockFileRound = ManifestParsers.lockfileCandidates[ecosystem.ecosystem] ?? []
            let artifactRound = ManifestParsers.resolvedArtifactCandidates[ecosystem.ecosystem] ?? []
            for candidate in isLockFileRound + artifactRound {
                guard names.contains(candidate) else { continue }
                let url = directory.appendingPathComponent(candidate)
                guard let text = readText(at: url) else { continue }
                let relative = manifestDirectory.isEmpty ? candidate : "\(manifestDirectory)/\(candidate)"
                let isArtifact = artifactRound.contains(candidate)
                guard let resolution = isArtifact
                    ? DependencyLockParser.parseResolvedArtifact(fileName: candidate, text: text,
                                                                 relativePath: relative)
                    : DependencyLockParser.parse(fileName: candidate, text: text, relativePath: relative)
                else { continue }
                recordResolutionProvenance(resolution, for: relative)
                if isArtifact { markResolvedArtifact(ecoIndex: ecoIndex, file: relative) }
                for recordIndex in report.ecosystems[ecoIndex].dependencies.indices
                where report.ecosystems[ecoIndex].dependencies[recordIndex].resolvedVersion == nil {
                    let record = report.ecosystems[ecoIndex].dependencies[recordIndex]
                    guard let hit = resolution.resolvedVersion(name: record.name,
                                                              declaredRange: record.version) else { continue }
                    report.ecosystems[ecoIndex].dependencies[recordIndex].resolvedVersion = hit
                    report.ecosystems[ecoIndex].dependencies[recordIndex].resolvedVersionSource = relative
                    // 量到安装版本之后，"由父级管理但未解析"这件事就结束了：
                    // 三态里那一格必须翻成"已显式声明"，否则界面上会同时说"没解析出来"和"装的是 1.4.2"。
                    if report.ecosystems[ecoIndex].dependencies[recordIndex].declaredVersionState
                        == .managedByParent ||
                       report.ecosystems[ecoIndex].dependencies[recordIndex].declaredVersionState
                        == .undeterminable {
                        report.ecosystems[ecoIndex].dependencies[recordIndex].declaredVersionState = .explicit
                    }
                }
            }
        }
    }

    /// 同一份产物被多个清单目录读到时会累加到同一条上（按文件路径归并，保持稳定顺序）。
    private func markResolvedArtifact(ecoIndex: Int, file: String) {
        let counted = resolvedArtifactEvidence.firstIndex { $0.file == file }
        if let index = counted {
            resolvedArtifactEvidence[index] = (file, resolvedArtifactEvidence[index].entries + 1)
        } else {
            resolvedArtifactEvidence.append((file, 1))
        }
    }

    /// 一份解析结果的账（条数 / 歧义数）留在分析器里，供报告级说明引用。
    private func recordResolutionProvenance(_ resolution: DependencyLockResolution, for file: String) {
        resolutionProvenance[file] = (entries: resolution.versionsByName.count,
                                      ambiguous: resolution.ambiguousNames.count)
    }

    /// 离线时的「我们没做什么」说明，与在线路径同等直白（在线侧在
    /// `DependencyNetworkLookup` 里会把失败与未覆盖生态写进 note，离线侧原先什么都没有，
    /// 于是 `vulnerableCount = 0` 读起来像"查过、干净"）。
    static func offlineCaveat(for report: DependencyReport,
                                  resolvedArtifacts: [String] = []) -> String {
        let records = report.ecosystems.flatMap(\.dependencies)
        // "跳过比对"的判据 = **没有查询身份**（与在线/内置比对同一条闸门）。
        // 旧实现读的是第二套解析器 `KnownVulnerability.comparableCore`（已删，见台账 §9.5 第 1 条），
        // 于是"这句话数出来的条数"和"实际参与比对的条数"可以不是同一批。
        let skipped = records.filter { DependencyVersionIdentity.of($0).query == nil }.count
        // 四段各自是整句键、分隔符也查表：`parts.joined(separator: "；")`
        // 拼出来的整串在英文态会一半中文一半英文（运行时漏翻台账点名的就是这条）。
        var parts = [localizedFormat("未联网核对：漏洞判定只依据内置快照（覆盖 npm / Maven / Python），%@",
                                      DependencySnapshot.asOfText)]
        let uncovered = ecosystemsWithoutOfflineRules(in: report)
        if !uncovered.isEmpty {
            parts.append(localizedFormat("本次未覆盖生态：%@",
                                          uncovered.joined(separator: localizedCopy("、"))))
        }
        if skipped > 0 {
            parts.append(localizedFormat("%@ 项版本不可比较（「*」、workspace:*、分支/修订号等）已跳过比对",
                                          NumberFormat.grouped(skipped)))
        }
        // RD-13b：三态分开说，且"由父级管理"绝不计入"没写版本"。
        let declaration = DependencyEvidence.declarationPhrases(DependencyEvidence.ledger(for: report))
        if !declaration.isEmpty {
            parts.append("版本声明形态：" + declaration.joined(separator: localizedCopy("、")))
        }
        if !resolvedArtifacts.isEmpty {
            parts.append(localizedFormat("读到已解析产物 %1$@ 份（%2$@），按其解析出实际版本",
                                          NumberFormat.grouped(resolvedArtifacts.count),
                                          resolvedArtifacts.sorted().joined(separator: localizedCopy("、"))))
        }
        if report.totalDependencies == 0 { parts.append(localizedCopy("没有可核对的依赖")) }
        return parts.joined(separator: localizedCopy("；"))
    }

    /// 该生态有没有内置离线漏洞规则。从规则表与坐标互通表**推导**，不另抄一份清单，
    /// 免得规则增删后口径漂移（`DependencyReport.uncoveredEcosystemNames` 就是抄了
    /// `displayName` 清单，结果把 npm 误报成"未覆盖"）。
    static func hasOfflineRules(for ecosystem: DependencyEcosystem) -> Bool {
        let scopes = Set(DependencySnapshot.lookupScopes(for: ecosystem))
        return VulnerabilitySource.bundled.contains { scopes.contains($0.ecosystem.rawValue) }
    }

    /// 报告里存在、但内置规则不覆盖的生态（去重、保持首次出现顺序）。
    static func ecosystemsWithoutOfflineRules(in report: DependencyReport) -> [String] {
        var seen = Set<DependencyEcosystem>()
        var names: [String] = []
        for ecosystem in report.ecosystems.map(\.ecosystem) {
            guard !hasOfflineRules(for: ecosystem), seen.insert(ecosystem).inserted else { continue }
            names.append(ecosystem.displayName)
        }
        return names
    }
}
