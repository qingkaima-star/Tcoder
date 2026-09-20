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

/// 错误概览：一行四枚 34pt 纯墨读数（今日错误 / 异常 / 崩溃 / 警告）+ 归一口径脚注。
///
/// **本页的主角**（风格契约 4）。四格横向排成 `ReadoutStrip`、列间发丝线，
/// 替掉原来 `LazyVGrid(adaptive 220)` 的四块灰盒 + 四份投影。
///
/// 四格一律纯墨，**不再按危险/严重涂色**。理由不是审美：旧写法把 `role: .danger`
/// 写死在调用点上，**零错误的项目那格照样是红的** —— 一个永远不关灯的颜色
/// 不携带任何信息，只会把整页读成一片报警（与 `PerformanceProcessTableCard.cpuTint`
/// 的注释同源：「给每个正常进程挂上颜色会把整张表读成一片警告」）。
/// 这一页的**判断**由 `trailing` 那枚 `RiskBadge(overallRisk)` 承担，
/// 它是色 + 文字 + 图标三通道；等级本身在高频错误行的 `SeverityBadge` 与
/// 趋势图的堆叠色上，那些地方颜色**随数据变**，才是语义。
struct LogsMetricGrid: View {
    let logs: LogSummary?
    let code: CodeMetrics?

    var body: some View {
        GlassSection("错误概览", subtitle: subtitle, icon: .riskSevere, trailing: riskBadge) {
            ReadoutStrip {
                tile("今日错误", count: LogReading.count(logs) { $0.todayErrorCount },
                     caption: todayCaption, icon: .riskWarning)
                DataBandSeparator()
                tile("异常", count: LogReading.count(logs) { $0.exceptionCount },
                     caption: LogReading.caption(logs) { _ in "窗口内累计" }, icon: .riskSevere)
                DataBandSeparator()
                tile("崩溃", count: LogReading.count(logs) { $0.crashCount },
                     caption: LogReading.caption(logs) { "其中 FATAL \(NumberFormat.grouped($0.fatalCount)) 条" },
                     icon: .crash)
                DataBandSeparator()
                tile("警告", count: LogReading.count(logs) { $0.warningCount },
                     caption: warningCaption, icon: .info)
            }
            if let perKilo = LogReading.perKiloCode(logs, code: code) {
                NoteLine("今日错误按代码规模归一为每千行 \(Live.fixed(perKilo, digits: 2)) 次；"
                         + "分母来自同一次扫描的有效代码行。")
            }
        }
    }

    private var subtitle: String {
        guard let logs else { return "尚未分析，下方数值一律 --" }
        guard logs.hasData else {
            // 全读不动时 hasData 为假，只说「没有可读的日志文件」会被听成「这个项目没有日志」，
            // 而真相是「有 N 份、N 份都读不动」——跳过条数与原因在这条路径上更该说出口。
            return "没有可读的日志文件，下方数值一律 --" + skippedNote(logs)
        }
        return "扫描 \(NumberFormat.grouped(logs.totalLinesScanned)) 行 · "
            + "\(NumberFormat.grouped(logs.scannedFiles.count)) 个文件" + skippedNote(logs)
    }

    /// 「已跳过 N 份读取失败（权限不足 ×2、文件已不存在 ×1）」。
    /// 带原因分布而不是只报个数：同样是被跳过，权限问题用户自己能修，文件消失是另一回事。
    private func skippedNote(_ logs: LogSummary) -> String {
        guard let failed = logs.readFailedFiles, failed.isEmpty == false else { return "" }
        let grouped = Dictionary(grouping: failed.map { $0.readFailure ?? "未记录原因" }, by: { $0 })
        let reasons = grouped.keys.sorted().map { "\($0) ×\(NumberFormat.grouped(grouped[$0]?.count ?? 0))" }
        return " · 已跳过 \(NumberFormat.grouped(failed.count)) 份读取失败（\(reasons.joined(separator: "、"))）"
    }

    private var riskBadge: AnyView? {
        guard let logs, logs.hasData else { return nil }
        return AnyView(RiskBadge(risk: logs.overallRisk))
    }

    /// `tint` 不传 = `MetricTile` 的默认值 `Surface.ink`（纯墨）。
    private func tile(_ label: String, count: Int?, caption: String,
                      icon: IconName) -> some View {
        MetricTile(label: label,
                   value: count == nil ? nil : NumberFormat.grouped(count ?? 0),
                   // **没数就不重复解释**。原来四格各挂一句「未发现日志文件」，
                   // 而本节副标题刚说过一次「没有可读的日志文件，下方数值一律 --」——
                   // 一句诚实性陈述被复述五遍，读起来像坏了，也把页面压成四块同构灰格。
                   // 口径只留一个权威落点（节副标题），这一改删的是**重复**，不是诚实性信息。
                   caption: count == nil ? nil : caption,
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
