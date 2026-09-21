import XCTest
@testable import TcoderMonitor

/// 「碎文案收进 ⓘ」这一轮的成对守卫。规格与切片边界见
/// `docs/superpowers/plans/2026-09-21-copy-into-tooltips.md`。
///
/// 三条守卫**成对**才成立，单独任何一条都能被绕过：
/// - A 只数"仍常驻上屏的长句"，逼着字真的变少 —— 但光有 A，最省事的做法是把解释**删掉**；
/// - B 数"可见 + tooltip 的总和"不许下降 —— 删一句就红，搬进 tooltip 不算丢；
/// - C 钉住一批承担诚实性承诺的句子必须仍然常驻 —— 否则 A 的下界就成了"全藏起来"。
///
/// 门槛与盘点表同源：半角宽度 > 24（≈ 12 个汉字）才算长句，
/// `未分析` / `算不出` 这类短态词本来就是读数，不算碎文案。
final class TooltipMigrationGuardTests: XCTestCase {

    // MARK: - 尺子

    struct Caliber: Hashable {
        let path: String
        let line: Int
        let text: String
    }

    private static let longCaliberWidth = 24

    /// 可见槽位：字面上屏的那些入口（与 `LocalizationGuardTests` 的入口族同源）。
    private static let visibleSlotPattern =
        "(?:subtitle|caption|note|footnote|emptyNote|message|text|label|title)\\s*:\\s*\""
        + "|(?:GlassSection|NoteLine|DataFootnote|DataCaption|Text|BannerRow|StatLine"
        + "|SectionEmptyNote|EmptyStateView)\\s*\\("

    /// tooltip 承载位：`.help(...)` 与共用的 `CopyHelpBadge(...)`。
    private static let tooltipCarrierPattern = "\\.help\\s*\\(|CopyHelpBadge\\s*\\("

    private static let literalPattern = "\"((?:[^\"\\\\]|\\\\.)*?)\""
    private static let hanPattern = "[\\u4E00-\\u9FFF]"

    static func displayWidth(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { partial, scalar in
            partial + ((0x4E00...0x9FFF).contains(scalar.value) ? 2 : 1)
        }
    }

    /// 纯函数：只吃 `[(路径, 内容)]`。元测试因此在内存里造坏样例，
    /// 不往仓库塞临时夹具（那种东西会被下一轮扫描当成真存量）。
    static func scan(_ files: [(path: String, content: String)]) -> (visible: [Caliber], tooltip: [Caliber]) {
        let visible = try! NSRegularExpression(pattern: visibleSlotPattern)
        let carrier = try! NSRegularExpression(pattern: tooltipCarrierPattern)
        let literal = try! NSRegularExpression(pattern: literalPattern)
        let han = try! NSRegularExpression(pattern: hanPattern)
        var visibleHits: [Caliber] = []
        var tooltipHits: [Caliber] = []
        for file in files {
            let lines = file.content.split(separator: "\n", omittingEmptySubsequences: false)
            for (offset, raw) in lines.enumerated() {
                let line = String(raw)
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                let range = NSRange(line.startIndex..., in: line)
                let isTooltip = carrier.firstMatch(in: line, options: [], range: range) != nil
                let isVisible = visible.firstMatch(in: line, options: [], range: range) != nil
                guard isTooltip || isVisible else { continue }
                for match in literal.matches(in: line, options: [], range: range) {
                    guard let group = Range(match.range(at: 1), in: line) else { continue }
                    let text = String(line[group])
                    guard han.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil,
                          displayWidth(text) > longCaliberWidth else { continue }
                    let caliber = Caliber(path: file.path, line: offset + 1, text: text)
                    if isTooltip { tooltipHits.append(caliber) } else { visibleHits.append(caliber) }
                }
            }
        }
        return (visibleHits, tooltipHits)
    }

    static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)     // …/TcoderMonitor/Tests/TcoderMonitorTests/本文件.swift
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static func viewFiles() throws -> [(path: String, content: String)] {
        let root = packageRoot.appendingPathComponent("Sources/TcoderMonitor/Views").path
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: root) else {
            return XCTFailEven("扫不到 \(root) —— 路径没了不等于「页面干净了」")
        }
        var out: [(String, String)] = []
        for case let path as String in enumerator where path.hasSuffix(".swift") {
            out.append(("Views/\(path)", (try? String(contentsOfFile: "\(root)/\(path)", encoding: .utf8)) ?? ""))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    // MARK: - 基线（必须是某次实扫的现量，不许拍脑袋）

    /// 2026-09-21 在 main `14a1f29` 实扫播种：**可见长句 88 条 / tooltip 长句 13 条 / 总和 101**
    /// （扫 `Views/**` 42 个 swift 文件）。
    /// 只许往下调：每还一笔债就写清是哪一片还的。
    private static let visibleCaliberCeiling = 88

    /// 总量下限 = 播种时的可见 + tooltip 之和。**只许往上**（新增口径允许，删口径不行）。
    private static let totalCaliberFloor = 101

    /// 承担诚实性告知、**不许只活在 hover 里**的句子片段。
    /// 取值前逐个核实过当前确实常驻上屏（片段是为了避开同一句在两个页面各写一份时的措辞差）。
    private static let mustRemainVisible: [String] = [
        "取不到的一律显示",            // 性能页：缺数据是 -- 而不是 0
        "不会补成 0",
        "启发式加权计算",              // 评分页：没调外部模型
        "未调用外部模型",
        "不表示数量为 0",              // 进程表：-- 的读法
        "未做时区归一",                // 活跃热力：近似口径
        "不含锁文件解析出的传递依赖",   // 依赖数分母
        "首个差分帧到达前",            // 两帧才出速率
        "没有命中错误行",              // 扫了但没找到 ≠ 没扫
    ]

    /// 片段在源码里的**出现位置**（含所在行是可见槽位还是 tooltip 承载位）。
    /// 守卫 C 用它，而不是用上面那个"长句"名单 —— 承诺句有好几条本来就是短句
    /// （`未做时区归一`、`不会补成 0`），拿长度门槛去判"还在不在"会漏。
    struct Sighting: Hashable { let path: String; let line: Int; let inTooltip: Bool }

    static func sight(_ fragment: String, in files: [(path: String, content: String)]) -> [Sighting] {
        let carrier = try! NSRegularExpression(pattern: tooltipCarrierPattern)
        var out: [Sighting] = []
        for file in files {
            let lines = file.content.split(separator: "\n", omittingEmptySubsequences: false)
            for (offset, raw) in lines.enumerated() {
                let line = String(raw)
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                guard line.contains(fragment) else { continue }
                let range = NSRange(line.startIndex..., in: line)
                out.append(Sighting(path: file.path, line: offset + 1,
                                    inTooltip: carrier.firstMatch(in: line, options: [], range: range) != nil))
            }
        }
        return out
    }

    /// C 的判据：每个承诺片段都要**至少有一处不在 tooltip 行上**。返回违规清单。
    static func hiddenCommitments(_ fragments: [String], files: [(path: String, content: String)]) -> [String] {
        fragments.compactMap { fragment in
            let sightings = sight(fragment, in: files)
            guard !sightings.isEmpty else { return "「\(fragment)」整页找不到（被删了不是被藏了）" }
            guard sightings.contains(where: { !$0.inTooltip }) else {
                return "「\(fragment)」只剩 hover 可见（\(sightings.map(\.path).sorted().first ?? "?")）"
            }
            return nil
        }
    }


    // MARK: - 守卫 A：常驻长句只减不增

    func test_visibleLongCalibersOnlyShrink() throws {
        let files = try Self.viewFiles()
        XCTAssertGreaterThanOrEqual(files.count, 40, "扫到的页面文件只有 \(files.count) 个，扫描面坏了")
        let (visible, tooltip) = Self.scan(files)
        XCTAssertFalse(visible.isEmpty, "一条常驻长句都没扫到 —— 尺子失灵，不是页面变干净了")
        print("ⓘ 收纳棘轮：可见长句 \(visible.count) / 上限 \(Self.visibleCaliberCeiling)"
              + "（tooltip 承载 \(tooltip.count) 条 / 扫描面 \(files.count) 个文件）")
        XCTAssertLessThanOrEqual(visible.count, Self.visibleCaliberCeiling,
                                 "常驻长句从 \(Self.visibleCaliberCeiling) 涨到 \(visible.count)："
                                 + "新增解释文案要么走 tooltip，要么别再写")
    }

    // MARK: - 守卫 B：口径总量不许被"顺手删掉"

    func test_caliberStringsAreNotDeleted() throws {
        let (visible, tooltip) = Self.scan(try Self.viewFiles())
        let total = visible.count + tooltip.count
        XCTAssertGreaterThanOrEqual(total, Self.totalCaliberFloor,
                                    "口径说明总量从 \(Self.totalCaliberFloor) 掉到 \(total)："
                                    + "把长句**删掉**不是「藏进 ⓘ」。搬进 .help 或 CopyHelpBadge 才算数。")
    }

    // MARK: - 守卫 C：核心承诺必须常驻

    func test_honestyCommitmentsStayVisible() throws {
        let offenders = Self.hiddenCommitments(Self.mustRemainVisible, files: try Self.viewFiles())
        XCTAssertTrue(offenders.isEmpty,
                      "这些诚实性承诺不许只靠悬停看见（A 的上界就是这一条）：\n" + offenders.joined(separator: "\n"))
    }

    // MARK: - 元测试：三条尺子各自都必须能抓到坏样例

    /// A 的扫描器：可见槽位里的长句要算进去；tooltip 里的不算；注释里的不算；短句不算。
    func test_meta_visibleScannerCatchesBadSampleAndSparesTheRest() {
        let dirty = [(path: "Views/Fake.swift", content: """
        GlassSection("代码规模", subtitle: "这是一条足够长的解释性文案，用来验证扫描器真的能把它算进常驻量") {
            NoteLine("又一条足够长的解释性文案，第二段，同样必须被算成常驻而不是已藏")
            Text("短态词")
                .help("这条已经收进 tooltip 了，长得再长也不该算进常驻量里面去")
        }
        // subtitle: "注释里出现的这种长句绝对不该被算成上屏的常驻文案内容"
        """)]
        let (visible, tooltip) = Self.scan(dirty)
        XCTAssertEqual(visible.count, 2, "常驻扫描器失灵：应抓到两条，实际 \(visible.count)")
        XCTAssertEqual(tooltip.count, 1, "tooltip 承载位没认出来")
        XCTAssertFalse(visible.contains { $0.text.contains("短态词") }, "≤12 字的短读数不该算碎文案")
    }

    /// B 的下界：删一句必须让总量掉下来（而不是"看起来更干净"）。
    func test_meta_totalFloorDetectsDeletion() {
        let before = [(path: "Views/Fake.swift", content: """
        NoteLine("口径说明第一句，长度足够，它属于必须一直存在的解释性文案范畴")
        Text("口径说明第二句，同样长度足够，删掉它就会让总量掉到下界以下去")
        """)]
        let after = [(path: "Views/Fake.swift", content: """
        NoteLine("口径说明第一句，长度足够，它属于必须一直存在的解释性文案范畴")
        """)]
        let totalBefore = Self.scan(before).visible.count + Self.scan(before).tooltip.count
        let totalAfter = Self.scan(after).visible.count + Self.scan(after).tooltip.count
        XCTAssertEqual(totalBefore, 2)
        XCTAssertLessThan(totalAfter, totalBefore, "删掉一条口径却没被察觉 —— B 是摆设")
    }

    /// C 三个方向都要有反应：搬进 tooltip 要喊、仍常驻不许误报、**整句删掉**要单独点名。
    /// （只测前两个会漏掉最坏的那种失败 —— 删干净之后守卫反而一片绿。）
    func test_meta_commitmentGuardDistinguishesHiddenKeptAndDeleted() {
        let fragments = ["取不到的一律显示", "不会补成 0"]
        let hidden = [(path: "Views/Fake.swift", content: """
        MetricTile("内存")
            .help("内存读数不可信时取不到的一律显示 --，不会补成 0")
        """)]
        let flagged = Self.hiddenCommitments(fragments, files: hidden)
        XCTAssertEqual(flagged.count, 2, "搬进 tooltip 之后必须两条都点名")
        XCTAssertTrue(flagged.allSatisfy { $0.contains("只剩 hover 可见") }, "\(flagged)")

        let kept = [(path: "Views/Fake.swift", content: """
        NoteLine("数值随采样刷新，取不到的一律显示 --，不会补成 0。")
        """)]
        XCTAssertTrue(Self.hiddenCommitments(fragments, files: kept).isEmpty,
                      "合法样例被误报 —— 这条守卫会把正常的口径句当成违规，几次之后就有人删名单")

        let deleted = [(path: "Views/Fake.swift", content: "NoteLine(\"这页什么都没解释\")")]
        let missing = Self.hiddenCommitments(fragments, files: deleted)
        XCTAssertEqual(missing.count, 2)
        XCTAssertTrue(missing.allSatisfy { $0.contains("整页找不到") },
                      "删掉承诺句必须被单独点名，不能和「只剩 hover 可见」混成同一条")
    }

    /// 已知保守处必须显形：跨行写的 `.help(` 实参会被算成"可见"。
    /// 记成测试是为了将来有人改判据时知道这条边界在哪儿 —— 方向是安全的（多要求藏，不会少要求）。
    func test_multilineHelpArgumentFailsSafeAsVisible() {
        let split = [(path: "Views/Fake.swift", content: """
        Text("这条文案本身很长很长，它的 hover 说明在下一行才写出来，所以会被算成常驻而不是已藏")
            .help("这就是那个说明")
        """)]
        let (visible, tooltip) = Self.scan(split)
        XCTAssertEqual(visible.count, 1, "跨行 help 的第一行被算成可见（保守方向）")
        XCTAssertEqual(tooltip.count, 0, "短句本就不该进 tooltip 名单")
    }
}

private func XCTFailEven(_ message: String) -> [(String, String)] {
    XCTFail(message)
    return []
}
