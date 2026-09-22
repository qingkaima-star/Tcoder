import Foundation

/// 一份报告里**每一路分析器的执行台账**（整改意见 §十一「每个分析器的状态 / 耗时 / 上限 / 失败原因」）。
///
/// 为什么要有它：`ProjectReport` 原来只有 `failedSections`（中文路名）与 `code.durationMs`（唯一一路耗时）。
/// 于是"这一路没出声"这件事分不清是**跑通了没发现问题**、**跑挂了**、**撞到上限只量到一半**，
/// 还是**压根没跑** —— 而这四件事的处置完全不同。用户要的"哪些没量准"必须能逐路问出来。
///
/// 一台台账只有一个装配口：`AnalyzerLedger.timed` 收成 `AnalyzerAttempt`，
/// 四态判定只写在 `AnalyzerAttempt.record` 里。CLI 与 GUI 两条装配路共用它（AGENTS §8 第 2 条）。
enum AnalyzerRunState: String, Codable, Sendable {
    /// 跑完了、没撞到上限：读数可信。
    case ok
    /// 跑完了但**撞到上限或不完整**：读数只能算部分测量，`limitsHit` 里写明撞了哪一条。
    case partial
    /// 跑了但失败：`failureReason` 是原因原文（不是中文路名）。
    case failed
    /// **没跑**：不许渲染成"这一维没问题"，也不许当成失败 —— 它意味着装配口没把这一路排进去。
    case notRun
}

struct AnalyzerRunRecord: Codable, Equatable, Sendable {
    /// 路名，取值只能是 `CLIScan.sectionLabels` 里那五个（一条守卫盯着同源）。
    var name: String
    var state: AnalyzerRunState
    var durationMs: Int? = nil
    var limitsHit: [String]? = nil
    var failureReason: String? = nil
}

struct AnalyzerAttempt: Sendable {
    var label: String
    /// 缺席是**显式事实**，不由推断得出：只有装配口明说"这一路没排进来"才写 `false`。
    var didRun: Bool = true
    var durationMs: Int? = nil
    var failureReason: String? = nil
    var limitsHit: [String] = []

    /// 四态判定只在这一处发生。优先级：没跑 > 失败 > 部分 > 通过。
    var record: AnalyzerRunRecord {
        if !didRun {
            return AnalyzerRunRecord(name: label, state: .notRun, durationMs: nil,
                                     limitsHit: nil, failureReason: nil)
        }
        if let failureReason {
            return AnalyzerRunRecord(name: label, state: .failed, durationMs: durationMs,
                                     limitsHit: limitsHit.isEmpty ? nil : limitsHit,
                                     failureReason: failureReason)
        }
        return AnalyzerRunRecord(name: label,
                                 state: limitsHit.isEmpty ? .ok : .partial,
                                 durationMs: durationMs,
                                 limitsHit: limitsHit.isEmpty ? nil : limitsHit,
                                 failureReason: nil)
    }
}

enum AnalyzerLedger {

    /// 五路的中文名**只这一份**。CLI 的 `CLIScan.sectionLabels` 转发它，GUI 的失败路名与台账路名也引用它。
    ///
    /// 为什么单独钉：`AppState` 原来在 `Self.attempt("日志分析")` 与 `Self.attempt("覆盖率读取")`
    /// 里各写一遍路名，而 `failedSections` 那五行写的是"错误日志""测试覆盖率" ——
    /// 同一次失败在界面上叫一个名、在报告里叫另一个名，而对表尺子逐字段比 `failedSections`，
    /// 台账一上屏就把这个分叉变成了硬红。
    static let sectionLabels = ["代码扫描", "Git 分析", "错误日志", "依赖分析", "测试覆盖率"]

    /// 跑一段分析，同时把它收成台账需要的那份形状（值本身另外返回给调用方落进报告）。
    ///
    /// 计时住在这里而不是各分析器里：`durationMs` 要量的是"这一路从被派出去到交回"，
    /// 而分析器内部的计时（如 `CodeMetrics.durationMs`）不含它自己的调度与解码 ——
    /// 两枚读数同量级但不同源，展示层保留哪一枚由 R10 后续定，这里先都留着。
    static func timed<T: Sendable>(
        _ label: String,
        _ work: @Sendable () async throws -> T
    ) async -> (value: T?, attempt: AnalyzerAttempt) {
        let startedAt = Date()
        do {
            let value = try await work()
            return (value, AnalyzerAttempt(label: label, durationMs: elapsed(since: startedAt)))
        } catch {
            return (nil, AnalyzerAttempt(label: label, durationMs: elapsed(since: startedAt),
                                         failureReason: error.localizedDescription))
        }
    }

    /// 台账逐条落进报告；`limits` 由调用方按"哪一路报了自己撞上限"喂进来。
    static func records(from attempts: [AnalyzerAttempt]) -> [AnalyzerRunRecord] {
        attempts.map(\.record)
    }

    private static func elapsed(since startedAt: Date) -> Int {
        max(1, Int(Date().timeIntervalSince(startedAt) * 1000))
    }
}
