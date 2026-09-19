import SwiftUI

// MARK: - 错误概览四指标

/// 日志计数的三态判定的唯一落点。
///
/// 之前这里传的是字符串 `"--"`，`MetricTile` 于是把它当成「有值」，
/// 于是「还没分析」也照样涂成红色——看上去像「错误很多」，其实一个文件都没读。
/// 现在传 `nil`，前景由组件强制回落到中性色。
enum LogReading {
    /// nil = 没跑过分析，或跑了但没有任何可读文件（③ 没证据）。
    /// 非 nil = 真实计数，**含真实的 0**（① 有数据，0 就是结论）。
    static func count(_ logs: LogSummary?, _ pick: (LogSummary) -> Int) -> Int? {
        guard let logs, logs.hasData else { return nil }
        return pick(logs)
    }

    /// ③ 的两句话：没跑过 ≠ 跑了没文件，得分清楚。
    static func caption(_ logs: LogSummary?, detail: (LogSummary) -> String) -> String {
        guard let logs else { return "尚未分析" }
        guard logs.hasData else { return "未发现日志文件" }
        return detail(logs)
    }

    /// 每千行代码错误数。分母不可信（没扫到代码行）时返回 nil，不给 0。
    static func perKiloCode(_ logs: LogSummary?, code: CodeMetrics?) -> Double? {
        guard let logs, logs.hasData, let code, code.codeLines > 0 else { return nil }
        return Double(logs.todayErrorCount) / (Double(code.codeLines) / 1000)
    }

    static func warningShareOfScanned(_ logs: LogSummary?) -> Double? {
        guard let logs, logs.hasData, logs.totalLinesScanned > 0 else { return nil }
        return Double(logs.warningCount) / Double(logs.totalLinesScanned)
    }
}

struct LogsMetricGrid: View {
    let logs: LogSummary?
    let code: CodeMetrics?

    private static let columns = [GridItem(.adaptive(minimum: Theme.Layout.tileMinWidth),
                                           spacing: Theme.Spacing.sm)]

    var body: some View {
        GlassSection("错误概览", subtitle: subtitle, icon: .riskSevere, trailing: riskBadge) {
            LazyVGrid(columns: Self.columns, spacing: Theme.Spacing.sm) {
                tile("今日错误", count: LogReading.count(logs) { $0.todayErrorCount },
                     caption: todayCaption,
                     role: Theme.Semantic.danger, icon: .riskWarning)
                tile("异常", count: LogReading.count(logs) { $0.exceptionCount },
                     caption: LogReading.caption(logs) { _ in "窗口内累计" },
                     role: Theme.Semantic.danger, icon: .riskSevere)
                tile("崩溃", count: LogReading.count(logs) { $0.crashCount },
                     caption: LogReading.caption(logs) { "其中 FATAL \(NumberFormat.grouped($0.fatalCount)) 条" },
                     role: Theme.Semantic.critical, icon: .crash)
                tile("警告", count: LogReading.count(logs) { $0.warningCount },
                     caption: warningCaption,
                     role: Theme.Semantic.warning, icon: .info)
            }
            if let perKilo = LogReading.perKiloCode(logs, code: code) {
                NoteLine("今日错误按代码规模归一为每千行 \(Live.fixed(perKilo, digits: 2)) 次；"
                         + "分母来自同一次扫描的有效代码行。")
            }
        }
    }

    private var subtitle: String {
        guard let logs else { return "尚未分析，下方数值一律 --" }
        guard logs.hasData else { return "没有可读的日志文件，下方数值一律 --" }
        return "扫描 \(NumberFormat.grouped(logs.totalLinesScanned)) 行 · \(NumberFormat.grouped(logs.scannedFiles.count)) 个文件"
    }

    private var riskBadge: AnyView? {
        guard let logs, logs.hasData else { return nil }
        return AnyView(RiskBadge(risk: logs.overallRisk))
    }

    private func tile(_ label: String, count: Int?, caption: String,
                      role: Theme.SemanticRole, icon: IconName) -> some View {
        MetricTile(label: label,
                   value: count == nil ? nil : NumberFormat.grouped(count ?? 0),
                   caption: caption,
                   tint: role.textColor,
                   systemImage: icon.rawValue)
    }

    private var todayCaption: String {
        LogReading.caption(logs) { _ in
            LogReading.perKiloCode(logs, code: code) != nil
                ? "错误 + 异常 + 崩溃，按代码规模归一见下"
                : "错误 + 异常 + 崩溃合计"
        }
    }

    private var warningCaption: String {
        LogReading.caption(logs) { _ in
            guard let share = LogReading.warningShareOfScanned(logs) else { return "窗口内累计" }
            return "占扫描行 \(NumberFormat.percent(share, precision: 2))"
        }
    }
}
