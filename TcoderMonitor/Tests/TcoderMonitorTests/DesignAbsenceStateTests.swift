import Foundation
import XCTest
@testable import TcoderMonitor

// MARK: - #47「缺数据怎么显示」收敛守卫
//
// 工单原文 = Obsidian《42 WS-G 设计系统基座》§14。本轮把两件事合成一套**有语义的机制**：
//   1. **单点**：WS-L 那份三态 `DataAbsence`（原住 `Views/CodeGit/CodeGitDesignKit.swift`）
//      上提进 `Design/DataAbsence.swift`，成为全仓唯一一份；
//   2. **补第四态** `indeterminate`（除零 / 分母为 0）——它绝不能和 `notAnalysed`
//      （没扫 / 没查）共用同一个 `--`，否则用户分不清「这项目真的没有」和「我们没查」。
//
// 本文件钉六件事：
// A. 四态字面互不相同、都不是空串（`term` 与 `display` 两个口径都钉）；
// B. 无证据的两态（算不出 / 未分析）不许撑出结论性措辞，也不许带倾向色；
// C. §14.1 那 12 处锚点的**行为**：除零三处现在必须给「算不出」，给不出 `--`；
// D. 视觉与读屏同源：`HealthRing.scoreText` 与 `HealthRing.accessibilityText`
//    未评分时必须给**同一个串**，且两个视图出口都只走这两个函数（《42》§14.3 第 2 条）；
// E. 扫描守卫：`Views/**` 里手写 `Theme.Placeholder.missingValue` 的绕过写法**只减不增**，
//    基线 = 本轮改完的实测值（15 → 1，剩下的那处是《42》§14.2 明令保持原样的字段缺失）；
//    另钉「缺数据枚举这一族」只有 `DataAbsence` + `GitDataAbsence` 两个名字，
//    以及单点定义恰好一处、页面调用点有下限。
// F. 元测试三个方向：坏例抓得住、真文件放过、**空输入判失败**（不许「没扫到＝通过」）。
//
// 尺子的有效性是**真探针**验过的（探针已删）：临时加一个 `Views/Code/QaProbeAbsence.swift`
// 塞 3 处手写占位 + 两个新 `*Absence` 枚举 → 本文件当场 4 failures 并指到该文件；
// 临时把 `HealthRing.accessibilityText` 未评分那一支改成「尚未评分」（只改读屏一边）
// → 当场 2 failures。
//
// 扫描判据一律写成**纯函数**（喂字符串进、吐违规出），所以下面能用合成输入双向元测试它。

final class DesignAbsenceStateTests: XCTestCase {

    // MARK: - 扫描器（纯函数）

    struct Hit: Equatable {
        let file: String
        let line: Int
        let text: String
    }

    /// 绕过单点的写法：在 `Views/**` 里直接引用字面本体 `Theme.Placeholder.missingValue`。
    /// （`Design/DataAbsence.swift` 与 `Design/ThemeTokens.swift` 是**定义侧**，不在扫描范围内。）
    static let bypassPattern = #"Theme\.Placeholder\.missingValue"#

    /// 缺数据枚举这一族的全部成员。新增一个就是"第三份实现"回来，必须报总工再登记。
    /// `GitDataAbsence` 是 Git 页的**空态文案**枚举（不是数字位的态），故允许并存。
    static let allowedAbsenceEnums: Set<String> = ["DataAbsence", "GitDataAbsence"]

    /// 单点自身的定义处（全仓必须恰好一处）。
    static let absenceDefinitionPattern = #"^\s*enum\s+DataAbsence\s*:"#

    /// 「名字里带 Absence 的枚举」定义处——用来证明这一族没长出第三份实现。
    static let absenceFamilyPattern = #"\benum\s+([A-Za-z]\w*Absence\w*)\s*:"#

    /// 页面走单点的出口（用来证明「上提之后真有人用」，不是又供起来一个基座件）。
    static let singlePointUsePattern = #"DataAbsence\.[A-Za-z]"#

    /// 《42》§14.2 的排除项：这一处是「注册表没给版本号」的**字段缺失**，
    /// 语义本来就对，明令保持原样。它构成基线里唯一的那 1 处。
    static let excludedBypassSites: Set<String> = [
        "Views/Dependencies/DependencyVerdictRows.swift",
    ]

    private static func isComment(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*")
    }

    /// 按行扫正则。**整行注释豁免**：文档与注释里必须提到被禁的写法，不能因此判违规。
    static func scan(_ pattern: String,
                     in files: [(path: String, content: String)]) throws -> [Hit] {
        let expression = try NSRegularExpression(pattern: pattern, options: [])
        var hits: [Hit] = []
        for file in files {
            for (index, raw) in file.content.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated() {
                let line = String(raw)
                guard !isComment(line) else { continue }
                let range = NSRange(line.startIndex..., in: line)
                if expression.firstMatch(in: line, options: [], range: range) != nil {
                    hits.append(Hit(file: file.path, line: index + 1,
                                    text: line.trimmingCharacters(in: .whitespaces)))
                }
            }
        }
        return hits
    }

    static func describe(_ hits: [Hit]) -> String {
        hits.map { "  \($0.file):\($0.line) \($0.text)" }.joined(separator: "\n")
    }

    /// 按行扫正则并取**第 1 个捕获组**（用来数「叫什么名字」，而不只是数有没有）。
    static func scanNames(_ pattern: String,
                          in files: [(path: String, content: String)]) throws -> [Hit] {
        let expression = try NSRegularExpression(pattern: pattern, options: [])
        var hits: [Hit] = []
        for file in files {
            for (index, raw) in file.content.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated() {
                let line = String(raw)
                guard !isComment(line) else { continue }
                let range = NSRange(line.startIndex..., in: line)
                guard let match = expression.firstMatch(in: line, options: [], range: range),
                      match.numberOfRanges >= 2,
                      let swiftRange = Range(match.range(at: 1), in: line) else { continue }
                hits.append(Hit(file: file.path, line: index + 1, text: String(line[swiftRange])))
            }
        }
        return hits
    }

    /// 真源码。路径按 `#filePath` 上溯到包根，再进 `Sources/TcoderMonitor/<subdirectory>`。
    private static func swiftFiles(under subdirectory: String) -> [(path: String, content: String)] {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TcoderMonitorTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // TcoderMonitor（包根）
        let sourcesRoot = packageRoot.appendingPathComponent("Sources/TcoderMonitor")
        let root = subdirectory.isEmpty ? sourcesRoot
                                        : sourcesRoot.appendingPathComponent(subdirectory)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        var result: [(path: String, content: String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            // 一律给**相对 `Sources/TcoderMonitor`** 的路径（例 `Views/Shell/DashboardHero.swift`），
            // 这样 `subdirectory` 只决定扫哪一片、不改变报错里路径的形状。
            let relative = url.path.hasPrefix(sourcesRoot.path)
                ? String(url.path.dropFirst(sourcesRoot.path.count).drop(while: { $0 == "/" }))
                : url.lastPathComponent
            result.append((path: relative.isEmpty ? url.lastPathComponent : relative, content: content))
        }
        return result.sorted { $0.path < $1.path }
    }

    private static var viewFiles: [(path: String, content: String)] { swiftFiles(under: "Views") }
    private static var allSourceFiles: [(path: String, content: String)] { swiftFiles(under: "") }

    static func fileContent(underViews name: String) throws -> String {
        guard let entry = viewFiles.first(where: { $0.path.hasSuffix(name) }) else {
            XCTFail("扫不到 Views/\(name)——路径口径变了，本文件的扫描断言全是空谈")
            return ""
        }
        return entry.content
    }

    /// 截出某个成员的函数体（从签名那行起，到下一个同缩进的收尾 `}` 为止）。
    /// 够用来钉「这一段里有没有手写串」，不去解析 Swift 语法。
    static func functionBody(of signature: String, in content: String,
                             endingWith terminator: String = "    }") throws -> String {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: { $0.contains(signature) }) else {
            XCTFail("扫不到 `\(signature)`——它被改名或删掉了，同源断言就没人守了")
            return ""
        }
        var body: [String] = [lines[start]]
        for line in lines.dropFirst(start + 1) {
            body.append(line)
            if line.trimmingCharacters(in: .whitespaces) == terminator.trimmingCharacters(in: .whitespaces) {
                break
            }
        }
        XCTAssertEqual(body.count > 1, true, "`\(signature)` 截出来只有签名一行，截取口径坏了")
        return body.joined(separator: "\n")
    }

    // MARK: - 分母闸（防假绿的底座）

    /// 扫不到足够文件，任何「0 违规」都是假的。口径与《68》§4 那道分母闸一致。
    private static let minimumScannedViews = 20
    private static let minimumScannedSources = 40

    /// 本轮收敛完成时的实测基线：**只减不增**。
    /// 改前 15 处（《42》§14.1 逐处清单），改后 1 处 = §14.2 的排除项
    /// （`DependencyRow.body` 的 `latestKnownVersion ?? …`，字段缺失、语义本来就对）。
    static let bypassCeiling = 1

    /// 页面走单点的最少调用处数（下限，不设上限）：12 个锚点改完后实测 13 处。
    /// 只设下限——谁把某一处退回手写，这里就红。
    static let minimumSinglePointUseSites = 12

    // MARK: - A. 四态字面

    /// 四个态**各自的中文字面**互不相同、都不是空串。
    /// `indeterminate` ≠ `notAnalysed` 是这张工单存在的理由，单独再钉一条（见下一条）。
    func testFourStateLiteralsAreMutuallyDistinctAndNonEmpty() {
        let states: [(name: String, term: String, display: String)] = [
            ("value", DataAbsence.value("42").term, DataAbsence.value("42").display),
            ("measuredEmpty", DataAbsence.measuredEmpty.term, DataAbsence.measuredEmpty.display),
            ("indeterminate", DataAbsence.indeterminate.term, DataAbsence.indeterminate.display),
            ("notAnalysed", DataAbsence.notAnalysed.term, DataAbsence.notAnalysed.display),
        ]
        XCTAssertEqual(states.count, 4, "四态少一个，这张工单就白做")
        for state in states {
            XCTAssertFalse(state.term.isEmpty, "\(state.name) 的态名字面是空串")
            XCTAssertFalse(state.display.isEmpty, "\(state.name) 的显示字面是空串")
        }
        XCTAssertEqual(Set(states.map(\.term)).count, 4,
                       "四态字面撞车：\(states.map { "\($0.name)=\($0.term)" })")
        XCTAssertEqual(Set(states.map(\.display)).count, 4,
                       "四态数字位字面撞车：\(states.map { "\($0.name)=\($0.display)" })")
    }

    /// 最关键的一条：除零不能借用「没查」的 `--`。
    func testIndeterminateNeverSharesTheNotAnalysedLiteral() {
        XCTAssertNotEqual(DataAbsence.indeterminate.display, DataAbsence.notAnalysed.display,
                          "「算不出」与「未分析」共用同一个字面，用户就没法分清"
                              + "「这项目真的没有」和「我们没查」——本轮收敛的就是这件事")
        XCTAssertNotEqual(DataAbsence.indeterminate.term, DataAbsence.measuredEmpty.term,
                          "「分母为 0」也不是「查了但是空的」")
        XCTAssertEqual(DataAbsence.notAnalysed.display, Theme.Placeholder.missingValue,
                       "「没查」仍是全仓那个 `--`，字面本体只有一个定义处")
    }

    /// 真 0 与「查了但是空的」都必须和「没查」不同：`0` 是结论，不许塌成占位符。
    func testRealZeroAndMeasuredEmptyStayApartFromNotAnalysed() {
        XCTAssertEqual(DataAbsence.value("0").display, "0")
        XCTAssertEqual(DataAbsence.measuredEmpty.display, NumberFormat.grouped(0))
        XCTAssertNotEqual(DataAbsence.measuredEmpty.display, DataAbsence.notAnalysed.display)
        XCTAssertNotEqual(DataAbsence.value("0").display, DataAbsence.notAnalysed.display)
    }

    /// 文字槽位（日期 / 名称）：`measuredEmpty` 在那里渲染成 `0` 会被读成假数字，
    /// 所以它另有字面；而 `--` 仍只有「没查」这一态在用。
    func testTextSlotsNeverRenderMeasuredEmptyAsAFakeNumber() {
        XCTAssertEqual(DataAbsence.measuredEmpty.textDisplay, "无记录")
        XCTAssertNotEqual(DataAbsence.measuredEmpty.textDisplay, DataAbsence.measuredEmpty.display)
        XCTAssertEqual(DataAbsence.value("2024-01-02").textDisplay, "2024-01-02")
        XCTAssertEqual(DataAbsence.notAnalysed.textDisplay, DataAbsence.notAnalysed.display)
        XCTAssertEqual(DataAbsence.indeterminate.textDisplay, DataAbsence.indeterminate.display)
    }

    // MARK: - B. 无证据不许带结论

    func testStatesWithoutEvidencePermitNoConclusion() {
        XCTAssertTrue(DataAbsence.value("3").permitsConclusion)
        XCTAssertTrue(DataAbsence.measuredEmpty.permitsConclusion,
                      "「查了、确实是空的」本身就是结论，这一态可以给定心丸语气")
        XCTAssertFalse(DataAbsence.indeterminate.permitsConclusion,
                       "算不出撑不起一句安心话")
        XCTAssertFalse(DataAbsence.notAnalysed.permitsConclusion, "没查更不行")
    }

    func testEvidenceFreeStatesForceNeutralRole() {
        for state in [DataAbsence.indeterminate, .notAnalysed] {
            XCTAssertEqual(state.effectiveRole(Theme.Semantic.success).name, "neutral",
                             "\(state) 态不该保留调用方给的倾向色")
        }
        XCTAssertEqual(DataAbsence.value("0").effectiveRole(Theme.Semantic.success).name, "success",
                       "真值（含真 0）的着色归调用方")
        XCTAssertEqual(DataAbsence.measuredEmpty.effectiveRole(Theme.Semantic.success).name, "success")
    }

    /// 悬停口径：`indeterminate` 必须说出分母是什么（§14.3 第 1 条的「或加 help:」这一支），
    /// 且三句说明彼此不同、都不许出现「没问题 / 正常」这类结论词。
    func testHelpSentencesDifferAndNameTheDenominator() {
        XCTAssertNil(DataAbsence.value("7").help(denominator: "总行数"))
        let text = DataAbsence.indeterminate.help(denominator: "总行数") ?? ""
        XCTAssertTrue(text.contains("总行数"), "算不出这一态的 help 必须点出分母：\(text)")
        XCTAssertTrue(text.contains("0"), "算不出这一态要说明是分母为 0：\(text)")
        for fragment in ["没问题", "正常", "无风险"] {
            XCTAssertFalse(text.contains(fragment), "help 里不许藏结论词「\(fragment)」：\(text)")
        }
        let notAnalysed = DataAbsence.notAnalysed.help() ?? ""
        let measuredEmpty = DataAbsence.measuredEmpty.help() ?? ""
        XCTAssertEqual(Set([text, notAnalysed, measuredEmpty]).count, 3,
                       "三种空位的说明撞成一句，用户还是分不清")
        XCTAssertTrue(notAnalysed.contains("没"), "「没查」的说明要认得出是没查：\(notAnalysed)")
        XCTAssertTrue(measuredEmpty.contains("已完成扫描"),
                      "「查了但是空的」必须交代查过（《40》§7.3 句式）：\(measuredEmpty)")
    }

    /// `optional(absent:)` 把「选哪一态」变成形参：调用点被迫表态，不许默认糊过去。
    func testOptionalConstructorKeepsTheStateChoiceExplicit() {
        XCTAssertEqual(DataAbsence.optional(nil), .notAnalysed, "不表态时默认「没查」")
        XCTAssertEqual(DataAbsence.optional(nil, absent: .indeterminate), .indeterminate)
        XCTAssertEqual(DataAbsence.optional("8"), .value("8"))
        XCTAssertEqual(DataAbsence.optional("", absent: .notAnalysed), .value(""),
                       "空串是调用方给的真值，不能顺手当缺失")
    }

    // MARK: - C. §14.1 锚点的行为：除零三处必须是「算不出」

    func testDivideByZeroAnchorsRenderAsIndeterminate() {
        XCTAssertEqual(CodeMetricsSummaryGrid.shareOf(10, CodeMetrics()),
                       DataAbsence.indeterminate.display,
                       "总行数 0 → 占比算不出，不是没扫")
        XCTAssertEqual(CodeScaleSection.averageFileLines(CodeMetrics()),
                       DataAbsence.indeterminate.display,
                       "行数与文件数都是 0 → 平均算不出")
        XCTAssertEqual(CodeRiskAnalysis.averageComplexityValue(CodeMetrics(totalFiles: 1, totalLines: 10)),
                       DataAbsence.indeterminate.display,
                       "一个函数都没识别出来 → 均值算不出，既不是 0 也不是没扫")
        for anchor in [CodeMetricsSummaryGrid.shareOf(10, CodeMetrics()),
                       CodeScaleSection.averageFileLines(CodeMetrics()),
                       CodeRiskAnalysis.averageComplexityValue(CodeMetrics())] {
            XCTAssertNotEqual(anchor, Theme.Placeholder.missingValue,
                              "锚点又退回和「没查」共用 `--`，语义塌陷回来了")
        }
    }

    /// 分母在场时照实给比值——不许把「算不出」当成新的偷懒默认值到处盖。
    func testRatiosStillRenderWhenTheDenominatorExists() {
        XCTAssertEqual(CodeMetricsSummaryGrid.shareOf(0, CodeMetrics(totalFiles: 4, totalLines: 100)), "0%",
                       "真 0% 是结论")
        XCTAssertEqual(CodeScaleSection.averageFileLines(CodeMetrics(totalFiles: 4, totalLines: 40)), "10.0")
    }

    func testContributorShareUsesIndeterminateNotNotAnalysed() {
        // `authorShare` 在分母（非合并提交数）为 0 时给 nil；这一格的 help 原文就写着「占比无法计算」。
        let git = GitInsights()
        let author = AuthorStats(name: "张三", email: "z@e.com", commits: 1,
                                 additions: 2, deletions: 3, filesTouched: 1,
                                 firstCommitAt: nil, lastCommitAt: nil,
                                 activityByHour: [], topDirectories: [:])
        XCTAssertNil(git.authorShare(of: author),
                     "夹具要造的是「分母为 0」，不然这条测试没在量东西")
        let absence = DataAbsence.optional(git.authorShare(of: author).map { NumberFormat.percent($0) },
                                           absent: .indeterminate)
        XCTAssertEqual(absence, .indeterminate)
        XCTAssertEqual(absence.display, DataAbsence.indeterminate.display)
        XCTAssertNotEqual(absence.display, DataAbsence.notAnalysed.display)
    }

    /// 「首次提交」这一格：空仓库（查了、真的没有）与没跑分析（没查）是两句话。
    func testFirstCommitCaptionSeparatesEmptyRepositoryFromNoAnalysis() {
        XCTAssertEqual(GitRepositoryInfoSection.firstCommitCaption(GitInsights()),
                       DataAbsence.notAnalysed.display, "压根不是仓库 / 没跑分析 → 没查")
        XCTAssertEqual(GitRepositoryInfoSection.firstCommitCaption(
                           GitInsights(isRepository: true, totalCommits: 0)),
                       DataAbsence.measuredEmpty.textDisplay,
                       "是仓库且 0 次提交 → 查了、真的没有，这一态不能写成 `--`")
        XCTAssertNotEqual(GitRepositoryInfoSection.firstCommitCaption(
                              GitInsights(isRepository: true, totalCommits: 0)),
                          GitRepositoryInfoSection.firstCommitCaption(GitInsights()),
                          "两态撞回同一个字面，就是本轮要修的毛病")
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(GitRepositoryInfoSection.firstCommitCaption(
                           GitInsights(isRepository: true, totalCommits: 3, firstCommitAt: stamp)),
                       DateFormat.full.string(from: stamp))
    }

    /// WS-M 三页的本地单点 `Live.missing` 现在只是全仓单点的一个别名，不再是第二处字面定义。
    func testLiveMissingIsAnAliasOfTheSinglePoint() {
        XCTAssertEqual(Live.missing, DataAbsence.notAnalysed.display)
        XCTAssertTrue(Live.isMissing(Live.missing))
        XCTAssertFalse(Live.isMissing("0"), "真 0 不是占位符")
        XCTAssertEqual(Live.text(nil), Live.missing)
    }

    /// `MetricTile` 的 `value: nil` 也必须从单点取字面（总览四枚 tile 走的就是这条路）。
    func testMetricTileMissingValueComesFromTheSinglePoint() {
        XCTAssertEqual(MetricTile.displayValue(nil), DataAbsence.notAnalysed.display)
        XCTAssertEqual(MetricTile.displayValue("0"), "0", "真 0 必须原样显示")
    }

    // MARK: - D. 视觉与读屏同源（《42》§14.3 第 2 条）

    func testHealthRingScoreTextIsTheUnscoredLiteral() {
        XCTAssertEqual(HealthRing.scoreText(for: nil), DataAbsence.notAnalysed.display,
                       "未评分属「没查」这一态，字面归单点")
        XCTAssertNotEqual(HealthRing.scoreText(for: nil), HealthRing.scoreText(for: 0),
                          "「未评分」与「0 分」若同串，等于把没查说成最差")
        XCTAssertEqual(HealthRing.scoreText(for: 87), "87")
    }

    /// **同源的行为判据**：未评分时，读屏出口必须与视觉出口给**同一个串**。
    /// 任何一边单独改措辞（哪怕改成的还是 `--` 的近义句），这里就红。
    func testHealthRingVoiceOverAndVisualGiveTheSameStringWhenUnscored() {
        XCTAssertEqual(HealthRing.accessibilityText(score: nil, grade: nil, trend: nil),
                       HealthRing.scoreText(for: nil),
                       "眼睛看到 `--`、VoiceOver 念出另一句——《42》§14.3 第 2 条就是防这个")
        XCTAssertEqual(HealthRing.accessibilityText(score: nil, grade: .a, trend: 3),
                       HealthRing.scoreText(for: nil),
                       "未评分时等级与趋势都不该给读屏添第二句说法")
        let scored = HealthRing.accessibilityText(score: 87, grade: .a, trend: 3)
        XCTAssertTrue(scored.contains(HealthRing.scoreText(for: 87)),
                      "有评分时读屏里的数字也得来自同一个出口：\(scored)")
        XCTAssertTrue(scored.contains("分"), scored)
    }

    /// 两个出口还都得**真的**从这两个唯一函数取串：谁在视图里就地拼字面，扫描判红。
    func testHealthRingVisualAndVoiceOverOutletsBothGoThroughOneFunction() throws {
        let hero = try Self.fileContent(underViews: "Shell/DashboardHero.swift")
        let readoutBody = try Self.functionBody(of: "private func readout(role:", in: hero)
        let summaryBody = try Self.functionBody(
            of: "private var accessibilitySummary:", in: hero, endingWith: "    }")
        XCTAssertTrue(readoutBody.contains("Self.scoreText(for:"),
                      "HealthRing.readout 没走 scoreText(for:) 这个唯一视觉出口：\n" + readoutBody)
        XCTAssertTrue(summaryBody.contains("Self.accessibilityText("),
                      "HealthRing.accessibilitySummary 没走 accessibilityText(…) 这个唯一读屏出口：\n"
                          + summaryBody)
        for (name, body) in [("readout", readoutBody), ("accessibilitySummary", summaryBody)] {
            XCTAssertFalse(body.contains("--"),
                           "HealthRing.\(name) 里又手写了一遍占位字面，改措辞时只会改到一边：\n" + body)
            XCTAssertFalse(body.contains("Theme.Placeholder"),
                           "HealthRing.\(name) 绕开单点直接取字面本体：\n" + body)
        }
    }

    // MARK: - E. 扫描守卫：绕过单点的手写写法只减不增

    func testScanActuallyFindsEnoughFilesToBeMeaningful() throws {
        XCTAssertGreaterThan(Self.viewFiles.count, Self.minimumScannedViews,
                             "只扫到 \(Self.viewFiles.count) 个 Views 文件，口径坏了")
        XCTAssertGreaterThan(Self.allSourceFiles.count, Self.minimumScannedSources,
                             "只扫到 \(Self.allSourceFiles.count) 个源文件，口径坏了")
    }

    func testHandWrittenPlaceholderBypassesNeverIncrease() throws {
        let files = Self.viewFiles
        XCTAssertGreaterThan(files.count, Self.minimumScannedViews,
                             "扫不到 Views，下面那条上限断言就是永真绿")
        let hits = try Self.scan(Self.bypassPattern, in: files)
        let unexpected = hits.filter { !Self.excludedBypassSites.contains($0.file) }
        XCTAssertTrue(unexpected.isEmpty,
                      """
                      《42》§14.2 之外还有 \(unexpected.count) 处手写 `Theme.Placeholder.missingValue`，
                      它们绕开了 `Design/DataAbsence.swift` 这个单点，请改成取某一态的 `display`：
                      \(Self.describe(unexpected))
                      基线：改前 15 处 → 本轮改完实测 \(hits.count) 处（上限 \(Self.bypassCeiling)）。
                      """)
        XCTAssertLessThanOrEqual(hits.count, Self.bypassCeiling,
                                 "绕过单点的写法从 \(Self.bypassCeiling) 处涨到 \(hits.count) 处：\n"
                                     + Self.describe(hits))
    }

    /// 排除项也要被钉住：§14.2 那处是「字段缺失」，它若消失说明有人顺手改了不该改的，
    /// 若变多说明有人拿它当挡箭牌塞新的。
    func testTheExcludedFieldMissingSiteStaysExactlyOne() throws {
        let hits = try Self.scan(Self.bypassPattern, in: Self.viewFiles)
        let excluded = hits.filter { Self.excludedBypassSites.contains($0.file) }
        XCTAssertEqual(excluded.count, 1,
                       "《42》§14.2 的排除项应当恰好 1 处，实际 \(excluded.count) 处：\n"
                           + Self.describe(excluded))
    }

    /// 单点必须仍是单点：`enum DataAbsence` 全仓恰好一个定义，
    /// 且它住在 `Design/`（#47 上提的理由就是别再让页面各留一份）。
    func testAbsenceEnumIsDefinedExactlyOnceInsideDesign() throws {
        let files = Self.allSourceFiles
        XCTAssertGreaterThan(files.count, Self.minimumScannedSources, "扫不到源码，这条恰好一个的断言会空转")
        let definitions = try Self.scan(Self.absenceDefinitionPattern, in: files)
        XCTAssertEqual(definitions.count, 1,
                       "缺数据态的定义必须全仓唯一，实际定义处：\n" + Self.describe(definitions))
        XCTAssertTrue(definitions.first?.file.hasSuffix("Design/DataAbsence.swift") == true,
                      "唯一那份应在 Design/DataAbsence.swift，实际在 \(definitions.first?.file ?? "nil")")
    }

    /// 这一族不许长出第三份实现（历史上正是「基座一份 / WS-L 一份 / WS-M 一份」并存，
    /// 结果同一个「空」在三页有三种说法）。`GitDataAbsence` 是 Git 页的空态**文案**枚举，
    /// 不管数字位，允许并存；再冒第三个名字就要报总工，别默默加进白名单。
    func testAbsenceEnumFamilyHasNoThirdImplementation() throws {
        let files = Self.allSourceFiles
        XCTAssertGreaterThan(files.count, Self.minimumScannedSources, "扫不到源码，这条白名单断言会空转")
        let names = Set(try Self.scanNames(Self.absenceFamilyPattern, in: files).map(\.text))
        XCTAssertEqual(names, Self.allowedAbsenceEnums,
                       "缺数据枚举这一族的成员变了：期望 \(Self.allowedAbsenceEnums.sorted())，"
                           + "实际 \(names.sorted())——多出来的那份就是第二套语义")
    }

    /// 上提之后必须**真有人用**（《42》§14.3 第 3 条：不许基座预建等待接入的壳）。
    func testPagesActuallyRouteThroughTheSinglePoint() throws {
        let files = Self.viewFiles
        let uses = try Self.scan(Self.singlePointUsePattern, in: files)
        XCTAssertGreaterThanOrEqual(uses.count, Self.minimumSinglePointUseSites,
                                    "页面走单点的处数掉到 \(uses.count)（下限 \(Self.minimumSinglePointUseSites)）"
                                        + "——说明有锚点被改回手写：\n" + Self.describe(uses))
        // 12 个锚点所在文件都要么引单点、要么本来就没有手写占位。
        for anchorFile in ["Views/DashboardView.swift", "Views/Shell/ProjectSidebar.swift",
                           "Views/Shell/DashboardHero.swift", "Views/Code/CodeMetricsView.swift",
                           "Views/Code/CodeRiskRows.swift", "Views/Git/ContributorRows.swift",
                           "Views/Git/GitInsightsSections.swift", "Views/PerfLogs/LiveReadings.swift"] {
            let entry = files.first { $0.path.hasSuffix(anchorFile) }
            XCTAssertNotNil(entry, "锚点文件 \(anchorFile) 扫不到")
            let usesHere = try Self.scan(Self.singlePointUsePattern, in: [entry ?? ("", "")])
            XCTAssertFalse(usesHere.isEmpty, "\(anchorFile) 不再引用 DataAbsence，§14.1 的锚点被改回去了")
        }
    }

    // MARK: - 元测试：证明上面这把尺子量得动东西

    private static func synthetic(_ path: String, _ lines: String...) -> (path: String, content: String) {
        (path: path, content: lines.joined(separator: "\n"))
    }

    /// 坏例抓得住：合成输入里埋 4 处绕过写法（含同文件多处），必须全数到并指到文件。
    func testMetaBypassDetectorCatchesSyntheticHits() throws {
        let bad = [Self.synthetic("Views/X/FakeA.swift",
                                  "import SwiftUI",
                                  "    Text(snapshot.map { \"\\($0)\" } ?? Theme.Placeholder.missingValue)",
                                  "    guard let read else { return Theme.Placeholder.missingValue }",
                                  "// 注释里再提一次 Theme.Placeholder.missingValue 不算违规",
                                  "    static let missing = Theme.Placeholder.missingValue"),
                   Self.synthetic("Views/Y/FakeB.swift",
                                  "        ?? Theme.Placeholder.missingValue")]
        let hits = try Self.scan(Self.bypassPattern, in: bad)
        XCTAssertEqual(hits.count, 4, "埋了 4 处代码违规（另有 1 行注释要放过），数错就是尺子坏了")
        XCTAssertEqual(Set(hits.map(\.file)), ["Views/X/FakeA.swift", "Views/Y/FakeB.swift"],
                       "报错必须指到文件，不然谁来修")
    }

    /// 好例不误伤：真·改完的 Views 扫出来必须只剩排除项那 1 处；
    /// 同时 `term` 之类的合规引用、注释里的历史提法都不该被抓。
    func testMetaBypassDetectorIgnoresCompliantSites() throws {
        let good = [Self.synthetic("Views/X/Compliant.swift",
                                   "// 以前这里写 `?? Theme.Placeholder.missingValue`，#47 改走单点",
                                   "    Text(DataAbsence.notAnalysed.display)",
                                   "    let term = DataAbsence.indeterminate.term",
                                   "    .help(absence.help(denominator: \"总行数\"))")]
        let hits = try Self.scan(Self.bypassPattern, in: good)
        XCTAssertTrue(hits.isEmpty, "合规写法被误伤，守卫撑不过一轮就会被人为删掉：\n" + Self.describe(hits))
        let real = try Self.scan(Self.bypassPattern, in: Self.viewFiles)
        XCTAssertEqual(Set(real.map(\.file)), Self.excludedBypassSites,
                       "改完的真实文件里只剩 §14.2 那 1 处，多一个就是本轮没做完")
        XCTAssertEqual(try Self.scan(Self.singlePointUsePattern, in: good).count, 2,
                       "单点调用计数扫不动，那条下限断言就是摆设")
    }

    /// 假绿防线：**空输入必须判失败**，不能因为「一条违规都没找到」就通过。
    func testMetaEmptyScanCanNeverSatisfyTheGuards() throws {
        let none: [(path: String, content: String)] = []
        let bypasses = try Self.scan(Self.bypassPattern, in: none)
        let definitions = try Self.scan(Self.absenceDefinitionPattern, in: none)
        let uses = try Self.scan(Self.singlePointUsePattern, in: none)
        XCTAssertTrue(bypasses.isEmpty, "空输入下绕过写法当然是空的——正因如此才要下面三条")
        XCTAssertNotEqual(definitions.count, 1, "空输入不该满足「恰好一个定义」")
        XCTAssertLessThan(uses.count, Self.minimumSinglePointUseSites,
                          "空输入不该满足单点调用下限，否则那条守卫是永真绿")
        XCTAssertLessThan(Self.swiftFiles(under: "NoSuchDirectory").count, Self.minimumScannedViews,
                          "路径写错却扫到「足够多」文件，分母闸就是假的")
        XCTAssertGreaterThan(Self.viewFiles.count, Self.minimumScannedViews,
                             "真源码扫不到文件 = 路径坏了，上面所有元测试通过也没意义")
    }

    /// 元测试的元测试：检测表与基线本身不许被清空 / 放宽。
    func testMetaGuardInputsAreStillLoadBearing() {
        XCTAssertFalse(Self.excludedBypassSites.isEmpty,
                       "排除集被清空的话，§14.2 那处会天天判红，守卫只会被删")
        XCTAssertEqual(Self.bypassCeiling, 1,
                       "基线当前应当恰好等于 §14.2 排除项的 1 处；往上调就是给绕过写法开口子")
        XCTAssertGreaterThanOrEqual(Self.minimumSinglePointUseSites, 12,
                                    "12 个锚点是这张工单的最低产出，下限被调低就等于活没干")
        XCTAssertGreaterThan(Self.minimumScannedViews, 0)
        XCTAssertGreaterThan(Self.minimumScannedSources, 0)
    }
}
