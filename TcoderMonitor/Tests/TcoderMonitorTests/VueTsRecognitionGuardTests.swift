import XCTest
@testable import TcoderMonitor

/// OWNER: R2（Vue / TS 识别与模板字符串）—— **两条扫描型守卫 + 各自的元测试**（工单 F②）。
///
/// 为什么要元测试：本仓反复踩过「永真绿守卫」——只匹配到某个特定写法的正则，
/// 换个形状就空转，全绿看着像"问题已修"。所以每条守卫都配三件：
/// 合成违例必须命中、合法写法（含注释里提到被禁词）不得误伤、分母必须 > 0。
///
/// 守卫 1：RD-06 的形状回归 —— 词法状态不许再退回「平铺布尔 + 单层 stringDelim」。
/// 守卫 2：真值夹具对账 —— 一组内联夹具的函数条数 / 边界必须等于手写期望，
///         而且比对器本身要被"故意写错的期望"证明有牙。
final class VueTsRecognitionGuardTests: XCTestCase {

    // MARK: - 测试侧的独立脱敏（不用产品侧 sanitize，避免拿被测物当尺子）

    /// 剥掉行注释 / 块注释 / 字符串字面量，只留代码骨架。
    /// 刻意写得很笨：这条路径要是坏了，元测试会当场抓到（拿注释造违例必须不命中）。
    private func stripCommentsAndStrings(_ text: String) -> String {
        var out = ""
        var inBlock = false
        var quote: Character?
        let chars = Array(text)
        var index = 0
        while index < chars.count {
            let c = chars[index]
            let next: Character? = index + 1 < chars.count ? chars[index + 1] : nil
            if inBlock {
                if c == "*", next == "/" { inBlock = false; index += 2; continue }
                index += 1
                continue
            }
            if let open = quote {
                if c == "\\", index + 1 < chars.count { index += 2; continue }
                if c == open { quote = nil }
                index += 1
                continue
            }
            if c == "/", next == "*" { inBlock = true; index += 2; continue }
            if c == "/", next == "/" { while index < chars.count, chars[index] != "\n" { index += 1 }; continue }
            if c == "\"" || c == "'" || c == "`" { quote = c; index += 1; continue }
            out.append(c)
            index += 1
        }
        return out
    }

    /// 守卫 1 的判据：这两个旧符号**作为代码标识符**再出现就说明状态机退回了平铺字段。
    private static let flatStateNames = ["inTemplateExpression", "stringIsTemplate", "templateBraceDepth"]

    private func codeFiles() throws -> [URL] {
        let root = SelfScanHarnessCase.repoRoot
        let directory = root.appendingPathComponent("TcoderMonitor/Sources/TcoderMonitor/Services/Code")
        let urls = try FileManager.default.contentsOfDirectory(at: directory,
                                                              includingPropertiesForKeys: nil,
                                                              options: [])
        return urls.filter { $0.pathExtension == "swift" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func testGuard1FlatTemplateStateDoesNotComeBack() throws {
        let files = try codeFiles()
        XCTAssertGreaterThan(files.count, 10, "分母为 0：一个 Code 目录下的实现文件都没扫到，守卫在空转")
        var hits: [String] = []
        var scannedSymbols = 0
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            let code = stripCommentsAndStrings(text)
            for name in Self.flatStateNames where code.contains(name) {
                hits.append("\(url.lastPathComponent) 又出现平铺模板状态 \(name)")
            }
            if code.contains("LexFrame") || code.contains("frames.append") { scannedSymbols += 1 }
        }
        XCTAssertEqual(hits, [], "RD-06 回归：\n" + hits.joined(separator: "\n"))
        XCTAssertGreaterThan(scannedSymbols, 0,
                             "脱敏后一个帧栈符号都没扫到 ⇒ 脱敏器或判据在空转（永真绿守卫）")
    }

    /// 守卫 1 的元测试：合成违例必须命中、注释里提到被禁词不得误伤、分母 > 0。
    func testGuard1RulerCatchesInjectedViolationAndIgnoresComments() {
        let violating = "func x() {\n  var inTemplateExpression = false\n}\n"
        XCTAssertTrue(Self.flatStateNames.contains { stripCommentsAndStrings(violating).contains($0) },
                      "元测试：把被禁形状塞进代码里，守卫必须认出来（认不出=永真绿）")
        let mentioned = "// 旧实现叫 inTemplateExpression / stringIsTemplate / templateBraceDepth\n"
            + "let value = \"inTemplateExpression\"\n"
        XCTAssertFalse(Self.flatStateNames.contains { stripCommentsAndStrings(mentioned).contains($0) },
                       "元测试：注释与字符串里提到被禁词不得算违例（误伤=守卫不可信）")
        XCTAssertFalse(stripCommentsAndStrings(mentioned).isEmpty, "脱敏后仍有代码骨架，说明脱敏器没空转")
    }

    // MARK: - 守卫 2：真值夹具对账

    private struct Truth {
        var name: String
        var expected: [String]        // "name@start..end"，手写、不是引擎输出
        var lines: [String]
    }

    private var corpus: [Truth] {
        [
            Truth(name: "单层插值", expected: ["buildLabel@1..7", "afterInterpolation@8..13"], lines: [
                "function buildLabel(name: string, flag: boolean): string {",
                "  const text = `hi ${name}!`",
                "  if (flag && name.length > 3) {",
                "    return text",
                "  }",
                "  return \"plain\"",
                "}",
                "function afterInterpolation(x: number): number {",
                "  if (x > 1) {",
                "    return x + 1",
                "  }",
                "  return x",
                "}",
            ]),
            Truth(name: "插值里的对象字面量", expected: ["renderUser@1..7", "tailFn@8..13"], lines: [
                "const renderUser = (user: User): string => {",
                "  const badge = `${ { level: 1 }.level } 级`",
                "  if (user.admin && badge.length > 0) {",
                "    return badge",
                "  }",
                "  return \"\"",
                "}",
                "function tailFn(a: number): number {",
                "  if (a > 0) {",
                "    return a",
                "  }",
                "  return 0",
                "}",
            ]),
            Truth(name: "正则里含反引号", expected: ["usesTricky@2..7", "secondFn@8..13"], lines: [
                "const TRICKY = /`.*\\$\\{(/;",
                "function usesTricky(n: number): number {",
                "  if (n > 0) {",
                "    return n;",
                "  }",
                "  return 0;",
                "}",
                "function secondFn(x: number): number {",
                "  if (x > 1) {",
                "    return x;",
                "  }",
                "  return 0;",
                "}",
            ]),
            Truth(name: "嵌套具名函数", expected: ["outerFlag@1..12", "innerCount@2..7"], lines: [
                "function outerFlag(items: number[]): number {",
                "  function innerCount(list: number[]): number {",
                "    if (list.length > 0) {",
                "      return list.length",
                "    }",
                "    return 0",
                "  }",
                "  if (items.length > 3) {",
                "    return innerCount(items)",
                "  }",
                "  return innerCount([])",
                "}",
            ]),
        ]
    }

    private func audit(_ corpus: [Truth]) -> (problems: [String], expectedEntries: Int) {
        var problems: [String] = []
        for truth in corpus {
            var walker = SourceLineWalker(language: "TypeScript")
            var sourceLines: [SourceLine] = []
            var code = 0
            for (offset, text) in truth.lines.enumerated() {
                var characters = Array(text)
                let kind = walker.kind(for: &characters)
                if kind == .code { code += 1 }
                sourceLines.append(SourceLine(number: offset + 1, text: text, kind: kind))
            }
            let file = ScannedSourceFile(url: URL(fileURLWithPath: "/r2-corpus/\(truth.name).ts"),
                                         relativePath: truth.name, language: "TypeScript",
                                         lines: sourceLines, blankLineCount: 0,
                                         commentLineCount: 0, codeLineCount: code,
                                         todoCount: 0, fixmeCount: 0)
            let measured = ComplexityEngine.functions(in: file)
                .map { "\($0.name)@\($0.startLine)..\($0.startLine + $0.lineCount - 1)" }
            if measured != truth.expected {
                problems.append("\(truth.name)：期望 \(truth.expected)，实测 \(measured)")
            }
        }
        return (problems, corpus.reduce(0) { $0 + $1.expected.count })
    }

    func testGuard2TruthCorpusAgreesWithEngine() {
        let result = audit(corpus)
        XCTAssertGreaterThan(result.expectedEntries, 0, "分母为 0：夹具一条期望都没写，守卫在空转")
        XCTAssertEqual(result.problems, [], "真值夹具对不上账：\n" + result.problems.joined(separator: "\n"))
    }

    /// 守卫 2 的元测试：把期望故意改错一条，比对器必须报出来。
    /// 少了这一条，`audit` 可以退化成"永远返回空数组"而全仓照样绿。
    func testGuard2AuditDetectsCorruptedExpectation() {
        var corrupted = corpus
        corrupted[0].expected[0] = "buildLabel@1..99"
        let result = audit(corrupted)
        XCTAssertEqual(result.problems.count, 1, "故意写错的期望必须被抓出来：\(result.problems)")
        XCTAssertTrue(result.problems[0].contains("单层插值"), "报错要能指名是哪条夹具：\(result.problems)")
    }
}
