import Foundation
import XCTest
@testable import TcoderMonitor

// MARK: - WS-W 三页（性能 / 日志 / 健康）的「简约无界」守卫
//
// 权威 = spec §1 风格契约 + §4.2 逐页自查清单，加上总工 2026-09-20 补的两条
// （`tint:` 不得收 `Theme.Semantic.info/accent`；`MetricTile` 的 `tint:` 不得收图表序列色）。
//
// 三条写文件时就定下的规矩：
//   1. **每条扫描判据都配元测试**（造违规样本确认它会红）。理由见记忆
//      「扫描型测试要配元测试」：本轮的病因之一就是守卫只查「有没有散写魔法数」，
//      查不出「定义了没人用」，于是 `Spacing.section` 零引用烂了一整轮。
//      一条扫不到东西的守卫和一条失灵了的守卫，在输出上长得一模一样。
//   2. 复用总工在 `BorderlessSurfaceGuardTests` 里那份 `sourceFiles(under:)` / `codeLines(_:)`
//      —— 不另起一套路径口径，两把尺子量同一个东西才能互相比对。
//   3. 脏样本里凡是标了「HEAD 原文」的，是从 `415f0f0` 逐字抄下来的**改前代码**，
//      不是编出来的稻草人：守卫必须能抓到历史上真实存在过的那个形状。

final class PerfLogsBorderlessTests: XCTestCase {

    static let ownedDirectories = ["Performance", "Logs", "Health", "PerfLogs"]

    // MARK: - 扫描器（纯函数，供合成输入元测试）

    /// 一条 `.tertiary` 所在的**修饰链** = 它自己那一行，往上直到（并包含）第一条
    /// 不以 `.` 开头的行；碰到空行、或以 `{` / `}` 结尾的行就停。
    ///
    /// 为什么要成链而不是只看一行：SwiftUI 里读数的写法是
    /// `Text(Live.bytes(x))` ↵ `.font(...)` ↵ `.foregroundStyle(.tertiary)`，
    /// 只看 `.tertiary` 那一行的话，**每一处跨行链都漏**，守卫会稳定假绿。
    /// 为什么必须封顶：往上一个空行/一个 `}` 之外就是**兄弟语句**了，
    /// 把它一起算进来会把邻居的测得值误记到这条链上（《45》里 awk 块越界的同类坑）。
    static func modifierChain(around index: Int, in lines: [String]) -> [String] {
        let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(".") else { return [lines[index]] }
        var chain = [lines[index]]
        var j = index - 1
        while j >= 0 {
            let up = lines[j].trimmingCharacters(in: .whitespaces)
            if up.isEmpty || up.hasSuffix("{") || up.hasSuffix("}") { break }
            chain.append(lines[j])
            if !up.hasPrefix(".") { break }   // 锚行（`Text(…)`）收进来就停
            j -= 1
        }
        return chain
    }

    /// 读数格式化器的字面。链里出现任意一个 = 这条 `Text` 承载的是**测得值**。
    static let measuredValueMarkers = [
        "Live.", "NumberFormat.", "ByteFormat.", "DataAbsence", "LiveNumber", "value:",
    ]

    /// 落在测得值上的 `.tertiary`。
    static func tertiaryOnMeasuredValues(in files: [(path: String, content: String)]) -> [String] {
        files.flatMap { file -> [String] in
            let lines = BorderlessSurfaceGuardTests.codeLines(file.content)
            var found: [String] = []
            for index in lines.indices where lines[index].contains(".tertiary") {
                let chain = modifierChain(around: index, in: lines)
                let carriesReading = chain.contains { line in
                    measuredValueMarkers.contains(where: line.contains)
                }
                if carriesReading { found.append("\(file.path):\(index + 1)") }
            }
            return found
        }
    }

    /// `MetricTile(` / 格子调用点上的 `tint:` 收**交互色**（info / accent）的位置。
    /// 只扫 `tint:` 具名实参这一种形状 —— `.tint()` 修饰器服务的是控件（如
    /// `DisclosureGroup`），那里 accent 合法，不是一刀切的对象。
    static func interactiveTintOnTiles(in files: [(path: String, content: String)]) -> [String] {
        hits(in: files, where: { line in
            line.contains("tint: Theme.Semantic.info") || line.contains("tint: Theme.Semantic.accent")
        })
    }

    /// `tint:` 收图表**序列色**（`ChartSeries.color(`）的位置 —— 序列色属于图与图例，
    /// 不属于数字。
    static func seriesColoredTiles(in files: [(path: String, content: String)]) -> [String] {
        hits(in: files, where: { $0.contains("tint: ChartSeries.color(") })
    }

    /// `areaTopOpacity` 的**定义行**没走 `Opacity.gradientAreaSoft` 令牌的位置。
    /// 只要行里同时有 `areaTopOpacity` 和 `=`，就算定义行
    /// （使用处是 `color.opacity(areaTopOpacity)`，没有 `=`，不会误伤）。
    static func areaOpacityDefinitionsNotUsingToken(in files: [(path: String, content: String)]) -> [String] {
        hits(in: files, where: { line in
            line.contains("areaTopOpacity") && line.contains("=")
                && !line.contains("Opacity.gradientAreaSoft")
        })
    }

    /// 图表层里 `Theme.Chart` 分类板的引用位置。三页**每张图只有一条序列**，
    /// 没有需要分辨「哪条是哪条」的场合，于是分类色在这里必然为零。
    static func categoryPaletteUses(in files: [(path: String, content: String)]) -> [String] {
        hits(in: files, where: { $0.contains("Theme.Chart") })
    }

    /// 把「相邻分组间距 ≥ 24」量出来的那条判据：
    /// 从 `spacing: Theme.Spacing.<档>` 起按**大括号深度**找到容器闭合，
    /// 途中出现直接子项 `GlassSection(` 就说明这个间距管的是**组间**，
    /// 低于 24 即为拥挤。
    static func containersTighteningGroups(in files: [(path: String, content: String)]) -> [String] {
        var hits: [String] = []
        for file in files {
            let lines = BorderlessSurfaceGuardTests.codeLines(file.content)
            for index in lines.indices {
                guard let tier = spacingTier(in: lines[index]),
                      !sufficientGroupTiers.contains(tier) else { continue }
                var depth = 0
                var j = index
                while j < lines.count {
                    depth += lines[j].filter { $0 == "{" }.count
                    depth -= lines[j].filter { $0 == "}" }.count
                    if j > index {
                        if lines[j].contains("GlassSection(") {
                            hits.append("\(file.path):\(index + 1) [\(tier)] 组间距低于 24")
                            break
                        }
                        if depth <= 0 { break }
                    }
                    j += 1
                }
            }
        }
        return hits
    }

    static let sufficientGroupTiers: Set<String> = ["group", "section", "xxl", "xl"]

    static func spacingTier(in line: String) -> String? {
        guard let range = line.range(of: "spacing: Theme.Spacing.") else { return nil }
        let tail = line[range.upperBound...]
        return String(tail.prefix { $0.isLetter })
    }

    /// 每个 `struct` 里某符号的出现次数 —— 「一枚 hero 主角」这类判据的作用域单位。
    /// 健康页有两处 `HealthRing(`，但分别在 `HealthHero` 与 `HealthNoInputCard`
    /// 两个互斥分支里，所以「整页 ≤ 2」是假松、「同一 struct 内 ≤ 1」才是真判据。
    static func symbolCountPerStruct(named symbol: String,
                                     in files: [(path: String, content: String)]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for file in files {
            var scope = file.path
            for line in BorderlessSurfaceGuardTests.codeLines(file.content) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let keyword: String?
                if trimmed.hasPrefix("struct ") { keyword = "struct " }
                else if trimmed.hasPrefix("enum ") { keyword = "enum " }
                else { keyword = nil }
                if let keyword {
                    let name = trimmed.dropFirst(keyword.count)
                        .prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                    if !name.isEmpty { scope = "\(file.path).\(name)" }
                }
                counts[scope, default: 0] += line.contains(symbol) ? 1 : 0
            }
        }
        return counts
    }

    /// 页面目录里自己养的**页头类型**声明。
    /// 「页头」（项目名 / 路径 / 分析时间 / 右侧控件）全仓只许一套画法，
    /// 归 `Views/ProjectDetailView.swift` 与 `Views/Shell/**`（WS-O 名下）。
    static func pageHeaderDeclarations(in files: [(path: String, content: String)]) -> [String] {
        hits(in: files, where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("struct ") && trimmed.contains(": View")
                && trimmed.contains("PageHeader")
        })
    }

    static func hits(in files: [(path: String, content: String)],
                             where predicate: (String) -> Bool) -> [String] {
        files.flatMap { file in
            BorderlessSurfaceGuardTests.codeLines(file.content)
                .enumerated()
                .filter { _, line in predicate(line) }
                .map { "\(file.path):\($0.offset + 1)" }
        }
    }

    func ownedFiles() throws -> [(path: String, content: String)] {
        let all = try BorderlessSurfaceGuardTests.sourceFiles(under: "Views")
        let picked = all.filter { file in
            Self.ownedDirectories.contains { file.path.hasPrefix("Views/\($0)/") }
        }
        XCTAssertEqual(picked.count, 17,
                       "只扫到 \(picked.count) 个文件（应为 17：性能 6 + 日志 5 + 健康 3 + 共用层 3）。"
                       + "目录或文件数变了先改这条，否则下面所有扫描都在空气上判通过。")
        return picked
    }

    // MARK: - ① 测得值上不得有 `.tertiary`

    // MARK: - ② 健康分 nil 必须仍是 neutral / 空心

    // MARK: - ③ 每页最多一枚 heroMetric

    // MARK: - ④ 相邻分组间距 ≥ 24

    // MARK: - ⑤ 曲线面积顶色走令牌，不走字面量

    // MARK: - ⑥⑦（总工补）tile 的 tint 收支

    // MARK: - 元测试：证明上面每条尺子都量得动东西

}
