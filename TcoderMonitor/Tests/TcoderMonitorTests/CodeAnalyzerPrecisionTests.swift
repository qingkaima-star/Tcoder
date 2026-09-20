import Foundation
import XCTest
@testable import TcoderMonitor

// OWNER: Workstream A (静态代码分析) —— CodeAnalyzerTests 的续篇
// （M 类型声明护栏 / N 全仓均复杂度 / O 根路径归一化 / P 剔除台账）。
// 拆出去只为守住「800 行以上的文件不得增加」这条红线，一条测试都没删。
// 共享夹具辅助留在 CodeAnalyzerTests.swift，可见性已从 private 放宽到模块内。
extension CodeAnalyzerTests {
    // MARK: - M. 类型声明不得被当成函数（真实语料回归：protobuf 35.0 头文件）

    /// `class PROTOBUF_EXPORT PROTOBUF_ALIGNAS(8) … Arena final {` 里「宏 + 括号」长得像函数签名，
    /// 一旦被吃下来，边界会一路走到类体的 `}`：实测 arena.h 的一个类声明被记成 626 行 / CC=43 的
    /// 「超高复杂度函数」，把 longFunctions 与热点榜一起污染。类里的真实成员函数必须照常识别。
    func testCppTypeDeclarationWithMacroParenIsNotReportedAsFunction() throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        let header = """
        class PROTOBUF_EXPORT PROTOBUF_ALIGNAS(8)
        #ifdef __clang__
            ABSL_ATTRIBUTE_WARN_UNUSED
        #endif
            Arena final {
         public:
          void Reset() {
            if used && arena {
              Free();
            }
          }
        };
        """
        let file = try XCTUnwrap(classify(try write(header + "\n", to: "arena.h", in: root), root: root),
                                 "C++ 头文件夹具必须分类成功")
        let names = ComplexityEngine.functions(in: file).map(\.name)
        XCTAssertFalse(names.contains(where: { $0.contains("ALIGNAS") }),
                       "类声明被误判成函数了：\(names)")
        XCTAssertTrue(names.contains("Reset"), "类里的真实成员函数必须仍然被识别：\(names)")
        let reset = try XCTUnwrap(names.firstIndex(of: "Reset").flatMap { ComplexityEngine.functions(in: file)[$0] })
        XCTAssertLessThanOrEqual(reset.lineCount, 8, "成员函数边界不得越出类体：\(reset)")
        XCTAssertEqual(reset.complexity, 3, "if + && 两个分支 → CC = 3")
    }

    /// Kotlin `data class`、Java `record` 的「名字 + 括号」同样不是函数。
    func testDataClassAndRecordDeclarationsAreNotFunctions() throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        let kotlin = """
        data class Point(val x: Int, val y: Int) {
            fun length(): Int {
                if x > y {
                    return x
                }
                return y
            }
        }
        """
        let kt = try XCTUnwrap(classify(try write(kotlin + "\n", to: "Point.kt", in: root), root: root))
        XCTAssertEqual(ComplexityEngine.functions(in: kt).map(\.name), ["length"],
                       "data class 的构造器不是函数")

        let java = """
        public record Box(int width, int height) {
            int area() {
                return width * height;
            }
        }
        """
        let box = try XCTUnwrap(classify(try write(java + "\n", to: "Box.java", in: root), root: root))
        XCTAssertEqual(ComplexityEngine.functions(in: box).map(\.name), ["area"],
                       "record 声明不是函数")
    }

    /// 两条必须存在的豁免，否则会误杀真函数：
    /// C 的 `static struct foo *get_value(void)`（`*` 属于返回类型）、
    /// Swift 的 `@objc class func shared()`（`func` 是定义关键字）。
    func testPointerReturnTypeAndSwiftClassFuncSurviveTheGuard() throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        let c = """
        static struct foo *get_value(void) {
            if a && b {
                return 0;
            }
            return 0;
        }
        """
        let cFile = try XCTUnwrap(classify(try write(c + "\n", to: "widget.c", in: root), root: root))
        XCTAssertEqual(ComplexityEngine.functions(in: cFile).map(\.name), ["get_value"],
                       "返回指针的 C 函数不能被类型声明护栏误杀")

        let swift = """
        @objc class func shared() -> Int {
            if a > b && c {
                return 1
            }
            return 0
        }
        """
        let swiftFile = try XCTUnwrap(classify(try write(swift + "\n", to: "Holder.swift", in: root), root: root))
        XCTAssertEqual(ComplexityEngine.functions(in: swiftFile).map(\.name), ["shared"],
                       "class func 的 class 是修饰符，不是类型声明")
    }

    /// `isTypeDeclaration` 是纯函数，单独钉住判定表。
    func testIsTypeDeclarationTruthTable() {
        let declarations = [
            "class PROTOBUF_EXPORT", "data class", "public record", "enum class",
            "struct S", "namespace n", "@interface", "abstract sealed class",
        ]
        let notDeclarations = [
            "static struct foo *",          // C 返回类型带 *
            "const char &",                  // C++ 引用返回
            "@objc class func",              // Swift 定义关键字豁免
            "private static fun",            // Kotlin 定义关键字豁免
            "void", "int", "std::string", "", "  ",
        ]
        for text in declarations {
            XCTAssertTrue(ComplexityEngine.isTypeDeclaration(text), "\(text) 应判为类型声明")
        }
        for text in notDeclarations {
            XCTAssertFalse(ComplexityEngine.isTypeDeclaration(text), "\(text) 不应判为类型声明")
        }
    }

    /// Go 1.18+ 泛型函数：`func Map[T, U any](...)` 的方括号类型参数表必须能吃下，
    /// 且不能因为参数里嵌套括号而丢函数。
    func testGoGenericFunctionIsRecognized() throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        let src = """
        func Map[T, U any](s []T, f func(T) U) []U {
            r := make([]U, len(s))
            for i, v := range s {
                r[i] = f(v)
            }
            return r
        }
        """
        let file = try XCTUnwrap(classify(try write(src + "\n", to: "map.go", in: root), root: root))
        let functions = ComplexityEngine.functions(in: file)
        XCTAssertEqual(functions.map(\.name), ["Map"], "泛型函数必须被识别：\(functions.map(\.name))")
        let mapFunction = try XCTUnwrap(functions.first)
        XCTAssertGreaterThanOrEqual(mapFunction.lineCount, 6, "函数体要覆盖到闭合花括号：\(mapFunction)")
        XCTAssertGreaterThanOrEqual(mapFunction.complexity, 2, "for range 至少贡献一个分支")
        XCTAssertEqual(mapFunction.parameterCount, 2, "两个真参数（类型参数表不计）：\(mapFunction)")
    }

    /// 口径护栏：少于 2 行的函数与无函数体的生成声明一律不计入函数统计。
    /// 实测占比不小 —— `go/ast/ast.go` 174 个 `^func` 里 143 个是单行体、
    /// `simd/archsimd/ops_amd64.go` 的 1597 个 `func` 全无函数体（引擎报 0）。
    /// 因此 `averageFunctionLength` 只统计 ≥2 行的函数，UI 标签已注明「仅 ≥2 行」。
    func testSingleLineAndBodyLessFunctionsAreExcludedByPolicy() throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        let src = """
        func oneLiner(x int) int { return x }

        func twoLiner(x int) int {
            return x
        }
        """
        let file = try XCTUnwrap(classify(try write(src + "\n", to: "policy.go", in: root), root: root))
        XCTAssertEqual(ComplexityEngine.functions(in: file).map(\.name), ["twoLiner"],
                       "单行函数按口径不计入")

        let decls = """
        func (a Uint8x16) AESDecryptLastRound(y Uint32x4) Uint8x16

        func (a Uint8x32) AESDecryptLastRound(y Uint32x8) Uint8x32
        """
        let declFile = try XCTUnwrap(classify(try write(decls + "\n", to: "decls.go", in: root), root: root))
        XCTAssertTrue(ComplexityEngine.functions(in: declFile).isEmpty,
                      "无函数体的声明不构成函数：\(ComplexityEngine.functions(in: declFile))")
    }

    // MARK: - N. 全仓平均圈复杂度（评分曲线的分母）

    // MARK: - O. 根路径归一化口径（钉死 flaky：/tmp 是 /private/tmp 的符号链接）

    // MARK: - P. 剔除台账：每丢掉一个条目都要说清是被哪条规则丢的

    // MARK: - R. 清账：少掉的每一行都要能被指回一条规则

    // MARK: - Q. 覆盖度：上限生效过就不能把结果当全量（WS-D 诚实性审计 P1 #7 / #8）

    /// 重复率的「低估」原先只写在源码注释里；现在必须是本次运行的实测数字。
    func testDuplicationBudgetLossIsMeasured() async throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        // 同一段 15 行代码抄 40 份：远超每指纹 24 处、每文件 8 处的片段预算
        let body = [
            "fun sharedProbe(left: Int, right: Int): Int {",
            "    var totalValue = left + right * 3",
            "    if totalValue > 100 && left != right {",
            "        totalValue = totalValue - right",
            "    }",
            "    while totalValue > 50 {",
            "        totalValue = totalValue / 2",
            "    }",
            "    val labelMark = \"shared-copy-\"",
            "    if totalValue < 0 || left > 900 {",
            "        return right",
            "    }",
            "    println(labelMark)",
            "    return totalValue",
            "}",
        ].joined(separator: "\n") + "\n"
        for index in 0..<40 { _ = try write(body, to: "copy\(index).kt", in: root) }
        let outcome = try await FileSystemCodeAnalyzer().analyzeWithCoverage(root: root, options: options(maxFiles: 200))
        XCTAssertGreaterThan(outcome.coverage.duplicateFragmentsDroppedByBudget, 0,
                             "片段预算必然被触顶，必须报出被丢掉的拷贝数")
        XCTAssertTrue(outcome.coverage.isPartial)
        XCTAssertTrue(outcome.coverage.limitationSummary.contains { $0.contains("指纹预算") || $0.contains("明细榜单") },
                      "\(outcome.coverage.limitationSummary)")
        XCTAssertGreaterThan(outcome.metrics.duplicationRatio, 0, "重复率本身仍要算得出来")
    }

    /// 台账必须能按**根因目录**报出行数 —— 用户看到的是「已跳过 vendor/ 352,784 行」，
    /// 而不是一个光秃秃的总数（Homebrew 实测 vendor 一条就占 excludedDirectoryContent 的 558,732 行）。
    func testSkipLedgerAttributesLinesToTheRootCauseDirectory() async throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        _ = try write("let kept = 1\n", to: "Keep.swift", in: root)
        _ = try write("let a = 1\nlet b = 2\n", to: "vendor/Deep.swift", in: root)
        _ = try write(String(repeating: "let x = 1\n", count: 7), to: "vendor/nested/More.swift", in: root)
        let opts = options(skipDirectories: ["vendor"])

        let audited = await SourceTreeScanner(options: opts,
                                             auditLineBudget: SourceSkipLedger.defaultAuditBudget).scan(root: root)
        let bucket = try XCTUnwrap(audited.skipLedger.buckets[.excludedDirectoryContent],
                                   "审计模式必须展开被剔除目录")
        XCTAssertEqual(bucket.files, 2, "vendor 之下两个文件都要归因")
        XCTAssertEqual(bucket.lines, 9, "2 + 7 行")
        XCTAssertEqual(bucket.lineRules["vendor"], 9, "行数是 9 行，且全部归到根因 vendor 而不是 vendor/nested")
        XCTAssertEqual(bucket.rules["vendor"], 2, "文件数按根因计数")
        XCTAssertTrue(audited.skipLedger.topLineRules(.excludedDirectoryContent).contains("vendor=9"),
                      "台账摘要要能直接印出来：\(audited.skipLedger.topLineRules(.excludedDirectoryContent))")
        XCTAssertEqual(audited.skipLedger.buckets[.excludedDirectoryNested]?.files, 1,
                       "vendor/nested 记成嵌套目录，行数不重复计")
        XCTAssertEqual(audited.skipLedger.buckets[.excludedDirectoryNested]?.lineRules.values.reduce(0, +) ?? 0, 0,
                       "嵌套目录自己不该带行数，否则会与根因重复")
    }

    /// `analyze` 的公开入口也要能单独取台账；不存在的目录必须照旧抛错。
    func testSkipLedgerEntryPointAndMissingRootError() async throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        _ = try write("let a = 1\n", to: "A.swift", in: root)
        _ = try write("prose\n", to: "readme.txt", in: root)
        let ledger = try await FileSystemCodeAnalyzer().skipLedger(root: root, options: options())
        XCTAssertEqual(ledger.buckets[.unsupportedExtension]?.files, 1)

        do {
            _ = try await FileSystemCodeAnalyzer().skipLedger(
                root: root.appendingPathComponent("never-created"), options: options())
            XCTFail("不存在的目录必须抛 notDirectory")
        } catch let error as AnalysisError {
            guard case .notDirectory = error else { return XCTFail("错误类型不对：\(error)") }
        }
    }
}
