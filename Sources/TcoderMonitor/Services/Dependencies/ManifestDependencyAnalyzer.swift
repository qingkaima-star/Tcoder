import Foundation

/// OWNER: WS-B（依赖分析入口）。类型名与协议一致性已冻结。
///
/// 职责：在项目树里找清单（深度 ≤ 6、跳过 `ScanOptions.skipDirectories`）、
/// 交给 `ManifestParsers` 解析、用 `DependencySnapshot` / `VulnerabilitySource`
/// 回填版本与内置漏洞；只有 `allowNetwork == true` 才走 `DependencyNetworkLookup`，
/// 且任何在线失败都只是把说明写进 `networkLookupNote`，绝不影响本次分析产出。
final class ManifestDependencyAnalyzer: DependencyAnalysisProviding {

    static let defaultMaxDepth = 6
    private static let maxMavenModuleExpansions = 200

    private let options: ScanOptions
    private let maxDepth: Int
    private let maxManifestBytes: Int
    private let fileManager: FileManager

    init(options: ScanOptions = .default,
         maxDepth: Int = ManifestDependencyAnalyzer.defaultMaxDepth,
         maxManifestBytes: Int = 4_000_000,
         fileManager: FileManager = .default) {
        self.options = options
        self.maxDepth = max(1, maxDepth)
        self.maxManifestBytes = maxManifestBytes
        self.fileManager = fileManager
    }

    // MARK: - Entry point

    func analyze(projectRoot: URL, allowNetwork: Bool) async throws -> DependencyReport {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: projectRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw AnalysisError.notDirectory(projectRoot.path)
        }

        var ecosystems: [EcosystemReport] = []
        for hit in discoverManifests(root: projectRoot) {
            guard let text = readText(at: hit.url) else { continue }
            let listing = Set(directoryListing(of: hit))
            guard let parsed = ManifestParsers.parse(text: text,
                                                    manifestPath: hit.relativePath,
                                                    directoryRelativePath: hit.directoryRelativePath,
                                                    directoryListing: listing) else {
                // 认得出是清单、但一条外部依赖都没有（例如本仓库自己的 Package.swift）。
                // 仍产出一张 0 依赖卡片，UI 才能区分「有清单无依赖」和「根本没有清单」。
                guard let ecosystem = ManifestFileName.ecosystem(for: hit.url.lastPathComponent) else { continue }
                ecosystems.append(EcosystemReport(ecosystem: ecosystem,
                                                  manifestPath: hit.relativePath,
                                                  lockfileName: ManifestParsers.lockfileName(for: ecosystem,
                                                                                             in: listing),
                                                  dependencies: [],
                                                  frameworkMarkers: []))
                continue
            }
            ecosystems.append(EcosystemReport(ecosystem: parsed.ecosystem,
                                              manifestPath: parsed.manifestRelativePath,
                                              lockfileName: parsed.lockfileName,
                                              dependencies: parsed.dependencies,
                                              frameworkMarkers: parsed.frameworkMarkers))
        }
        ecosystems.sort(by: Self.manifestOrder)

        var report = DependencyReport(analyzedAt: Date(), ecosystems: ecosystems)
        applyBundledKnowledge(&report)
        if allowNetwork {
            await applyNetworkKnowledge(&report)
        } else {
            report.networkLookupPerformed = false
        }
        return report
    }

    // MARK: - Manifest discovery

    private struct ManifestHit: Equatable {
        var url: URL
        var relativePath: String
        var directoryRelativePath: String
    }

    /// 广度优先扫描：目录深度上限 `maxDepth`，符号链接不跟随，隐藏目录按 `includeHidden` 决定。
    private func discoverManifests(root: URL) -> [ManifestHit] {
        var hits: [ManifestHit] = []
        var seenPaths = Set<String>()
        var queue: [(directory: URL, relative: String, depth: Int)] = [(root, "", 0)]
        var cursor = 0

        while cursor < queue.count {
            let entry = queue[cursor]
            cursor += 1
            guard let names = try? fileManager.contentsOfDirectory(atPath: entry.directory.path) else { continue }

            for name in names.sorted() {
                let url = entry.directory.appendingPathComponent(name)
                let relative = entry.relative.isEmpty ? name : "\(entry.relative)/\(name)"
                let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                if values?.isSymbolicLink == true { continue }

                if values?.isDirectory == true {
                    if options.skipDirectories.contains(name) { continue }
                    if !options.includeHidden && name.hasPrefix(".") { continue }
                    if entry.depth + 1 <= maxDepth {
                        queue.append((url, relative, entry.depth + 1))
                    }
                    continue
                }
                guard ManifestFileName.ecosystem(for: name) != nil else { continue }
                if seenPaths.insert(relative).inserted {
                    hits.append(ManifestHit(url: url,
                                            relativePath: relative,
                                            directoryRelativePath: entry.relative))
                }
            }
        }

        return expandMavenModules(hits, root: root, seenPaths: &seenPaths)
    }

    /// 多模块 Maven：父 pom 的 `<module>` 目录常常深过扫描上限，这里显式补一层。
    private func expandMavenModules(_ hits: [ManifestHit],
                                    root: URL,
                                    seenPaths: inout Set<String>) -> [ManifestHit] {
        var result = hits
        var pending = hits.filter { ManifestFileName.ecosystem(for: $0.url.lastPathComponent) == .maven }
        var expanded = 0
        var round = 0

        while !pending.isEmpty, expanded < Self.maxMavenModuleExpansions, round < maxDepth + 2 {
            round += 1
            var next: [ManifestHit] = []
            for hit in pending {
                guard let text = readText(at: hit.url) else { continue }
                for module in ManifestParsers.mavenModulePaths(in: text) {
                    guard let moduleURL = Self.resolve(module, inside: hit.url.deletingLastPathComponent(), root: root) else { continue }
                    let pomURL = moduleURL.appendingPathComponent("pom.xml")
                    let relative = Self.relativePath(of: pomURL, to: root)
                    guard !relative.isEmpty, seenPaths.insert(relative).inserted else { continue }
                    guard fileManager.fileExists(atPath: pomURL.path) else { continue }
                    let added = ManifestHit(url: pomURL,
                                           relativePath: relative,
                                           directoryRelativePath: (relative as NSString).deletingLastPathComponent)
                    result.append(added)
                    next.append(added)
                    expanded += 1
                    if expanded >= Self.maxMavenModuleExpansions { break }
                }
            }
            pending = next
        }
        return result
    }

    /// 模块路径必须仍然落在项目根之内（拒绝 `../` 逃逸），否则忽略。
    private static func resolve(_ module: String, inside directory: URL, root: URL) -> URL? {
        let cleaned = module.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !cleaned.contains("\0") else { return nil }
        let candidate = directory.appendingPathComponent(cleaned).standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.path
        guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else { return nil }
        return candidate
    }

    private func directoryListing(of hit: ManifestHit) -> [String] {
        (try? fileManager.contentsOfDirectory(atPath: hit.url.deletingLastPathComponent().path)) ?? []
    }

    private func readText(at url: URL) -> String? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size <= maxManifestBytes else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func relativePath(of url: URL, to root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return "" }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private static func manifestOrder(_ lhs: EcosystemReport, _ rhs: EcosystemReport) -> Bool {
        let lhsDepth = lhs.manifestPath.components(separatedBy: "/").count
        let rhsDepth = rhs.manifestPath.components(separatedBy: "/").count
        if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
        let comparison = lhs.manifestPath.localizedStandardCompare(rhs.manifestPath)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return lhs.ecosystem.rawValue < rhs.ecosystem.rawValue
    }

    // MARK: - Offline enrichment（内置快照 + 内置漏洞）

    private func applyBundledKnowledge(_ report: inout DependencyReport) {
        Self.mutateRecords(&report.ecosystems) { record in
            // 只有声明版本能收敛成数字（`^1.2`、`5.6`）才回填，否则 "未声明"、"*"、"latest"
            // 会被冻结契约的 isProbablyOutdated 当成 0.0.0 一律判成过旧。
            guard KnownVulnerability.comparableCore(record.version) != nil else { return }
            record = DependencySnapshot.applySnapshotInfo(to: record)
            let hits = VulnerabilitySource.matches(ecosystem: record.ecosystem,
                                                   name: record.name,
                                                   version: record.version)
            guard !hits.isEmpty else { return }
            record.knownVulnerabilities = Self.deduped(hits.map { $0.cveIdentifiers.first ?? $0.id })
        }
        report.offlineVulnerabilities = VulnerabilitySource.offlineVulnerabilities(for: allRecords(report))
    }

    // MARK: - Optional online enrichment

    private func applyNetworkKnowledge(_ report: inout DependencyReport) async {
        let records = allRecords(report)
        var notes: [String] = []
        var attempted = 0

        let npmNames = records.filter { $0.ecosystem == .npm }.map(\.name)
        if !npmNames.isEmpty {
            attempted += 1
            let registry = await DependencyNetworkLookup.npmLatestVersions(npmNames)
            if !registry.latestVersions.isEmpty {
                Self.mutateRecords(&report.ecosystems) { record in
                    guard record.ecosystem == .npm,
                          KnownVulnerability.comparableCore(record.version) != nil,
                          let latest = registry.latestVersions[record.name] else { return }
                    record.latestKnownVersion = latest
                    record.versionCheckSource = .onlineRegistry
                }
            }
            if registry.failedRequests > 0 {
                notes.append("npm registry：\(registry.packagesChecked) 个包中 \(registry.failedRequests) 个查询失败")
            }
            if !registry.note.isEmpty { notes.append(registry.note) }
        }

        let osv = await DependencyNetworkLookup.osvBatch(for: records)
        if osv.packagesChecked > 0 {
            attempted += 1
            let covered = Self.coveredIdentifiers(in: records)
            let fresh = osv.advisories.filter { advisory in
                !Self.intersects(covered, with: [advisory.id] + advisory.aliases)
            }
            report.advisories = VulnerabilitySource.sortedAdvisories(fresh)
            Self.merge(advisories: fresh, into: &report.ecosystems)
            if osv.failedRequests > 0 {
                notes.append("OSV：\(osv.packagesChecked) 个包中 \(osv.failedRequests) 个查询失败")
            }
        }
        if !osv.note.isEmpty { notes.append(osv.note) }

        report.networkLookupPerformed = attempted > 0
        report.networkLookupNote = notes.isEmpty
            ? (attempted > 0 ? "在线查询已完成（OSV + npm registry）" : "本项目没有可在线查询的生态（SwiftPM / CocoaPods 不在 OSV 覆盖范围内）")
            : notes.joined(separator: "；")
    }

    /// 已被内置规则覆盖的标识（CVE + 规则 id），用于避免在线结果重复计入。
    private static func coveredIdentifiers(in records: [DependencyRecord]) -> Set<String> {
        var covered = Set<String>()
        for record in records {
            covered.formUnion(VulnerabilitySource.coveredIdentifiers(ecosystem: record.ecosystem,
                                                                     name: record.name,
                                                                     version: record.version))
        }
        return covered
    }

    private static func intersects(_ set: Set<String>, with values: [String]) -> Bool {
        values.contains { set.contains($0) }
    }

    /// 把在线公告的 CVE 编号并回受影响依赖的 `knownVulnerabilities`。
    private static func merge(advisories: [SecurityAdvisory], into ecosystems: inout [EcosystemReport]) {
        guard !advisories.isEmpty else { return }
        var cvesByCoordinate: [String: [String]] = [:]
        for advisory in advisories {
            let payload = advisory.aliases.filter { $0.hasPrefix("CVE-") }
            let identifiers = payload.isEmpty ? [advisory.id] : payload
            for package in advisory.affectedPackages {
                cvesByCoordinate[package, default: []].append(contentsOf: identifiers)
            }
        }
        mutateRecords(&ecosystems) { record in
            guard let extra = cvesByCoordinate["\(record.name)@\(record.version)"] else { return }
            record.knownVulnerabilities = deduped(record.knownVulnerabilities + extra)
        }
    }

    // MARK: - Shared plumbing

    private func allRecords(_ report: DependencyReport) -> [DependencyRecord] {
        report.ecosystems.flatMap(\.dependencies)
    }

    private static func mutateRecords(_ ecosystems: inout [EcosystemReport],
                                      _ transform: (inout DependencyRecord) -> Void) {
        for ecosystemIndex in ecosystems.indices {
            for recordIndex in ecosystems[ecosystemIndex].dependencies.indices {
                transform(&ecosystems[ecosystemIndex].dependencies[recordIndex])
            }
        }
    }

    private static func deduped(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
