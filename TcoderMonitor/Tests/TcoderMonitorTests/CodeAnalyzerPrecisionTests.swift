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

    // MARK: - O. 根路径归一化口径（钉死 flaky：/tmp 是 /private/tmp 的符号链接）

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

    // MARK: - P. 剔除台账：每丢掉一个条目都要说清是被哪条规则丢的

    /// 夹具根里一次摆齐七种剔除理由，台账必须逐条对上，且「纳入 + 剔除 == 遍历到的文件数」。
    func testSkipLedgerAttributesEveryRejectedEntry() async throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        _ = try write("let kept = 1\n", to: "Keep.swift", in: root)
        _ = try write("no extension at all\n", to: "LICENSE", in: root)
        _ = try write("plain prose\n", to: "notes.txt", in: root)
        _ = try write("fake image bytes\n", to: "logo.png", in: root)
        _ = try write("let hidden = 1\n", to: ".secret.swift", in: root)
        _ = try write(String(repeating: "let line = 1\n", count: 300), to: "huge.swift", in: root)
        _ = try write("let vendored = 1\n", to: "vendor/Pkg.swift", in: root)
        _ = try write("let deep = 1\nlet two = 2\n", to: "vendor/nested/Deep.swift", in: root)
        let link = root.appendingPathComponent("link.swift")
        try? fm.removeItem(at: link)
        try fm.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("Keep.swift"))

        let opts = options(maxFileBytes: 2_000, skipDirectories: ["vendor"],
                           binaryExtensions: ["png"], includeHidden: false)

        // —— 正常扫描（不审计）：零额外读盘，只记条数与字节
        let plain = await SourceTreeScanner(options: opts).scan(root: root)
        XCTAssertEqual(plain.scannedFileCount, 1, "只有 Keep.swift 应被纳入：\(plain.files.map(\.relativePath))")
        XCTAssertEqual(plain.skippedFileCount + plain.scannedFileCount, plain.visitedFileCount,
                       "visited 必须等于纳入 + 剔除")
        let ledger = plain.skipLedger
        XCTAssertEqual(ledger.buckets[.missingExtension]?.files, 1, "LICENSE 无后缀")
        XCTAssertEqual(ledger.buckets[.unsupportedExtension]?.files, 1, "notes.txt 语言表里没有")
        XCTAssertEqual(ledger.buckets[.binaryExtension]?.files, 1, "logo.png 命中二进制后缀")
        XCTAssertEqual(ledger.buckets[.oversize]?.files, 1, "huge.swift 超过 maxFileBytes")
        XCTAssertEqual(ledger.buckets[.hiddenEntry]?.files, 1, ".secret.swift 是隐藏项")
        XCTAssertEqual(ledger.buckets[.symbolicLink]?.files, 1, "link.swift 是软链接")
        XCTAssertEqual(ledger.buckets[.skippedDirectory]?.files, 1, "vendor 整棵被剔除（根因只记一次）")
        XCTAssertEqual(ledger.buckets[.excludedDirectoryNested]?.files ?? 0, 0,
                       "正常扫描掐了子树，vendor/nested 这一层根本不该被看到")
        XCTAssertEqual(ledger.buckets[.excludedDirectoryContent]?.files ?? 0, 0,
                       "正常扫描对被剔除目录掐子树，子树里的文件不该被逐个看到")
        XCTAssertEqual(ledger.skippedFileTotal, 7, "台账覆盖的条目数（含 visited 之外的隐藏/软链接/目录）")
        XCTAssertFalse(ledger.cappedRemaining, "maxFiles 未命中，不得谎报截断")
        XCTAssertEqual(ledger.buckets[.binaryExtension]?.rules["png"], 1, "规则项要落到具体后缀上")

        // —— 审计模式：额外数出被剔除文件的真实行数，把「少掉的行数」完整解释掉
        let audited = await SourceTreeScanner(options: opts,
                                             auditLineBudget: SourceSkipLedger.defaultAuditBudget).scan(root: root)
        let audit = audited.skipLedger
        XCTAssertEqual(audit.buckets[.excludedDirectoryContent]?.files, 2, "审计模式要展开被剔除目录逐文件归因")
        XCTAssertEqual(audit.buckets[.excludedDirectoryContent]?.lines, 3,
                       "vendor/Pkg.swift 1 行 + vendor/nested/Deep.swift 2 行")
        XCTAssertEqual(audit.buckets[.excludedDirectoryNested]?.files, 1, "vendor/nested 记成嵌套目录，根因仍是 vendor")
        XCTAssertEqual(audit.buckets[.skippedDirectory]?.files, 1, "根因条数不能被嵌套目录稀释")
        XCTAssertEqual(audit.buckets[.oversize]?.lines, 300, "超限文件的 300 行要能对上")
        XCTAssertEqual(audit.buckets[.hiddenEntry]?.lines, 0, "隐藏项一律不读内容（可能是 .env 之类）")
        XCTAssertFalse(audit.linesBudgetExhausted, "夹具远小于预算，不得报预算耗尽")
        XCTAssertEqual(audit.skippedLineTotal,
                       (audit.buckets.values.map(\.lines).reduce(0, +)), "台账自洽")
        XCTAssertGreaterThan(audit.auditedBytes, 0)

        // 同一份夹具：审计与否，纳入集合必须完全一致（审计只多加统计，不改判定）
        XCTAssertEqual(Set(audited.files.map(\.relativePath)), Set(plain.files.map(\.relativePath)))
    }

    // MARK: - R. 清账：少掉的每一行都要能被指回一条规则

    /// 「比 `find` 少 22%」这类质疑的唯一正经答法：纳入行 + 各条原因剔除行 == 磁盘真实行，逐行对上。
    func testSkipClearingReconcilesEveryLine() async throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        _ = try write("let kept = 1\nlet more = 2\n", to: "Keep.swift", in: root)                       // 2 行，纳入
        _ = try write("puts 1\nputs 2\nputs 3\n", to: "vendor/Deep.rb", in: root)                     // 3 行，排除目录
        _ = try write("project(x)\ninstall(FILES a)\n", to: "sub/CMakeLists.cmake", in: root)         // 2 行，后缀未收录
        _ = try write("MIT\nLicense\n", to: "LICENSE", in: root)                                       // 2 行，无后缀

        let opts = options(skipDirectories: ["vendor"], binaryExtensions: ["png"])
        let outcome = try await FileSystemCodeAnalyzer().analyzeWithCoverage(root: root, options: opts)
        XCTAssertEqual(outcome.metrics.totalLines, 2, "只有 Keep.swift 进入指标")

        let ledger = try await FileSystemCodeAnalyzer()
            .skipLedger(root: root, options: opts, countSkippedLines: true)
        XCTAssertTrue(ledger.linesCounted, "审计模式必须声明自己数过行数")
        XCTAssertEqual(ledger.skippedLineTotal, 7, "3 + 2 + 2 行")
        let diskLines = outcome.metrics.totalLines + ledger.skippedLineTotal
        XCTAssertEqual(diskLines, 9, "纳入 + 剔除 == 磁盘真实行数，一行不差")

        let clearing = ledger.clearing(linesCounted: true)
        XCTAssertEqual(clearing.count, ledger.buckets.count, "每条生效过的原因都要出一行")
        XCTAssertTrue(clearing.contains { $0.contains("排除目录里的文件") && $0.contains("3 行")
            && $0.contains("vendor 3 行") }, "\(clearing)")
        XCTAssertTrue(clearing.contains { $0.contains("语言表未收录的后缀") && $0.contains("cmake") }, "\(clearing)")
        XCTAssertTrue(clearing.contains { $0.contains("无后缀文件") && $0.contains("(无后缀) 2 行") }, "\(clearing)")

        // 非审计模式：行数没数过就必须如实说没数，不许显示 0 行。
        let plain = try await FileSystemCodeAnalyzer().skipLedger(root: root, options: opts)
        XCTAssertFalse(plain.linesCounted)
        let plainLines = plain.clearing(linesCounted: false)
        XCTAssertTrue(plainLines.allSatisfy { !$0.contains(" 0 行") && !$0.contains("· 0 行") },
                      "未审计时不得出现「0 行」这种把缺数据当零的写法：\(plainLines)")
    }

    // MARK: - Q. 覆盖度：上限生效过就不能把结果当全量（WS-D 诚实性审计 P1 #7 / #8）

    /// 被 20 万行/文件上限切过的文件必须留痕，否则 `totalLines` 看起来像全量。
    func testLineCapTruncationIsReported() async throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        _ = try write(String(repeating: "1\n", count: 200_001), to: "huge.swift", in: root)
        _ = try write("let ok = 1\n", to: "normal.swift", in: root)

        let file = try XCTUnwrap(classify(root.appendingPathComponent("huge.swift"), root: root))
        XCTAssertEqual(file.totalLineCount, 200_000, "只保留前 20 万行")
        XCTAssertTrue(file.lineCountTruncated, "必须留痕：这个文件被行数上限切过")
        XCTAssertFalse(try XCTUnwrap(classify(root.appendingPathComponent("normal.swift"), root: root)).lineCountTruncated,
                       "正常文件不得被标成截断")

        let outcome = try await FileSystemCodeAnalyzer().analyzeWithCoverage(root: root, options: options())
        XCTAssertEqual(outcome.coverage.lineTruncatedFileCount, 1)
        XCTAssertTrue(outcome.coverage.isPartial, "有上限生效过 ⇒ 这是部分测量")
        XCTAssertTrue(outcome.coverage.limitationSummary.contains { $0.contains("20 万行") },
                      "限制说明要带真实数字：\(outcome.coverage.limitationSummary)")
    }

    /// `maxFiles` 生效后，覆盖率事实必须能从 `analyze` 的返回值里拿到（原先四个字段全被丢弃）。
    func testFileCapCoverageIsExposed() async throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        for index in 0..<6 { _ = try write("let v\(index) = 1\n", to: "f\(index).swift", in: root) }
        var opts = options(maxFiles: 3)
        let outcome = try await FileSystemCodeAnalyzer().analyzeWithCoverage(root: root, options: opts)
        XCTAssertTrue(outcome.coverage.truncatedByMaxFiles, "6 个文件、上限 3，必须报截断")
        XCTAssertEqual(outcome.coverage.includedFileCount, 3)
        XCTAssertEqual(outcome.metrics.totalFiles, 3, "指标本身只统计进入的部分")
        XCTAssertTrue(outcome.coverage.isPartial)
        XCTAssertTrue(outcome.coverage.limitationSummary.contains { $0.contains("上限") },
                      "\(outcome.coverage.limitationSummary)")
        opts.maxFiles = 100
        let whole = try await FileSystemCodeAnalyzer().analyzeWithCoverage(root: root, options: opts)
        XCTAssertFalse(whole.coverage.truncatedByMaxFiles)
        XCTAssertFalse(whole.coverage.isPartial, "一个上限都没碰到时不得谎称部分测量")
        XCTAssertTrue(whole.coverage.limitationSummary.isEmpty, "\(whole.coverage.limitationSummary)")
    }

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
