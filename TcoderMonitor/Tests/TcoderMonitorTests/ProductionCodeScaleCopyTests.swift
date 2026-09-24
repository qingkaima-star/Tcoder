import XCTest
@testable import TcoderMonitor

/// R40 · 「生产码 N 行 / 全量 M 行」的**双语侧**与**真源码侧**（RD-67 · 台账卷四 §73）。
///
/// # 为什么单独一个文件
/// 键化这件事有四个各自会静默失灵的环节，逐个钉：
/// ① 复数槽必须**在真英文 bundle 上**选出 one / other 两支 —— `stringsdict` 的键不在
///   `.strings` 里，按正则数键的那把尺子看不见它，而查不中的表现是**退回中文整句**；
///   两个槽还必须**交叉**测（只测 (1,1) 与 (5,5) 会漏掉「整句只选了一支」这种错法）；
/// ② 模板里不许带非转换符的数字 —— `groupedInto` 按「第 i 个槽 ⇔ 第 i 段连续数字」配对，
///   多一枚 `0` 就会把千分位补到别人的数字上（中文态完全看不出来）；
/// ③ 英文值只用 ASCII 标点（一个 `，` 或 `（）` 就是把中文标点带进英文态）；
/// ④ 键必须真的被装配口查着（登记了没人查 = 白翻，本仓立过案）。
///
/// # 真源码那一格
/// 自扫本仓那句走的是产品同一条路（`SelfScanHarnessCase` 的缓存快照），并与无头那一路
/// 已有的 `CLIScoreText.fileRoleStatement` **对账**：两处读的是同一枚 `code.fileRoles`，
/// 数字必须相等。真值不在此处（手写的独立真值在 `ProductionScaleReadoutTests`）。
final class ProductionCodeScaleCopyTests: XCTestCase {

    private static let enCatalogDirectory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/en.lproj")

    private static let paired = "生产码 %1$lld 行 / 全量 %2$lld 行"
    private static let unmeasured = "生产码 -- / 全量 %lld 行 · 这一档没数出来，不是这一档没有生产码"
    private static let zero = "生产码这一档这次量到的是零，不是没数出来"
    private static let weak = "生产码里 %lld 个文件只有语言证据、路径没有线索，读这一档要按它打折"

    /// 整串 ASCII 吗？英文目录的值必须是：一个全角逗号或句号就是中文残留，
    /// 而按码点判「还残留中文」的那把尺子对 U+3000 段以外的中日韩标点同样判红。
    private static func isAsciiOnly(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy(\.isASCII)
    }

    /// 英文资源**必须在原位**：读不到就判败，不许静默跳过（跳过 = 这一族的绿是空转）。
    private static func englishBundle() throws -> Bundle {
        try XCTUnwrap(Bundle(url: enCatalogDirectory),
                      "打不开 \(enCatalogDirectory.path) —— 英文资源不在原位，本文件不能算通过")
    }

    // MARK: - ① 两条复数槽各自选支（交叉四格）

    func test_pairedSentencePicksBothPluralBranchesIndependently() throws {
        let bundle = try Self.englishBundle()
        XCTAssertFalse(bundle.localizedString(forKey: "%lld 行", value: "\u{FFFF}", table: nil)
            .contains("\u{FFFF}"), "连既有的「%lld 行」都查不到 ⇒ 这个 bundle 不是真的")
        let cases: [(slots: [Int], expect: String)] = [
            ([1, 1], "1 production code line / 1 line in total"),
            ([1, 5], "1 production code line / 5 lines in total"),
            ([3, 1], "3 production code lines / 1 line in total"),
            ([3, 5], "3 production code lines / 5 lines in total"),
        ]
        for item in cases {
            XCTAssertEqual(Self.english(bundle, key: Self.paired, slots: item.slots), item.expect,
                           "槽 \(item.slots) 填错 ⇒ 两个复数变量没有各选各的支")
        }
        // 交叉那四格的前提是「模板真的取到了两支」，所以顺手钉一句：中文态一字不差。
        XCTAssertEqual(localizedCount(Self.paired, slots: [13, 45]),
                       "生产码 13 行 / 全量 45 行")
    }

    /// 另外两条单槽键的 one / other；`--` 那一支的英文值里 `--` 必须原样在场
    /// （把缺数折成 0 的写法在中文态与英文态都会静默发生，这里两侧都拦）。
    func test_singleSlotKeysResolveBothBranchesAndKeepTheDashes() throws {
        let bundle = try Self.englishBundle()
        XCTAssertEqual(Self.english(bundle, key: Self.unmeasured, slots: [1]),
                       "production code -- / 1 line in total: this bucket was not measured, "
                       + "it is not an empty one")
        XCTAssertEqual(Self.english(bundle, key: Self.unmeasured, slots: [7]),
                       "production code -- / 7 lines in total: this bucket was not measured, "
                       + "it is not an empty one")
        XCTAssertEqual(Self.english(bundle, key: Self.weak, slots: [1]),
                       "1 production code file rests on language evidence only with no path clue, "
                       + "so discount this bucket")
        XCTAssertEqual(Self.english(bundle, key: Self.weak, slots: [7]),
                       "7 production code files rest on language evidence only with no path clue, "
                       + "so discount this bucket")
        XCTAssertFalse(bundle.localizedString(forKey: Self.zero, value: "\u{FFFF}", table: nil)
            .contains("\u{FFFF}"), "整句键没进目录（它没有数字槽，该在 .strings 里）：\(Self.zero)")

        // 中文态走装配口那一条出口（含千分位）：`--` 不许被折成 0、大数必须分组。
        XCTAssertEqual(localizedCount(Self.unmeasured, 45_678),
                       "生产码 -- / 全量 45,678 行 · 这一档没数出来，不是这一档没有生产码")
        XCTAssertEqual(localizedCount(Self.weak, 1_204),
                       "生产码里 1,204 个文件只有语言证据、路径没有线索，读这一档要按它打折")
    }

    /// 英文那一支：**从真 bundle 取模板再填槽**（与 `LocalizationGuardTests+MultiSlotCopy`
    /// 同一形状）。测试宿主的 `Bundle.main` 里没有 `en.lproj`，直接调 `localizedCount`
    /// 只会拿到中文 —— 那样测的是另一件事（下面那两条中文态断言）。
    private static func english(_ bundle: Bundle, key: String, slots: [Int]) -> String {
        let template = bundle.localizedString(forKey: key, value: "\u{FFFF}", table: nil)
        XCTAssertFalse(template.contains("\u{FFFF}"), "\(key) 在 stringsdict 里查不到")
        return String(format: template, arguments: slots)
    }

    // MARK: - ② 模板不许自带数字 / ③ 英文值只用 ASCII 标点

    func test_templatesCarryNoForeignDigitsAndEnglishIsPureAscii() throws {
        let path = LocalizationGuardTests.packageRoot
            .appendingPathComponent("Resources/en.lproj/Localizable.stringsdict").path
        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertFalse(text.isEmpty, "读不到 stringsdict ⇒ 本条在空转")
        for key in [Self.paired, Self.unmeasured, Self.weak] {
            guard let block = LocalizationGuardTests.stringsDictEntry(for: key, in: text) else {
                return XCTFail("\(key)：stringsdict 里没有这条顶层键（缩进不是一个 tab？）")
            }
            for source in [key] + LocalizationGuardTests.plistStrings(in: block) {
                if let digits = LocalizationGuardTests.foreignDigits(in: source) {
                    XCTFail("\(key) 的模板带了非转换符的数字 \(digits)：\"\(source)\"")
                }
            }
            // 英文侧（`NSStringLocalizedFormatKey` 与 one / other 那几串）只用 ASCII 标点。
            for value in LocalizationGuardTests.plistStrings(in: block) {
                XCTAssertTrue(Self.isAsciiOnly(value), "英文值只用 ASCII 标点，实得：\(value)")
            }
        }
        // .strings 里那枚无槽整句键。
        let strings = try String(contentsOf: LocalizationGuardTests.packageRoot
            .appendingPathComponent("Resources/en.lproj/Localizable.strings"))
        let entries = LocalizationGuardTests.parseCatalog(strings)
        let value = try XCTUnwrap(entries.first { $0.key == Self.zero }?.value,
                                  "整句键没登记进 .strings：\(Self.zero)")
        XCTAssertTrue(Self.isAsciiOnly(value), "英文值只用 ASCII 标点，实得：\(value)")
    }

    // MARK: - ④ 四枚键都必须被装配口查着（登记了没人查 = 白翻）

    func test_everyKeyIsLookedUpAtTheAssemblyPoint() throws {
        let bodies = try SurfaceScanKit.sourceFiles(under: "").map(\.content).joined()
        XCTAssertEqual(LocalizationGuardTests.unusedPluralKeys(
            [Self.paired, Self.unmeasured, Self.weak], in: bodies), [],
            "整句键登记了却没有生产者 ⇒ 屏上仍是拼出来的中文")
        XCTAssertTrue(bodies.contains(Self.zero), "无槽整句键不在源码里 ⇒ 已烂尾")
        // 反向（元测试）：假键必须报出来，否则上面那条绿只说明扫描面是空的。
        XCTAssertFalse(LocalizationGuardTests.unusedPluralKeys(
            ["R40 夹具：这条键绝不存在 %lld 行"], in: bodies).isEmpty,
                       "假键没被抓到 ⇒ 判据没有牙")
    }

    /// 装配口那三枚键的**名字**必须只住在那一个文件里（键名被抄到别处就是第二把尺子的前兆）。
    func test_keysAreNamedOnlyInsideTheAssemblyPoint() throws {
        let files = try SurfaceScanKit.sourceFiles(under: "")
        let offenders = files.filter { file in
            file.path.hasSuffix(ProductionCodeScaleGuardTests.home) == false
                && ProductionCodeScaleGuardTests.codeLines(file.content).contains { line in
                    line.contains(Self.paired) || line.contains(Self.weak)
                }
        }.map(\.path)
        XCTAssertTrue(offenders.isEmpty, "整句键被抄进别的文件：\(offenders)")
    }
}

// MARK: - 真源码那一格（产品同一条路，与本仓已有的自扫快照共用一份）

final class ProductionCodeScaleRealScanTests: SelfScanHarnessCase {

    /// 自扫本仓 ⇒ 这一句必须出声（本仓做了分档），且与无头那一路的
    /// `CLIScoreText.fileRoleStatement` 读到的是**同一个生产码行数**（两处读者不许分叉）。
    func testSelfScanSpeaksAndAgreesWithTheExistingCLIReader() async throws {
        let metrics = try await selfScan().code
        let line = try XCTUnwrap(ProductionCodeScaleReadout.reading(metrics),
                                 "扫本仓没落角色分档 ⇒ 这一句整条在屏上缺席")
        XCTAssertTrue(line.hasPrefix("生产码 "), line)
        XCTAssertTrue(line.contains(" / 全量 "), line)

        var report = ProjectReport(project: MonitoredProject(name: "本仓", path: "/repo"))
        report.code = metrics
        let cli = try XCTUnwrap(CLIScoreText.fileRoleLines(report).first { $0.contains("文件角色分档") },
                                "CLI 那一行没出来 ⇒ 两处读者对不上，本条不能算对过表")
        XCTAssertTrue(Self.productionMatches(line: line, cli: cli),
                       "同一枚字段两处读数分叉：界面句「\(line)」 / CLI 句「\(cli)」")
        print("【R40 真扫本仓】\(line)\n  同一次扫描的 CLI 那一行：\(cli)")
        GuardLedger.record(guard: "ProductionCodeScaleCopyTests",
                           readings: ["真扫本仓那句：\(line)"])
    }

    /// 两句格式不同（界面句是「生产码 N 行 / 全量 M 行」、CLI 句是「生产源码 N 个 / M 代码行」），
    /// 比对的是**同一个数**：生产码那一档的代码行数。
    static func productionMatches(line: String, cli: String) -> Bool {
        guard let mine = number(before: " 行 /", in: line),
              let theirs = number(before: " 代码行", in: cli) else { return false }
        return mine == theirs
    }

    /// 取某个标签**紧前面**那一段连续数字（允许千分位逗号），取不到返回 nil。
    static func number(before label: String, in text: String) -> Int? {
        guard let range = text.range(of: label) else { return nil }
        let digits = text[..<range.lowerBound].reversed()
            .prefix { $0.isNumber || $0 == "," }
            .reversed()
        return Int(String(digits).replacingOccurrences(of: ",", with: ""))
    }
}
