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

        // RD-80（已修）：三元换行以前少算一档 —— 逐行的尺子要求「`?` 后面同一行还得有冒号」
        // （`ComplexityCounting.countsAsTernary`），于是 `? a` 换行 `: b` 读成 CC 1、
        // 同一行写完读成 CC 2：**形状没变、只是换了行，数就变了**。
        // 现在两行的写法与一行写完必须给同一个数（下面那组同行正例就是这一条的独立真值）。
        let ternary = "const verdict = (score) => score > 90\n"
            + "    ? 'high'\n"
            + "    : 'low'\n"
        let ternaryFile = try XCTUnwrap(classify(try write(ternary, to: "verdict.js", in: root), root: root))
        let ternaryFunctions = ComplexityEngine.functions(in: ternaryFile)
        XCTAssertEqual(ternaryFunctions.map(\.name), ["verdict"], "三元换行的体要被认出来")
        XCTAssertEqual(ternaryFunctions.first?.lineCount, 3, "体是 3 行")
        XCTAssertEqual(ternaryFunctions.first?.complexity, 2,
                       "RD-80：跨行三元与同行写法必须同分（配不到就不加是下一条反例的事）")

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

    /// 文件作用域的原型声明后面跟着一个**不是签名**的 `{`（这里是 `struct Flags {`）时，
    /// 旧路径会把它当自己的体 ⇒ 产出一条跨越第 1~5 行的假函数 `open`。
    /// 独立真值 = 这份夹具里只有 `helper` 是一个函数体（第 7~9 行）。
    /// 交付二进制实测（台账卷六 §93 补记三）：原型为主的总体量到 0 个函数时，
    /// 评分侧把「复杂度」整维判为**缺席**（不按 0 计、也不给满分）⇒ 这一格钉的是「不产假条目」那一半。
    func testCFileScopePrototypeDoesNotAdoptTheNextBlocksBrace() throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        let source = "int open(const char *path);\n"
            + "\n"
            + "struct Flags {\n"
            + "    int a;\n"
            + "};\n"
            + "\n"
            + "static int helper(void) {\n"
            + "    return 0\n"
            + "}\n"
        let file = try XCTUnwrap(classify(try write(source, to: "reader.c", in: root), root: root))
        let functions = ComplexityEngine.functions(in: file)
        XCTAssertEqual(functions.map(\.name), ["helper"],
                      "原型声明不得产假条目，实测 \(functions.map(\.name))")
        XCTAssertEqual(functions.first?.startLine, 7, "唯一的函数 helper 从第 7 行起")
        XCTAssertEqual(functions.first?.lineCount, 3, "体是第 7~9 行")
    }

    /// RD-80 的另一半：跨行三元**配到冒号**才补那一分，配不到、也只补一次。
    /// 独立真值 = 同一句话无论换不换行、`?` 写在行尾还是行首，读出来的 CC 都一样；
    /// 反例是可空返回类型那种"整行末尾一枚 `?`、下一行跟冒号毫无关系"的真形状。
    func testCrossLineTernaryCarryOnlyPaysWhenTheNextLineOpensWithColon() throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }

        // 正例 1：两层三元铺开成五行 ⇒ 基准 1 + 两次判定，且**每枚 `?` 只配一分**。
        let nested = "const grade = (s) => s > 90\n"
            + "    ? 'A'\n"
            + "    : s > 60\n"
            + "    ? 'B'\n"
            + "    : 'C'\n"
        let nestedFile = try XCTUnwrap(classify(try write(nested, to: "grade.js", in: root), root: root))
        let nestedFunctions = ComplexityEngine.functions(in: nestedFile)
        XCTAssertEqual(nestedFunctions.first?.complexity, 3,
                      "两枚跨行三元各补一分，实测 \(nestedFunctions.first?.complexity ?? -1)")

        // 正例 2：`?` 写在上一行行尾（operator-trailing 风格）也要配到下一行的冒号。
        let trailing = "const lane = (s) => s > 90 ? 'high'\n"
            + "    : 'low'\n"
        let trailingFile = try XCTUnwrap(classify(try write(trailing, to: "trail.js", in: root), root: root))
        XCTAssertEqual(ComplexityEngine.functions(in: trailingFile).first?.complexity, 2,
                      "换行位置换了、判定还是那一个 ⇒ 与同行写法同分（2）")

        // 反例：可空返回类型在行尾就是一枚"看起来像在等冒号"的 `?`，
        // 下一行是 `{` ⇒ 一分都不许补（这一枚 `?` 是类型，不是分支）。
        let nullable = "func readName() -> String?\n"
            + "{\n"
            + "    return nil\n"
            + "}\n"
        let nullableFile = try XCTUnwrap(classify(try write(nullable, to: "Name.swift", in: root), root: root))
        let nullableFunctions = ComplexityEngine.functions(in: nullableFile)
        XCTAssertEqual(nullableFunctions.map(\.name), ["readName"], "夹具本身要被认出来，实测 \(nullableFunctions.map(\.name))")
        XCTAssertEqual(nullableFunctions.first?.complexity, 1,
                      "可空类型换行不得被算成三元，实测 \(nullableFunctions.first?.complexity ?? -1)")
    }
}
