import XCTest
@testable import TcoderMonitor

// MARK: - 尺子的元测试：`subtitleHelp:` / `captionHelp:` 这类新标签必须进账
//
// 从 `TooltipMigrationGuardTests.swift` 拆出来住（那个文件加完这条就 423 行，
// 撞上 `X3TestSizeAuditTests` 与产品同源的 400 行口径）。判据本体一字未改。

extension TooltipMigrationGuardTests {

    /// 同一条判据要沿到**新开的两个标签**上。S7 交回时点名：`subtitleHelp:` / `captionHelp:`
    /// 大小写与 `\\bhelp:` 不匹配 ⇒ 按「一个参数一行」排版的整句被判成 `.skipped`，
    /// **A 与 B 同时看不见它**（搬进去 A 降、总量也降，守恒线撞不出红）——
    /// 而 B 存在的全部理由就是"别让搬字变成删字"。这条元测试钉的就是那个形状。
    func test_meta_newHelpLabelsAreCountedAsHiddenNotSkipped() {
        let hoverted = [(path: "Views/Fake.swift", content: """
        GlassSection("健康评分",
                     subtitle: "综合 76 分",
                     subtitleHelp: "综合分 = Σ（得分 × 归一化权重），缺席维度不参与计分也不按 0 计入") {
            EmptyView()
        }
        """)]
        let (visible, tooltip) = Self.scan(hoverted)
        XCTAssertEqual(tooltip.count, 1, "单独一行的 `subtitleHelp:` 没被算成已藏 —— 尺子在漏计")
        XCTAssertTrue(visible.isEmpty, "同一句既算常驻又算已藏，A/B 会互相圆场：\(visible)")
        let captioned = [(path: "Views/Fake.swift", content: """
        MetricTile(title: "内存",
                   captionHelp: "口径 = 总量 −（空闲 + 推测 + 可清除），这是「在用」不是「剩余可用」")
        """)]
        XCTAssertEqual(Self.scan(captioned).tooltip.count, 1)
        // 反向：这句要是被整行删掉，必须让总量掉下来（不是"看不见"）。
        let deleted = [(path: "Views/Fake.swift", content: """
        GlassSection("健康评分",
                     subtitle: "综合 76 分") {
            EmptyView()
        }
        """)]
        let after = Self.scan(deleted)
        XCTAssertTrue(after.tooltip.isEmpty && after.visible.count <= 1,
                      "删掉整句却什么都没少 ⇒ 这条线抓不住删除：" + "\(after)")
    }

    /// 同族盲区的**又一次复发**（上一次是本分片第一条元测试那两个 `subtitleHelp:` 新标签）：
    /// **整句键化之后**，常驻句从尺子上消失。
    ///
    /// 实测（09-24 02:5x，`TooltipMigrationGuardTests` 单跑）：
    /// * 并 main `999e25f` 之后，旧尺子报「总量 101 掉到 100」⇒ B 当场红；
    ///   拆开看是可见 54 + tooltip 46，而 **tooltip 一直没动** ⇒ 瞎的那半边是**可见槽**。
    /// * 入口族认了 `text: localizedFormat("…")` 这类查表形状之后，同一份内容
    ///   可见 **54 → 86**（上限 62 是 09-21 在瞎的尺子上打的，见 `visibleCaliberCeiling` 上方注释）。
    ///
    /// 机制：槽位识别只认 `text: "`，新形状 `text: localizedFormat("` 判成 `.skipped`
    /// ⇒ A 与 B **同时**看不见它。**键化不改变中文态屏上一个字**，所以这 32 条一直是真债
    /// （86 条里只有 7 条住在 P69 三批改过的文件 ⇒ 其余 79 条先前就躲着；至于 09-21 那次
    /// "88 → 62" 里有多少其实也是键化躲过去的，**没有回测**，两份文档里都留了更正段）。
    ///
    /// ⚠ **这条判据现在有且只有一处实现**：我第一版是在四条正则里插 `keyedLookup`（`7f6b5c7`），
    /// 合并时 main 那侧（P70）已经独立得出同一个数、改用 `stripLookupWrappers` 归一 prefix
    /// （能剥嵌套的 `Text(localizedFormat(`，我那版只能剥一层）⇒ **我的正则撤了**，
    /// 这条元测试留着当**第二双眼睛**：它不依赖任何实现细节，只钉"换壳不换读数"。
    /// ⇒ 这条元测试钉的是**形状不变式**：同一句话，换壳不换读数。
    func test_meta_keyedLookupInsideSlotKeepsTheSameReading() {
        let sentence = "先去掉嵌套：校验与异常分支改成提前返回，再把成组的分支换成策略表"
        let unkeyed = [(path: "Views/Fake.swift", content: "        text: \"" + sentence + "\"")]
        let keyed = [(path: "Views/Fake.swift",
                      content: "        text: localizedFormat(\"%1$@ " + sentence + "\", n)")]
        let before = Self.scan(unkeyed)
        let after = Self.scan(keyed)
        XCTAssertEqual(before.visible.count, 1, "旧形状本身就没被数到 ⇒ 夹具坏了")
        XCTAssertEqual(after.visible.count, before.visible.count,
                       "同一句常驻话，套上查表出口就不见了 ⇒ 键化等于对尺子隐身")
        XCTAssertTrue(after.tooltip.isEmpty, "常驻句被算成已藏：\(after.tooltip)")
        // hover 侧同理：`.help(localizedCopy("…"))` 必须是「已藏」，不是「没有」。
        let hoverted = [(path: "Views/Fake.swift",
                         content: "        Text(\"内存\").help(localizedCopy(\"口径 = 总量减去空闲、推测与可清除三类，这是在用而非剩余可用\"))")]
        let hover = Self.scan(hoverted)
        XCTAssertEqual(hover.tooltip.count, 1, "套了查表出口的 hover 句没被算成已藏：\(hover.visible)")
        // 反向（不许扩口扩成「凡键化句都算常驻」）：不在任何槽位里的查表调用仍然不计。
        let floating = [(path: "Services/Fake.swift",
                         content: "    static let draft = localizedCopy(\"这句还没被任何视图用上，它不该出现在两份名单里面去\")")]
        let none = Self.scan(floating)
        XCTAssertTrue(none.visible.isEmpty && none.tooltip.isEmpty,
                      "槽位外的查表字面量被算进账了 ⇒ 扩口扩错了方向：" + "\(none)")
    }

    /// 每次跑都落一份**常驻长句名单**（相对路径 `.scratch/tcoder-caliber-visible-inventory.txt`）。
    ///
    /// 为什么必须有：这次「可见 56 → 86」的跳变，守卫原本只印两个数 ——
    /// 读的人分不清是"页面长胖了"还是"尺子刚好了一点"，只能自己再算一遍（而复刻的尺子必然差几格）。
    /// 名单在，跳变就能逐条对；这也顺手补掉另一格：**A 那次失败时日志里连现量都没留下**。
    static func dump(_ visible: [Caliber]) -> String {
        let relative = ".scratch/tcoder-caliber-visible-inventory.txt"
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent(relative)
        let body = visible.sorted { ($0.path, $0.line) < ($1.path, $1.line) }
            .map { "\($0.path):\($0.line)\t\($0.text)" }.joined(separator: "\n")
        let text = "# 常驻长句 \(visible.count) 条（由 TooltipMigrationGuardTests 每次跑落盘）\n" + body + "\n"
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
            let back = ((try? String(contentsOf: file, encoding: .utf8)) ?? "")
                .split(separator: "\n").count - 1        // 减掉第一行的 `#` 表头
            return "；名单 \(relative)（回读 \(back) 行）" + (back == visible.count ? "" : " ⇒ ⚠ 回读与现量不符，清单不可信")
        } catch {
            return "；⚠ 名单落盘失败（\(error.localizedDescription)）⇒ 只有数字、没有名单"
        }
    }

}
