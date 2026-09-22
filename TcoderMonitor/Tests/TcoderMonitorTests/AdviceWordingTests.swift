import XCTest
@testable import TcoderMonitor

// OWNER: R7 建议与榜长真修（RD-41「建议必须与语言匹配」）
//
// ## 这条守卫要修的是什么（修前可复现）
//
// `FileSystemCodeAnalyzer.splitSuggestion` 里那一支「有超长函数」的建议，
// 在 HEAD 之前对**任何**语言都吐同一句：
//
//     先把这些函数按职责抽成独立类型或同类型的 extension
//
// `extension` 是 Swift（以及 Kotlin/Dart）的语法关键字，TypeScript / Java / Python / Go
// 里根本没有这个东西。⇒ 一个 900 行的 `.ts` 文件收到的"可执行建议"，
// 是让它写一种该语言不存在的构造。这不是"建议不够好"，是**建议不可执行**。
//
// ## 独立真值（不拿实现输出当答案）
//
// ① 每种语言有没有 `extension`/`impl`/`trait`/`partial class`/`mixin`/`category`，
//    由本文件下面那张 `constructHome` 表**自己列**（语言常识，不抄实现）；
// ② 建议句里的三个数字（超长函数个数 / 最长行数 / 文件行数）由夹具**手工数出来**，
//    见 `fixtureTruth`——不是从扫描结果里读回来比对的。
//
// ## 四态
//
// 正例 Swift→出 `extension`、反例 TS→必须不出、未知 `supportedLanguages` 之外的语言→中性说法、
// 失败 未被识别出函数的分支 与 元测试（checker 对坏样例必须报、对注释里的样例必须不报）。

final class AdviceWordingTests: XCTestCase {

    // MARK: - 独立真值表

    /// 拉丁语法词 → **真正有**这个构造的语言（测试侧自己列的表）。
    ///
    /// 为什么不抄实现：抄了就成了"实现说啥测试信啥"，实现把 `extension` 发给 TypeScript
    /// 时测试会跟着一起绿。这张表唯一的根据是语言本身有没有这个关键字。
    static let constructHome: [String: Set<String>] = [
        "extension": ["Swift", "Kotlin", "Dart"],
        "impl": ["Rust"],
        "trait": ["Rust", "PHP", "Scala"],
        "partial class": ["C#"],
        "mixin": ["Ruby", "Dart", "Scala"],
        "category": ["Objective-C"],
    ]

    /// 夹具真值：一个 TypeScript 文件，函数体行数是**手数**出来的。
    /// `parseTarget` 61 行、`renderLegend` 55 行 ⇒ 超过 50 行的 2 个；`tiny` 30 行不算。
    static let fixtureTruth = (longCount: 2, longest: 61, fileLines: 150, threshold: 50)

    // MARK: - 判据

    /// 一句话里出现的、**不属于该语言**的语法词（词边界比对：`implement` 不算 `impl`）。
    static func foreignConstructs(in phrase: String, for language: String) -> [String] {
        constructHome.compactMap { token, homes in
            guard !homes.contains(language), containsWord(token, in: phrase) else { return nil }
            return token
        }
    }

    static func containsWord(_ token: String, in text: String) -> Bool {
        let pattern = "(?<![\\w])" + NSRegularExpression.escapedPattern(for: token) + "(?![\\w])"
        let re = try! NSRegularExpression(pattern: pattern, options: [])
        let range = NSRange(text.startIndex..., in: text)
        return re.firstMatch(in: text, options: [], range: range) != nil
    }

    /// 内存里造一个被扫文件（不落盘，避免污染本仓自扫分母）。
    static func scannedFile(language: String, lines: Int) -> ScannedSourceFile {
        ScannedSourceFile(
            url: URL(fileURLWithPath: "/r7-advice/Fixture.\(language.lowercased())"),
            relativePath: "Fixture.\(language.lowercased())",
            language: language,
            lines: (1...max(1, lines)).map { SourceLine(number: $0, text: "line \($0)", kind: .code) },
            blankLineCount: 0, commentLineCount: 0, codeLineCount: max(1, lines),
            todoCount: 0, fixmeCount: 0)
    }

    /// 同一份函数形状、只换语言名：建议句就是这么产出来的。
    static func suggestion(for language: String) -> String {
        let functions = [
            FunctionCandidate(name: "parseTarget", startLine: 3, lineCount: fixtureTruth.longest,
                              parameterCount: 2, complexity: 9),
            FunctionCandidate(name: "renderLegend", startLine: 70, lineCount: 55,
                              parameterCount: 1, complexity: 4),
            FunctionCandidate(name: "tiny", startLine: 130, lineCount: 30,
                              parameterCount: 0, complexity: 2),
        ]
        return FileSystemCodeAnalyzer().splitSuggestion(for: scannedFile(language: language,
                                                                        lines: fixtureTruth.fileLines),
                                                       functions: functions)
    }

    // MARK: - ① 逐语言相容性（全量扫 `supportedLanguages`，不是挑三个说）

    func test_splitAdviceConstructExistsInItsOwnLanguageForEverySupportedLanguage() throws {
        let languages = SourceLanguageCatalog.supportedLanguages
        XCTAssertGreaterThanOrEqual(languages.count, 20,
                                    "语言目录只扫出 \(languages.count) 个 —— 分母塌了，这条断言就是永真绿")
        var checked = 0
        for language in languages {
            let phrase = FileSystemCodeAnalyzer.splitConstruct(for: language)
            XCTAssertFalse(phrase.isEmpty, "\(language) 的拆分说法是空串")
            let offenders = Self.foreignConstructs(in: phrase, for: language)
            XCTAssertTrue(offenders.isEmpty,
                          "\(language) 拿到一句它自己写不出的建议：\(phrase) —— 句里的 \(offenders)")
            checked += 1
        }
        XCTAssertEqual(checked, languages.count)
        print("RD-41：逐语言查过 \(checked) 种语言的拆分建议，越界语法词 0 处")
    }

    /// 全量扫的不只是短语，而是**整句建议**：模板里再硬编码一个语法词也会被这句抓到。
    func test_wholeSuggestionSentenceCarriesNoForeignConstruct() throws {
        for language in SourceLanguageCatalog.supportedLanguages {
            let offenders = Self.foreignConstructs(in: Self.suggestion(for: language), for: language)
            XCTAssertTrue(offenders.isEmpty, "\(language) 的整句建议里出现外来语法词：\(offenders)")
        }
    }

    // MARK: - ② 正例 / 反例 / 未知 / 失败 四态

    /// 正例：Swift 文件**照旧**拿到 `extension` —— 修这个 bug 不许把建议磨成废话。
    func test_swiftFileStillGetsExtensionAdvice() {
        let text = Self.suggestion(for: "Swift")
        XCTAssertTrue(text.contains("extension"), "Swift 的建议里 `extension` 被一起删掉了：\(text)")
        XCTAssertTrue(Self.foreignConstructs(in: text, for: "Swift").isEmpty)
    }

    /// 反例（立案原样）：TypeScript 文件绝不能再看到 `extension`。
    func test_typescriptFileDoesNotGetSwiftSyntaxAdvice() {
        let text = Self.suggestion(for: "TypeScript")
        XCTAssertFalse(text.contains("extension"), "TS 文件仍被建议写 Swift 语法：\(text)")
        XCTAssertEqual(Self.foreignConstructs(in: text, for: "TypeScript"), [])
        XCTAssertTrue(text.contains("TypeScript"), "建议句里连语言名都没了：\(text)")
    }

    /// 未知态：语言表里查不到 ⇒ 走中性说法，而中性说法**不含表里任何一个语法词**。
    func test_unknownLanguageFallsBackToNeutralPhrase() {
        for language in ["脑裂语言", "", "MadeUpLang", "未知"] {
            let phrase = FileSystemCodeAnalyzer.splitConstruct(for: language)
            XCTAssertEqual(phrase, FileSystemCodeAnalyzer.neutralSplitConstruct, "\(language) 没走中性说法")
            let vocabulary = Self.constructHome.keys.filter { Self.containsWord($0, in: phrase) }
            XCTAssertTrue(vocabulary.isEmpty, "中性说法里混进了语法词 \(vocabulary)")
        }
    }

    /// 失败态：这一支**没有被识别出的函数**时走另两条模板，同样不许漏出语法词。
    func test_noFunctionBranchesStayLanguageNeutral() throws {
        let functions: [FunctionCandidate] = []
        for language in SourceLanguageCatalog.supportedLanguages {
            let text = FileSystemCodeAnalyzer().splitSuggestion(
                for: Self.scannedFile(language: language, lines: 400), functions: functions)
            XCTAssertTrue(Self.foreignConstructs(in: text, for: language).isEmpty,
                          "\(language) 的无函数建议里出现外来语法词：\(text)")
        }
    }

    // MARK: - ③ 数字来自哪把尺子（独立真值 + 常量对账，坑 ② 的形状）

    /// 建议句里的三个数字必须与**手数的夹具**一致，且门槛数字来自冻结常量而不是手抄。
    func test_adviceNumbersMatchHandCountedFixtureAndFrozenConstants() {
        let text = Self.suggestion(for: "Swift")
        XCTAssertTrue(text.contains("含 2 个超过 50 行的函数"),
                      "超长函数个数或门槛与夹具真值 \(Self.fixtureTruth.longCount)/\(Self.fixtureTruth.threshold) 不符：\(text)")
        XCTAssertTrue(text.contains("最长 61 行"), "最长函数行数不是手数的 \(Self.fixtureTruth.longest)：\(text)")
        XCTAssertTrue(text.contains("TypeScript") || text.contains("Swift"))
        // 常量对账：实现里的门槛若被改动，先红在"常量分叉"上，而不是留一句读不懂的建议。
        XCTAssertEqual(FileSystemCodeAnalyzer.longFunctionThreshold, Self.fixtureTruth.threshold,
                       "实现侧 longFunctionThreshold 与本文件真值表分叉了")
        XCTAssertEqual(FileSystemCodeAnalyzer.mediumFileLines, 400,
                       "实现侧 mediumFileLines 变了 —— 那句「目标单文件 N 行」现在建议的是别的数")
    }

    // MARK: - ④ 元测试：判据有牙，且不咬注释里的样例

    func test_meta_foreignCheckerCatchesTheRealBug() {
        // 坏样例 = 修前那句原话喂给 TypeScript。必须报。
        XCTAssertEqual(Self.foreignConstructs(in: "抽成独立类型或同类型的 extension", for: "TypeScript"),
                       ["extension"], "判据抓不到修前的真实缺陷 —— 这是一条永真绿守卫")
        // 同一句喂给 Swift 必须干净（双向的另一侧）。
        XCTAssertTrue(Self.foreignConstructs(in: "抽成独立类型或同类型的 extension", for: "Swift").isEmpty)
        // 词边界自证：`implement` / `example impl` 里不能误伤 `impl`。
        XCTAssertTrue(Self.foreignConstructs(in: "implement the example", for: "TypeScript").isEmpty,
                      "词边界没生效，`implement` 被当成 Rust 的 `impl`")
        XCTAssertEqual(Self.foreignConstructs(in: "另一个 impl 块", for: "Swift"), ["impl"])
    }

    /// 源码级钉子：语法词只能出现在 `CodeRiskAssessment.swift` 那张表里。
    /// 第二处硬编码（比如有人在建议模板里再写一次 `extension`）当场红。
    func test_hardcodedConstructLivesOnlyInsideTheLanguageTable() throws {
        let offenders = try Self.hardcodedConstructSites()
        XCTAssertTrue(offenders.allSatisfy { $0.hasPrefix("Services/Code/CodeRiskAssessment.swift:") },
                      "建议文案里出现了第二处硬编码的语言专有构造：\n" + offenders.joined(separator: "\n"))
        XCTAssertFalse(offenders.isEmpty,
                       "一条语法词都没扫到 —— 扫描面或剥注释失效，这条钉子是永真绿")
        print("RD-41 源码钉子：语法词字面量 \(offenders.count) 处，全部点名在语言表所在文件")
    }

    static func hardcodedConstructSites() throws -> [String] {
        var out: [String] = []
        for subpath in ["Services/Code", "Views/Code"] {
            for file in try SurfaceScanKit.sourceFiles(under: subpath) where isAdviceFile(file.path) {
                for (index, line) in file.content.components(separatedBy: "\n").enumerated() {
                    guard SurfaceScanKit.isCode(line) else { continue }   // 讲代码的话不算违例
                    for token in constructHome.keys where inQuotedLiteral(token, line: line) {
                        out.append("\(file.path):\(index + 1) 「\(token)」 "
                            + line.trimmingCharacters(in: .whitespaces))
                    }
                }
            }
        }
        return out
    }

    /// 只认「产出建议的那三类文件」，避免把词法识别链里的关键字表（`FunctionPatterns` 等）当违例。
    static func isAdviceFile(_ path: String) -> Bool {
        ["CodeRiskAssessment.swift", "CodeRiskAdvice.swift", "CodeRiskRows.swift"]
            .contains { path.hasSuffix($0) }
    }

    /// 语法词必须**在双引号字面量里面**才算：Swift 自己的 `extension Foo { }` 声明不是建议文案。
    static func inQuotedLiteral(_ token: String, line: String) -> Bool {
        line.components(separatedBy: "\"").enumerated().contains { offset, chunk in
            offset % 2 == 1 && containsWord(token, in: chunk)
        }
    }

    /// 反向元测试：注释里写旧写法**必须不掉分**（本仓扫源码的守卫栽过六次的那条）。
    func test_meta_sourceScanSparesCommentsAndDeclarations() {
        let synthetic = """
            // 修前写着「抽成同类型的 extension」，那是 Swift 语法
            /// extension 在 TypeScript 里不存在
            extension CodeRiskAnalysis { }
            let text = "先把这些函数按职责抽成独立类型或同类型的 extension"
            """
        let lines = synthetic.components(separatedBy: "\n")
        var hits: [Int] = []
        for (index, line) in lines.enumerated() where SurfaceScanKit.isCode(line) {
            if Self.constructHome.keys.contains(where: { Self.inQuotedLiteral($0, line: line) }) {
                hits.append(index + 1)
            }
        }
        XCTAssertEqual(hits, [4], "只有第 4 行（字面量）该被抓到；注释里的样例或 Swift 的 extension 声明被抓 = 咬自己人")
    }
}
