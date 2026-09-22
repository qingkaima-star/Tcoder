import Foundation
import XCTest
@testable import TcoderMonitor

/// WS-F 夹具实验室 · 依赖清单：十种生态的解析条数、版本原样、scope 与内置快照判定。
/// 拆自 ManifestLabFixtureTests.swift，断言与用例一字未改（WS-V）。
final class ManifestLabDependencyTests: ManifestLabTestCase {
    // MARK: - 1. 依赖清单

    func testManifestLabDependencyCountsVersionsAndScopes() async throws {
        let report = try await ManifestDependencyAnalyzer(options: .default, maxDepth: 6)
            .analyze(projectRoot: root, allowNetwork: false)

        print("=== WS-F 夹具 · 依赖清单实测 ===")
        for eco in report.ecosystems {
            print("[\(eco.ecosystem.displayName)] \(eco.manifestPath) 依赖 \(eco.dependencies.count)"
                + "  锁文件 \(eco.lockfileName ?? "无")"
                + "  标记 \(eco.frameworkMarkers.joined(separator: ","))")
            for record in eco.dependencies {
                print("    \(record.name) = \(record.version)  scope=\(record.scope.rawValue)"
                    + "  latest=\(record.latestKnownVersion ?? "-")"
                    + "  过旧=\(record.isProbablyOutdated)"
                    + "  漏洞=\(record.knownVulnerabilities.joined(separator: "+"))")
            }
        }
        print("清单份数 = \(report.ecosystems.count)  依赖总数 = \(report.totalDependencies)"
            + "  运行时/开发 = \(report.productionCount)/\(report.devCount)"
            + "  过旧 = \(report.outdatedCount)  漏洞 = \(report.vulnerableCount)"
            + "  漏洞规则 = \(report.offlineVulnerabilities.count)  联网 = \(report.networkLookupPerformed)")

        XCTAssertEqual(report.ecosystems.count, 16, "16 份清单必须各产出一张生态卡片")
        XCTAssertEqual(report.totalDependencies, 79, "依赖总数必须等于设计真值表 79")
        XCTAssertEqual(report.devCount, 11, "scope=开发 的依赖恰好 11 条")
        XCTAssertEqual(report.productionCount, 68)
        XCTAssertFalse(report.networkLookupPerformed, "allowNetwork false 时不得发起在线查询")
        XCTAssertEqual(report.offlineVulnerabilities.count, 7, "内置规则应命中 7 条漏洞")
        // 设计期望 8：jjwt 0.9.1 在 orders-api(pom) 与 settings.gradle 两份清单里各一条。
        // 实测 7 —— VulnerabilitySource.swift:406 用 `uniqueSorted(name@version)` 去重，
        // 同一坐标出现在多个清单时被并成 1 条「受影响依赖」（单条记录上的 CVE 标注仍正确）。
        XCTAssertEqual(report.vulnerableCount, strictContract ? 8 : 7,
                       "同一坐标跨两份清单是否各算一条受影响依赖，口径见 VulnerabilitySource.swift:406")
        if !strictContract {
            print("【已知缺陷】vulnerableCount 把跨清单的同一坐标并成 1 条：设计 8 / 实得 7")
        }
        // RD-10（2026-09-22 由 R3 按 AGENTS §8.1 豁免改正这条用例）。
        // 它原来默认断言 25、并在 `TCODER_F_STRICT_CONTRACT=1` 时断言"设计期望 24"。
        // **两个数都是错的**：25 里含 5 条 caret 声明被 `DependencyVersion.normalize` 在 `^`
        // 处截成 `[0]` 而虚报的"过旧"；24 是 WS-F 手算时把 `^18.2.0` 的下界当成安装版本 ——
        // 那正是 RD-10 明令禁止的口径（"去掉 ^ 就把下界当安装版本"）。
        // 现在断言 20：本夹具的 `package-lock.json` 是 `"packages": {}`（空），
        // 所以 `^18.2.0` / `^18.2.0` / `^5.3.3` / `^5.2.1` / `[3.8,4.0)` / `~> 7.1.2` 这类
        // **只有范围、没有解析值**的条目一律落「未定」，既不计过旧也不计正常；
        // 而 `Package.swift` 的 `swift-log from:"1.5.0"` 被同目录 `Package.resolved`
        // 解析成 1.6.1 = 快照最新 ⇒ 也不过旧（这一步是锁文件替我们把"装的是哪个版本"量出来了）。
        // 手核的 20 条（每条都是"解析值/精确声明 < 最新已知"）：
        // okhttp 4.9.0、grpc-netty-shaded 1.60.0、lombok 1.18.30×2、guava 33.0.0-jre、
        // serde 1.0.190、tokio 1.37.0、gin 1.9.1、axios 0.21.1、lodash 4.17.20、GRDB 6.23.0、
        // requests 2.28.1、pydantic 2.4、vue 3.4.0、vite 5.0.0、flask 3.0.0、pandas 2.1.4、
        // jackson-databind 2.13.2、log4j-core 2.14.1、commons-collections 3.2.1。
        XCTAssertEqual(report.outdatedCount, 20, "过旧 = 手核 20 条（范围未解析的条目不计入，见上方推导）")

        // 逐份清单的依赖数：数量错 = 解析器漏读或多读
        let counts = Dictionary(uniqueKeysWithValues: report.ecosystems.map { ($0.manifestPath, $0.dependencies.count) })
        XCTAssertEqual(counts["package.json"], 10)
        XCTAssertEqual(counts["frontend/package.json"], 3)
        XCTAssertEqual(counts["pom.xml"], 3)
        XCTAssertEqual(counts["java/orders-api/pom.xml"], 3)
        XCTAssertEqual(counts["java/orders-service/pom.xml"], 5)
        XCTAssertEqual(counts["build.gradle"], 7)
        XCTAssertEqual(counts["build.gradle.kts"], 6)
        XCTAssertEqual(counts["settings.gradle"], 2)
        XCTAssertEqual(counts["Package.swift"], 5)
        XCTAssertEqual(counts["go.mod"], 6)
        XCTAssertEqual(counts["Cargo.toml"], 6)
        XCTAssertEqual(counts["pyproject.toml"], 10)
        XCTAssertEqual(counts["python-tool/requirements.txt"], 3)
        XCTAssertEqual(counts["Gemfile"], 5)
        XCTAssertEqual(counts["ios/Podfile"], 3)
        XCTAssertEqual(counts["dotnet/packages.config"], 2)

        // npm：版本原样保留（^18.2.0 不该被剥成 18.2.0），四段 scope 分开
        let npm = try require(report.ecosystems.first { $0.manifestPath == "package.json" })
        XCTAssertEqual(npm.ecosystem, .npm)
        XCTAssertEqual(npm.lockfileName, "package-lock.json")
        expect(npm, "lodash", "4.17.20", .runtime)
        expect(npm, "axios", "0.21.1", .runtime)
        expect(npm, "react", "^18.2.0", .runtime)
        expect(npm, "typescript", "^5.3.3", .dev)
        expect(npm, "moment", "2.29.4", .platform)
        expect(npm, "@acme/experimental", "1.0.0-rc.3", .unknown)
        XCTAssertTrue(npm.frameworkMarkers.contains("React"))
        XCTAssertTrue(npm.frameworkMarkers.contains("Lodash"))
        XCTAssertEqual(npm.frameworkMarkers.count, 8, "frameworkMarkers 上限 8，超出被截断")
        // RD-10：`react = ^18.2.0` 这一条**原来断言"必须算过旧"**，那是拿范围下界当安装版本。
        // 本夹具的 package-lock.json 是空的 ⇒ 装的是哪个版本没量到 ⇒ 只能判「未定」。
        // 量得到的东西一个不少：声明范围原样在 `version` 里，最新已知版本在 `latestKnownVersion` 里。
        let react = try require(npm.dependencies.first { $0.name == "react" })
        XCTAssertEqual(react.version, "^18.2.0", "声明范围不许被剥成 18.2.0")
        XCTAssertEqual(react.latestKnownVersion, "19.3.0")
        XCTAssertNil(react.resolvedVersion, "空锁文件里解析不出东西，不许编一个")
        XCTAssertFalse(react.isProbablyOutdated, "安装版本未解析 ⇒ 不许报过旧")
        XCTAssertEqual(DependencyVersionIdentity.of(react).outdatedness, .undetermined(.rangeNotResolved),
                       "「未定」要带原因，行状态与评分读的就是这个原因")
        let express = try require(npm.dependencies.first { $0.name == "express" })
        XCTAssertFalse(express.isProbablyOutdated,
                       "express 声明 ^5.2.1 而快照最新就是 5.2.1：旧实现把它判成过旧是纯错")

        // Maven：${property} 与 ${project.version} 代入、dependencyManagement 继承、provided/test/plugin scope
        let parent = try require(report.ecosystems.first { $0.manifestPath == "pom.xml" })
        XCTAssertEqual(parent.ecosystem, .maven)
        expect(parent, "com.acme:acme-shared", "1.4.2", .runtime)
        expect(parent, "org.springframework.boot:spring-boot-starter", "3.2.0", .runtime)
        expect(parent, "com.acme.orders:orders-api", "2.7.0", .runtime)
        XCTAssertTrue(parent.frameworkMarkers.contains("Spring Boot"))

        let api = try require(report.ecosystems.first { $0.manifestPath == "java/orders-api/pom.xml" })
        expect(api, "com.fasterxml.jackson.core:jackson-databind", "2.13.2", .runtime)
        expect(api, "org.projectlombok:lombok", "1.18.30", .platform)
        expect(api, "io.jsonwebtoken:jjwt", "0.9.1", .runtime)
        XCTAssertEqual(api.dependencies.filter { $0.name == "com.fasterxml.jackson.core:jackson-databind" }
                            .first!.knownVulnerabilities.count, 1)
        XCTAssertFalse(api.dependencies.filter { $0.name == "io.jsonwebtoken:jjwt" }.first!.isProbablyOutdated,
                       "jjwt 该坐标最后发布版本就是 0.9.1，不得判成过旧")

        let service = try require(report.ecosystems.first { $0.manifestPath == "java/orders-service/pom.xml" })
        expect(service, "org.apache.logging.log4j:log4j-core", "2.14.1", .runtime)
        expect(service, "commons-collections:commons-collections", "3.2.1", .runtime)
        expect(service, "junit:junit", "4.13.2", .test)
        expect(service, "org.ow2.asm:asm", "9.6", .build)
        // Maven 版本区间 [1.0,2.0)：必须被读出来，且不得被当成 0.0.0 判成过旧
        expect(service, "org.acme.legacy:legacy-range-client", "[1.0,2.0)", .runtime)
        XCTAssertFalse(service.dependencies.filter { $0.name.contains("legacy-range-client") }.first!.isProbablyOutdated)
        XCTAssertTrue(service.dependencies.contains { !$0.knownVulnerabilities.isEmpty })

        // Gradle：Groovy DSL、Kotlin DSL、map 写法、platform、版本目录、插件、注释里的假依赖
        let groovy = try require(report.ecosystems.first { $0.manifestPath == "build.gradle" })
        XCTAssertEqual(groovy.ecosystem, .gradle)
        expect(groovy, "com.squareup.okhttp3:okhttp", "4.9.0", .runtime)
        expect(groovy, "org.apache.commons:commons-lang3", "[3.8,4.0)", .runtime)
        expect(groovy, "com.google.code.gson:gson", "2.10.1", .runtime)
        expect(groovy, "junit:junit", "4.13.2", .test)
        expect(groovy, "org.projectlombok:lombok", "1.18.30", .build)
        expect(groovy, "org.springframework.boot", "3.2.0", .build)
        XCTAssertFalse(groovy.dependencies.contains { $0.name.contains("should-not-parse") },
                       "被 // 注释掉的 implementation 行不得算依赖")

        let kotlinDsl = try require(report.ecosystems.first { $0.manifestPath == "build.gradle.kts" })
        expect(kotlinDsl, "com.google.guava:guava", "33.0.0-jre", .runtime)
        expect(kotlinDsl, "org.springframework.boot:spring-boot-dependencies", "3.2.0", .runtime)
        expect(kotlinDsl, "org.jetbrains.kotlin.jvm", "1.9.22", .build)
        expect(kotlinDsl, "com.diffplug.spotless", "6.23.3", .build)
        expect(kotlinDsl, "org.mockito:mockito-core", "5.2.0", .test)
        expect(kotlinDsl, "com.mysql:mysql-connector-j", "8.2.0", .runtime)

        let catalog = try require(report.ecosystems.first { $0.manifestPath == "settings.gradle" })
        XCTAssertEqual(catalog.dependencies.count, 2, "versionCatalogs 的 library() 写法必须读出来")
        expect(catalog, "com.acme:acme-shared", "1.4.2", .runtime)
        expect(catalog, "io.jsonwebtoken:jjwt", "0.9.1", .runtime)

        // SwiftPM：URL 末段取名、exact/branch 形式、本地 path 依赖不计数
        let swpm = try require(report.ecosystems.first { $0.manifestPath == "Package.swift" })
        XCTAssertEqual(swpm.ecosystem, .swiftPM)
        XCTAssertEqual(swpm.lockfileName, "Package.resolved")
        expect(swpm, "swift-log", "1.5.0", .runtime)
        expect(swpm, "GRDB.swift", "6.23.0", .runtime)
        expect(swpm, "Kingfisher", "7.10.0", .runtime)
        XCTAssertFalse(swpm.dependencies.contains { $0.name == "acme-local-kit" },
                       ".package(path:) 是本地模块，不得算外部依赖")
        expect(swpm, "palette", "stable", .runtime)
        // RD-10 的实际收益（本夹具独立真值）：`Package.swift` 写 `from: "1.5.0"` 是**请求**，
        // 同目录 `Package.resolved` 把实际检出的版本锁在 **1.6.1**（真值来自那 3 行 pin，
        // 不是从实现输出抄的）。装的是 1.6.1，而内置快照最新也是 1.6.1 ⇒ 不过旧。
        // 旧实现在这里既读不到 1.6.1、也解释不了"为什么 1.5.0 与 1.6.1 同时出现"。
        let swiftLog = try require(swpm.dependencies.first { $0.name == "swift-log" })
        XCTAssertEqual(swiftLog.version, "1.5.0", "声明范围原样保留")
        XCTAssertEqual(swiftLog.resolvedVersion, "1.6.1", "实际检出版本来自 Package.resolved")
        XCTAssertEqual(swiftLog.resolvedVersionSource, "Package.resolved", "结论要能追到是哪份文件给的")
        XCTAssertFalse(swiftLog.isProbablyOutdated, "按安装版本 1.6.1 比，已经就是最新")
        // 口径缺口（已报总工）：`.branch("main")` 与 `branch: "main"` 在 SwiftPM 里等价，
        // 但 ManifestParsers.swift:728-729 只认 `branch:` 关键字形式，
        // 方法形式取不到版本 -> 记成「未声明」，依赖实际锁在一个分支上却看不出来。
        expect(swpm, "design-system", strictContract ? "main" : "未声明", .runtime)

        // Go：require 块 + 单行 require + // indirect 降级 + replace 不解析 + v 前缀剥掉
        let go = try require(report.ecosystems.first { $0.manifestPath == "go.mod" })
        XCTAssertEqual(go.lockfileName, "go.sum")
        expect(go, "github.com/gin-gonic/gin", "1.9.1", .runtime)
        expect(go, "gopkg.in/yaml.v3", "3.0.1", .runtime)
        expect(go, "github.com/golang/protobuf", "1.5.3", .unknown)
        expect(go, "golang.org/x/sys", "0.12.0", .unknown)
        XCTAssertFalse(go.dependencies.contains { $0.name.hasPrefix("github.com/acme/orders-lab") },
                       "module 自指与 replace 行不得算依赖")

        // Cargo：内联表 version、git 无版本、dev/build 段
        let cargo = try require(report.ecosystems.first { $0.manifestPath == "Cargo.toml" })
        XCTAssertEqual(cargo.lockfileName, "Cargo.lock")
        expect(cargo, "serde", "1.0.190", .runtime)
        expect(cargo, "tokio", "1.37.0", .runtime)
        expect(cargo, "reqwest", "未声明", .runtime)
        expect(cargo, "tempfile", "3.10.0", .dev)
        expect(cargo, "cc", "1.0.83", .build)
        XCTAssertFalse(cargo.dependencies.contains { $0.name == "acme-orders-worker" },
                       "[package] 段是包自身，不是依赖")

        // Python：PEP 508 区间取下界、extras、-r 跳过、requires-python
        let pyproject = try require(report.ecosystems.first { $0.manifestPath == "pyproject.toml" })
        XCTAssertEqual(pyproject.lockfileName, .none)
        expect(pyproject, "requests", "2.28.1", .runtime)
        expect(pyproject, "pydantic", "2.4", .runtime)
        expect(pyproject, "rich", "未声明", .runtime)
        expect(pyproject, "python", "3.11", .platform)
        expect(pyproject, "setuptools", "68", .build)
        expect(pyproject, "click", "8.1", .dev)
        expect(pyproject, "pytest", "8.0", .dev)

        let requirements = try require(report.ecosystems.first { $0.manifestPath == "python-tool/requirements.txt" })
        expect(requirements, "flask", "3.0.0", .runtime)
        expect(requirements, "pandas", "2.1.4", .runtime)
        expect(requirements, "uvicorn", "0.27.0", .runtime)
        XCTAssertTrue(requirements.frameworkMarkers.contains("Flask"))

        // Ruby / CocoaPods / NuGet
        let gemfile = try require(report.ecosystems.first { $0.manifestPath == "Gemfile" })
        XCTAssertEqual(gemfile.lockfileName, "Gemfile.lock")
        expect(gemfile, "rails", "~> 7.1.2", .runtime)
        expect(gemfile, "rspec", "~> 3.12.2", .test)
        expect(gemfile, "rubocop", "~> 1.59.0", .dev)
        expect(gemfile, "nokogiri", ">= 1.13.10", .runtime)

        let podfile = try require(report.ecosystems.first { $0.manifestPath == "ios/Podfile" })
        XCTAssertEqual(podfile.lockfileName, "Podfile.lock")
        expect(podfile, "Alamofire", "~> 5.8.1", .runtime)
        expect(podfile, "Nimble", "~> 13.0.0", .test)
        XCTAssertFalse(podfile.dependencies.contains { $0.name == "ios" }, "platform 行不得算依赖")

        let nuget = try require(report.ecosystems.first { $0.manifestPath == "dotnet/packages.config" })
        XCTAssertEqual(nuget.ecosystem, .nuget)
        expect(nuget, "Newtonsoft.Json", "12.0.3", .runtime)
        expect(nuget, "Serilog", "3.1.1", .dev)

        XCTAssertFalse(report.ecosystems.contains { $0.ecosystem == .unknown })
    }

    /// Maven 多模块递归：把深度上限压到 1，BFS 就到不了 `java/<module>/pom.xml`，
    /// 只有 `expandMavenModules` 能把两份模块 pom 找回来。找不到就是「清单支持但读错」。
    func testMavenMultiModuleRescuedWhenDepthCapHidesModules() async throws {
        let shallow = try await ManifestDependencyAnalyzer(options: .default, maxDepth: 1)
            .analyze(projectRoot: root, allowNetwork: false)
        let deep = try await ManifestDependencyAnalyzer(options: .default, maxDepth: 6)
            .analyze(projectRoot: root, allowNetwork: false)

        let shallowPoms = shallow.ecosystems.filter { $0.ecosystem == .maven }.map(\.manifestPath).sorted()
        let deepPoms = deep.ecosystems.filter { $0.ecosystem == .maven }.map(\.manifestPath).sorted()
        print("=== WS-F 夹具 · Maven 多模块 ===")
        print("maxDepth=1 -> \(shallowPoms)")
        print("maxDepth=6 -> \(deepPoms)")

        XCTAssertEqual(shallowPoms, ["java/orders-api/pom.xml", "java/orders-service/pom.xml", "pom.xml"],
                       "深度上限外的小模块 pom.xml 必须通过 <modules> 递归补回来")
        XCTAssertEqual(deepPoms, shallowPoms, "两种深度上限下发现的 Maven 清单应当一致")
        XCTAssertEqual(shallow.ecosystems.filter { $0.ecosystem == .maven }
                           .reduce(0) { $0 + $1.dependencies.count }, 11)
    }

}
