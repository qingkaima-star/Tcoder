/// OWNER: WS-X3 TestSplit —— 自 DependencyNetworkLookupTests.swift 整块拆出：联网实查三例（在线版本/漏洞公告/真实规模项目）。用例本体一字未改，只是搬了家。
import XCTest
@testable import TcoderMonitor

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
    ///   · registry 自己都没答上（账本里 `.failed` 条数 > 0）→ XCTSkip，并留下实测数字；
    ///   · registry 自述答上了、记录里却没有在线源归因 → 归因链路断了，必须失败。
    /// 不放宽任何断言，也不放宽超时预算。
    ///
    /// 分界读的是**逐条状态账本**（`DependencyEvidence.ledger`），不再是那句中文说明 ——
    /// 这里曾经是 `DependencyNetworkLookup.npmShortfallDisclosed(in: note)`，
    /// 拿 `note.contains("npm registry 查询超过")` 一类清单判"该跳还是该红"（RD-13 的形状，已删）。
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
            guard registryFailedCount(report) > 0 else {
                XCTFail("\(name) 既无版本又无在线源归因，而账本自述没有任何一条查询失败："
                    + "说明结果被取回却没写回记录 —— 归因链路断了。"
                    + "最后一次 note=\(report.networkLookupNote)／失败 \(registryFailedCount(report)) 条")
                continue
            }
            starved.append(name)
        }
        XCTAssertTrue(report.networkLookupPerformed)

        // 预检可达 ≠ 现场每次都在预算内：账本里落了失败条数的那些，
        // 是网络状况而非产品缺陷 —— 跳过并留下实测痕迹，而不是留成一条会自行翻红的断言。
        if !starved.isEmpty {
            throw XCTSkip("预检可达，但 \(starved.joined(separator: "、")) 在 \(attempts) 次尝试里都没从 registry "
                + "取回版本（账本：版本核对失败 \(registryFailedCount(report)) 条／共 \(report.totalDependencies) 条）："
                + "\(report.networkLookupNote)")
        }
        // 这一分支以前靠"那句中文里有没有『超时』两个字"，现在读账本里那两个数。
        if let lookup = report.versionLookup, lookup.attempted > lookup.checked {
            throw XCTSkip("预检可达但有 \(lookup.attempted - lookup.checked) 次请求没拿到可用结果"
                + "（单次预算 \(Int(DependencyNetworkLookup.requestTimeout)) 秒）：\(report.networkLookupNote)")
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
            // 空公告 + 账本说明确实有失败 = 网络状况；空公告 + 账本一条失败都没记 = 结果被丢，是缺陷。
            // （旧写法读 `osvShortfallDisclosed(in: note)` 那句中文，已随 RD-13 的收尾删掉。）
            let failures = osvFailedCount(report)
            XCTAssertTrue(failures > 0,
                          "OSV 自述在线查询已完成，却一条公告都没给出（\(attempts) 次尝试）："
                          + "结果被取回却没落进报告，属归因/聚合缺陷。"
                          + "note=\(report.networkLookupNote)／漏洞核对失败 \(failures) 条")
            throw XCTSkip("预检可达，但 OSV 在 \(attempts) 次尝试里都有请求没答上："
                + "漏洞核对失败 \(failures) 条／共 \(report.totalDependencies) 条 · \(report.networkLookupNote)")
        }
        for advisory in osv {
            XCTAssertTrue(["GHSA-", "PYSEC-", "CVE-", "RSEC-", "GO-", "META-"].contains { advisory.id.hasPrefix($0) },
                          "公告编号要像真实 OSV id：\(advisory.id)")
            XCTAssertFalse(advisory.affectedPackages.isEmpty, "\(advisory.id) 必须点名受影响坐标")
            XCTAssertFalse(advisory.summary.isEmpty, "\(advisory.id) 摘要不得为空")
            // 坐标自 R3 起是**规范形状** `生态|包名|版本`（存储层用它回填，展示层才还原成
            // `lodash@4.17.15`）。这条用例管的是"受影响坐标必须点到具体版本"，
            // 与分隔符无关 ⇒ 判据改成"三段且第三段非空"。
            XCTAssertTrue(advisory.affectedPackages.allSatisfy { coordinate in
                let pieces = coordinate.split(separator: "|")
                return pieces.count == 3 && !pieces[2].isEmpty && pieces[1].contains(where: { $0.isLetter })
            }, "受影响坐标必须是 生态|包名|版本 且带版本：\(advisory.affectedPackages)")
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

    // MARK: - 「这次红是网络状况还是产品缺陷」的结构化判据（取代已删的中文措辞清单）

    /// registry 那一路失败的条数：逐条状态里 `.failed` 的条目数。
    /// `> 0` = 数据源确实有包没答上（网络状况）；`== 0` 而记录里仍没有在线归因 = 产品缺陷。
    private func registryFailedCount(_ report: DependencyReport) -> Int {
        DependencyEvidence.ledger(for: report).versionStateCounts[.failed] ?? 0
    }

    /// OSV 那一路同一条判据。**包含**"发出去了、公告 id 也看见了、但详情没能展开成"的那批
    /// （它们由 `OsvAnswerAccounting.unresolvedOsvCoordinates` 结构化地落成 `.failed`）。
    private func osvFailedCount(_ report: DependencyReport) -> Int {
        DependencyEvidence.ledger(for: report).vulnerabilityStateCounts[.failed] ?? 0
    }
}
