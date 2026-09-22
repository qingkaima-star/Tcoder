import XCTest
@testable import TcoderMonitor

/// OWNER: R12（非代码读数流）—— RD-42：`LexIntegrity.nonCodeRegionLineCount`「有写无读」收口。
///
/// 立案事实（grep 原文见交回汇报①，不是推测）：`nonCodeRegionLineCount` 从 R2 起就在算
/// （`ComplexitySanitizer.swift` 里逐行累加 + `merged` 跨区累加），全仓**一个读者都没有**：
/// 既不在 `hasAnomaly` 也不在 `limitations` ⇒ 「分区认出来了、N 行归位为非代码」一件没说；
/// 而「分区**没**认出来」是另一条在出声（`vueRegionFallbackFileCount` 进限制账、进 `isPartial`）。
///
/// 本文件钉四件事：
/// 1. **正例 + 独立真值**：自建 `.vue` 夹具，行数**手写死在这里**（template 12 · style 8 ·
///    SFC 标签 6 = 26），字段值必须等于手写的数，且界面/CLI 那句话真的带这个数；
/// 2. **反例（真护栏）**：这句话**不进** `scanLimitations` —— 那条在 CLI 被打成「未量准 N 条」，
///    而 template/style 是**已经量到了**、只是分类不同，塞进去就是把「未量准」灌虚高；
/// 3. **未知态**：分区没认出来的那些文件**不许**被算成「已归位」，同时原有那句「可能混进了
///    代码统计」必须仍然成立，两句同时在场、互不覆盖；
/// 4. **缺席**：没有混合语言文件的语料 ⇒ 整句不出声；旧 JSON 缺这个键必须仍能解码成 `nil`。
///
/// 夹具落在**被测仓库之外**的沙箱：包内 `.scratch/`（AGENTS §1.6 定的落点，已 gitignore），即建即删。
/// ⚠️ 刻意**不**继承 `SelfScanHarnessCase`：那台夹具会复用共享扫描缓存，一个 30 行的 `.vue`
///    落进本仓自扫面会动到「巨大文件 / 榜单」那一族基线数字。
final class NonCodeRegionReadoutTests: XCTestCase {

    private static let packageRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Tests/TcoderMonitorTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // TcoderMonitor（包根）

    // MARK: - 独立真值（手写在测试里，**不是**实现自己的输出）

    /// `Widget.vue`：按 SFC 约定顶格的三个顶层块。手写归位账 —— 照夹具内容一行行数出来的：
    /// template 正文 12 · style 正文 8 · SFC 标签行 6（三个开标签 + 三个闭标签）
    /// ⇒ 非代码 **26** 行；脚本区 4 行（import / 签名 / return / 闭括号），合计 30 行。
    private static let templateBody = 12
    private static let styleBody = 8
    private static let sfcTags = 6
    private static let scriptLines = 4
    private static var nonCode: Int { templateBody + styleBody + sfcTags }      // 26
    private static var total: Int { nonCode + scriptLines }                     // 30

    private var widgetVue: [String] {
        ["<template>"]
            + (1...Self.templateBody).map { "  <p>a\($0)</p>" }
            + ["</template>",
               "<script setup lang=\"ts\">",
               "import { ref } from 'vue'",
               "export function useThing(): number {",
               "  return 1",
               "}",
               "</script>",
               "<style scoped>"]
            + (1...Self.styleBody).map { "  .n\($0) { color: red }" }
            + ["</style>"]
    }

    /// 分区**没**认出来的形状：顶层块全部被缩进（顶格判据不命中）⇒ 退回旧的粗判掩码。
    /// 这 8 行里有标签也有模板正文 —— 实现若把它们算进「已归位」就是虚报。
    private var indentedVue: [String] {
        ["  <template>", "    <b>{{ x }}</b>", "  </template>",
         "  <script setup lang=\"ts\">", "  function f(): void {", "    x()", "  }", "  </script>"]
    }

    private var pureSwift: [String] {
        ["import Foundation",
         "enum Greeter {",
         "    static func hello(_ name: String) -> String {",
         "        return \"hi \\(name)\"",
         "    }",
         "}"]
    }

    // MARK: - 沙箱与取数

    /// 写夹具 → 走**产品侧同一条**扫描口（与 `analyze` 同一次遍历，字段 / 台账 / 限制账同源）。
    private func scan(_ files: [String: [String]], tag: String) async throws
        -> FileSystemCodeAnalyzer.AnalysisOutcome {
        let fm = FileManager.default
        let root = Self.packageRoot
            .appendingPathComponent(".scratch/r12-noncode-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? fm.removeItem(at: root) }
        for (name, lines) in files {
            try Data((lines.joined(separator: "\n") + "\n").utf8)
                .write(to: root.appendingPathComponent(name), options: .atomic)
        }
        return try await FileSystemCodeAnalyzer().analyzeWithCoverage(root: root, options: .default)
    }

    private func report(_ metrics: CodeMetrics) -> ProjectReport {
        var full = ProjectReport(project: MonitoredProject(name: "r12夹具", path: "/scratch/r12"))
        full.code = metrics
        return full
    }

    // MARK: - ① 正例：字段 == 手写的独立真值，两处出口那句话真的带这个数

    func testFieldEqualsHandWrittenLineCounts() async throws {
        XCTAssertEqual(Self.nonCode, 26, "手写账自己就先数错了，下面的断言不作数")
        XCTAssertEqual(widgetVue.count, Self.total, "夹具行数与手写账不符，先修夹具")
        XCTAssertEqual(indentedVue.count, 8)

        let outcome = try await scan(["Widget.vue": widgetVue, "Greeter.swift": pureSwift], tag: "positive")
        let metrics = outcome.metrics
        XCTAssertEqual(metrics.totalFiles, 2, "分母不对：夹具里就两个文件")
        XCTAssertEqual(metrics.nonCodeRegionLineCount, Self.nonCode,
                       "字段必须等于手写的那 26 行（template 12 + style 8 + SFC 标签 6）")
        XCTAssertGreaterThan(metrics.codeLines, 0, "脚本区与 Swift 文件必须仍然进代码统计")

        let note = try XCTUnwrap(MixedLanguageRegionCaliber.note(metrics), "有 26 行归位却不出口径句")
        XCTAssertTrue(note.contains(String(Self.nonCode)),
                      "口径句必须带字段里那个数，不许含一个凭空的约数：\(note)")
        XCTAssertTrue(note.contains(MixedLanguageRegionCaliber.marker), note)
        XCTAssertFalse(note.contains("排除"),
                       "写成「排除了 N 行」就是「没扫」的意思，与事实相反：\(note)")
    }

    func testScoreTextCarriesTheNumberWithoutInflatingTheLimitationCount() async throws {
        let outcome = try await scan(["Widget.vue": widgetVue, "Greeter.swift": pureSwift], tag: "cli")
        let text = CLIScoreText.render(report(outcome.metrics), exit: .ok)
        XCTAssertTrue(text.contains("另有 26 行"), "CLI 侧这句话必须带同一个数：\n\(text)")
        XCTAssertFalse(text.contains("未量准"),
                       "这份夹具一个上限都没碰到，却有混合语言文件 ⇒ 一句口径都不许挤进「未量准」：\n\(text)")
    }

    // MARK: - ② 反例（真护栏）：这条**不进** `scanLimitations`

    func testThisSentenceNeverEntersTheLimitationLedger() async throws {
        let outcome = try await scan(["Widget.vue": widgetVue, "Greeter.swift": pureSwift], tag: "reverse")
        let limits = outcome.metrics.scanLimitations ?? []
        XCTAssertFalse(limits.contains { $0.contains(MixedLanguageRegionCaliber.marker) },
                       "「按分区归位」被塞进限制账了 ⇒ CLI 的「未量准 N 条」会被灌虚高：\(limits)")
        // 更强的形状：限制账的**条数**必须正好等于台账自己那两本账（限制 + 口径顶格句），
        // 一枚直传字段没地方偷偷 +1。
        let ledgerCount = outcome.coverage.limitationSummary.count + outcome.coverage.surfaceNotes.count
        XCTAssertEqual(limits.count, ledgerCount,
                       "scanLimitations 与台账产出对不上账（多出来的那条就是被塞进来的）："
                       + "限账 \(limits) / 台账 \(ledgerCount)")
    }

    // MARK: - ③ 未知态：没认出分区的不算「已归位」，原有那句必须仍在

    func testUnrecognizedRegionsStillGoToTheLimitationLedger() async throws {
        let outcome = try await scan(["Indented.vue": indentedVue], tag: "unknown")
        XCTAssertEqual(outcome.coverage.vueRegionFallbackFileCount, 1, "分区没认出来必须留名")
        let sentence = try XCTUnwrap(
            outcome.metrics.scanLimitations?.first { $0.contains("可能混进了代码统计") },
            "「分区没认出来」那句必须仍在限制账里：\(outcome.metrics.scanLimitations ?? [])")
        XCTAssertTrue(sentence.contains("1"), sentence)
        XCTAssertEqual(outcome.metrics.nonCodeRegionLineCount, 0,
                       "没认出分区的文件一行都不算「已归位」，退回旧掩码就是量到的 0")
        XCTAssertNil(MixedLanguageRegionCaliber.note(outcome.metrics),
                     "0 行却打一句「另有 0 行」= 把没发生的事画出来")
    }

    /// 同一份夹具里两种都有：口径句只算**已认出分区**的那部分，两句同时成立、互不覆盖。
    func testCaliberSentenceAndFallbackSentenceCoexistWithoutContradiction() async throws {
        let outcome = try await scan(["Widget.vue": widgetVue, "Indented.vue": indentedVue], tag: "both")
        XCTAssertEqual(outcome.coverage.vueRegionFallbackFileCount, 1)
        XCTAssertEqual(outcome.metrics.nonCodeRegionLineCount, Self.nonCode,
                       "未知态那 8 行被算进「已归位」了 —— 读数只能算认出分区的部分")
        let note = try XCTUnwrap(MixedLanguageRegionCaliber.note(outcome.metrics))
        XCTAssertTrue(note.contains("26"), note)
        let text = CLIScoreText.render(report(outcome.metrics), exit: .ok)
        XCTAssertTrue(text.contains("未量准 "),
                      "这份夹具的限制账至少含「分区没认出来」那一句：\n\(text)")
        XCTAssertFalse(text.contains("边界：另有 26 行"),
                       "口径句被当成「未量准」的一条打上去了：\n\(text)")
        XCTAssertTrue(text.contains("口径：另有 26 行"), text)
    }

    // MARK: - ④ 缺席：干净语料一个字都不许多；旧 JSON 缺键仍能解码

    func testCleanCorpusStaysSilentAndFieldIsMeasuredZero() async throws {
        let outcome = try await scan(["Greeter.swift": pureSwift], tag: "absence")
        XCTAssertEqual(outcome.metrics.nonCodeRegionLineCount, 0,
                       "纯 Swift 语料：跑过了、没有需要分区的区域 ⇒ 量到的 0，不是 nil")
        XCTAssertNil(MixedLanguageRegionCaliber.note(outcome.metrics), "干净的扫描不许多一个字")
        XCTAssertFalse(CLIScoreText.render(report(outcome.metrics), exit: .ok).contains("非代码分区"))
    }

    func testOldJSONWithoutTheKeyStillDecodesAndStaysUnknown() throws {
        var metrics = CodeMetrics()
        metrics.nonCodeRegionLineCount = nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metrics)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("nonCodeRegionLineCount"),
                       "没量到就该整键缺席，而不是写 0（0 会被读成「这个仓库没有混合语言文件」）")
        let back = try JSONDecoder.tcoderReportDecoder().decode(CodeMetrics.self, from: data)
        XCTAssertNil(back.nonCodeRegionLineCount, "缺键 = 这份报告没有这个读数，不许补 0")
        XCTAssertNil(MixedLanguageRegionCaliber.note(back), "旧报告没有这一格 ⇒ 句子只能沉默，不许编数")
    }

    // MARK: - ⑤ 结构守卫：这一格必须既有写者、又有两个出口的读者
    //
    // RD-42 立案的就是「有写无读」，所以除行为之外再钉一条**扫描型**守卫；
    // 扫描型守卫按本仓规矩必须自带「故意改坏就能红」的元测试 —— 见下面 `testMeta_...`。

    private struct Witness: Equatable {
        var writers: [String] = []
        var exits: [String] = []
        var assemblerReadsField: [String] = []
    }

    private func sourceFiles() throws -> [(path: String, body: String)] {
        let root = Self.packageRoot.appendingPathComponent("Sources/TcoderMonitor")
        let urls = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }) ?? []
        XCTAssertGreaterThanOrEqual(urls.count, 40, "扫描面只有 \(urls.count) 个文件，分母不对")
        return urls.map { url in
            (String(url.path.dropFirst(Self.packageRoot.path.count + 1)),
             (try? String(contentsOf: url, encoding: .utf8)) ?? "")
        }
    }

    /// 纯函数：喂「路径 + 内容」得出「谁在写 / 谁在读」。**剥掉注释行** ——
    /// 注释里点名这个字段的地方很多（本文件的说明就是），让它们凑证据等于永真绿。
    private func witnesses(_ files: [(path: String, body: String)]) -> Witness {
        var seen = Witness()
        for file in files {
            let code = file.body.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("//") == false }
            if code.contains(where: { $0.contains("metrics.nonCodeRegionLineCount =") }) {
                seen.writers.append(file.path)
            }
            if code.contains(where: { $0.contains("MixedLanguageRegionCaliber.note(") }) {
                seen.exits.append(file.path)
            }
            if code.contains(where: { $0.contains("static func note(_ code: CodeMetrics)") }),
               code.contains(where: { $0.contains("code.nonCodeRegionLineCount") }) {
                seen.assemblerReadsField.append(file.path)
            }
        }
        return seen
    }

    func testFieldHasExactlyOneWriterAndTwoExitsAsReaders() throws {
        let found = witnesses(try sourceFiles())
        XCTAssertEqual(found.writers, ["Sources/TcoderMonitor/Services/Code/FileSystemCodeAnalyzer.swift"],
                       "写这一格的只能有一处（引擎直传）。多一处就是第二把尺子，没有就是回到有读无写")
        XCTAssertEqual(found.assemblerReadsField,
                       ["Sources/TcoderMonitor/Services/Code/SourceScanScopeReadout.swift"],
                       "口径句的唯一装配口必须真的读那枚字段：\(found.assemblerReadsField)")
        XCTAssertTrue(found.exits.contains("Sources/TcoderMonitor/Views/Code/CodeMetricsView.swift"),
                      "界面那格读者被摘掉了 ⇒ 三种诚实度又回来了：\(found.exits)")
        XCTAssertTrue(found.exits.contains("Sources/TcoderMonitor/Services/CLI/CLIScoreText.swift"),
                      "CLI 不再读它 ⇒ 看界面的人与读终端的人拿到两种诚实度：\(found.exits)")
    }

    /// 元测试（有牙证明）：三个方向各破坏一次，守卫必须各红一次；注释里点名不算读者。
    func testMeta_witnessScannerCatchesEveryBrokenShape() throws {
        let real = try sourceFiles()
        let base = witnesses(real)
        XCTAssertEqual(base.writers.count, 1, "真源码这份连基线都不成立，元测试不作数")
        XCTAssertEqual(base.exits.count, 2, "基线里出口读者就该是界面 + CLI 两处：\(base.exits)")

        let cli = "Sources/TcoderMonitor/Services/CLI/CLIScoreText.swift"
        let view = "Sources/TcoderMonitor/Views/Code/CodeMetricsView.swift"
        let assembler = "Sources/TcoderMonitor/Services/Code/SourceScanScopeReadout.swift"
        let analyzer = "Sources/TcoderMonitor/Services/Code/FileSystemCodeAnalyzer.swift"

        // ① 摘掉 CLI 那个读者（换成别的句）⇒ 出口少一条、且少的必须正是 CLI。
        let lostCLI = witnesses(real.map { file in
            file.path == cli
                ? (file.path, file.body.replacingOccurrences(of: "MixedLanguageRegionCaliber.note(code)",
                                                             with: "SomethingElse.said(code)"))
                : file
        })
        XCTAssertEqual(lostCLI.exits, [view], "摘掉 CLI 读者没被抓到 ⇒ 这条守卫永真绿")

        // ② 擦掉唯一那处直传 ⇒ 写者归零（就是 RD-42 立案的那个形态反过来）。
        let noWriter = witnesses(real.filter { $0.path != analyzer })
        XCTAssertEqual(noWriter.writers, [], "把唯一的直传处擦掉而守卫仍报有写者 ⇒ 没牙")

        // ③ 装配口不读字段了（改成从中文句子里抠数）⇒ 必须判红。
        let blindAssembler = witnesses(real.map { file in
            file.path == assembler
                ? (file.path, file.body.replacingOccurrences(of: "code.nonCodeRegionLineCount", with: "code.codeLines"))
                : file
        })
        XCTAssertEqual(blindAssembler.assemblerReadsField, [], "装配口不再读那枚字段却没报 ⇒ 没牙")

        // ④ 只在**注释**里点名这个装配口，不许被算成读者（否则守卫数的是文档不是代码）。
        let commentOnly = witnesses([(path: "Sources/TcoderMonitor/Views/Dummy.swift",
                                      body: "// 读者见 `MixedLanguageRegionCaliber.note(code)`\nimport Foundation")])
        XCTAssertEqual(commentOnly.exits, [], "注释凑成了读者 ⇒ 这条守卫会在文档里找到证据")
    }
}
