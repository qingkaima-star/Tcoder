// OWNER: WS-R36 依赖证据链 · 把 C/D/E 三组补到「三出口同闸」这一级（台账 §67 的第三问）
//
// 台账 §67 给这三组的等级是「钉子存在且被执行」，缺的正是 §8 第 6 条**第三问**：
// 同一件事在 GUI 契约字段 / CLI 那句文本 / 落盘 JSON 是不是同一个装配口出来的。
// 逐例打开身体后读到的是（下面是本文件立案时的事实，不是推测）：
//   · 闸门本体 `DependencyEvidence.mayClaimNoKnownVulnerabilities` 与总览文案
//     由 `DependencyAttemptedVsCheckedTests` / `DependencySafetyVerdictTests` 钉着 —— 两格都在账本层；
//   · **CLI 那一出口此前全仓零覆盖**：`CLIScoreText.networkCaveat` 的三态分支
//     「（全量覆盖且零命中）」/「（全量覆盖）」/「 —— 这是「没查全」，不是「没有漏洞」」
//     与 D 组唯一的降级披露「其中 N 条按声明范围的下界查询」没有任何用例读过。
//     把那句三元反过来写也不会红 —— 与 RD-31×RD-60 栽的「一个态只在一个出口说话」同一族。
//   · 分 scope 那一族只断到 `declared` 一列（`testScopeBreakdownKeepsScopesApart`），
//     `vulnerabilityChecked` / `versionChecked` / `vulnerable` 三列没有任何用例分开钉过，
//     空桶（「这一档是 0」vs「这一档没统计」）与旧报告缺键时的兜底账本同样零覆盖。
//
// 本文件**只补断言，不放宽任何既有期望、不改判据**。期望值一律来自本文件手写的清单
// 与手写的假源行为表（哪条答、哪条失败、哪条没答），没有一条是从实现返回值回填的。
// 真值表在每条用例的注释里逐条写出，便于交回汇报里贴原文。
import XCTest
@testable import TcoderMonitor

final class DependencyExitParityTests: XCTestCase {

    // MARK: - 夹具：三份清单 + 一张手写假源行为表

    /// 三条精确版本声明，名字一律**不在内置快照里**（正向证据只可能来自我给的假源行为）。
    private static let threeDependencyManifest =
        #"{"name":"exit-lab","dependencies":{"exit-a":"1.0.0","exit-b":"2.0.0","exit-c":"3.0.0"}}"#

    private static func coordinate(_ name: String, _ version: String) -> String {
        DependencyVersionIdentity.coordinate(ecosystem: .npm, name: name, queryVersion: version)
    }

    // MARK: - ① C 组：all-clear 这句话在 CLI 出口必须与账本同闸

    /// 手写推导：3 条声明、`exit-c` 那一条的 OSV 查询**点名失败** ⇒
    /// 已核对 2 / 共 3、失败 1 ⇒ 闸门必须关。
    func testCLIRefusesTheZeroHitClaimWhenOneRowIsUncovered() async throws {
        let stub = StubOnlineSource(failedCoordinates: [Self.coordinate("exit-c", "3.0.0")],
                                    latestVersions: ["exit-a": "1.0.0", "exit-b": "2.0.0", "exit-c": "3.0.0"])
        let report = try await analyze(["package.json": Self.threeDependencyManifest], tag: "claim-partial",
                                       online: stub)
        let ledger = DependencyEvidence.ledger(for: report)
        XCTAssertEqual(ledger.totalCount, 3)
        XCTAssertEqual(ledger.vulnerabilityCheckedCount, 2, "三条里只核对成两条")
        XCTAssertFalse(DependencyEvidence.mayClaimNoKnownVulnerabilities(ledger))

        // 第二问的反例态：还有 2 条答上了、1 条失败 —— 这一档在 CLI 必须落在「没查全」那侧。
        let text = cliText(of: report)
        // RD-74：这一句里**同一对数字只许出现一次**（改前它会打两遍、还是两种写法：
        // 「已核对 2/3」＋装配口那句「已核对 2 / 3 个依赖，另外 1 个没查…」）。
        let statusLine = Self.vulnerabilityStatusLine(in: text)
        XCTAssertTrue(statusLine.contains("已核对 2 / 3"), statusLine)
        XCTAssertEqual(Self.occurrences(of: "已核对", in: statusLine), 1,
                       "同一对条数在一行里印了两遍：" + statusLine)
        XCTAssertTrue(text.contains("这是「没查全」，不是「没有漏洞」"), dependencyLines(text))
        XCTAssertFalse(text.contains("全量覆盖且零命中"),
                       "部分覆盖却打了零命中那句：" + dependencyLines(text))

        // 第三问：落盘 JSON 那一格必须与 CLI 那句是同一份数（不许各自再数一遍）。
        let stored = try roundTrip(report)
        XCTAssertEqual(stored.vulnerabilityLookup?.checked, 2)
        XCTAssertEqual(stored.vulnerabilityLookup?.failed, 1)
        XCTAssertEqual(stored.vulnerabilityLookup?.totalRecords, 3)
    }

    /// 同一份清单、三条全答上且零命中 ⇒ 这一档才许打「全量覆盖且零命中」。
    func testCLIGrantsTheZeroHitClaimOnlyOnFullCoverage() async throws {
        let stub = StubOnlineSource(latestVersions: ["exit-a": "1.0.0", "exit-b": "2.0.0", "exit-c": "3.0.0"])
        let report = try await analyze(["package.json": Self.threeDependencyManifest], tag: "claim-clean",
                                       online: stub)
        let ledger = DependencyEvidence.ledger(for: report)
        XCTAssertEqual(ledger.vulnerabilityCheckedCount, 3, "手写推导：三条都在假源的回执里")
        XCTAssertTrue(DependencyEvidence.mayClaimNoKnownVulnerabilities(ledger))
        let text = cliText(of: report)
        XCTAssertTrue(text.contains("已核对 3/3"), dependencyLines(text))
        XCTAssertTrue(text.contains("全量覆盖且零命中"), dependencyLines(text))
    }

    /// 「没去查」（离线，一条都没发起）与「查了没查到」是两件事：这一档 CLI 必须说未查。
    func testOfflineRunSpeaksTheUncheckedTailAtTheCLIExit() async throws {
        let report = try await analyze(["package.json": Self.threeDependencyManifest], tag: "claim-offline",
                                       online: nil, allowNetwork: false)
        let ledger = DependencyEvidence.ledger(for: report)
        XCTAssertEqual(ledger.vulnerabilityCheckedCount, 0)
        let text = cliText(of: report)
        let offlineLine = Self.vulnerabilityStatusLine(in: text)
        XCTAssertTrue(offlineLine.contains("共 3 个依赖，一条都没核对"), offlineLine)
        XCTAssertEqual(Self.occurrences(of: "已核对", in: offlineLine), 0,
                       "一条都没核对，就不该在这一行再报一遍「已核对 N/M」：" + offlineLine)
        XCTAssertTrue(text.contains("3 个未查"), dependencyLines(text))
        XCTAssertTrue(text.contains("这是「没查全」，不是「没有漏洞」"), dependencyLines(text))
        XCTAssertFalse(text.contains("全量覆盖"), dependencyLines(text))
    }

    // MARK: - ② D 组：没量到安装版本 ⇒ 按下界查询这件事必须自己出声

    /// 正例（量到了）：锁文件把 `^1.2.3` 钉在 1.2.9 ⇒ 降级句必须**不出现**；
    /// 反例（没量到）：同一份清单去掉锁文件 ⇒ 只能按下界查，两出口都得说出来。
    func testLowerBoundFallbackIsDisclosedAtBothExits() async throws {
        let declared = #"{"name":"lock-lab","dependencies":{"left-pad":"^1.2.3"}}"#
        let lock = #"""
        {"lockfileVersion":3,"packages":{"":{"dependencies":{"left-pad":"^1.2.3"}},
         "node_modules/left-pad":{"version":"1.2.9"}}}
        """#

        let locked = try await analyze(["package.json": declared, "package-lock.json": lock],
                                       tag: "fallback-locked", online: nil, allowNetwork: false)
        let lockedRow = try XCTUnwrap(locked.ecosystems.flatMap(\.dependencies).first)
        XCTAssertEqual(lockedRow.resolvedVersion, "1.2.9", "前提：安装版本量到了")
        XCTAssertEqual(DependencyVersionIdentity.of(lockedRow).query?.basis, .lockedVersion)
        XCTAssertEqual(try roundTrip(locked).versionLookup?.lowerBoundQueries, 0,
                       "量到安装版本还记降级 = 把已经做成的事再认一次账")
        XCTAssertFalse(cliText(of: locked).contains("声明范围的下界"),
                       "正例：没有降级就不许在 CLI 打这句")

        // 去掉锁文件：只剩范围 ⇒ 按下界 1.2.3 查询，且这一格必须在两出口同时出声。
        let ranges = try await analyze(["package.json": declared], tag: "fallback-range",
                                       online: nil, allowNetwork: false)
        let rangeRow = try XCTUnwrap(ranges.ecosystems.flatMap(\.dependencies).first)
        XCTAssertEqual(rangeRow.resolvedVersion, nil, "没有锁文件就是没量到，不许编一个")
        XCTAssertEqual(DependencyVersionIdentity.of(rangeRow).query?.basis, .rangeLowerBound)
        let stored = try roundTrip(ranges)
        XCTAssertEqual(stored.versionLookup?.lowerBoundQueries, 1, "落盘 JSON 那一格")
        XCTAssertEqual(stored.vulnerabilityLookup?.lowerBoundQueries, 1)
        let text = cliText(of: ranges)
        XCTAssertTrue(text.contains("声明范围的下界"), "CLI 必须说出这条降级：" + dependencyLines(text))
        XCTAssertTrue(text.contains("实际安装版本没量到"), dependencyLines(text))
    }

    /// D 组的失败态此前只断到解析器返回 nil（`testMalformedLocksYieldNoResolution`），
    /// 报告与出口那一层没人接手。这条补的是「读不动绝不长成解析成功」：
    /// 坏锁与无锁都必须停在「安装版本没量到」，且那句「安装版本由已解析产物给出」不许出现。
    ///
    /// ⚠️ 仍然没做到、也不许假装做到的一件事（已列进交回报告的缺口清单）：
    /// 产品里没有任何一格能回答「有一份锁文件我读不动」——它与「这个项目根本没有锁文件」
    /// 在三个出口长成一个样。本条只钉"不许冒充成功"这一侧，不替那一格的存在背书。
    func testUnreadableLockNeverClaimsAResolvedVersion() async throws {
        let declared = #"{"name":"lock-lab","dependencies":{"left-pad":"^1.2.3"}}"#
        let broken = try await analyze(["package.json": declared, "package-lock.json": "{ not json"],
                                       tag: "lock-unreadable", online: nil, allowNetwork: false)
        let row = try XCTUnwrap(broken.ecosystems.flatMap(\.dependencies).first)
        XCTAssertNil(row.resolvedVersion, "读不动的锁里编不出安装版本")
        XCTAssertNil(row.resolvedVersionSource, "没有来源可点名的结论就不许挂上")
        XCTAssertFalse(DependencyEvidence.declarationExplain(for: row).contains("安装版本由已解析产物给出"),
                       DependencyEvidence.declarationExplain(for: row))
        // 这一态现在唯一的出声口：它必须自己承认是按声明下界查的。
        XCTAssertEqual(DependencyVersionIdentity.of(row).query?.basis, .rangeLowerBound)
        let text = dependencyLines(cliText(of: broken))
        XCTAssertTrue(text.contains("声明范围的下界"), text)
    }

    // MARK: - ③ E 组：分 scope 的四列必须各归各的档

    /// 手写行为表（每档一枚不同的四元组，任何两列互换、任何两档互换都会红）：
    ///   运行时 声明1 漏洞核1 版本核1 命中0 —— OSV 答上且干净、registry 也答上
    ///   开发   声明1 漏洞核0 版本核1 命中0 —— OSV **点名失败**、registry 答上
    ///   平台   声明1 漏洞核1 版本核0 命中0 —— OSV 答上、registry 没答（peerDependencies）
    ///   未标注 声明1 漏洞核0 版本核0 命中0 —— 版本写 `*` ⇒ 两路都没资格进（optionalDependencies）
    ///   测试 / 构建 全 0 —— 空桶也必须留在账上（「这一档是 0」与「这一档没统计」得分开）
    func testEachScopeBucketKeepsItsOwnFourNumbersApart() async throws {
        let manifest = #"""
        {"name":"scope-lab",
         "dependencies":{"sc-runtime":"1.0.0"},
         "devDependencies":{"sc-dev":"1.0.0"},
         "peerDependencies":{"sc-peer":"1.0.0"},
         "optionalDependencies":{"sc-star":"*"}}
        """#
        let stub = StubOnlineSource(
            answered: [Self.coordinate("sc-runtime", "1.0.0"): [],
                       Self.coordinate("sc-peer", "1.0.0"): []],
            failedCoordinates: [Self.coordinate("sc-dev", "1.0.0")],
            latestVersions: ["sc-runtime": "1.0.0", "sc-dev": "1.0.0"])
        let report = try await analyze(["package.json": manifest], tag: "scope-columns", online: stub)
        XCTAssertEqual(stub.receivedOsvQueries.count, 3, "手写推导：`*` 那条没资格进查询批次")

        let breakdown = try XCTUnwrap(report.scopeBreakdown)
        XCTAssertEqual(breakdown.map(\.scope), ["运行时", "开发", "测试", "构建", "平台", "未标注"],
                       "六档必须按固定顺序全量列出 —— 缺档会被读成「这一档没统计」")
        let expected: [String: [Int]] = ["运行时": [1, 1, 1, 0], "开发": [1, 0, 1, 0],
                                         "测试": [0, 0, 0, 0], "平台": [1, 1, 0, 0],
                                         "构建": [0, 0, 0, 0], "未标注": [1, 0, 0, 0]]
        for row in breakdown {
            XCTAssertEqual([row.declared, row.vulnerabilityChecked, row.versionChecked, row.vulnerable],
                           expected[row.scope], "\(row.scope) 这一档的四列与手写行为表不符")
        }
        XCTAssertEqual(breakdown.reduce(0) { $0 + $1.declared }, report.totalDependencies)
    }

    /// 同一份账的三出口：字段 / CLI 那几行 / 屏上那张卡必须报同一批数，
    /// 且「只列非空档」这条规则两侧一致（不许一侧列出 0 档、另一侧不列）。
    /// `@MainActor` 只为一件事：卡片那两个静态方法住在 `View` 上（SwiftUI 是主 actor 隔离的）。
    @MainActor func testFieldScopeRowsCliLinesAndCardCaptionCarryTheSameNumbers() async throws {
        let manifest = #"""
        {"name":"scope-lab","dependencies":{"sc-runtime":"1.0.0"},
         "devDependencies":{"sc-dev":"1.0.0"}}
        """#
        let stub = StubOnlineSource(latestVersions: ["sc-runtime": "1.0.0", "sc-dev": "1.0.0"])
        let report = try await analyze(["package.json": manifest], tag: "scope-exits", online: stub)
        let rows = try XCTUnwrap(report.scopeBreakdown).filter { $0.declared > 0 }
        XCTAssertEqual(rows.map(\.scope), ["运行时", "开发"])

        let lines = DependencyScopeLines.lines(report)
        XCTAssertEqual(lines.count, rows.count, "CLI 每档一行，且只列非空档：\(lines)")
        for (index, row) in rows.enumerated() {
            XCTAssertTrue(lines[index].contains("· \(row.scope)：声明 \(row.declared)"), lines[index])
            XCTAssertTrue(lines[index].contains("漏洞已核对 \(row.vulnerabilityChecked)"), lines[index])
            XCTAssertTrue(lines[index].contains("版本已核对 \(row.versionChecked)"), lines[index])
            let caption = DependencyScopeBreakdown.caption(row)
            XCTAssertTrue(caption.contains("声明 \(row.declared)"), caption)
            XCTAssertTrue(caption.contains("漏洞已核对 \(row.vulnerabilityChecked)"), caption)
            XCTAssertTrue(caption.contains("版本已核对 \(row.versionChecked)"), caption)
            // 覆盖度不许只报分子：还有没核成的，屏上那一行必须把差值讲出来。
            XCTAssertTrue(DependencyScopeBreakdown.help(row).contains("未完成漏洞核对")
                          || row.vulnerabilityChecked == row.declared, DependencyScopeBreakdown.help(row))
        }
        for scope in ["测试", "构建"] {
            XCTAssertFalse(lines.contains { $0.contains("· \(scope)") }, "空档不许出现在 CLI：\(lines)")
        }
    }

    /// 一条依赖都没有时的第①态：两出口都得说「没有可统计的依赖声明」，而不是沉默。
    func testEmptyManifestStillSpeaksAtBothScopeExits() throws {
        var empty = DependencyReport()
        empty.ecosystems = [EcosystemReport(ecosystem: .npm, manifestPath: "package.json",
                                           lockfileName: nil, dependencies: [], frameworkMarkers: [])]
        let lines = DependencyScopeLines.lines(empty)
        XCTAssertEqual(lines, ["分 scope 统计：没有可统计的依赖声明"])
        // 兜底账本：没有逐条记录时也必须交出六档全 0，而不是「没有这本账」。
        let fallback = DependencyEvidence.ledger(for: empty).scopeBreakdown
        XCTAssertEqual(fallback.count, 6)
        XCTAssertEqual(fallback.reduce(0) { $0 + $1.declared }, 0)
    }

    /// 旧报告缺 `scopeBreakdown` 这一整键 ⇒ 读成「没统计」还是现推一本账？
    /// 手写推导：这一条带着内置命中、但没有逐条状态格 ⇒ 兜底账本按「命中即核对过」计，
    /// 且**新报告走字段、旧报告走兜底，两本账对同一批数据必须给出同一份数**。
    func testLegacyReportWithoutTheKeyFallsBackToTheSameRuler() async throws {
        let report = try await analyze(["package.json": Self.threeDependencyManifest], tag: "scope-legacy",
                                       online: StubOnlineSource(latestVersions: ["exit-a": "1.0.0",
                                                                                 "exit-b": "2.0.0",
                                                                                 "exit-c": "3.0.0"]))
        let written = try XCTUnwrap(report.scopeBreakdown)
        let legacy = try roundTrip(report, dropping: "scopeBreakdown")
        XCTAssertNil(legacy.scopeBreakdown, "整键删掉之后必须真是 nil，不许被补成空数组")
        let fallback = DependencyEvidence.ledger(for: legacy).scopeBreakdown
        XCTAssertEqual(fallback, written, "兜底那把尺子与写字段那把尺子一旦分叉，屏上与 JSON 就各报一本账")
    }

    // MARK: - 辅助

    private func analyze(_ files: [String: String], tag: String,
                         online: (any DependencyOnlineSource)?,
                         allowNetwork: Bool = true) async throws -> DependencyReport {
        let analyzer = online == nil
            ? ManifestDependencyAnalyzer(options: .default, maxDepth: 3)
            : ManifestDependencyAnalyzer(options: .default, maxDepth: 3, onlineSource: online!)
        return try await analyzer.analyze(projectRoot: try makeTree(tag, files: files), allowNetwork: allowNetwork)
    }

    /// CLI 出口：把这份依赖报告塞进唯一那份 schema，走 `score` 的文本装配口。
    ///
    /// 必须带上 `health` —— `CLIScoreText.render` 把「漏洞核对状态」那几行**排在分数之后**
    /// （见该文件第 3 条设计说明），没有评分结果时那一整段直接 return。评分用产品自己的
    /// `WeightedHealthScorer` 现算，不在测试里另抄一份分。
    private func cliText(of deps: DependencyReport) -> String {
        var report = ProjectReport(project: MonitoredProject(name: "出口对表", path: "/tmp/tcoder-exit-parity"))
        report.dependencies = deps
        report.health = WeightedHealthScorer().score(HealthInputs(dependencies: deps))
        return CLIScoreText.render(report, exit: .ok)
    }

    /// 断言消息只带**依赖那几行**（单行）。
    /// 实测教训：把整段多行 CLI 文本当消息塞进 XCTAssertEqual，红的时候日志里会
    /// **丢掉记录**（本文件第一版 8 例 6 失败、日志只有 3 条 error 记录，复跑同形）——
    /// 与 AGENTS §8 第 6.1 条「判据不许只有 print 一个出口」同族：红也要留得下字。
    private func dependencyLines(_ text: String) -> String {
        text.split(separator: "\n")
            .filter { $0.contains("漏洞核对") || $0.contains("分 scope") || $0.contains("下界") }
            .joined(separator: " ⏎ ")
    }

    private func roundTrip(_ deps: DependencyReport, dropping key: String? = nil) throws -> DependencyReport {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(deps)) as? [String: Any]
        json = try XCTUnwrap(json)
        if let key { json?.removeValue(forKey: key) }
        return try JSONDecoder().decode(DependencyReport.self, from: JSONSerialization.data(withJSONObject: json!))
    }

    private func makeTree(_ tag: String, files: [String: String]) throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tcoder-r36-exit-\(tag)-\(UUID().uuidString.prefix(8))", isDirectory: true)
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

    /// 只取「漏洞核对状态」**那一行**。RD-74 要判的是这一行内部有没有把同一对数印两遍，
    /// 拿全篇 `contains` 数会被「版本核对状态」与分 scope 那几行稀释成假绿。
    private static func vulnerabilityStatusLine(in text: String) -> String {
        text.split(separator: "\n").first { $0.hasPrefix("漏洞核对状态") }.map(String.init) ?? ""
    }

    /// 出现次数（`components` 相减是 0 次时得 0，不额外分支）。
    private static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}
