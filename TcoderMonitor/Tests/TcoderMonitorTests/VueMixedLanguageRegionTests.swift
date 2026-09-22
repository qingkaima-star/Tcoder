import XCTest
@testable import TcoderMonitor

/// OWNER: R2（Vue / TS 识别与模板字符串）—— Vue 单文件组件的**语言分区**（RD-07 + RD-20 的相关半边）。
///
/// 判据三条，全部对着 `.vue` 一份文件同时成立：
/// 1. **函数识别**归 `<script>`（模板区里的 `@click="() => doThing()"` 不得算函数、不得进复杂度榜）；
/// 2. **注释统计**按所在区域的语言归位（脚本区的 `//`、样式区的 `/* */` 以前都被算成代码行）；
/// 3. **代码行统计**与分区一致，且分区注释率有自己独立的分母（不许把模板/样式注释混进来）。
///
/// 夹具走 `SourceFileClassifier.classify` 这条真路径（要落盘，落在系统临时目录、随测试即建即删，
/// 与 `CodeAnalyzerTests.makeFixtureRoot` 同一约定）；函数侧另有内联构造的旁路。
final class VueMixedLanguageRegionTests: XCTestCase {

    private var fm: FileManager { FileManager.default }

    private func makeRoot() throws -> URL {
        let base = fm.temporaryDirectory.appendingPathComponent("r2-vue-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: false)
        return base
    }

    /// 一份典型 SFC：`<script setup>` 跨多行开标签、模板区内联箭头、样式区块注释、脚本区两种注释。
    private var sfc: [String] {
        [
            /* 1 */ "<template>",
            /* 2 */ "  <div @click=\"() => doThing()\">",
            /* 3 */ "    {{ msg }}",
            /* 4 */ "    <!-- 模板注释 -->",
            /* 5 */ "  </div>",
            /* 6 */ "</template>",
            /* 7 */ "<script",
            /* 8 */ "  setup",
            /* 9 */ "  lang=\"ts\"",
            /* 10 */ ">",
            /* 11 */ "import { ref } from 'vue'",
            /* 12 */ "// 脚本区行注释",
            /* 13 */ "/* 脚本区块注释 */",
            /* 14 */ "const msg = ref('hi')",
            /* 15 */ "function doThing(): void {",
            /* 16 */ "  if (msg.value.length > 0) {",
            /* 17 */ "    console.log(`len ${msg.value.length}`)",
            /* 18 */ "  }",
            /* 19 */ "}",
            /* 20 */ "const secondFn = (n: number): number => {",
            /* 21 */ "  return n + 1",
            /* 22 */ "}",
            /* 23 */ "</script>",
            /* 24 */ "<style scoped>",
            /* 25 */ "/* 样式注释 */",
            /* 26 */ ".box { color: red }",
            /* 27 */ "</style>",
        ]
    }

    private func classifySFC(_ lines: [String], named name: String = "Widget.vue") throws -> ScannedSourceFile {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let url = root.appendingPathComponent(name)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        return try XCTUnwrap(SourceFileClassifier(options: .default).classify(url: url, root: root),
                             "Vue 夹具必须分类成功")
    }

    private func describe(_ candidates: [FunctionCandidate]) -> [String] {
        candidates.map { "\($0.name)@\($0.startLine)..\($0.startLine + $0.lineCount - 1)cc\($0.complexity)" }
    }

    // MARK: - 1. 函数识别归位（RD-05 / RD-07 / RD-06 三头同时成立）

    func testFunctionsComeOnlyFromScriptRegion() throws {
        let file = try classifySFC(sfc)
        let detected = ComplexityEngine.functions(in: file)
        XCTAssertEqual(describe(detected), ["doThing@15..19cc2", "secondFn@20..22cc1"],
                       "脚本区两个函数必须都在、模板/样式区一条都不许多：\(describe(detected))")
        // 模板区的内联箭头 `@click="() => doThing()"`（第 2 行）不得算函数、不得进榜
        XCTAssertFalse(detected.contains { $0.startLine <= 6 },
                       "模板区的内联箭头表达式被当成函数了：\(describe(detected))")
        XCTAssertFalse(detected.contains { $0.startLine >= 24 },
                       "样式区被当成代码了：\(describe(detected))")
        // 第 17 行那个以反引号收尾的模板串以前会把 18 行之后整段吞掉 ⇒ 这里必须是 2 条
        XCTAssertEqual(detected.count, 2, "模板串之后的函数不许消失")
    }

    // MARK: - 2. 注释 / 代码行按区域语言归位

    func testCommentsAreClassifiedByTheirOwnRegion() throws {
        let file = try classifySFC(sfc)
        var kinds: [Int: SourceLineKind] = [:]
        for line in file.lines { kinds[line.number] = line.kind }
        XCTAssertEqual(kinds[4], .comment, "模板区的 <!-- --> 必须按 HTML 判注释")
        XCTAssertEqual(kinds[12], .comment, "脚本区的 // 必须按 TS 判注释（HEAD 判成代码行）")
        XCTAssertEqual(kinds[13], .comment, "脚本区的 /* */ 必须按 TS 判注释（HEAD 判成代码行）")
        XCTAssertEqual(kinds[25], .comment, "样式区的 /* */ 必须按 CSS 判注释（HEAD 判成代码行）")
        XCTAssertEqual(kinds[26], .code, "样式规则本体是代码行")
        XCTAssertEqual(kinds[11], .code, "import 是代码行")
        // 不变式：每行只落一个桶
        let recount = file.lines.reduce((0, 0, 0)) { sum, line in
            switch line.kind {
            case .blank: return (sum.0 + 1, sum.1, sum.2)
            case .comment: return (sum.0, sum.1 + 1, sum.2)
            case .code: return (sum.0, sum.1, sum.2 + 1)
            }
        }
        XCTAssertEqual(recount.1, 4, "整份 SFC 的注释行必须正好是 4 行（模板 1 + 脚本 2 + 样式 1）")
        XCTAssertEqual(file.totalLineCount, file.blankLineCount + file.commentLineCount + file.codeLineCount,
                       "行分桶不变式破了：total ≠ blank + comment + code")
    }

    // MARK: - 3. 分区注释率有自己的分母（RD-20 的相关半边）

    func testRegionTallyKeepsSeparateDenominators() throws {
        let file = try classifySFC(sfc)
        let tally = try XCTUnwrap(file.vueRegionTally, "Vue 文件必须带分区归位读数")
        XCTAssertEqual(tally.scriptCommentLines, 2, "脚本区两条注释")
        XCTAssertEqual(tally.scriptCodeLines, 10,
                       "脚本区代码行 = 11..22 减去两条注释行")
        XCTAssertEqual(tally.templateCommentLines, 1, "模板区注释不得混进脚本区分母")
        XCTAssertEqual(tally.styleCommentLines, 1, "样式区注释不得混进脚本区分母")
        XCTAssertGreaterThan(tally.scriptCommentRatio, 0, "分区注释率必须算得出来")
        XCTAssertEqual(tally.scriptCommentRatio, 2.0 / 12.0, accuracy: 1e-9,
                       "脚本区注释率的分母只能是脚本区自己的行数")
        // 整份文件口径与分区口径必须是两个数，不许互相冒充
        XCTAssertNotEqual(file.commentLineCount, tally.scriptCommentLines,
                          "整份文件的注释数与脚本区的注释数本该不同，相同说明分区没生效")
    }

    // MARK: - 4. 分区认不出来时必须走「未知态」并且出声

    /// `<script>` 不顶格（被缩进了）⇒ SFC 分区识别不出来。
    /// 判据：不许悄悄按「没有模板区」处理，必须给出可展示的未知态。
    func testUnrecognizedSFCBlockIsReportedNotSilentlyIgnored() throws {
        let indented = ["  <template>", "    <b>{{ x }}</b>", "  </template>",
                        "  <script setup lang=\"ts\">", "  function f(): void {", "    x()", "  }",
                        "  </script>"]
        let file = try classifySFC(indented, named: "Indented.vue")
        let outcome = ComplexityEngine.functionsWithIntegrity(in: file)
        XCTAssertTrue(outcome.vueRegionFallback, "顶格判据没命中时必须明说退回了粗判掩码")
        XCTAssertFalse(outcome.limitations.isEmpty, "退回旧口径必须留下可展示的限制说明")
        XCTAssertTrue(outcome.limitations.contains { $0.contains("SFC") },
                      "限制说明里要点名是 SFC 分区没认出来：\(outcome.limitations)")
    }

    /// 未闭合的模板串：文件读完仍在插值里 ⇒ 必须是「部分测量」而不是「这文件没函数」。
    func testUnterminatedTemplateLiteralBecomesPartialMeasurement() throws {
        let lines = ["<script setup lang=\"ts\">",
                     "const broken = `没有收尾的反引号 ${x}",
                     "function later(): void {", "  if (a) { b() }", "}",
                     "</script>"]
        let file = try classifySFC(lines, named: "Broken.vue")
        let outcome = ComplexityEngine.functionsWithIntegrity(in: file)
        XCTAssertTrue(outcome.integrity.hasAnomaly, "未闭合的串必须留下完整性异常")
        XCTAssertGreaterThan(outcome.integrity.endsInsideString + outcome.integrity.endsInsideExpression, 0,
                             "未闭合的串 / 插值必须计数")
        XCTAssertTrue(outcome.limitations.contains { $0.contains("部分测量") },
                      "必须明说这是部分测量：\(outcome.limitations)")
    }

    // MARK: - 5. `<script>` 里的 TS 词法真的在用（分区不是只写在注释里）

    /// 模板区里的一个**未配对**引号不许污染后面的脚本区：
    /// 旧口径整份文件喂同一个状态机，模板区的引号会把后面的代码吃进串里。
    func testUnbalancedQuoteInTemplateCannotPoisonScriptRegion() throws {
        let lines = ["<template>", "  <p>这里有个没配对的引号 \" 和反引号 `</p>", "</template>",
                     "<script setup lang=\"ts\">", "function ok(): void {", "  if (a) { b() }", "}",
                     "const tail = (n: number): number => {", "  return n", "}", "</script>"]
        let file = try classifySFC(lines, named: "Quote.vue")
        let detected = ComplexityEngine.functions(in: file)
        XCTAssertEqual(describe(detected), ["ok@5..7cc2", "tail@8..10cc1"],
                       "模板区里没配对的引号 / 反引号不得吞掉脚本区：\(describe(detected))")
    }

    /// `lang="ts"` 与 `lang="js"` 两种脚本区都要认；缺省按 JavaScript。
    func testScriptLanguageFollowsLangAttribute() throws {
        let ts = ComplexityEngine.detectVueRegions(sfc)
        XCTAssertEqual(ts?.scriptLanguage, "TypeScript", "lang=\"ts\" 必须落到 TypeScript 档案")
        let plain = ComplexityEngine.detectVueRegions(["<script>", "const a = 1", "</script>"])
        XCTAssertEqual(plain?.scriptLanguage, "JavaScript", "没有 lang 属性时按 JavaScript")
        let map = try XCTUnwrap(ts)
        XCTAssertEqual(map.scriptLineCount(), 12, "脚本区行数 = 第 11..22 行（开标签 7..10 与 </script> 第 23 行都不算）")
        XCTAssertEqual(map.regions[0], .structure, "<template> 开标签本身是结构行")
        XCTAssertEqual(map.regions[2], .template, "模板区正文")
        XCTAssertEqual(map.regions[25], .style, "样式区正文")
    }
}
