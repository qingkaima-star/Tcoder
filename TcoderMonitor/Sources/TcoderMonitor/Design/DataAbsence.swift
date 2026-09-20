import SwiftUI

// MARK: - 缺数据四态（全仓唯一一份）
//
// 这里回答的只有一个问题：**屏幕上的这个空位，到底为什么是空的**。
// 监控类 App 最贵的一类错就是把「没有证据」渲染成「0」或绿色对勾
// （AGENTS.md §4 /《40 WS-H》§7.3 /《20 WS-D》已在此抛过真问题）。
//
// 落点来由（#47，笔记《42》§14.2 的决策点）：这份枚举原本是 WS-L 的三态实现
// （`Views/CodeGit/CodeGitDesignKit.swift · DataAbsence`），有引用、无第二套，
// 按「零引用即删、有引用即上提」上提进 `Design/`，同时补上第四态 `indeterminate`：
// **除零（分母为 0、算不出来）与「没扫/没查」是两件事**，
// 两者共用同一个 `--`，用户就再也分不出「这项目真的没有」和「我们没查」。
//
// 四态各带一个中文字面（`term`，短到能进表格单元格）：
// `value`→实测值、`measuredEmpty`→未发现、`indeterminate`→算不出、`notAnalysed`→未分析。
// 《40》§7.3 的三态在这里对应：有数据 = `value`，「查了但空」= `measuredEmpty`，
// 「没查/失败/不适用」= `notAnalysed`；`indeterminate` 是本轮从第三态里**拆出来**的那一叉。
//
// 用法约定（页面侧）：
// - 数字位取 `display`；日期/名称这类**文字槽位**取 `textDisplay`
//   （`measuredEmpty` 在文字槽位里渲染成 `0` 会被读成假数字）；
// - 口径解释走 `help(denominator:)`，`indeterminate` 必须交代分母是什么；
// - 页面里不要再手写 `?? Theme.Placeholder.missingValue`——那是本轮收敛掉的散布写法，
//   由 `DesignAbsenceStateTests` 的扫描守卫钉住只减不增。

// MARK: - 四态

/// 一个数字（或一格文字）的四种在场状态。
enum DataAbsence: Equatable {
    /// 有数据：真值字符串，**含测得的 0**。
    case value(String)
    /// 查了、结果就是空：数字位给 0 并写明「未发现」。这是**结论**，不是缺证据。
    case measuredEmpty
    /// 算不出来：扫描做过、数据在场，但分母为 0（总行数 0、函数数 0、非合并提交 0……）。
    ///
    /// 与 `notAnalysed` 的区别是这一态**确实查过**，只是这个比值没有定义；
    /// 两者共用 `--` 就是本轮要消灭的语义塌陷。
    case indeterminate
    /// 没查：未扫描、未采样、不适用、查失败。一律 `--`，不给倾向色、不给对勾。
    case notAnalysed

    /// 各态的**中文字面**（短到能进表格单元格）。四态互不相同，由测试钉住。
    var term: String {
        switch self {
        case .value: return "实测值"
        case .measuredEmpty: return "未发现"
        case .indeterminate: return "算不出"
        case .notAnalysed: return "未分析"
        }
    }

    /// 数字位显示值：真值 / `0`（真 0 是结论）/ 「算不出」/ `--`。
    var display: String {
        switch self {
        case .value(let text): return text
        case .measuredEmpty: return NumberFormat.grouped(0)
        case .indeterminate: return term
        case .notAnalysed: return Theme.Placeholder.missingValue
        }
    }

    /// 文字槽位（日期、名称、路径）的显示值。
    ///
    /// 这些槽位里出现 `0` 会被读成假数字，所以 `measuredEmpty` 在这里改说「无记录」；
    /// 另外两态与数字位一致。
    var textDisplay: String {
        switch self {
        case .value(let text): return text
        case .measuredEmpty: return "无记录"
        case .indeterminate: return term
        case .notAnalysed: return Theme.Placeholder.missingValue
        }
    }

    /// 是否允许给出结论性措辞（绿色对勾、「无风险」之类）。
    ///
    /// `measuredEmpty` 允许（查过了、是空的，这本身就是结论）；
    /// `indeterminate` 与 `notAnalysed` 不允许——「算不出」和「没查」都撑不起一句安心话。
    var permitsConclusion: Bool {
        switch self {
        case .value, .measuredEmpty: return true
        case .indeterminate, .notAnalysed: return false
        }
    }

    /// 没证据时强制退回中性角色，不接受调用方给的倾向色——「没查」「算不出」都不该带倾向。
    /// 返回角色而不是 `Color`：动态色无法在单测里比较，角色名可以。
    func effectiveRole(_ role: Theme.SemanticRole) -> Theme.SemanticRole {
        permitsConclusion ? role : Theme.Semantic.neutral
    }

    func tint(_ role: Theme.SemanticRole) -> Color { effectiveRole(role).textColor }

    /// 悬停口径：`value` 返回 nil（有值不必解释），其余三态各给一句。
    /// `denominator` 只被 `indeterminate` 用，用来回答「哪个分母是 0」。
    func help(denominator: String? = nil) -> String? {
        switch self {
        case .value:
            return nil
        case .measuredEmpty:
            return "已完成扫描，这一项确实没有命中任何记录——这个 0 是测得的结果，不是没查。"
        case .indeterminate:
            return "算不出来：分母（\(denominator ?? "该项的分母")）为 0，这个比值没有定义。"
                + "这里既不是没扫，也不是 0。"
        case .notAnalysed:
            return "还没查到：这一项的扫描或采样没有完成，先跑一次分析、或等首帧到达。"
        }
    }

    /// 由「可选读数」构造：有值走 `value`，`nil` 归入 `absent` 指定的那一态（默认「没查」）。
    ///
    /// 把态写成**形参**而不是写死，是为了让每个调用点都被迫表态：
    /// 你屏幕上这个空位到底是「没查」还是「查了没有」，必须选一个。
    static func optional(_ raw: String?, absent: DataAbsence = .notAnalysed) -> DataAbsence {
        guard let raw else { return absent }
        return .value(raw)
    }
}
