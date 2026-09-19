import Foundation
import XCTest
@testable import TcoderMonitor

/// WS-F 夹具实验室 · 代码规模 / 复杂度 / 重复：已知标记、超大文件与刻意埋的克隆块。
/// 拆自 ManifestLabFixtureTests.swift，断言与用例一字未改（WS-V）。
final class ManifestLabCodeMetricsTests: ManifestLabTestCase {
    // MARK: - 3. 代码规模 / 复杂度 / 重复

    func testCodeMetricsOnKnownMarkersHugeFilesAndClones() async throws {
        let code = try await FileSystemCodeAnalyzer().analyze(root: root, options: .default)

        print("=== WS-F 夹具 · 代码实测 ===")
        print("文件 \(code.totalFiles) 总行 \(code.totalLines) 码 \(code.codeLines)"
            + " 注释 \(code.commentLines) 空 \(code.blankLines)"
            + " TODO=\(code.todoCount)(期望 7) FIXME=\(code.fixmeCount)(期望 3)")
        print("语言分布：" + code.languages.map { "\($0.language):\($0.fileCount)文件/\($0.lineCount)行" }
            .joined(separator: " "))
        print("最大文件 \(code.largestFileLineCount) 行  巨大文件 \(code.hugeFiles.count) 个")
        for hotspot in code.hugeFiles.prefix(5) {
            print("  \(hotspot.risk.rawValue) \(hotspot.path.replacingOccurrences(of: root.path, with: "")) \(hotspot.lineCount)")
        }
        print("热点函数 \(code.topComplexFunctions.count) 个，前 5：")
        for hotspot in code.topComplexFunctions.prefix(5) {
            print("  CC=\(hotspot.cyclomaticComplexity) \(hotspot.name) \(hotspot.lineCount) 行"
                + " 参数 \(hotspot.parameterCount) [\(hotspot.risk.rawValue)]"
                + " \(hotspot.filePath.replacingOccurrences(of: root.path, with: "")):\(hotspot.startLine)")
        }
        print("重复率 \(String(format: "%.4f", code.duplicationRatio)) 重复块 \(code.duplicatedBlocks.count)"
            + " 长函数 \(code.longFunctions) 均函数长 \(code.averageFunctionLength)"
            + " 整体风险 \(code.overallRisk.rawValue)")
        for block in code.duplicatedBlocks.prefix(4) {
            print("  块 \(block.lineCount) 行 相似度 \(String(format: "%.2f", block.similarity)) -> "
                + block.occurrences.map { "\($0.path.replacingOccurrences(of: root.path, with: "")):\($0.startLine)" }
                .joined(separator: " + "))
        }

        XCTAssertEqual(code.todoCount, 7, "TODO 是我写死的 7 个，测得不等就是漏数或多数")
        XCTAssertEqual(code.fixmeCount, 3, "FIXME 是我写死的 3 个")

        let userService = "src/main/java/com/acme/orders/UserService.java"
        XCTAssertEqual(code.largestFileLineCount, tree.lineCounts[userService],
                       "最大文件行数必须等于我写出的 UserService.java 行数")
        XCTAssertEqual(tree.lineCounts[userService], 1600, "夹具本身必须真造出 1600 行")
        XCTAssertEqual(code.hugeFiles.first?.path.hasSuffix("UserService.java"), true)
        XCTAssertEqual(code.hugeFiles.first?.lineCount, 1600)
        XCTAssertEqual(code.hugeFiles.first?.risk, .high, ">1500 行的文件要判成高风险")
        XCTAssertTrue(code.hugeFiles.contains { $0.path.hasSuffix("OrderOrchestrator.java") },
                      "430 行越过 400 门槛，必须进巨大文件榜")
        XCTAssertEqual(code.hugeFiles.count, 2, "只有两份文件越过 mediumFileLines=400（另两份各 120 行）")

        let java = try require(code.languages.first { $0.language == "Java" }, "语言分布必须认得 Java")
        XCTAssertEqual(java.fileCount, 5, "五份 .java 全部要计入")
        XCTAssertGreaterThan(java.lineCount, 100, "五份 .java 合计 2298 行，注释填充不进有效码，但真代码必须在")
        XCTAssertGreaterThan(code.commentLines, 1600, "两份撑行数的文件把注释量抬起来")
        XCTAssertEqual(code.primaryLanguage, "Java")
        for language in ["Swift", "Go", "Rust", "Python", "TypeScript", "Kotlin", "Gradle", "XML", "JSON", "TOML"] {
            XCTAssertTrue(code.languages.contains { $0.language == language }, "缺语言 \(language)")
        }

        let route = try require(code.topComplexFunctions.first { $0.name.contains("routeOrder") },
                                "热点榜里必须找得到 routeOrder（实得 \(code.topComplexFunctions.map(\.name))）")
        XCTAssertGreaterThanOrEqual(route.cyclomaticComplexity, 15, "手写 ≥15 的嵌套分支必须堆出来")
        XCTAssertTrue(route.filePath.hasSuffix("OrderOrchestrator.java"))
        XCTAssertEqual(route.parameterCount, 2, "routeOrder(Order, List) 两个参数")
        XCTAssertGreaterThan(route.lineCount, 30)

        XCTAssertGreaterThan(code.duplicationRatio, 0, "两文件各一份的 16 行复制块必须被识别")
        XCTAssertLessThan(code.duplicationRatio, 0.2, "夹具里只有两处真克隆，比率被抬高说明指纹通道过松")
        XCTAssertFalse(code.duplicatedBlocks.isEmpty)
        func blockPair(_ lhs: String, _ rhs: String) -> DuplicatedBlock? {
            code.duplicatedBlocks.first { block in
                let paths = Set(block.occurrences.map { ($0.path as NSString).lastPathComponent })
                return paths.isSuperset(of: [lhs, rhs])
            }
        }
        // 刻意埋的两处克隆：Java 侧 16 行逐字相同；两份模块 pom.xml 的骨架同构（type-2）
        let clonedPair = blockPair("PricingRules.java", "BillingRules.java")
        XCTAssertNotNil(clonedPair, "PricingRules/BillingRules 的逐行相同块要出现在重复块里")
        XCTAssertGreaterThanOrEqual(clonedPair?.lineCount ?? 0, 10,
                                    "实得 \(clonedPair?.lineCount ?? 0) 行（16 行源码去掉空行与纯标点行）")
        XCTAssertNotNil(blockPair("pom.xml", "pom.xml") ?? blockPair("orders-api", "orders-service"),
                        "两份模块 pom 的同构骨架也该被认出来，实得 \(code.duplicatedBlocks.map(\.id))")
        print("两处设计克隆：Java 块 \(clonedPair?.lineCount ?? 0) 行"
            + " pom 块 \(blockPair("pom.xml", "pom.xml")?.lineCount ?? 0) 行")

        // 全仓平均圈复杂度（WS-A f55e4a0 修好后的回归护栏）：
        // 分母是被识别出的函数数，均值 = 49/18。
        // 手算账本（逐函数照夹具正文数分支，1 基准 + 判定构造）：
        //   Java 9 个：routeOrder 17、currentLane 3、lookup 3、clampLimit 3、clampLimit 3、
        //             validate 2、loadPrice 2、charge 2(catch)、Order 构造 1
        //   Go   2 个：main 3(for+if)、CurrentState 2(if)
        //   Swift 2 个：init 1、describe(using:) 1
        //   Rust 2 个：lane_weight 2(match)、main 1
        //   Python 2 个：is_low 1、reorder_point 1
        //   TypeScript 1 个：summarize 1
        //   ——合计 18 个函数、49 点。单行函数（`public long id() { return id; }`、
        //   `func New() *Reader { return &Reader{} }` 等 7 个）被 ComplexityEngine 的
        //   minFunctionLines = 2 挡在分母之外，这也是口径的一部分，钉在这里。
        XCTAssertEqual(code.analyzedFunctionCount, 18, "被识别函数数必须等于手算账本 18")
        XCTAssertEqual(code.topComplexFunctions.count, code.analyzedFunctionCount,
                       "夹具函数总数低于榜单上限 20，热点榜就是全量，两者必须相等")
        let mean = try require(code.averageCyclomaticComplexity, "均值不得再是 nil")
        XCTAssertEqual(mean, 49.0 / 18.0, accuracy: 1e-9,
                       "全仓均值必须等于手算的 49/18=2.7222…，不得拿热点榜均值顶替")
        XCTAssertTrue(code.overallRisk >= .low)
    }

}
