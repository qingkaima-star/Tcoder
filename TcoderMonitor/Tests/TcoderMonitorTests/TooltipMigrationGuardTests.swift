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

    /// tooltip 承载位：`.help(...)`、共用的 `CopyHelpBadge(...)`，以及**带 `help:` 标签的槽位**
    /// （`NoteLine(_, help:)`、`DataFieldRow(help:)`、`EmptyStateView(help:)` 都是官方推荐形状）。
    ///
    /// 少了最后这一支就是**尺子在惩罚用对 API 的人**：S2 交回时报"搬了字现量不减"，
    /// 因为它把长句放进 `help:` 后，那一行仍被 `NoteLine(` 认成可见槽位 —— 于是它只好绕开
    /// 推荐形状去直接写 `CopyHelpBadge`。画法仍然唯一，但那是被坏尺子逼出来的。
    private static let tooltipCarrierPattern = "\\.help\\s*\\(|CopyHelpBadge\\s*\\("
        + "|(?:subtitleHelp|captionHelp|help)\\s*:\\s*\""

    private static let literalPattern = "\"((?:[^\"\\\\]|\\\\.)*?)\""
    private static let hanPattern = "[\\u4E00-\\u9FFF]"

    /// 一个字面量在屏上的身份。`skipped` = 这行既看不出槽位也没有任何槽位线索
    /// （跨行拼接的续行、被塞进变量的中段），不计入任何一份名单 —— 与改造前逐行判定同一条边界。
    enum LiteralSlot { case visible, tooltip, skipped }

    /// 直接压在引号前面的槽位线索（比逐行判定精确一档）。
    private static let tooltipPrefixPattern = "(?:\\.help|CopyHelpBadge)\\s*\\(\\s*$"
        + "|(?:subtitleHelp|captionHelp|help)\\s*:\\s*$"
    private static let visiblePrefixPattern =
        "(?:subtitle|caption|note|footnote|emptyNote|message|text|label|title)\\s*:\\s*$"
        + "|(?:GlassSection|NoteLine|DataFootnote|DataCaption|Text|BannerRow|StatLine"
        + "|SectionEmptyNote|EmptyStateView)\\s*\\(\\s*$"

    /// **逐字面量**判槽位，判不出来才退回整行线索。
    ///
    /// 为什么不能按行：本轮「留短藏长」的标准形状就是同一行既有一句常驻短句、
    /// 又有一个 `help:` 长口径。按行判会把那行里的**常驻句**一起算成"已藏" ——
    /// S5 的元测试正是这么撞红的（合法样例被误报）。按行判还有一个反方向的老洞：
    /// 一行里 `.help(` 与常驻长句同时出现时，常驻那份的债会被记成"已经藏好了"。
    static func literalSlots(in line: String) -> [(text: String, span: Range<String.Index>, slot: LiteralSlot)] {
        let literal = try! NSRegularExpression(pattern: literalPattern)
        let tooltipPrefix = try! NSRegularExpression(pattern: tooltipPrefixPattern)
        let visiblePrefix = try! NSRegularExpression(pattern: visiblePrefixPattern)
        let carrierOnLine = try! NSRegularExpression(pattern: tooltipCarrierPattern)
        let visibleOnLine = try! NSRegularExpression(pattern: visibleSlotPattern)
        let lineRange = NSRange(line.startIndex..., in: line)
        let lineHasCarrier = carrierOnLine.firstMatch(in: line, options: [], range: lineRange) != nil
        let lineHasVisible = visibleOnLine.firstMatch(in: line, options: [], range: lineRange) != nil
        var out: [(text: String, span: Range<String.Index>, slot: LiteralSlot)] = []
        for match in literal.matches(in: line, options: [], range: lineRange) {
            guard let whole = Range(match.range, in: line),
                  let inner = Range(match.range(at: 1), in: line) else { continue }
            let prefix = Self.stripLookupWrappers(String(line[line.startIndex..<whole.lowerBound]))
            let prefixRange = NSRange(prefix.startIndex..., in: prefix)
            let slot: LiteralSlot
            if tooltipPrefix.firstMatch(in: prefix, options: [], range: prefixRange) != nil {
                slot = .tooltip
            } else if visiblePrefix.firstMatch(in: prefix, options: [], range: prefixRange) != nil {
                slot = .visible
            } else if lineHasCarrier {
                slot = .tooltip
            } else if lineHasVisible {
                slot = .visible
            } else {
                slot = .skipped
            }
            out.append((String(line[inner]), whole, slot))
        }
        return out
    }

    static func displayWidth(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { partial, scalar in
            partial + ((0x4E00...0x9FFF).contains(scalar.value) ? 2 : 1)
        }
    }

    /// 纯函数：只吃 `[(路径, 内容)]`。元测试因此在内存里造坏样例，
    /// 不往仓库塞临时夹具（那种东西会被下一轮扫描当成真存量）。
    static func scan(_ files: [(path: String, content: String)]) -> (visible: [Caliber], tooltip: [Caliber]) {
        let han = try! NSRegularExpression(pattern: hanPattern)
        var visibleHits: [Caliber] = []
        var tooltipHits: [Caliber] = []
        for file in files {
            let lines = file.content.split(separator: "\n", omittingEmptySubsequences: false)
            for (offset, raw) in lines.enumerated() {
                let line = String(raw)
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                for hit in literalSlots(in: line) {
                    guard hit.slot != .skipped else { continue }
                    let text = hit.text
                    guard han.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil,
                          displayWidth(text) > longCaliberWidth else { continue }
                    let caliber = Caliber(path: file.path, line: offset + 1, text: text)
                    if hit.slot == .tooltip { tooltipHits.append(caliber) } else { visibleHits.append(caliber) }
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
    /// 只许往下调，每降一次都写明是哪一片还的债（现量由守卫每次打印，不许估）：
    /// 88 → 76（S2 代码两页）→ 74（S3 Git 与贡献者）→ 72（尺子改逐字面量判槽位 + S6 键登记）
    /// → 69（S1 总览与外壳）→ **62（S5 性能与日志 19 处、S4 依赖 3 处、S7 总览三处收进 ⓘ）**。
    /// 同批 tooltip 承载 13 → 49、总量 101 → 111：**B 一句没删**，降下来的 26 条全部搬进了 ⓘ。
    /// → 54（P69 合流：26 段半句并成 10 条整句键）
    /// → **86（P70 重播种：不是新增债，是量具坏了** —— 分类器原先看不见包在 `localizedFormat(…)` 里的常驻句，
    /// 机制与双向元测试见 `+CaliberMerges.swift` 的 `stripLookupWrappers`；旧曲线 88→54 里有一部分是"句子变得看不见"）。
    /// → **72**（P71 三路收纳 14 条：A 代码页 5 处 / C 性能·日志·外壳 5 片 / B Git·依赖·健康 3 笔；
    /// 同批 tooltip 46 → 65、总量 132 → 137 —— 上漂那 5 是"屏上半句 + ⓘ 整句"各计一次，A 在 `CodeGitTooltipTests` 里逐条算过哪两句不该降账）。
    private static let visibleCaliberCeiling = 72

    /// 总量下限 = 播种时的可见 + tooltip 之和 **减去已核准的删除数**。
    ///
    /// 为什么必须有豁免口：盘点表里 16 处判的是「删」（同屏两遍、卡名换个说法再讲一遍），
    /// 那些不是"藏起来"，是本来就不该占两处。一条只许往上的守恒线会把合理的删句一起拦下，
    /// 而被人嫌烦的守卫活不过下一轮 —— 所以给一个**逐条留名**的口，而不是放宽判据。
    /// 101 → 100（P69 合流）：26 段"插值 + `+` 拼的半句"并成 10 条整句键，文本一字未少、单元少 8 个
    /// ⇒ 那 10 句由 `+CaliberMerges.swift` 逐句钉着还活着；删除仍只能走 `acceptedCaliberDeletions`。
    /// ⚠ 但 100 是**瞎尺子**的现量：分类器认了查表出口之后（P70 的 `stripLookupWrappers`），
    /// 同一份内容读成 86 + 46 = **132** ⇒ 地板按修好的口径收紧到 132（方向是变严，不是放宽）。
    private static let totalCaliberFloor = 132 - acceptedCaliberDeletions.count

    /// 已核准「删掉而不是藏进 ⓘ」的口径句：片段 → 为什么该删。
    /// **只由总工写**：切片负责人在自己汇报里列《建议删除》清单，由总工在合流时逐条登记。
    /// 每一条都要能被读者反驳 —— 空着的时候这条守卫就是纯守恒。
    /// 2026-09-21 播种时为空 —— 还没有任何一条删除经过复核。
    /// （空表得写 `[:]`：Swift 不接受只由注释撑着的 `[ ]` 当字典字面量。）
    static let acceptedCaliberDeletions: [String: String] = [:]

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
                out.append(Sighting(path: file.path, line: offset + 1, inTooltip: hoverOnly(
                    fragment, in: line,
                    lineHasCarrier: carrier.firstMatch(in: line, options: [], range: range) != nil)))
            }
        }
        return out
    }

    /// 片段在这一行是不是**只**住在 hover 字面量里。
    ///
    /// `NoteLine("取不到的一律显示 --，不会补成 0", help: "数值随采样刷新")` 是本轮
    /// 最标准的形状：承诺句在常驻那半截，hover 那半截是另一回事。按行判会把它
    /// 报成违规（S5 的元测试就是这么撞红的），所以这里逐个出现位置判。
    /// 片段落在所有字面量之外时（拼进变量的中段）退回整行线索 —— 与按行判同向。
    static func hoverOnly(_ fragment: String, in line: String, lineHasCarrier: Bool) -> Bool {
        let slots = literalSlots(in: line)
        var sawOccurrence = false
        var searchFrom = line.startIndex
        while let found = line.range(of: fragment, range: searchFrom..<line.endIndex) {
            sawOccurrence = true
            let enclosing = slots.first {
                $0.span.lowerBound <= found.lowerBound && found.upperBound <= $0.span.upperBound
            }
            guard enclosing?.slot == .tooltip || (enclosing == nil && lineHasCarrier) else { return false }
            searchFrom = line.index(after: found.lowerBound)
        }
        return sawOccurrence
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
              + "（tooltip 承载 \(tooltip.count) 条 / 扫描面 \(files.count) 个文件）" + Self.dump(visible))
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

    /// 元测试：`help:` 标签形状必须被认成"已藏"，同时**不能反过来**把同行的短句也算进 tooltip。
    func test_meta_labeledHelpSlotIsCountedAsHidden() {
        let moved = [(path: "Views/Fake.swift", content: """
        NoteLine("屏上留的短半句", role: .neutral, help: "这一长句已经进了 hover，它绝不能再被算进常驻量里面去")
        """)]
        let (visible, tooltip) = Self.scan(moved)
        XCTAssertTrue(visible.isEmpty, "help: 里的长句仍被判成常驻 —— 尺子在惩罚用对 API 的人")
        XCTAssertEqual(tooltip.count, 1)
        // 反向：只有 `help:` 标签、没有承载组件的一行，不该凭空多出 tooltip 落点。
        let plain = [(path: "Views/Fake.swift", content: """
        NoteLine("只有正文的一行长句，它没有任何 help 参数，因此必须继续算进常驻量里面去")
        """)]
        XCTAssertEqual(Self.scan(plain).visible.count, 1, "无 help 的常驻句被漏计，A 棘轮就成了摆设")
        XCTAssertTrue(Self.scan(plain).tooltip.isEmpty)
    }

    /// 同行两句长句：常驻那半截算债、hover 那半截不算。
    /// 这是「留短藏长」的真实形状，按行判会**两个方向同时错**
    /// （常驻句被记成已藏 → A 虚降；整行被记成 hover → B 看不见有人删了常驻句）。
    func test_meta_mixedLineCountsEachLiteralOnItsOwnSlot() {
        let mixed = [(path: "Views/Fake.swift", content: """
        NoteLine("这一句常驻上屏，长度过门槛，它欠着一条应该还掉的口径债", help: "这一句已经在 hover 里，长得再长也不该算进常驻量里面去")
        """)]
        let (visible, tooltip) = Self.scan(mixed)
        XCTAssertEqual(visible.count, 1, "常驻那半截被漏计，A 棘轮会虚降：\(visible)")
        XCTAssertEqual(tooltip.count, 1, "hover 那半截没被认出来")
        XCTAssertTrue(visible[0].text.contains("常驻上屏"))
        // C 同理：承诺句在常驻半截时不许报违规，在 hover 半截时必须报。
        let commitment = ["常驻上屏"]
        XCTAssertTrue(Self.hiddenCommitments(commitment, files: mixed).isEmpty,
                      "承诺句住在可见槽位却被报成只剩 hover")
        let hoverted = [(path: "Views/Fake.swift", content: """
        NoteLine("短句", help: "常驻上屏这半截被搬进了 hover，它就该被点名")
        """)]
        XCTAssertEqual(Self.hiddenCommitments(commitment, files: hoverted).count, 1)
    }

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

    /// 豁免口自己也要有读者：登记必须**带原因**，且下界随登记数同步 ——
    /// 否则它就是一个可以悄悄清空存量的口子（本仓在别的基线清单上栽过同款）。
    func test_deletionRegistryCarriesAReasonAndMovesTheFloorOnlyThatMuch() {
        for (fragment, why) in Self.acceptedCaliberDeletions {
            XCTAssertFalse(fragment.trimmingCharacters(in: .whitespaces).isEmpty)
            XCTAssertGreaterThanOrEqual(why.trimmingCharacters(in: .whitespaces).count, 8,
                                        "「\(fragment)」的删除理由太短，无法被反驳：" + why)
        }
        XCTAssertEqual(Self.totalCaliberFloor, 132 - Self.acceptedCaliberDeletions.count,
                       "下界只能被登记数逐条抵掉，不许另写一个更小的数（基数 132 = 尺子认了查表出口之后的现量）")
    }

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
