import XCTest
@testable import TcoderMonitor

/// OWNER: R2（Vue / TS 识别与模板字符串）—— **「配不平 / 判不准 / 放弃了多少行」必须出声**（RD-06 的未知态半边）。
///
/// 这个文件是反证矩阵量出来的产物，不是先写实现再补的样板：
/// `.scratch/sabotage2.py` 把 `unboundedSignatureCount` / `regexLikeUnterminated` /
/// `untrustedDepthLineCount` / `expressionUnderflow` / `unbalancedExpressions`
/// 五处出声**逐条单独摘掉**重跑，头一遍**五条全绿** ——
/// 也就是"未知态"这一头当时只有实现、一条判据都没有（摘掉没人喊）。
/// 这里一处一条把它钉住。
///
/// 两条写法上的规矩，都是从本仓今天踩过的坑来的：
/// 1. **每例都配"合法写法不得出声"的反向 twin** —— 只钉正向的判据可以靠"整行都不数"蒙过去；
/// 2. **夹具一律内联字符串数组、不用 Swift 三引号多行字面量** ——
///    多行字面量里一个不配对的定界符会让本文件在 `X3TestSizeAuditTests` 那把尺子下
///    长出一条吞掉后续行的假函数（AGENTS §8 第 2 条点名的同一件事）。
final class TsLexicalVoiceTests: XCTestCase {

    /// 与产品同一个 `SourceLineWalker` 落行桶，走 `functionsWithIntegrity` 这条真路径。
    private func makeFile(_ name: String, _ lines: [String], language: String = "TypeScript")
        -> ScannedSourceFile {
        var walker = SourceLineWalker(language: language)
        var sourceLines: [SourceLine] = []
        var blank = 0, comment = 0, code = 0
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
        return ScannedSourceFile(url: URL(fileURLWithPath: "/r2-voice/\(name)"), relativePath: name,
                                 language: language, lines: sourceLines,
                                 blankLineCount: blank, commentLineCount: comment, codeLineCount: code,
                                 todoCount: 0, fixmeCount: 0)
    }

    private func scan(_ name: String, _ lines: [String]) -> ComplexityEngine.FunctionScanOutcome {
        ComplexityEngine.functionsWithIntegrity(in: makeFile(name, lines))
    }

    private func voiced(_ outcome: ComplexityEngine.FunctionScanOutcome, _ needle: String) -> Bool {
        outcome.limitations.contains { $0.contains(needle) }
    }

    // MARK: - 1. 命中签名但边界推不出来（L）

    /// HEAD 的形状：放弃的候选与"这行不是函数"在报告里长得一模一样 ⇒ 文件读起来像"没有函数"。
    func testUnboundedSignatureIsVoiced() throws {
        let broken = ["function unclosed(a: number): number {",
                      "  if (a > 0) {",
                      "    return a",
                      "  }"]
        let outcome = scan("unclosed.ts", broken)
        XCTAssertEqual(outcome.candidates.count, 0, "边界推不出来的函数不许硬凑一条候选")
        XCTAssertEqual(outcome.unboundedSignatureCount, 1,
                       "放弃了候选必须计数，实测 \(outcome.unboundedSignatureCount)")
        XCTAssertTrue(voiced(outcome, "边界推不出来"),
                      "限制说明要点名边界推不出来：\(outcome.limitations)")

        var fixed = broken
        fixed.append("}")
        let ok = scan("closed.ts", fixed)
        XCTAssertEqual(ok.candidates.map(\.name), ["unclosed"], "补上收尾花括号必须照常识别")
        XCTAssertEqual(ok.unboundedSignatureCount, 0, "合法写法不得出声（误伤 = 守卫不可信）")
        XCTAssertEqual(ok.limitations, [], "没有异常时限制说明必须是空：\(ok.limitations)")
    }

    // MARK: - 2. 形似正则而本行内不闭合（Q）

    /// 判不准只许退回普通字符（绝不吞行），但**"这一格判不准"本身要落进读数**。
    func testUnterminatedRegexLikeSlashIsVoiced() throws {
        let outcome = scan("regex.ts", ["function afterSlash(n: number): number {",
                                        "  const broken = /没有收尾的正则",
                                        "  if (n > 0) { return n }",
                                        "  return 0",
                                        "}"])
        XCTAssertGreaterThan(outcome.integrity.regexLikeUnterminated, 0,
                             "像正则起点却配不上尾的 `/` 必须留名")
        XCTAssertTrue(voiced(outcome, "正则"),
                      "限制说明里要写清是正则这一档判不准：\(outcome.limitations)")
        XCTAssertEqual(outcome.candidates.map(\.name), ["afterSlash"],
                       "判不准不许把后面 3 行吞掉：\(outcome.candidates.map(\.name))")

        let clean = scan("div.ts", ["function div(total: number, count: number): number {",
                                    "  const ratio = total / count",
                                    "  return ratio",
                                    "}"])
        XCTAssertEqual(clean.integrity.regexLikeUnterminated, 0, "真除法不得当成「形似正则」")
        XCTAssertEqual(clean.candidates.map(\.name), ["div"], "真除法那行不许影响识别")
        XCTAssertEqual(clean.limitations, [], "没有异常时不得编出限制说明：\(clean.limitations)")
    }

    // MARK: - 3. 花括号深度跌破 -3（R）

    /// 跌破之后的签名一律放弃 —— 放弃是对的，**不说放弃了多少行**才是缺陷。
    func testDepthCollapseBelowMinusThreeIsVoiced() throws {
        let lines = ["}", "}", "}", "}", "}",
                     "function afterNoise(a: number): number {",
                     "  if (a > 0) { return a }",
                     "  return 0",
                     "}"]
        let outcome = scan("noise.ts", lines)
        XCTAssertLessThan(outcome.integrity.lowestBracePrefix, -3,
                         "夹具没让深度真的跌破 -3（实测 \(outcome.integrity.lowestBracePrefix)）⇒ 用例在空转")
        XCTAssertGreaterThan(outcome.integrity.untrustedDepthLineCount, 0, "不可信的行数必须留名")
        XCTAssertTrue(voiced(outcome, "跌破"),
                      "必须说明这些行的边界不可信：\(outcome.limitations)")
        XCTAssertEqual(outcome.candidates.count, 0, "深度不可信时不许硬推边界")

        let clean = scan("quiet.ts", Array(lines.dropFirst(5)))
        XCTAssertEqual(clean.integrity.untrustedDepthLineCount, 0, "正常文件不得报不可信")
        XCTAssertEqual(clean.candidates.map(\.name), ["afterNoise"])
    }

    // MARK: - 4. 插值里出现配不上的闭括号（S）

    /// `${ a) }`：括号跌破 0 会被夹住（否则后面的深度全废），但跌破这件事**必须留名**。
    func testInterpolationBracketUnderflowIsVoiced() throws {
        let outcome = scan("underflow.ts", ["const s = `x ${ a) } y`",
                                            "function afterParen(n: number): number {",
                                            "  if (n > 0) { return n }",
                                            "  return 0",
                                            "}"])
        XCTAssertEqual(outcome.integrity.expressionUnderflow, 1,
                       "插值里多余的闭括号要计数，实测 \(outcome.integrity.expressionUnderflow)")
        XCTAssertTrue(voiced(outcome, "配不平"),
                      "限制说明要点名插值配不平：\(outcome.limitations)")
        XCTAssertEqual(outcome.candidates.map(\.name), ["afterParen"],
                       "夹住深度之后不许吞行：\(outcome.candidates.map(\.name))")

        // twin 里插值只写 `a + 1`，**不写圆括号**：`const s = \`x ${ (a) } y\`` 清洗完是
        // `const s = (a)`，会被 JS/TS 的签名模式当函数命中又推不出边界 ⇒ 凭空报一条
        // "1 处函数签名命中后边界推不出来"（本轮实测，见交回汇报的新发现；
        // 根在 `FunctionPatterns.jsVariableArrow`，R1 名下、与 RD-38 同一个收敛口）。
        // 拿它当"合法写法"的期望等于把误报冻结成契约，所以这里避开这个形状。
        let clean = scan("paired.ts", ["const s = `x ${ a + 1 } y`",
                                       "function afterParen(n: number): number {",
                                       "  return n",
                                       "}"])
        XCTAssertEqual(clean.integrity.expressionUnderflow, 0, "配平的圆括号不得报跌破")
        XCTAssertEqual(clean.integrity.unbalancedExpressions, 0, "配平的插值不得报未配平")
        XCTAssertEqual(clean.limitations, [], "没有异常时不得出声：\(clean.limitations)")
    }

    // MARK: - 5. 文件读完时插值里还剩未配的括号（T）

    /// 串到文件尾仍在插值里、且插值里 `{` 没配平：两处读数都要有，少一处就有一处没人守。
    func testInterpolationUnbalancedAtEndOfFileIsVoiced() throws {
        let outcome = scan("unbalanced.ts", ["const s = `x ${ { a: 1",
                                             "function afterBrace(n: number): number {",
                                             "  return n",
                                             "}"])
        XCTAssertGreaterThan(outcome.integrity.endsInsideExpression, 0, "插值帧未弹出必须留名")
        XCTAssertGreaterThan(outcome.integrity.unbalancedExpressions, 0,
                             "插值里剩下的 `{` 必须单独计数，实测 \(outcome.integrity.unbalancedExpressions)")
        XCTAssertTrue(voiced(outcome, "仍未闭合"),
                      "必须说清是到文件末尾仍未闭合：\(outcome.limitations)")
        XCTAssertTrue(voiced(outcome, "配不平"),
                      "必须说清这些行的函数边界不可信：\(outcome.limitations)")

        let clean = scan("closed-interp.ts", ["const s = `x ${ { a: 1 }.a }`",
                                              "function afterBrace(n: number): number {",
                                              "  return n",
                                              "}"])
        XCTAssertEqual(clean.integrity.unbalancedExpressions, 0, "配平的插值不得报未配平")
        XCTAssertEqual(clean.integrity.endsInsideExpression, 0, "闭合的插值不得报未闭合")
    }
}
