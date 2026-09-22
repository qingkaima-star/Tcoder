import XCTest
@testable import TcoderMonitor

// WS-B · 依赖侧测试：清单解析（契约 B）、内置快照与离线漏洞（契约 C）、
// 漏洞核对覆盖度三态（契约 F）。Git 侧在 GitDependencyTests.swift，
// 两者共用那里的 `Fixture`（同一编译单元内可见，命名不与他文件冲突）。
// MARK: - 契约 B：ManifestParsers

// MARK: - 契约 C：内置快照与离线漏洞

final class DependencySnapshotTests: XCTestCase {

    func assertVulnerable(_ ecosystem: DependencyEcosystem, _ name: String, _ version: String,
                                  _ label: String) {
        XCTAssertFalse(VulnerabilitySource.matches(ecosystem: ecosystem, name: name, version: version).isEmpty,
                       label)
    }

    func assertClean(_ ecosystem: DependencyEcosystem, _ name: String, _ version: String,
                             _ label: String) {
        XCTAssertTrue(VulnerabilitySource.matches(ecosystem: ecosystem, name: name, version: version).isEmpty,
                      label)
    }

    var vulnerableBatch: [DependencyRecord] {
        [Fixture.record(name: "lodash", version: "4.17.15", manifest: "package.json"),
         Fixture.record(name: "com.alibaba:fastjson", version: "1.2.68", ecosystem: .maven, manifest: "pom.xml"),
         Fixture.record(name: "org.apache.logging.log4j:log4j-core", version: "2.14.1", ecosystem: .maven,
                        manifest: "server/pom.xml"),
         Fixture.record(name: "axios", version: "0.21.1", manifest: "web/package.json")]
    }

    func testSnapshotMetadataAndLatestKnownVersion() throws {
        XCTAssertGreaterThan(DependencySnapshot.bundledEntryCount, 0, "内置快照不得为空")
        XCTAssertGreaterThan(DependencySnapshot.snapshotDate.timeIntervalSince1970, 1_600_000_000,
                             "快照日期必须晚于 2020 年")
        // 契约只要求「lodash 已收录、且最新已知版本不低于修复版 4.17.21」，不锁死具体小版本号。
        let lodash = try XCTUnwrap(DependencySnapshot.latestKnownVersion(ecosystem: .npm, name: "lodash"),
                                   "lodash 必须被内置快照收录")
        XCTAssertFalse(DependencyVersion.isOlder(current: lodash, than: "4.17.21"),
                       "lodash 的最新已知版本不得低于修复版 4.17.21")
        XCTAssertNil(DependencySnapshot.latestKnownVersion(ecosystem: .npm, name: "tcoder-not-real"),
                     "不存在的包返回 nil")
        XCTAssertNil(DependencySnapshot.latestKnownVersion(ecosystem: .npm, name: ""), "空包名返回 nil")
        let maven = DependencySnapshot.latestKnownVersion(ecosystem: .maven, name: "com.alibaba:fastjson")
        let gradle = DependencySnapshot.latestKnownVersion(ecosystem: .gradle, name: "com.alibaba:fastjson")
        XCTAssertNotNil(maven, "maven 坐标必须命中快照")
        XCTAssertEqual(gradle, maven, "gradle 与 maven 坐标互通")
    }

    func testMatchesRespectsFixVersionBoundary() throws {
        XCTAssertEqual(VulnerabilitySource.matches(ecosystem: .npm, name: "lodash", version: "4.17.15").count, 1,
                       "lodash 4.17.15 命中 1 条漏洞")
        assertClean(.npm, "lodash", "4.17.21", "lodash 4.17.21 是修复版本，不得命中")
        let hits = VulnerabilitySource.matches(ecosystem: .npm, name: "lodash", version: "4.17.15")
        let first = try XCTUnwrap(hits.first, "lodash 4.17.15 应有命中")
        XCTAssertTrue(first.affects(version: "4.17.20"), "受影响区间内为 true")
        XCTAssertFalse(first.affects(version: "4.17.21"), "修复版本本身为 false")
    }

    func testMatchesBoundariesAcrossEcosystems() {
        assertVulnerable(.maven, "com.alibaba:fastjson", "1.2.68", "fastjson 1.2.68 命中")
        assertVulnerable(.maven, "commons-collections:commons-collections", "3.2.1", "commons-collections 命中")
        assertVulnerable(.maven, "io.jsonwebtoken:jjwt", "0.9.1", "jjwt 0.9.1 命中")
        assertVulnerable(.maven, "org.apache.logging.log4j:log4j-core", "2.14.1", "log4j-core 2.14.1 命中")
        assertVulnerable(.npm, "axios", "0.21.1", "axios 0.21.1 命中")
        assertClean(.maven, "org.apache.logging.log4j:log4j-core", "2.20.0", "log4j-core 2.20.0 已修复")
        assertClean(.npm, "axios", "1.6.0", "新版 axios 不得命中")
        assertClean(.npm, "tcoder-not-real", "1.0.0", "不存在的包不得命中")
    }

    func testOfflineVulnerabilitiesAggregateAndCarryCVEIdentifiers() {
        let vulns = VulnerabilitySource.offlineVulnerabilities(for: vulnerableBatch)
        XCTAssertTrue(Set(["lodash", "com.alibaba:fastjson", "org.apache.logging.log4j:log4j-core", "axios"])
                        .isSubset(of: Set(vulns.map { $0.package })), "四个有漏洞的包都要出现")
        for vuln in vulns {
            XCTAssertFalse(vuln.cveIdentifiers.isEmpty, "\(vuln.package) 的 CVE 列表不得为空")
            XCTAssertTrue(vuln.cveIdentifiers.allSatisfy { $0.hasPrefix("CVE-") }, "\(vuln.package) 编号须为 CVE 格式")
            XCTAssertFalse(vuln.vulnerableRange.isEmpty, "\(vuln.package) 的区间描述不得为空")
            XCTAssertGreaterThan(vuln.severity.rank, RiskLevel.none.rank, "\(vuln.package) 级别不得是「无」")
        }
        let samePackage = VulnerabilitySource.offlineVulnerabilities(for: [
            Fixture.record(name: "lodash", version: "4.17.15", manifest: "package.json"),
            Fixture.record(name: "lodash", version: "4.17.20", manifest: "web/package.json"),
            Fixture.record(name: "lodash", version: "4.17.21", manifest: "app/package.json"),
        ])
        XCTAssertEqual(samePackage.count, 1, "同一包的多条命中聚合成 1 条")
        XCTAssertEqual(samePackage[0].package, "lodash", "包名正确")
        XCTAssertEqual(samePackage[0].ecosystem, .npm, "生态正确")
        XCTAssertEqual(samePackage[0].affectedDependencies.count, 2, "只有两个旧版本被计入")
        XCTAssertFalse(samePackage[0].affectedDependencies.contains { $0.isEmpty }, "受影响项不得为空串")
    }

    func testCleanInputProducesNoOfflineFindings() {
        let clean = [Fixture.record(name: "lodash", version: "4.17.21", manifest: "package.json"),
                     Fixture.record(name: "tcoder-not-real", version: "1.0.0", manifest: "package.json")]
        XCTAssertEqual(VulnerabilitySource.offlineVulnerabilities(for: clean), [], "干净依赖返回空数组")
        XCTAssertEqual(VulnerabilitySource.offlineVulnerabilities(for: []), [], "空输入返回空数组")
        XCTAssertEqual(VulnerabilitySource.bundledAdvisories(for: clean), [], "无漏洞时不得杜撰公告")
    }

    func testBundledAdvisoriesDescribeAffectedPackages() {
        let advisories = VulnerabilitySource.bundledAdvisories(
            for: [Fixture.record(name: "lodash", version: "4.17.15", manifest: "package.json")])
        XCTAssertFalse(advisories.isEmpty, "lodash 旧版本必须有公告")
        XCTAssertEqual(advisories[0].ecosystem, .npm, "公告生态正确")
        XCTAssertFalse(advisories[0].id.isEmpty, "公告 id 不得为空")
        XCTAssertFalse(advisories[0].summary.isEmpty, "公告标题不得为空")
        XCTAssertTrue(advisories[0].affectedPackages.contains { $0.contains("lodash") }, "受影响包含 lodash")
    }

    /// RD-10：这条用例**原来是在给一个缺陷发合格证**，2026-09-22 由 R3 按 AGENTS §8.1 豁免改正。
    ///
    /// 它原来断言（逐条）：
    ///   · `isOlder("^1.2.3", "1.2.4") == true`，注释写"`^1.2.3` 归一化为 0 视为落后"；
    ///   · `isOlder("1.2.3", "^1.2.4") == false`，注释写"latest 归一化为 0 时不得判落后"；
    ///   · `isOlder("", "1.0.0") == true` / `isOlder("abc", "1.0.0") == true`，注释"归一化为 [0]"；
    ///   · `normalize("2.0") == [2, 0]` 且隐含"解析不出就是 `[0]`"。
    /// 为什么那是错的：`normalize` 的截断符集合里写着 `^~<>`，所以 caret 在**第一个字符**就断成
    /// 空前缀 → `[0]` → "0.0.0 落后于任何版本"。后果有两个方向都错：
    ///   ① 任何 `^x.y.z` 声明被虚报成"版本过旧"（本仓自扫时 express `^5.2.1` 就是受害者，
    ///      而 `KnownVulnerability.comparableCore` 会吃掉 `^` ⇒ 同一份数据两套口径）；
    ///   ② `""` / `abc` / `*` 被折成 0.0.0 去和真版本比，于是"没量到"长成了"量出来很旧"。
    /// 现在断言什么：解析不出的一方一律 **`.unknown`**，`isOlder` 对未知返回 false（不宣称过旧），
    /// 而 caret 的比较按**它写的下界**（与 `comparableCore` 同一把尺子）；
    /// "下界不等于安装版本"这条语义由 `DependencyVersionIdentity` 负责，见同文件新用例。
    func testVersionIsOlderEdgeCases() {
        XCTAssertEqual(DependencyVersion.normalize("2.0"), [2, 0], "数字芯解析")
        XCTAssertEqual(DependencyVersion.normalize("^1.2.3"), [1, 2, 3],
                       "caret 的下界是它写着的那个数 —— 与 comparableCore 同一口径，不再折成 [0]")
        XCTAssertEqual(DependencyVersion.normalize("*"), [], "通配解析不出就是空，不许伪造 [0]")
        XCTAssertEqual(DependencyVersion.normalize(""), [], "空串同上")
        XCTAssertEqual(DependencyVersion.normalize(ManifestParsers.undeclaredVersion), [], "「未声明」同上")
        XCTAssertEqual(DependencyVersion.normalize("[1.0,2.0)"), [], "Maven 区间不是一个版本号")

        XCTAssertEqual(DependencyVersion.outcome(current: "^1.2.3", than: "1.2.4"), .older,
                       "比较的是串里写着的 1.2.3；这条依赖**装的是哪个版本**由版本身份那一层判")
        XCTAssertEqual(DependencyVersion.outcome(current: "1.2.3", than: "^1.2.4"), .older)
        XCTAssertEqual(DependencyVersion.outcome(current: "", than: "1.0.0"), .unknown,
                       "旧实现此处判『更旧』，那是把没量到说成量出来很旧")
        XCTAssertEqual(DependencyVersion.outcome(current: "abc", than: "1.0.0"), .unknown)
        XCTAssertEqual(DependencyVersion.outcome(current: "*", than: "1.0.0"), .unknown)
        XCTAssertFalse(DependencyVersion.isOlder(current: "*", than: "1.0.0"),
                       "不可比较 ⇒ 不得产出『过旧』这个结论")

        XCTAssertFalse(DependencyVersion.isOlder(current: "1.0.0.0.0.0.0", than: "1.0.0"), "多出的零段不得判落后")
        XCTAssertTrue(DependencyVersion.isOlder(current: "1.0.0.0.0.0.2", than: "1.0.0.0.0.0.3"), "超长段数逐位比较")
        XCTAssertTrue(DependencyVersion.isOlder(current: "1.0.0-SNAPSHOT", than: "1.0.0"),
                      "预发布低于正式版（semver）。旧实现把 `-SNAPSHOT` 整个截掉 ⇒ 与正式版判等，"
                      + "于是快照过期的包永远判不出落后")
        XCTAssertFalse(DependencyVersion.isOlder(current: "33.3.1-jre", than: "33.3.1"),
                       "发行限定（-jre / -android）不是预发布，与正式版同档")
        XCTAssertFalse(DependencyVersion.isOlder(current: "1.2.3+build7", than: "1.2.3"),
                       "构建元数据不参与先后")
    }

    /// `compare` 那颗地雷：**解析不出来的两个版本曾被判"相等"**（`.orderedSame`）。
    ///
    /// 现场（改前原文，`DependencyVersionRuler.swift`）：
    /// `guard let left = Self.core(lhs), let right = Self.core(rhs) else { return .orderedSame }`
    /// —— 三态在 `outcome()` 里是有的（`.unknown`），这一支却是它的失真副本：
    /// 谁拿它去排序 / 去重 / 分组，`*`、`latest`、`未声明`、`[1.0,2.0)` 就会互相"相等"。
    /// 本仓当时**零调用方**（Sources + Tests 逐条 grep，只有注释提到它）⇒ 不是活 bug，是地雷。
    ///
    /// 期望全部手写（semver 定义 + "认不出就不是相等"这条语义），不是从实现输出回填的：
    ///   · 可比较的样本给确定的升/降/等；
    ///   · 认不出的样本给 **nil**，且 nil **永远不许**被读成 `.orderedSame`；
    ///   · 同一个样本集上 `compare` 与 `outcome` 必须一个答案都不差（同一把尺子的两条出口）；
    ///   · `isComparable` 与「compare 有没有值」必须同真同假。
    func testCompareRefusesToCallUnknownEqual() {
        // (左, 右, 手写的 compare 期望, 手写的 outcome 期望)
        let table: [(String, String, ComparisonResult?, DependencyVersion.Outcome)] = [
            ("^1.2.3", "1.2.4", .orderedAscending, .older),       // 比的是写着的那个下界
            ("1.2.4", "^1.2.3", .orderedDescending, .newer),
            ("1.2.3", "1.2.3.0", .orderedSame, .same),           // 缺段按 0 补 ⇒ 这才是真的"相等"
            ("1.2.3-beta", "1.2.3", .orderedAscending, .older),   // 预发布低于正式版
            ("1.2.3+build7", "1.2.3", .orderedSame, .same),       // 构建元数据不参与先后
            ("1.0.0-jre-SNAPSHOT", "1.0.0", .orderedAscending, .older),
            ("2.14.1", "2.0.0", .orderedDescending, .newer),
            ("*", "1.0.0", nil, .unknown),                        // ↓ 这四支就是地雷本体
            ("1.0.0", "*", nil, .unknown),
            ("latest", "1.0.0", nil, .unknown),
            ("", "1.0.0", nil, .unknown),
            ("abc", "def", nil, .unknown),                        // 两侧都认不出：旧实现判 .orderedSame
            ("[1.0,2.0)", "1.5", nil, .unknown),
            (ManifestParsers.undeclaredVersion, "1.0.0", nil, .unknown),
        ]
        XCTAssertFalse(table.isEmpty)
        var comparableSamples = 0
        var unknownSamples = 0
        for (left, right, expectedComparison, expectedOutcome) in table {
            XCTAssertEqual(DependencyVersion.compare(left, right), expectedComparison,
                           "compare 判错：\(left) vs \(right)")
            if expectedComparison == nil {
                // 地雷本体：认不出的一侧**永远不许**长成 `.orderedSame`（那是谎称相等）。
                XCTAssertNil(DependencyVersion.compare(left, right),
                             "不可比较被折成了相等语义：\(left) vs \(right)")
            }
            XCTAssertEqual(DependencyVersion.outcome(current: left, than: right), expectedOutcome,
                           "同一把尺子的两条出口分叉：\(left) vs \(right)")
            // compare 有没有值 ⟺ **两侧**都能解析（一侧认不出就整体不可比）。
            XCTAssertEqual(DependencyVersion.isComparable(left) && DependencyVersion.isComparable(right),
                           DependencyVersion.compare(left, right) != nil,
                           "「能不能比」与「compare 有没有值」必须同真同假：\(left) vs \(right)")
            if expectedComparison == nil { unknownSamples += 1 } else { comparableSamples += 1 }
        }
        XCTAssertGreaterThanOrEqual(comparableSamples, 6, "可比较样本不足，上面的对照是空跑")
        XCTAssertGreaterThanOrEqual(unknownSamples, 6, "认不出的样本不足，地雷等于没被踩过")
    }

    /// 逐条依赖的"这条到底过没过旧"必须走版本身份，而不是直接拿清单原文去比。
    /// 这里是那条链的入口守卫：`isProbablyOutdated` 读 `resolvedVersion`，
    /// 没有解析值时**范围声明判未定**（既不报过旧、也不报正常）。
    func testIsProbablyOutdatedUsesResolvedVersionNotDeclaredRange() {
        func record(_ version: String, resolved: String?, latest: String?) -> DependencyRecord {
            DependencyRecord(name: "acme", version: version, ecosystem: .npm, scope: .runtime,
                             manifestPath: "package.json", latestKnownVersion: latest,
                             versionCheckSource: latest == nil ? .none : .bundledSnapshot,
                             knownVulnerabilities: [], resolvedVersion: resolved)
        }
        XCTAssertTrue(record("^1.2.3", resolved: "1.2.3", latest: "1.2.4").isProbablyOutdated,
                      "锁文件说装的是 1.2.3，最新是 1.2.4 ⇒ 过旧")
        XCTAssertFalse(record("^1.2.3", resolved: nil, latest: "1.2.4").isProbablyOutdated,
                       "只有范围、没有解析值 ⇒ 安装版本未知，不许报过旧")
        XCTAssertFalse(record("^5.2.1", resolved: "5.2.1", latest: "5.2.1").isProbablyOutdated,
                       "已是最新，不得判过旧（旧实现在这里判 true）")
        XCTAssertFalse(record("*", resolved: nil, latest: "1.9.0").isProbablyOutdated, "通配不折成 0")
        XCTAssertFalse(record("workspace:*", resolved: nil, latest: "1.9.0").isProbablyOutdated)
        XCTAssertFalse(record("1.9.0", resolved: nil, latest: nil).isProbablyOutdated,
                       "没有『最新』这一侧的证据时不得判过旧")
        XCTAssertFalse(record("2.0.0", resolved: nil, latest: "1.9.0").isProbablyOutdated,
                       "当前高于最新 ⇒ 快照过期，不是过旧")
        XCTAssertEqual(DependencyVersionIdentity.of(record("2.0.0", resolved: nil, latest: "1.9.0")).outdatedness,
                       .aheadOfLatest, "『高于最新』要能单独读出来，不能被压进『不过旧』这一格")
    }
}

// 契约 F（漏洞核对覆盖度三态）已于 2026-09-22 整块搬到同目录的
// `DependencySafetyVerdictTests.swift` —— 400 行口径下按**类型**整块搬，判据一字未动。

