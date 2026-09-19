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
// 在线实测对网络抖动敏感（同一请求观测到 0.9s 与 3.5s 两种结果），需要真实数据的用例最多重试 2 次，
// 每次耗时都会记进附件 —— 重试是给抖动留余地，不是放宽预算。

// MARK: - 探针与工具

private enum NetProbe {
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
private func withHostOverride<T>(_ host: String, _ body: () async throws -> T) async rethrows -> T {
    let key = DependencyNetworkLookup.hostOverrideEnvironmentKey
    let previous = ProcessInfo.processInfo.environment[key]
    host.withCString { _ = setenv(key, $0, 1) }
    defer {
        if let previous { previous.withCString { _ = setenv(key, $0, 1) } } else { unsetenv(key) }
    }
    return try await body()
}

private func uptimeNow() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

private func secondsText(_ value: TimeInterval) -> String { String(format: "%.3fs", value) }

// MARK: - 夹具

/// 在线查询用的依赖集合。
///
/// `snapshotBlind`（moment / semver / jquery / react 内置快照都没收录）是用来证明
/// 「拿到的版本确实来自 registry.npmjs.org，而不是内置字典」的抓手。
private enum DepFixture {
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

private extension XCTestCase {
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

// MARK: - 2) 硬超时实测（黑洞地址；本机环境不「挂住」就整组跳过）


final class DependencyNetworkTimeoutTests: XCTestCase {

    override func setUp() async throws {
        let stalls = await NetProbe.doesBlackHoleStall()
        try XCTSkipUnless(stalls,
                          "本机到 \(NetProbe.blackHoleHost) 的裸请求会立刻报错而不是挂住，"
                          + "这种环境下量出的「5 秒」证明不了预算生效，整组跳过")
    }

    /// 主张②：请求不能在预算内完成时，必须停在预算附近被放弃，而不是挂到裸请求的 81.8 秒。
    func testHardTimeoutAbortsAtBudgetInsteadOfHanging() async throws {
        let timeout = DependencyNetworkLookup.requestTimeout
        XCTAssertEqual(timeout, 5, "被测预算是 5 秒；本测试不改动它")
        let queries = [
            OsvPackageQuery(ecosystem: "npm", package: "jquery", version: "3.4.1"),
            OsvPackageQuery(ecosystem: "Maven", package: "com.alibaba:fastjson", version: "1.2.68"),
        ]

        let osvStarted = uptimeNow()
        let osv = await withHostOverride(NetProbe.blackHoleHost) {
            await DependencyNetworkLookup.osvBatch(queries)
        }
        let osvSeconds = uptimeNow() - osvStarted

        let npmStarted = uptimeNow()
        let registry = await withHostOverride(NetProbe.blackHoleHost) {
            await DependencyNetworkLookup.npmLatestVersions(["jquery", "moment", "semver", "react"])
        }
        let npmSeconds = uptimeNow() - npmStarted

        let root = try makeDependencyProject("timeout", files: DepFixture.full)
        let (report, analyzeSeconds) = try await withHostOverride(NetProbe.blackHoleHost) {
            try await analyzeOnline(root)
        }

        logMeasurement("主张②对照基线",
                       "同地址无保护裸请求 ≥20s 未结束（curl 实测 81.8s 才失败）；"
                       + "OSV=\(secondsText(osvSeconds)) npm=\(secondsText(npmSeconds)) "
                       + "整链路=\(secondsText(analyzeSeconds))")
        logMeasurement("超时 note", "OSV[\(osv.note)] npm[\(registry.note)] 报告[\(report.networkLookupNote)]")

        // 单点：OSV 预算 5s、npm 预算 5(+1)s，各留 2 秒调度余量；关键是停在个位数秒。
        XCTAssertLessThanOrEqual(osvSeconds, timeout + 2, "OSV 必须停在预算附近，实测 \(osvSeconds)s")
        XCTAssertGreaterThanOrEqual(osvSeconds, 0.2, "这么快返回说明根本没发请求，测量无效")
        XCTAssertLessThanOrEqual(npmSeconds, timeout + 3, "npm 必须停在预算附近，实测 \(npmSeconds)s")
        XCTAssertGreaterThanOrEqual(npmSeconds, 0.2, "这么快返回说明根本没发请求，测量无效")

        XCTAssertTrue(osv.advisories.isEmpty)
        XCTAssertFalse(osv.note.isEmpty, "超时/失败必须写进 note")
        XCTAssertGreaterThanOrEqual(osv.failedRequests, queries.count)
        XCTAssertTrue(registry.latestVersions.isEmpty)
        XCTAssertFalse(registry.note.isEmpty)
        XCTAssertEqual(registry.failedRequests, 4)

        // 整条链路是 npm -> OSV 串行，最坏 ≈ 5+6 秒，而不是裸请求的 81.8 秒。
        XCTAssertLessThanOrEqual(analyzeSeconds, 2 * timeout + 4,
                                "整链路实测 \(analyzeSeconds)s，超出两个查询预算之和")
        // 主张③同时成立：超时后仍然返回结果，并明确标注未完成。
        XCTAssertFalse(report.ecosystems.isEmpty, "超时后仍然返回完整清单")
        XCTAssertGreaterThanOrEqual(report.totalDependencies, 11)
        XCTAssertFalse(report.offlineVulnerabilities.isEmpty, "内置结论仍然给出")
        XCTAssertTrue(report.networkLookupPerformed)
        XCTAssertFalse(report.networkLookupNote.isEmpty)
        XCTAssertTrue(report.advisories.isEmpty)
        XCTAssertTrue(report.networkLookupNote.contains("超时") || report.networkLookupNote.contains("失败"),
                      "报告必须点名在线没查成")
    }
}

// MARK: - 3) 真实在线查询（需公网；不可达整组跳过）

final class DependencyNetworkLiveTests: XCTestCase {

    override func setUp() async throws {
        let seconds = await NetProbe.osvReachable()
        try XCTSkipIf(seconds == nil, "api.osv.dev 在 4 秒内握不上手：跳过在线实测（本机无网络或被拦截）")
        if let seconds { logMeasurement("预检 api.osv.dev 往返", secondsText(seconds)) }
    }

    /// 主张①（registry）：内置快照**没收录**的包能拿到真实最新版本，就证明数据来自 registry。
    ///
    /// 最多 3 次尝试，且**必须三个盲区包全部**拿到在线源归因才停：5 个包共用一个并发窗口和
    /// 同一条 5 秒总预算（`performNpmLookup` + `makeRequest`），冷启动 TLS 握手会让其中
    /// **个别**包先被掐掉（实测首个请求 5.006s 被预算吃掉、热了之后同一条只要 0.23s）。
    /// 所以「有一个包拿到了」并不等于「网络给力」，早停条件写成「全都拿到」。
    ///
    /// 收尾把两种结局分开，二者绝不混为一谈：
    ///   · registry 自己都没答上（`npmShortfallDisclosed`）→ XCTSkip，并留下实测数字；
    ///   · registry 自述答上了、记录里却没有在线源归因 → 归因链路断了，必须失败。
    /// 不放宽任何断言，也不放宽超时预算。
    func testOnlineRegistryLookupReturnsRealLatestVersionsForPackagesMissingFromSnapshot() async throws {
        let root = try makeDependencyProject("live-registry",
                                             files: ["package.json": DepFixture.registryPackageJSON])
        let blind = ["moment", "semver", "jquery"]
        for name in blind {
            XCTAssertNil(DependencySnapshot.latestKnownVersion(ecosystem: .npm, name: name),
                         "前置条件：\(name) 不该在内置快照里，否则这条证明不成立")
        }

        var report = DependencyReport()
        var seconds: TimeInterval = 0
        var attempts = 0
        while attempts < 3 {
            attempts += 1
            let attempt = try await analyzeOnline(root)
            (report, seconds) = attempt
            let attributed = blind.filter { name in
                record(report, named: name)?.versionCheckSource == .onlineRegistry
            }.count
            if attributed == blind.count { break }
        }

        let online = records(of: report).filter { $0.versionCheckSource == .onlineRegistry }
        let detail = online.map { "\($0.name)->\($0.latestKnownVersion ?? "nil")" }.sorted()
        logMeasurement("主张①registry（尝试\(attempts)次）",
                       "\(secondsText(seconds)) 在线版本 \(detail.joined(separator: " "))")

        var starved: [String] = []
        for name in blind {
            guard let found = record(report, named: name) else {
                XCTFail("\(name) 应出现在依赖清单里"); continue
            }
            if found.versionCheckSource == .onlineRegistry {
                let latest = try XCTUnwrap(found.latestKnownVersion,
                                           "\(name) 已归因成在线源，就必须带在线最新版本")
                XCTAssertFalse(latest.isEmpty)
                XCTAssertTrue(latest.split(separator: ".").first?.allSatisfy { $0.isNumber } ?? false,
                              "\(name) 的在线最新版本要像版本号，实测 \(latest)")
                XCTAssertTrue(found.isProbablyOutdated,
                              "\(name) 声明 \(found.version) 应被在线最新版 \(latest) 判为过旧")
                continue
            }
            // 以下两条是「归因是否丢」的判据，与网络状况无关，一条都不许让步。
            if let latest = found.latestKnownVersion {
                XCTFail("\(name) 有最新版本 \(latest) 却被报成 \(found.versionCheckSource.rawValue)："
                    + "数据取回来了却没写来源，属归因缺陷，不是网络抖动")
                continue
            }
            guard DependencyNetworkLookup.npmShortfallDisclosed(in: report.networkLookupNote) else {
                XCTFail("\(name) 既无版本又无在线源归因，而 registry 自述没有任何包查询失败："
                    + "说明结果被取回却没写回记录 —— 归因链路断了。最后一次 note=\(report.networkLookupNote)")
                continue
            }
            starved.append(name)
        }
        XCTAssertTrue(report.networkLookupPerformed)

        // 预检可达 ≠ 现场每次都在预算内：被 registry 自述为「有包没答上」的那些，
        // 是网络状况而非产品缺陷 —— 跳过并留下实测痕迹，而不是留成一条会自行翻红的断言。
        if !starved.isEmpty {
            throw XCTSkip("预检可达，但 \(starved.joined(separator: "、")) 在 \(attempts) 次尝试里都没从 registry "
                + "取回版本（registry 自述有包未答上）：\(report.networkLookupNote)")
        }
        if report.networkLookupNote.contains("超时") {
            throw XCTSkip("预检可达但现场有请求超出 \(Int(DependencyNetworkLookup.requestTimeout)) 秒预算："
                + "\(report.networkLookupNote)")
        }
    }

    /// 主张①（CVE）：真打 OSV 要回真实公告编号（GHSA / CVE 别名）。
    ///
    /// 与 registry 那条同款的处理：两次尝试都没拿到公告时，先看 OSV 自己有没有把缺口讲出来 ——
    /// 讲了就是网络状况（跳过并留数），没讲就是"自称查成功却一条都没给"（必须失败）。
    /// 公告一旦拿到，下面每条实质断言原样保留，不做任何放宽。
    func testOnlineVulnerabilityLookupReturnsRealAdvisoryIdsAndCVEAliases() async throws {
        let root = try makeDependencyProject("live-advisory",
                                             files: ["package.json": DepFixture.advisoryPackageJSON])
        var report = DependencyReport()
        var seconds: TimeInterval = 0
        var attempts = 0
        while attempts < 2 {
            attempts += 1
            let attempt = try await analyzeOnline(root)
            (report, seconds) = attempt
            if !report.advisories.isEmpty { break }
        }

        let osv = report.advisories.filter { $0.source.localizedCaseInsensitiveContains("OSV") }
        let listing = osv.map { advisory in
            advisory.id + "(aliases=" + advisory.aliases.joined(separator: ",")
                + ",sev=" + advisory.severity.rawValue + ",pkgs=" + advisory.affectedPackages.joined(separator: "|") + ")"
        }
        logMeasurement("主张①OSV（尝试\(attempts)次）",
                       "\(secondsText(seconds)) 在线公告 \(osv.count) 条：\(listing.joined(separator: " "))")

        if osv.isEmpty {
            // 空公告 + OSV 自述没查成 = 网络状况；空公告 + OSV 自述查成功了 = 结果被丢，是缺陷。
            XCTAssertTrue(DependencyNetworkLookup.osvShortfallDisclosed(in: report.networkLookupNote),
                          "OSV 自述在线查询已完成，却一条公告都没给出（\(attempts) 次尝试）："
                          + "结果被取回却没落进报告，属归因/聚合缺陷。note=\(report.networkLookupNote)")
            throw XCTSkip("预检可达，但 OSV 在 \(attempts) 次尝试里都有请求没答上："
                + "\(report.networkLookupNote)")
        }
        for advisory in osv {
            XCTAssertTrue(["GHSA-", "PYSEC-", "CVE-", "RSEC-", "GO-", "META-"].contains { advisory.id.hasPrefix($0) },
                          "公告编号要像真实 OSV id：\(advisory.id)")
            XCTAssertFalse(advisory.affectedPackages.isEmpty, "\(advisory.id) 必须点名受影响坐标")
            XCTAssertFalse(advisory.summary.isEmpty, "\(advisory.id) 摘要不得为空")
            XCTAssertTrue(advisory.affectedPackages.allSatisfy { $0.contains("@") },
                          "受影响坐标要带版本：\(advisory.affectedPackages)")
        }
        XCTAssertTrue(osv.contains { $0.aliases.contains { $0.hasPrefix("CVE-") } },
                      "至少一条在线公告要带真实 CVE 编号")
        XCTAssertTrue(osv.contains { $0.severity > RiskLevel.none }, "至少一条要有严重度")
        XCTAssertEqual(report.networkLookupPerformed, true)
    }

    /// 真实规模档案：12 条依赖在 OSV 一次回 104 条公告 id（curl 实测），
    /// 而单次只拉 40 条详情、整体预算 5 秒。这里只要求「有界 + 诚实 + 不杜撰」，
    /// 不要求在线公告非空 —— 结果是否被预算整体放弃，正是这条测试要记录下来的事实。
    func testRealSizedProjectOnlineProfileStaysBoundedAndHonest() async throws {
        let root = try makeDependencyProject("live-profile", files: DepFixture.full)
        let (report, seconds) = try await analyzeOnline(root)

        let covered = Set(["CVE-2021-23337", "CVE-2021-44228", "CVE-2022-25845", "CVE-2020-28168",
                           "CVE-2015-6420", "CVE-2018-1000531", "CVE-2022-42003"])
        let duplicated = report.advisories.filter { advisory in advisory.aliases.contains { covered.contains($0) } }
        logMeasurement("真实规模在线档案",
                       "\(secondsText(seconds)) 依赖 \(report.totalDependencies) 条 / 在线公告 "
                       + "\(report.advisories.count) 条 / 内置 \(report.offlineVulnerabilities.count) 条 "
                       + "/ vulnerableCount=\(report.vulnerableCount) 风险=\(report.riskLevel.rawValue) "
                       + "note=\(report.networkLookupNote)")

        XCTAssertGreaterThanOrEqual(report.totalDependencies, 11)
        // 预算：npm(≤6) + OSV(≤5) 串行，再加清单扫描，必须停在个位数~十位数秒。
        XCTAssertLessThanOrEqual(seconds, 2 * DependencyNetworkLookup.requestTimeout + 6,
                                 "真实规模在线阶段实测 \(seconds)s，已失去「硬超时」意义")
        XCTAssertTrue(report.networkLookupPerformed)
        XCTAssertFalse(report.offlineVulnerabilities.isEmpty, "内置结论永远在场")
        // 去重：在线公告不得重复计入内置规则已覆盖的同一 CVE。
        XCTAssertTrue(duplicated.isEmpty, "在线结果与内置规则重复：\(duplicated.map(\.id))")
        // note 与 advisories 必须自洽：一条在线公告都没拿到时，必须注明原因。
        if report.advisories.isEmpty {
            XCTAssertFalse(report.networkLookupNote.isEmpty, "空在线结果必须注明原因：\(report.networkLookupNote)")
        }
    }
}

// MARK: - 4) 版本来源归因（不打公网）

/// 钉住「版本来源归因」本身，一条公网请求都不发。
///
/// 为什么要单独有这一组：在线实测那条只能证明「这一次网络给力时归因是对的」，
/// registry 一抖它就跳，守不住归因链路。这两条把快照侧与在线侧的**成对写回**钉死 ——
/// 谁给的数据就归因给谁；registry 没答的包不许被顺手改成在线源，
/// 答了的包也不许只留版本不改来源（那正是"其实没查到"被读成"查到并确认最新"的方向）。
final class DependencyNetworkAttributionTests: XCTestCase {

    private func offlineReport(_ tag: String, files: [String: String]) async throws -> DependencyReport {
        let root = try makeDependencyProject(tag, files: files)
        // allowNetwork=false：这条路径保证一个请求都不发（已由主张④钉住），结果只可能来自内置快照。
        return try await ManifestDependencyAnalyzer().analyze(projectRoot: root, allowNetwork: false)
    }

    /// 快照未收录、但在线能返结果的依赖 -> 来源必须是 `.onlineRegistry` 且版本非空。
    func testRegistryAnswerForSnapshotBlindPackageIsAttributedToOnlineSource() async throws {
        let report = try await offlineReport("attribution-blind",
                                            files: ["package.json": DepFixture.registryPackageJSON])
        let before = try XCTUnwrap(record(report, named: "moment"), "moment 应出现在依赖清单里")
        XCTAssertEqual(before.versionCheckSource, VersionCheckSource.none,
                       "前置条件：内置快照没收录 moment，离线阶段它不能带任何来源")
        XCTAssertNil(before.latestKnownVersion, "前置条件：离线阶段 moment 不能有版本")

        var patched = report
        ManifestDependencyAnalyzer.applyRegistryVersions(
            RegistryLookupResult(latestVersions: ["moment": "2.31.0"],
                                 packagesChecked: 1, failedRequests: 0, note: ""),
            to: &patched.ecosystems)

        let after = try XCTUnwrap(record(patched, named: "moment"))
        XCTAssertEqual(after.versionCheckSource, .onlineRegistry,
                       "registry 已经给出 moment 的版本，来源却还是 \(after.versionCheckSource.rawValue)："
                       + "在线结果被丢了，用户会把「没核对」读成「已核对」")
        XCTAssertEqual(after.latestKnownVersion, "2.31.0", "在线版本必须原样落到记录里")
        XCTAssertFalse(after.latestKnownVersion?.isEmpty ?? true)
        XCTAssertTrue(after.isProbablyOutdated, "声明 \(after.version) 对在线最新 \(after.latestKnownVersion ?? "") 应判为过旧")

        // 在线用例的跳过闸门只能用得准：成功说明不能被当成「有包没答上」。
        XCTAssertFalse(DependencyNetworkLookup.npmShortfallDisclosed(in: "在线查询已完成（OSV + npm registry）"),
                       "全量成功的说明被误判成有缺口，会把真缺陷跳过去")
        XCTAssertTrue(DependencyNetworkLookup.npmShortfallDisclosed(in: "npm registry：5 个包中 1 个查询失败"))
        XCTAssertTrue(DependencyNetworkLookup.npmShortfallDisclosed(in: "OSV 批量接口不可用，已改用逐包查询"
            + "；达到时间预算，剩余 1 个包未查询"))
        XCTAssertFalse(DependencyNetworkLookup.osvShortfallDisclosed(in: "在线查询已完成（OSV + npm registry）"),
                       "OSV 的全量成功说明同样不能被误判成缺口")
        XCTAssertTrue(DependencyNetworkLookup.osvShortfallDisclosed(in: "OSV：12 个包中 13 个查询失败"))
    }

    /// 内置快照命中的依赖 -> 来源必须是快照，不能是"在线"。
    func testSnapshotCoveredPackageIsAttributedToBundledSnapshotNotOnline() async throws {
        let report = try await offlineReport("attribution-snapshot",
                                            files: ["package.json": DepFixture.registryPackageJSON])
        let snapshotName = "lodash"
        let snapshotVersion = try XCTUnwrap(DependencySnapshot.latestKnownVersion(ecosystem: .npm, name: snapshotName),
                                            "前置条件：\(snapshotName) 必须在内置快照里")
        let lodash = try XCTUnwrap(record(report, named: snapshotName))
        XCTAssertEqual(lodash.versionCheckSource, .bundledSnapshot)
        XCTAssertNotEqual(lodash.versionCheckSource, .onlineRegistry,
                          "没联网却把来源报成在线源，等于凭空声称在线核对过")
        XCTAssertEqual(lodash.latestKnownVersion, snapshotVersion)

        // registry 这次只答了 moment：lodash 的结论必须原地不动，既不升级成在线源、也不被抹掉。
        var patched = report
        ManifestDependencyAnalyzer.applyRegistryVersions(
            RegistryLookupResult(latestVersions: ["moment": "2.31.0"],
                                 packagesChecked: 2, failedRequests: 1, note: "npm registry：2 个包中 1 个查询失败"),
            to: &patched.ecosystems)
        let after = try XCTUnwrap(record(patched, named: snapshotName))
        XCTAssertEqual(after.versionCheckSource, .bundledSnapshot,
                       "registry 没答 \(snapshotName)，就不能把它顺手改称在线源；实得 \(after.versionCheckSource.rawValue)")
        XCTAssertEqual(after.latestKnownVersion, snapshotVersion, "未答的包已有结论不许被清空")

        // 反向上限：registry 真答了 lodash 时，来源必须随之升级（否则归因写死了快照）。
        ManifestDependencyAnalyzer.applyRegistryVersions(
            RegistryLookupResult(latestVersions: [snapshotName: "9.9.9"],
                                 packagesChecked: 1, failedRequests: 0, note: ""),
            to: &patched.ecosystems)
        let promoted = try XCTUnwrap(record(patched, named: snapshotName))
        XCTAssertEqual(promoted.versionCheckSource, .onlineRegistry)
        XCTAssertEqual(promoted.latestKnownVersion, "9.9.9")
    }
}
