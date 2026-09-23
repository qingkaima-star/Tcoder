import Foundation
import XCTest
@testable import TcoderMonitor

// MARK: - 目录必须能被**系统那个解析器**读进来
//
// OWNER: 总工程师（批次 P6-E 收尾时立的规矩）
//
// 为什么单独一条：2026-09-21 我自己往 `Localizable.strings` 追加了一条英文值，
// 里面写了没转义的双引号（`means "our rules did not run"`）。整份文件当场变成
// **解析失败**，于是 `NSLocalizedString` 对**每一个键**都退回键本身 ——
// 英文态九页全部变回中文。而既有守卫全是绿的，因为它们用正则数键、
// 比对键集合，**从不按真正的 .strings 语法解析**。
// 一把只查"内容对不对"的尺子，看不见"整把尺子量的东西已经读不出来"。
//
// 判据因此选 `PropertyListSerialization` —— 它就是 `Foundation` 读 .strings 用的
// 那个解析器。它说失败，运行时就一定查不到表。

extension LocalizationGuardTests {

    /// 用系统解析器读一份 .strings / .stringsdict。失败即返回错误描述。
    static func catalogParseFailure(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return "读不到文件" }
        do {
            let object = try PropertyListSerialization.propertyList(from: data, format: nil)
            guard let dict = object as? [String: Any] else { return "顶层不是字典" }
            guard !dict.isEmpty else { return "解析成功但 0 键" }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func test_localizationCatalogsParseWithTheSystemReader() throws {
        let base = LocalizationGuardTests.packageRoot
        for name in ["Resources/en.lproj/Localizable.strings",
                     "Resources/en.lproj/Localizable.stringsdict"] {
            let url = base.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                XCTFail("\(name) 不在包里 —— 打出来的 App 不会说第二种语言")
                continue
            }
            if let failure = Self.catalogParseFailure(at: url) {
                XCTFail("""
                \(name) 用系统解析器读不进来：\(failure)
                后果不是"某几条没翻"，是**整份目录作废、所有键退回中文**，
                而按正则数键的守卫会全部保持绿色。
                最常见成因：值里写了没转义的双引号（`"..."` 里再出现 `"` 必须写成 \\"）。
                """)
            }
        }
    }

    /// 反向自证：把一条未转义引号喂进去，必须判失败。
    func test_theRulerCatchesAnUnescapedQuote() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-ruler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let broken = dir.appendingPathComponent("broken.strings")
        try "\"你好\" = \"hello\";\n\"坏\" = \"这里有 \"未转义\" 引号\";\n".write(
            to: broken, atomically: true, encoding: .utf8)
        XCTAssertNotNil(Self.catalogParseFailure(at: broken),
                        "未转义引号没被抓到 → 这条守卫挡不住下一次整份目录作废")

        let fine = dir.appendingPathComponent("fine.strings")
        try "\"你好\" = \"hello\";\n\"转义\" = \"里面有 \\\"引号\\\"\";\n".write(
            to: fine, atomically: true, encoding: .utf8)
        XCTAssertNil(Self.catalogParseFailure(at: fine),
                     "合法转义被误判 → 每次加带引号的译文都要手工绕过这条门")
    }

    /// 量词族必须与全站大读数**同一把记法**。
    /// 交付头实拍「代码规模」语言构成那一列打的是 `46330 行`，
    /// 而同页总行数打的是 `77,515` —— 同一个量在一屏上两种写法。
    /// 根因是 84 个 `stringsdict` 量词键一律 `%lld`（复数规则要数字），
    /// 而 `String(format:)` 实测不认分组标志 `%'lld` ⇒ 只能在填完之后补分隔符。
    func test_countsGetTheSameSeparatorsAsBigReadouts() {
        XCTAssertEqual(groupedInto("46330 行", count: 46330), "46,330 行")
        XCTAssertEqual(groupedInto("999 行", count: 999), "999 行", "不足一千不该加分隔")
        XCTAssertEqual(groupedInto("第 1024 名 · 1024 行", count: 1024), "第 1,024 名 · 1024 行",
                       "只替换第一次出现的那串（那才是刚填进去的 token），后面的译文自带数字不动")
        XCTAssertEqual(groupedInto("没有数字", count: 5000), "没有数字",
                       "找不到数字串就原样返回 —— 不许猜着改")
        XCTAssertEqual(localizedCount("%lld 行", 46330), "46,330 行", "端到端：目录 + stringsdict 那条路也要补")
        XCTAssertEqual(localizedCount("%lld 行", 5), "5 行", "小数量词一字不变")
    }

    // MARK: - 批次 P69：屏上正文那三条"未登记话术"的复数键（B 类收口）

    /// 这四条整句复数键必须**在真英文 bundle 上**选出 one / other 两支。
    ///
    /// 为什么不能只靠"键登记进目录了"那条守卫：`stringsdict` 的键不在 `.strings` 里，
    /// 按正则数键的尺子看不见它，而 `localizedCount` 查不中时的表现是
    /// **退回中文原句**——英文态照样铺中文，且一条守卫都不红。
    /// 所以这里走产品同一条路（`localizedString(forKey:)` + `String(format:)`），
    /// 并把 1 这一档单独钉住：十八趟读数里的样本全是复数，
    /// 没有 1 的读数就只能算"结构对了"，不能算"翻对了"。
    func test_p69CountSentencesResolveBothPluralFormsInEnglish() throws {
        let en = LocalizationGuardTests.packageRoot.appendingPathComponent("Resources/en.lproj")
        guard let enBundle = Bundle(url: en) else {
            return XCTFail("打不开 \(en.path) —— 英文资源不在原位，本条不能算通过")
        }
        XCTAssertFalse(enBundle.localizedString(forKey: "%lld 行", value: "\u{FFFF}", table: nil)
            .contains("\u{FFFF}"), "连既有的「%lld 行」都查不到 ⇒ 这个 bundle 不是真的")
        let cases: [(key: String, many: Int, one: String, other: String)] = [
            ("窗口内确认崩溃；其中 FATAL %lld 条", 4,
             "Crash confirmed inside the window; 1 FATAL entry among them",
             "Crash confirmed inside the window; 4 FATAL entries among them"),
            ("窗口内确认崩溃 %lld 次，只统计有真实事件证据的报告", 4,
             "Crash confirmed 1 time inside the window; only reports with real event evidence are counted",
             "Crash confirmed 4 times inside the window; only reports with real event evidence are counted"),
            ("共 %lld 类签名", 7, "1 signature class in total", "7 signature classes in total"),
            ("共 %lld 类签名 · 按出现次数排序", 7,
             "1 signature class in total, sorted by occurrences",
             "7 signature classes in total, sorted by occurrences"),
        ]
        for item in cases {
            let englishValue = enBundle.localizedString(forKey: item.key, value: "\u{FFFF}", table: nil)
            XCTAssertFalse(englishValue.contains("\u{FFFF}"), "\(item.key) 在 stringsdict 里查不到")
            XCTAssertEqual(String(format: englishValue, 1), item.one, "\(item.key) 的单数形态")
            XCTAssertEqual(String(format: englishValue, item.many), item.other, "\(item.key) 的复数形态")
        }
    }

    /// 正向：这四条键确实被 `localizedCount` 用着。反向（元测试）：一条不存在的键必须报出来。
    /// 没有反向那一半，"逐条都在源码里"这条绿只说明扫描面是空的。
    func test_p69CountKeysAreLookedUpAtTheirProducers() throws {
        let files = try SurfaceScanKit.sourceFiles(under: "")
        let bodies = files.map(\.content).reduce("") { $0 + $1 }
        let keys = ["窗口内确认崩溃；其中 FATAL %lld 条",
                    "窗口内确认崩溃 %lld 次，只统计有真实事件证据的报告",
                    "共 %lld 类签名",
                    "共 %lld 类签名 · 按出现次数排序"]
        XCTAssertEqual(Self.unusedPluralKeys(keys, in: bodies), [],
                       "整句复数键登记了却没人查 ⇒ 屏上仍是拼出来的中文")
        XCTAssertFalse(Self.unusedPluralKeys(["P69 夹具：这条键绝不存在 %lld 条"], in: bodies).isEmpty,
                       "假键没被抓到 ⇒ 上面那条绿不可信")
    }

    static func unusedPluralKeys(_ keys: [String], in bodies: String) -> [String] {
        keys.filter { !bodies.contains($0) }
    }

    // MARK: - 批次 P69a：代码风险这一片收口时新增的整句量词键（7 条里的第 1 条）

    /// `%lld 个条目` 必须在**真英文 bundle** 上选出 one / other 两支，并且真的被生产者查着。
    ///
    /// 为什么跟着 P69 那两条的形状再写一遍而不是复用：`describe(unit:)` 的入参从半截量词
    /// （`"个条目"`）换成整句键之后，"键查不中"的表现不再是"退回中文"而是
    /// **屏幕上打「%lld 个条目」** —— 字面 `%lld` 漏上屏，比铺中文更难看，
    /// 而按正则数键的尺子看不见它（它读的是 `.strings`，复数形态住在 `.stringsdict`）。
    /// 所以两侧都要量：bundle 解析得出两支、源码里有人查这一枚。
    func test_p69aScopeEntryCountResolvesBothPluralFormsAndHasAProducer() throws {
        let en = LocalizationGuardTests.packageRoot.appendingPathComponent("Resources/en.lproj")
        guard let enBundle = Bundle(url: en) else {
            return XCTFail("打不开 \(en.path) —— 英文资源不在原位，本条不能算通过")
        }
        let key = "%lld 个条目"
        let english = enBundle.localizedString(forKey: key, value: "\u{FFFF}", table: nil)
        XCTAssertFalse(english.contains("\u{FFFF}"), "\(key) 在 stringsdict 里查不到")
        XCTAssertEqual(String(format: english, 1), "1 entry", "单数形态")
        XCTAssertEqual(String(format: english, 4), "4 entries", "复数形态")
        // 正向：三个调用点里至少这一枚真的在源码里被传进 `describe(unit:)`。
        let bodies = try SurfaceScanKit.sourceFiles(under: "").map(\.content).reduce("") { $0 + $1 }
        XCTAssertEqual(Self.unusedPluralKeys([key], in: bodies), [],
                       "整句量词键登记了却没有生产者 ⇒ 屏上仍是拼出来的中文")
        // 反向（元测试）：一条不存在的键必须报出来，否则上面那条绿只说明扫描面是空的。
        XCTAssertFalse(Self.unusedPluralKeys(["P69a 夹具：这条键绝不存在 %lld 个条目"], in: bodies).isEmpty,
                       "假键没被抓到 ⇒ 判据没有牙")
    }

    /// 句末标点随语言：中文 `。`、英文 `.`。
    /// 探针在测试宿主里恒判中文（`Bundle.main` 没有 `en.lproj`），
    /// 所以英文那一支用入参驱动 —— 两支都要咬得住。
    func test_endingSentencePicksTheTerminatorOfTheActiveLanguage() {
        XCTAssertEqual(endingSentence("窗口内确认崩溃", chinese: true), "窗口内确认崩溃。")
        XCTAssertEqual(endingSentence("Crash confirmed", chinese: false), "Crash confirmed.",
                       "英文句子尾巴挂一个 U+3002 ⇒ 十八趟读数按码点仍判它残留中文")
        XCTAssertTrue(endingSentence("甲").hasSuffix("。"),
                      "测试宿主里探针应当判中文；这里红了说明探针前提变了，本文件多条判据要重读")
    }
}
