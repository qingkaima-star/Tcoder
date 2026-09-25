import Foundation

// OWNER: 总工（RD-81）—— 检测规则版本台账。从 `Models/ScanProvenance.swift` 整块另起文件，
// 原因与本仓每条「新增实现另起新文件」一样：`ScanProvenance.swift` 离 `SourcesSizeAuditTests`
// 的 400 行闸门只剩几十行，把台账 + 校验塞进去会把下一个动契约的人顶到线上。
//
// 为什么要有这一格（台账卷六 §94 / RD-81）：`rulesVersion` 这一栏的本意是
// 「这份报告是哪一版判据产的」。可它自 `9932a19`（RD-30 立溯源块）以来就是**一行手写字面量**，
// 整整一轮检测正确性整改（RD-01…RD-79，换了十几把尺子）**一次都没挪过**——
// 于是今天带 RD-79 判据的报告仍在说 `2026.09-r1`，那句不是「没更新」，是**假话**。
// 而守卫只钉戳的**形状**（`ScanProvenanceTests.testRulesStampIsWellFormed`），
// 形状对了就永远绿 ⇒ 这一格此前**没有任何读者能证伪**。

extension ScanProvenance {

    /// 一版规则戳：戳号 + 这一版**收进了哪些判据条目**。
    /// `landed` 必须点名台账 RD 号（由 `rulesLedgerDefects` 判），
    /// 不许写「日常维护」或「若干修复」这类既查不出错又读不出信息的话。
    struct RulesVersion: Equatable, Sendable {
        var stamp: String
        var landed: String
    }

    /// 规则版本台账，**最新一格在最前**。
    ///
    /// 抬戳的唯一姿势：在这里加一行，别去改 `rulesVersionStamp`（它是从这里取的第一格）。
    static let rulesChangeLedger: [RulesVersion] = [
        RulesVersion(
            stamp: "2026.09-r3",
            landed: "RD-80 修：三元的 `?` 与 `:` 分行写时以前**不计判定**（尺子逐行数问号），"
                + "同一句话换行前后 CC 差一档 ⇒ 现在由相邻两行配对补那一分（配不到不补、一枚 `?` 只补一次）。"
                + "受影响读数：函数 CC、平均 CC、复杂度榜与热点榜排序（`docs/口径与已知限制.md` §4.7）"
        ),
        RulesVersion(
            stamp: "2026.09-r2",
            landed: "RD-79 两笔（`export const` 箭头整类漏认；无花括号的箭头体不得借下一条语句的花括号，"
                + "函数数／平均 CC／热点榜分母同时变）＋ RD-80 立案（跨行三元不计判定，写进 `docs/口径与已知限制.md` §4.7）"
        ),
        RulesVersion(
            stamp: "2026.09-r1",
            landed: "RD-30／RD-31 立报告溯源块时的判据基线。"
                + "⚠ 此后 RD-01…RD-79 十几笔判据改动都没抬戳（台账卷六 §94 记的就是这笔漏抬）"
        ),
    ]

    /// 检测规则戳 = 台账最新一格。**不再允许手写字面量**：
    /// 「挪了戳没记账」与「记了账没挪戳」这两件事由 `rulesLedgerDefects` 判红（同一处装配 ⇒ 两半同时成立）。
    ///
    /// 射程边界（写清楚，别把它当闸门用）：这一格挡不住**「改了判据什么都不动」**。
    /// 要挡那一格，只能按判据源文件的摘要上闸，而摘要会在**纯注释改动**上误报 ——
    /// 本仓那条「会误报的粗尺不上闸」（守卫失效第 24 类）明令不许那么做。
    /// 所以那一格靠两件事兜：评审（动 `Services/**` 判据的 PR 必须问一句戳抬没抬），
    /// 以及对表（同一提交复扫读数变了就说明该抬 —— 卷六 §93 那三张对照表就是这个用途的样板）。
    static let rulesVersionStamp: String = ScanProvenance.rulesChangeLedger.first?.stamp ?? "未记录"

    /// 台账自检（**纯函数**，元测试可以喂合成输入，不必去改产品常量）。
    /// 返回缺陷清单；空数组 = 台账自洽。设计成"返回原因而不是布尔"，
    /// 是因为红的时候必须能一眼说出**是哪一格**坏了（只报计数不报位置的守卫第二天没人能找到那一条）。
    static func rulesLedgerDefects(current: String, ledger: [RulesVersion]) -> [String] {
        var defects: [String] = []
        if ledger.isEmpty {
            defects.append("台账是空的 ⇒ 上屏的规则戳「\(current)」没有任何一格支撑")
            return defects
        }
        if current != ledger[0].stamp {
            defects.append("上屏的戳「\(current)」不是台账最新一格「\(ledger[0].stamp)」"
                + " ⇒ 要么挪了戳忘了记账，要么改了戳的字面量没走台账")
        }
        var seen = Set<String>()
        var previousRevision: Int?
        for entry in ledger {
            if !seen.insert(entry.stamp).inserted { defects.append("戳号重复：\(entry.stamp)") }
            if rulesStampRevision(entry.stamp) == nil {
                defects.append("戳号形状不合 `YYYY.MM-rN`：\(entry.stamp)")
            }
            if entry.landed.range(of: "RD-") == nil {
                defects.append("「\(entry.stamp)」那一格没点名任何判据条目（要写台账 RD 号，不许写「若干修复」这种话）")
            }
            guard let revision = rulesStampRevision(entry.stamp) else { continue }
            if let previous = previousRevision, revision >= previous {
                defects.append("台账顺序不是从新到旧：\(entry.stamp) 排在了更新的一格后面")
            }
            previousRevision = revision
        }
        // 最新一格点名的 RD 号要比**任何旧格**都新。为什么单独要这一条：
        // 「戳号在抬」只证明有人动过那一行，不证明他记的是**这一版真正收进去的东西**——
        // 抄一段旧条目同样能把戳号抬上去。有了这条，抬戳必须附带比历史更大的 RD 号。
        // 已知限度：RD 号是**递增的案号**，所以"更大 = 更新"成立；将来若有人插编号会失真。
        // 最新一格一枚 RD 号都没点名时**不再叠加**这一条 —— 上面那条命名判据已经出声，
        // 一行的毛病报两条会把既有反例的期望值搅浑（`testDefectRequiresAnEntryToNameLedgerItems` 就钉着这个）。
        let historyNewest = ledger.dropFirst().flatMap { $0.landed.rdNumbers() }.max() ?? 0
        if let headNewest = ledger[0].landed.rdNumbers().max(), headNewest < historyNewest {
            defects.append("最新一格「\(ledger[0].stamp)」点名的判据只到 RD-\(headNewest)，"
                + "比它下面任何一格（RD-\(historyNewest)）都旧 ⇒ 抬了戳却没记新判据")
        }
        return defects
    }

    /// 戳号尾段 `rN` 的数字，用于判"从新到旧"的单调性；解析不出来返回 nil（交给形状那条出声）。
    static func rulesStampRevision(_ stamp: String) -> Int? {
        guard let dash = stamp.lastIndex(of: "-"), stamp[dash...].hasPrefix("-r") else { return nil }
        return Int(stamp[stamp.index(after: dash)...].dropFirst())
    }
}

extension String {
    /// 本行里所有 `RD-<数字>` 的数字部分。只认 `RD-` 前缀，
    /// 所以戳号里的 `r3`、日期里的 `09`、版本号里的 `.9` 都不会被误当成案号。
    func rdNumbers() -> [Int] {
        var numbers: [Int] = []
        var search = self[...]
        while let hit = search.range(of: "RD-") {
            search = search[hit.upperBound...]
            if let value = Int(search.prefix(while: { $0.isNumber })) { numbers.append(value) }
        }
        return numbers
    }
}
