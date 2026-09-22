// OWNER: R3 依赖证据链 · 版本模型用例（RD-10）
//
// 真值全部来自本文件内联的字符串夹具（**不读本机任何其它工程**）：
// 每一条期望都是手写的，不是拿实现输出回填的。
//
// 为什么这些用例一上手就是红的：整改清单 RD-10 点名的退化 ——
// `DependencyVersion.normalize("^1.2.3")` 在首字符 `^` 处截断成空前缀 ⇒ `[0]` ⇒
// 任何 caret 声明都被判成"落后于任何最新版本"，而 `*` / `latest` / `未声明`
// 同样被折算成 0 参与比较。旧测试（`DependencySnapshotTests.testVersionIsOlderEdgeCases`）
// 认可了这个退化，本次一并修正（见该文件与提交信息）。
import XCTest
@testable import TcoderMonitor

final class DependencyVersionIdentityTests: XCTestCase {

    /// 手写一条依赖的三份版本。`declared` 一律是清单原文。
    func identity(_ declared: String, resolved: String? = nil, latest: String? = nil,
                  ecosystem: DependencyEcosystem = .npm,
                  name: String = "acme-pkg") -> DependencyVersionIdentity {
        DependencyVersionIdentity(ecosystem: ecosystem, name: name,
                                  declaredRange: declared, resolvedVersion: resolved,
                                  latestKnownVersion: latest)
    }

    /// 契约记录形状：用来打真 `isProbablyOutdated`（视图与评分读的就是它）。
    func recordLike(_ declared: String, resolved: String?, latest: String?,
                    ecosystem: DependencyEcosystem = .npm) -> DependencyRecord {
        DependencyRecord(name: "acme-pkg", version: declared, ecosystem: ecosystem, scope: .runtime,
                         manifestPath: "package.json", latestKnownVersion: latest,
                         versionCheckSource: latest == nil ? .none : .bundledSnapshot,
                         knownVulnerabilities: [], resolvedVersion: resolved)
    }

    // MARK: - 1. 三份版本各存各的，不互相冒充

    func testDeclaredResolvedAndLatestAreKeptApart() {
        let record = DependencyRecord(name: "react", version: "^18.2.0", ecosystem: .npm, scope: .runtime,
                                      manifestPath: "package.json", latestKnownVersion: "19.3.0",
                                      versionCheckSource: .bundledSnapshot, knownVulnerabilities: [])
        let locked = identity(record.version, resolved: "18.2.0", latest: record.latestKnownVersion)
        XCTAssertEqual(locked.declaredRange, "^18.2.0", "声明范围原样保留，不许被剥成 18.2.0")
        XCTAssertEqual(locked.resolvedVersion, "18.2.0", "锁定版本单独存")
        XCTAssertEqual(locked.latestKnownVersion, "19.3.0", "最新已知版本单独存")
        XCTAssertEqual(locked.comparisonVersion, "18.2.0", "比较用的是**安装**的那个版本")
        XCTAssertEqual(locked.query?.version, "18.2.0")
        XCTAssertEqual(locked.query?.basis, .lockedVersion, "有锁文件解析值时查询身份必须是它")
    }

    func testUnparsedLockKeepsDeclaredRangeVisible() {
        let unlocked = identity("^18.2.0", resolved: nil, latest: "19.3.0")
        XCTAssertNil(unlocked.comparisonVersion, "只有范围时不许把下界当安装版本去比")
        XCTAssertEqual(unlocked.query?.basis, .rangeLowerBound, "范围仍能查，但必须标成按下界查询")
        XCTAssertEqual(unlocked.query?.version, "18.2.0")
    }

    // MARK: - 2. 未知 / 通配 / workspace / 无版本 一律不得折算成 0

    func testNonVersionsNeverCollapseToZero() {
        // (清单原文, 应有的声明形态) —— 两态都"没有版本"，但含义不同，必须分别落。
        let cases: [(String, DependencyDeclaredForm)] = [
            ("*", .wildcard), ("x", .wildcard), ("latest", .wildcard), ("any", .wildcard),
            ("", .unspecified), (ManifestParsers.undeclaredVersion, .unspecified),
        ]
        for (raw, form) in cases {
            let subject = identity(raw, latest: "1.0.0")
            XCTAssertEqual(subject.declaredForm, form, "\(raw) 的声明形态")
            XCTAssertNil(subject.comparisonVersion, "\(raw) 不许产生可比较版本（旧实现折算成 0）")
            XCTAssertNil(subject.query, "\(raw) 根本没资格进在线查询")
            XCTAssertEqual(subject.outdatedness, .undetermined(.versionUnspecified),
                           "\(raw) 必须落成「未定 · 版本未指定」，既不是过旧也不是最新")
            XCTAssertEqual(DependencyVersion.normalize(raw), [], "normalize 解析不出时返回空数组，不再返回 [0]")
        }
    }

    func testWorkspaceProtocolIsItsOwnState() {
        let subject = identity("workspace:*", latest: "1.9.0")
        XCTAssertEqual(subject.declaredForm, .workspace)
        XCTAssertEqual(subject.outdatedness, .undetermined(.workspaceProtocol))
        XCTAssertNil(subject.query, "workspace: 的版本在仓内另一份清单里，按包名去查注册表是错的")
    }

    func testExternalSourceVersionsAreNotRegistryVersions() {
        for raw in ["git+https://github.com/acme/x.git#semver:~1.2.0", "file:../local-pkg",
                   "branch:main", "acme/x#abc1234"] {
            let subject = identity(raw, latest: "1.2.0")
            XCTAssertEqual(subject.declaredForm, .externalSource, "\(raw) 不是注册表版本")
            XCTAssertEqual(subject.outdatedness, .undetermined(.nonRegistrySource))
            XCTAssertNil(subject.query)
        }
    }

    // MARK: - 3. 范围不得被当成"已安装版本"参与新旧判定

    func testRangeWithoutLockIsUndeterminedNotOutdated() {
        // 独立真值：^1.2.3 允许 1.2.3…1.x，实际装的是哪个**没量到** ⇒ 结论只能是未定。
        let caret = identity("^1.2.3", resolved: nil, latest: "1.2.4")
        XCTAssertEqual(caret.outdatedness, .undetermined(.rangeNotResolved))
        // 分层要说清：`DependencyVersion` 是"这两个串谁在前"的工具，它按串里写着的下界回答；
        // **"这条依赖过不过旧"只能走上面的 outdatedness** —— 后者在没有解析值时判未定。
        // 旧实现的问题是第二层直接用了第一层，于是 caret 声明被成片虚报成过旧。
        XCTAssertEqual(DependencyVersion.outcome(current: "^1.2.3", than: "1.2.4"), .older)
        XCTAssertFalse(recordLike("^1.2.3", resolved: nil, latest: "1.2.4").isProbablyOutdated,
                       "语义层不得把范围下界当安装版本判过旧（旧实现在这里返回 true）")
        XCTAssertTrue(recordLike("^1.2.3", resolved: "1.2.3", latest: "1.2.4").isProbablyOutdated,
                      "锁文件解析出来之后，同一个范围就能判了")
        let tilde = identity("~1.2.3", resolved: nil, latest: "1.9.0")
        XCTAssertEqual(tilde.outdatedness, .undetermined(.rangeNotResolved))
        let mavenRange = identity("[1.0,2.0)", resolved: nil, latest: "2.1.0",
                                  ecosystem: .maven, name: "org.acme:legacy")
        XCTAssertEqual(mavenRange.outdatedness, .undetermined(.rangeNotResolved))
        let wildcardPatch = identity("1.2.x", resolved: nil, latest: "1.2.9")
        XCTAssertEqual(wildcardPatch.outdatedness, .undetermined(.rangeNotResolved))
    }

    func testRangeWithLockUsesTheLockedVersion() {
        let subject = identity("^1.2.3", resolved: "1.2.9", latest: "1.2.4")
        XCTAssertEqual(subject.outdatedness, .aheadOfLatest, "锁到 1.2.9 而最新已知是 1.2.4 ⇒ 快照过期，不是过旧")
    }

    // MARK: - 4. 精确比较：高于 / 等于 / 低于 / 预发布

    func testExactComparisonDirections() {
        XCTAssertEqual(identity("1.2.3", latest: "1.2.4").outdatedness, .older)
        XCTAssertEqual(identity("1.2.4", latest: "1.2.4").outdatedness, .atLatest)
        XCTAssertEqual(identity("1.2.5", latest: "1.2.4").outdatedness, .aheadOfLatest,
                       "当前高于最新不许判成过旧（那是快照过期）")
        XCTAssertEqual(identity("4.17.15", latest: "4.17.21").outdatedness, .older)
        XCTAssertEqual(identity("0.9.1", latest: "0.12.6").outdatedness, .older, "逐段比较而非字典序")
        XCTAssertEqual(identity("1.0.0.0.0.0.0", latest: "1.0.0").outdatedness, .atLatest, "多出的零段等值")
    }

    func testPrereleaseOrdersBelowItsRelease() {
        let beta = identity("1.2.3-beta.1", latest: "1.2.3")
        XCTAssertEqual(beta.outdatedness, .older, "预发布版低于正式版")
        XCTAssertEqual(identity("1.2.3-beta.1", latest: "1.2.4-beta.2").outdatedness, .older)
        XCTAssertEqual(identity("1.2.3-beta.2", latest: "1.2.3-beta.1").outdatedness, .aheadOfLatest)
        XCTAssertEqual(identity("1.2.3-beta.1", latest: "1.2.3-beta.1").outdatedness, .atLatest)
        XCTAssertNotNil(DependencySemver.parse("1.2.3-beta.1"), "预发布是可解析的版本，不是脏数据")
        // `-jre` / `-android` 这类发行限定不是预发布：guava 33.3.1-jre 对 33.3.1 视为同档
        XCTAssertEqual(identity("33.3.1-jre", latest: "33.3.1").outdatedness, .atLatest)
        XCTAssertEqual(identity("1.0.0-SNAPSHOT", latest: "1.0.0").outdatedness, .older,
                       "SNAPSHOT 不是正式版，低于正式版")
        XCTAssertEqual(identity("1.2.3+build7", latest: "1.2.3").outdatedness, .atLatest,
                       "构建元数据按 semver 不参与先后")
    }

    func testMissingLatestSideIsUndeterminedNotZero() {
        XCTAssertEqual(identity("1.2.3", latest: nil).outdatedness, .undetermined(.missingLatestVersion),
                       "没有「最新」这一侧的证据时不许判过旧，也不许判「已是最新」")
        XCTAssertEqual(identity("abc", latest: "1.0.0").outdatedness, .undetermined(.malformedVersion))
    }

    // MARK: - 5. 查询身份与回填身份同源（RD-12 的地基）

    func testQueryCoordinateIsTheSameStringOnBothEnds() {
        let record = DependencyRecord(name: "lodash", version: "^4.17.15", ecosystem: .npm, scope: .runtime,
                                      manifestPath: "package.json", latestKnownVersion: nil,
                                      versionCheckSource: VersionCheckSource.none, knownVulnerabilities: [])
        let subject = identity(record.version, latest: nil, name: record.name)
        guard let query = subject.query else { return XCTFail("caret 声明至少要能按下界查询") }
        XCTAssertEqual(query.version, "4.17.15")
        let fromQuery = DependencyVersionIdentity.coordinate(ecosystem: .npm, name: record.name,
                                                            queryVersion: query.version)
        XCTAssertEqual(subject.coordinate(for: query.version), fromQuery,
                       "回填 key 必须由同一个 helper 生成，禁止两侧各自拼 name@version")
        XCTAssertNotEqual(fromQuery, DependencyVersionIdentity.coordinate(ecosystem: .npm, name: "lodash",
                                                                        queryVersion: record.version),
                          "回填侧若误用声明原文（^4.17.15）就会与查询侧错开 —— 这条不许被撞回")
    }

    func testRecordIDSeparatesSamePackageAcrossManifestsAndVersions() {
        let a = DependencyVersionIdentity.recordID(ecosystem: .npm, manifestPath: "package.json",
                                                  name: "lodash", declaredRange: "4.17.15")
        let b = DependencyVersionIdentity.recordID(ecosystem: .npm, manifestPath: "web/package.json",
                                                  name: "lodash", declaredRange: "4.17.15")
        let c = DependencyVersionIdentity.recordID(ecosystem: .npm, manifestPath: "package.json",
                                                  name: "lodash", declaredRange: "4.17.20")
        XCTAssertEqual(Set([a, b, c]).count, 3, "同包多清单、同包多版本必须是三个不同的稳定 ID")
    }
}
