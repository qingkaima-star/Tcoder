import Foundation
import XCTest
@testable import TcoderMonitor

/// WS-P「简约无界」五页守卫（代码规模 / 复杂度风险 / Git 洞察 / 贡献者 / 依赖分析）。
///
/// **作用域**只限 `Views/Code`、`Views/Git`、`Views/Dependencies`、`Views/CodeGit`
/// 四个目录 = 本轮派发给 WS-P 的五页加它们的公共基座。`Design/**` 与 `App/Theme.swift`
/// 归总工，由既成的 `BorderlessSurfaceGuardTests` / `DesignTokenTests` 守，这里不重复。
///
/// ## 为什么断言长成这个样子
///
/// 四条主诉（不规整拥挤 / 滥用投影 / 整页发黑脏 / 没有主次）没有一条是「某页写错了」，
/// 全都是**同一套写法在五页各复制了一遍**。所以本文件没有一条"数量阈值"式断言
/// （那种只会逼人把违规挪到别处），每条都是「这种写法在本流目录里不该再有写法可以表达」：
///
/// - 主角只能有一枚，且 56pt 与纯墨只从一个原语 `DataHeroReadout` 出来。
/// - 分组节奏只能从命名容器 `DataPageScaffold` / `PageParagraph` / `GroupStack` 出来。
/// - 井只能包表格，且只能通过 `DataTableWell`；读数不得有面。
/// - 交互色只能待在交互件里。
///
/// ## 元测试是硬要求，不是仪式
///
/// 扫描型断言最经典的死法是「分母为空」：目录改名、界符写错、文件被移动，
/// 于是全部零命中、绿灯、债原样留着。本项目已经真栽过一次（这正是
/// `CodeGitRestyleTests.testRatchetPatternsActuallyDetectTheirOwnViolations` 存在的理由）。
/// 所以每个扫描器都配**双向**样本：脏样本必须被抓到，干净样本不得被误判；
/// 外加 `test_sourceScannerActuallyFindsFiles` 反向自证真读到了 15 个文件。
final class CodeGitBorderlessTests: XCTestCase {

    // MARK: - 页面归属表

    /// 五个页面各自包含哪些文件。`Code/CodeViewSupport.swift` 按主归属记在「代码规模」，
    /// `Git/GitInsightsCharts.swift` 记在「Git 洞察」。
    /// 若将来有人把第二枚主角塞进共用文件，这里会让该页变红 —— 那是 fail-safe，
    /// 正确反应是把主角挪回它自己的页面文件，不是给共用文件开豁免。
    static let pageFiles: [String: [String]] = [
        "代码规模": ["Code/CodeMetricsView.swift", "Code/CodeMetricsSections.swift"],
        "复杂度风险": ["Code/CodeRiskView.swift", "Code/CodeRiskRows.swift"],
        "Git 洞察": ["Git/GitInsightsView.swift", "Git/GitInsightsSections.swift",
                     "Git/GitInsightsCharts.swift"],
        "贡献者": ["Git/ContributorsView.swift", "Git/ContributorRows.swift"],
        "依赖分析": ["Dependencies/DependenciesView.swift",
                     "Dependencies/DependencyVerdictRows.swift",
                     "Dependencies/NetworkOptionsCard.swift"],
    ]

    /// 本守卫的扫描目录。少扫一个就等于给那一页开后门。
    static let scannedDirs = ["Code", "Git", "Dependencies", "CodeGit"]

    /// 页面目录（不含公共基座 `CodeGit`）。`CodeGitRestyleTests.forbiddenRawValues`
    /// 里那几条 `pagesOnly` 禁令豁免基座，因为「不许页面写」的写法正是基座对外提供
    /// 实现的地方。本守卫沿用同一口径。
    static let pageDirs = ["Code", "Git", "Dependencies"]

    // MARK: - 扫描器（全是纯函数：喂 [(path, content)]，吐命中）

    /// 去掉整行注释，但**保留原始行号与缩进**。
    ///
    /// 行号必须一路带着走：先前有一版把注释行 `filter` 掉后再报 `index + 1`，
    /// 于是命中消息里的行号系统性偏小（报 121 实际 135）。报错误导人去找行，比不报错更糟。
    /// 缩进留给 `handRolledGroupContainers` 判父子关系用。
    static func numberedCodeLines(_ content: String) -> [(n: Int, text: String, indent: Int)] {
        content.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { index, raw in
                let text = String(raw)
                return (index + 1,
                        text.trimmingCharacters(in: .whitespaces),
                        text.prefix { $0 == " " || $0 == "\t" }.count)
            }
            .filter { !$0.text.hasPrefix("//") }
    }

    static func codeLines(_ content: String) -> [String] {
        numberedCodeLines(content).map(\.text)
    }

    /// 某段字面在哪些文件的哪些行出现。
    ///
    /// ⚠️ **needle 一律不带左括号**。SwiftUI 的容器视图绝大多数用尾随闭包调用
    /// （`DataReadoutBar { … }`、`DataTableWell { … }`），带 `(` 的 needle 对它们恒零命中，
    /// 于是断言「应该为零」的那几条会**永远绿**——本文件第一版就真的假绿在这一条上。
    static func hits(in files: [(path: String, content: String)],
                     containing needle: String) -> [String] {
        files.flatMap { file in
            numberedCodeLines(file.content).compactMap { entry in
                entry.text.contains(needle) ? "\(file.path):\(entry.n)" : nil
            }
        }
    }

    /// `.tertiary` 的任何用法。
    ///
    /// 判据比验收口径**更严**：口径只要求「承载测得值的 `.tertiary` 归零」，
    /// 但「这一行是不是测得值」在多行插值的 `Text("共 \\(NumberFormat…) 次")` 上
    /// 靠逐行扫判不可靠（基座那份 `tertiaryOnMeasuredValues` 就是按行扫的，
    /// 且它至今只在合成样本上跑过、没接真源码）。与其留一条会漏的判据，
    /// 不如本流目录整体归零：在 `ground` 上 secondary 与 tertiary 相差不过几个 RGB 阶，
    /// 路径与时间戳改 `.secondary` 没有任何可读性损失。
    static func tertiaryUses(in files: [(path: String, content: String)]) -> [String] {
        hits(in: files, containing: ".tertiary")
    }

    /// 裸字号。两种拼法都要抓：`Font.system(size:)` 与 `.font(.system(size:))`。
    /// 两者都在同一行内成形，逐行扫足够，不需要跨行拼接（拼反倒会吞掉行号）。
    static func bareSystemFonts(in files: [(path: String, content: String)]) -> [String] {
        let needles = ["Font.system(", ".system(size:"]
        return files.flatMap { file in
            numberedCodeLines(file.content).compactMap { entry in
                needles.contains(where: entry.text.contains)
                    ? "\(file.path):\(entry.n): \(entry.text.prefix(60))" : nil
            }
        }
    }

    /// 大字档被页面直接取用的位置（`Typo.heroMetric` / `Typo.metricNumber`）。
    static func directBigTierUses(in files: [(path: String, content: String)],
                                  tokenNamed name: String) -> [String] {
        hits(in: files, containing: "Typo.\(name)")
    }

    /// `DataHeroReadout(` 的调用点。每页最多一枚 —— 56pt 出现两枚就是「两个主角」，
    /// 放不下就降 `metricMid`(22)，不许回头改令牌。
    static func heroCallSites(in files: [(path: String, content: String)]) -> [String] {
        hits(in: files, containing: "DataHeroReadout")
    }

    /// `tint:` 传交互色或 info 色 —— 总工 2026-09-20 15:10 点名的那条：
    /// **M0 只改了 `MetricTile` 的默认值，而默认值盖不过显式传参**，
    /// 于是基座改绿了、页面照旧一片蓝。
    /// 合法的状态色（risk / severity / 增删）走 `role:` 形参，不在禁令里。
    static func dataTintedWithAccentOrInfo(in files: [(path: String,
                                                       content: String)]) -> [String] {
        let needles = ["tint: Theme.Semantic.accent", "tint: Theme.Semantic.info",
                       "tint: Theme.accent", "tint: Theme.info"]
        return files.flatMap { file in
            numberedCodeLines(file.content).compactMap { entry in
                needles.contains(where: entry.text.contains)
                    ? "\(file.path):\(entry.n): \(entry.text.prefix(60))" : nil
            }
        }
    }

    /// 交互色落在**非交互件**上。
    ///
    /// 判据形状：`Theme.Semantic.accent` 只允许出现在名字以 `Button` / `Action` 结尾的
    /// 视图里 —— `CodeOpenFileButton` 合法，`GitCommitRow` 里给 SHA 涂蓝非法（那是一行文本，
    /// 不可点）。按 `struct` 声明切块，块名不在白名单即违规。
    /// 这条刻意按**名字**判而不是按目录判，所以基座里的 `DataDisclosureButton` 一样合法。
    static func accentOutsideInteractiveViews(in files: [(path: String,
                                                          content: String)]) -> [String] {
        files.flatMap { file -> [String] in
            var found: [String] = []
            var current = "<文件头>"
            for (offset, line) in file.content.split(separator: "\n",
                                                      omittingEmptySubsequences: false)
                .enumerated() {
                let text = String(line).trimmingCharacters(in: .whitespaces)
                if text.hasPrefix("//") { continue }
                if text.contains("struct "), let name = declaredStructName(in: text) {
                    current = name
                }
                if text.contains("Theme.Semantic.accent"), !isInteractive(current),
                    !isBadgeRoleArgument(text) {
                    found.append("\(file.path):\(offset + 1): 在 \(current) 里用了 accent（\(text.prefix(52))）")
                }
            }
            return found
        }
    }

    static func declaredStructName(in line: String) -> String? {
        guard let start = line.range(of: "struct ") else { return nil }
        let name = line[start.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return name.isEmpty ? nil : String(name)
    }

    static func isInteractive(_ structName: String) -> Bool {
        structName.hasSuffix("Button") || structName.hasSuffix("Action")
    }

    /// 徽标是「色 + 文字 + 图标」三通道的**状态**载体，`role:` 传 accent 表达的是
    /// 「选中 / 当前对象」（契约 5 明确保留的那侧），与给数字涂蓝不是一回事。
    /// 所以只放行这一个形状：同一行若改成 `.foregroundStyle(Theme.Semantic.accent…)`
    /// 仍然算违规 —— 放宽的是「徽标 role 形参」，不是「这行允许出现蓝」。
    static func isBadgeRoleArgument(_ line: String) -> Bool {
        line.contains("SemanticBadge(") && line.contains("role: Theme.Semantic.accent")
    }

    /// 井的用法只许在基座里（`DataTableWell` 是 `.contentInset` 在本流唯一合法出口）。
    /// 页面自己写一遍 = 面由页面各自决定，正是要消灭的「每页各摆一次」。
    static func wellsOutsideKit(in files: [(path: String, content: String)]) -> [String] {
        files.filter { !$0.path.hasPrefix("CodeGit/") }.flatMap { file in
            numberedCodeLines(file.content).compactMap { entry in
                entry.text.contains("contentInset") ? "\(file.path):\(entry.n)" : nil
            }
        }
    }

    /// 有列头的表必须待在井里 ——「表格要嵌进去」是本轮对表格的唯一观感要求。
    static func tablesWithoutWell(in files: [(path: String, content: String)]) -> [String] {
        files.filter { $0.content.contains("DataTableHeader(") }
            .filter { !$0.content.contains("DataTableWell") }
            .map(\.path)
    }

    /// 读数用了井 = 给聚合数字画了一层面（契约 3 把井限定给表格/日志/代码块）。
    static func readoutBarsUsed(in files: [(path: String, content: String)]) -> [String] {
        hits(in: files, containing: "DataReadoutBar")
    }

    /// 页面手写容器来排 `GlassSection` → 组间距不受任何命名档位管辖。
    ///
    /// 判据：`VStack(` / `LazyVGrid(` / `ScrollView` 之后 8 行内出现**缩进更深**的
    /// `GlassSection(` 即违规。缩进这一维不是可有可无 —— 少了它就分不清
    /// 「VStack 里排着 section」（要管）与「某个 section 的内容里有个 VStack，
    /// 它的兄弟节点恰好是下一个 section」（不该管）。第一版没判缩进，
    /// 真在 `CodeMetricsView.swift` 的 `CodeScaleSection` 上误报了一处。
    /// 合法写法只有 `DataPageScaffold` / `PageParagraph` / `GroupStack`，
    /// 它们的档位全在基座，改一处五页同时生效。
    static func handRolledGroupContainers(in files: [(path: String,
                                                      content: String)]) -> [String] {
        let openers = ["VStack(", "LazyVGrid(", "ScrollView"]
        let lookAhead = 8
        return files
            .filter { pageDirs.contains(String($0.path.prefix { $0 != "/" })) }
            .flatMap { file -> [String] in
                let lines = numberedCodeLines(file.content)
                guard lines.contains(where: { $0.text.contains("GlassSection(") }) else { return [] }
                var found: [String] = []
                for (index, entry) in lines.enumerated() {
                    guard openers.contains(where: entry.text.contains) else { continue }
                    let end = min(lines.count, index + 1 + lookAhead)
                    guard index + 1 < end else { continue }
                    let nests = lines[(index + 1)..<end].contains {
                        $0.text.contains("GlassSection(") && $0.indent > entry.indent
                    }
                    if nests {
                        found.append("\(file.path):\(entry.n): \(entry.text.prefix(56))")
                    }
                }
                return found
            }
    }

    /// 页面里散写的**材质填充**。
    ///
    /// 为什么要在本流自己钉一份：基座的 `test_contentLayerDrawsNoMaterial` 在
    /// 本流开工时的作用域只是 `Design/Glass.swift` **一个文件**，页面里散写材质它看不见。
    /// 实测就在 `Views/Git` 抓到两处悬停浮层的 `.background(.regularMaterial, …)`
    /// （P-1 性能重构带进来的，不在任何人的观感工单里）。
    /// 两把尺子若共享同一个盲区，就等于没有第二把尺子。
    static func materialUses(in files: [(path: String, content: String)]) -> [String] {
        let needles = [".regularMaterial", ".ultraThinMaterial", ".thinMaterial", ".thickMaterial"]
        return files.flatMap { file in
            numberedCodeLines(file.content).compactMap { entry in
                needles.contains(where: entry.text.contains)
                    ? "\(file.path):\(entry.n): \(entry.text.prefix(60))" : nil
            }
        }
    }

    /// 浮层只能走 `.floating`，不得自己拼「材质 + 圆角数字」。
    static func rawCornerRadii(in files: [(path: String, content: String)]) -> [String] {
        hits(in: files, containing: "cornerRadius: ")
    }

    /// 色板 0 号位是**合计行 / 主序列**专用（`CodeGitRestyleTests
    /// .testMemberColorsNeverCollideWithTheAggregateBlue` 已钉过成员不得取 0）。
    /// 本轮集成修正又暴露它的反面：单序列图表（趋势柱、24×7 矩阵）也去取 0 号位，
    /// 于是同一段历史在总览是蓝的、在性能页是黑的 —— 三套图表取色约定并存。
    /// 单序列一律 `ChartSeries.lineColor`，所以全流只许在**合计行**出现一次 0 号位。
    static func aggregateIndexUses(in files: [(path: String, content: String)]) -> [String] {
        hits(in: files, containing: "Theme.Chart.color(at: CodeGitCategoryColor.aggregateIndex)")
    }

    // MARK: - 真源码定位

    static let packageRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TcoderMonitorTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // TcoderMonitor
    }()

    static func pageSourceFiles(dirs: [String] = CodeGitBorderlessTests.scannedDirs) throws
        -> [(path: String, content: String)] {
        let root = packageRoot.appendingPathComponent("Sources/TcoderMonitor/Views")
        var out: [(path: String, content: String)] = []
        for dir in dirs {
            let url = root.appendingPathComponent(dir)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            for name in names.sorted() where name.hasSuffix(".swift") {
                let file = url.appendingPathComponent(name)
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                out.append(("\(dir)/\(name)", text))
            }
        }
        return out
    }

    static func files(forPage page: String,
                              in all: [(path: String, content: String)])
        -> [(path: String, content: String)] {
        let owned = Set(pageFiles[page] ?? [])
        return all.filter { owned.contains($0.path) }
    }

    /// 只留页面目录（去掉公共基座 `CodeGit/`）。
    /// 「某原语是否真被接线」这类判据必须在页面目录上算：基座自己含那些名字，
    /// 拿四目录全集判会得到一个永真的分母。
    static func pageOnly(_ all: [(path: String, content: String)])
        -> [(path: String, content: String)] {
        all.filter { pageDirs.contains(String($0.path.prefix { $0 != "/" })) }
    }

    // MARK: - ① 测得值上不得有 `.tertiary`

    // MARK: - ② 无裸字号

    // MARK: - ③ 每页只有一枚主角

    // MARK: - ④ 相邻分组间距 ≥ 24

    // MARK: - ⑤ 倾向色只承载语义（总工 15:10 追加）

    // MARK: - ⑥ 面只剩井，且井只包表格

    // MARK: - ⑦ 内容层不得散写材质 / 裸圆角（P-1 之后补的一族）

    // MARK: - 元测试：确认每个扫描器都不是假绿

}
