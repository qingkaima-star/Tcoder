import Foundation
import XCTest
@testable import TcoderMonitor

// MARK: - 批次 P69c（WS-多槽复数流）：一句话里两个复数槽
//
// OWNER: WS-多槽复数流。这一族的入口住在 `Design/LocalizedCopyKit.swift`
// （`localizedCount(_:slots:)` 与 `localizedCount(_:count:note:)`）。
//
// 为什么单独成文件而不是留在 `+CatalogParses.swift`：那本原来 155 行，
// 接完这一族就是 440 行，正好撞上 `X3TestSizeAuditTests` 与产品同口径的 400 行线
// （阈值不许为变绿放宽 ⇒ 整块另起文件，这才是修复）。
// 判据仍然挂在 `LocalizationGuardTests` 上：它复用了那本里的
// `packageRoot` / `registeredStringsDictKeys` / `unusedPluralKeys` 三把既有尺子，
// 没有另抄一份口径。

extension LocalizationGuardTests {
    // MARK: - 批次 P69c（WS-多槽复数流）：一句话里两个复数槽
    //
    // 这一族是 P69 总工登记下来的缺口：`localizedCount` 只收一个 `Int`，
    // 于是「共 N 天 · 单日峰值 M 条」这种**两个槽各自有单复数**的句子
    // 只能留在插值里（英文态整句中文）或降级成单数键（英文语法错）。
    // 下面五组判据按"机制→目录→算法→中文侧→调用点"排：
    //   ① 先用**真 bundle** 证明多槽 stringsdict 真的各支独立选对（不成立就别往上盖房子）；
    //   ② 再把"模板不许自带数字"钉成目录判据 —— 逐槽千分位的全部前提就是这一条；
    //   ③ 千分位算法自己的元测试（正对照 + 不误伤），含"两个槽字面相同"那一格；
    //   ④ 中文侧逐字不变（含走真产品路径的那三句）；
    //   ⑤ 每条键都在自己的生产者那里被查。

    /// 本批登记的槽型键：`pluralSlots` = 复数（`%lld`）槽数，`textSlots` = 字符串（`%@`）槽数。
    /// 守卫按这张表逐条量目录 —— **加了键没登记进表 = 表与目录分叉当场红**。
    /// 键一律写成**一整条字面量**（不许 `+` 拼）：这张表本身就是"运行时送进查表那一串"的副本，
    /// 拼出来的话它就变成守卫 1d 点名的那族半句键，判据自己先失真。
    private static let p69cSlotKeys: [(key: String, pluralSlots: Int, textSlots: Int)] = [
        ("共 %lld 天 · 单日峰值 %lld 条", 2, 0),
        ("另有 %lld 次确认崩溃的事件时间在最近 %lld 天之外，属历史报告", 2, 0),
        ("读取失败 %1$lld 份（%2$@）未参与判定", 1, 1),
        ("还有 %lld 份崩溃通道文件未产出可计数的证据（内容损坏 / 只有文件名像 / 无事件时间 / 构建版本不是当前 / 同一事件的另一份），逐条原因待 LogSummary 落盘崩溃证据字段后展示", 1, 0),
    ]

    /// ① 多槽 stringsdict **真的**各支独立选对了吗。
    ///
    /// 为什么必须先有这一条：整栋房子（`localizedCount(_:slots:)` / `(_:count:note:)`）
    /// 盖在"一个键里能放多个复数变量"这句话上，而这句话我只在文档里见过。
    /// 本仓有过先例 —— 判据在假 bundle 上取到哨兵值、绿得没有意义
    /// （`DisclosureNounCopyTests` 为此专门钉"这个 bundle 不是空壳"），
    /// 所以这里同样先查一条既有键，再查各格组合。
    func test_p69cMultiSlotKeyActuallyPicksTwoIndependentBranches() throws {
        let en = LocalizationGuardTests.packageRoot.appendingPathComponent("Resources/en.lproj")
        guard let bundle = Bundle(url: en) else {
            return XCTFail("打不开 \(en.path) —— 英文资源不在原位，本条不能算通过")
        }
        XCTAssertFalse(bundle.localizedString(forKey: "%lld 行", value: "\u{FFFF}", table: nil)
            .contains("\u{FFFF}"), "连既有的「%lld 行」都查不到 ⇒ 这个 bundle 不是真的")

        // 每个槽**各自**过一遍 1 / 多：只测 (1,1) 与 (5,5) 是不够的 ——
        // 两槽同数时"整句只选了一支"这种错法照样绿。必须测交叉的 (1,5) 与 (3,1)。
        //
        // ⚠ 这一组**当场抓出一件文档里没写的事**（第一版就是这两格红的）：
        // 一个复数变量选哪一支，只看**它自己绑的那个数**，不看句子里别的主语。
        // 所以"要和第一个槽一致"的词（本句的动词 have/has）**只能放进第一个槽的形态里**；
        // 把它写在第二个槽的 one/other 上，(3,1) 就会输出
        // `3 confirmed crashes has…` —— 中文永远测不出来，只有交叉格能量到。
        let days = "共 %lld 天 · 单日峰值 %lld 条"
        let historical = "另有 %lld 次确认崩溃的事件时间在最近 %lld 天之外，属历史报告"
        let cases: [(key: String, slots: [Int], expect: String)] = [
            (days, [1, 1], "1 day · single-day peak 1 entry"),
            (days, [1, 5], "1 day · single-day peak 5 entries"),
            (days, [3, 1], "3 days · single-day peak 1 entry"),
            (days, [3, 5], "3 days · single-day peak 5 entries"),
            (historical, [1, 1],
             "1 confirmed crash has an event time outside the last 1 day, "
             + "counted as a historical report"),
            (historical, [3, 1],
             "3 confirmed crashes have an event time outside the last 1 day, "
             + "counted as a historical report"),
            (historical, [1, 30],
             "1 confirmed crash has an event time outside the last 30 days, "
             + "counted as a historical report"),
            (historical, [4, 30],
             "4 confirmed crashes have an event time outside the last 30 days, "
             + "counted as a historical report"),
        ]
        for item in cases {
            let template = bundle.localizedString(forKey: item.key, value: "\u{FFFF}", table: nil)
            XCTAssertFalse(template.contains("\u{FFFF}"), "\(item.key) 在 stringsdict 里查不到")
            XCTAssertEqual(String(format: template, arguments: item.slots), item.expect,
                           "槽 \(item.slots) 填进「\(item.key)」")
        }
    }

    /// ①b 混槽（复数 + 任意字符串）这一支：字符串落在**它自己的位置**上，
    /// 复数仍然按数字选形态。这条成立了，`读取失败 N 份（原因）未参与判定`
    /// 才允许留成一条整句键；它不成立就得拆两句（见 `localizedCount(_:count:note:)` 注释）。
    func test_p69cMixedSlotKeyResolvesPluralAndTextInEnglish() throws {
        let en = LocalizationGuardTests.packageRoot.appendingPathComponent("Resources/en.lproj")
        guard let bundle = Bundle(url: en) else {
            return XCTFail("打不开 \(en.path) —— 英文资源不在原位，本条不能算通过")
        }
        let key = "读取失败 %1$lld 份（%2$@）未参与判定"
        let template = bundle.localizedString(forKey: key, value: "\u{FFFF}", table: nil)
        XCTAssertFalse(template.contains("\u{FFFF}"), "混槽键在 stringsdict 里查不到")
        XCTAssertEqual(String(format: template, arguments: [1, "perm denied"] as [CVarArg]),
                       "1 unreadable crash file (perm denied) left out of the verdict")
        XCTAssertEqual(String(format: template, arguments: [4, "perm denied"] as [CVarArg]),
                       "4 unreadable crash files (perm denied) left out of the verdict")
    }

    /// ② 目录判据：**槽型键的模板里不许有非转换符的数字**。
    ///
    /// 为什么这条必须存在而不是"记得别写数字"：`groupedInto(_:counts:)` 的配对规则是
    /// "第 i 个槽 ↔ 渲染串里第 i 段连续数字"。模板只要自带一个数字字面
    /// （`{1,2,2.5,5}×10ⁿ`、`0…100`、`1,000 lines` 这种），段数就比槽数多，
    /// 千分位会补到别人的数字上 —— 而且中文态看不出来（中文那几个数本来就不分组）。
    /// 中文键与英文两支形态**都要量**：中文那一份走的是 `String(format: 键, …)` 这条路。
    func test_p69cRegisteredSlotKeysCarryNoForeignDigitRuns() throws {
        let path = LocalizationGuardTests.packageRoot
            .appendingPathComponent("Resources/en.lproj/Localizable.stringsdict").path
        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertFalse(text.isEmpty, "读不到 stringsdict ⇒ 本条在空转")
        XCTAssertFalse(Self.p69cSlotKeys.isEmpty, "槽型键名单是空的 ⇒ 本条在空转")

        var problems: [String] = []
        for item in Self.p69cSlotKeys {
            guard let block = Self.stringsDictEntry(for: item.key, in: text) else {
                problems.append("\(item.key)：stringsdict 里没有这条顶层键（缩进不是一个 tab？）")
                continue
            }
            let values = Self.plistStrings(in: block)
            guard values.count >= 1 + 2 * item.pluralSlots else {
                problems.append("\(item.key)：只取到 \(values.count) 个 <string>，"
                              + "\(item.pluralSlots) 个复数槽至少要 \(1 + 2 * item.pluralSlots) 个")
                continue
            }
            let pluralVars = block.components(separatedBy: "<string>NSStringPluralRuleType</string>")
                .count - 1
            if pluralVars != item.pluralSlots {
                problems.append("\(item.key)：目录里 \(pluralVars) 个复数变量，名单声明 \(item.pluralSlots) 个")
            }
            // 混槽出口把实参**钉死**成 `[count, note]`（第 1 位是 `Int`、第 2 位是 `String`）。
            // 目录里只要写成 `%1$@ … %2$lld`，运行时就是拿一个 `Int` 去喂 `%@`
            // —— 那是本仓用 `EXC_BAD_ACCESS` 换回来的那条崩溃（编译得过、启动即崩）。
            // 所以这一条不是格式洁癖：它是那一族崩溃唯一的静态出口。
            if item.textSlots == 1,
               let broken = Self.mixedSlotContractBroken(key: item.key, formatKey: values.first ?? "") {
                problems.append("\(item.key)：\(broken)")
            }
            for source in [item.key] + values {
                if let digits = Self.foreignDigits(in: source) {
                    problems.append("\(item.key) 的模板带了非转换符的数字 \(digits)：\"\(source)\"")
                }
            }
        }
        XCTAssertTrue(problems.isEmpty,
                      "槽位与数字段的对位关系被破坏 ⇒ 千分位会补错地方：\n  "
                        + problems.joined(separator: "\n  "))
    }

    /// 元测试（判据的判据）：一条**真带数字**的模板必须被上面那把尺子点出来，
    /// 而 `LogsTrendCard.footnote` 那种真实存在的旧形状（`{1,2,2.5,5}×10ⁿ`、`0…100`）
    /// 就是它的样子 —— 拿本仓自己的句子当坏样例，不是编一个。
    /// 反向：本批四条真键一条都不许被误伤（上面那条已经绿，但那条是"全都要过"，
    /// 这一条才说明过滤器没有把一切都判死）。
    func test_meta_p69cDigitRulerCatchesRealShapesAndSparesThisBatch() throws {
        let dirty = [
            "纵轴 0…%1$@ 条，按 {1,2,2.5,5}×10ⁿ 台阶取轴。",
            "%@ per 1,000 lines",
            "%1$lld 天 · 峰值 %2$lld 条（近 30 日）",
        ]
        for sample in dirty {
            XCTAssertNotNil(Self.foreignDigits(in: sample), "带数字的模板没被抓到：\(sample)")
        }
        let clean = [
            "共 %lld 天 · 单日峰值 %lld 条",
            "读取失败 %1$lld 份（%2$@）未参与判定",
            "%1$#@unreadableCrashFiles@ (%2$@) left out of the verdict",
            "single-day peak %lld entries · 占全机 %1$@ 的写法不含数字？不含。",
        ]
        for sample in clean {
            XCTAssertNil(Self.foreignDigits(in: sample), "合法模板被误伤：\(sample)")
        }
        // 分母自证：本批四条键确实逐条被上面那条读到（名单写了却一条都没在目录里 ⇒
        // `problems` 非空，但过滤器坏掉时它是空的，所以要正面数一次）。
        let path = LocalizationGuardTests.packageRoot
            .appendingPathComponent("Resources/en.lproj/Localizable.stringsdict").path
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let found = Self.p69cSlotKeys.filter { Self.stringsDictEntry(for: $0.key, in: text) != nil }
        XCTAssertEqual(found.count, Self.p69cSlotKeys.count, "有键的整块取不到 ⇒ 上面那条判据在空转")
        // 混槽形状契约：把两个槽的编号对调 ⇒ 必须判坏（对调后是"Int 喂 %@"，启动即崩那一族）。
        XCTAssertNotNil(Self.mixedSlotContractBroken(key: "读取失败 %1$@ 份（%2$lld）未参与判定",
                                                     formatKey: "%2$#@f@ (%1$@) left out"),
                        "对调过的混槽键没被抓到 ⇒ 那条崩溃只剩运行时看得见")
        XCTAssertNil(Self.mixedSlotContractBroken(key: "读取失败 %1$lld 份（%2$@）未参与判定",
                                                  formatKey: "%1$#@f@ (%2$@) left out"),
                     "本批真正在用的形状被判坏 ⇒ 契约写歪了")
    }

    /// ③ 多槽千分位算法自己的元测试。这一条是"新出口 = 新判据"里**咬人**的那一半。
    func test_p69cMultiSlotGroupingFillsEverySlotAndSparesForeignDigits() {
        // 正对照 A：两个槽、**字面不同**，两个都要补上。
        XCTAssertEqual(groupedInto("共 7 天 · 单日峰值 1234 条", counts: [7, 1234]),
                       "共 7 天 · 单日峰值 1,234 条")
        XCTAssertEqual(groupedInto("共 1234 天 · 单日峰值 7 条", counts: [1234, 7]),
                       "共 1,234 天 · 单日峰值 7 条")
        // 正对照 B：**两个槽字面相同**（旧的单槽"找第一次出现的子串"规则会把同一处改两遍、
        // 第二个槽照样光着）—— 这一格就是派单里点名"最需要自己想清楚"的那一点。
        XCTAssertEqual(groupedInto("共 1000 天 · 单日峰值 1000 条", counts: [1000, 1000]),
                       "共 1,000 天 · 单日峰值 1,000 条")
        // 不误伤 ①：译文里那一段数字**更长**（12345），不许去啃它的半截。
        XCTAssertEqual(groupedInto("12345 行", counts: [1234]), "12345 行",
                       "子串半截命中 ⇒ 会改出 `1,2345 行` 这种机器串")
        // 不误伤 ②：模板里已经有一段**分组形态**的数字（`1,024` = 两段数字）时，
        // 段数比槽数多、逐段对号全部对不上 ⇒ **一个都不补、也一个都不改坏**。
        // （这种模板本来就被 ② 那条目录判据挡在门外；这里钉的是"万一进来了也不许猜"。）
        XCTAssertEqual(groupedInto("每 1,024 行 · 1024 条", counts: [1024, 1024]),
                       "每 1,024 行 · 1024 条",
                       "对不上号就原样返回 —— 猜着改会把译文里的数字改坏")
        // 不误伤 ③：段数比槽少（译文把占位符弄丢了）—— 原样返回，不许猜。
        XCTAssertEqual(groupedInto("没有数字", counts: [5000, 6000]), "没有数字")
        XCTAssertEqual(groupedInto("共 1234 天", counts: [1234, 5000]), "共 1,234 天",
                       "只补得上号的那一个槽，剩下的不许往别处挪")
        // 不误伤 ④：**两个槽字面相同**、而串里前面还站着一段更长的数字（`991234` 的尾巴
        // 正好是 `1234`）。按值"从左往右找第一次出现的子串"会先把别人的数字啃掉
        // （改出 `991,234`），第二趟才轮到真槽；按"完整段 + 槽序号"配对只动真正那一格。
        XCTAssertEqual(groupedInto("第 991234 名 · 1234 条", counts: [1234, 1234]),
                       "第 991234 名 · 1,234 条",
                       "同字面两槽 ⇒ 子串规则会先改坏前一段，这一格就是它的反例")
        // 小数量词一字不变。
        XCTAssertEqual(groupedInto("共 1 天 · 单日峰值 5 条", counts: [1, 5]),
                       "共 1 天 · 单日峰值 5 条")
        // 端到端：混槽出口里那枚**含数字的字符串槽**不许被当成千分位目标。
        // （`原因 ×1234` 先落地的话它就是第 0 段连续数字 —— 占位符挡的就是这一格。）
        XCTAssertEqual(
            localizedCount("读取失败 %1$lld 份（%2$@）未参与判定",
                           count: 1234, note: "文件已不存在 ×1234、权限不足 ×2"),
            "读取失败 1,234 份（文件已不存在 ×1234、权限不足 ×2）未参与判定")
    }

    /// ④ 中文侧逐字不变。**改的是怎么取文案，不是文案本身。**
    /// 期望值是从改前的源码抄下来的字面量，右半边是**按老写法现算**出来的同形串，
    /// 两边都必须相等 —— 只写一边的话抄错了也测不出来。
    func test_p69cChineseSideOfTheFourSentencesIsUnchanged() throws {
        let fixed = Date(timeIntervalSince1970: 1_800_000_000)
        var summary = LogSummary()
        summary.crashCount = 4
        summary.trend = [
            LogBucket(date: fixed.addingTimeInterval(-70 * 86_400),
                      errors: 1, warnings: 0, exceptions: 0, crashes: 2),
            LogBucket(date: fixed, errors: 1, warnings: 0, exceptions: 0, crashes: 1),
        ]
        summary.scannedFiles = (0..<6).map {
            ScannedLogFile(path: "/tmp/p69c-\($0).ips", sizeBytes: 10, lineCount: 3,
                           modifiedAt: fixed, role: .crash)
        }
        summary.readFailedFiles = [
            ScannedLogFile(path: "/tmp/p69c-f1.log", sizeBytes: 10, lineCount: 0,
                           modifiedAt: fixed, role: .crash, readFailure: "权限不足"),
            ScannedLogFile(path: "/tmp/p69c-f2.log", sizeBytes: 10, lineCount: 0,
                           modifiedAt: fixed, role: .crash, readFailure: "文件已不存在"),
        ]
        let rendered = summary.crashEvidenceFootnote(windowDays: 30, now: fixed)
        // 抄自改前的 `FileLogAnalyzer.crashEvidenceFootnote`（四处插值 + 一次 `+` 拼接）。
        XCTAssertEqual(rendered,
                       "窗口内确认崩溃 4 次，只统计有真实事件证据的报告"
                     + " · 另有 2 次确认崩溃的事件时间在最近 30 天之外，属历史报告"
                     + " · 读取失败 2 份（文件已不存在 ×1、权限不足 ×1）未参与判定"
                     + " · 还有 2 份崩溃通道文件未产出可计数的证据（内容损坏 / 只有文件名像 / "
                     + "无事件时间 / 构建版本不是当前 / 同一事件的另一份），"
                     + "逐条原因待 LogSummary 落盘崩溃证据字段后展示。")
        // 右半边：与改前**同一个表达式**现算，防止上面那份抄本自己抄错。
        let legacy = "窗口内确认崩溃 \(summary.crashCount) 次，只统计有真实事件证据的报告"
            + " · 另有 \(summary.historicalCrashCount(windowDays: 30, now: fixed)) 次确认崩溃的事件"
            + "时间在最近 30 天之外，属历史报告"
            + " · 读取失败 2 份（文件已不存在 ×1、权限不足 ×1）未参与判定"
            + " · 还有 2 份崩溃通道文件未产出可计数的证据（内容损坏 / 只有文件名像 / "
            + "无事件时间 / 构建版本不是当前 / 同一事件的另一份），"
            + "逐条原因待 LogSummary 落盘崩溃证据字段后展示。"
        XCTAssertEqual(rendered, legacy)
        // 趋势卡副标题：老写法是 `NumberFormat.grouped` 两处，新写法是填完之后补千分位。
        for (days, peak) in [(7, 1_234), (1, 9), (1_000, 1_000), (365, 0)] {
            XCTAssertEqual(localizedCount("共 %lld 天 · 单日峰值 %lld 条", slots: [days, peak]),
                           "共 \(NumberFormat.grouped(days)) 天 · 单日峰值 \(NumberFormat.grouped(peak)) 条",
                           "槽 (\(days), \(peak)) 的中文态与老写法分叉")
        }
    }

    /// ⑤ 每条键都真的被它那个生产者查着（正向），假键必须报出来（反向）。
    /// 没有反向那一半，"逐条都在源码里"这条绿只说明扫描面是空的。
    func test_p69cSlotKeysAreLookedUpAtTheirProducers() throws {
        let bodies = try SurfaceScanKit.sourceFiles(under: "").map(\.content).reduce("") { $0 + $1 }
        XCTAssertEqual(Self.unusedPluralKeys(Self.p69cSlotKeys.map(\.key), in: bodies), [],
                       "槽型键登记了却没人查 ⇒ 屏上仍是拼出来的中文")
        XCTAssertFalse(Self.unusedPluralKeys(["P69c 夹具：这条键绝不存在 %lld 天"], in: bodies).isEmpty,
                       "假键没被抓到 ⇒ 上面那条绿不可信")
    }

    // MARK: P69c 用的小工具

    /// 取 stringsdict 里一条顶层键的**整块**文本（含它的 `<key>` 行，到下一个顶层键之前）。
    static func stringsDictEntry(for key: String, in text: String) -> String? {
        guard let head = text.range(of: "\n\t<key>\(key)</key>\n") else { return nil }
        let tail = text[head.upperBound...]
        let stop = tail.range(of: "\n\t<key>") ?? tail.range(of: "\n</dict>")
        return String(text[head.lowerBound..<(stop?.lowerBound ?? text.endIndex)])
    }

    /// 一块 plist 里所有 `<string>` 的值。
    static func plistStrings(in block: String) -> [String] {
        let re = try! NSRegularExpression(pattern: "<string>(.*?)</string>",
                                          options: [.dotMatchesLineSeparators])
        let range = NSRange(block.startIndex..., in: block)
        return re.matches(in: block, options: [], range: range).compactMap {
            Range($0.range(at: 1), in: block).map { String(block[$0]) }
        }
    }

    /// 混槽出口的键形状契约：`localizedCount(_:count:note:)` 按 `[count, note]` 喂，
    /// 所以**第 1 号槽必须是 `lld`、第 2 号必须是 `@`**。
    /// 写成 `%1$@ … %2$lld` 的话，运行时是拿一个 `Int` 去喂 `%@`
    /// —— 本仓用 `EXC_BAD_ACCESS` 换回来的那条崩溃（编译得过、启动即崩）。
    /// 所以这一条不是格式洁癖，它是那一族崩溃唯一的静态出口。
    static func mixedSlotContractBroken(key: String, formatKey: String) -> String? {
        if !(key.contains("%1$lld") && key.contains("%2$@")) {
            return "混槽键必须给复数槽 %1$lld、给字符串槽 %2$@（实参按 [count, note] 顺序喂）"
        }
        if !(formatKey.contains("%1$") || formatKey.contains("%#@")) {
            return "英文侧的 NSStringLocalizedFormatKey 没给这两个槽留位置：\"\(formatKey)\""
        }
        return nil
    }

    /// 剥掉**所有**转换符之后还剩 ASCII 数字吗？剩就是"模板自带的数字字面"，返回它们。
    /// 顺序要紧：`%1$#@var@` 要按整条剥（先 `%[0-9]*[$]?#@…@`，再普通转换符，最后裸 `%`）。
    static func foreignDigits(in text: String) -> [String]? {
        var stripped = text
        for pattern in [try! NSRegularExpression(pattern: #"%[0-9]*[$]?#@[A-Za-z0-9_]+@"#),
                        try! NSRegularExpression(pattern: #"%[0-9]*[$]?[@a-zA-Z]{1,3}"#),
                        try! NSRegularExpression(pattern: "%")] {
            stripped = pattern.stringByReplacingMatches(
                in: stripped, options: [], range: NSRange(stripped.startIndex..., in: stripped),
                withTemplate: "")
        }
        let runs = stripped.split(whereSeparator: { !$0.isASCII || !$0.isNumber })
            .filter { $0.allSatisfy { $0.isASCII && $0.isNumber } && !$0.isEmpty }
        return runs.isEmpty ? nil : runs.map(String.init)
    }
}
