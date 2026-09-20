/// OWNER: WS-X3 TestSplit —— 自 DependencyNetworkLookupTests.swift 整块拆出：答案来源归因两例（在线快照 vs 内置快照）。用例本体一字未改，只是搬了家。
import XCTest
@testable import TcoderMonitor

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
