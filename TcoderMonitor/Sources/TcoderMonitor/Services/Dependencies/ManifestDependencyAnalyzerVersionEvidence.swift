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
            for candidate in ManifestParsers.lockfileCandidates[ecosystem.ecosystem] ?? [] {
                guard names.contains(candidate) else { continue }
                let url = directory.appendingPathComponent(candidate)
                guard let text = readText(at: url) else { continue }
                let relative = manifestDirectory.isEmpty ? candidate : "\(manifestDirectory)/\(candidate)"
                guard let resolution = DependencyLockParser.parse(fileName: candidate,
                                                                 text: text,
                                                                 relativePath: relative) else { continue }
                for recordIndex in report.ecosystems[ecoIndex].dependencies.indices
                where report.ecosystems[ecoIndex].dependencies[recordIndex].resolvedVersion == nil {
                    let record = report.ecosystems[ecoIndex].dependencies[recordIndex]
                    guard let hit = resolution.resolvedVersion(name: record.name,
                                                              declaredRange: record.version) else { continue }
                    report.ecosystems[ecoIndex].dependencies[recordIndex].resolvedVersion = hit
                    report.ecosystems[ecoIndex].dependencies[recordIndex].resolvedVersionSource = relative
                }
            }
        }
    }

    /// 离线时的「我们没做什么」说明，与在线路径同等直白（在线侧在
    /// `DependencyNetworkLookup` 里会把失败与未覆盖生态写进 note，离线侧原先什么都没有，
    /// 于是 `vulnerableCount = 0` 读起来像"查过、干净"）。
    static func offlineCaveat(for report: DependencyReport) -> String {
        let records = report.ecosystems.flatMap(\.dependencies)
        let skipped = records.filter { KnownVulnerability.comparableCore($0.version) == nil }.count
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
