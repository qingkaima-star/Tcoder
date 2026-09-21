import XCTest

/// OWNER: WS-S3Git —— 本片「碎文案收进 ⓘ」的行级指认。
///
/// 全站三条尺子在 `TooltipMigrationGuardTests`（A 只减不增 / B 总量守恒 / C 承诺常驻），
/// 那三条是**九页共用**的、只由总工改的闸门。本文件只补本片自己的两件事：
/// 1. **一条文案只有一个落点**：搬进 ⓘ 的原句，屏上那一份必须真的不再出现；
///    留在屏上的短标签，必须真的还在屏上（不是只在 hover 里）。
/// 2. **画法全站唯一**：`Views/Git/**` 里不许再有人自己画一枚问号图标。
///
/// 判据形状与总工那把尺子同源（逐行、剥整行注释、按承载位分类），
/// 但把 `help:` 也算成 ⓘ 承载位 —— 它确实不再常驻上屏。
/// ⚠ 两类 `help:` 的**可见性不同**：`NoteLine.help:` 走 `Design/CopyHelp.swift`
/// 真上屏一枚问号；`DataFieldRow.help:` 走 `Design/DataRows.swift` 的
/// `DataOptionalHelp` → 只挂 `.help()`，问号看不见（悬停目标就是它解释的那一行）。
/// 本文件只判「有没有第二个落点」，不判问号可见性 —— 后者记进汇报的契约缺口。
final class GitTooltipTests: XCTestCase {

    // MARK: - 尺子

    /// ⓘ 承载位：`.help(…)`、共用的 `CopyHelpBadge(…)`、以及各组件的 `help:` 参数。
    static let tooltipCarrier = "\\.help\\s*\\(|CopyHelpBadge\\s*\\(|help\\s*:"

    static func codeLines(_ content: String) -> [(n: Int, text: String, inTooltip: Bool)] {
        let carrier = try! NSRegularExpression(pattern: tooltipCarrier)
        return content.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { index, raw -> (Int, String, Bool) in
                let text = String(raw)
                let range = NSRange(text.startIndex..., in: text)
                return (index + 1, text, carrier.firstMatch(in: text, options: [], range: range) != nil)
            }
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    /// 某个串在本片五个页面文件里的全部落点。
    static func sightings(_ fragment: String, in files: [(path: String, content: String)]) -> [String] {
        files.flatMap { file in
            codeLines(file.content)
                .filter { $0.text.contains(fragment) }
                .map { "\(file.path):\($0.n)\($0.inTooltip ? " [ⓘ]" : " [屏]")" }
        }
    }

    /// 只允许 hover 可见：至少一处、且每一处都在 ⓘ 承载位上。
    static func screenVisibleOccurrences(_ fragment: String,
                                         in files: [(path: String, content: String)]) -> [String] {
        sightings(fragment, in: files).filter { !$0.hasSuffix("[ⓘ]") }
    }

    static func gitViewFiles() throws -> [(path: String, content: String)] {
        let root = URL(fileURLWithPath: #filePath)     // …/TcoderMonitor/Tests/TcoderMonitorTests/本文件.swift
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TcoderMonitor/Views/Git").path
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root) else {
            return XCTFailEven("扫不到 \(root) —— 路径没了不等于「文案已经收干净」")
        }
        let out = names.filter { $0.hasSuffix(".swift") }.sorted().map { name in
            (path: name, content: (try? String(contentsOfFile: "\(root)/\(name)", encoding: .utf8)) ?? "")
        }
        XCTAssertGreaterThanOrEqual(out.count, 5, "本片扫描面只剩 \(out.count) 个文件，分母不对")
        return out
    }

    // MARK: - 本片已收进 ⓘ 的原句：屏上不许再有第二份

    /// 每条 = 「进 ⓘ 的那句完整原话」。逐条对应汇报里的落点表。
    private static let movedIntoTooltip: [String] = [
        "以下均为测得值，口径见上方口径条",                                     // D1
        "数据源只有边际分布 · 单元格是小时与星期两档归一的近似强度",                  // D9
        "当前只分析了提交数最多的那一个；要单独分析其中某个，直接把它添加为项目",        // D8
        "Git 分析没有产出按时间分桶的提交数据，因此这里无法给出峰值或均值。",          // D13
        "来源未记录（旧数据，重新分析后可见）",                                   // D7
    ]

    func test_movedCalibersNoLongerReachTheScreen() throws {
        let files = try Self.gitViewFiles()
        let offenders = Self.movedIntoTooltip.flatMap { sentence in
            Self.screenVisibleOccurrences(sentence, in: files).map { "\(sentence) 仍常驻上屏 → \($0)" }
        }
        XCTAssertTrue(offenders.isEmpty, "一条文案两个落点（屏上 + ⓘ 各一份）：\n" + offenders.joined(separator: "\n"))
    }

    func test_everyMovedCaliberActuallySitsOnATooltipCarrier() throws {
        let files = try Self.gitViewFiles()
        let missing = Self.movedIntoTooltip.filter { Self.sightings($0, in: files).isEmpty }
        XCTAssertTrue(missing.isEmpty, "这些句子既不在屏上也不在 ⓘ 里 —— 是被删了而不是被藏了：\(missing)")
    }

    // MARK: - 必须继续看得见的（诚实性红线，含 Z/C 名单里落在本页的那条）

    private static let mustStayOnScreen: [String] = [
        "未做时区归一",                       // C 名单：未做时区归一就长在这一页
        "按各作者本地时区合并",
        "数据源只有边际分布",                  // D9 留下的短标签
        "当前只分析了提交数最多的那一个",        // D8 留下的短标签
        "Git 分析没有产出按时间分桶的提交数据。", // D13 留下的短标签
        "来源未记录",                         // D7 留下的短标签
        "scope.headline",                   // D2/E3：分母口径句整体留在屏上（源在 CodeGit，不归本片）
        "totalTileCaption",                 // D4
        "authorTileCaption",                // D5
    ]

    func test_honestyCalibersStayOnScreen() throws {
        let files = try Self.gitViewFiles()
        let offenders = Self.mustStayOnScreen
            .filter { Self.screenVisibleOccurrences($0, in: files).isEmpty }
        XCTAssertTrue(offenders.isEmpty,
                      "这些口径不许只靠悬停看见（A 的下界就是这一条）：\(offenders)")
    }

    // MARK: - 画法全站唯一：本片不自己造第二枚问号

    func test_gitPagesDrawNoHandRolledHelpIcon() throws {
        let files = try Self.gitViewFiles()
        let offenders = files.flatMap { file in
            Self.codeLines(file.content)
                .filter { $0.text.contains("questionmark.circle") || $0.text.contains("Image(systemName:") }
                .map { "\(file.path):\($0.n)" }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "ⓘ 的画法全站唯一（`Design/CopyHelp.swift`），页面里不许再画一遍：\(offenders)")
    }

    // MARK: - 元测试：这把尺子自己必须能抓到坏样例

    /// 同一句同时挂在屏上与 ⓘ 上 = 两个落点，必须红；只在 ⓘ 上 = 合法。
    func test_meta_twoLandingDetectorCatchesTheDuplicateAndSparesTheMovedOne() {
        let duplicated = [(path: "Fake.swift", content: """
        GlassSection("卡", subtitle: "这是一条足够长的解释性口径句，屏上与 ⓘ 各留了一份") {
            CopyHelpBadge("这是一条足够长的解释性口径句，屏上与 ⓘ 各留了一份")
        }
        """)]
        XCTAssertEqual(Self.screenVisibleOccurrences("这是一条足够长的解释性口径句，屏上与 ⓘ 各留了一份",
                                                    in: duplicated).count, 1)

        let moved = [(path: "Fake.swift", content: """
        GlassSection("卡", subtitle: "留下的短句",
                     trailing: AnyView(CopyHelpBadge("这是一条足够长的解释性口径句，屏上与 ⓘ 各留了一份"))) {
            EmptyView()
        }
        """)]
        XCTAssertTrue(Self.screenVisibleOccurrences("这是一条足够长的解释性口径句，屏上与 ⓘ 各留了一份",
                                                   in: moved).isEmpty)
        // 反向自证：搬进 ⓘ 之后，"必须还在屏上"的那把尺子要能喊出「整句找不到」。
        XCTAssertFalse(Self.sightings("留下的短句", in: moved).isEmpty)
        XCTAssertTrue(Self.sightings("这一句根本不存在", in: moved).isEmpty)
    }

    /// 剥注释必须真在剥：注释里写着的口径句不算上屏。
    func test_meta_commentLinesAreNotCountedAsScreenText() {
        let commented = [(path: "Fake.swift", content: """
        // subtitle: "只在注释里出现的解释性长句，它一个字都没有上屏"
        Text(verbatim: "x")
        """)]
        XCTAssertTrue(Self.screenVisibleOccurrences("只在注释里出现的解释性长句，它一个字都没有上屏",
                                                   in: commented).isEmpty)
    }
}

private func XCTFailEven(_ message: String) -> [(path: String, content: String)] {
    XCTFail(message)
    return []
}
