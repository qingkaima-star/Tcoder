// OWNER: R3 依赖证据链 · 全仓只许有一把版本尺子（RD-10 / RD-12，台账 §9.5 第 1 条）
//
// 台账 §9.5 第 1 条的原话：`KnownVulnerability.comparableCore` 还在三个调用点上活着，
// **两套版本解析器并存就是 RD-10 的根因本身，不许留成第三套**。
// 本文件把"两套尺子"曾经分叉出的三个后果各自钉死：
//   1. 同一个版本串，"比较那条路"与"公告命中那条路"给出不同答案（下表逐条手写真值）；
//   2. 同一条依赖，总览列了公告而依赖行没标记（两份取数口径：一份用声明原文、一份用查询身份）；
//   3. 查询侧与回填侧的坐标不是同一个字符串（gradle 记录两侧分别长成 `gradle|…` 与 `maven|…`）。
// 第 4 组是防回归的扫描守卫（带分母 > 0 与两条反向元测试）。
// 表里的期望全部**手写**（semver 定义 + 内置公告表的边界），没有一条是从实现输出抄回来的。
import XCTest
@testable import TcoderMonitor

final class DependencySingleRulerTests: XCTestCase {

    // MARK: - 1. 同一个串，两条路必须同答案

    /// (版本原文, 受影响上界, 手写真值：能不能比 / 比出来是不是更旧)
    private static let versionTable: [(raw: String, upperBound: String, comparable: Bool, older: Bool)] = [
        ("^4.17.15", "4.17.21", true, true),          // caret 声明：可比、下界就低于上界
        ("~4.17.15", "4.17.21", true, true),
        (">= 3.2.1", "4.0.0", true, true),            // 带空格的范围算符
        ("4.17.21", "4.17.21", true, false),          // 相等 ⇒ 不在「< 上界」之内
        ("4.17.22", "4.17.21", true, false),
        ("1.2.3-beta", "1.2.3", true, true),          // 预发布低于正式版（旧 comparableCore 截成 1.2.3 ⇒ 漏报）
        ("1.0.0-jre-SNAPSHOT", "1.0.0", true, true),  // 同上：`-` 段不再被整段丢掉
        ("33.3.1-jre", "33.3.0", true, false),        // 字母限定不是预发布 ⇒ 33.3.1 > 33.3.0
        ("1.2.3+build7", "1.2.3", true, false),       // 构建元数据不参与先后
        ("v1.2.0", "1.3.0", true, true),
        ("1.2.3.4.5", "4.17.21", true, true),         // 四段号
        ("*", "4.17.21", false, false),
        ("latest", "4.17.21", false, false),
        ("workspace:*", "4.17.21", false, false),
        ("未声明", "4.17.21", false, false),
        ("", "4.17.21", false, false),
        ("abc", "4.17.21", false, false),
        ("1.2.x", "4.17.21", false, false),           // 含 x 的通配不是版本号
        ("[1.0,2.0)", "4.17.21", false, false),       // 区间写法本身不是「一个版本」
        ("1.0.0 || 2.0.0", "4.17.21", false, false),
        ("git+https://github.com/acme/x.git", "1.0.0", false, false),
    ]

    /// lodash 那条内置公告（`< 4.17.21`）= "公告命中那条路"的样本。
    private var lodashRule: KnownVulnerability {
        VulnerabilitySource.bundled.first { $0.package == "lodash" }
            ?? KnownVulnerability(id: "T", ecosystem: .npm, package: "lodash", affectedBelow: "4.17.21",
                                  introducedIn: nil, fixedVersion: "4.17.21", severity: .high,
                                  cveIdentifiers: ["CVE-2021-23337"], summary: "s", details: "d",
                                  source: VulnerabilitySource.bundledSource)
    }

    /// **正例 / 反例 / 未知态**同表跑：比较那条路与公告命中那条路必须一个答案都不差。
    ///
    /// 两条路的定义（"两条路"就是字面这两条）：
    ///   · 比较路 = `DependencyVersion.outcome(current:than:)`（契约上那把尺子，内部走 `DependencySemver`）；
    ///   · 公告路 = `KnownVulnerability.affects(version:)`（曾经自带 `comparableCore` 第二套解析）。
    func testSameStringSameAnswerOnBothPaths() {
        XCTAssertFalse(Self.versionTable.isEmpty, "表夹具空着的话这条用例就是永真绿")
        var comparableCases = 0
        var uncomparableCases = 0
        for row in Self.versionTable {
            let outcome = DependencyVersion.outcome(current: row.raw, than: row.upperBound)
            var rule = lodashRule
            rule.affectedBelow = row.upperBound   // 公告路必须拿**同一道上界**来比，否则比的不是同一件事
            XCTAssertEqual(DependencyVersion.isComparable(row.raw), row.comparable,
                           "「能不能比」判错：\(row.raw) 实得 \(outcome)")
            XCTAssertEqual(outcome == .older, row.older,
                           "比较路答案错：\(row.raw) vs \(row.upperBound) 实得 \(outcome)")
            XCTAssertEqual(rule.affects(version: row.raw), row.older,
                           "两条路分叉（RD-10 根因形状）：\(row.raw) 比较路=\(outcome) 公告路不同答案")
            if row.comparable { comparableCases += 1 } else { uncomparableCases += 1 }
        }
        XCTAssertGreaterThanOrEqual(comparableCases, 8, "可比较的正/反例样本不足，守卫没在管东西")
        XCTAssertGreaterThanOrEqual(uncomparableCases, 8, "未知态样本不足，守卫没在管东西")
    }

    /// 内置公告的**下界**那一支（log4j `>= 2.0.0 < 2.17.1`）也必须走同一把尺子。
    func testIntroducedInBoundUsesTheSameRuler() throws {
        let rule = try XCTUnwrap(VulnerabilitySource.bundled.first { $0.package.contains("log4j-core") })
        XCTAssertEqual(rule.introducedIn, "2.0.0", "手写期望：这条公告带下界")
        XCTAssertEqual(rule.affectedBelow, "2.17.1")
        let cases: [(String, Bool)] = [
            ("2.14.1", true), ("2.0.0", true), ("1.2.3", false), ("2.17.1", false),
            ("2.18.0", false), ("*", false), ("未声明", false),
            ("2.0.0-rc1", false),   // 预发布低于 2.0.0 ⇒ 在区间之外（同一把尺子的必然结论）
        ]
        for (raw, hit) in cases {
            XCTAssertEqual(rule.affects(version: raw), hit, "下界支判错：\(raw)")
            let viaComparison = DependencyVersion.isComparable(raw)
                && DependencyVersion.outcome(current: raw, than: "2.17.1") == .older
                && DependencyVersion.outcome(current: raw, than: "2.0.0") != .older
            XCTAssertEqual(viaComparison, hit, "下界支与比较路分叉：\(raw)")
        }
    }

    // MARK: - 2. 总览与依赖行取同一个数（同一条路的两个出口）

    /// 离线一次分析之后：**总览列出的每条公告都能在依赖行上找到标记，反向亦然**。
    /// 旧实现两份取数口径（行用查询身份、总览用声明原文）就是台账 X6
    /// 「总览说有公告而依赖行没标记」的机制。
    func testOverviewAndRowAgreeOnTheSameRecord() async throws {
        let root = try makeTree("single-ruler-overview", files: [
            "package.json": #"{"name":"app","dependencies":{"lodash":"^4.17.15","axios":"0.21.1","left-pad":"1.3.0"}}"#,
            "requirements.txt": "requests==2.28.1\ndjango>=4.2.0\nurllib3==1.26.18\n",
        ])
        let report = try await ManifestDependencyAnalyzer(options: .default, maxDepth: 3)
            .analyze(projectRoot: root, allowNetwork: false)
        let records = report.ecosystems.flatMap(\.dependencies)
        XCTAssertEqual(records.count, 6)

        // 手写真值（逐条对着内置公告表推）：
        //   lodash ^4.17.15 → 下界 4.17.15 < 4.17.21 ⇒ CVE-2021-23337
        //   axios  0.21.1   → < 0.21.2              ⇒ CVE-2020-28168
        //   left-pad 1.3.0  → 内置表没收              ⇒ 不命中
        //   requests 2.28.1 → < 2.31.0              ⇒ CVE-2023-32681
        //   django >=4.2.0  → 取下界 4.2.0 < 4.2.6  ⇒ CVE-2023-43666
        //   urllib3 1.26.18 → 上界不含 ⇒ 正好等于     ⇒ 不命中
        let expectedHit: [String: String] = [
            "lodash": "CVE-2021-23337", "axios": "CVE-2020-28168",
            "requests": "CVE-2023-32681", "django": "CVE-2023-43666",
        ]
        for record in records {
            let expected = expectedHit[record.name]
            XCTAssertEqual(record.knownVulnerabilities, expected.map { [$0] } ?? [],
                           "行上标记错：\(record.name) 声明 \(record.version)")
            let coordinate = record.dependencyCoordinate
            let listedInOverview = report.offlineVulnerabilities.contains { vuln in
                vuln.cveIdentifiers.contains(expected ?? "\u{0000}")
                    && vuln.affectedDependencies.contains(coordinate ?? "\u{0001}")
            }
            XCTAssertEqual(listedInOverview, expected != nil,
                           "总览与依赖行对不上账（X6）：\(record.name)，行=\(record.knownVulnerabilities) 总览=\(report.offlineVulnerabilities.map(\.id))")
        }
        XCTAssertEqual(report.offlineVulnerabilities.count, 4, "真值：4 条规则命中")
        XCTAssertEqual(report.vulnerableCount, 4, "真值：4 个受影响坐标")
    }

    // MARK: - 3. 查询侧与回填侧的坐标必须是同一个字符串

    func testQueryAndBackfillCoordinateAreTheSameString() {
        func rec(_ name: String, _ declared: String, ecosystem: DependencyEcosystem,
                 manifest: String, resolved: String? = nil) -> DependencyRecord {
            DependencyRecord(name: name, version: declared, ecosystem: ecosystem, scope: .runtime,
                             manifestPath: manifest, latestKnownVersion: nil, versionCheckSource: .none,
                             knownVulnerabilities: [], resolvedVersion: resolved)
        }

        // 正例①：npm caret —— 两侧都必须用**下界**，不是声明原文。
        let caret = rec("lodash", "^4.17.15", ecosystem: .npm, manifest: "package.json")
        let built = OsvPackageQuery.query(from: caret)
        XCTAssertEqual(built?.coordinate, "npm|lodash|4.17.15", "手写期望：坐标三段")
        XCTAssertEqual(DependencyVersionIdentity.of(caret).queryCoordinate, built?.coordinate,
                       "回填侧 key 与查询侧 key 必须一字不差")

        // 正例②：gradle 记录。旧实现两侧分别长成 `gradle|…` 与 `maven|…` ⇒ 公告永不落行。
        let gradle = rec("junit:junit", "4.13.2", ecosystem: .gradle, manifest: "build.gradle")
        let gradleQuery = OsvPackageQuery.query(from: gradle)
        XCTAssertEqual(gradleQuery?.query.ecosystem, "Maven", "OSV 那边 gradle 走 Maven 这张表")
        XCTAssertEqual(gradleQuery?.coordinate, "maven|junit:junit|4.13.2")
        XCTAssertEqual(DependencyVersionIdentity.of(gradle).queryCoordinate, gradleQuery?.coordinate,
                       "gradle 记录的查询/回填 key 必须同源（否则在线公告回不到依赖行）")
        XCTAssertNotEqual(DependencyVersionIdentity.of(gradle).queryCoordinate,
                          DependencyVersionIdentity.coordinate(ecosystem: .gradle, name: "junit:junit",
                                                              queryVersion: "4.13.2"),
                          "回填侧不许退回声明生态")

        // 正例③：锁文件解析值优先 —— 查询用的是装的那个版本。
        let locked = rec("left-pad", "^1.2.3", ecosystem: .npm, manifest: "package.json", resolved: "1.2.9")
        XCTAssertEqual(OsvPackageQuery.query(from: locked)?.coordinate, "npm|left-pad|1.2.9")

        // 反例①：OSV 不收的生态一条查询都不发，逐条状态落「生态不支持」（不是"查过、干净"）。
        let swpm = rec("swift-log", "1.5.0", ecosystem: .swiftPM, manifest: "Package.swift")
        XCTAssertNil(OsvPackageQuery.query(from: swpm), "OSV 不收 SwiftPM ⇒ 没有查询身份")
        XCTAssertEqual(DependencyEvidence.vulnerabilityState(of: swpm), .ecosystemUnsupported)

        // 反例②：版本没解析出来 ⇒ 两侧都没有坐标，也就永远不会被错标成"已核对"。
        let wildcard = rec("anything", "*", ecosystem: .npm, manifest: "package.json")
        XCTAssertNil(OsvPackageQuery.query(from: wildcard))
        XCTAssertNil(DependencyVersionIdentity.of(wildcard).queryCoordinate)
        XCTAssertEqual(DependencyEvidence.vulnerabilityState(of: wildcard), .versionUnresolved)
    }

    /// 端到端：gradle 记录的**在线**公告必须能回落到依赖行上（上一条的机制面证明）。
    ///
    /// 故意选一个内置表没有的包 ⇒ 行上那个 CVE 只可能来自在线回填，
    /// 不会被"内置规则本来就命中"混掉（用 fastjson 就测不出这条链）。
    func testGradleRecordReceivesOnlineAdvisoryOnTheRow() async throws {
        let root = try makeTree("single-ruler-gradle", files: [
            "build.gradle": "dependencies {\n  implementation 'com.acme:widget:1.0.0'\n}\n",
        ])
        let coordinate = OsvPackageQuery.query(from: DependencyRecord(
            name: "com.acme:widget", version: "1.0.0", ecosystem: .gradle, scope: .runtime,
            manifestPath: "build.gradle", latestKnownVersion: nil, versionCheckSource: .none,
            knownVulnerabilities: []
        ))?.coordinate
        XCTAssertEqual(coordinate, "maven|com.acme:widget|1.0.0", "真值：gradle 走 Maven 那张表")
        let stub = StubOnlineSource(answered: [try XCTUnwrap(coordinate): [
            stubAdvisory(id: "GHSA-widget", coordinate: try XCTUnwrap(coordinate),
                         aliases: ["CVE-2099-0100"]),
        ]])
        let report = try await ManifestDependencyAnalyzer(options: .default, maxDepth: 3, onlineSource: stub)
            .analyze(projectRoot: root, allowNetwork: true)
        XCTAssertTrue(report.advisories.contains { $0.id == "GHSA-widget" }, "前提：总览确实带回了公告")
        let row = try XCTUnwrap(report.ecosystems.flatMap(\.dependencies).first { $0.name.contains("widget") })
        XCTAssertEqual(row.knownVulnerabilities, ["CVE-2099-0100"],
                       "总览有公告而 gradle 行没标记 = RD-12 的另一张脸，实得 \(row.knownVulnerabilities)")
        XCTAssertEqual(DependencyRowStatus.of(row), .vulnerable(count: 1))
    }

    // MARK: - 4. 第二把尺子的形状不许回来（扫描守卫 + 反向元测试）

    /// 在依赖域里，**在自己的文件里按 `.` 切版本号**就是第二把尺子的定义性动作
    /// （白名单之外任何一处都得重新解释一遍 `^1.2.3` / `-beta` / `+build`）。
    /// 白名单只有两处：`DependencySemver.swift`（那把尺子本身）与
    /// `Models/DependencyReport.swift` 里 `DependencyVersion` 的入口（只剥前缀，比较仍转交）。
    static let rulerWhitelist: Set<String> = ["DependencySemver.swift", "DependencyReport.swift"]
    static let rulerNeedles = ["split(separator: \".\")", "prefix(while:"]

    /// 纯函数：喂文件清单，返回"第二把尺子"的落点。剥行首注释 —— 注释里的 needle 不算。
    static func secondRulerFindings(in files: [(path: String, text: String)]) -> [String] {
        files.compactMap { file in
            guard isDependencyDomain(file.path) else { return nil }   // 守卫只管依赖链，越界就是误伤
            let name = (file.path as NSString).lastPathComponent
            guard !rulerWhitelist.contains(name) else { return nil }
            let hit = file.text.split(separator: "\n").contains { rawLine in
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.hasPrefix("//") else { return false }
                return rulerNeedles.contains(where: { line.contains($0) })
            }
            return hit ? file.path : nil
        }
    }

    /// 真树上必须 0 命中，且**分母 > 0**（扫不到文件 = 永真绿守卫）。
    func testNoSecondVersionParserInDependencyDomain() throws {
        let files = try dependencyDomainSources()
        XCTAssertGreaterThan(files.count, 15, "扫描面小到这个程度说明扫描坏了，不是代码干净")
        let findings = Self.secondRulerFindings(in: files)
        XCTAssertTrue(findings.isEmpty, "出现第二把版本尺子：\(findings)")
        // 白名单本身必须在场，否则"0 命中"可能只是因为那把尺子被改名/挪走了。
        XCTAssertTrue(files.contains { Self.rulerWhitelist.contains(($0.path as NSString).lastPathComponent) },
                      "唯一那把尺子不在扫描面里，这条守卫已经失去意义")
    }

    /// 元测试①：坏样例必须被抓到（证明上一条不是永真绿）。
    func testGuardCatchesAnInjectedSecondParser() {
        let bad = [(path: "Sources/TcoderMonitor/Services/Dependencies/NewVersionThing.swift",
                    text: "let parts = raw.split(separator: \".\")")]
        XCTAssertEqual(Self.secondRulerFindings(in: bad),
                       ["Sources/TcoderMonitor/Services/Dependencies/NewVersionThing.swift"])
        let alsoBad = [(path: "Sources/TcoderMonitor/Services/Dependencies/Other.swift",
                        text: "let core = text.prefix(while: { $0 != \"-\" })")]
        XCTAssertEqual(Self.secondRulerFindings(in: alsoBad).count, 1)
    }

    /// 元测试②：合法形状不误伤（白名单文件、注释里的字样、依赖域外的切点）。
    func testGuardIgnoresLegalShapes() {
        let inDomain = [
            (path: "Sources/TcoderMonitor/Services/Dependencies/DependencySemver.swift",
             text: "let parts = core.split(separator: \".\")"),
            (path: "Sources/TcoderMonitor/Models/DependencyReport.swift",
             text: "text.split(separator: \".\")"),
            (path: "Sources/TcoderMonitor/Services/Dependencies/ManifestParsers.swift",
             text: "// 这里以前写作 text.prefix(while: …)，现在不了。\nlet x = 1"),
        ]
        XCTAssertTrue(Self.secondRulerFindings(in: inDomain).isEmpty, "合法形状被误伤")
        // 域外（不在扫描面里）的东西扫不到是**设计**：这条守卫管的是依赖链，不是全仓。
        let outOfDomain = [(path: "Sources/TcoderMonitor/Utilities/SharedUtilities.swift",
                            text: "name.split(separator: \".\")")]
        XCTAssertFalse(Self.dependencyDomainPaths().isEmpty, "扫描面配置坏了：一个目录都没配")
        XCTAssertEqual(Self.secondRulerFindings(in: outOfDomain), [],
                       "守卫越界去管依赖域外的同形代码（那是包名不是版本号）")
    }

    /// 管辖区：`Sources/TcoderMonitor/Services/Dependencies/**` 加契约里那份 `DependencyReport.swift`。
    /// 域外的 `split(separator: ".")` 大多数是在切**包名 / 模块名**，不是版本号，管了就是误伤。
    static func isDependencyDomain(_ path: String) -> Bool {
        path.contains("/Services/Dependencies/") || path.hasSuffix("/Models/DependencyReport.swift")
    }

    static func dependencyDomainPaths() -> [String] {
        ["TcoderMonitor/Services/Dependencies", "TcoderMonitor/Models"]
    }

    /// 扫描面：`Sources/TcoderMonitor/Services/Dependencies/**` + `Models/DependencyReport.swift`。
    private func dependencyDomainSources() throws -> [(path: String, text: String)] {
        let root = packageRoot().appendingPathComponent("Sources", isDirectory: true)
        let manager = FileManager.default
        var files: [(String, String)] = []
        for relative in Self.dependencyDomainPaths() {
            let directory = root.appendingPathComponent(relative, isDirectory: true)
            let contents = try manager.contentsOfDirectory(atPath: directory.path).sorted()
            for name in contents where name.hasSuffix(".swift") {
                // Models 目录只收 `DependencyReport.swift`：其余契约文件不属于这条尺子的管辖区。
                if relative.hasSuffix("Models"), name != "DependencyReport.swift" { continue }
                let path = directory.appendingPathComponent(name).path
                guard let data = manager.contents(atPath: path), let text = String(data: data, encoding: .utf8)
                else { continue }
                files.append((path: path, text: text))
            }
        }
        return files
    }

    /// 包根回溯：本文件 → TcoderMonitorTests → Tests → **TcoderMonitor（包根）**。
    /// 与 `SourceFileReachabilityTests.repoRoot` 同一套写法 —— 测试进程的 CWD 不是包根，
    /// 按相对路径扫会"静默扫不到东西、然后判通过"。
    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DependencySingleRulerTests.swift
            .deletingLastPathComponent()   // TcoderMonitorTests
            .deletingLastPathComponent()   // Tests            ⇒ 再往上就是包根
    }

    // MARK: - 夹具

    private func makeTree(_ tag: String, files: [String: String]) throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tcoder-r3-ruler-\(tag)-\(UUID().uuidString.prefix(8))", isDirectory: true)
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
}
