import Foundation
import XCTest
@testable import TcoderMonitor

// MARK: - 批次 P69c · 夹具名册与混槽那一支（RD-60 收尾轮 · R3 裁定拆出来住）
//
// OWNER: WS-R20 CrashEvidence（收支流 R30 落 R3 裁定）。判据仍然挂 `LocalizationGuardTests`，
// 与 `LocalizationGuardTests+MultiSlotCopy.swift` 是**同一个类型、同一批键** ——
// 分片只因 `X3TestSizeAuditTests` 那条与产品同口径的 400 行线（阈值不许为变绿放宽），
// 不是把判据拆开各管一段。
//
// # 为什么这一格里放着三样东西
//
// 1. **夹具名单 `p69cFixtureOnlySlotKeys`**：R3 第 3 步把原来那一份 `p69cSlotKeys` 拆成两份 ——
//    留在原名单里的必须"有生产者"（那是 ⑤ 的判据对象），只为契约保活、屏上不出现的那两枚
//    搬到这里。分家的唯一理由：⑤ 那句「每条键都在自己的生产者那里被查」是**全名单量词**，
//    掺进一枚夹具键就等于把那句真话稀释成"大概都有人查"。
// 2. **它的分母断言**：名单与"名单不许变成空壳"那条断言必须住在同一个文件里 ——
//    谁删条目就当场看见另一条红，而不是让 ②/①b 悄悄少覆盖几枚键。
// 3. **混槽那一支（①b）+ 形状契约工具 `mixedSlotContractBroken` + ② 的元测试**：
//    那两枚混槽键（一枚在产、一枚夹具）正是这一支的两个对象，搬过来之后
//    "键 → 形状契约 → 分母断言"读起来是一条链，不用在两个文件之间跳。

extension LocalizationGuardTests {
    /// 只为契约保活、**屏上不出现**的夹具键：② 的目录形状判据与 ①/①b 的"两支各自选对"
    /// 照旧逐条覆盖它们，而 ⑤ **不要求**它们有生产者。
    /// 每一枚都要在下面那条分母断言里取到整块，也要在 ①/①b 里被真的用着。
    static let p69cFixtureOnlySlotKeys: [(key: String, pluralSlots: Int, textSlots: Int)] = [
        // 两枚两复数槽键里**唯一一枚英文值带动词**的（另一枚 `共 %lld 天 · 单日峰值 %lld 条`
        // 的英文是名词短语，没有动词可错）⇒ ① 那个"动词只能跟第一个槽"的交叉格结论
        // 只有它撑得住。R3 第 3 步因此判它**不删**。
        ("另有 %lld 次确认崩溃的事件时间在最近 %lld 天之外，属历史报告", 2, 0),
        // 混槽形状的正例载体（`%1$lld` + `%2$@`）。RD-60 把那句换成了两条在产键，
        // 生产路径上同一形状已由 `最近 %1$lld 天为窗口，逐条原因如下：%2$@` 顶上（在 ⑤ 那份名单里）；
        // 这一枚留着是让 ②/①b 继续量它那个目录块，屏幕不再读它。
        ("读取失败 %1$lld 份（%2$@）未参与判定", 1, 1),
    ]

    /// 夹具名单的**分母断言**：名单非空、且每一枚在 `.stringsdict` 里**整块取得到**、
    /// 块里的复数变量个数与名单声明一致。
    /// 少了这一条，"从名单里删掉一枚夹具键"就是一次没人察觉的降级：
    /// ②/①b 会静默少覆盖几枚键，而 ⑤ 照旧绿（它本来就不读这份名单）。
    func test_p69cFixtureOnlySlotKeysStillCarryTheirCatalogBlocks() throws {
        XCTAssertFalse(Self.p69cFixtureOnlySlotKeys.isEmpty,
                       "夹具名单已经空了 ⇒ ②/①b 对夹具键的覆盖面静默消失。"
                     + "要么把那两枚键请回名单，要么把这一族判据整条删掉并说明理由，不许留着空壳")
        let path = LocalizationGuardTests.packageRoot
            .appendingPathComponent("Resources/en.lproj/Localizable.stringsdict").path
        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertFalse(text.isEmpty, "读不到 stringsdict ⇒ 本条在空转")
        var missing: [String] = []
        var mismatched: [String] = []
        for item in Self.p69cFixtureOnlySlotKeys {
            guard let block = Self.stringsDictEntry(for: item.key, in: text) else {
                missing.append(item.key)
                continue
            }
            let pluralVars = block.components(separatedBy: "<string>NSStringPluralRuleType</string>")
                .count - 1
            if pluralVars != item.pluralSlots {
                mismatched.append("\(item.key)：目录里 \(pluralVars) 个复数变量，名单声明 \(item.pluralSlots) 个")
            }
        }
        XCTAssertTrue(missing.isEmpty, "夹具键的整块在 .stringsdict 里取不到了：\(missing)")
        XCTAssertTrue(mismatched.isEmpty, "夹具名单声明的槽数与目录分叉：\(mismatched)")
        // 反向自证：一枚绝不存在的键必须落进 `missing` 那种形状（取整块那把尺子返回 nil 要可信），
        // 否则上面那两句绿只说明名单是空的。
        XCTAssertNil(Self.stringsDictEntry(for: "P69c 夹具名单元测试：这条键绝不存在 %lld 天", in: text),
                     "取整块那把尺子在假键上也取得到东西 ⇒ 上面那条分母断言不可信")
    }

    /// ①b 混槽（复数 + 任意字符串）这一支：字符串落在**它自己的位置**上，
    /// 复数仍然按数字选形态。这条成立了，混槽那一句才允许留成一条整句键；
    /// 它不成立就得拆两句（见 `localizedCount(_:count:note:)` 注释）。
    ///
    /// RD-60 收尾轮（R3 第 2 步）：这一支**改指到生产路径上真实被查的那枚同形状键**
    /// （`最近 %1$lld 天为窗口，逐条原因如下：%2$@`，生产者 = `CrashEvidenceReadout.footnote`），
    /// 原来那枚夹具键 `读取失败 %1$lld 份（%2$@）未参与判定` 同时留在本条里继续量 ——
    /// 它是 ② 那条混槽崩溃契约的正例载体，屏上不再出现。
    func test_p69cMixedSlotKeyResolvesPluralAndTextInEnglish() throws {
        let en = LocalizationGuardTests.packageRoot.appendingPathComponent("Resources/en.lproj")
        guard let bundle = Bundle(url: en) else {
            return XCTFail("打不开 \(en.path) —— 英文资源不在原位，本条不能算通过")
        }
        let cases: [(key: String, count: Int, expect: String)] = [
            ("最近 %1$lld 天为窗口，逐条原因如下：%2$@", 1,
             "The window is the last 1 day; per-reason breakdown: perm denied"),
            ("最近 %1$lld 天为窗口，逐条原因如下：%2$@", 30,
             "The window is the last 30 days; per-reason breakdown: perm denied"),
            ("读取失败 %1$lld 份（%2$@）未参与判定", 1,
             "1 unreadable crash file (perm denied) left out of the verdict"),
            ("读取失败 %1$lld 份（%2$@）未参与判定", 4,
             "4 unreadable crash files (perm denied) left out of the verdict"),
        ]
        for item in cases {
            let template = bundle.localizedString(forKey: item.key, value: "\u{FFFF}", table: nil)
            XCTAssertFalse(template.contains("\u{FFFF}"), "混槽键 \(item.key) 在 stringsdict 里查不到")
            XCTAssertEqual(String(format: template,
                                  arguments: [item.count, "perm denied"] as [CVarArg]), item.expect,
                           "槽 \(item.count) 填进「\(item.key)」")
        }
    }

    /// 元测试（② 的判据的判据）：一条**真带数字**的模板必须被那把尺子点出来，
    /// 而 `LogsTrendCard.footnote` 那种真实存在的旧形状（`{1,2,2.5,5}×10ⁿ`、`0…100`）
    /// 就是它的样子 —— 拿本仓自己的句子当坏样例，不是编一个。
    /// 反向：本批真键一条都不许被误伤（② 那条已经绿，但那条是"全都要过"，
    /// 这一条才说明过滤器没有把一切都判死）。
    /// 末了三格是混槽形状契约的**正反两例**（R3 第 2 步之后正例落在在产键上）。
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
        // 分母自证：**两份**名单里的键确实逐条被 ② 读到（名单写了却一条都没在目录里 ⇒
        // `problems` 非空，但过滤器坏掉时它是空的，所以要正面数一次）。
        let path = LocalizationGuardTests.packageRoot
            .appendingPathComponent("Resources/en.lproj/Localizable.stringsdict").path
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let found = Self.p69cAllSlotKeys.filter { Self.stringsDictEntry(for: $0.key, in: text) != nil }
        XCTAssertEqual(found.count, Self.p69cAllSlotKeys.count, "有键的整块取不到 ⇒ 上面那条判据在空转")
        // 混槽形状契约：把两个槽的编号对调 ⇒ 必须判坏（对调后是"Int 喂 %@"，启动即崩那一族）。
        XCTAssertNotNil(Self.mixedSlotContractBroken(key: "最近 %1$@ 天为窗口，逐条原因如下：%2$lld",
                                                     formatKey: "%2$#@f@ (%1$@) left out"),
                        "对调过的混槽键没被抓到 ⇒ 那条崩溃只剩运行时看得见")
        XCTAssertNil(Self.mixedSlotContractBroken(key: "最近 %1$lld 天为窗口，逐条原因如下：%2$@",
                                                  formatKey: "%1$#@f@; per-reason breakdown: %2$@"),
                     "生产路径真正在用的形状被判坏 ⇒ 契约写歪了")
        // 夹具键那一枚的同一条契约也要过（它仍是 `localizedCount(_:count:note:)` 的正例载体）。
        XCTAssertNil(Self.mixedSlotContractBroken(key: "读取失败 %1$lld 份（%2$@）未参与判定",
                                                  formatKey: "%1$#@f@ (%2$@) left out"),
                     "夹具键那一枚的形状契约被改歪 ⇒ 上面那条正例不算覆盖它")
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
}
