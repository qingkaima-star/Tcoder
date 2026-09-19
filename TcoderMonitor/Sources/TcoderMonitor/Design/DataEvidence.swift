import SwiftUI

// MARK: - 缺证据三态（把"不许把没查画成安全"变成机制）
//
// 为什么要有这个文件：AGENTS.md §4 与 WS-H §7.3 都写了「数据缺失不要显示为 0」，
// 但它是一条**靠自觉的约定**——上一轮实测，`DashboardView` 里同一块卡片 CPU/内存
// 正确显示 `--`，而「今日错误」却写 `?? 0`，同一屏自相矛盾。
// 三条流重样时各自在页面里补了一份这套逻辑（WS-L 的 `DataAbsence`、
// WS-M 的 `SampleContext`），说明这是真需求，只是没地方放。
//
// 放这里之后，"没证据"这件事在类型上就只有三种写法，页面拿不到"随便一个 String"的口子。
//
// 命名说明：整个基座都嵌在 `Theme.` 里。页面目录里已经飘着 `DataAbsence`、`ChartAxis`、
// `ChartSeries`、`LiveNumber` 这些顶层类型（WS-M 那份还没合进 main），
// Design 再造同名顶层类型会在下一次 merge 时**重声明**、把全仓编译弄红。

extension Theme {
    /// 一个数字/结论背后的证据状态。三态语义**不可合并**：
    /// 把 ③ 渲染成 0 或绿色结论，等于把"没有证据"说成"没有问题"。
    enum Evidence: Equatable {
        /// ① 有数据。字符串是已经格式化好的真值，**含测得的 0**。
        case measured(String)
        /// ② 扫过了、确实为空：显示 `0`，并配「未发现」这类措辞。
        case scannedEmpty
        /// ③ 没扫 / 不适用 / 扫失败：显示 `--`，强制中性，禁止任何结论性表达。
        case notCollected

        /// 「查了但是空的」默认文案。
        static let scannedEmptyCopy = "未发现"

        /// 数字位显示值。
        var displayText: String {
            switch self {
            case .measured(let text): return text
            case .scannedEmpty: return NumberFormat.grouped(0)
            case .notCollected: return Theme.Placeholder.missingValue
            }
        }

        /// 是否属于"没有证据"。② 有证据（证据就是"扫过且为空"），③ 没有。
        var isAbsent: Bool {
            if case .notCollected = self { return true }
            return false
        }

        /// 是否允许给出结论性表达（绿色对勾、「无风险」「一切正常」）。
        /// ② 允许——"扫过没有"本身就是结论；③ 不允许。
        var permitsConclusion: Bool { !isAbsent }

        /// 缺证据时强制退回中性角色，**盖掉调用方给的倾向色**。
        /// 返回角色而不是 `Color`：动态 `NSColor` 包出的 `Color` 两次取值不相等，
        /// 拿它断言测不出东西（上一轮踩过）。
        func role(_ preferred: Theme.SemanticRole) -> Theme.SemanticRole {
            isAbsent ? Theme.Semantic.neutral : preferred
        }

        func tint(_ preferred: Theme.SemanticRole) -> Color {
            role(preferred).textColor
        }

        /// 从可选值构造：`nil` 一律是「没证据」，**不会**被折叠成 0。
        /// 差分型指标（每秒速率、占用增量）只有首个样本时算不出，就是这个入口。
        static func optional<Value>(_ raw: Value?, format: (Value) -> String) -> Evidence {
            guard let raw else { return .notCollected }
            return .measured(format(raw))
        }

        /// 整数计数的专用入口（不与泛型 `optional(_:format:)` 抢推断）。
        /// 叫 `optionalCount` 而不是重载 `optional`：两者都能收 `nil`，
        /// 重载后 `optional(nil)` 在调用点歧义、编译器还会要求显式特化泛型参数。
        static func optionalCount(_ raw: Int?, scannedEmpty: Bool = false) -> Evidence {
            switch (raw, scannedEmpty) {
            case (let value?, _): return .measured(NumberFormat.grouped(value))
            case (nil, true): return .scannedEmpty
            case (nil, false): return .notCollected
            }
        }
    }
}

extension Theme {
    /// WS-H §7.3 的三态：有数据 = 真值（**含真 0**）；查了但是空的 = `0` + 「未发现」；
    /// 没查 / 查失败 = 下面这个占位。把第三态写成 0，就是把"没证据"伪装成"结论"。
    enum Placeholder {
        static let missingValue = "--"
    }
}
