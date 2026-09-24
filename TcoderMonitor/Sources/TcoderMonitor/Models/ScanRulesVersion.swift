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
        return defects
    }

    /// 戳号尾段 `rN` 的数字，用于判"从新到旧"的单调性；解析不出来返回 nil（交给形状那条出声）。
    static func rulesStampRevision(_ stamp: String) -> Int? {
        guard let dash = stamp.lastIndex(of: "-"), stamp[dash...].hasPrefix("-r") else { return nil }
        return Int(stamp[stamp.index(after: dash)...].dropFirst())
    }
}
