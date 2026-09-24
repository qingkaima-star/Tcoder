/// OWNER: R47（检测正确性整改轮 · RD-79 第二根因）—— 箭头**表达式体**（不带花括号的函数）的边界与分母。
///
/// 三条用例都是**手写夹具逐行数出来的独立真值**，不引用任何外部仓库的读数（AGENTS §8 第 1 条）。
/// 修前的原始读数记在台账卷五：`const add = (a, b) => a + b` 后面跟着对象字面量时，
/// 1 行的箭头被记成 4 行的函数，而那个对象里的真方法整段不再被扫到。
import Foundation
import XCTest
@testable import TcoderMonitor

extension CodeAnalyzerTests {

    /// RD-79 核心回归：不带花括号的箭头体**不许**去接下一条语句的 `{`。
    /// 一条假条目 + 一处漏报同源 —— 扫描线 `cursor = endLine + 1` 一步跨过被吃掉的区间。
    func testArrowExpressionBodyDoesNotStealTheNextStatementsBlock() throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        let objectCase = "const add = (a, b) => a + b\n"
            + "const config = {\n"
            + "    retries: 2\n"
            + "}\n"
        let objectFile = try XCTUnwrap(classify(try write(objectCase, to: "object.js", in: root), root: root))
        let objectOutcome = ComplexityEngine.functionsWithIntegrity(in: objectFile)
        XCTAssertTrue(objectOutcome.candidates.isEmpty,
                      "1 行的箭头与对象字面量都不是函数，实测 \(objectOutcome.candidates.map(\.name))")
        XCTAssertEqual(objectOutcome.unboundedSignatureCount, 0,
                       "边界推得出来就不许报「推不出来」，实测 \(objectOutcome.unboundedSignatureCount)")

        let swallowing = "const add = (a, b) => a + b\n"
            + "const handlers = {\n"
            + "    onSave() {\n"
            + "        if (value > 1) {\n"
            + "            return 1\n"
            + "        }\n"
            + "        return 0\n"
            + "    }\n"
            + "}\n"
        let file = try XCTUnwrap(classify(try write(swallowing, to: "handlers.js", in: root), root: root))
        let methods = ComplexityEngine.functions(in: file)
        XCTAssertFalse(methods.contains { $0.startLine == 1 },
                       "第 1 行的箭头不得成为条目（修前它是那条 8 行假函数）")
        XCTAssertEqual(methods.count, 1, "对象字面量里那个真方法必须被扫到，实测 \(methods.map(\.name))")
        let onSave = try XCTUnwrap(methods.first)
        XCTAssertEqual(onSave.startLine, 3, "onSave 的签名在第 3 行")
        XCTAssertEqual(onSave.lineCount, 6, "体是第 3~8 行")
        XCTAssertEqual(onSave.complexity, 2, "1 基准 + 1 个 if")
    }

    /// RD-79 补齐的那一半：**铺开成几行**的表达式体要进分母（点号链、三元换行、逐行参数表）。
    func testUnbracedArrowBodySpanningLinesIsCounted() throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        let chain = "export const labelOf = (items) => items\n"
            + "    .filter((item) => item.ok)\n"
            + "    .map((item) => item.name)\n"
        let chainFile = try XCTUnwrap(classify(try write(chain, to: "chain.ts", in: root), root: root))
        let chainFunctions = ComplexityEngine.functions(in: chainFile)
        XCTAssertEqual(chainFunctions.map(\.name), ["labelOf"], "点号链体要被认出来，实测 \(chainFunctions.map(\.name))")
        XCTAssertEqual(chainFunctions.first?.lineCount, 3, "体是 3 行")
        XCTAssertEqual(chainFunctions.first?.parameterCount, 1, "参数只认签名那一段的 (items)")
        XCTAssertEqual(chainFunctions.first?.complexity, 1, "链上没有分支构造，CC 就是基准 1")

        // 三元换行：体认得对（3 行），但 CC 少算一档 —— 三元那把尺子是逐行数问号的，
        // 要求「? 后面同一行还得有冒号」才算一次判定（ComplexityCounting.countsAsTernary）。
        // 下面那条同一行的正例是这一组的反证：形状没变、只是换了行，CC 从 2 掉到 1。
        // 这条限度另立 RD-80 并写进 docs/口径与已知限制.md §4.7，不许读成「三元没分支」。
        let ternary = "const verdict = (score) => score > 90\n"
            + "    ? 'high'\n"
            + "    : 'low'\n"
        let ternaryFile = try XCTUnwrap(classify(try write(ternary, to: "verdict.js", in: root), root: root))
        let ternaryFunctions = ComplexityEngine.functions(in: ternaryFile)
        XCTAssertEqual(ternaryFunctions.map(\.name), ["verdict"], "三元换行的体要被认出来")
        XCTAssertEqual(ternaryFunctions.first?.lineCount, 3, "体是 3 行")
        XCTAssertEqual(ternaryFunctions.first?.complexity, 1, "RD-80：跨行三元目前不计判定（同行正例见下一条）")

        let sameLineTernary = "const verdict = (score) => {\n"
            + "    const lane = score > 90 ? 'high' : 'low'\n"
            + "    return lane\n"
            + "}\n"
        let sameLineFile = try XCTUnwrap(classify(try write(sameLineTernary, to: "lane.js", in: root), root: root))
        XCTAssertEqual(ComplexityEngine.functions(in: sameLineFile).first?.complexity, 2,
                       "同一行写完的三元必须计一次判定 —— 上面少算不是尺子坏了")

        let params = "const sum = (\n    a,\n    b\n) => a + b\n"
        let paramsFile = try XCTUnwrap(classify(try write(params, to: "sum.js", in: root), root: root))
        let paramsFunctions = ComplexityEngine.functions(in: paramsFile)
        XCTAssertEqual(paramsFunctions.map(\.name), ["sum"], "逐行参数表的箭头也要被认出来")
        XCTAssertEqual(paramsFunctions.first?.parameterCount, 2, "参数表跨行也必须数到 2 个入参")
    }

    /// 反例与限度：带花括号的体画法一字不改；单行表达式体**仍然**不进分母 ——
    /// 那不是箭头特有的规则，`minFunctionLines = 2` 是全语言口径
    /// （同一条钉在 `testCodeMetricsOnKnownMarkersHugeFilesAndClones` 的手算账本里：Go 的单行函数同样不进）。
    func testBracedArrowBodiesKeepWorkingAndSingleLineOnesStayExcluded() throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        let wrapped = "export const pointOf = (raw) => ({\n"
            + "    x: raw.x,\n"
            + "    y: raw.y,\n"
            + "})\n"
        let wrappedFile = try XCTUnwrap(classify(try write(wrapped, to: "wrapped.js", in: root), root: root))
        let wrappedFunctions = ComplexityEngine.functions(in: wrappedFile)
        XCTAssertEqual(wrappedFunctions.map(\.name), ["pointOf"], "括号包对象字面量的箭头体照旧认出")
        XCTAssertEqual(wrappedFunctions.first?.lineCount, 4, "修前后都必须是 4 行")

        // 对象字面量里的属性箭头：体只有 1 行，`key: (x) => x + 1,` 行尾那个逗号
        // 是**对象语法**的分隔符、不是「本行没说完」，不许把下一行并进来。
        let property = "const table = {\n"
            + "    key: (x) => x + 1,\n"
            + "    other: 2\n"
            + "}\n"
        let propertyFile = try XCTUnwrap(classify(try write(property, to: "table.js", in: root), root: root))
        XCTAssertTrue(ComplexityEngine.functions(in: propertyFile).isEmpty,
                      "单行属性箭头不进分母，也不许把 `other: 2` 吃进体里")

        for (name, text) in [("oneline.js", "const add = (a, b) => a + b\n"),
                             ("oneline.go", "package main\n\nfunc one(a int) int { return a }\n")] {
            let file = try XCTUnwrap(classify(try write(text, to: name, in: root), root: root))
            XCTAssertTrue(ComplexityEngine.functions(in: file).isEmpty,
                          "\(name)：单行函数按 minFunctionLines 口径不进分母")
        }
    }

    /// 反向自证（新加的闸门不许回头咬真函数）：返回类型另起一行写的 Swift 签名必须照常带体。
    /// 这条是修完当场被**本仓自扫**抓到的：加上语句上界之后，
    /// `static func buildIndex(files: …)` 换行 `-> (…) {` 这一族在本仓一度被误杀 20 多处
    /// （X3 普查读数 3069 → 3053），修法是给「下一行开头」补 `-` 与 `>` 两个续行符。
    func testMultilineSignatureWithReturnOnItsOwnLineKeepsItsBody() throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        let body = """
        final class Reader {
            static func buildIndex(files: [Int], total: Int)
                -> (scan: [Int], capped: Int) {
                if total > 1 {
                    return (files, 0)
                }
                return ([], 1)
            }
        }
        """
        let file = try XCTUnwrap(classify(try write(body + "\n", to: "Reader.swift", in: root), root: root))
        let functions = ComplexityEngine.functions(in: file)
        XCTAssertEqual(functions.map(\.name), ["buildIndex"], "返回类型换行不得把真函数判没，实测 \(functions.map(\.name))")
        XCTAssertEqual(functions.first?.startLine, 2, "签名从第 2 行起")
        XCTAssertEqual(functions.first?.lineCount, 7, "体是第 2~8 行")
        XCTAssertEqual(functions.first?.parameterCount, 2, "两个入参")
        XCTAssertEqual(functions.first?.complexity, 2, "1 基准 + 1 个 if")
    }
}
