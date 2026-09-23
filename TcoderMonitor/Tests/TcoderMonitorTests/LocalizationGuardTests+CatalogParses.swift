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

    // MARK: - 批次 P69b（WS-Git / 健康页）：那 5 条存量收口之后要能自己站住
    //
    // 四条各管一个"绿了不代表修好了"的洞：
    //   ① 键登记了，但**英文 bundle 里查不到**（P59 那个 `#` 注释炸的就是这一类）；
    //   ② 键查得到，但**没有人在产出处查它**（`Text(变量)` 不查表 ⇒ 白登记）；
    //   ③ 改成了查表，但**把中文态改坏了**（多一个空格、少一个字，既有守卫一条都不红）；
    //   ④ 本批还过债的文件**长回插值中文串**（1b 那条全量棘轮只许降，涨回去才看得见，
    //      但它按"入口白名单"扫 —— 三个文件里别的形状的残留它不点名，这里按文件钉死）。
    // ①② 与 P69 那两条同族，③ 与守卫 6「整句键不许改坏中文侧」同族。

    /// P69b 新登记的 4 条 `.strings` 键（第 5 条复用已在 `stringsdict` 里的量词键 `%lld 天`）。
    static let p69bKeys: [String] = [
        "分析的是另一个仓库：%1$@\n%2$@",
        "当前只分析了提交数最多的那一个",
        "Git 分析没有产出按时间分桶的提交数据。",
        "未找到仓库",
        "历史末点 %1$@ 与本次 %2$@ 不一致。",
    ]

    private static let p69bSentinel = "\u{FFFE}"

    /// ① 每条键都必须**在真英文 bundle 上**查得到；带实参的两条填完必须是英文。
    /// 反向自证：一条夹具假键必须判"查不到" —— 否则上面那张空清单是尺子失灵。
    func test_p69bKeysResolveThroughTheRealEnglishBundle() throws {
        let en = LocalizationGuardTests.packageRoot.appendingPathComponent("Resources/en.lproj")
        guard let enBundle = Bundle(url: en) else {
            return XCTFail("打不开 \(en.path) —— 英文资源不在原位，本条不能算通过")
        }
        let unresolved = Self.unresolvedCatalogKeys(Self.p69bKeys.map { (key: $0, value: "") },
                                                   in: enBundle)
        XCTAssertEqual(unresolved, [], "这些键写在目录里、运行时查不到 ⇒ 英文态照旧铺中文")
        XCTAssertEqual(Self.unresolvedCatalogKeys(
            [(key: "P69b 夹具：这条键绝不存在 %1$@", value: "")], in: enBundle).count, 1,
            "假键没被判成查不到 ⇒ 上面那条空清单不可信")

        // 外壳句：两个位置参数的**顺序**必须是「路径、定位说法」。填反了一样的绿
        // （占位符比对只看数量与类型），但英文态会读成"另一个仓库：所选目录即仓库 / 路径"。
        let relocated = Self.p69bKeys[0]
        let relocatedValue = enBundle.localizedString(forKey: relocated,
                                                      value: Self.p69bSentinel, table: nil)
        XCTAssertFalse(relocatedValue.contains(Self.p69bSentinel), "\(relocated) 查不到")
        XCTAssertEqual(String(format: relocatedValue, "/repo/path", "The folder is the repository"),
                       "Analysing a different repository: /repo/path\nThe folder is the repository",
                       "外壳句的位置参数形状与本批写法不一致（改了译文形状要同批复核这条）")
        // 评分不一致那句：两个分数不是可数名词 ⇒ 必须是 `.strings` 单数键，
        // 不许被塞进 `stringsdict` 硬凑单复数。
        let mismatchKey = "历史末点 %1$@ 与本次 %2$@ 不一致。"
        let mismatchValue = enBundle.localizedString(forKey: mismatchKey,
                                                     value: Self.p69bSentinel, table: nil)
        XCTAssertFalse(mismatchValue.contains(Self.p69bSentinel), "\(mismatchKey) 查不到")
        // 两侧占位符必须同形（与守卫 4 同一把尺子，不另造一份）。
        XCTAssertEqual(LocalizationGuardTests.formatSpecs(in: mismatchValue), ["%1$@", "%2$@"],
                       "这条键与它的英文译文占位符不同形 ⇒ 填参会静默改义：\(mismatchValue)")
        XCTAssertTrue(Self.cjkResidue(in: mismatchValue).isEmpty,
                      "英文译文里残留中日韩字符 ⇒ 这一格半英半中：\(mismatchValue)")
    }

    /// ② 每条键都必须真的出现在**产出处**（源码里的字面量）。登记了没人查 = 没修。
    ///
    /// ⚠ 两把尺子的转义差别必须显式桥接（守卫 1i 的同一条教训）：目录解析器按正则
    /// 取的是**原文**，所以 `.strings` 里的键写着 `\n` 两个字符；而 Swift 源码里那条
    /// 整句键也是 `\n` 两个字符 —— 本测试数组里写的却是**真换行**（运行时形状）。
    /// 不桥接就会把一条活键报成"没人查"。
    func test_p69bKeysAreLookedUpAtTheirProducers() throws {
        let bodies = try SurfaceScanKit.sourceFiles(under: "").map(\.content)
            .reduce("") { $0 + $1 }
        let sourceForm = Self.p69bKeys.map { $0.replacingOccurrences(of: "\n", with: "\\n") }
        XCTAssertEqual(Self.unusedPluralKeys(sourceForm, in: bodies), [],
                       "这些整句键登记了却没有任何调用点 ⇒ 屏上仍是拼出来的中文")
        XCTAssertFalse(Self.unusedPluralKeys(["P69b 夹具：这条键绝不存在 %1$@"], in: bodies).isEmpty,
                       "假键没被抓到 ⇒ 上面那条空清单不可信")
        // 桥接本身也要有牙：不桥接就拿真换行去搜原文，必然报"没人查"（假红）。
        XCTAssertFalse(Self.unusedPluralKeys(Self.p69bKeys, in: bodies).isEmpty,
                       "带 \\n 的键不桥接居然也搜得到 ⇒ 这条桥接是多余的，删掉它")
    }

    /// ③ 中文态逐字不变。测试宿主里 `Bundle.main` 没有 `en.lproj` ⇒ `localizedCopy`
    /// 恒退回键本身 = 中文，所以这里量到的就是**中文用户实际看到的那一串**，
    /// 而且走的是**真生产者**（不是在测试里重抄一遍表达式）。
    func test_p69bKeystayByteIdenticalInTheChineseState() {
        for (mode, hops, expected) in [
            (GitDiscoveryMode.selectedDirectory, 0, "所选目录即仓库"),
            (.parentDirectory, 2, "向上 2 层找到"),
            (.nestedSubdirectory, 12, "向下 12 层找到"),
            (.none, 0, "未找到仓库"),
        ] {
            let git = GitInsights(resolvedRepositoryRoot: "/tmp/repo",
                                  discoveryMode: mode, discoveryHops: hops)
            XCTAssertEqual(GitRepositorySourceSection.relocatedNotice(git: git, root: "/tmp/repo"),
                           "分析的是另一个仓库：/tmp/repo\n\(expected)",
                           "偏离提示的中文态被改坏了（mode \(mode)）")
        }
        XCTAssertEqual(HealthTrendCard.spanCaption(0), "0 天")
        XCTAssertEqual(HealthTrendCard.spanCaption(45), "45 天")
        XCTAssertEqual(HealthTrendCard.spanCaption(1_234), "1,234 天",
                       "量词改走 localizedCount 之后千分位必须仍在（与全站大读数同一把记法）")
        XCTAssertEqual(HealthTrendCard.scoreMismatchNote(last: 76, current: 78),
                       "历史末点 76 与本次 78 不一致。")
    }

    /// ④ 本批**真拆掉的三种形状**不许长回来（逐条留名，不是一片文件配额）。
    ///
    /// 为什么不写成"这三个文件里插值中文串必须为 0"（守卫 1g 那种名单制）：
    /// 同三个文件里还留着**没派给我**的 4 处（`discoveryCaption` 的「向上 / 向下 N 层找到」
    /// 两态要英语单复数、`GitNestedCandidatesSection` 卡名「所选目录下发现 N 个仓库」、
    /// `GitInsightsView` 的「始于 …」），按文件收口就等于替别人的账签字，
    /// 也等于把这条判据写成一条此刻根本红的东西。名单制留给真正清干净的那一天。
    static let p69bRetiredShapes: [(file: String, literal: String)] = [
        ("Views/Git/GitInsightsSections.swift",
         #"DataNotice(text: "分析的是另一个仓库：\(root)\n\(Self.discoveryCaption(git))""#),
        ("Views/Health/HealthAdviceCards.swift",
         #"Theme.Readout.Field("跨度", "\(NumberFormat.grouped(spanDays)) 天")"#),
        ("Views/Health/HealthAdviceCards.swift",
         #"NoteLine("历史末点 \(last.score) 与本次 \(score) 不一致。""#),
    ]

    /// 判据体：某个文件里是否还写着这条旧形状（原样子串，不按行猜）。
    static func retiredShapesStillWritten(_ retired: [(file: String, literal: String)],
                                          in scanned: [String: String]) -> [String] {
        retired.compactMap { item in
            guard let content = scanned[item.file] else { return "\(item.file) 不在扫描面上" }
            return content.contains(item.literal) ? "\(item.file) 又写回了 \(item.literal)" : nil
        }
    }

    func test_p69bRetiredShapesDoNotComeBack() throws {
        let scanned = Dictionary(uniqueKeysWithValues:
            try SurfaceScanKit.sourceFiles(under: "").map { ($0.path, $0.content) })
        let offenders = Self.retiredShapesStillWritten(Self.p69bRetiredShapes, in: scanned)
        XCTAssertTrue(offenders.isEmpty,
                      "这些形状先拼成串再上屏，拼完那一整串永远查不中 ⇒ 英文态整行中文：\n  "
                        + offenders.joined(separator: "\n  "))
    }

    /// 元测试（④ 的双向）：已知坏样例必须抓得到、已知合法写法一条不许误伤。
    /// 少了这半边，上面那条绿只可能意味着"文件路径对不上、所以什么都没扫到"。
    func test_meta_p69bRetiredShapeRulerBitesBothWays() {
        let keyized = [#"DataNotice(text: localizedFormat("分析的是另一个仓库：%1$@\n%2$@", a, b))"#,
                       #"Theme.Readout.Field("跨度", localizedCount("%lld 天", days))"#,
                       #"NoteLine(localizedFormat("历史末点 %1$@ 与本次 %2$@ 不一致。", x, y))"#]
        // 反向：把三个落点换成**成熟写法**，同一份"要禁的旧形状"清单必须一条都不报。
        // （首版我在这里把"要找的旧形状"错传成了成熟写法本身 ⇒ 自己找自己、必然报，
        //   记下来是为了让下一个人在这里少踩一次。）
        XCTAssertTrue(Self.retiredShapesStillWritten(
            Self.p69bRetiredShapes,
            in: ["Views/Git/GitInsightsSections.swift": keyized[0],
                 "Views/Health/HealthAdviceCards.swift": keyized[1] + "\n" + keyized[2]]).isEmpty,
            "整句键 + 位置参数的成熟写法被误报 ⇒ 下次没人信这条")
        // 正向：把三条旧形状原样塞回去，必须逐条抓到（分母 3，不许只抓到一部分）。
        XCTAssertEqual(Self.retiredShapesStillWritten(
            Self.p69bRetiredShapes,
            in: ["Views/Git/GitInsightsSections.swift": Self.p69bRetiredShapes[0].literal,
                 "Views/Health/HealthAdviceCards.swift":
                     Self.p69bRetiredShapes[1].literal + "\n" + Self.p69bRetiredShapes[2].literal]
        ).count, 3, "旧形状漏抓 ⇒ 这条判据拦不住回退")
        // 文件不在扫描面上要单独出声（不能和"没抓到"混成同一个空清单）。
        XCTAssertEqual(Self.retiredShapesStillWritten(
            [(file: "Views/Nowhere/Gone.swift", literal: "x")], in: [:]).count, 1,
            "文件消失被当成通过 ⇒ 改名/挪走就能悄悄关掉判据")
    }

    // MARK: - 批次 P70：清单分隔符也不许写死成顿号

    /// 与 `endingSentence` 同族：`、` 是 U+3001（中日韩标点段），写死在 `joined(separator:)` 里
    /// 就会长成 `Swift、Homebrew、Ruby`。它**不在任何一条键上** ⇒ 按目录查的守卫全绿，
    /// 只有按码点量残留的那把尺子看得见 —— 所以这条必须钉在**源码形状**上。
    func test_sourcesNeverJoinListsWithTheIdeographicComma() throws {
        let files = try SurfaceScanKit.sourceFiles(under: "")
        XCTAssertFalse(files.isEmpty, "一个源码文件都没扫到 ⇒ 这条判据在空转")
        let offenders = Self.ideographicCommaJoins(in: files.map { ($0.path, $0.content) })
        XCTAssertTrue(offenders.isEmpty,
                      "这 \(offenders.count) 处把清单分隔符写死成顿号 ⇒ 英文态句中会长出中日韩标点，"
                    + "改用 localizedListSeparator()：\n  " + offenders.joined(separator: "\n  "))
    }

    /// 纯函数（元测试在内存里造坏样例，不往仓库塞临时夹具）。返回命中文件的路径。
    static func ideographicCommaJoins(in files: [(path: String, content: String)]) -> [String] {
        files.filter { $0.content.contains("joined(separator: \"、\")") }.map(\.path)
    }

    func test_meta_ideographicCommaRulerCatchesTheOldShapeAndSparesTheNew() {
        XCTAssertEqual(Self.ideographicCommaJoins(in: [
            (path: "a", content: #"names.joined(separator: "、")"#),
            (path: "b", content: #"names.joined(separator: localizedListSeparator())"#),
            (path: "c", content: #"names.joined(separator: ", ")"#),
        ]), ["a"], "坏形状没被抓到 / 合法写法被误判 ⇒ 上面那条绿不可信")
    }

    /// 两个分支都要咬得住：测试宿主里探针恒判中文，英文那一支靠入参驱动。
    func test_listSeparatorFollowsTheActiveLanguage() {
        XCTAssertEqual(localizedListSeparator(chinese: true), "、")
        XCTAssertEqual(localizedListSeparator(chinese: false), ", ",
                       "英文清单用顿号 ⇒ 十八趟读数按码点判它残留中文")
    }
}
