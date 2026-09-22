// OWNER: R3 依赖证据链 · 锁文件解析用例（RD-10 / RD-12 地基）
//
// 真值全部来自本文件内联的夹具字符串（禁止读本机其它工程）：
// 每个期望值都是手写的"这份锁文件应该解析出哪个数"，不是拿实现输出回填的。
import XCTest
@testable import TcoderMonitor

final class DependencyLockResolutionTests: XCTestCase {

    // MARK: - package-lock.json v3（声明范围 ≠ 锁定版本）

    /// 夹具：根包声明 `^1.2.3`，但实际锁到 `1.2.9`；另有传递依赖 `b` 藏在 `a` 下面。
    func testPackageLockV3ResolvesDeclaredRangeToInstalledVersion() throws {
        let lock = #"""
        {
          "name": "acme-app", "lockfileVersion": 3,
          "packages": {
            "": { "name": "acme-app", "dependencies": { "a": "^1.2.3", "lodash": "~4.17.15" } },
            "node_modules/a": { "version": "1.2.9", "license": "MIT" },
            "node_modules/lodash": { "version": "4.17.21" },
            "node_modules/a/node_modules/b": { "version": "9.9.9" }
          }
        }
        """#
        let parsed = try XCTUnwrap(DependencyLockParser.parse(fileName: "package-lock.json",
                                                             text: lock, relativePath: "package-lock.json"))
        XCTAssertEqual(parsed.resolvedVersion(name: "a", declaredRange: "^1.2.3"), "1.2.9",
                       "锁文件说装的是 1.2.9 —— 声明里的 ^1.2.3 只是请求")
        XCTAssertEqual(parsed.resolvedVersion(name: "lodash", declaredRange: "~4.17.15"), "4.17.21")
        XCTAssertNil(parsed.resolvedVersion(name: "b", declaredRange: "^9.0.0"),
                     "node_modules/a/node_modules/b 是 a 的传递依赖，不得回填成直接依赖 b")
    }

    func testPackageLockV1TopLevelOnly() throws {
        let lock = #"""
        {
          "lockfileVersion": 1,
          "dependencies": {
            "left-pad": { "version": "1.3.0" },
            "express": { "version": "4.18.2", "dependencies": { "debug": { "version": "2.6.9" } } }
          }
        }
        """#
        let parsed = try XCTUnwrap(DependencyLockParser.parse(fileName: "package-lock.json",
                                                             text: lock, relativePath: "package-lock.json"))
        XCTAssertEqual(parsed.resolvedVersion(name: "left-pad", declaredRange: "1.3.0"), "1.3.0")
        XCTAssertEqual(parsed.resolvedVersion(name: "express", declaredRange: "^4.0.0"), "4.18.2")
        XCTAssertNil(parsed.resolvedVersion(name: "debug", declaredRange: "^2.0.0"),
                     "嵌套的 debug 属于 express 的传递依赖，不回填")
    }

    // MARK: - yarn.lock（同包多版本：按声明符匹配，绝不按包名匹配）

    func testYarnLockMatchesBySpecifierNotByName() throws {
        let lock = """
        # yarn lockfile v1
        lodash@^4.17.15, lodash@^4.17.20:
          version "4.17.21"
          resolved "https://registry.yarnpkg.com/lodash/-/lodash-4.17.21.tgz"

        "@acme/tool@^1.0.0":
          version "1.0.4"

        axios@0.21.1:
          version "0.21.1"
        """
        let parsed = try XCTUnwrap(DependencyLockParser.parse(fileName: "yarn.lock",
                                                             text: lock, relativePath: "yarn.lock"))
        XCTAssertEqual(parsed.resolvedVersion(name: "lodash", declaredRange: "^4.17.15"), "4.17.21")
        XCTAssertEqual(parsed.resolvedVersion(name: "lodash", declaredRange: "^4.17.20"), "4.17.21")
        XCTAssertEqual(parsed.resolvedVersion(name: "@acme/tool", declaredRange: "^1.0.0"), "1.0.4",
                       "scope 包名里也有 @，切分必须从右往左找")
        XCTAssertEqual(parsed.resolvedVersion(name: "axios", declaredRange: "0.21.1"), "0.21.1")
    }

    func testAmbiguousSameNameVersionsAreNotGuessed() throws {
        // 同一个包在锁里有两个版本（不同父包各锁一份）⇒ 按包名回填就是凭空挑一个。
        let lock = """
        foo@^1.0.0:
          version "1.0.1"

        foo@^2.0.0:
          version "2.3.4"
        """
        let parsed = try XCTUnwrap(DependencyLockParser.parse(fileName: "yarn.lock",
                                                             text: lock, relativePath: "yarn.lock"))
        XCTAssertEqual(parsed.ambiguousNames, ["foo"], "歧义要留下证据")
        XCTAssertNil(parsed.resolvedVersion(name: "foo", declaredRange: ""), "按包名不许猜")
        XCTAssertEqual(parsed.resolvedVersion(name: "foo", declaredRange: "^2.0.0"), "2.3.4",
                       "但按声明符仍能确定回填")
    }

    // MARK: - gradle.lockfile / Cargo.lock / Package.resolved

    func testGradleLockfileCoordinates() throws {
        // 真实 gradle.lockfile 的形状是 `group:name:version=配置,配置`（一行一条）。
        let lock = """
        # This is a Gradle generated file for dependency locking.
        com.acme.lib:core:1.4.2=compileClasspath,runtimeClasspath
        org.jetbrains.kotlin:kotlin-stdlib:1.9.22=compileClasspath
        empty=annotationProcessor
        """
        let parsed = try XCTUnwrap(DependencyLockParser.parse(fileName: "gradle.lockfile",
                                                             text: lock, relativePath: "gradle.lockfile"))
        XCTAssertEqual(parsed.resolvedVersion(name: "com.acme.lib:core", declaredRange: "[1.4,2.0)"), "1.4.2")
        XCTAssertEqual(parsed.resolvedVersion(name: "org.jetbrains.kotlin:kotlin-stdlib",
                                             declaredRange: "1.9.0"), "1.9.22")
        XCTAssertNil(parsed.resolvedVersion(name: "empty", declaredRange: "*"), "占位行不产结论")
    }

    func testCargoLockNameVersionPairs() throws {
        let lock = """
        version = 3

        [[package]]
        name = "serde"
        version = "1.0.203"
        source = "registry+https://github.com/rust-lang/crates.io-index"

        [[package]]
        name = "tokio"
        version = "1.38.1"
        """
        let parsed = try XCTUnwrap(DependencyLockParser.parse(fileName: "Cargo.lock",
                                                             text: lock, relativePath: "Cargo.lock"))
        XCTAssertEqual(parsed.resolvedVersion(name: "serde", declaredRange: "1.0"), "1.0.203")
        XCTAssertEqual(parsed.resolvedVersion(name: "tokio", declaredRange: ">=1.0"), "1.38.1")
    }

    func testSwiftPackageResolvedPins() throws {
        let lock = #"""
        {
          "pins": [
            { "identity": "swift-log", "location": "https://github.com/apple/swift-log.git",
              "state": { "revision": "d", "version": "1.6.1" } },
            { "identity": "grdb.swift", "location": "https://github.com/groue/GRDB.swift.git",
              "state": { "revision": "e", "version": "6.24.0" } }
          ],
          "version": 2
        }
        """#
        let parsed = try XCTUnwrap(DependencyLockParser.parse(fileName: "Package.resolved",
                                                             text: lock, relativePath: "Package.resolved"))
        XCTAssertEqual(parsed.resolvedVersion(name: "swift-log", declaredRange: "1.4.0"), "1.6.1")
    }

    // MARK: - 坏数据：解不出就返回 nil，绝不抛、绝不给 0

    func testMalformedLocksYieldNoResolution() {
        for (name, text) in [("package-lock.json", "{ not json"),
                             ("package-lock.json", #"{"lockfileVersion": 3, "packages": {}}"#),
                             ("yarn.lock", ""),
                             ("Cargo.lock", "]]]garbage"),
                             ("gradle.lockfile", "no-equals-here"),
                             ("bun.lockb", "\u{0}\u{1}binary")] {
            XCTAssertNil(DependencyLockParser.parse(fileName: name, text: text, relativePath: name),
                         "\(name) 的这份坏数据必须解不出东西，而不是解出一个假版本")
        }
    }

    // MARK: - 端到端：分析器把解析值写进记录，比较与查询都改用它

    func testAnalyzerAppliesLockResolutionIntoRecords() async throws {
        let root = try makeTree("lock-e2e", files: [
            "package.json": #"""
            { "name": "app", "dependencies": { "a": "^1.2.3" }, "devDependencies": { "zz-not-locked": "^9.0.0" } }
            """#,
            "package-lock.json": #"""
            {
              "name": "app", "lockfileVersion": 3,
              "packages": {
                "": { "dependencies": { "a": "^1.2.3" } },
                "node_modules/a": { "version": "1.2.9" }
              }
            }
            """#,
        ])
        let report = try await ManifestDependencyAnalyzer(options: .default, maxDepth: 3)
            .analyze(projectRoot: root, allowNetwork: false)
        let npm = try XCTUnwrap(report.ecosystems.first { $0.ecosystem == .npm })
        let locked = try XCTUnwrap(npm.dependencies.first { $0.name == "a" })
        XCTAssertEqual(locked.version, "^1.2.3", "声明范围原样留着")
        XCTAssertEqual(locked.resolvedVersion, "1.2.9", "解析版本另存一格")
        XCTAssertEqual(locked.resolvedVersionSource, "package-lock.json", "结论要能追到是哪份文件")
        let identity = DependencyVersionIdentity.of(locked)
        XCTAssertEqual(identity.query?.version, "1.2.9", "查询身份改用安装版本")
        XCTAssertEqual(identity.query?.basis, .lockedVersion)

        let notLocked = try XCTUnwrap(npm.dependencies.first { $0.name == "zz-not-locked" })
        XCTAssertNil(notLocked.resolvedVersion, "锁里没有的包不得被编出一个版本")
        XCTAssertNil(notLocked.resolvedVersionSource)
        XCTAssertEqual(DependencyVersionIdentity.of(notLocked).query?.basis, .rangeLowerBound,
                       "没解析值时降级成'按下界查询'，并且要把这个降级说出来")
    }

    /// 一条锁文件与声明**互相矛盾**的夹具：锁里是 2.0.0，清单要 ^1.0.0。
    /// 这不该被静默"择一"——安装的就是 2.0.0，而"它不满足自己的声明范围"是另一件事。
    func testLockVersionOutsideDeclaredRangeStillWinsForComparison() throws {
        let lock = #"""
        { "lockfileVersion": 3,
          "packages": { "": { "dependencies": { "odd": "^1.0.0" } },
                        "node_modules/odd": { "version": "2.0.0" } } }
        """#
        let parsed = try XCTUnwrap(DependencyLockParser.parse(fileName: "package-lock.json",
                                                             text: lock, relativePath: "package-lock.json"))
        XCTAssertEqual(parsed.resolvedVersion(name: "odd", declaredRange: "^1.0.0"), "2.0.0",
                       "锁文件是安装事实的唯一来源；不与声明范围做'看起来更合理'的取舍")
    }

    // MARK: - 夹具

    private func makeTree(_ tag: String, files: [String: String]) throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tcoder-r3-lock-\(tag)-\(UUID().uuidString.prefix(8))", isDirectory: true)
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
