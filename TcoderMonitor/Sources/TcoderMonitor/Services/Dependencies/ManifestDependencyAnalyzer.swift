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
    let fileManager: FileManager   // 跨文件可见：版本证据分片（本类型 extension）要用
    /// 在线核对的数据源。默认是真源（OSV + npm registry）；测试里换成假源，
    /// 于是「npm 成功 + OSV 失败」「预算截断」「部分失败」都能在**不打的网**的前提下钉住。
    /// 协议形状按 AGENTS §3：不动 `ServiceContracts` 的冻结协议，只给具体类型加带默认值的参数。
    let onlineSource: any DependencyOnlineSource

    /// 本轮从**已解析产物**（effective-POM / 依赖树 / SBOM）里读到的证据（RD-13b 的披露面）：
    /// 文件 -> 它给出确切版本的条数。存在这里是为了让"依据哪份文件"能随报告一起说出口
    /// （台账 §4 第 1 条：重要结论要能追溯）。存储属性必须住在类本体（扩展不许带存储），
    /// 而写它的是同类型在另一文件里的 extension（400 行口径拆的），故只能是 internal。
    var resolvedArtifactEvidence: [(file: String, entries: Int)] = []
    /// 每份锁文件/产物解析出的条数与歧义数（歧义 = 同名多版本，一律不回填、不猜）。
    var resolutionProvenance: [String: (entries: Int, ambiguous: Int)] = [:]

    init(options: ScanOptions = .default,
         maxDepth: Int = ManifestDependencyAnalyzer.defaultMaxDepth,
         maxManifestBytes: Int = 4_000_000,
         fileManager: FileManager = .default,
         onlineSource: any DependencyOnlineSource = LiveDependencyOnlineSource()) {
        self.options = options
        self.maxDepth = max(1, maxDepth)
        self.maxManifestBytes = maxManifestBytes
        self.fileManager = fileManager
        self.onlineSource = onlineSource
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
        applyLockResolutions(&report, root: projectRoot)
        applyBundledKnowledge(&report)
        if allowNetwork {
            await applyNetworkKnowledge(&report)
        } else {
            report.networkLookupPerformed = false
            report.networkLookupNote = Self.offlineCaveat(
                for: report, resolvedArtifacts: resolvedArtifactEvidence.map(\.file))
            // 离线也要落账：逐条状态 + 报告级账本 + 分 scope 统计一次写完。
            // 不写的话消费端只能读到 nil，而 nil 在账本里就是"没测过"——
            // 那正是"未查"该有的形状，但总览与评分需要拿到**为什么**未查的分档计数。
            applyCheckStates(&report, online: nil)
        }
        return report
    }

    // MARK: - Manifest discovery

    private struct ManifestHit: Equatable {
        var url: URL
        var relativePath: String
        var directoryRelativePath: String
    }

    /// 广度优先队列里的一项。
    private struct ScanEntry {
        var directory: URL
        var relative: String
        var depth: Int
    }

    /// 广度优先扫描：目录深度上限 `maxDepth`，符号链接不跟随，隐藏目录按 `includeHidden` 决定。
    /// 单个目录项的判定抽在 `discoverQueueEntry` 里，那里的每一条 guard/continue
    /// 都原样映射成 return，行为与抽取前逐字一致。
    private func discoverManifests(root: URL) -> [ManifestHit] {
        var hits: [ManifestHit] = []
        var seenPaths = Set<String>()
        var queue: [ScanEntry] = [ScanEntry(directory: root, relative: "", depth: 0)]
        var cursor = 0

        while cursor < queue.count {
            let entry = queue[cursor]
            cursor += 1
            guard let names = try? fileManager.contentsOfDirectory(atPath: entry.directory.path) else { continue }
            for name in names.sorted() {
                discoverQueueEntry(name: name, in: entry,
                                   hits: &hits, queue: &queue, seenPaths: &seenPaths)
            }
        }

        return expandMavenModules(hits, root: root, seenPaths: &seenPaths)
    }

    /// 处理队列某一项目录下的一个名字：要么下潜（追加队列）、要么收成一次清单命中。
    private func discoverQueueEntry(name: String,
                                    in entry: ScanEntry,
                                    hits: inout [ManifestHit],
                                    queue: inout [ScanEntry],
                                    seenPaths: inout Set<String>) {
        let url = entry.directory.appendingPathComponent(name)
        let relative = entry.relative.isEmpty ? name : "\(entry.relative)/\(name)"
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        if values?.isSymbolicLink == true { return }

        if values?.isDirectory == true {
            if options.skipDirectories.contains(name) { return }
            if !options.includeHidden && name.hasPrefix(".") { return }
            if entry.depth + 1 <= maxDepth {
                queue.append(ScanEntry(directory: url, relative: relative, depth: entry.depth + 1))
            }
            return
        }
        guard ManifestFileName.ecosystem(for: name) != nil else { return }
        if seenPaths.insert(relative).inserted {
            hits.append(ManifestHit(url: url,
                                    relativePath: relative,
                                    directoryRelativePath: entry.relative))
        }
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

    func readText(at url: URL) -> String? {
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
            // 查询用的是**版本身份**给出的那个数（锁文件解析值优先，其次精确声明，
            // 最后才是范围下界）；三样都没有就不比对，否则 "未声明"、"*"、"latest"
            // 会被当成 0.0.0 一律判成过旧 —— 旧实现这里是 `comparableCore(version)`，
            // 与在线侧的取数口径不是一套，两处各自解释同一个 `^1.2.3`。
            let identity = DependencyVersionIdentity.of(record)
            guard let queryVersion = identity.query?.version else { return }
            record = DependencySnapshot.applySnapshotInfo(to: record)
            let hits = VulnerabilitySource.matches(ecosystem: record.ecosystem,
                                                   name: record.name,
                                                   version: queryVersion)
            guard !hits.isEmpty else { return }
            record.knownVulnerabilities = Self.deduped(hits.map { $0.cveIdentifiers.first ?? $0.id })
        }
        report.offlineVulnerabilities = VulnerabilitySource.offlineVulnerabilities(for: allRecords(report))
    }

    // MARK: - Shared plumbing

    func allRecords(_ report: DependencyReport) -> [DependencyRecord] {
        report.ecosystems.flatMap(\.dependencies)
    }

    static func mutateRecords(_ ecosystems: inout [EcosystemReport],
                                      _ transform: (inout DependencyRecord) -> Void) {
        for ecosystemIndex in ecosystems.indices {
            for recordIndex in ecosystems[ecosystemIndex].dependencies.indices {
                transform(&ecosystems[ecosystemIndex].dependencies[recordIndex])
            }
        }
    }

    static func deduped(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
