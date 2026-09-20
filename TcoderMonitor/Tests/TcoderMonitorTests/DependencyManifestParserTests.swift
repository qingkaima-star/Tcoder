/// OWNER: WS-X3 TestSplit —— 自 DependencyAnalysisTests.swift 整块拆出：14 种清单解析器逐个（npm/maven/gradle/swiftpm/pip/go/cargo/gem/lock 名）。用例本体一字未改，只是搬了家。
import XCTest
@testable import TcoderMonitor

final class ManifestParserTests: XCTestCase {

    private func assertLock(_ ecosystem: DependencyEcosystem, _ listing: [String], _ expected: String?,
                            _ label: String) {
        XCTAssertEqual(ManifestParsers.lockfileName(for: ecosystem, in: Set(listing)), expected, label)
    }

    private func assertName(_ fileName: String, _ expected: DependencyEcosystem?, _ label: String) {
        XCTAssertEqual(ManifestFileName.ecosystem(for: fileName), expected, label)
    }

    func testPackageJSONScopesAndMalformedInput() {
        let deps = ManifestParsers.packageJSONDependencies(Fixture.pkgJSON, manifestPath: "package.json")
        XCTAssertEqual(Fixture.names(deps), ["react", "lodash", "vite", "fsevents"], "四个依赖都要抓到")
        XCTAssertEqual(Fixture.found(deps, "react")?.scope, .runtime, "dependencies 是运行时")
        XCTAssertEqual(Fixture.found(deps, "vite")?.scope, .dev, "devDependencies 是开发")
        XCTAssertTrue(Fixture.found(deps, "vite")?.isDevDependency == true, "isDevDependency 与 scope 一致")
        XCTAssertFalse(Fixture.found(deps, "fsevents")?.isDevDependency == true, "optional 不是开发依赖")
        XCTAssertTrue(Fixture.found(deps, "lodash")?.version.contains("4.17.15") == true, "版本号要抓到")
        XCTAssertEqual(deps.first?.ecosystem, .npm, "生态必须是 npm")
        XCTAssertEqual(ManifestParsers.packageJSONDependencies("{ not json", manifestPath: "package.json"), [],
                       "非法 JSON 返回空数组而不是崩溃")
        XCTAssertEqual(ManifestParsers.packageJSONDependencies("", manifestPath: "package.json"), [], "空文本返回空数组")
    }

    func testPomXMLSubstitutesPropertiesAndScope() {
        let deps = ManifestParsers.pomXMLDependencies(Fixture.pomXML, manifestPath: "pom.xml")
        XCTAssertEqual(Fixture.names(deps), ["org.springframework:spring-core", "com.google.guava:guava"],
                       "命名必须是 group:artifact")
        let spring = Fixture.found(deps, "org.springframework:spring-core")
        XCTAssertEqual(spring?.version, "5.3.30", "${spring.version} 必须被 properties 代入")
        XCTAssertEqual(spring?.scope, .test, "<scope>test</scope> 映射为测试")
        let guava = Fixture.found(deps, "com.google.guava:guava")
        XCTAssertEqual(guava?.version, "32.1.3-jre", "第二个属性也要代入")
        XCTAssertEqual(guava?.scope, .runtime, "无 scope 标签默认运行时")
        let paths = ManifestParsers.mavenModulePaths(in: Fixture.pomXML)
        XCTAssertEqual(Set(paths), ["api", "service-core"], "抽取两个 <module>")
        XCTAssertFalse(paths.contains { $0.isEmpty }, "不得产出空模块名")
        XCTAssertEqual(ManifestParsers.mavenModulePaths(in: "<project></project>"), [], "无 modules 返回空")
    }

    func testGradleBothStringSyntaxesAndTestConfiguration() {
        let deps = ManifestParsers.gradleDependencies("""
        dependencies {
            implementation 'com.google.guava:guava:33.0.0-jre'
            implementation("org.jetbrains.kotlin:kotlin-stdlib:1.9.20")
            testImplementation 'junit:junit:4.13.2'
        }
        """, manifestPath: "build.gradle")
        XCTAssertEqual(Fixture.names(deps), ["com.google.guava:guava", "org.jetbrains.kotlin:kotlin-stdlib",
                                             "junit:junit"], "单引号与括号两种形式都要解析")
        XCTAssertEqual(Fixture.found(deps, "com.google.guava:guava")?.version, "33.0.0-jre", "版本取第三段")
        XCTAssertEqual(Fixture.found(deps, "junit:junit")?.scope, .test, "testImplementation 是测试")
        XCTAssertEqual(Fixture.found(deps, "org.jetbrains.kotlin:kotlin-stdlib")?.scope, .runtime,
                       "implementation 是运行时")
        XCTAssertEqual(deps.first?.ecosystem, .gradle, "生态必须是 gradle")
    }

    func testSwiftPackageFromAndExactStripGitSuffix() {
        let deps = ManifestParsers.swiftPackageDependencies("""
        let package = Package(
            name: "TcoderKit",
            dependencies: [
                .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
                .package(url: "https://github.com/tcoder/Kit.git", exact: "2.0.0"),
            ]
        )
        """, manifestPath: "Package.swift")
        XCTAssertEqual(deps.count, 2, "两个 .package 都要抓到")
        XCTAssertTrue(deps.allSatisfy { !$0.name.hasSuffix(".git") }, "name 必须去掉 .git 后缀")
        XCTAssertTrue(deps.contains { $0.name.hasSuffix("swift-log") }, "第一个包名以 swift-log 结尾")
        XCTAssertTrue(deps.contains { $0.name.hasSuffix("Kit") }, "第二个包名以 Kit 结尾")
        XCTAssertTrue(deps.contains { $0.version.contains("1.5.0") }, "from: 语义版本要抓到")
        XCTAssertTrue(deps.contains { $0.version.contains("2.0.0") }, "exact: 语义版本要抓到")
        XCTAssertEqual(deps.first?.ecosystem, .swiftPM, "生态必须是 swiftPM")
    }

    func testRequirementsTxtSkipsCommentsAndReferences() {
        let deps = ManifestParsers.requirementsTxtDependencies("""
        # Tcoder 后端依赖
        flask==2.3.3
        requests>=2.31.0

        -r base.txt
        --index-url https://pypi.tcoder.local/simple
        """, manifestPath: "requirements.txt")
        XCTAssertEqual(Fixture.names(deps), ["flask", "requests"], "注释、空行、-r/--index-url 全部跳过")
        XCTAssertEqual(Fixture.found(deps, "flask")?.version, "2.3.3", "== 取精确版本")
        XCTAssertEqual(Fixture.found(deps, "requests")?.version, "2.31.0", ">= 取约束右侧版本")
        XCTAssertEqual(deps.first?.ecosystem, .python, "生态必须是 python")
    }

    func testGoModRequireBlock() {
        let deps = ManifestParsers.goModDependencies("""
        module tcoder.local/monitor
        go 1.22
        require (
        \tgithub.com/gin-gonic/gin v1.9.1
        \tgolang.org/x/net v0.17.0
        )
        """, manifestPath: "go.mod")
        XCTAssertEqual(Fixture.names(deps), ["github.com/gin-gonic/gin", "golang.org/x/net"],
                       "require 块内两条依赖都要抓到")
        XCTAssertTrue(Fixture.found(deps, "golang.org/x/net")?.version.hasSuffix("0.17.0") == true, "版本要解析出来")
        XCTAssertEqual(deps.first?.ecosystem, .go, "生态必须是 go")
    }

    func testCargoTomlThreeSections() {
        let deps = ManifestParsers.cargoTomlDependencies("""
        [package]
        name = "tcoder-monitor"
        [dependencies]
        serde = "1.0.190"
        [dev-dependencies]
        tempfile = "3.8.1"
        [build-dependencies]
        cc = "1.0.83"
        """, manifestPath: "Cargo.toml")
        XCTAssertEqual(Fixture.names(deps), ["serde", "tempfile", "cc"], "三个 section 都要解析")
        XCTAssertEqual(Fixture.found(deps, "serde")?.version, "1.0.190", "版本正确")
        XCTAssertEqual(Fixture.found(deps, "serde")?.scope, .runtime, "[dependencies] 是运行时")
        XCTAssertEqual(Fixture.found(deps, "tempfile")?.scope, .dev, "[dev-dependencies] 是开发")
        XCTAssertEqual(Fixture.found(deps, "cc")?.scope, .build, "[build-dependencies] 是构建")
        XCTAssertEqual(deps.first?.ecosystem, .cargo, "生态必须是 cargo")
    }

    func testLockfileNameDetectionForKnownLockfiles() {
        assertLock(.npm, ["package.json", "package-lock.json"], "package-lock.json", "npm 默认锁文件")
        assertLock(.npm, ["package.json", "yarn.lock"], "yarn.lock", "yarn 锁文件")
        assertLock(.npm, ["pnpm-lock.yaml", "package.json"], "pnpm-lock.yaml", "pnpm 锁文件")
        assertLock(.gradle, ["build.gradle", "gradle.lockfile"], "gradle.lockfile", "gradle 锁文件")
        assertLock(.cocoapods, ["Podfile", "Podfile.lock"], "Podfile.lock", "CocoaPods 锁文件")
        assertLock(.cargo, ["Cargo.toml", "Cargo.lock"], "Cargo.lock", "cargo 锁文件")
        assertLock(.go, ["go.mod", "go.sum"], "go.sum", "go 校验文件")
        assertLock(.npm, ["package.json"], nil, "无锁文件返回 nil")
    }

    func testFrameworkMarkersFromDependencyNames() {
        let web = ManifestParsers.frameworkMarkers(ecosystem: .npm, dependencyNames: ["react", "vite", "lodash"])
        XCTAssertTrue(web.contains("React"), "react 给出 React 标记")
        XCTAssertTrue(web.contains("Vite"), "vite 给出 Vite 标记")
        let server = ManifestParsers.frameworkMarkers(ecosystem: .maven, dependencyNames: [
            "org.springframework.boot:spring-boot-starter-web"])
        XCTAssertTrue(server.contains("Spring Boot"), "spring-boot-starter 给出 Spring Boot 标记")
        XCTAssertEqual(ManifestParsers.frameworkMarkers(ecosystem: .npm, dependencyNames: ["left-pad"]), [],
                       "无框架特征返回空数组")
    }

    func testManifestFileNameLookupAndFullSet() {
        assertName("package.json", .npm, "package.json -> npm")
        assertName("pom.xml", .maven, "pom.xml -> maven")
        assertName("build.gradle.kts", .gradle, "kts -> gradle")
        assertName("Package.swift", .swiftPM, "Package.swift -> swiftPM")
        assertName("requirements.txt", .python, "requirements -> python")
        assertName("go.mod", .go, "go.mod -> go")
        assertName("Cargo.toml", .cargo, "Cargo.toml -> cargo")
        assertName("Podfile", .cocoapods, "Podfile -> CocoaPods")
        assertName("README.md", nil, "未知文件名返回 nil")
        assertName("", nil, "空文件名返回 nil")
        for expected in ["package.json", "pom.xml", "build.gradle", "Package.swift", "go.mod", "Cargo.toml"] {
            XCTAssertTrue(ManifestFileName.allManifestNames.contains(expected), "清单名集合缺少 \(expected)")
        }
        XCTAssertFalse(ManifestFileName.allManifestNames.contains("README.md"), "集合不得混入非清单文件")
    }

    func testParseDispatchesByNameAndRejectsNonManifest() {
        let parsed = ManifestParsers.parse(text: Fixture.pkgJSON, manifestPath: "package.json",
                                           directoryRelativePath: "web",
                                           directoryListing: ["package.json", "yarn.lock"])
        guard let parsed else { return XCTFail("package.json 必须分派到 npm 解析器") }
        XCTAssertEqual(parsed.ecosystem, .npm, "生态由文件名决定")
        XCTAssertEqual(parsed.manifestRelativePath, "package.json", "清单相对路径原样回传")
        XCTAssertEqual(parsed.directoryRelativePath, "web", "目录相对路径原样回传")
        XCTAssertEqual(parsed.lockfileName, "yarn.lock", "锁文件由目录清单推出")
        XCTAssertTrue(parsed.frameworkMarkers.contains("React"), "框架标记要带上")
        XCTAssertEqual(parsed.dependencies.count, 4, "依赖数量正确")
        XCTAssertNil(ManifestParsers.parse(text: "hello", manifestPath: "notes.txt", directoryRelativePath: "",
                                           directoryListing: ["notes.txt"]), "非清单文件名返回 nil")
        XCTAssertNil(ManifestParsers.parse(text: "", manifestPath: "", directoryRelativePath: "",
                                           directoryListing: []), "空文件名返回 nil")
        let sub = ManifestParsers.parse(text: Fixture.pomXML, manifestPath: "backend/pom.xml",
                                        directoryRelativePath: "backend", directoryListing: ["pom.xml"])
        guard let sub else { return XCTFail("子目录里的 pom.xml 也要能解析") }
        XCTAssertEqual(sub.ecosystem, .maven, "生态必须是 maven")
        XCTAssertEqual(sub.directoryRelativePath, "backend", "子目录路径要保留")
        XCTAssertEqual(sub.dependencies.count, 2, "maven 依赖数正确")
    }
    /// Ruby 生态的计数口径：只数 Gemfile 里直接声明的 `gem`，**不**展开 Gemfile.lock 的
    /// 传递依赖树。Homebrew 实测是 44（直接声明）对 90（lock 里含传递），两者必须分得清。
    func testGemfileCountsDirectDeclarationsNotLockTree() {
        let gemfile = """
        source "https://rubygems.org"
        ruby "~> 4.0.0"
        gem "rake"
        group :doc do
          gem "ronn", require: false
        end
        # gem "disabled-in-comment"
        #disallowed = ["bundler"]
        group :test do
          gem "minitest", "~> 5.0"
          gem "rubocop", "1.2"
        end
        """
        let deps = ManifestParsers.gemfileDependencies(gemfile, manifestPath: "Gemfile")
        XCTAssertEqual(Fixture.names(deps), Set(["rake", "ronn", "minitest", "rubocop"]),
                       "只收直接声明的 gem：注释里的、disallowed 列表、ruby 版本都不算依赖")
        XCTAssertEqual(deps.count, 4, "4 条直接声明，不展开锁文件")
        XCTAssertEqual(Fixture.found(deps, "ronn")?.scope, .dev, "group :doc 属开发分组")
        XCTAssertEqual(Fixture.found(deps, "minitest")?.scope, .test, "group :test 归测试")
        XCTAssertEqual(ManifestParsers.lockfileName(for: .ruby, in: ["Gemfile", "Gemfile.lock"]),
                       "Gemfile.lock", "锁文件要单独报出来，但它是口径说明不是依赖数")
    }

}
