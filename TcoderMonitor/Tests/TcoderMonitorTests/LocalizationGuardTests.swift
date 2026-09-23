import XCTest
import Foundation
@testable import TcoderMonitor

/// 双语守卫（方案见 `docs/中英双语方案.md`）。
///
/// 三条都是**扫描型**守卫，所以每条都配了"注入坏样例必须红"的元测试 ——
/// 本项目已经吃过四次假绿（假零 / 永真绿 / 门控绿灯 / 共享盲区），
/// 一个数不出东西的扫描器比没有扫描器更危险：它会让人以为有人在管。
///
/// 机制前提（决定下面为什么这么查）：
/// - **本地化键 = 中文原文**。所以缺译文时 macOS 退回显示键本身 = 正确的中文，
///   界面上永远不会出现 `contributor.busfactor.high` 这种机器键。
/// - 源语言 `zh-Hans` 因此**不需要**目录文件（键就是它自己）；只有 `en.lproj` 存在。
///   于是"两语言键集相等"这种查法是错的，真正要查的是：
///   ① 已迁移的文件里不许再有没登记的中文串；② 登记了却不翻；③ 翻了但代码里已无此串。
final class LocalizationGuardTests: XCTestCase {

    // MARK: - 读盘

    static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/TcoderMonitorTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // TcoderMonitor
    }

    private static var englishCatalogPath: String {
        packageRoot.appendingPathComponent("Resources/en.lproj/Localizable.strings").path
    }

    /// 解析 `"键" = "值";`。
    ///
    /// 注释必须剥：目录文件里的说明文字大量带引号，不剥就会解析出假键。
    /// 曾经用"逐行状态机"剥块注释，结果**同行开合**的 `/* … */` 会把下一行
    /// 也当成注释吃掉 —— 于是 27 条键解析出 0 条，而"0 条"看起来像"目录是空的"。
    /// 现在直接按跨度删：先 `/* … */`（非贪婪、可跨行），再逐行删 `// …`。
    /// 已知局限：值里若真出现 `*/` 或 `//` 会被误剥 —— 本目录由我们自己写，
    /// 不放 URL；哪天要放，改的是这个解析器而不是放宽断言。
    static func parseCatalog(_ text: String) -> [(key: String, value: String)] {
        func dropping(_ pattern: String, from source: String, options: NSRegularExpression.Options) -> String {
            let re = try! NSRegularExpression(pattern: pattern, options: options)
            return re.stringByReplacingMatches(in: source, options: [],
                                               range: NSRange(source.startIndex..., in: source),
                                               withTemplate: "")
        }
        let stripped = dropping(#"/\*.*?\*/"#, from: text, options: [.dotMatchesLineSeparators])
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let comment = line.range(of: "//") else { return String(line) }
                return String(line[..<comment.lowerBound])
            }
            .joined(separator: "\n")

        let pattern = #"^\s*"((?:[^"\\]|\\.)+)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;"#
        let re = try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        let range = NSRange(stripped.startIndex..., in: stripped)
        var out: [(String, String)] = []
        for m in re.matches(in: stripped, options: [], range: range) {
            guard let kr = Range(m.range(at: 1), in: stripped),
                  let vr = Range(m.range(at: 2), in: stripped) else { continue }
            out.append((String(stripped[kr]), String(stripped[vr])))
        }
        return out
    }

    static func catalog() throws -> [(key: String, value: String)] {
        let text = try String(contentsOfFile: englishCatalogPath, encoding: .utf8)
        let entries = parseCatalog(text)
        // 反向自证：目录读不出任何键 = 解析器坏了，而不是"这个包不需要翻译"。
        XCTAssertFalse(entries.isEmpty, "英文目录解析出 0 条 —— 解析器或路径坏了")
        return entries
    }


    /// 含 CJK 的界面串字面量，返回「文件: 串」。**剥掉整行注释**。
    ///
    /// 三类入口都算，少扫一类就会出现"守卫绿了、界面还是中文"的假完成：
    /// ① **视图入口**（`Text` / `Button` / `GlassButton` / `Label` / `Menu` /
    ///    `Toggle` / `TextField` / `Picker` / `NavigationLink` / `LabeledContent`）
    ///    —— 它们的 `LocalizedStringKey` 会自动查表，缺译文就退回显示中文；
    /// ② **修饰符**（`.help` / `.accessibilityLabel` / `.navigationTitle`）——
    ///    tooltip 与 VoiceOver 也是界面；
    /// ③ **字符串型文案参数与本仓三个查表口子**（`label:` / `caption:` / …
    ///    与 `localizedCopy` / `localizedFormat` / `localizedCount`）——
    ///    这些是 `String`，**只有登记成键才会被翻译**，漏一条英文态就原样吐中文。
    ///
    /// ICU 正则**不认** Swift 的 `\u{4E00}` 写法，只认 `\u4E00`；写成前者时
    /// `try?` 会把编译失败吞成 nil、函数返回 [:]，于是"没有未迁移的串"是假的。
    /// 所以这里一律 `try!`：正则坏了就该炸，不许静默通过。
    static func uiLiteralsNeedingKeys(in files: [(path: String, content: String)]) -> [String: Set<String>] {
        // 三段入口前缀 + 一个公共的"含汉字的双引号字面量"尾巴。
        // 拼字符串而不是写多行字面量：`"""` 里的行尾 `\` 续行会在行尾空格上翻车，
        // 而正则里多出来的一个空格会让整条模式静默不匹配（= 永真绿）。
        let entryPoints = "(?:Text|Button|GlassButton|Label|Menu|Toggle|TextField|Picker"
            + "|NavigationLink|LabeledContent|CopyHelpBadge)\\(\\s*(?:verbatim:\\s*)?"
        let modifiers = "\\.(?:help|accessibilityLabel|navigationTitle)\\(\\s*"
        let lookups = "(?:localizedCopy|localizedFormat|localizedCount)\\(\\s*"
        // `help` / `subtitleHelp` / `captionHelp` 是**本轮「留短藏长」的落点**：
        // 这些组件内部替调用方过了 `localizedCopy`，所以调用点那个中文字面量就是键。
        // 少了这三个标签，全站的 ⓘ 解释句会整片躲开双语棘轮 —— 英文态漏出中文而守卫一片绿。
        let stringParams = "(?:label|caption|text|title|subtitle|unit|message|note|placeholder"
            + "|emptyNote|iconLabel|help|subtitleHelp|captionHelp)\\s*:\\s*"
        let pattern = "(?:" + entryPoints + "|" + modifiers + "|" + lookups + "|" + stringParams + ")"
            + "\"((?:[^\"\\\\]|\\\\.)*[\\u4E00-\\u9FFF](?:[^\"\\\\]|\\\\.)*)\""
        let re = try! NSRegularExpression(pattern: pattern, options: [])
        var out: [String: Set<String>] = [:]
        for file in files {
            for line in file.content.split(separator: "\n", omittingEmptySubsequences: false) {
                let l = String(line)
                if l.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                // `@available(*, deprecated, message: "改用 …")` 是**讲给维护者听的话**，
                // 不进界面也不该翻译。`message:` 这个参数标签两边同名，
                // 只能按"整行是不是 @available"来分 —— 否则 15 条编译器提示
                // 会被算成双语债（守卫扫到"讲代码的话"是本项目吃过六次的老坑）。
                if l.contains("@available(") { continue }
                let range = NSRange(l.startIndex..., in: l)
                for m in re.matches(in: l, options: [], range: range) {
                    guard let r = Range(m.range(at: 1), in: l) else { continue }
                    out[file.path, default: []].insert(String(l[r]))
                }
            }
        }
        return out
    }

    static func sourceFiles() throws -> [(path: String, content: String)] {
        // **动态枚举整个 `Sources/TcoderMonitor`**，不再写死目录名：写死的清单只会数
        // "想到名字的那几个"（`Utilities/` 就一直没进来）。动态枚举之后只有一条元测试
        // 兜住反向风险 —— 见 `test_meta_scanSurfaceCoversEveryTopLevelDirectory`。
        // 五个目录时代的教训仍然成立：**Services/ 与 Models/ 会产出喂给界面的整句**
        // （健康页那句"综合 76 分（B 级）…"就住在 `Services/Health/ScoreCurves.swift`）。
        let out = try SurfaceScanKit.sourceFiles(under: "")
        XCTAssertGreaterThanOrEqual(out.count, 40, "扫到的界面文件只有 \(out.count) 个，分母不对")
        return out
    }

    static func walkFiles(in dir: String) -> [String] {
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: dir) else { return [] }
        return en.compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") }
            .map { "\(dir)/\($0)" }
    }

    // MARK: - 守卫 1：已迁移的文件不许再有未登记的中文串

    /// **已完成迁移的文件清单。只许变长，不许变短。**
    ///
    /// 为什么用"完工清单"而不是"全局未迁移计数棘轮"：一个 26 的基线数字会随
    /// 任何人加一句中文而涨，涨了就"合法"，等于没有闸门；而"某个文件已经干净"
    /// 是一个可复核的事实，退回去就会立刻红。
    private static let migratedFiles: Set<String> = [
        "Views/Shell/ProjectSidebar.swift",
        "App/TcoderMonitorApp.swift",
        "Views/Shell/DashboardHero.swift",
    ]

    func test_migratedFilesHaveNoUnregisteredUILiterals() throws {
        guard !Self.migratedFiles.isEmpty else { return }   // 清单为空时不假装有结论
        let registered = Set(try Self.catalog().map(\.key))
        let literals = Self.uiLiteralsNeedingKeys(in: try Self.sourceFiles()
            .filter { Self.migratedFiles.contains($0.path) })
        let offenders = literals.flatMap { path, strings in
            strings.filter { !registered.contains($0) }.map { "\(path) → \"\($0)\"" }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "这些文件在已迁移清单里，却出现没登记的界面中文串：\n\(offenders.sorted().joined(separator: "\n"))")
    }

    // MARK: - 守卫 1b：全量存量棘轮（报告 + 只减不增）

    /// 已登记文件清单是"点"闸门，这条是"面"闸门：把 Views/Design/App 全扫一遍，
    /// 报出还没登记的界面串总数。
    ///
    /// **每次跑都打印现量/上限** —— 只减不增的棘轮通过时若不报现量，
    /// 已还的债就变成隐形余量（新增 N 处照样绿）。上限的取值必须是**某次实扫的现量**，
    /// 不许拍脑袋；调低它 = 还了债，调高它 = 新增债，两者都要在 diff 里显形。
    /// 2026-09-21 实扫登记：首测 **264 条**（扫到 369 条界面串 / 目录 112 条键），
    /// 同日七批迁移后收到 **28 条**（已登记键 388）。
    /// 数字从 22 涨回 28 **不是新增债**，是把扫描面从 Views/Design/App 扩到
    /// Services/Models（英文实拍证伪：页头出英文、同页叙述仍中文）后**多看见的 6 条**。
    /// 剩下的集中在
    /// `CodeRiskAdvice` 的多段建议长句（4~6 个占位符，改成整句键要逐句重写）
    /// 与 `ShellLayout` 的三句组合式空态 —— 它们是**已知账**，不是"没扫到"。
    /// 这个数字是"面"闸门第一次跑出来的存量，不是估的 ——
    /// 只按 `Text("中文")` 扫会得到 43 条，漏掉的 221 条住在 tooltip、
    /// `label:` / `caption:` 这类字符串型参数与 `localizedCopy` 口子里。
    ///
    /// **2026-09-21 一天之内动了两次数字：19 → 21 → 19**，两次都是实扫现量、方向由守卫自己打印：
    /// 扩口 + S5 搬字让存量涨 2（新增债显形），补账轮把两处 `Text(变量)` 改成查表又降 2。
    /// 剩下的 19 条**全部是内插短句**，逐条台账与还法见计划文档 §6（本文件从 399 行让 1 行给这条）。
    ///
    /// **2026-09-24 P69a：19 → 11 → 4**。11 是 P69 合进 main 后的实扫现量，4 是本批清掉
    /// 「代码风险这一片」7 条之后守卫自己打印的那一行（逐条清单同一趟落盘核对）。
    /// 7 条全改成**整句键 + 在产出处查表**：5 条 `localizedFormat`（一句两槽以上）、
    /// 1 条 `localizedCount` + `.stringsdict`（`%lld 个条目`）、1 条 `describe(unit:)` 的量词整句化。
    /// 剩的 4 条不在本流名下（`CodeViewSupport` 1 / `Views/Git/` 3）。
    /// ⚠ 「countable 名词 + 别的槽挤在同一句」这一族改成整句键之后**英语单复数仍然表达不了**
    /// （`localizedCount` 只收一个 `Int`）⇒ 整句键是"能上屏"，不是"已收口"，缺口见双语台账交回汇报。
    private static let unregisteredLiteralCeiling = 4

    func test_unregisteredLiteralInventoryPrintsAndShrinks() throws {
        let registered = Set(try Self.catalog().map(\.key)).union(Self.registeredStringsDictKeys())
        let literals = Self.uiLiteralsNeedingKeys(in: try Self.sourceFiles())
        XCTAssertFalse(literals.isEmpty, "一条界面串都没扫到 —— 扫描器或分母坏了")
        let offenders = literals.flatMap { path, strings in
            strings.filter { !registered.contains($0) }.map { "\(path) → \"\($0)\"" }
        }
        print("双语存量棘轮：现量 \(offenders.count) / 上限 \(Self.unregisteredLiteralCeiling)"
              + "（扫到串 \(literals.values.reduce(0) { $0 + $1.count }) 条 / 已登记键 \(registered.count) 条）")
        // 清单落盘（报告器，不是闸门）：闸门无条件跑，这份文件只给"下一步该翻谁"用。
        // 没有它，264 这个数字只是一句无法核对的口号。
        if let target = ProcessInfo.processInfo.environment["TCODER_I18N_LEDGER"], !target.isEmpty {
            try? offenders.sorted().joined(separator: "\n").write(toFile: target,
                                                                  atomically: true, encoding: .utf8)
            print("  清单已落盘 \(target)（\(offenders.count) 行）")
        }
        XCTAssertLessThanOrEqual(offenders.count, Self.unregisteredLiteralCeiling,
                                 "未登记界面串比上限还多 —— 新增双语债，见下面清单\n"
                                 + offenders.sorted().prefix(40).joined(separator: "\n"))
    }

    // MARK: - 守卫 1d：目录键必须唯一

    /// 同一个键写两条 = **后一条悄悄覆盖前一条**（`NSDictionary` 语义），
    /// 而且两条译文可以互相矛盾。这条是新的英文宽度审计**当场撞出来的**：
    /// `"%@ 秒"` 在 P3-5 与 P5-c8 各登记过一次，`Dictionary(uniqueKeysWithValues:)`
    /// 直接 fatal error，才让人看见目录里有重复。
    /// 判据按"解析出的键序列"数重复，不按文件行号 —— 换行/注释都不该影响结论。
    func test_catalogHasNoDuplicateKeys() throws {
        let keys = try Self.catalog().map(\.key)
        var seen = Set<String>(), dupes = Set<String>()
        for key in keys where !seen.insert(key).inserted { dupes.insert(key) }
        XCTAssertTrue(dupes.isEmpty,
                      "英文目录里这些键登记了不止一次（后一条会静默覆盖前一条）：\(dupes.sorted())")
    }

    // MARK: - 守卫 2：登记了就必须翻（值不等于键）

    /// 允许"值 = 键"的例外。**每条都要写理由**，否则白名单就是遮羞布。
    private static let identicalValueAllowlist: Set<String> = []

    func test_everyRegisteredKeyHasAnEnglishValue() throws {
        let entries = try Self.catalog()
        let untranslated = entries.filter { $0.value == $0.key }
            .map(\.key).filter { !Self.identicalValueAllowlist.contains($0) }
        XCTAssertTrue(untranslated.isEmpty,
                      "这些键登记了却没有译文（英文态会退回中文）：\(untranslated)")
        let empty = entries.filter { $0.value.isEmpty }.map(\.key)
        XCTAssertTrue(empty.isEmpty, "这些键的译文是空串：\(empty)")
    }

    // MARK: - 守卫 3：译文不许烂尾（键必须在代码里真实出现）

    /// 键必须作为**完整的字符串字面量**出现在源码里。
    ///
    /// 原来用 `allSource.contains(key)`，于是**长键的前缀**会被当成"还活着"：
    /// P3-4 把 `"口径：报告只有汇总粒度，未区分测试代码 · 来源 "` 这个碎片键换成整句键
    /// `"口径：报告只有汇总粒度，未区分测试代码 · 来源 %1$@"` 之后，碎片键其实已经没人用了，
    ///  substring 判据却照样放行 —— 正是守卫 3 要抓的"改了原文没同步目录"。
    static func staleKeys(keys: [String], source: String) -> [String] {
        keys.filter { !source.contains("\"" + $0 + "\"") }
    }

    func test_noStaleKeysInCatalog() throws {
        let entries = try Self.catalog()
        let allSource = try Self.walkFiles(in: Self.packageRoot.appendingPathComponent("Sources/TcoderMonitor").path)
            .reduce("") { $0 + ((try? String(contentsOfFile: $1, encoding: .utf8)) ?? "") }
        let stale = Self.staleKeys(keys: entries.map(\.key), source: allSource)
        XCTAssertTrue(stale.isEmpty,
                      "目录里有 \(stale.count) 条代码中已不存在的键（改了原文没同步目录）：\(stale)")
    }

    func test_staleKeyScannerRejectsPrefixOnlyMatches() {
        let source = ##"Text(localizedFormat("口径 · 来源 %1$@", x))"## 
        // 碎片键只作为长键的前缀出现 → 必须判成烂尾
        XCTAssertEqual(Self.staleKeys(keys: ["口径 · 来源"], source: source), ["口径 · 来源"])
        // 完整字面量在场 → 放行
        XCTAssertTrue(Self.staleKeys(keys: ["口径 · 来源 %1$@"], source: source).isEmpty)
    }

    // MARK: - 守卫 4：键值两端的格式占位符必须一致

    /// 抽出串里的**格式占位符**（`%@` / `%d` / `%lld` / `%f` / `%%` …）。
    /// 裸 `%`（后面不跟转换字符）**不算占位符** —— 这样「95% 的提交…」这类中文键
    /// 今天就能过，而翻译时把 `%@` 翻丢、写错顺序、多写一个都会被抓到。
    static func formatSpecs(in text: String) -> [String] {
        let re = try! NSRegularExpression(pattern: #"%%|%[0-9]*[$]?[@a-zA-Z]{1,3}"#, options: [])
        let range = NSRange(text.startIndex..., in: text)
        return re.matches(in: text, options: [], range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    func test_catalogPlaceholdersMatch() throws {
        let offenders = try Self.catalog().compactMap { entry -> String? in
            let k = Self.formatSpecs(in: entry.key), v = Self.formatSpecs(in: entry.value)
            return k == v ? nil : "\(entry.key) → 键 \(k) / 值 \(v)"
        }
        XCTAssertTrue(offenders.isEmpty,
                      "译文里的格式占位符与原文不一致（会静默改义或崩）：\(offenders)")
    }

    /// 元测试：占位符比对必须真能抓错，且**不把裸百分号当占位符误伤**。
    func test_placeholderScannerDetectsMismatchButIgnoresBarePercent() {
        XCTAssertEqual(Self.formatSpecs(in: "共 %@ 次，占 %lld%%"), ["%@", "%lld", "%%"])
        XCTAssertTrue(Self.formatSpecs(in: "95% 的提交由一人完成").isEmpty,
                      "裸 % 被当成占位符 —— 会把所有含百分号的中文键误判")
    }

    // MARK: - 元测试：三条守卫各自的扫描器必须真能抓到坏样例

    func test_scannersDetectInjectedViolations() {
        // 守卫 1 的扫描器：未登记的中文串要能被抓到，注释里的不能算。
        let dirty = [(path: "Views/Fake.swift",
                      content: "  Text(\"尚未翻译的句子\")\n// Text(\"注释里的\")\n")]
        XCTAssertEqual(Self.uiLiteralsNeedingKeys(in: dirty)["Views/Fake.swift"],
                       ["尚未翻译的句子"], "界面串扫描器失灵或没剥注释")
        // 只扫 Text、不扫按钮 = "守卫绿了、按钮还是中文"的假完成
        let buttons = [(path: "Views/Fake.swift",
                        content: ##"  GlassButton("添加项目", icon: .add)"## + "\n"
                            + ##"  Button("移除", role: .destructive) {}"## + "\n")]
        XCTAssertEqual(Self.uiLiteralsNeedingKeys(in: buttons)["Views/Fake.swift"]?.count, 2,
                       "按钮标题没被算进界面串")
        // ② 修饰符与 ③ 字符串型参数/查表口子：漏一类就是"守卫绿了、界面还是中文"
        let broad = [(path: "Views/Fake.swift", content:
                        #"    .help("切换排序口径；两种都是全系统范围")"# + "\n"
                      + #"    MetricTile(label: "累计变更", caption: "按非合并提交统计")"# + "\n"
                      + #"    Text(localizedCopy("尚未分析Git 历史"))"# + "\n"
                      + #"    TextField("分组名称，例如「后端服务」", text: $title)"# + "\n")]
        let found = Self.uiLiteralsNeedingKeys(in: broad)["Views/Fake.swift"] ?? []
        XCTAssertEqual(Set(found), ["切换排序口径；两种都是全系统范围", "累计变更",
                                    "按非合并提交统计", "尚未分析Git 历史", "分组名称，例如「后端服务」"],
                       "tooltip / label / caption / localizedCopy / TextField 里有没被算进来的：\(found.sorted())")
        // 反向：纯代码括号与英文串不得被算进来（误判会逼人写绕路代码）
        let legal = [(path: "Views/Fake.swift", content:
                         #"    Text(verbatim: name)"# + "\n" + #"    let width = Text("ok")"# + "\n")]
        XCTAssertTrue(Self.uiLiteralsNeedingKeys(in: legal).isEmpty,
                      "无汉字的写法被误判：\(Self.uiLiteralsNeedingKeys(in: legal))")

        // 守卫 2/3 的目录解析器：能读键值、能剥块注释与行注释。
        let parsed = Self.parseCatalog("""
        /* 说明里有 "假键" = "假值"; 一行 */
        "真键" = "Real";
        "另一键" = "Second";   // 行尾注释 "噪声" = "噪声值"
        """)
        XCTAssertEqual(parsed.count, 2,
                       "目录解析器数错了条数（\(parsed.map(\.key))）—— 注释没剥干净")
        XCTAssertEqual(parsed.map(\.key), ["真键", "另一键"])
        XCTAssertEqual(parsed.map(\.value), ["Real", "Second"])
        // 空值必须能被数出来（守卫 2 依赖它）
        XCTAssertEqual(Self.parseCatalog("\"k\" = \"\";").first?.value, "")
    }

    // MARK: - 守卫 6：整句键不许改坏中文侧

    /// 相对时间改成「整句键 + `%lld`」之后，**中文侧必须逐字不变**：
    /// 多一个空格、少一个「前」字，九页上几十处「分析于 X 前」就全变了样，
    /// 而这类改动不会让任何一条既有测试变红。
    /// 英文侧的单复数走 `stringsdict`，测试进程里没有语言目录、查不到值，
    /// 只能靠 `-AppleLanguages "(en)"` 的实拍取证（方案 §10.6）。
    func testRelativeTimeChineseSideIsUnchanged() {
        let now = Date()
        func ago(_ seconds: Int) -> String {
            LogRecency.describe(now.addingTimeInterval(-Double(seconds)))
        }
        XCTAssertEqual(ago(5), "5 秒前")
        XCTAssertEqual(ago(55), "55 秒前")
        XCTAssertEqual(ago(120), "2 分钟前")
        XCTAssertEqual(ago(7_200), "2 小时前")
        XCTAssertEqual(ago(86_400 + 600), "昨天")
        XCTAssertEqual(ago(3 * 86_400 + 600), "3 天前")
        XCTAssertEqual(ago(61 * 86_400 + 600), "2 个月前")
        XCTAssertEqual(ago(400 * 86_400 + 600), "1 年前")
        XCTAssertEqual(LogRecency.describe(nil), "未知")
        XCTAssertEqual(ago(-30), "即将")
    }

    /// `LogRecency.split` 是**语言无关**的：它切的是"已经本地化完的那一句"，
    /// 所以中文与英文都必须切成「数字 / 其余」。
    /// 英文侧尤其要紧 —— 词序反过来（"49 seconds ago"），任何按中文词表写的
    /// 拆分逻辑都会在这里失效。
    func test_recencySplitKeepsNumberAndUnitApartInBothLanguages() {
        XCTAssertEqual(LogRecency.split("49 秒前").value, "49")
        XCTAssertEqual(LogRecency.split("49 秒前").unit, "秒前")
        XCTAssertEqual(LogRecency.split("2 小时前").unit, "小时前")
        XCTAssertEqual(LogRecency.split("1,234 天前").value, "1,234")
        // 英文：整句回来的是 "49 seconds ago"，单位段必须连着吃下 "seconds ago"
        XCTAssertEqual(LogRecency.split("49 seconds ago").value, "49")
        XCTAssertEqual(LogRecency.split("49 seconds ago").unit, "seconds ago")
        XCTAssertEqual(LogRecency.split("2 hours ago").unit, "hours ago")
        // 三态没有数字，就不该硬造单位（否则 value 会变成空串）
        for phrase in ["昨天", "未知", "即将", "Yesterday"] {
            XCTAssertEqual(LogRecency.split(phrase).value, phrase, "\(phrase) 被拆坏了")
            XCTAssertNil(LogRecency.split(phrase).unit, "\(phrase) 凭空多出一段单位")
        }
    }


}


