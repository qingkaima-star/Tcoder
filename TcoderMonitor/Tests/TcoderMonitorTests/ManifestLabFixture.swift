import Foundation
import XCTest
@testable import TcoderMonitor
/// OWNER: WS-F 多清单夹具实验室（本文件由 WS-F 独占，不落进 WS-A/B/C 的任何 glob）。
///
/// 目标：用一棵**每个数字都由本文件手写定死**的夹具树，把六类分析器全部驱出真实数字，
/// 然后逐条核对「App 测得值 vs 设计真值」。`/opt/homebrew` 压测只有 Ruby/Gemfile，
/// 用户点名的 `package.json` / `pom.xml` / `build.gradle` / `Package.swift` 四类清单
/// 以及 Java 技术栈此前从未被真实数据验过 —— 这里补上。
///
/// 为什么断言精确相等而不是量级：夹具是我造的，真值就是我的设计，
/// 测得不等要么是解析缺陷、要么是口径缺陷，两种都必须暴露，**不许改断言迁就实现**。
///
/// ## 设计真值表（改夹具正文必须同步改这张表和下面的断言）
///
/// 清单 16 份 / 10 个生态 / 79 条依赖：
/// * `package.json` 10、`frontend/package.json` 3
/// * `pom.xml` 3、`java/orders-api/pom.xml` 3、`java/orders-service/pom.xml` 5
/// * `build.gradle` 7、`build.gradle.kts` 6、`settings.gradle` 2（版本目录写法）
/// * `Package.swift` 5（`.package(path:)` 不算）、`go.mod` 6、`Cargo.toml` 6
/// * `pyproject.toml` 10、`python-tool/requirements.txt` 3、`Gemfile` 5、
///   `ios/Podfile` 3、`dotnet/packages.config` 2
/// * 内置快照判定的 `outdatedCount` = 24；内置漏洞命中的 `vulnerableCount` = 8（7 条规则，
///   其中 jjwt 规则同时命中 Maven 与 Gradle 两份清单 -> 受影响依赖 2 条）
///
/// 覆盖率 5 份报告：lcov 75/100、istanbul 300/400、JaCoCo **report 级** 175/200、
/// coverage.py 200/250、clover 90/120 -> 合计 covered 840 / total 1070 = 78.5046…%。
///
/// 代码：`TODO` 7 个、`FIXME` 3 个；最大文件 `UserService.java` 1600 行（越过 1500 门槛）；
/// `OrderOrchestrator.routeOrder` 手写圈复杂度 17；两文件各一份的 16 行复制块 -> 重复率 > 0。
///
/// 日志 32 行：ERROR 5、WARN 3、FATAL 2、INFO 4、DEBUG 2、Java 异常头 4、
/// 堆栈与 Caused by 9 行；`crash.log` 3 个 `Fatal error` 锚点 -> crashCount 3。
///
/// Git：9 次提交、3 位作者（5/3/1）、无 merge、跨度 60 小时、分支 main、全部文件恰好各提交一次。
///
/// ## 已知缺陷留档
///
/// 本文件最初按切出点 `7347e09` 写下一批「缺陷留档」断言（钉的是当时的错误行为）。
/// WS-A `f55e4a0`（全仓均复杂度）与 WS-B `bf71131`（Git 探测与窗口报数）修好之后，
/// 这些位置已经**反向钉成回归护栏**：`analyzedFunctionCount` = 手算账本 18、
/// `averageCyclomaticComplexity` = 49/18、`commitsAnalyzed` = 9、
/// `discoveryMode` = `.selectedDirectory`、`resolvedRepositoryRoot` = 夹具根。
///
/// 剩下三处仍未修，默认轮次按现状断言并打印，
/// `TCODER_F_STRICT_CONTRACT=1` 换成设计期望（应当变红）：
/// caret 版本被虚报过旧、跨清单同坐标被并成一条漏洞、`Package.swift` 的
/// `.branch("x")` 方法形式丢版本。三处都修好后请删掉 `strictContract` 与本节。

/// WS-C/WS-F 健康评分与日志/代码分析共用的测试基类：整棵夹具树 + git 历史按类造一次。
/// 下面是 WS-F「多清单夹具实验室」的设计真值表与生命周期，正文原样搬自
/// ManifestLabFixtureTests.swift（1943 行越过 800 闸门，WS-V 拆分，断言与用例一字未改）：
/// 用例按分析器分成 ManifestLabDependencyTests / CoverageTests / CodeMetricsTests /
/// LogAndGitTests / HealthTests 五个类，夹具树正文搬到 ManifestLabTree*.swift。
class ManifestLabTestCase: XCTestCase {

    /// 整棵树 + git 历史对全类只造一次：每个用例重造 40 个文件与 21 次 git 调用，
    /// 既慢又会在 Process 反复起停时偶发 60 秒级停顿。
    private static var shared: (root: URL, built: LabTree.Built)?
    private static var failure: Error?

    var root: URL!
    var tree: LabTree.Built!

    /// 打开后按「设计期望」断言；默认按「HEAD 实测」断言并打印缺陷。
    var strictContract: Bool {
        ProcessInfo.processInfo.environment["TCODER_F_STRICT_CONTRACT"] == "1"
    }

    // MARK: - 生命周期

    override class func setUp() {
        super.setUp()
        let name = "acme-orders-lab-\(UUID().uuidString.prefix(8))"
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        do {
            let started = Date()
            let built = try LabTree.build(at: base)
            try LabTree.makeGitRepository(at: base, files: built.files)
            print("【WS-F】夹具构建耗时 \(String(format: "%.2f", Date().timeIntervalSince(started)))s"
                + " 文件 \(built.files.count) 个")
            shared = (base, built)
        } catch {
            failure = error
        }
    }

    override class func tearDown() {
        if let shared { try? FileManager.default.removeItem(at: shared.root) }
        shared = nil
        super.tearDown()
    }

    override func setUpWithError() throws {
        if let failure = Self.failure { throw failure }
        guard let shared = Self.shared else { throw LabTree.LabError.git("共享夹具未建成") }
        root = shared.root
        tree = shared.built
    }


    // MARK: - 断言小工具

    func expect(_ report: EcosystemReport, _ name: String, _ version: String, _ scope: DependencyScope,
                        file: StaticString = #filePath, line: UInt = #line) {
        guard let record = report.dependencies.first(where: { $0.name == name }) else {
            XCTFail("「\(report.manifestPath)」里找不到依赖 \(name)，实得 \(report.dependencies.map(\.name))",
                    file: file, line: line)
            return
        }
        XCTAssertEqual(record.version, version, "\(name) 的版本解析不对", file: file, line: line)
        XCTAssertEqual(record.scope, scope, "\(name) 的 scope 不对", file: file, line: line)
    }

    func require<T>(_ value: T?, _ message: String = "取值失败",
                            file: StaticString = #filePath, line: UInt = #line) throws -> T {
        try XCTUnwrap(value, message, file: file, line: line)
    }

}
