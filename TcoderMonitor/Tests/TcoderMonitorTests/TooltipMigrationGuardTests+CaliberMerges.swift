import Foundation
import XCTest

// MARK: - 守恒线的第二条腿：整句键化之后，口径文本必须逐句还活着
//
// OWNER: 总工程师（批次 P69 合流时立）
//
// 为什么要单独一条：`TooltipMigrationGuardTests` 的守卫 B 数的是 `Views/**` 里
// **长中文字面量的条数**，它是个单元数代理。P69a/b/c 三条流把 26 段"插值 + `+` 拼出来的半句"
// 并成下面这 10 条整句键 —— 文本一个字没少，**可数的单元少了 8 个**，于是守恒线当场判红：
// 「口径说明总量从 101 掉到 100：把长句删掉不是藏进 ⓘ」。
//
// 那条判词在这里是**误报**，但误报的方式很有价值：它说明"条数"根本不是我们关心的量。
// 两种处置的区别：
//   ① 往 `acceptedCaliberDeletions` 里塞 8 条 —— 错。那个口的语义是「这句本来就不该占两处，
//      核准删除」，把"并成整句"记成"删除"，等于用豁免口掩盖判据口径错，
//      而且下一轮真有谁删句子，那个口已经松了。
//   ② 把地板按实测降到 100，**同时**立一条能反驳"文本其实丢了"的判据 —— 本文件就是这条。
//      从此地板降一次，必须有这里逐句点名过的一条整句键在树里活着来抵；
//      只降地板、不登记存活句，本文件当场红。

// 从主文件搬来的四行（主文件正好卡在 Tests 侧 400 行线，内容一字未删）：
    // 101 → **100（P69 合流，2026-09-24）**：三条流把 26 段"插值 + `+` 拼的半句"并成 10 条整句键，
    // **文本一字未少、可数的单元少 8 个**（守卫 B 数的是字面量条数，是个单元代理）。
    // 这不是放宽：那 10 句现在由 `+CaliberMerges.swift` 逐句钉着必须还在树里，
    // 地板每降一次都要有存活句抵一次。删除仍只能走 `acceptedCaliberDeletions` 逐条留名。

extension TooltipMigrationGuardTests {

    /// P69a/b/c 并成整句键的那 10 句口径原文（**照抄源码里的键，含 `%1$@` / `%lld` 占位符**）。
    /// 每一条都必须在当前 `Views/**` 源码里逐字出现 —— 这就是"文本没丢"的机器形态。
    static let caliberKeysThatMustSurvive: [String] = [
        // P69a：复杂度风险页四条建议 + 一处 badge
        "%1$@ 个函数被判为严重复杂度，最高圈复杂度 %2$@：%3$@。",
        "同时有 %1$@ 个函数处于高复杂度档（CC %2$@~%3$@）：",
        "%1$@ 个上榜函数的参数达到或超过 %2$@ 个，最多的是%3$@（%4$@ 个参数 · %5$@:%6$@）：",
        "注释率 %1$@（%2$@ / %3$@ 行）低于本页 %4$@ 的提示线：",
        "%1$@（CC %2$@ · %3$@ 行 · %4$@:%5$@）",
        // P69a：复杂度风险页两处空态正文
        "扫描了 %1$@ 个文件 / %2$@ 行有效代码，重复率为 %3$@。",
        "本次扫描没有函数达到引擎给出的复杂度上榜条件。参考数字：超长函数 %1$@ 个 · 平均函数长度 %2$@ 行。",
        // P69b：Git 洞察外壳句与健康评分一致性句
        "分析的是另一个仓库：%1$@\\n%2$@",
        "历史末点 %1$@ 与本次 %2$@ 不一致。",
        // P69c：错误趋势卡副标题（一句两个复数槽）
        "共 %lld 天 · 单日峰值 %lld 条",
    ]

    /// 正向：每条都必须在树里活着。反向（元测试）：一条不存在的句子必须被点名。
    /// 没有反向那一半，这条绿只说明扫描面是空的。
    func test_p69CaliberKeysStillExistVerbatim() throws {
        let files = try Self.viewFiles()
        XCTAssertGreaterThanOrEqual(files.count, 40, "扫到的页面文件只有 \(files.count) 个，扫描面坏了")
        let missing = Self.survivalGaps(in: files)
        XCTAssertTrue(missing.isEmpty,
                      "地板是按「这些整句键还活着」才降下来的；下面这些已经不在了 ⇒ "
                    + "要么文本真被删了（把地板抬回去并恢复文本），要么键被改写（同步本清单）：\n  "
                    + missing.joined(separator: "\n  "))
        XCTAssertEqual(Self.survivalGaps(in: files, keys: ["这一句仓里绝对不存在 P69 元测试夹具 %1$@"]).count, 1,
                       "假句没被抓到 ⇒ 上面那条绿不可信")
    }

    /// 纯函数：只吃 `[(路径, 内容)]`，坏样例在内存里造（不往仓库塞临时夹具）。
    static func survivalGaps(in files: [(path: String, content: String)],
                             keys: [String]? = nil) -> [String] {
        let haystack = files.map(\.content).reduce("") { $0 + $1 }
        return (keys ?? caliberKeysThatMustSurvive).filter { !haystack.contains($0) }
    }

    /// **修的是分类器的盲区，不是地板的数值**（P70；`75ae29c` 一度把它删掉，这一笔接回来）。
    ///
    /// `literalSlots(in:)` 靠"引号前面那截"判断一个字面量是常驻还是已藏进 ⓘ。
    /// 键化之后那句常驻长句前面会多一层查表调用 ——
    /// `message: localizedFormat("点击「重新分析」…", page)` ——
    /// 前缀不再以 `message:` 结尾 ⇒ 落到 `skipped`，**这条守卫就看不见它了**。
    /// 后果是守恒线每键化一句就掉一格：P69 合流掉 8 格、P70 又掉 1 格，
    /// 而那两句文本都**一字未少**地常驻上屏。
    /// 一直降地板等于给"看不见"记账；剥掉查表外壳再判，才是给"删掉了"记账。
    /// ⚠ 为什么用它而不是我那版：我 `7f6b5c7` 是往四条正则里插 `keyedLookup`，**只能剥一层**；
    /// 这里的循环能吃嵌套（`Text(localizedCount("…"))`），且判据本体一字不动 ⇒ 按能力合。
    static func stripLookupWrappers(_ prefix: String) -> String {
        var out = prefix
        let wrapper = try! NSRegularExpression(
            pattern: "(?:localizedCopy|localizedFormat|localizedCount)\\s*\\(\\s*$")
        while true {
            let range = NSRange(out.startIndex..., in: out)
            guard let hit = wrapper.firstMatch(in: out, options: [], range: range),
                  let cut = Range(hit.range, in: out) else { return out }
            out = String(out[..<cut.lowerBound])
        }
    }

    /// 双向元测试：包一层的常驻句必须算 visible、包一层的 tooltip 句必须算 tooltip、
    /// 没有任何渲染线索的仍然要 skipped（不许把"看不见"修成"全都算"）。
    func test_classifierLooksThroughTheLookupWrapper() {
        let visible = Self.literalSlots(in: #"                message: localizedFormat("点击重新分析开始扫描该目录。", page)"#)
        XCTAssertEqual(visible.map(\.slot), [.visible], "包了一层查表的常驻句没被认成常驻")
        let nested = Self.literalSlots(in: #"            Text(localizedCount("错误趋势，%lld 天", n))"#)
        XCTAssertEqual(nested.map(\.slot), [.visible], "两层包裹（Text 套 localizedCount）要能一路剥到 Text(")
        let bare = Self.literalSlots(in: #"        let x = "点击重新分析开始扫描该目录。""#)
        XCTAssertEqual(bare.map(\.slot), [.skipped], "没有渲染线索的也被算进去了 ⇒ 修过头")
    }

}