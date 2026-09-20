/// OWNER: WS-X3 TestSplit —— 自 DependencyNetworkLookupTests.swift 整块拆出：硬超时一档预算。用例本体一字未改，只是搬了家。
import XCTest
@testable import TcoderMonitor

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
