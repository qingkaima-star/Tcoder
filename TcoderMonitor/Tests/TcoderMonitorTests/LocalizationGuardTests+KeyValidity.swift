import Foundation
import XCTest
@testable import TcoderMonitor

// MARK: - 键的有效性（批次 P5）
//
// 从 `LocalizationGuardTests.swift` 拆出来住：主文件加完 510 行，
// 超了 `X3TestSizeAuditTests` 与产品同口径的 400 行线。判据与元测试一字未改。
// 这两条管的是同一件事：**目录里有这条键 ≠ 运行时查得到这条键**。

extension LocalizationGuardTests {

    // MARK: - 守卫 1c：拼接出来的串**永远查不中**（翻了也白翻）

    /// 键必须是**运行时真正送进查表函数的那一串**。
    ///
    /// 2026-09-21 双语批量登记时，翻译同事抓到这个机制洞：源码里写
    /// `"历史里有提交…\n" + "另一段说明"`，于是**目录里那条以 `\n` 结尾的键**
    /// 在运行时永远等不到 —— `Text("…")` 生成的键是拼接后的整串，
    /// 半句键查不中 ⇒ 英文态退回中文，而守卫 1/2/3 全是绿的：
    /// 守卫 3 只要求"键作为完整字面量出现在源码里"，半句恰好满足它。
    /// ⇒ 这是"翻了但白翻"，比没翻更危险（它看起来有账）。
    static func keysBuiltByConcatenation(keys: [String], source: String) -> [String] {
        var out: [String] = []
        for key in keys {
            let escaped = key.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                // 字面量后面紧跟 `+ "`（同一行或换行后）= 它只是半句
                let pattern = "\"" + escaped + "\"\\s*(?:\\n\\s*)?\\+\\s*(?:\\n\\s*)*\""
                let re = try! NSRegularExpression(pattern: pattern, options: [])
                if re.firstMatch(in: source, options: [], range: NSRange(source.startIndex..., in: source)) != nil {
                    out.append(key)
                }
            }
        return out
    }

    /// 分母自证：扫描面**动态枚举**整个 `Sources/TcoderMonitor`，新增目录会自动进来；
    /// 反过来，一个目录被改名或整片消失会让存量"假短"。这里钉住已知的六个一级目录，
    /// 少一个就红 —— 断言读的是 `sourceFiles()` 自己看见的路径，不是另抄一份清单。
    func test_meta_scanSurfaceCoversEveryTopLevelDirectory() throws {
        let seen = Set(try Self.sourceFiles().compactMap {
            $0.path.split(separator: "/").first.map(String.init)
        })
        for dir in ["App", "Design", "Models", "Services", "Utilities", "Views"] {
            XCTAssertTrue(seen.contains(dir),
                          "扫描面里没有 \(dir)/ —— 这一片的存量被隐形漏掉：\(seen.sorted())")
        }
    }

    func test_noRegisteredKeyIsOnlyAHalfSentence() throws {
        let source = try Self.walkFiles(in: Self.packageRoot.appendingPathComponent("Sources/TcoderMonitor").path)
            .reduce("") { $0 + ((try? String(contentsOfFile: $1, encoding: .utf8)) ?? "") }
        let offenders = Self.keysBuiltByConcatenation(
            keys: Self.catalogKeysForConcatenationCheck(try Self.catalog()), source: source)
        XCTAssertTrue(offenders.isEmpty,
                      "这些键在源码里是被 `+` 拼出去的半句，运行时永远查不中（英文态仍显示中文）：\n"
                      + offenders.joined(separator: "\n"))
    }

    /// 只查"值里带句末标点或以 `\n` 结尾"的可疑键：短标签不会与下一段拼接，
    /// 全量扫会让报错淹没在噪声里（也拖慢守卫）。
    static func catalogKeysForConcatenationCheck(_ entries: [(key: String, value: String)]) -> [String] {
        entries.map(\.key).filter { $0.hasSuffix("\\n") || $0.hasSuffix("。") || $0.hasSuffix("，") }
    }

    /// 元测试：半句必须抓到、整句不得误判。
    func test_concatenationGuardCatchesHalfSentencesAndSparesWholeOnes() {
        let source = """
        let a = DataNotice(text: "历史里有提交，\\n" + "但没有作者字段。")
        let b = DataNotice(text: "这是一句完整的话，没有拼接。")
        """
        XCTAssertEqual(Self.keysBuiltByConcatenation(keys: ["历史里有提交，\\n"], source: source),
                       ["历史里有提交，\\n"], "半句键没被抓到")
        XCTAssertTrue(Self.keysBuiltByConcatenation(keys: ["这是一句完整的话，没有拼接。"], source: source).isEmpty,
                      "整句键被误判")
        // 分母自证：可疑键筛选器确实会挑出以 \n / 。 结尾的键
        XCTAssertEqual(Self.catalogKeysForConcatenationCheck([
            (key: "甲\\n", value: "A"), (key: "乙。", value: "B"), (key: "丙", value: "C")
        ].map { (key: $0.key, value: $0.value) }), ["甲\\n", "乙。"])
    }

    /// stringsdict 里的**顶层键**也算"已登记"。
    ///
    /// 复数串（`%lld 次`、`另有 %lld 处`）住在 `Localizable.stringsdict`，
    /// 不在 `.strings` 里。守卫原来只认 `.strings`，于是"已经翻了复数形态"的键
    /// 会被算成双语债 —— 逼人把复数串退回单数键，那正是"乱翻译"的成因。
    static func stringsDictKeys(in text: String) -> Set<String> {
        // 顶层键 = 第一个 `<dict>` 之后、缩进只有一层 tab 的 `<key>`。
        // 用缩进判层级，比数尖括号稳（`one`/`other` 那些是三层）。
        let re = try! NSRegularExpression(pattern: "^\t<key>(.+)</key>$", options: [.anchorsMatchLines])
        let range = NSRange(text.startIndex..., in: text)
        return Set(re.matches(in: text, options: [], range: range).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        })
    }

    /// 读 stringsdict 的顶层键；文件不存在时返回空集（源语言侧不需要目录）。
    static func registeredStringsDictKeys() -> Set<String> {
        let path = packageRoot.appendingPathComponent("Resources/en.lproj/Localizable.stringsdict").path
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return stringsDictKeys(in: text)
    }

    func test_stringsDictTopLevelKeysAreParsed() throws {
        let path = Self.packageRoot.appendingPathComponent("Resources/en.lproj/Localizable.stringsdict").path
        let keys = Self.stringsDictKeys(in: try String(contentsOfFile: path, encoding: .utf8))
        XCTAssertFalse(keys.isEmpty, "stringsdict 解析出 0 个顶层键 —— 解析器坏了")
        XCTAssertTrue(keys.contains("%lld 次"), "复数键没被认成已登记：\(keys.sorted())")
        XCTAssertFalse(keys.contains("one"), "把子层的 one/other 当成了顶层键")
        XCTAssertFalse(keys.contains("NSStringLocalizedFormatKey"), "把元数据键当成了文案键")
    }
    // MARK: - 守卫 1f（P58）：英文目录的值里不许留中日韩文字或标点

    /// **登记了 ≠ 翻完了**：值里只要还留着一个中日韩字符，英文态那一行就是半英半中，
    /// 而"查表必有键"那条守卫对它完全绿灯 —— 它只看键在不在，不看值。
    ///
    /// 为什么不复用仓里已有的两把 `containsHan`（`ScoreCurves` 与
    /// `DependencyWordingGuardTests`）：那两条判的是「这算不算一个汉字**词**」，
    /// 明令把全角标点排除在外；本条判的是「这段英文还**残留**着中文的痕迹吗」，
    /// 所以 `「」`、`。`、`，` 一个都不许放过。**两个判据不同，别合并成一把尺子。**
    static func cjkResidue(in text: String) -> [Character] {
        text.filter { isCJKCodePoint($0) }
    }

    private static func isCJKCodePoint(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            let value = scalar.value
            return (0x2E80...0x303F).contains(value)   // 中日韩部首、标点、假名
                || (0x3041...0x33FF).contains(value)   // 平假名/片假名/中日韩符号
                || (0x3400...0x4DBF).contains(value)   // 汉字扩展 A
                || (0x4E00...0x9FFF).contains(value)   // 汉字
                || (0xAC00...0xD7A3).contains(value)   // 韩文音节
                || (0xF900...0xFAFF).contains(value)   // 兼容汉字
                || (0xFE30...0xFE6F).contains(value)   // 兼容标点
                || (0xFF00...0xFF60).contains(value)   // 全角形式（含「，」（））
        }
    }

    static func entriesWithCJKResidue(_ entries: [(key: String, value: String)]) -> [String] {
        entries.filter { !cjkResidue(in: $0.value).isEmpty }
            .map { "\(cjkResidue(in: $0.value)) → \"\($0.key)\" = \"\($0.value)\"" }
    }

    func test_englishCatalogValuesCarryNoChineseResidue() throws {
        let entries = try Self.catalog()
        XCTAssertFalse(entries.isEmpty, "目录读空 ⇒ 这条判据在空转")
        let offenders = Self.entriesWithCJKResidue(entries)
        XCTAssertTrue(offenders.isEmpty,
                      "这些英文译文里还留着中日韩文字或标点 ⇒ 英文态那一行半英半中，"
                    + "而「查表必有键」那条看不见它（它只看键在不在）：\n  "
                    + offenders.sorted().joined(separator: "\n  "))
        print("【英文目录纯净】扫 \(entries.count) 条 → 值里残留中日韩文字/标点 0 条"
            + "（P58 首测 642 条里抓到 1 条：书名号「」）")
    }

    /// 元测试：书名号与汉字两种残留都要被抓到，半角引号/破折号/省略号不许误伤。
    /// 没有这半边，上面那条绿只可能意味着"过滤器没匹配上任何东西"。
    func test_meta_cjkResidueRulerCatchesBracketsAndSparesLatinPunctuation() {
        let dirty = [
            (key: "用「附加日志文件」手动选择。", value: "Use 「Attach Log Files」 by hand."),
            (key: "任何汉字", value: "still 中文 here"),
            (key: "全角逗号", value: "one，two"),
        ].map { (key: $0.key, value: $0.value) }
        XCTAssertEqual(Self.entriesWithCJKResidue(dirty).count, 3,
                       "三种残留形状漏一种，那一族就会继续在英文目录里假绿")
        // 英文译文里合法的标点：半角引号、en dash、省略号、中点、×
        let clean = [
            "Use \"Attach Log Files\" by hand.", "2%–15% band", "…coming later",
            "Merges included · non-merge", "CC≥16", "−22 points", "Errors per 1,000 log lines",
        ].map { (key: "k", value: $0) }
        XCTAssertTrue(Self.entriesWithCJKResidue(clean).isEmpty,
                      "合法英文标点被误判 ⇒ 下次有人为了过守卫去改译文")
        // 反向自查：汉字这一档仍然判得出（上面 clean 全是拉丁文，漏了它也会"绿"）。
        XCTAssertFalse(Self.cjkResidue(in: "键本身当然还是中文").isEmpty,
                       "汉字判不出 ⇒ 这条尺子根本没有牙")
        // **键**是中文原文，判据只量值：整本目录的键都含汉字，键算进去它就没法用了。
        XCTAssertEqual(Self.entriesWithCJKResidue([(key: "中文键", value: "English value")]).count, 0,
                       "把键算进去 ⇒ 每条键都违规，判据立刻失去意义")
    }

    // MARK: - 守卫 1k（P65）：值里不许留 JSON 式的 `\uXXXX` 转义

    /// `.strings` 认的是 `\UXXXX`（**大写** U）与 `\n`/`\t`/`\"`/`\\`；写成 JSON 式的 `\u201c`
    /// 时，运行时解析器**吃掉反斜杠、留下字面的 `u201c`**，屏上就长出
    /// 「Identity u201cTcoder Teamu201d holds 75% of co…」这种机器串
    /// （2026-09-23 英文窄态截断普查抓到的，同一行还顺带把弯引号丢了）。
    /// 它对 `plutil -lint`、按正则数键的四条守卫、以及"逐键查得到"（1i）**全都成立**：
    /// 键查得到、值也非空，只是值被解析器改了形状 ⇒ 判据必须钉**写法**本身。
    static func jsonStyleUnicodeEscapes(in text: String) -> [Substring] {
        let pattern = #"\\u[0-9a-fA-F]{4}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            XCTFail("转义判据的正则构造失败，本条不能算通过")
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { text[$0] }
        }
    }

    func test_englishCatalogValuesHaveNoJSONStyleUnicodeEscapes() throws {
        let entries = try Self.catalog()
        XCTAssertFalse(entries.isEmpty, "目录读空 ⇒ 这条判据在空转")
        let offenders = entries.filter { !Self.jsonStyleUnicodeEscapes(in: $0.value).isEmpty }
            .map { "\(Self.jsonStyleUnicodeEscapes(in: $0.value)) 残在 \"\($0.key)\" 的值里" }
        XCTAssertTrue(offenders.isEmpty,
                      "英文值里写着 `.strings` 不认的 JSON 式转义 ⇒ 运行时会被解析器改成字面串上屏，"
                    + "要弯引号/破折号就直接写字符：\n  " + offenders.sorted().joined(separator: "\n  "))
        print("【目录转义写法】扫 \(entries.count) 条 → JSON 式 \\uXXXX 写法 \(offenders.count) 条")
    }

    /// 元测试：脏样例必须被抓，三种**合法**写法一种都不许误判。
    func test_meta_jsonEscapeRulerCatchesLowercaseUAndSparesLegalForms() {
        let dirty = #"Identity \u201cTeam\u201d holds \u201475%"#
        XCTAssertEqual(Self.jsonStyleUnicodeEscapes(in: dirty).count, 3,
                       "三个 JSON 式转义只抓到一部分 ⇒ 判据在按位置漏")
        XCTAssertTrue(Self.jsonStyleUnicodeEscapes(in: #"Identity \U201CTeam\U201D"#).isEmpty,
                      "大写 \\U 是 `.strings` 的正写法，不该被报")
        XCTAssertTrue(Self.jsonStyleUnicodeEscapes(in: #"两行\n句与\"引号\"，还有真引号 “字”"#).isEmpty,
                      "合法转义与字面字符被误判 ⇒ 这条守卫会拦掉正常登记")
    }

    // MARK: - 守卫 1i（P59）：目录里**每一条键**都必须在运行时查得中
    /// 这条是 P59 被活界面抓出来之后立的。我往 `.strings` 追加了一批键，
    /// 注释行误用了 `#`（那是 python/shell 的记号，不是 `.strings` 的），
    /// 于是**运行时解析器从那一行起整段读不到**：
    /// `plutil -lint` 说 OK、按正则数键的四条守卫全绿、代码里也确实调了 `localizedFormat`，
    /// 而屏上还是中文 —— 只有"拿 App 用的那把解析器逐键查一遍"能看见。
    ///
    /// 所以这里不用正则、也不用 `plutil`，用的是 **`Bundle` 自己**：
    /// 与 `localizedCopy` 在运行时走的是同一个解析器，读不到就是读不到。
    /// 分母是**整本目录**，不是抽样：抽样会放过"从某一行起全废"这种形状。
    /// 目录里键是**带转义写法**存的（`"…\\n…"`），而 `Bundle` 读文件时会把 `\n` 还原成真换行。
    /// 本守卫的目录解析器是按正则取原文的（它不看转义），所以拿去查之前必须先还原，
    /// 否则十条"空态两行句"会被误报成"运行时查不到"——**两把尺子的差别必须显式桥接**，
    /// 不能靠"看起来一样"。
    static func runtimeForm(of key: String) -> String {
        var characters = key.makeIterator()
        var out = ""
        while let character = characters.next() {
            guard character == "\\", let next = characters.next() else { out.append(character); continue }
            switch next {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "\"": out.append("\"")
            case "\\": out.append("\\")
            default: out.append(character); out.append(next)
            }
        }
        return out
    }

    static func unresolvedCatalogKeys(_ entries: [(key: String, value: String)],
                                      in bundle: Bundle) -> [String] {
        entries.map(\.key).filter {
            bundle.localizedString(forKey: runtimeForm(of: $0), value: unresolvedSentinel, table: nil)
                == unresolvedSentinel
        }
    }

    private static let unresolvedSentinel = "\u{FFFF}"

    func test_everyCatalogKeyResolvesThroughTheRuntimeParser() throws {
        let entries = try Self.catalog()
        XCTAssertFalse(entries.isEmpty, "目录读空 ⇒ 这条判据在空转")
        let url = Self.packageRoot.appendingPathComponent("Resources/en.lproj")
        guard let bundle = Bundle(url: url) else {
            return XCTFail("打不开 \(url.path) ⇒ 英文资源不在原位，本条不能算通过（静默跳过等于关掉判据）")
        }
        let unresolved = Self.unresolvedCatalogKeys(entries, in: bundle)
        XCTAssertTrue(unresolved.isEmpty,
                      "这 \(unresolved.count) 条键写在目录里、运行时却查不到 ⇒ 英文态照旧铺中文，"
                    + "而按正则数键的守卫全绿。先看注释记号是不是 `//`（`#` 会让解析器从那一行起整段放弃）：\n  "
                    + unresolved.prefix(20).joined(separator: "\n  "))
        // 读数必须来自判据自己算的那个变量（这是本仓第四次抓到"打印写死好消息"）。
        print("【运行时逐键可查】整本目录 \(entries.count) 条 → 查不到 \(unresolved.count) 条（用的就是 App 那把 Bundle 解析器）")
    }

    /// 已知答案：一条不存在的键必须被判"查不到"，一条真键必须被判"查得到"。
    /// 没有这一半，上面那条绿只说明"bundle 是空的、而 filter 恰好没跑"。
    func test_meta_runtimeRulerCatchesABogusKeyAndSparesARealOne() throws {
        let url = Self.packageRoot.appendingPathComponent("Resources/en.lproj")
        guard let bundle = Bundle(url: url) else {
            return XCTFail("打不开 \(url.path) —— 元测试也需要真解析器")
        }
        let entries = try Self.catalog()
        XCTAssertFalse(entries.isEmpty, "目录读空 ⇒ 元测试没有对照")
        let real = entries[0].key
        XCTAssertEqual(Self.unresolvedCatalogKeys([(key: real, value: "x")], in: bundle), [],
                       "真键被判查不到 ⇒ 这把尺子在误报，上面那条绿不可信")
        XCTAssertEqual(Self.unresolvedCatalogKeys([(key: "这一条目录里绝对不存在 P59 元测试夹具", value: "x")], in: bundle).count, 1,
                       "假键没被抓到 ⇒ 上面那条绿只说明 filter 根本没在跑")
        // 转义桥接：目录里带 `\n` 的键，**不还原就查不到**（首版就是这么误报十条空态句的）。
        let escaped = entries.first { $0.key.contains("\\n") }
        XCTAssertNotNil(escaped, "目录里应当有带 \\n 的键（空态两行句），否则这条对照没有对象")
        if let escaped {
            XCTAssertEqual(Self.unresolvedCatalogKeys([escaped], in: bundle), [],
                           "还原转义之后仍查不到 ⇒ 要么这把尺子又偏了，要么那句空态文案真的白登记")
            XCTAssertFalse(Self.runtimeForm(of: escaped.key).contains("\\n"),
                           "runtimeForm 没把 \\n 换成真换行 ⇒ 桥接没生效")
        }
    }

    // MARK: - 守卫 1e：语言探针键不许消失

    /// `Theme.Layout.isChineseUI` 靠"查这条键回不回原词"判断界面语言。
    /// **这条键一旦不在目录里，探针就永远判成中文**，所有"英文态才生效"的
    /// 度量（定宽列宽等）会静默退回中文档 —— 而且守卫按英文预算量还是绿的。
    /// 今天就是这样翻过一次车：探针用了从未登记的 `"口径"`。
    func test_languageProbeKeyIsAlwaysRegistered() throws {
        let keys = Set(try Self.catalog().map(\.key))
        XCTAssertTrue(keys.contains(Theme.Layout.languageProbeKey),
                      "语言探针键 \"\(Theme.Layout.languageProbeKey)\" 不在英文目录里 ⇒ isChineseUI 会恒真")
        let english = try Self.catalog().first { $0.key == Theme.Layout.languageProbeKey }!.value
        XCTAssertNotEqual(english, Theme.Layout.languageProbeKey,
                          "探针键的译文等于键本身，同样会让 isChineseUI 恒真")
    }

}
