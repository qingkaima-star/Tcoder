/// OWNER: WS-X3 TestSplit —— 自 CodeAnalyzerScanTests.swift 拆出，四语言圈复杂度口径与函数识别（含多行签名/扩展/闭包/恶意代码降级）。用例本体未改，只是搬了家。
import Foundation
import XCTest
@testable import TcoderMonitor

extension CodeAnalyzerTests {

    func testSwiftComplexityEqualsOnePlusBranchCount() throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        let body = [
            "func scoreFor(value: Int, flag: Bool) -> Int {",
            "    if value > 10 && flag {",
            "        return value + 20",
            "    } else if value > 5 {",
            "        return value",
            "    }",
            "    return 0",
            "}",
        ]
        let url = try write(body.joined(separator: "\n") + "\n", to: "Score.swift", in: root)
        guard let file = classify(url, root: root) else { return XCTFail("Swift 夹具必须分类成功") }

        // 分支：if(1) + &&(1) + else if(1) = 3 → CC = 1 + 3
        XCTAssertEqual(ComplexityEngine.complexity(forLines: body, language: file.language), 4,
                       "Swift 夹具：CC 必须等于 1 + if + && + else if")
        let detected = ComplexityEngine.functions(in: file)
        XCTAssertEqual(detected.count, 1, "必须恰好识别出 1 个函数，实际 \(detected.map(\.name))")
        let candidate = try XCTUnwrap(detected.first)
        XCTAssertEqual(candidate.name, "scoreFor", "函数名必须取签名里的标识符")
        XCTAssertEqual(candidate.complexity, 4, "函数级 CC 必须与整段 CC 一致，实际 \(candidate)")
        XCTAssertEqual(candidate.parameterCount, 2, "两个入参")
        XCTAssertEqual(candidate.startLine, 1, "startLine 必须是签名所在行")
    }

    func testPythonComplexityEqualsOnePlusBranchCount() throws {
        let body = [
            "def classify(value):",
            "    if value > 90:",
            "        return 1",
            "    elif value > 50:",
            "        return 2",
            "    for item in value:",
            "        print(item)",
            "    while value < 3:",
            "        value += 1",
            "    return 0",
        ]
        // 分支：if + elif + for + while = 4 → CC = 5
        XCTAssertEqual(ComplexityEngine.complexity(forLines: body, language: "Python"), 5,
                       "Python 夹具：CC 必须等于 1 + if + elif + for + while")
    }

    func testJavaComplexityEqualsOnePlusBranchCount() throws {
        let body = [
            "public int grade(int mark) {",
            "    switch (mark) {",
            "        case 1:",
            "            return 10;",
            "        case 2:",
            "            return 20;",
            "        default:",
            "            return 0;",
            "    }",
            "    try {",
            "        worker.run();",
            "    } catch (IllegalStateException ex) {",
            "        return -1;",
            "    }",
            "    return mark;",
            "}",
        ]
        // 分支：case + case + catch = 3 → CC = 4；switch / default / try 不算判定分支。
        XCTAssertEqual(ComplexityEngine.complexity(forLines: body, language: "Java"), 4,
                       "Java 夹具：CC 必须等于 1 + 两个 case + 一个 catch")
    }

    func testComplexityIgnoresKeywordsInsideCommentsAndStrings() throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        let body = [
            "func quiet(text: String) -> String {",
            "    // if a && b { for ever } while case catch",
            "    let note = \"if x && y || z\"",
            "    /* if p && q */",
            "    return text",
            "}",
        ]
        let url = try write(body.joined(separator: "\n") + "\n", to: "Quiet.swift", in: root)
        guard let file = classify(url, root: root), let candidate = ComplexityEngine.functions(in: file).first else {
            return XCTFail("Swift 夹具必须分类成功并识别出函数")
        }

        XCTAssertEqual(ComplexityEngine.complexity(forLines: body, language: "Swift"), 1,
                       "注释与字符串字面量里的 if / && / for 一律不得计入复杂度")
        XCTAssertEqual(candidate.complexity, 1, "函数级统计同样不得被注释/字符串污染：\(candidate)")
        XCTAssertEqual(ComplexityEngine.complexity(forLines: ["# if a && b", "x = 1"], language: "Python"), 1,
                       "Python 的 # 注释行不得计入复杂度")
        XCTAssertEqual(ComplexityEngine.complexity(forLines: ["-- if a && b", "select 1"], language: "SQL"), 1,
                       "SQL 的 -- 注释行不得计入复杂度")
    }

    func testComplexityBaselineAndPerBranchIncrement() throws {
        XCTAssertEqual(ComplexityEngine.complexity(forLines: ["let totalValue = baseValue + rate"], language: "Swift"), 1,
                       "直线代码的 CC 必须是 1")
        XCTAssertEqual(ComplexityEngine.complexity(forLines: [], language: "Swift"), 1, "空输入必须退化成 1 而不是 0")
        XCTAssertEqual(ComplexityEngine.complexity(forLines: ["let a = 1"], language: "未发明的语言"), 1,
                       "未知语言不得崩溃，返回基线 1")

        var lines = ["let totalValue = baseValue"]
        var previous = ComplexityEngine.complexity(forLines: lines, language: "Swift")
        for extra in ["if alphaValue { betaValue() }", "while gammaValue { deltaValue() }", "for epsilonValue in zetaValue { etaValue() }"] {
            lines.append(extra)
            let next = ComplexityEngine.complexity(forLines: lines, language: "Swift")
            XCTAssertEqual(next, previous + 1, "追加一行分支「\(extra)」之后 CC 必须正好加 1，实际 \(previous) → \(next)")
            previous = next
        }
        XCTAssertEqual(previous, 4, "三个分支叠加后 CC 必须是 1 + 3")
    }

    func testFunctionIdentificationForMultilineSignatureAndExtension() throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }

        let multi = """
        func multiLineSignature(
            firstValue: Int,
            secondValue: Int
        ) -> Int {
            if firstValue > secondValue {
                return firstValue
            }
            return secondValue
        }
        """
        let multiFile = try XCTUnwrap(classify(try write(multi + "\n", to: "Multi.swift", in: root), root: root))
        let multiFunctions = ComplexityEngine.functions(in: multiFile)
        XCTAssertEqual(multiFunctions.count, 1, "多行签名必须只算一个函数：\(multiFunctions.map(\.name))")
        let multiCandidate = try XCTUnwrap(multiFunctions.first)
        XCTAssertEqual(multiCandidate.name, "multiLineSignature", "函数名必须来自签名行")
        XCTAssertEqual(multiCandidate.startLine, 1, "startLine 必须是签名所在的 1-based 行号")
        XCTAssertEqual(multiCandidate.parameterCount, 2, "跨行签名里的两个参数都要数到：\(multiCandidate)")
        XCTAssertGreaterThanOrEqual(multiCandidate.lineCount, 2, "退化保护：lineCount 至少 2")
        XCTAssertEqual(multiCandidate.complexity, 2, "分支只有一个 if → CC = 2")

        let ext = """
        extension Widget {
            func renderScaled(scale: Double) -> String {
                if scale > 2 && scale < 9 {
                    return "big"
                }
                return "small"
            }
        }
        """
        let widget = try XCTUnwrap(classify(try write(ext + "\n", to: "Widget.swift", in: root), root: root))
        let extFunctions = ComplexityEngine.functions(in: widget)
        XCTAssertEqual(extFunctions.map(\.name), ["renderScaled"], "extension 内的函数必须被识别：\(extFunctions.map(\.name))")
        let extCandidate = try XCTUnwrap(extFunctions.first)
        XCTAssertEqual(extCandidate.startLine, 2, "startLine 必须是 func 所在行而不是 extension 行")
        XCTAssertEqual(extCandidate.lineCount, 6, "函数体必须覆盖到闭合花括号")
        XCTAssertEqual(extCandidate.complexity, 3, "分支：if + && → CC = 3")
    }

    func testFunctionIdentificationAcrossPythonGoAndJavaScriptClosure() throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }

        let python = """
        def grade_one(mark):
            if mark > 90:
                return 1
            for item in mark:
                print(item)
            return 0
        """
        let pyFile = try XCTUnwrap(classify(try write(python + "\n", to: "Grade.py", in: root), root: root))
        let pyFunctions = ComplexityEngine.functions(in: pyFile)
        XCTAssertEqual(pyFunctions.map(\.name), ["grade_one"], "Python def 必须被识别：\(pyFunctions.map(\.name))")
        XCTAssertEqual(pyFunctions.first?.lineCount, 6, "缩进式函数体必须覆盖到最后一个缩进行")
        XCTAssertEqual(pyFunctions.first?.complexity, 3, "分支：if + for → CC = 3")

        let pythonMulti = """
        def summarize_rows(
            rows,
            tax_rate,
            allow_zero
        ):
            total_value = 0
            for row in rows:
                total_value += row
            return total_value
        """
        let pyMultiFile = try XCTUnwrap(classify(try write(pythonMulti + "\n", to: "Summarize.py", in: root), root: root))
        let pyMultiFunctions = ComplexityEngine.functions(in: pyMultiFile)
        XCTAssertEqual(pyMultiFunctions.map(\.name), ["summarize_rows"], "跨行 def 签名也必须被识别：\(pyMultiFunctions.map(\.name))")
        XCTAssertGreaterThanOrEqual(pyMultiFunctions.first?.lineCount ?? 0, 2, "退化保护：lineCount 至少 2")

        let go = "package main\n\nfunc computeTotal(base int, rate int) int {\n"
            + "\tif base > 10 && rate > 2 {\n\t\treturn base + rate\n\t}\n"
            + "\tfor index := 0; index < 3; index++ {\n\t\t_ = index\n\t}\n"
            + "\treturn base\n}\n"
        let goFile = try XCTUnwrap(classify(try write(go, to: "total.go", in: root), root: root))
        let goFunctions = ComplexityEngine.functions(in: goFile)
        XCTAssertEqual(goFunctions.map(\.name), ["computeTotal"], "Go 函数必须被识别：\(goFunctions.map(\.name))")
        XCTAssertEqual(goFunctions.first?.parameterCount, 2, "Go 两个入参")
        XCTAssertEqual(goFunctions.first?.complexity, 4, "分支：if + && + for → CC = 4")

        let jsClosure = """
        const priceOf = (item) => {
            if (item.flag && item.count > 2) {
                return item.count * 2
            }
            return 0
        }
        """
        let jsFile = try XCTUnwrap(classify(try write(jsClosure + "\n", to: "price.js", in: root), root: root))
        let jsFunctions = ComplexityEngine.functions(in: jsFile)
        XCTAssertTrue(jsFunctions.contains { $0.name == "priceOf" },
                      "箭头函数赋给 const 时也必须被识别，实际：\(jsFunctions.map(\.name))")

        // 没有函数概念的语言不得凭空造函数
        for (name, content) in [("data.json", "{\n  \"key\": 1\n}\n"), ("page.css", ".a { color: red }\n")] {
            let scanned = try XCTUnwrap(classify(try write(content, to: name, in: root), root: root))
            XCTAssertTrue(ComplexityEngine.functions(in: scanned).isEmpty, "\(name) 不该识别出任何函数")
        }
    }

    /// RD-79：`export const useFoo = (…) => {…}` 是 ESM/TS 模块的主流写法，
    /// 以前整类漏认（`jsFunction` 收了 `export function`，`jsVariableArrow` 没有 `export` 前缀位）。
    /// 独立真值 = 只差一个 `export` 的两份同形夹具必须同权；反例 = 对象字面量与常量赋值不算函数。
    func testExportedArrowFunctionIsRecognizedAndPlainExportsAreNot() throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        let exportedArrow = """
        export const priceOf = (item) => {
            if (item.flag) {
                return item.count
            }
            return 0
        }
        """
        let exportedFile = try XCTUnwrap(classify(try write(exportedArrow + "\n", to: "price2.js", in: root), root: root))
        XCTAssertEqual(ComplexityEngine.functions(in: exportedFile).map(\.name), ["priceOf"],
                       "带 export 的 const 箭头函数必须与不带时同权被识别")
        // 反例：`export` 后面跟对象字面量或常量**不是**函数，不许被上面那一档顺手吃进来。
        for (name, text) in [("config.js", "export const config = {\n  retries: 2\n}\n"),
                             ("n.js", "export const n = 1\n")] {
            let file = try XCTUnwrap(classify(try write(text, to: name, in: root), root: root))
            XCTAssertTrue(ComplexityEngine.functions(in: file).isEmpty, "\(name) 不该识别出任何函数")
        }
    }

    func testFunctionIdentificationDegradesSafelyOnHostileCode() throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        let cases: [(String, String)] = [
            ("Unclosed.swift", "func neverCloses(a: Int) -> Int {\n    if a > 1 {\n        return a\n    }\n"),
            ("StrayBrace.swift", "func odd(a: Int) -> Int {\n}\n}\nfunc after() -> Int {\n    return 1\n}\n"),
            ("Wide.swift", "func wide(a: Int) -> Int {\n" + String(repeating: "    let v = 1\n", count: 300) + "    return a\n}\n"),
            ("Empty.swift", ""),
            ("OnlyBrace.swift", "{{{{\n}}}}\n"),
            ("NoBrace.swift", "func tail(a: Int) -> Int\n"),
            ("Deep.swift", "func deep(a: Int) -> Int {\n    if a > 1 {\n        if a > 2 {\n            return a\n        }\n    }\n    return 0\n}\n"),
            ("Quoted.swift", "func quoted(a: Int) -> Int {\n    let s = \"} { func fake() {\"\n    return a\n}\n"),
        ]
        for (name, content) in cases {
            let file = try XCTUnwrap(classify(try write(content, to: name, in: root), root: root), "\(name) 夹具必须分类成功")
            let functions = ComplexityEngine.functions(in: file)
            for candidate in functions {
                XCTAssertGreaterThanOrEqual(candidate.startLine, 1,
                                            "\(name)：startLine 必须是 1-based 正数，实际 \(candidate.startLine)")
                XCTAssertGreaterThanOrEqual(candidate.lineCount, 2,
                                            "\(name)：过短片段不得作为函数产出，实际 \(candidate.lineCount)")
                XCTAssertGreaterThanOrEqual(candidate.complexity, 1, "\(name)：CC 必须 >= 1")
                XCTAssertGreaterThanOrEqual(candidate.parameterCount, 0, "\(name)：参数个数不得为负")
                XCTAssertFalse(candidate.name.isEmpty, "\(name)：函数名不得为空串")
                XCTAssertLessThanOrEqual(candidate.startLine + candidate.lineCount - 1, file.totalLineCount,
                                         "\(name)：函数区间必须落在文件行数之内")
            }
        }
    }

    func testParameterCountFromSignatures() {
        XCTAssertEqual(ComplexityEngine.parameterCount(from: "func foo(a: Int, b: Int) -> Void"), 2, "两个普通参数")
        XCTAssertEqual(ComplexityEngine.parameterCount(from: "func foo()"), 0, "空参数表必须是 0 而不是 1")
        XCTAssertEqual(ComplexityEngine.parameterCount(from: "func foo(dict: [String: Int], flag: Bool)"), 2,
                       "方括号里的逗号不得被当成参数分隔")
        XCTAssertEqual(ComplexityEngine.parameterCount(from: "func foo(items: Array<Int>, flag: Bool)"), 2,
                       "泛型尖括号里的逗号不得被当成参数分隔")
        XCTAssertEqual(ComplexityEngine.parameterCount(from: "func foo(msg: String)"), 1, "单个参数")
        XCTAssertEqual(ComplexityEngine.parameterCount(from: "没有括号的签名"), 0, "找不到左括号必须返回 0")
        XCTAssertEqual(ComplexityEngine.parameterCount(from: ""), 0, "空串必须返回 0")
    }

}
