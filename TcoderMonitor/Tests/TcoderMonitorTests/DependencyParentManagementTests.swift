// OWNER: R3 依赖证据链 · 父 POM / 导入 BOM 三态（RD-13b）
//
// 整改意见的原句有两半："父 POM / 导入 BOM 未解析不得解释成'项目没管理版本'；要能读已有
// 的 effective-POM / 依赖树 / SBOM；不得要求被扫项目为消提示手工补版本。"
// 本文件按这三句各配一组用例（正例/反例/未知态/失败态都在表里）。
// 真值全部来自本文件内联的 pom / 产物文本 —— **没有读本机任何其它工程**。
import XCTest
@testable import TcoderMonitor

final class DependencyParentManagementTests: XCTestCase {

    // MARK: - 夹具：手写 pom 与已解析产物

    /// 子模块 pom：声明一条依赖但**不写版本**，版本由父级决定。
    private static let childPom = """
    <project>
      <parent>
        <groupId>com.acme</groupId><artifactId>acme-parent</artifactId><version>2.7.0</version>
      </parent>
      <artifactId>orders-service</artifactId>
      <dependencies>
        <dependency><groupId>com.acme</groupId><artifactId>acme-shared</artifactId></dependency>
      </dependencies>
    </project>
    """

    /// 没有父级、也没有 dependencyManagement，同样不写版本 ⇒ 这才是"项目确实没定版本"。
    private static let orphanPom = """
    <project>
      <groupId>com.acme</groupId><artifactId>loose</artifactId><version>1.0.0</version>
      <dependencies>
        <dependency><groupId>com.acme</groupId><artifactId>mystery</artifactId></dependency>
      </dependencies>
    </project>
    """

    /// 导入型 BOM（`<type>pom</type>` + `<scope>import</scope>`）：版本在 BOM 里。
    private static let bomImportPom = """
    <project>
      <groupId>com.acme</groupId><artifactId>bom-user</artifactId><version>1.0.0</version>
      <dependencyManagement><dependencies>
        <dependency>
          <groupId>org.springframework.boot</groupId><artifactId>spring-boot-dependencies</artifactId>
          <version>3.2.0</version><type>pom</type><scope>import</scope>
        </dependency>
      </dependencies></dependencyManagement>
      <dependencies>
        <dependency><groupId>com.zaxxer</groupId><artifactId>HikariCP</artifactId></dependency>
      </dependencies>
    </project>
    """

    /// 属性代不出来（`${revision}` 由 flatten-plugin 在构建期注入，仓里读不到）。
    private static let unresolvablePom = """
    <project>
      <groupId>com.acme</groupId><artifactId>revisioned</artifactId><version>${revision}</version>
      <dependencies>
        <dependency><groupId>com.acme</groupId><artifactId>needs-rev</artifactId>
          <version>${revision}</version></dependency>
      </dependencies>
    </project>
    """

    /// effective-POM：同一个 childPom 跑完 `mvn help:effective-pom` 之后的样子（版本已全部代入）。
    private static let effectivePom = """
    <project>
      <groupId>com.acme</groupId><artifactId>orders-service</artifactId><version>2.7.0</version>
      <dependencies>
        <dependency><groupId>com.acme</groupId><artifactId>acme-shared</artifactId>
          <version>1.4.2</version><scope>compile</scope></dependency>
      </dependencies>
    </project>
    """

    private static let dependencyTree = """
    [INFO] Scanning for projects...
    [INFO] com.acme:orders-service:jar:2.7.0
    [INFO] +- com.acme:acme-shared:jar:1.4.2:compile
    [INFO] |  \\- org.slf4j:slf4j-api:jar:2.0.9:compile
    [INFO] \\- junit:junit:jar:4.13.2:test
    """

    private static let cycloneDX = """
    {"bomFormat":"CycloneDX","specVersion":"1.5","components":[
      {"type":"library","name":"acme-shared","group":"com.acme","version":"1.4.2",
       "purl":"pkg:maven/com.acme/acme-shared@1.4.2"},
      {"type":"library","name":"lodash","version":"4.17.21","purl":"pkg:npm/lodash@4.17.21"}
    ]}
    """

    private static let spdx = """
    {"spdxVersion":"SPDX-2.3","name":"orders-sbom","packages":[
      {"name":"acme-shared","versionInfo":"1.4.2",
       "externalRefs":[{"referenceType":"purl","referenceLocator":"pkg:maven/com.acme/acme-shared@1.4.2"}]},
      {"name":"no-version-here"}
    ]}
    """

    // MARK: - ① 三态本身：未显式声明 / 由父级管理但未解析 / 确实无法确定

    func testThreeDeclarationStatesAreToldApart() async throws {
        let root = try makeTree("parent-states", files: [
            "service/pom.xml": Self.childPom,
            "loose/pom.xml": Self.orphanPom,
            "bom-user/pom.xml": Self.bomImportPom,
            "revisioned/pom.xml": Self.unresolvablePom,
        ])
        let report = try await analyze(root)
        let records = report.ecosystems.flatMap(\.dependencies)
        XCTAssertEqual(records.count, 4, "四份清单各一条依赖")

        func state(_ manifest: String) throws -> DependencyDeclaredVersionState? {
            try XCTUnwrap(records.first { $0.manifestPath == manifest }).declaredVersionState
        }
        func version(_ manifest: String) throws -> String {
            try XCTUnwrap(records.first { $0.manifestPath == manifest }).version
        }

        XCTAssertEqual(try state("service/pom.xml"), .managedByParent,
                       "有父级 ⇒ 不许说成「项目没管理版本」")
        XCTAssertEqual(try state("bom-user/pom.xml"), .managedByParent, "导入 BOM 与父级同义")
        XCTAssertEqual(try state("loose/pom.xml"), .notDeclared, "既无父级也无 BOM ⇒ 确实没写")
        XCTAssertEqual(try state("revisioned/pom.xml"), .undeterminable,
                       "写了占位 ≠ 没写：这一条的失败原因与前两者不同")
        // 代不出来的占位**原文保留**（可追溯），但它绝不参与比较、也进不了查询批次：
        // 旧实现同样保留原文，区别是以前它会一路被当成一个"版本号"去比 —— 那是假结论。
        XCTAssertEqual(try version("revisioned/pom.xml"), #"${revision}"#)

        let revisioned = try XCTUnwrap(records.first { $0.manifestPath == "revisioned/pom.xml" })
        XCTAssertFalse(revisioned.isProbablyOutdated, "占位串不许参与新旧比较")
        XCTAssertNil(OsvPackageQuery.query(from: revisioned), "占位串没资格进查询批次")
        XCTAssertNil(revisioned.dependencyCoordinate)

        // 三态在**行状态与 tooltip** 上必须是三句话，而不是一句"未声明"。
        for manifest in ["service/pom.xml", "bom-user/pom.xml", "loose/pom.xml", "revisioned/pom.xml"] {
            let record = try XCTUnwrap(records.first { $0.manifestPath == manifest })
            XCTAssertEqual(DependencyRowStatus.of(record), .versionUnresolved, manifest)
            let tooltip = DependencyRowStatus.versionUnresolved.tooltip(record: record)
            XCTAssertTrue(tooltip.contains(DependencyEvidence.declarationExplain(for: record)), manifest)
        }
        let parentTooltip = DependencyRowStatus.versionUnresolved.tooltip(
            record: try XCTUnwrap(records.first { $0.manifestPath == "service/pom.xml" }))
        XCTAssertTrue(parentTooltip.contains("父 POM"), parentTooltip)
        XCTAssertFalse(parentTooltip.contains("确实没写"), "父级管理不许读成没写版本：" + parentTooltip)
        let orphanTooltip = DependencyRowStatus.versionUnresolved.tooltip(
            record: try XCTUnwrap(records.first { $0.manifestPath == "loose/pom.xml" }))
        XCTAssertTrue(orphanTooltip.contains("确实没给它定版本"), orphanTooltip)
    }

    /// 本仓已有的 Maven 行为不许退化：本地 `dependencyManagement` 能代入 ⇒ `.explicit`。
    func testLocallyManagedVersionStaysExplicit() async throws {
        let root = try makeTree("parent-local-managed", files: [
            "pom.xml": """
            <project>
              <groupId>com.acme</groupId><artifactId>root</artifactId><version>1.0.0</version>
              <dependencyManagement><dependencies>
                <dependency><groupId>com.acme</groupId><artifactId>shared</artifactId>
                  <version>1.4.2</version></dependency>
              </dependencies></dependencyManagement>
              <dependencies>
                <dependency><groupId>com.acme</groupId><artifactId>shared</artifactId></dependency>
              </dependencies>
            </project>
            """,
        ])
        let parsed = try await analyze(root)
        let record = try XCTUnwrap(parsed.ecosystems.flatMap(\.dependencies).first)
        XCTAssertEqual(record.version, "1.4.2", "本份 pom 自己能代出来的必须代出来（旧行为保留）")
        XCTAssertEqual(record.declaredVersionState, .explicit)
    }

    // MARK: - ② 能读已有的已解析产物

    func testEffectivePomResolvesTheParentManagedVersion() async throws {
        let root = try makeTree("parent-effective", files: [
            "pom.xml": Self.childPom,
            "effective-pom.xml": Self.effectivePom,
        ])
        let analyzer = ManifestDependencyAnalyzer(options: .default, maxDepth: 3)
        let report = try await analyzer.analyze(projectRoot: root, allowNetwork: false)
        let record = try XCTUnwrap(report.ecosystems.flatMap(\.dependencies).first)

        XCTAssertEqual(record.resolvedVersion, "1.4.2", "effective-POM 里代入好的版本要读出来")
        XCTAssertEqual(record.resolvedVersionSource, "effective-pom.xml", "结论必须能追到是哪份文件给的")
        XCTAssertEqual(record.declaredVersionState, .explicit,
                       "量到安装版本之后，「由父级管理但未解析」这一格必须翻篇")
        XCTAssertTrue(report.networkLookupNote.contains("已解析产物"), report.networkLookupNote)
        XCTAssertTrue(report.networkLookupNote.contains("effective-pom.xml"), report.networkLookupNote)
    }

    func testDependencyTreeResolvesVersions() async throws {
        let root = try makeTree("parent-tree", files: [
            "pom.xml": Self.childPom,
            "dependency-tree.txt": Self.dependencyTree,
        ])
        let report = try await analyze(root)
        let record = try XCTUnwrap(report.ecosystems.flatMap(\.dependencies).first)
        XCTAssertEqual(record.resolvedVersion, "1.4.2")
        XCTAssertEqual(record.resolvedVersionSource, "dependency-tree.txt")
    }

    func testSbomFamiliesResolveVersionsAndIgnorNonMaven() async throws {
        let cdx = try makeTree("parent-cdx", files: [
            "pom.xml": Self.childPom, "bom.json": Self.cycloneDX,
        ])
        let cdxReport = try await analyze(cdx)
        let cdxRecord = try XCTUnwrap(cdxReport.ecosystems.flatMap(\.dependencies).first)
        XCTAssertEqual(cdxRecord.resolvedVersion, "1.4.2", "CycloneDX 的 purl 必须还原成 group:artifact")
        XCTAssertEqual(cdxRecord.resolvedVersionSource, "bom.json")

        let spdxTree = try makeTree("parent-spdx", files: [
            "pom.xml": Self.childPom, "spdx.json": Self.spdx,
        ])
        let spdxReport = try await analyze(spdxTree)
        let spdxRecord = try XCTUnwrap(spdxReport.ecosystems.flatMap(\.dependencies).first)
        XCTAssertEqual(spdxRecord.resolvedVersion, "1.4.2", "SPDX 走 versionInfo + externalRefs")
        XCTAssertEqual(spdxRecord.resolvedVersionSource, "spdx.json")
    }

    /// 失败态：产物**互相矛盾**时不猜（同名多版本一律不回填），也不许编一个"看起来对的"。
    func testContradictoryArtifactDoesNotGuessAVersion() async throws {
        let root = try makeTree("parent-ambiguous", files: [
            "pom.xml": Self.childPom,
            "dependency-tree.txt": """
            [INFO] +- com.acme:acme-shared:jar:1.4.2:compile
            [INFO] +- com.acme:acme-shared:jar:1.5.0:runtime
            """,
        ])
        let report = try await analyze(root)
        let record = try XCTUnwrap(report.ecosystems.flatMap(\.dependencies).first)
        XCTAssertNil(record.resolvedVersion, "两份版本互斥 ⇒ 不回填（猜一个就是把假数据写进报告）")
        XCTAssertEqual(record.declaredVersionState, .managedByParent, "仍然停在「未解析」那一格")
        let resolution = try XCTUnwrap(
            DependencyLockParser.parseResolvedArtifact(fileName: "dependency-tree.txt",
                                                       text: """
                                                       [INFO] +- com.acme:acme-shared:jar:1.4.2:compile
                                                       [INFO] +- com.acme:acme-shared:jar:1.5.0:runtime
                                                       """,
                                                       relativePath: "dependency-tree.txt"))
        XCTAssertEqual(resolution.ambiguousNames, ["com.acme:acme-shared"])
        XCTAssertTrue(resolution.originIsResolvedArtifact)
    }

    /// 反例：垃圾/不认识的 JSON 不许被当成"解析出 0 个版本 = 这个项目没有依赖"。
    func testUnreadableArtifactLeavesNoTraceInsteadOfAFakeZero() async throws {
        let root = try makeTree("parent-junk", files: [
            "pom.xml": Self.childPom,
            "bom.json": "{\"whatever\":true}",
        ])
        let report = try await analyze(root)
        let record = try XCTUnwrap(report.ecosystems.flatMap(\.dependencies).first)
        XCTAssertNil(record.resolvedVersion)
        XCTAssertEqual(record.declaredVersionState, .managedByParent)
        // 解析不出东西的文件不许进"读到已解析产物 N 份"那句（否则披露的是假成功）。
        XCTAssertFalse(report.networkLookupNote.contains("已解析产物"), report.networkLookupNote)
    }

    // MARK: - ③ 不得要求被扫项目为消提示手工补版本

    /// 依赖链所有**面向用户**的句子里，不许出现"你去补个版本号"这类建议（X5 建议与对象不符）。
    func testNoUserFacingTextAsksTheProjectToAddVersions() throws {
        let texts = sampledUserFacingTexts()
        XCTAssertGreaterThanOrEqual(texts.count, 12, "采样面太小 ⇒ 这条守卫管不到东西")
        for text in texts {
            for needle in Self.manualVersionNeedles {
                XCTAssertFalse(text.contains(needle), "文案在要求被扫项目手工补版本（\(needle)）：\(text)")
            }
        }
    }

    static let manualVersionNeedles = [
        "补上版本号", "请填写版本", "请声明版本", "手工写死版本", "补一个版本", "请补 version",
    ]

    /// 元测试： needles 表真的有牙 —— 造一句坏文案必须被自己的判据抓到。
    func testManualVersionGuardCatchesInjectedAdvice() {
        let bad = "这些依赖没有版本，请在 pom.xml 里补上版本号以消除本提示。"
        XCTAssertTrue(Self.manualVersionNeedles.contains { bad.contains($0) }, "判据抓不到坏样例")
        let legal = "版本由父 POM / 导入 BOM 管理，本轮未解析。不要求你为了消提示去手工补版本号。"
        XCTAssertFalse(Self.manualVersionNeedles.contains { legal.contains($0) },
                       "把「不许这样修」写进文案，反而会被自己的守卫打死：\(legal)")
    }

    // MARK: - 辅助

    /// 采样面：三态各一 + 每种行状态的 tooltip + 离线说明 + 分 scope 行 + 评分建议。
    private func sampledUserFacingTexts() -> [String] {
        var texts: [String] = []
        for record in sampleRecords() {
            texts.append(DependencyRowStatus.of(record).tooltip(record: record))
            texts.append(DependencyEvidence.declarationExplain(for: record))
            texts.append(DependencyEvidence.versionState(of: record).rawValue)
        }
        let report = DependencyReport(ecosystems: [EcosystemReport(
            ecosystem: .maven, manifestPath: "pom.xml", lockfileName: nil,
            dependencies: sampleRecords(), frameworkMarkers: [])])
        texts.append(ManifestDependencyAnalyzer.offlineCaveat(for: report))
        texts.append(contentsOf: DependencyScopeLines.lines(report))
        let ledger = DependencyEvidence.ledger(for: report)
        texts.append(DependencyEvidence.findingsStatement(for: report, ledger: ledger))
        texts.append(DependencyEvidence.declarationPhrases(ledger).joined(separator: "、"))
        texts.append(DependencySafetyVerdict(report, ledger: ledger).summaryCaption)
        texts.append(VulnerabilityEvidence.degradationReasons(report).joined(separator: "、"))
        return texts
    }

    private func sampleRecords() -> [DependencyRecord] {
        var plain = DependencyRecord(name: "com.acme:plain", version: "1.0.0", ecosystem: .maven,
                                     scope: .runtime, manifestPath: "pom.xml", latestKnownVersion: "2.0.0",
                                     versionCheckSource: .bundledSnapshot, knownVulnerabilities: [])
        plain.declaredVersionState = .explicit
        var parentManaged = DependencyRecord(name: "com.acme:shared", version: "未声明", ecosystem: .maven,
                                            scope: .runtime, manifestPath: "service/pom.xml",
                                            latestKnownVersion: nil, versionCheckSource: .none,
                                            knownVulnerabilities: [])
        parentManaged.declaredVersionState = .managedByParent
        var orphan = DependencyRecord(name: "com.acme:mystery", version: "未声明", ecosystem: .maven,
                                      scope: .runtime, manifestPath: "loose/pom.xml",
                                      latestKnownVersion: nil, versionCheckSource: .none,
                                      knownVulnerabilities: [])
        orphan.declaredVersionState = .notDeclared
        var undeterminable = DependencyRecord(name: "com.acme:needs-rev", version: "未声明",
                                             ecosystem: .maven, scope: .runtime,
                                             manifestPath: "revisioned/pom.xml", latestKnownVersion: nil,
                                             versionCheckSource: .none, knownVulnerabilities: [])
        undeterminable.declaredVersionState = .undeterminable
        return [plain, parentManaged, orphan, undeterminable]
    }

    private func analyze(_ root: URL) async throws -> DependencyReport {
        try await ManifestDependencyAnalyzer(options: .default, maxDepth: 3)
            .analyze(projectRoot: root, allowNetwork: false)
    }

    private func makeTree(_ tag: String, files: [String: String]) throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tcoder-r3-parent-\(tag)-\(UUID().uuidString.prefix(8))", isDirectory: true)
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
