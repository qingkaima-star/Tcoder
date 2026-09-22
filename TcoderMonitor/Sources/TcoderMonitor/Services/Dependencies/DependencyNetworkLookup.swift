// 在线查询入口 + 预算与限流（WS-B · 依赖安全四层里的第 4 层）
//
// 只有公共入口、参数上限、host 覆盖探针、HTTP 管道与共享 session/decoder；
// OSV 的具体协议在 OsvClient.swift，npm registry 在 NpmClient.swift（都是本类型的 extension）。
// 拆到多文件后跨文件可见的成员一律 internal（原本 private），这是模块内部类型，不对外暴露。
import Foundation

/// 由依赖记录构造 OSV 查询的入口**只有一个**：`OsvPackageQuery.query(from:)`
/// （住在 `DependencyOnlineSource.swift`，与回填 key 同源）。
///
/// 这里原先还有一条 `static func make(from:)`：它用第二套版本解析器
/// `KnownVulnerability.comparableCore` 判"能不能查"并自己剥 `^`。两套解析器并存正是
/// RD-10 的根因（台账 §9.5 第 1 条点名），而"查询用收敛后的版本、回填用声明原文"
/// 又正是 RD-12 的症状 —— 所以这条重复入口整个删掉，只留身份那一份。
struct OsvPackageQuery: Equatable, Sendable {
    /// OSV 生态名："npm" / "Maven" / "PyPI" / "Go" / "crates.io" / "RubyGems" / "NuGet"。
    /// OSV 不覆盖 SwiftPM / CocoaPods，这类依赖直接不查（`query(from:)` 返回 nil）。
    var ecosystem: String
    var package: String
    var version: String

    /// 依赖生态 -> OSV 生态名；OSV 不覆盖的返回 nil。
    static func osvEcosystem(for ecosystem: DependencyEcosystem) -> String? {
        switch ecosystem {
        case .npm: return "npm"
        case .maven, .gradle: return "Maven"
        case .python: return "PyPI"
        case .go: return "Go"
        case .cargo: return "crates.io"
        case .ruby: return "RubyGems"
        case .nuget: return "NuGet"
        case .swiftPM, .cocoapods, .unknown: return nil
        }
    }

    /// OSV 生态名 -> 依赖生态（大小写不敏感）。
    static func dependencyEcosystem(for name: String) -> DependencyEcosystem? {
        switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "npm": return .npm
        case "maven", "gradle": return .maven
        case "pypi", "python": return .python
        case "go", "golang": return .go
        case "crates.io", "cargo", "rust": return .cargo
        case "rubygems", "ruby": return .ruby
        case "nuget": return .nuget
        default: return nil
        }
    }
}

/// 一条 OSV 公告详情拉取的结局。
enum OsvDetailOutcome: Equatable, Sendable {
    case fetched
    case failed
    /// 预算用尽，根本没去发这个请求。
    case notAttempted
}

/// 详情展开的账本。
struct OsvDetailTally: Equatable, Sendable {
    var totalIDs: Int
    var fetched: Int
    var failed: Int
    var notAttemptedByBudget: Int
    /// 超出 `maxOsvDetailRequests` 上限、压根没进队列的条数。
    var skippedByCap: Int

    init(totalIDs: Int, outcomes: [OsvDetailOutcome]) {
        var fetched = 0, failed = 0, notAttempted = 0
        for outcome in outcomes {
            switch outcome {
            case .fetched: fetched += 1
            case .failed: failed += 1
            case .notAttempted: notAttempted += 1
            }
        }
        self.totalIDs = totalIDs
        self.fetched = fetched
        self.failed = failed
        self.notAttemptedByBudget = notAttempted
        self.skippedByCap = max(0, totalIDs - outcomes.count)
    }

    var needsDisclosure: Bool {
        failed > 0 || notAttemptedByBudget > 0 || skippedByCap > 0
    }
}

struct OsvLookupResult: Sendable {
    var advisories: [SecurityAdvisory]
    var packagesChecked: Int
    var failedRequests: Int
    /// 简体中文说明，成功时为 ""。
    var note: String
}

struct RegistryLookupResult: Sendable {
    var latestVersions: [String: String]
    var packagesChecked: Int
    var failedRequests: Int
    var note: String
}

/// 在线查询：OSV 漏洞库与 npm registry。任何失败 / 超时都只体现在 `note` 与计数里，绝不抛出。

enum DependencyNetworkLookup {

    /// 单次请求硬超时（秒），也是整体查询的时间预算。
    static let requestTimeout: TimeInterval = 5
    /// OSV 批量接口单次最多查询的包数。
    static let maxOsvBatchPackages = 100
    /// npm 并发窗口（同时在飞的请求数）。
    static let npmConcurrency = 30
    /// npm 单次最多查询包数（防止超大仓库把调用方拖死）。
    static let maxNpmPackages = 200
    /// OSV 详情二次拉取的条数与并发上限。
    static let maxOsvDetailRequests = 40
    static let osvDetailConcurrency = 8

    /// 在线查询默认打到的真实主机名（写死，防止任何路径偷偷去访问别的地址）。
    static let osvHost = "api.osv.dev"
    static let npmRegistryHost = "registry.npmjs.org"

    /// 主机名替换开关的环境变量键。**只服务于「把 5 秒硬超用量出来」的实测**，
    /// App 运行时永远不会设置它，因此线上行为与写死域名逐字节一致。
    ///
    /// 为什么要有这个口子：在线结论必须打到真实域名才算验证过，但要量出硬超时，
    /// 又必须让请求落到一个「只丢包、永不应答」的地址（RFC 5737 文档地址段
    /// 192.0.2.0/24、198.51.100.0/24）。替换只改主机名 —— scheme、path、请求体、
    /// 超时值、`withHardDeadline` 一概不动，所以量出来的仍是真实网络栈上的耗时。
    static let hostOverrideEnvironmentKey = "TCODER_DEPENDENCY_HOST_OVERRIDE"

    /// 逐次即时读取（测试里 `setenv` 之后立刻生效，不需要重启进程）。
    static func host(replacing defaultHost: String) -> String {
        let raw = ProcessInfo.processInfo.environment[hostOverrideEnvironmentKey] ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultHost : trimmed
    }

    static func osvURL(_ path: String) -> URL? {
        URL(string: "https://\(host(replacing: osvHost))/\(path)")
    }

    static func npmURL(_ encodedPackage: String) -> URL? {
        URL(string: "https://\(host(replacing: npmRegistryHost))/\(encodedPackage)/latest")
    }

    /// 批量查 OSV。
    ///
    /// 实现说明：OSV 的批量端点是 `POST https://api.osv.dev/v1/querybatch`，请求体
    /// `{"queries":[{"package":{"name","ecosystem"},"version"}]}`，响应 `{"results":[{"vulns":[{"id",…}]}]}`
    /// 且与请求顺序一一对应；`/v1/query` 只接受**单条** query，向其发 `{"queries":[…]}` 会返回 400。
    /// 由于 querybatch 只回 id，再用 `GET /v1/vulns/<id>` 补齐 summary / severity 等详情。
    static func osvBatch(_ queries: [OsvPackageQuery]) async -> OsvLookupResult {
        var skipped = 0
        var supported: [OsvPackageQuery] = []
        supported.reserveCapacity(queries.count)
        for query in queries {
            let name = query.package.trimmingCharacters(in: .whitespacesAndNewlines)
            let version = query.version.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !version.isEmpty,
                  OsvPackageQuery.dependencyEcosystem(for: query.ecosystem) != nil else {
                skipped += 1
                continue
            }
            supported.append(OsvPackageQuery(ecosystem: query.ecosystem, package: name, version: version))
        }
        var notes: [String] = []
        if skipped > 0 {
            notes.append("\(skipped) 个依赖因 OSV 不支持其生态或版本未声明而未查询")
        }
        guard !supported.isEmpty else {
            return OsvLookupResult(advisories: [], packagesChecked: 0, failedRequests: 0,
                                   note: notes.joined(separator: noteSeparator))
        }
        let batch = Array(supported.prefix(maxOsvBatchPackages))
        notes.append(contentsOf: capNote(cap: maxOsvBatchPackages, attempted: supported.count, accepted: batch.count))

        return await registryLookup(
            notes: notes,
            batchCount: batch.count,
            timeoutNote: "OSV 查询超过 \(Int(requestTimeout)) 秒硬超时，本次在线漏洞结果整体放弃（含已取回但未来得及返回的公告）",
            run: { deadline in await Self.performOsvLookup(batch, deadline: deadline) },
            payloadNote: { $0.note },
            success: { payload, checked, note in
                OsvLookupResult(advisories: payload.advisories, packagesChecked: checked,
                                failedRequests: payload.failedRequests, note: note)
            },
            failure: { checked, note in
                OsvLookupResult(advisories: [], packagesChecked: checked,
                                failedRequests: checked, note: note)
            }
        )
    }

    /// 便捷入口：直接对一批依赖记录查 OSV（生态不支持 / 版本没解析出来的自动不查）。
    /// 取数口径**只有身份那一份**：`OsvPackageQuery.query(from:)`，与回填 key 同源。
    static func osvBatch(for dependencies: [DependencyRecord]) async -> OsvLookupResult {
        await osvBatch(dependencies.compactMap { OsvPackageQuery.query(from: $0)?.query })
    }

    /// GET https://registry.npmjs.org/<包名>/latest 取 `version`。并发 <=30，单个硬超时 5 秒，失败静默计数。
    static func npmLatestVersions(_ packages: [String]) async -> RegistryLookupResult {
        var seen = Set<String>()
        var names: [String] = []
        names.reserveCapacity(packages.count)
        for raw in packages {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !name.contains(" "), seen.insert(name).inserted else { continue }
            names.append(name)
        }
        var notes: [String] = []
        guard !names.isEmpty else {
            return RegistryLookupResult(latestVersions: [:], packagesChecked: 0, failedRequests: 0, note: "")
        }
        let batch = Array(names.prefix(maxNpmPackages))
        notes.append(contentsOf: capNote(cap: maxNpmPackages, attempted: names.count, accepted: batch.count))

        return await registryLookup(
            notes: notes,
            batchCount: batch.count,
            timeoutNote: "npm registry 查询超过 \(Int(requestTimeout)) 秒硬超时，已放弃在线版本结果",
            run: { deadline in await Self.performNpmLookup(batch, deadline: deadline) },
            payloadNote: { $0.note },
            success: { payload, checked, note in
                RegistryLookupResult(latestVersions: payload.versions, packagesChecked: checked,
                                     failedRequests: payload.failedRequests, note: note)
            },
            failure: { checked, note in
                RegistryLookupResult(latestVersions: [:], packagesChecked: checked,
                                     failedRequests: checked, note: note)
            }
        )
    }

    // MARK: - 两条在线路径共用的收口

    /// 多条说明并成一句中文时的分隔符。原先四处各自写字面量「；」，值完全相同，
    /// 收成一份以免将来有人只改一处。
    static let noteSeparator = "；"

    /// 超出单次上限时的说明；**没超出就返回空数组**（与原两处 `if count > batch.count`
    /// 只在超限时才 append 的行为一致）。文案与插值顺序逐字照抄。
    static func capNote(cap: Int, attempted: Int, accepted: Int) -> [String] {
        guard attempted > accepted else { return [] }
        return ["超出单次上限，仅查询前 \(cap) 个包（其余 \(attempted - accepted) 个未查）"]
    }

    /// 「两级超时保护 + 把 payload 自述的说明并进 notes + 结局分派」——OSV 与 npm
    /// 两条路径原本各写一遍这 14 行（工具点名的重复块），现在共用一份。
    ///
    /// 三个必须逐字保住的口径**全部留在调用方**，本函数不引入任何新数值：
    /// 超时那句中文文案、成功/失败各自怎么装配结果、以及批量数。
    /// 只有两处时间口径搬了进来，且与搬出前两处写的完全一致：
    /// 内层 `deadline = now + requestTimeout`，外层硬线 `requestTimeout + 1`
    /// （比内层多 1 秒：正常情况下内层会带着「已取回的部分」在 5 秒线自行返回，
    /// 外层只在真挂死时兜底，否则内层攒到的公告会被整个丢弃 —— 缺陷 D2 的另一半）。
    static func registryLookup<Payload: Sendable, Outcome: Sendable>(
        notes: [String],
        batchCount: Int,
        timeoutNote: String,
        run: @escaping @Sendable (Date) async -> Payload,
        payloadNote: @Sendable (Payload) -> String?,
        success: @Sendable (Payload, Int, String) -> Outcome,
        failure: @Sendable (Int, String) -> Outcome
    ) async -> Outcome {
        var merged = notes
        let deadline = Date().addingTimeInterval(requestTimeout)
        let outcome = await Self.withHardDeadline(requestTimeout + 1) { await run(deadline) }
        switch outcome {
        case .value(let payload):
            if let extra = payloadNote(payload), !extra.isEmpty { merged.append(extra) }
            return success(payload, batchCount, merged.joined(separator: noteSeparator))
        case .timedOut:
            merged.append(timeoutNote)
            return failure(batchCount, merged.joined(separator: noteSeparator))
        }
    }

    // MARK: - HTTP plumbing

    static func makeRequest(url: URL, deadline: Date) -> URLRequest {
        let remaining = deadline.timeIntervalSinceNow
        let interval = remaining.isFinite ? max(0.3, min(requestTimeout, remaining)) : requestTimeout
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: interval)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Tcoder-Project-Monitor", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func isOK(_ response: URLResponse?) -> Bool {
        guard let http = response as? HTTPURLResponse else { return false }
        return (200...299).contains(http.statusCode)
    }

    /// "@angular/core" -> "@angular%2Fcore"。
    static func npmPathEncoded(_ name: String) -> String? {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~@")
        var pieces: [String] = []
        for component in name.split(separator: "/", omittingEmptySubsequences: false) {
            guard let encoded = String(component).addingPercentEncoding(withAllowedCharacters: allowed) else {
                return nil
            }
            pieces.append(encoded)
        }
        return pieces.isEmpty ? nil : pieces.joined(separator: "%2F")
    }

    static func appendNote(_ note: inout String?, _ text: String) {
        note = note.map { $0 + "；" + text } ?? text
    }

    /// 报告说明里有没有**自述**「npm 侧有包没拿到结果」。
    ///
    /// 这四条措辞都是 npm 路径独有（逐包失败计数、整体硬超时、全军覆没、并发窗口耗尽时间预算）。
    /// 全量成功时 note 是 `在线查询已完成（OSV + npm registry）`，紧跟 "npm registry" 的是全角括号
    /// 而不是全角冒号，所以不会被误判成缺口 —— 误判会把真缺陷跳过去。
    /// 用途：让在线用例把「网络根本没给数据」和「给了数据却没归因」分开处理，前者跳过、后者必须失败。
    /// 已知不覆盖：`maxNpmPackages` 截断说明（不含上述措辞）。
    static func npmShortfallDisclosed(in note: String) -> Bool {
        note.contains("npm registry：")
            || note.contains("npm registry 查询超过")
            || note.contains("npm registry 全部")
            || note.contains("达到时间预算")
    }

    /// OSV 侧的同款判据：说明里有没有自述「有公告没查成 / 没来得及展开」。
    /// 成功说明是 `在线查询已完成（OSV + npm registry）`，不含下列任何一条措辞。
    static func osvShortfallDisclosed(in note: String) -> Bool {
        note.contains("OSV：")
            || note.contains("OSV 查询超过")
            || note.contains("OSV 批量接口不可用")
            || note.contains("OSV 详情：")
            || note.contains("个 OSV 请求失败")
            || note.contains("OSV 不支持其生态")
    }

    /// 硬超时保护：超时返回 `.timedOut`，调用方既不抛错也不会卡住。
    enum DeadlineResult<Value: Sendable>: Sendable {
        case value(Value)
        case timedOut
    }

    static func withHardDeadline<Value: Sendable>(
        _ seconds: TimeInterval,
        operation: @escaping @Sendable () async -> Value
    ) async -> DeadlineResult<Value> {
        await withTaskGroup(of: DeadlineResult<Value>.self) { group in
            group.addTask { .value(await operation()) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0.1, seconds) * 1_000_000_000))
                return .timedOut
            }
            let first = await group.next() ?? DeadlineResult<Value>.timedOut
            group.cancelAll()
            return first
        }
    }


    static let jsonDecoder = JSONDecoder()

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = requestTimeout * 2
        config.waitsForConnectivity = false
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }()
}
