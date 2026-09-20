import XCTest
@testable import TcoderMonitor

// WS-B · 子代理6（依赖在线查询实测）：验证四条主张 ——
//   ① 联网真能取回真实 CVE / registry 数据；② 5 秒硬超时真的生效；
//   ③ 离线 / 超时后的降级是诚实的（不会把「没核对」说成「很干净」）；④ 默认确实是关。
//
// 三类测试按**是否需要公网**分家，保证离线机器上整份套件仍然全绿：
//   1. `DependencyNetworkOfflineGuardTests` —— 不打公网：用 `127.0.0.1:1`（没人监听、连接立刻被拒）
//      模拟彻底断网；并把两个端点指向黑洞地址来证明「默认关 = 一个包都没发出去」。任何网络状况都能跑。
//   2. `DependencyNetworkTimeoutTests` —— 把主机名换成 RFC 5737 文档地址段（公网不可路由、只丢包
//      不应答）量硬超时。setUp 先用一条**不受任何保护**的裸请求确认该地址在本机真的会挂住
//      （curl 同地址实测 81.8 秒才失败），挂不住就整组 XCTSkip —— 宁可不测，也不给没意义的数。
//   3. `DependencyNetworkLiveTests` —— 真打 api.osv.dev / registry.npmjs.org 取真实 CVE。
//      预检 4 秒内握不上手就整组 XCTSkip。
//
// 主机名替换只有一个环境变量入口 `TCODER_DEPENDENCY_HOST_OVERRIDE`（见 VulnerabilitySource.swift
// 的 `host(replacing:)`）：改的仅是主机名，scheme / path / 请求体 / `requestTimeout` /
// `withHardDeadline` 一概不动，所以量到的是真实网络栈上的耗时；App 运行时永远不设该变量。
// 本文件不修改、也不放宽任何被测超时值。
//
// 夹具全在 `NSTemporaryDirectory()` 下即建即删；不读本机任何已有仓库。
// 2026-09-20 WS-X3：本文件 701 行超口径，四个类已各成文件；本文件只留夹具与 1) 离线守卫组。
// 在线实测对网络抖动敏感（同一请求观测到 0.9s 与 3.5s 两种结果），需要真实数据的用例最多重试 2 次，
// 每次耗时都会记进附件 —— 重试是给抖动留余地，不是放宽预算。

// MARK: - 探针与工具

enum NetProbe {
    /// RFC 5737 TEST-NET-1：公网不可路由。curl 实测 `https://192.0.2.10/v1/querybatch`
    /// 在 TLS 层挂 81.8 秒才报错（另一文档段 198.51.100.7 挂 83.9 秒）—— 天然的「永不应答」。
    static let blackHoleHost = "192.0.2.10"
    /// 本机没人监听的端口：连接立刻被拒，等价于「彻底没有网络」。
    static let refusedHost = "127.0.0.1:1"

    /// 裸请求（不受被测代码超时保护）在黑洞地址上的结果：
    /// nil = 未探测；`.some(nil)` = ceiling 秒内仍未结束（确实只丢包不应答）；`.some(秒)` = 提前结束。
    static var blackHoleProbe: Double??
    /// api.osv.dev 预检往返耗时；nil = 不可达。
    static var reachability: Double??

    static func osvReachable() async -> Double? {
        if let cached = reachability { return cached }
        let result = await rawCompletion(for: URL(string: "https://api.osv.dev/")!,
                                         requestBudget: 4, ceiling: 6)
        reachability = result
        return result
    }

    static func doesBlackHoleStall() async -> Bool {
        if let cached = blackHoleProbe { return cached == nil }
        let result = await rawCompletion(for: URL(string: "https://\(blackHoleHost)/v1/query")!,
                                         requestBudget: 100, ceiling: 20)
        blackHoleProbe = result
        return result == nil
    }

    /// 发一条裸 GET：返回结束耗时；超过 `ceiling` 还没结束就返回 nil 并取消该请求。
    static func rawCompletion(for url: URL, requestBudget: TimeInterval,
                             ceiling: TimeInterval) async -> Double? {
        let started = uptimeNow()
        return await withTaskGroup(of: Optional<Double>.self) { group in
            group.addTask {
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = requestBudget
                config.timeoutIntervalForResource = requestBudget
                config.waitsForConnectivity = false
                config.requestCachePolicy = .reloadIgnoringLocalCacheData
                let session = URLSession(configuration: config)
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                         timeoutInterval: requestBudget)
                request.httpMethod = "GET"
                _ = try? await session.data(for: request)
                session.invalidateAndCancel()
                return uptimeNow() - started
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(ceiling * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

/// 在 body 执行期间把 OSV / npm 的主机名整体换成 `host`，结束后恢复原值。
/// SwiftPM 的 XCTest runner 默认串行执行用例，故不额外加锁。
func withHostOverride<T>(_ host: String, _ body: () async throws -> T) async rethrows -> T {
    let key = DependencyNetworkLookup.hostOverrideEnvironmentKey
    let previous = ProcessInfo.processInfo.environment[key]
    host.withCString { _ = setenv(key, $0, 1) }
    defer {
        if let previous { previous.withCString { _ = setenv(key, $0, 1) } } else { unsetenv(key) }
    }
    return try await body()
}

func uptimeNow() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

func secondsText(_ value: TimeInterval) -> String { String(format: "%.3fs", value) }

// MARK: - 夹具

/// 在线查询用的依赖集合。
///
/// `snapshotBlind`（moment / semver / jquery / react 内置快照都没收录）是用来证明
/// 「拿到的版本确实来自 registry.npmjs.org，而不是内置字典」的抓手。
enum DepFixture {
    /// 只放 2 个 OSV 命中少（3 条公告）的包：详情二次拉取能稳稳落在 5 秒预算内。
    static let advisoryPackageJSON = """
    {
      "name": "tcoder-cve-advisory",
      "dependencies": { "jquery": "3.4.1", "semver": "7.3.5" }
    }
    """

    /// 只用来量 registry：5 个包一个并发窗口。
    static let registryPackageJSON = """
    {
      "name": "tcoder-cve-registry",
      "dependencies": {
        "lodash": "4.17.15",
        "moment": "2.29.0",
        "semver": "7.3.5",
        "jquery": "3.4.1",
        "react": "18.3.1"
      }
    }
    """

    /// 真实规模：npm + maven + python 共 12 条依赖，OSV 一次回 104 条公告 id（实测）。
    static let packageJSON = """
    {
      "name": "tcoder-cve-fixture",
      "dependencies": {
        "lodash": "4.17.15",
        "axios": "0.21.1",
        "jquery": "3.4.1",
        "moment": "2.29.0",
        "semver": "7.3.5",
        "react": "18.3.1"
      },
      "devDependencies": { "vite": "5.0.0" }
    }
    """

    static let pomXML = """
    <project>
      <dependencies>
        <dependency>
          <groupId>com.alibaba</groupId><artifactId>fastjson</artifactId><version>1.2.68</version>
        </dependency>
        <dependency>
          <groupId>org.apache.logging.log4j</groupId><artifactId>log4j-core</artifactId><version>2.14.1</version>
        </dependency>
      </dependencies>
    </project>
    """

    static let requirements = """
    requests==2.25.0
    urllib3==1.24.1
    jinja2==2.11.2
    """

    /// 一条内置规则都不命中（lodash 已是修复版 4.17.21，其余三内置快照不收录）的组合。
    /// 配合「在线没核对成功」使用，用来钉住降级后的报告长相。
    static let cleanPackageJSON = """
    {
      "name": "tcoder-cve-fixture-clean",
      "dependencies": {
        "lodash": "4.17.21",
        "jquery": "3.7.1",
        "moment": "2.30.1",
        "semver": "7.7.4"
      }
    }
    """

    static var full: [String: String] {
        ["package.json": packageJSON, "server/pom.xml": pomXML, "python/requirements.txt": requirements]
    }
}

extension XCTestCase {
    func makeDependencyProject(_ tag: String, files: [String: String]) throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tcoder-depnet-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        for (relative, text) in files {
            let url = base.appendingPathComponent(relative, isDirectory: false)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return base
    }

    func records(of report: DependencyReport) -> [DependencyRecord] { report.ecosystems.flatMap(\.dependencies) }

    func record(_ report: DependencyReport, named name: String) -> DependencyRecord? {
        records(of: report).first { $0.name == name }
    }

    /// 关键实测数字既打进输出、也存成附件，方便在 Obsidian 日志里引用同一份数。
    func logMeasurement(_ label: String, _ text: String) {
        print("[TCODER-DEPNET] \(label): \(text)")
        let attachment = XCTAttachment(string: "\(label): \(text)")
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 跑一次在线分析并量墙钟耗时。
    func analyzeOnline(_ root: URL) async throws -> (report: DependencyReport, seconds: TimeInterval) {
        let started = uptimeNow()
        let report = try await ManifestDependencyAnalyzer().analyze(projectRoot: root, allowNetwork: true)
        return (report, uptimeNow() - started)
    }
}

// MARK: - 1) 默认关闭 + 断网降级（不需要公网，任何时候都跑）

final class DependencyNetworkOfflineGuardTests: XCTestCase {

    /// 主张④：联网是显式 opt-in。开关关的时候，即使把两个端点都指到黑洞地址，
    /// 分析也必须在远小于 5 秒的时间内返回 —— 只要偷偷发过一次请求就不可能这么快。
    func testOfflineIsDefaultAndIssuesNoRequestEvenWhenEndpointsAreBlackHoles() async throws {
        let root = try makeDependencyProject("default-off", files: DepFixture.full)
        let budget = DependencyNetworkLookup.requestTimeout

        let started = uptimeNow()
        let report = try await withHostOverride(NetProbe.blackHoleHost) {
            try await ManifestDependencyAnalyzer().analyze(projectRoot: root, allowNetwork: false)
        }
        let seconds = uptimeNow() - started

        logMeasurement("主张④默认离线耗时",
                       "\(secondsText(seconds))（硬超时预算 \(Int(budget))s；同地址裸请求实测 81.8s）")
        XCTAssertLessThan(seconds, 2.0, "allowNetwork=false 却花了 \(seconds)s，说明偷偷发了请求")
        XCTAssertFalse(report.networkLookupPerformed, "没联网就不能声称联网查过")
        // 这条断言原本要求离线 note 必须为空串，但那与 P0#4（总工 21:0x 指派 WS-B）正相反：
        // 离线时 note 必须**主动自述"没查"**（含未覆盖生态与被跳过的不可比较版本数）。
        // 意图不变 —— 不许编造在线结论 —— 只是把"空"改成"只能是自述，不能夹带在线"。
        XCTAssertTrue(report.networkLookupNote.isEmpty || report.networkLookupNote.contains("未联网核对"),
                      "离线 note 只能是「没查」的自述，实得：\(report.networkLookupNote)")
        XCTAssertFalse(report.networkLookupNote.contains("在线公告"),
                       "离线 note 里不得出现任何在线结论，实得：\(report.networkLookupNote)")
        XCTAssertFalse(records(of: report).contains { $0.versionCheckSource == .onlineRegistry },
                       "离线时不得有记录声称版本来自在线源")
        XCTAssertTrue(report.advisories.isEmpty, "离线只该有内置结论，在线公告必须为空")
        XCTAssertFalse(report.offlineVulnerabilities.isEmpty, "离线仍要给出内置快照的 CVE 结论")
        XCTAssertEqual(DependencyReport().networkLookupPerformed, false, "模型层默认值也必须是关")
        XCTAssertGreaterThanOrEqual(report.totalDependencies, 11, "夹具本身要被解析出来")
    }

    /// 主张③：彻底断网（连接立刻被拒）时结果照样返回，并且必须在 note 里说清楚在线没查成。
    func testConnectionRefusedStillReturnsResultsAndSaysSoInPlainNote() async throws {
        let root = try makeDependencyProject("refused", files: DepFixture.full)

        let started = uptimeNow()
        let report = try await withHostOverride(NetProbe.refusedHost) {
            try await ManifestDependencyAnalyzer().analyze(projectRoot: root, allowNetwork: true)
        }
        let seconds = uptimeNow() - started

        logMeasurement("主张③断网降级耗时", "\(secondsText(seconds))，note=\(report.networkLookupNote)")
        XCTAssertLessThan(seconds, DependencyNetworkLookup.requestTimeout, "连接被拒不该占满 5 秒预算")
        XCTAssertFalse(report.ecosystems.isEmpty, "断网也必须返回依赖清单")
        XCTAssertGreaterThanOrEqual(report.totalDependencies, 11)
        XCTAssertFalse(report.offlineVulnerabilities.isEmpty, "内置 CVE 结论必须保留")
        XCTAssertTrue(report.networkLookupPerformed, "确实尝试过在线查询，必须记为 true")
        XCTAssertFalse(report.networkLookupNote.isEmpty, "失败必须落到 networkLookupNote")
        XCTAssertTrue(report.networkLookupNote.contains("失败") || report.networkLookupNote.contains("超时"),
                      "note 要直说没查成，实测：\(report.networkLookupNote)")
        XCTAssertTrue(report.advisories.isEmpty, "没查成就不能凭空造在线公告")
        XCTAssertFalse(records(of: report).contains { $0.versionCheckSource == .onlineRegistry },
                       "失败时不得把版本来源冒充成在线源")
    }

    /// 主张③的反面检查（钉**现状**，不是认可）：在线没核对成功、又恰好没有内置命中时，
    /// 报告的「漏洞数 / 风险等级」仍然是 0 / 无风险 —— 唯一的未核对信号只有自由文本 note。
    /// 修好最终汇报里的 D1/D2/D3 时这条会红，请连同视图与评分一起改。
    func testUnverifiedLookupStillPresentsZeroVulnerabilitiesAsClean_currentBehaviourPinned() async throws {
        let root = try makeDependencyProject("unverified-clean",
                                             files: ["package.json": DepFixture.cleanPackageJSON])
        let report = try await withHostOverride(NetProbe.refusedHost) {
            try await ManifestDependencyAnalyzer().analyze(projectRoot: root, allowNetwork: true)
        }

        XCTAssertTrue(report.networkLookupNote.contains("失败"), "note 里必须写明在线失败")
        XCTAssertEqual(report.totalDependencies, 4)
        XCTAssertEqual(report.vulnerableCount, 0)
        XCTAssertEqual(report.riskLevel, RiskLevel.none,
                       "现状：riskLevel 不区分「核对过确实干净」和「压根没核对成」")
        XCTAssertNil(records(of: report).first { $0.versionCheckSource == .onlineRegistry })
        logMeasurement("缺陷 D3 现场",
                       "vulnerableCount=\(report.vulnerableCount) riskLevel=\(report.riskLevel.rawValue) "
                       + "note=\(report.networkLookupNote)")
    }

    /// 两个查询函数自己也要如实汇报失败计数（不经过分析器这一层）。
    func testLookupFunctionsThemselvesReportFailureCounts() async throws {
        let queries = [
            OsvPackageQuery(ecosystem: "npm", package: "jquery", version: "3.4.1"),
            OsvPackageQuery(ecosystem: "Maven", package: "com.alibaba:fastjson", version: "1.2.68"),
        ]
        let started = uptimeNow()
        let osv = await withHostOverride(NetProbe.refusedHost) {
            await DependencyNetworkLookup.osvBatch(queries)
        }
        let registry = await withHostOverride(NetProbe.refusedHost) {
            await DependencyNetworkLookup.npmLatestVersions(["jquery", "moment"])
        }

        logMeasurement("OSV 断网返回值",
                       "advisories=\(osv.advisories.count) failed=\(osv.failedRequests) "
                       + "checked=\(osv.packagesChecked) note=\(osv.note)")
        logMeasurement("npm 断网返回值",
                       "versions=\(registry.latestVersions.count) failed=\(registry.failedRequests) "
                       + "checked=\(registry.packagesChecked) note=\(registry.note)")

        XCTAssertLessThan(uptimeNow() - started, DependencyNetworkLookup.requestTimeout,
                          "连接被拒的两条查询都不该占满预算")
        XCTAssertTrue(osv.advisories.isEmpty)
        XCTAssertFalse(osv.note.isEmpty, "OSV 失败要写进 note")
        XCTAssertGreaterThan(osv.failedRequests, 0)
        XCTAssertTrue(registry.latestVersions.isEmpty)
        XCTAssertGreaterThan(registry.failedRequests, 0)
        XCTAssertFalse(registry.note.isEmpty, "npm 失败要写进 note")
    }
    /// 缺陷 D1 回归门：N 个包全部查询失败时，`failedRequests` 必须按包计，
    /// 不能只报批量那一次（改前 12 个包全挂只报 `failed=1`，等于把失败面往小里说）。
    func testEveryFailedPackageIsCountedNotJustTheBatchRequest() async throws {
        let queries = (0..<12).map {
            OsvPackageQuery(ecosystem: "npm", package: "tcoder-pkg\($0)", version: "1.\($0).0")
        }
        let osv = try await withHostOverride(NetProbe.refusedHost) {
            await DependencyNetworkLookup.osvBatch(queries)
        }
        logMeasurement("缺陷 D1 现场", "checked=\(osv.packagesChecked) failed=\(osv.failedRequests) note=\(osv.note)")
        XCTAssertEqual(osv.packagesChecked, 12)
        XCTAssertGreaterThanOrEqual(osv.failedRequests, queries.count,
                                    "12 个包全失败就必须报 ≥12 次失败，实得 \(osv.failedRequests)")
        XCTAssertTrue(osv.advisories.isEmpty)
        XCTAssertFalse(osv.note.isEmpty, "整批失败必须落到 note")
    }

    /// 缺陷 D2 回归门：详情展开不全时，账本要把"已取回 / 拉取失败 / 预算内未展开 / 上限截断"
    /// 分开记，并且明说已取回的部分仍在结果里 —— 丢数据可以，静默丢数据不行。
    func testDetailTallyKeepsWhatItAlreadyFetched() throws {
        let outcomes: [OsvDetailOutcome] =
            Array(repeating: OsvDetailOutcome.fetched, count: 30)
            + Array(repeating: OsvDetailOutcome.failed, count: 3)
            + Array(repeating: OsvDetailOutcome.notAttempted, count: 7)
        let tally = DependencyNetworkLookup.tallyOsvDetails(totalIDs: 60, outcomes: outcomes)
        XCTAssertEqual(tally.fetched, 30, "已取回的 30 条必须留住并计入")
        XCTAssertEqual(tally.failed, 3)
        XCTAssertEqual(tally.notAttemptedByBudget, 7, "预算内没来得及展开的不算拉取失败")
        XCTAssertEqual(tally.skippedByCap, 20, "共 60 条、只展开 40 条 → 上限截断 20 条")
        let note = try XCTUnwrap(DependencyNetworkLookup.osvDetailNote(totalIDs: 60, tally: tally, cap: 40))
        XCTAssertTrue(note.contains("共 60 条"), note)
        XCTAssertTrue(note.contains("20 条未展开"), note)
        XCTAssertTrue(note.contains("7 条因时间预算未展开"), note)
        XCTAssertTrue(note.contains("3 条详情拉取失败"), note)
        XCTAssertTrue(note.contains("已取回 30 条并计入结果"),
                      "必须说出还剩多少可用，否则读者只会看到一个笼统的截断提示：\(note)")
        let allGood = DependencyNetworkLookup.tallyOsvDetails(
            totalIDs: 5, outcomes: Array(repeating: OsvDetailOutcome.fetched, count: 5))
        XCTAssertFalse(allGood.needsDisclosure, "全部展开成功就别制造噪音")
        XCTAssertNil(DependencyNetworkLookup.osvDetailNote(totalIDs: 5, tally: allGood, cap: 40))
    }

}

// MARK: - 2) 硬超时实测 / 3) 真实在线查询 / 4) 版本来源归因
//
// 这三组已按类各拆一个文件（WS-X3 TestSplit，用例本体一字未改）：
// `DependencyNetworkTimeoutTests.swift`、`DependencyNetworkLiveTests.swift`、
// `DependencyNetworkAttributionTests.swift`。夹具（NetProbe / DepFixture / XCTestCase 扩展）
// 仍留在本文件，同模块 internal 可见。
