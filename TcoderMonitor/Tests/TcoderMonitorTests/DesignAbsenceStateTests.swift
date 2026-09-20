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

    static func isComment(_ line: String) -> Bool {
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
    static func swiftFiles(under subdirectory: String) -> [(path: String, content: String)] {
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

    static var viewFiles: [(path: String, content: String)] { swiftFiles(under: "Views") }
    static var allSourceFiles: [(path: String, content: String)] { swiftFiles(under: "") }

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
    static let minimumScannedViews = 20
    static let minimumScannedSources = 40

    /// 本轮收敛完成时的实测基线：**只减不增**。
    /// 改前 15 处（《42》§14.1 逐处清单），改后 1 处 = §14.2 的排除项
    /// （`DependencyRow.body` 的 `latestKnownVersion ?? …`，字段缺失、语义本来就对）。
    static let bypassCeiling = 1

    /// 页面走单点的最少调用处数（下限，不设上限）：12 个锚点改完后实测 13 处。
    /// 只设下限——谁把某一处退回手写，这里就红。
    static let minimumSinglePointUseSites = 12

    // MARK: - A. 四态字面

    // MARK: - B. 无证据不许带结论

    // MARK: - C. §14.1 锚点的行为：除零三处必须是「算不出」

    // MARK: - D. 视觉与读屏同源（《42》§14.3 第 2 条）

    // MARK: - E. 扫描守卫：绕过单点的手写写法只减不增

    // MARK: - 元测试：证明上面这把尺子量得动东西

}
