import XCTest
@testable import TcoderMonitor

/// OWNER: R2（Vue / TS 识别与模板字符串）—— **模板字符串词法状态机的独立真值夹具**（RD-06 / RD-05）。
///
/// 这一份文件是**先写期望、再看实现**的产物：每个夹具的行号、函数名、边界、圈复杂度
/// 都是按 TS 源码逐行手算出来的（手算过程写在每个夹具上面的算式里），
/// 不是把 `ComplexityEngine` 现在的输出抄回来当期望。
///
/// 夹具一律用**内联字符串**（不落 `.ts` / `.vue` 文件进仓库，避免自扫时把自己的夹具算进分母）；
/// `ScannedSourceFile` 直接按产品侧同一个 `SourceLineWalker` 落桶，
/// 走的是 `ComplexityEngine.functions(in:)` 这条真路径。
///
/// 禁则（AGENTS §8 第 1 条）：本文件不引用任何本机其它工程的读数。
final class TsTemplateLiteralRecognitionTests: XCTestCase {

    // MARK: - 夹具装配

    /// 用与产品相同的状态机给内联夹具落行桶（代码 / 注释 / 空行）。
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

    private func functions(_ name: String, _ lines: [String], language: String = "TypeScript")
        -> [FunctionCandidate] {
        ComplexityEngine.functions(in: makeFile(name, language: language, lines))
    }

    /// 把识别结果折成可比对的四元组字符串，一次断言替换掉四条。
    private func describe(_ candidates: [FunctionCandidate]) -> [String] {
        candidates.map {
            "\($0.name)@\($0.startLine)..\($0.startLine + $0.lineCount - 1)cc\($0.complexity)"
        }
    }

    // MARK: - 夹具 1：单层插值 `a${x}b`
    //
    // 手算真值：
    //   buildLabel（1...7）：基线 1 + `if`(1) + `&&`(1) = 3
    //   afterInterpolation（8...13）：基线 1 + `if`(1) = 2
    //   第 2 行是**模板串**：串内文字与收尾反引号都不是代码，不得吃掉第 3 行之后的任何一行。
    func testSingleInterpolationKeepsFollowingLines() {
        let fixture = [
            /* 1 */ "function buildLabel(name: string, flag: boolean): string {",
            /* 2 */ "  const text = `hi ${name}!`",
            /* 3 */ "  if (flag && name.length > 3) {",
            /* 4 */ "    return text",
            /* 5 */ "  }",
            /* 6 */ "  return \"plain\"",
            /* 7 */ "}",
            /* 8 */ "function afterInterpolation(x: number): number {",
            /* 9 */ "  if (x > 1) {",
            /* 10 */ "    return x + 1",
            /* 11 */ "  }",
            /* 12 */ "  return x",
            /* 13 */ "}",
        ]
        XCTAssertEqual(describe(functions("f1.ts", fixture)),
                       ["buildLabel@1..7cc3", "afterInterpolation@8..13cc2"],
                       "单层插值之后的两个函数都必须按手算边界与 CC 出现")
    }

    // MARK: - 夹具 2：对象字面量嵌在插值里
    //
    // 手算真值：
    //   renderUser（1...7）：基线 1 + `if`(1) + `&&`(1) = 3
    //   tailFn（8...13）：基线 1 + `if`(1) = 2
    //   第 2 行 `${ { level: 1 }.level }` 里的 `{` `}` 是一对**对象字面量**括号，
    //   既不得被当成插值闭合，也不得把外层的插值状态提前结束。
    func testObjectLiteralInsideInterpolation() {
        let fixture = [
            /* 1 */ "const renderUser = (user: User): string => {",
            /* 2 */ "  const badge = `${ { level: 1 }.level } 级`",
            /* 3 */ "  if (user.admin && badge.length > 0) {",
            /* 4 */ "    return badge",
            /* 5 */ "  }",
            /* 6 */ "  return \"\"",
            /* 7 */ "}",
            /* 8 */ "function tailFn(a: number): number {",
            /* 9 */ "  if (a > 0) {",
            /* 10 */ "    return a",
            /* 11 */ "  }",
            /* 12 */ "  return 0",
            /* 13 */ "}",
        ]
        let detected = functions("f2.ts", fixture)
        XCTAssertEqual(describe(detected), ["renderUser@1..7cc3", "tailFn@8..13cc2"],
                       "插值里的对象字面量不得吞掉后面的函数：\(detected.map(\.name))")
        // 分母钉子：插值行（第 2 行）之后的行必须**仍然被统计**
        let src = sanitized(fixture, "TypeScript")
        let opensAfterInterpolation = src.opens[2...].reduce(0, +)
        XCTAssertGreaterThan(opensAfterInterpolation, 0, "第 3 行之后一个花括号都没统计到 ⇒ 后续代码被整段吞掉")
        // 配平判据取**整份文件**：切片 `[2...]` 少算的是第 1 行那个开括号（renderUser 自己的 `{`），
        // 所以正确的不变式是「总数配平 + 文件末尾深度回到 0」，不是切片两侧相等。
        XCTAssertEqual(src.opens.reduce(0, +), src.closes.reduce(0, +),
                       "整份文件的花括号总数必须配平（插值行不许多算或少算一层）")
        XCTAssertEqual(src.prefix.last, 0,
                       "文件末尾花括号深度必须回到 0，实际 \(src.prefix.last ?? -999)")
    }

    // MARK: - 夹具 3：多层插值 `${ a ? `b${c}` : `d` }`
    //
    // 手算真值：
    //   nested（1...7）：基线 1 + 插值里的三元 `? `(1) + `if`(1) + `||`(1) = 4
    //     —— 插值表达式里的三元是**这个函数真跑过的判定分支**，计入本函数 CC；
    //   laterArrow（8...13）：基线 1 + `if`(1) = 2
    //   第 2 行有三对反引号（外层模板串 + 两个内层模板串）与两层插值，必须**逐层配平弹出**。
    func testNestedInterpolationStacksAndPops() {
        let fixture = [
            /* 1 */ "function nested(kind: string, ok: boolean): string {",
            /* 2 */ "  const label = `${ ok ? `b${kind}` : `d` }`",
            /* 3 */ "  if (kind === \"a\" || kind === \"b\") {",
            /* 4 */ "    return label",
            /* 5 */ "  }",
            /* 6 */ "  return \"\"",
            /* 7 */ "}",
            /* 8 */ "const laterArrow = (n: number): number => {",
            /* 9 */ "  if (n > 2) {",
            /* 10 */ "    return n * 2",
            /* 11 */ "  }",
            /* 12 */ "  return n",
            /* 13 */ "}",
        ]
        let detected = functions("f3.ts", fixture)
        XCTAssertEqual(describe(detected), ["nested@1..7cc4", "laterArrow@8..13cc2"],
                       "多层插值必须一层层配平，第 8 行那条函数不许消失：\(detected.map(\.name))")
        let src = sanitized(fixture, "TypeScript")
        XCTAssertFalse(src.cleaned[3].isEmpty, "插值之后的整行代码被当成串吃掉了：cleaned[4] = \"\(src.cleaned[3])\"")
        XCTAssertGreaterThan(src.opens[2...].reduce(0, +), 0, "第 3 行之后的花括号增量必须仍然产出（分母 > 0）")
    }

    // MARK: - 夹具 4：正则字面量里含反引号与 `${`
    //
    // 手算真值：
    //   usesTricky（2...7）：基线 1 + `if`(1) = 2
    //   secondFn（8...13）：基线 1 + `if`(1) = 2
    //   第 1 行的 `` /`.*\$\{(/ `` 是**正则字面量**：里面的反引号不是字符串开头、括号不是参数表，
    //   所以第 1 行既不是函数、也不得把词法状态带进「串里」。
    func testRegexLiteralWithBacktickAndInterpolationMarker() {
        let fixture = [
            /* 1 */ "const TRICKY = /`.*\\$\\{(/;",
            /* 2 */ "function usesTricky(n: number): number {",
            /* 3 */ "  if (n > 0) {",
            /* 4 */ "    return n;",
            /* 5 */ "  }",
            /* 6 */ "  return 0;",
            /* 7 */ "}",
            /* 8 */ "function secondFn(x: number): number {",
            /* 9 */ "  if (x > 1) {",
            /* 10 */ "    return x;",
            /* 11 */ "  }",
            /* 12 */ "  return 0;",
            /* 13 */ "}",
        ]
        let detected = functions("f4.ts", fixture)
        XCTAssertEqual(describe(detected), ["usesTricky@2..7cc2", "secondFn@8..13cc2"],
                       "正则字面量里的反引号不得开模板串：\(describe(detected))")
        XCTAssertFalse(detected.contains { $0.name.contains("TRICKY") },
                       "正则字面量那一行不许被认成函数声明")
    }

    // MARK: - 夹具 5：注释里含反引号与 `${`
    //
    // 手算真值：commented（2...8）CC 2；tailAfterComment（9...14）CC 2。
    //   第 1 行行注释、第 3 行块注释里的反引号都在注释里，不得进入字符串状态。
    func testBacktickInsideCommentsStaysComment() {
        let fixture = [
            /* 1 */ "// 行注释里有一个反引号 ` 和 ${name} 的花样",
            /* 2 */ "function commented(n: number): number {",
            /* 3 */ "  /* 块注释里也有 ` 反引号 */",
            /* 4 */ "  if (n > 0) {",
            /* 5 */ "    return n",
            /* 6 */ "  }",
            /* 7 */ "  return 0",
            /* 8 */ "}",
            /* 9 */ "function tailAfterComment(step: number): number {",
            /* 10 */ "  if (step > 0) {",
            /* 11 */ "    return step",
            /* 12 */ "  }",
            /* 13 */ "  return 0",
            /* 14 */ "}",
        ]
        XCTAssertEqual(describe(functions("f5.ts", fixture)),
                       ["commented@2..8cc2", "tailAfterComment@9..14cc2"],
                       "注释里的反引号不得开模板串")
    }

    // MARK: - 夹具 6：等价改写回归（普通字符串 → 模板字符串）
    //
    // 判据：把同一个函数体里的字符串改成模板写法之后，
    // **它自己和它后面那些函数一条都不许消失**，边界与 CC 一字不变。
    func testTemplateRewriteDoesNotDeleteFollowingFunctions() {
        let plain = [
            /* 1 */ "function reportName(user: User): string {",
            /* 2 */ "  const line = \"name: \" + user.name",
            /* 3 */ "  if (user.admin) {",
            /* 4 */ "    return \"admin \" + line",
            /* 5 */ "  }",
            /* 6 */ "  return line",
            /* 7 */ "}",
            /* 8 */ "function trailingCount(items: string[]): number {",
            /* 9 */ "  if (items.length > 0) {",
            /* 10 */ "    return items.length",
            /* 11 */ "  }",
            /* 12 */ "  return 0",
            /* 13 */ "}",
        ]
        var rewritten = plain
        rewritten[1] = "  const line = `name: ${user.name}`"
        rewritten[3] = "    return `admin ${line}`"
        XCTAssertEqual(rewritten.count, plain.count, "改写只动两行内容，行数必须一致")

        let before = describe(functions("equiv-plain.ts", plain))
        let after = describe(functions("equiv-template.ts", rewritten))
        XCTAssertEqual(after.count, 2, "模板写法版本必须仍然识别出 2 个函数，实际 \(after)")
        XCTAssertEqual(after, before, "同一函数换成模板字符串写法之后，条目/边界/CC 不许变：\(before) vs \(after)")
        XCTAssertEqual(before, ["reportName@1..7cc2", "trailingCount@8..13cc2"])
    }

    // MARK: - RD-06 直接钉子：结束反引号不会被重新当成开始反引号

    /// 一行里走完 `` `a${x}b` `` 之后，状态机必须回到「不在任何串里」：
    /// 收尾反引号是**闭合**，不是新开一个串。判据取下一行的花括号增量与 cleaned 文本，
    /// 因为「被当成串吃掉」在这两处的表现最稳定（下一行的 `{` 不再产出增量、cleaned 变空）。
    func testClosingBacktickIsNotReopenedAsOpeningBacktick() {
        let lines = [
            "const s = `a${x}b`",
            "const t = 1 + { beta: 2 }.beta",
        ]
        let src = sanitized(lines, "TypeScript")
        XCTAssertEqual(src.opens[1], 1, "第二行的 `{` 必须算成一次开括号（被串吃掉就是 0）")
        XCTAssertEqual(src.closes[1], 1, "第二行的 `}` 必须算成一次闭括号")
        XCTAssertTrue(src.cleaned[1].contains("const t"),
                      "第二行必须还是代码，实际清洗结果：\"\(src.cleaned[1])\"")
        XCTAssertTrue(src.cleaned[0].contains("x"), "插值表达式内部的代码要留在 cleaned 里参与统计")
        XCTAssertFalse(src.cleaned[0].contains("a${"), "模板串内部的字面文字不得留在 cleaned 里")
    }

    /// 跨行模板串：串里的 `{` `}` 与文字都不进深度，闭合之后必须继续正常统计。
    func testMultiLineTemplateLiteralContributesNoBraces() {
        let lines = [
            "const s = `alpha",
            "  brace { noise }",
            "beta`",
            "function after(x: number): number {",
            "  return x",
            "}",
        ]
        let src = sanitized(lines, "TypeScript")
        XCTAssertEqual(src.opens[1], 0, "模板串内部的 `{` 不得算开括号")
        XCTAssertEqual(src.closes[1], 0, "模板串内部的 `}` 不得算闭括号")
        XCTAssertEqual(src.prefix[3], 0, "整段跨行模板串走完之后深度必须回到 0，实际 \(src.prefix[3])")
        let detected = functions("multiline.ts", lines)
        XCTAssertEqual(describe(detected), ["after@4..6cc1"], "跨行模板串之后函数必须仍被识别：\(describe(detected))")
    }

    // MARK: - 辅助

    private func sanitized(_ lines: [String], _ language: String) -> ComplexityEngine.SanitizedSource {
        ComplexityEngine.sanitize(lines, ComplexityEngine.profile(for: language))
    }
}
