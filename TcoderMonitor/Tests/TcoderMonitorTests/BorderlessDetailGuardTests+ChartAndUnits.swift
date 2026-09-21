import Foundation
import SwiftUI
import XCTest
@testable import TcoderMonitor

// MARK: - 批次 H8 / H9 的图表与数值守卫（自 BorderlessDetailGuardTests.swift 原样搬出）
//
// 搬的理由与 `+FrameAndStrip` 那份一样是机械的：`X3TestSizeAuditTests` 用与产品
// 「巨大文件」同一口径（400 行）钉着 Tests 目录，而 H8/H9 两批守卫把主文件顶到 427 行。
// 判据、合成样例与数字一字未改，只换了住的地方。

extension BorderlessDetailGuardTests {

    // MARK: 批次 H8：纵轴刻度一律落在左边

    /// SwiftUI 的 `AxisMarks` 默认 `position` 是 `.automatic`，它会随图落位 ——
    /// 实拍总览页的 100/50/0 就跑到了**右边**，而性能/健康/日志/Git 四页的曲线
    /// 都显式写了 `.leading`。同一个 App 里"纵轴一会儿在左一会儿在右"是典型的
    /// 「东一个系一个」，而且只在**漏写**时发生，所以钉成机器断言。
    static func yAxesWithoutLeadingPosition(in files: [(path: String, content: String)]) -> [String] {
        files.flatMap { file -> [String] in
            let lines = SurfaceScanKit.codeLines(file.content)
            var hits: [String] = []
            for (index, line) in lines.enumerated() where line.contains(".chartYAxis") {
                let window = lines[index..<min(index + 6, lines.count)].joined(separator: "\n")
                if !window.contains("position: .leading") {
                    hits.append("\(file.path):\(index + 1)")
                }
            }
            return hits
        }
    }

    func test_yAxisLabelsAllSitOnTheLeadingSide() throws {
        let offenders = Self.yAxesWithoutLeadingPosition(in: try SurfaceScanKit.sourceFiles(under: "Views"))
        XCTAssertTrue(offenders.isEmpty,
                      "这些图的纵轴刻度没写 `position: .leading`，会自己跑到右边去：\(offenders)")
    }

    func test_yAxisScannerDetectsMissingPosition() {
        let missing = [(path: "Views/FakeChart.swift", content: """
            .chartYAxis {
                AxisMarks(values: [0, 50, 100]) { _ in
                    AxisValueLabel()
                }
            }
            """)]
        XCTAssertEqual(Self.yAxesWithoutLeadingPosition(in: missing), ["Views/FakeChart.swift:1"],
                       "漏写 position 的图没被抓到")
        let pinned = [(path: "Views/FakeChart.swift", content: """
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 50, 100]) { _ in
                    AxisValueLabel()
                }
            }
            """)]
        XCTAssertTrue(Self.yAxesWithoutLeadingPosition(in: pinned).isEmpty, "写了 .leading 的被误判")
    }

    // MARK: 批次 H9：量词不许被焊死在数值里
    /// `value: "\(…) 行"` 把单位与数字同号排，而同一条读数带里别的格子走 `unit:`（小一档）。
    /// H2 定的规则是**纯量词走 `unit:`**，当时只钉了"量词不许当 caption"，
    /// 没钉"量词不许焊进 value"，于是复杂度页「14 行」就这么漏过来了。
    static func unitsBakedIntoValues(in files: [(path: String, content: String)]) -> [String] {
        let quantifiers = ["行", "个", "次", "项", "条", "人", "天", "核", "处", "段"]
        return files.flatMap { file -> [String] in
            // **逐原始行**扫，不能先过 `codeLines`：那道过滤会删掉注释行，
            // 于是 `index + 1` 不再是文件行号 —— 报出来的行号指向无辜的那一行，
            // 这条守卫第一次跑就踩在这里（报到了 `GlassSection("重复与复杂度概览"` 上）。
            file.content.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .compactMap { index, raw -> String? in
                    let line = String(raw)
                    guard SurfaceScanKit.isCode(line) else { return nil }
                    guard let start = line.range(of: "value: \"") else { return nil }
                    let body = line[start.upperBound...]
                    guard let end = body.firstIndex(of: "\"") else { return nil }
                    let literal = body[..<end]
                    // 只有"插值 + 空格 + 量词"收尾的才算：`"44.3 GB"`、`"1 分钟前"` 都不在此列。
                    guard let paren = literal.lastIndex(of: ")"),
                          literal[literal.index(after: paren)...].count <= 2
                    else { return nil }
                    let tail = literal[literal.index(after: paren)...]
                        .trimmingCharacters(in: .whitespaces)
                    guard quantifiers.contains(String(tail)) else { return nil }
                    return "\(file.path):\(index + 1)"
                }
        }
    }

    func test_pureUnitsNeverSitInsideTheValue() throws {
        let offenders = Self.unitsBakedIntoValues(in: try SurfaceScanKit.sourceFiles(under: "Views"))
        XCTAssertTrue(offenders.isEmpty,
                      "量词被焊进 value 会与同排走 `unit:` 的格子字号不一致：\(offenders)")
    }

    func test_valueUnitScannerDetectsGluedUnitAndSparesRealStrings() {
        // 前面垫两行注释：报的行号必须是**文件行号**，不是"过滤掉注释后的第几行"。
        let glued = [(path: "Views/Fake.swift", content: """
            // 说明
            // 说明二
            DataReadout(label: "x", value: "\\(NumberFormat.grouped(n)) 行")
            """)]
        XCTAssertEqual(Self.unitsBakedIntoValues(in: glued), ["Views/Fake.swift:3"],
                       "抓到了但行号错位 —— 报出来的行号指不到病灶，等于让人重找一遍")
        let fine = [(path: "Views/Fake.swift", content: """
            DataReadout(label: "a", value: "44.3 GB", unit: nil)
            MetricTile(label: "b", value: "\\(Live.bytes(x))", unit: "行")
            Text("1 分钟前")
            """)]
        XCTAssertTrue(Self.unitsBakedIntoValues(in: fine).isEmpty,
                      "带单位的合法写法被误判：\(Self.unitsBakedIntoValues(in: fine))")
    }

    /// 反向自证：`sourceFiles` 真读到了文件。
    func test_detailScannerActuallyFindsFiles() throws {
        let views = try SurfaceScanKit.sourceFiles(under: "Views")
        XCTAssertGreaterThanOrEqual(views.count, 30, "Views/ 只扫到 \(views.count) 个文件")
        XCTAssertTrue(views.contains { $0.path.hasSuffix("PerformanceSystemTiles.swift") })
    }

    // MARK: 批次 H10：轴刻度不得用层级样式（会连乘）

    /// `AxisValueLabel` 之后 8 行内出现 `.foregroundStyle(.secondary)` / `.tertiary` 即算违规。
    /// 层级样式与宿主环境里的层级**连乘**（0.55×0.55≈0.30）：深色态实测性能页五档纵轴
    /// 刻度只剩 `#464646`（对纯黑约 2.2:1），整条轴读不出，而总览页同类刻度没被连乘 ——
    /// 同一个 App 里两页的轴一深一浅。绝对色出口是 `View.foregroundStyle(Color.secondary)`。
    static func hierarchicalAxisLabels(in files: [(path: String, content: String)]) -> [String] {
        files.flatMap { file -> [String] in
            let lines = file.content.split(separator: "\n", omittingEmptySubsequences: false)
                                .map(String.init)
            var hits: [String] = []
            for (index, line) in lines.enumerated() {
                guard SurfaceScanKit.isCode(line), line.contains("AxisValueLabel") else { continue }
                let window = lines[index..<min(index + 8, lines.count)]
                if window.contains(where: {
                    $0.contains(".foregroundStyle(.secondary)") || $0.contains(".foregroundStyle(.tertiary)")
                }) {
                    hits.append("\(file.path):\(index + 1)")
                }
            }
            return hits
        }
    }

    func test_chartAxisLabelsNeverUseHierarchicalStyle() throws {
        let offenders = Self.hierarchicalAxisLabels(in: try SurfaceScanKit.sourceFiles(under: "Views"))
        XCTAssertTrue(offenders.isEmpty,
                      "轴刻度又用了层级前景色，会跟宿主环境连乘变暗（深色态实测 2.2:1），"
                          + "请改绝对色 .foregroundStyle(Color.secondary)：\(offenders)")
    }

    func test_hierarchicalAxisScannerCatchesAndSpares() {
        let bad = [(path: "Views/FakeChart.swift", content: """
            AxisValueLabel {
                Text("50%")
                    .font(Theme.Typo.monoSmall.font)
                    .foregroundStyle(.secondary)
            }
            """)]
        XCTAssertEqual(Self.hierarchicalAxisLabels(in: bad), ["Views/FakeChart.swift:1"])
        let good = [(path: "Views/FakeChart.swift", content: """
            AxisValueLabel {
                Text("50%")
                    .font(Theme.Typo.monoSmall.font)
                    .foregroundStyle(Color.secondary)
            }
            """)]
        XCTAssertTrue(Self.hierarchicalAxisLabels(in: good).isEmpty, "绝对色的轴刻度被误判")
    }

    // MARK: 批次 P5：蓝只许描述数据，不许描述"界面在说话"

    /// `Theme.Semantic.info` 在页面里出现 = 把**口径说明/建议/空态**涂成语义色。
    /// 两批实拍各自独立点名同一现象：提示条在四页涂四种颜色（Git 洞察/依赖分析=蓝、
    /// 贡献者=红、错误日志=橙），而"结构去色、颜色只给语义"要求蓝只能描述
    /// **日志等级这一类数据本身**。判据按文件白名单收口，只有一处合法：
    /// `Views/Logs/LogsFileTables.swift`（日志文件类别 = 数据）。
    static func infoUsedToColorChrome(in files: [(path: String, content: String)]) -> [String] {
        let exempt: Set<String> = ["Views/Logs/LogsFileTables.swift"]
        var out: [String] = []
        for file in files where !exempt.contains(file.path) {
            for (offset, raw) in file.content.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated() {
                let line = String(raw)
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
                guard line.contains("Semantic.info") else { continue }
                out.append("\(file.path):\(offset + 1)")
            }
        }
        return out
    }

    func test_infoBlueNeverColorsChrome() throws {
        let files = try SurfaceScanKit.sourceFiles(under: "Views")
        XCTAssertGreaterThanOrEqual(files.count, 30, "只扫到 \(files.count) 个界面文件 —— 分母不对，这条没在检查任何东西")
        let hits = Self.infoUsedToColorChrome(in: files)
        XCTAssertTrue(hits.isEmpty,
                      "这些点用 info 蓝涂说明/建议类文字（结构必须去色）：\(hits.sorted())")
    }

    func test_infoChromeScannerCatchesBlueButSparesLogCategories() {
        let dirty = [(path: "Views/Fake.swift",
                      content: "DataNotice(text: note, role: Theme.Semantic.info, icon: .info)\n")]
        XCTAssertEqual(Self.infoUsedToColorChrome(in: dirty), ["Views/Fake.swift:1"],
                       "蓝涂说明的写法没被抓到")
        let legal = [(path: "Views/Fake.swift",
                      content: "DataNotice(text: note, role: Theme.Semantic.neutral, icon: .info)\n")]
        XCTAssertTrue(Self.infoUsedToColorChrome(in: legal).isEmpty, "中性色说明条被误判")
        // 白名单里的那种（日志类别）不该由这条管，但换掉文件名后必须被抓 ——
        // 否则"白名单"就是静默吞样本的黑洞。
        let whitelistedElsewhere = [(path: "Views/Logs/OtherFile.swift",
                                     content: "case .system: return Theme.Semantic.info\n")]
        XCTAssertEqual(Self.infoUsedToColorChrome(in: whitelistedElsewhere),
                       ["Views/Logs/OtherFile.swift:1"], "白名单按文件名放行，换个名字就漏")
        // 注释里提一句 info 不算违例（守卫不许扫到"讲代码的话"）
        let commented = [(path: "Views/Fake.swift",
                          content: "// 原来这里涂 Semantic.info，批次 P5 改成中性\n")]
        XCTAssertTrue(Self.infoUsedToColorChrome(in: commented).isEmpty, "注释被误判成代码")
    }

    // MARK: 批次 P5：整句相对时间不许占大数档

    /// `MetricTile(value:)` 收到"49 秒前"这种**整句**，等于让单位词吃到 34pt semibold。
    /// 实拍 Git 洞察：那三个字是全页最重的墨，比本页真正的最大数还抢眼。
    /// 正解是 `LogRecency.split(...)` 拆成数字 + 单位两段（`unit` 槽走 label 档）。
    /// 顺带禁掉手工 `replacingOccurrences(of: " 前")` —— 那是只治中文半种语言的补丁。
    /// 只钉**大数档**：`MetricTile` / `DataReadout` 调用里的 `value:` 实参
    /// （两者都把 value 画成 `metricNumber` 34pt）。同一条短语出现在
    /// `DataFieldRow`（标签-值行，走 monoSmall）里是合规的 —— 判据要跟着被检对象的
    /// 档位走；这条的最初版本按"整份文件里出现过"判，当场误判了代码规模页的
    /// `DataFieldRow(label: "距今", value: …)`，而误判会逼人写绕路代码（批次 P5 记录）。
    ///
    /// 逐行扫、命中报**原始行号**（不预先滤掉注释再取 index，那样行号会漂）。
    static func wholeRecencyInValueSlot(in files: [(path: String, content: String)]) -> [String] {
        var out: [String] = []
        for file in files {
            let lines = file.content.components(separatedBy: "\n")
            // 起点必须是「很远」：从 0 起算会把文件开头几行的 DataFieldRow 读成刚开过
            // MetricTile(，于是合规的标签-值行被误判。元测试 ③ 就是在这里抓到这个的。
            var heroDepth = 999      // 距离最近一次 MetricTile(/DataReadout( 的行数
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let isComment = trimmed.hasPrefix("//")
                if !isComment, trimmed.contains("MetricTile(") || trimmed.contains("DataReadout(") {
                    heroDepth = 0
                } else {
                    heroDepth += 1
                }
                if isComment { continue }
                // 手工削中文词的补丁：与档位无关，任何位置都不许留（它只治中文半种语言）
                if line.contains(#"replacingOccurrences(of: " 前""#) {
                    out.append("\(file.path):\(index + 1) 手工削 \" 前\"")
                }
                guard heroDepth <= 8 else { continue }
                guard let valueRange = line.range(of: "value:") else { continue }
                let argument = line[valueRange.lowerBound...]
                if argument.contains("LogRecency.split(") { continue }
                if argument.contains("LogRecency.describe(") || argument.contains("sinceDescription(") {
                    out.append("\(file.path):\(index + 1) 整句时间短语占了大数档")
                }
            }
        }
        return out.sorted()
    }

    func test_wholeRecencyPhraseNeverSitsInAValueSlot() throws {
        let files = try SurfaceScanKit.sourceFiles(under: "Views")
        let hits = Self.wholeRecencyInValueSlot(in: files)
        XCTAssertTrue(hits.isEmpty,
                      "整句相对时间占了大数档（单位词与数字同字号）：\(hits.sorted())")
    }

    /// 元测试**五向**：坏的要抓到、三种合法写法不得误判、注释不得算。
    /// ③ 那条尤其要紧 —— 少了它，这条判据会把合规的标签-值行一起卷进来，
    /// 逼人为了过守卫去改一个本来没错的写法。
    func test_recencyValueScannerCatchesPhraseButSparesLegalTiers() {
        func hits(_ content: String) -> [String] {
            Self.wholeRecencyInValueSlot(in: [(path: "Views/Fake.swift", content: content)])
        }
        // ① 大数档吃整句 → 抓到，且报的是原始行号
        XCTAssertEqual(hits("MetricTile(label: \"x\",\n    value: git.lastCommitAt.map { LogRecency.describe($0) })"),
                       ["Views/Fake.swift:2 整句时间短语占了大数档"],
                       "整句时间短语进大数档没被抓到，或行号漂了")
        // ② 大数档 + 数字/单位两段 → 合法
        XCTAssertTrue(hits("MetricTile(label: \"x\",\n    value: LogRecency.split(date).value,\n    unit: LogRecency.split(date).unit)")
                      .isEmpty, "拆成数字 + 单位两段被误判")
        // ③ 标签-值行走 monoSmall，整句是它该有的样子 → 不得误判
        XCTAssertTrue(hits("DataFieldRow(label: \"距今\",\n    value: DateFormat.sinceDescription(code.scannedAt), style: .number)")
                      .isEmpty, "非大数档的标签-值行被误判")
        // ④ 手工削中文词的补丁：与档位无关，任何位置都要抓到
        XCTAssertEqual(hits("value: s.replacingOccurrences(of: \" 前\", with: \"\")"),
                       ["Views/Fake.swift:1 手工削 \" 前\""],
                       "只治中文半种语言的补丁没被抓到")
        // ⑤ 讲代码的话不算违例
        XCTAssertTrue(hits("// 这里以前是 value: LogRecency.describe($0)，批次 P5 拆成两段").isEmpty,
                      "注释被误判成代码")
    }

}

