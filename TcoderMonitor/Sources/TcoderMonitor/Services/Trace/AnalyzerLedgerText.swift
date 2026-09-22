import Foundation

/// R10b 第 1 件：**把执行台账打到屏上**。
///
/// 要补的洞：`scan` 落的 JSON 里一直带着 `analyzerLedger`，但 `score` 的文本出口只打得出
/// 「失败路 N/5」那一行 —— 于是「这一路什么状态、花了多久、撞到哪条上限、失败原因原文」
/// 这四件事在文本里问不出来（而读文本的人与 AI 恰恰只有文本）。
///
/// 三条判据（`ReportTraceabilityTests` 逐条钉住）：
/// 1. **四态四样措辞**。`notRun` 一律写 `notRunPhrase` 那句「没跑（装配口没排进来）」，
///    不许写成「没问题 / 已通过」——「压根没排进来」与「跑通了没发现问题」处置完全相反。
/// 2. **不许把四态折叠成两态**（"有读数"与"没读数"）。表头那一行同时给出四个计数，
///    少一个计数就是一种折叠，所以四个计数**恒定全打**，为 0 也打。
/// 3. **台账缺席也要出声**（与 `CLIScoreText` 的 `provenanceLine` 同一个理由）：
///    旧报告没有这一格时打「未记录」，整段静默消失会被读成「这一屏不需要交代」。
///
/// 边界：这一段只说「这一路当时做了什么」，不说「这一路的结果好不好」——判定归判定。
/// 屏上出现的每一个数字都来自 `report.analyzerLedger` 本身，这里不现算第二份口径。
enum AnalyzerLedgerText {

    /// 表头定位串；取证与断言都靠它找到这一段。
    static let headerToken = "各路执行情况"
    /// `notRun` 的唯一措辞。**不许**在里面出现「没问题」「通过」「正常」任何判定词。
    static let notRunPhrase = "没跑（装配口没排进来）"

    /// 整段：表头 + 逐条。位置由调用方决定（`CLIScoreText` 把它放在「未量准」之后、综合分之前）。
    static func section(_ report: ProjectReport) -> [String] {
        guard let ledger = report.analyzerLedger else {
            return ["\(headerToken)：未记录 —— 这份报告出自没有台账格的结构，"
                    + "每一路的状态/耗时/上限/失败原因四件事都问不出来（不是五路都没跑）。"]
        }
        guard ledger.isEmpty == false else {
            return ["\(headerToken)：台账是空数组 —— 一行都没记下。"
                    + "这既不等于五路都跑通了，也不等于五路都没跑，只说明这份台账没写。"]
        }
        return ["\(headerToken) \(ledger.count) 路 · \(tally(ledger))" + countWarning(ledger) + "："]
            + ledger.map(row)
    }

    /// 逐条。**顺序沿用台账自己的顺序**（即 `AnalyzerLedger.sectionLabels` 的顺序），
    /// 这里不再排一次序：两处各排一次迟早分叉，而路名与顺序都只该有一份真值。
    static func row(_ record: AnalyzerRunRecord) -> String {
        var line = "  [\(statePhrase(record.state))] \(record.name)"
        switch record.state {
        case .ok:
            line += " · " + durationText(record.durationMs)
        case .partial:
            line += " · " + durationText(record.durationMs) + " · " + limitsText(record.limitsHit)
        case .failed:
            line += " · " + durationText(record.durationMs) + " · 原因原文：" + reasonText(record.failureReason)
        case .notRun:
            // 没跑就不该带着"像量过"的东西出场：耗时/原因/上限一律不渲染，
            // 与 `AnalyzerAttempt.record` 那一头的 nil 对齐（那头已经把这三格清空了）。
            line += " · 无耗时 · 无读数"
        }
        return line
    }

    /// 四态各自的措辞，四句互不相同。
    static func statePhrase(_ state: AnalyzerRunState) -> String {
        switch state {
        case .ok: return "跑完 · 没撞到上限"
        case .partial: return "跑完但只算部分测量"
        case .failed: return "跑了但失败"
        case .notRun: return notRunPhrase
        }
    }

    /// 四个计数**全部**打出（含 0）。少打一个就是把四态往两态折。
    static func tally(_ records: [AnalyzerRunRecord]) -> String {
        let states: [AnalyzerRunState] = [.ok, .partial, .failed, .notRun]
        return states.map { state in
            "\(tallyLabel(state)) \(records.filter { $0.state == state }.count)"
        }.joined(separator: " · ")
    }

    /// 「耗时」这一格：nil 说「未记录」，绝不说 0 —— 0 会被读成"跑得很快"，
    /// 而实情是那一路压根没计时（或没跑）。
    static func durationText(_ ms: Int?) -> String {
        guard let ms else { return "耗时未记录" }
        return "耗时 \(ms) ms"
    }

    /// 撞到的上限逐条原样列，不折叠成「有若干限制」。
    static func limitsText(_ limits: [String]?) -> String {
        guard let limits, limits.isEmpty == false else { return "撞上限的条目未记录" }
        return "撞到 \(limits.count) 条上限：" + limits.joined(separator: " / ")
    }

    static func reasonText(_ reason: String?) -> String {
        guard let reason, reason.isEmpty == false else { return "未记录（这一路只留下失败这件事，没留下原因）" }
        return reason
    }

    private static func tallyLabel(_ state: AnalyzerRunState) -> String {
        switch state {
        case .ok: return "跑完"
        case .partial: return "部分"
        case .failed: return "失败"
        case .notRun: return "没跑"
        }
    }

    /// 行数与路名清单不一致时必须自己喊出来：那说明装配口与台账分叉了，
    /// 这一屏的每一行都不可信（不是"少一行无所谓"）。
    private static func countWarning(_ records: [AnalyzerRunRecord]) -> String {
        let expected = CLIScan.sectionLabels.count
        guard records.count != expected else { return "" }
        return " · ⚠ 台账写了 \(records.count) 行，与路名清单的 \(expected) 路不一致 ⇒ 本段整体不可信"
    }
}
