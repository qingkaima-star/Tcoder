import XCTest
@testable import TcoderMonitor

/// OWNER: R2（Vue / TS 识别与模板字符串）—— **嵌套复杂度口径**（RD-08）与「最长函数」真值（RD-05）。
///
/// 本文件断言的口径（写在实现注释里、也在这里钉住）：
/// * 一条条目 = 一个具名函数，`complexity` 只算**它自己那部分体**（直接嵌套的子函数体已按行挖掉）；
/// * 子函数**自己单列一条**，不再因为"外层扫到了它的行"就消失；
/// * 全文件所有条目的判定分支之和 == 源码里真实分支数（不重、不漏）——
///   这条是"合并计数 + 内层条目消失"那种形状唯一能藏住身的地方，所以按分母对账来堵。
///
/// 期望表全部手算（每个夹具上面写了算式），不是 `ComplexityEngine` 的现输出。
final class TsNestedComplexityCaliberTests: XCTestCase {

    private func makeFile(_ name: String, language: String, _ lines: [String]) -> ScannedSourceFile {
        var walker = SourceLineWalker(language: language)
        var sourceLines: [SourceLine] = []
        var blank = 0
        var comment = 0
        var code = 0
        for (offset, text) in lines.enumerated() {
            var characters = Array(text)
            let kind = walker.kind(for: &characters)
            switch kind {
            case .blank: blank += 1
            case .comment: comment += 1
            case .code: code += 1
            }
            sourceLines.append(SourceLine(number: offset + 1, text: text, kind: kind))
        }
        return ScannedSourceFile(url: URL(fileURLWithPath: "/r2-fixture/\(name)"), relativePath: name,
                                 language: language, lines: sourceLines,
                                 blankLineCount: blank, commentLineCount: comment, codeLineCount: code,
                                 todoCount: 0, fixmeCount: 0)
    }

    private func describe(_ candidates: [FunctionCandidate]) -> [String] {
        candidates.map { "\($0.name)@\($0.startLine)..\($0.startLine + $0.lineCount - 1)cc\($0.complexity)" }
    }

    // MARK: - 嵌套具名函数：各计自己的体
    //
    // 手算真值（源码里一共两个 `if`，一个都没有 && / 三元）：
    //   innerCount（2...7）自己的体里有 `if` ⇒ CC = 1 + 1 = 2
    //   outerFlag （1...12）自己的体（把 2...7 挖掉之后）里有 `if` ⇒ CC = 1 + 1 = 2
    //   合并计数会得到 3 —— 那正是被否掉的那条路，本用例反面钉住它。
    func testNestedNamedFunctionGetsItsOwnEntryAndItsOwnBody() {
        let fixture = [
            /* 1 */ "function outerFlag(items: number[]): number {",
            /* 2 */ "  function innerCount(list: number[]): number {",
            /* 3 */ "    if (list.length > 0) {",
            /* 4 */ "      return list.length",
            /* 5 */ "    }",
            /* 6 */ "    return 0",
            /* 7 */ "  }",
            /* 8 */ "  if (items.length > 3) {",
            /* 9 */ "    return innerCount(items)",
            /* 10 */ "  }",
            /* 11 */ "  return innerCount([])",
            /* 12 */ "}",
        ]
        let detected = ComplexityEngine.functions(in: makeFile("nest.ts", language: "TypeScript", fixture))
        XCTAssertEqual(describe(detected), ["outerFlag@1..12cc2", "innerCount@2..7cc2"],
                       "外层与内层必须各计自己的体：\(describe(detected))")
        let outer = detected[0]
        XCTAssertNotEqual(outer.complexity, 3, "「合并内外层」的数字不许再叫单个函数的独立复杂度")
        XCTAssertEqual(outer.nestedFunctionCount, 1, "外层要能看出自己还包了一个单列的函数")
        XCTAssertEqual(detected.reduce(0) { $0 + $1.complexity - 1 }, 2,
                       "全文件判定分支之和必须正好等于源码里的 2 个 if（不重不漏）")
    }

    /// 箭头函数版：内层 `const innerOne = …` 也要单列，外层不许把它的 `if` 算进自己头上。
    func testNestedArrowFunctionIsNotMergedIntoOuter() {
        let fixture = [
            /* 1 */ "const outerRun = (): number => {",
            /* 2 */ "  const innerOne = (n: number): number => {",
            /* 3 */ "    if (n > 0) { return n }",
            /* 4 */ "    return 0",
            /* 5 */ "  }",
            /* 6 */ "  return innerOne(1)",
            /* 7 */ "}",
        ]
        let detected = ComplexityEngine.functions(in: makeFile("nest-arrow.ts", language: "TypeScript", fixture))
        XCTAssertEqual(describe(detected), ["outerRun@1..7cc1", "innerOne@2..5cc2"],
                       "内层箭头函数不得被外层吞掉：\(describe(detected))")
    }

    // MARK: - 深度上限：不再下钻时必须改口喊「含嵌套累计」

    /// 造 10 层嵌套具名函数。超过 `maxNestedFunctionScanDepth` 的那一层不再展开，
    /// 判据是：它**必须出声**（限制说明里写清"外层那条是含嵌套累计"），不许静默合并。
    func testDepthCapVoiceSaysCumulative() throws {
        let depth = 10
        var fixture: [String] = []
        for level in 0..<depth {
            fixture.append(String(repeating: "  ", count: level) + "function level\(level)(): number {")
        }
        fixture.append(String(repeating: "  ", count: depth) + "if (deepFlag) { return 1 }")
        for level in stride(from: depth - 1, through: 0, by: -1) {
            fixture.append(String(repeating: "  ", count: level) + "}")
        }
        let outcome = ComplexityEngine.functionsWithIntegrity(
            in: makeFile("deep.ts", language: "TypeScript", fixture))
        XCTAssertGreaterThan(outcome.nestedDepthTruncatedCount, 0, "超过深度上限必须计数")
        XCTAssertTrue(outcome.limitations.contains { $0.contains("含嵌套累计") },
                      "最深那条的口径必须被说成含嵌套累计：\(outcome.limitations)")
        XCTAssertEqual(outcome.candidates.count, ComplexityEngine.maxNestedFunctionScanDepth + 1,
                       "深度上限之内每层都该单列一条")
        // 并进去的是**最深那条**（不是跨度最大的外层）：外层已经把自己的子层挖干净了。
        let deepest = try XCTUnwrap(outcome.candidates.max { $0.startLine < $1.startLine })
        XCTAssertEqual(deepest.name, "level\(ComplexityEngine.maxNestedFunctionScanDepth)",
                       "最后单列出来的那条应该是深度上限这一层")
        XCTAssertEqual(deepest.complexity, 2,
                       "超过上限的那个 if 必须并进最深这条，并且这条的口径要在限制里改口喊累计")
    }

    // MARK: - RD-05 的另一半：最长函数不许被报成 46 行

    /// 合成一个 900 行的具名函数：识别结果必须给出**真实跨度 900**，
    /// 而不是因为它内部有一个未配对的构造就退化成"最长的只有 46 行"。
    func testNineHundredLineNamedFunctionIsReportedAtFullSpan() {
        var fixture = ["function giantNamed(index: number): number {"]
        fixture.append("  if (index > 1) { return 1 }")
        fixture.append("  if (index > 2) { return 2 }")
        fixture.append("  if (index > 3) { return 3 }")
        // 体里塞一行模板串，证明长跨度与 RD-06 的修复同时成立（旧状态机在这里就会把后面吃光）
        fixture.append("  const note = `第 ${index} 号 · 备注`")
        let fillerCount = 900 - fixture.count - 1
        fixture.append(contentsOf: Array(repeating: "  let filler = index + 1", count: fillerCount))
        fixture.append("}")
        fixture.append("function afterGiant(step: number): number {")
        fixture.append("  if (step > 0) { return step }")
        fixture.append("  return 0")
        fixture.append("}")
        XCTAssertEqual(fixture.count, 904, "夹具本身要正好 900 行函数 + 4 行尾巴")

        let detected = ComplexityEngine.functions(in: makeFile("giant.ts", language: "TypeScript", fixture))
        XCTAssertEqual(detected.map(\.name), ["giantNamed", "afterGiant"],
                       "900 行函数之后那条必须还在：\(detected.map(\.name))")
        let giant = detected[0]
        XCTAssertEqual(giant.startLine, 1)
        XCTAssertEqual(giant.lineCount, 900, "最长函数报成 \(giant.lineCount) 行，真值 900")
        XCTAssertGreaterThan(giant.lineCount, 46, "「最长函数 46 行」这类结论就是漏报撑出来的")
        XCTAssertEqual(giant.complexity, 4, "基线 1 + 三个 if；模板串里的 ${} 不是分支")
        XCTAssertEqual(detected[1].lineCount, 4)
    }

    /// 反证用的"合法形状"钉子：900 行这个量级不是只对内联字符串成立，
    /// 走真文件系统分类器同样要是 900。
    func testGiantSpanSurvivesRealClassifier() throws {
        var fixture = ["function giantViaDisk(index: number): number {"]
        fixture.append(contentsOf: Array(repeating: "  let filler = index + 1", count: 897))
        fixture.append("}")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("r2-giant-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Giant.ts")
        try Data((fixture.joined(separator: "\n") + "\n").utf8).write(to: url)
        let file = try XCTUnwrap(SourceFileClassifier(options: .default).classify(url: url, root: root))
        let detected = ComplexityEngine.functions(in: file)
        XCTAssertEqual(detected.map { "\($0.name):\($0.lineCount)" }, ["giantViaDisk:899"],
                       "分类器路径下跨度必须一致：\(describe(detected))")
    }
}
