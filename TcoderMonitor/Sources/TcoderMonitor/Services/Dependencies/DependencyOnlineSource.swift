// OWNER: R3 依赖证据链 · 在线核对的注入缝与回执（RD-11 / RD-12）
//
// 为什么要有这一层：`applyNetworkKnowledge` 原先直接写死
// `DependencyNetworkLookup.npmLatestVersions(...)` / `.osvBatch(for:)` 两个静态调用，
// 于是"npm 成功 + OSV 失败"、"预算截断"、"部分失败"这些结局**只能靠真打公网去凑**，
// 而本轮的硬要求是这些状态必须能在不打网的用例里被钉住。
// 协议形状按 AGENTS §3 的做法：不动 `ServiceContracts` 里的冻结协议，只给自己那个
// 具体类型加**带默认值的参数**（`ManifestDependencyAnalyzer(onlineSource:)`）。
import Foundation

/// 一条 OSV 查询的结局。**逐条**记，是为了让"这条依赖没查成"能长成依赖行上的一个字。
enum DependencyOsvOutcome: Equatable, Sendable {
    /// 批量端点答上了（空数组 = 答上了且没有公告）。
    case answered(advisories: [SecurityAdvisory])
    /// 发了请求但失败 / 超时 / 响应解不出来。
    case failed
    /// 生态不支持或版本没解析出来 ⇒ 压根没发请求（调用方负责落原因）。
    case skipped
}

/// 一次在线核对的回执，按**查询身份**回传（RD-12：查询用的 key 与回填用的 key 同源）。
struct DependencyOnlineReceipt: Sendable {
    /// registry 答上的包：包名 -> 最新版本。
    var latestVersions: [String: String] = [:]
    /// registry 明确失败的包名。
    var failedRegistryPackages: [String] = []
    /// OSV 逐条结局，key 是 `DependencyVersionIdentity.coordinate(...)`。
    var osvOutcomes: [String: DependencyOsvOutcome] = [:]
    /// 两路各自自述的补充说明（网络/截断等），只用于人读的那句，**不参与任何判定**。
    var registryNote: String = ""
    var osvNote: String = ""
    /// OSV 整体失败（超时 / 批量端点不可用且回退也失败）：此时未答上的那批一律记 `.failed`。
    var osvPathUnavailable = false
}

/// 在线数据源。生产实现就是现有那两个静态入口的薄壳。
protocol DependencyOnlineSource: Sendable {
    func registryLatestVersions(for packages: [String]) async -> DependencyOnlineReceipt
    func osvAdvisories(for queries: [OsvPackageQuery]) async -> DependencyOnlineReceipt
}

/// 真打公网的那一路（默认实现）。**不新增任何网络行为**：只是把已有的两个入口
/// 收成一个可替换的缝，并把它们已经知道的成败信息按查询身份回传。
struct LiveDependencyOnlineSource: DependencyOnlineSource {
    func registryLatestVersions(for packages: [String]) async -> DependencyOnlineReceipt {
        let result = await DependencyNetworkLookup.npmLatestVersions(packages)
        var receipt = DependencyOnlineReceipt()
        receipt.latestVersions = result.latestVersions
        // registry 的账本是"每包一次 GET"：没答上的名字即失败（数量口径由下面这行对齐）。
        receipt.failedRegistryPackages = packages.filter { !result.latestVersions.keys.contains($0) }
        receipt.registryNote = result.note
        return receipt
    }

    func osvAdvisories(for queries: [OsvPackageQuery]) async -> DependencyOnlineReceipt {
        let result = await DependencyNetworkLookup.osvBatch(queries)
        var receipt = DependencyOnlineReceipt()
        // 逐条归因：公告的 affectedPackages 里出现过的那条查询身份 = 确实答上了。
        var hitsByCoordinate: [String: [SecurityAdvisory]] = [:]
        for advisory in result.advisories {
            for coordinate in advisory.affectedPackages {
                hitsByCoordinate[coordinate, default: []].append(advisory)
            }
        }
        for query in queries {
            let coordinate = query.coordinate
            if let advisories = hitsByCoordinate[coordinate] {
                receipt.osvOutcomes[coordinate] = .answered(advisories: advisories)
            }
        }
        // 剩下的是"没公告"还是"没答上"？靠**计数**分开，不靠中文说明（RD-13）：
        //   · `failedRequests == 0` ⇒ 批量端点按顺序把每条查询都答过了，空结果就是干净；
        //   · `failedRequests > 0` 而本条没有命中 ⇒ 无法归因到具体哪几条，保守记 `.failed`
        //     （宁可少说"核对过"，也不把没答上的包说成答上了）。
        // 整路超时由 `OsvLookupResult` 自己保证 `failedRequests == packagesChecked`。
        let partialFailure = result.failedRequests > 0
        for query in queries where receipt.osvOutcomes[query.coordinate] == nil {
            receipt.osvOutcomes[query.coordinate] = partialFailure ? .failed : .answered(advisories: [])
        }
        receipt.osvPathUnavailable = result.failedRequests >= max(1, result.packagesChecked)
        receipt.osvNote = result.note
        return receipt
    }
}

extension OsvPackageQuery {
    /// **查询与回填共用的那一个 key**：由版本身份算出，禁止任何一侧自己拼 `name@version`。
    var coordinate: String {
        DependencyVersionIdentity.coordinate(ecosystem: dependencyEcosystem,
                                             name: package, queryVersion: version)
    }

    /// OSV 查询用的生态（回指成依赖生态，坐标 key 必须与记录侧同源）。
    var dependencyEcosystem: DependencyEcosystem {
        OsvPackageQuery.dependencyEcosystem(for: ecosystem) ?? .unknown
    }

    /// 由依赖记录构造查询：版本用**解析身份**（锁文件优先），不解析就不查。
    static func query(from record: DependencyRecord) -> (query: OsvPackageQuery, coordinate: String)? {
        guard let ecosystem = OsvPackageQuery.osvEcosystem(for: record.ecosystem) else { return nil }
        guard let queryVersion = DependencyVersionIdentity.of(record).query?.version else { return nil }
        let name = record.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let built = OsvPackageQuery(ecosystem: ecosystem, package: name, version: queryVersion)
        return (built, built.coordinate)
    }
}
