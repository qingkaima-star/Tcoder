/// OWNER: WS-X3 TestSplit —— 自 CodeAnalyzerPrecisionTests.swift 拆出，全仓均复杂度不是热点均值、相对路径与词法别名。用例本体未改，只是搬了家。
import Foundation
import XCTest
@testable import TcoderMonitor

extension CodeAnalyzerTests {

    /// 契约新字段必须是**全部被识别函数**的均值，而不是热点榜（前 20）的均值。
    /// 合成一个「1 个 21 分支的巨型函数 + 24 个平凡函数」的仓库：
    /// 全仓均值 = (21 + 24×1) / 25 = 1.8，热点榜均值 = (21 + 19×1) / 20 = 2.0 —— 方向必须是热点榜偏高。
    func testWholeRepositoryAverageComplexityIsNotTheHotspotAverage() async throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        var source = "func monster(a: Int) -> Int {\n"
        for index in 1...20 { source += "    if a > \(index) { return \(index) }\n" }
        source += "    return 0\n}\n"
        for index in 0..<24 { source += "func trivial\(index)(a: Int) -> Int {\n    return a\n}\n" }
        _ = try write(source + "\n", to: "Sized.swift", in: root)

        let metrics = try await FileSystemCodeAnalyzer().analyze(root: root, options: options(maxFiles: 100))
        XCTAssertEqual(metrics.analyzedFunctionCount, 25, "分母必须是全部被识别函数：\(metrics.analyzedFunctionCount)")
        XCTAssertEqual(metrics.totalFiles, 1)
        let average = try XCTUnwrap(metrics.averageCyclomaticComplexity, "有函数时均值不得为 nil")
        XCTAssertEqual(average, Double(21 + 24) / 25, accuracy: 1e-9, "全仓均值算法不符")
        let hotspots = metrics.topComplexFunctions.map(\.cyclomaticComplexity)
        XCTAssertFalse(hotspots.isEmpty, "热点榜必须有内容")
        let hotspotAverage = Double(hotspots.reduce(0, +)) / Double(hotspots.count)
        XCTAssertGreaterThan(hotspotAverage, average,
                             "热点榜均值必须高于全仓均值，否则说明字段取错了来源：\(hotspots)")
        XCTAssertEqual(hotspotAverage, Double(21 + 19) / 20, accuracy: 1e-9)
    }

    /// `analyzedFunctionCount == 0` 时均值必须是 nil，不是 0：
    /// 「没识别到函数」是未知，给 0 分会把纯数据/配置仓的复杂度分量评成满分。
    func testAverageComplexityIsNilWhenNoFunctionIsRecognized() async throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        _ = try write("{\"a\": 1,\n\"b\": 2}\n", to: "data.json", in: root)
        _ = try write("# 标题\n\n正文一行\n", to: "README.md", in: root)

        let metrics = try await FileSystemCodeAnalyzer().analyze(root: root, options: options(maxFiles: 100))
        XCTAssertEqual(metrics.totalFiles, 2, "两个数据文件都要进入统计")
        XCTAssertGreaterThan(metrics.codeLines, 0, "行数统计本身必须是真实的")
        XCTAssertEqual(metrics.analyzedFunctionCount, 0)
        XCTAssertNil(metrics.averageCyclomaticComplexity, "零函数必须是 nil，不能是 0")
        XCTAssertTrue(metrics.topComplexFunctions.isEmpty)
    }

    /// 字段是 Optional 是为了持久化兼容：JSON 往返必须保住 nil 与数值的区分。
    func testAverageComplexityRoundTripsThroughJSON() throws {
        var empty = CodeMetrics()
        empty.analyzedFunctionCount = 0
        empty.averageCyclomaticComplexity = nil
        let unknown = try JSONDecoder().decode(CodeMetrics.self, from: JSONEncoder().encode(empty))
        XCTAssertNil(unknown.averageCyclomaticComplexity, "nil 不能被解码成 0")
        XCTAssertEqual(unknown.analyzedFunctionCount, 0)

        var known = CodeMetrics()
        known.analyzedFunctionCount = 25
        known.averageCyclomaticComplexity = 1.8
        let decoded = try JSONDecoder().decode(CodeMetrics.self, from: JSONEncoder().encode(known))
        XCTAssertEqual(decoded.averageCyclomaticComplexity ?? 0, 1.8, accuracy: 1e-9)
        XCTAssertEqual(decoded.analyzedFunctionCount, 25)
    }

    /// `resolvingSymlinksInPath()` 与 `canonicalPathKey` 只对**已存在**的路径生效，
    /// 所以旧版 `relativePath` 在 `/tmp/x` 不存在时判不到同一个根、在存在时才判得到 ——
    /// 用例因此会随文件系统残留状态时好时坏（e2e 默认夹具就在 /tmp/tcoder-fixture）。
    /// 现在统一走「字面别名形态」这一档：不 stat、同一输入永远同一输出，两种方向都要钉住。
    func testRelativePathIsIndependentOfFileSystemState() throws {
        // 两个路径都不存在
        let missing = SourceFileClassifier.relativePath(
            for: URL(fileURLWithPath: "/private/tmp/wsa-definitely-missing/KeepMe/Kept.swift"),
            root: URL(fileURLWithPath: "/tmp/wsa-definitely-missing"))
        XCTAssertEqual(missing, "KeepMe/Kept.swift", "根不存在时必须仍能判定同根（反方向见下）")
        let reversed = SourceFileClassifier.relativePath(
            for: URL(fileURLWithPath: "/tmp/wsa-definitely-missing/KeepMe/Kept.swift"),
            root: URL(fileURLWithPath: "/private/tmp/wsa-definitely-missing/KeepMe/Kept.swift").deletingLastPathComponent())
        XCTAssertEqual(reversed, "Kept.swift", "反方向（URL 是别名形态、根是 private 形态）同样必须命中")

        // 同一条输入重复调用必须稳定（纯函数）
        let again = SourceFileClassifier.relativePath(
            for: URL(fileURLWithPath: "/private/tmp/wsa-definitely-missing/KeepMe/Kept.swift"),
            root: URL(fileURLWithPath: "/tmp/wsa-definitely-missing"))
        XCTAssertEqual(again, missing, "relativePath 必须是纯函数，不得依赖文件系统状态")

        // 夹具真实存在时结论必须一致，「不存在」与「存在」两种文件系统状态不得给出不同口径
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        _ = try write("let a = 1\n", to: "KeepMe/Kept.swift", in: root)
        let existing = SourceFileClassifier.relativePath(
            for: root.appendingPathComponent("KeepMe/Kept.swift"), root: root)
        XCTAssertEqual(existing, "KeepMe/Kept.swift")
    }

    /// 字面别名形态表：只有系统固定的那四个前缀参与，普通目录不得被改写。
    func testLexicalAliasFormsOnlyCoverSystemPrivateAliases() {
        XCTAssertEqual(SourceFileClassifier.lexicalAliasForms(ofPath: "/tmp/x/y").sorted(),
                       ["/private/tmp/x/y", "/tmp/x/y"])
        XCTAssertEqual(SourceFileClassifier.lexicalAliasForms(ofPath: "/private/var/folders/a").sorted(),
                       ["/private/var/folders/a", "/var/folders/a"])
        XCTAssertEqual(SourceFileClassifier.lexicalAliasForms(ofPath: "/etc/hosts").count, 2)
        XCTAssertEqual(SourceFileClassifier.lexicalAliasForms(ofPath: "/Users/one/x"), ["/Users/one/x"],
                       "非别名目录不得凭空造形态")
        XCTAssertEqual(SourceFileClassifier.lexicalAliasForms(ofPath: "/private/cores/x"),
                       ["/private/cores/x"], "private 下的非别名目录不得去掉 private")
    }

}
