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
    /// 页头那枚时间窗口的天数。ⓘ 里"历史报告在窗口之外"那一句要说清窗口有多长，
    /// 所以它必须由 `LogsView` 传进来，而不是在这里写一个常量 —— 写了就会在用户
    /// 切到 30 天时说出一句和屏上不一致的话。
    var windowDays: Int = 7

    var body: some View {
        GlassSection("错误概览", subtitle: subtitle, subtitleHelp: windowCaliberNote,
                     icon: .riskSevere, trailing: headerTrailing) {
            ReadoutStrip {
                tile("今日错误", count: LogReading.count(logs) { $0.todayErrorCount },
                     caption: todayCaption, icon: .riskWarning)
                DataBandSeparator()
                tile("异常", count: LogReading.count(logs) { $0.exceptionCount },
                     caption: LogReading.caption(logs) { _ in "窗口内累计" }, icon: .riskSevere)
                DataBandSeparator()
                tile("崩溃", count: LogReading.count(logs) { $0.crashCount },
                     // 读数句在 Services 侧拼（`LogSummary.crashTileCaption`）：
                     // 这里以前是「其中 FATAL n 条」，读者看不出这个数**只含窗口内有证据的那些**。
                     caption: LogReading.caption(logs) { $0.crashTileCaption },
                     icon: .crash)
                DataBandSeparator()
                tile("警告", count: LogReading.count(logs) { $0.warningCount },
                     caption: warningCaption, icon: .info)
            }
            if let perKilo = LogReading.perKiloCode(logs, code: code) {
                // **留短藏长**：屏上留这个归一后的数与「按代码规模」这五个字，
                // 分母是哪一批行（同一次扫描的有效代码行）进 ⓘ。整句是完整句，不是半句键。
                NoteLine(localizedFormat("按代码规模归一：每千行 %1$@ 次", Live.fixed(perKilo, digits: 2)),
                         help: localizedFormat("今日错误按代码规模归一为每千行 %1$@ 次；分母来自同一次扫描的有效代码行。",
                                           Live.fixed(perKilo, digits: 2)))
            }
        }
    }

    /// 卡头副标题旁那枚 ⓘ（RD-82；台账卷五 §92「另立一项」欠的那句界面说明）。
    /// 为什么非要有这句：副标题「扫描 N 行 · M 个文件」里的 N 是**这些被挑中的文件的全部扫描行**，
    /// 而页头那个「时间窗口 30 天」框的是**挑哪些文件**（按文件 mtime），不逐行按时间过滤
    /// —— 机制与准确读法写在 `docs/口径与已知限制.md` §4.8，可屏上从没说过，
    /// 于是读者会把「每千行日志 N 个错误」读成「最近 N 天的错误率」：数字是真的，话不是。
    /// 槽位选 `GlassSection.subtitleHelp:`（既有）而不是新写一行常驻长句：
    /// 风格契约 8 是「碎文案收进 ⓘ」，而 A 棘轮 `visibleCaliberCeiling` 只管屏上长句。
    private var windowCaliberNote: String {
        localizedFormat("时间窗口按文件挑、不逐行过滤：只读最近 %1$@ 天内被改动过的日志文件，文件一旦进来就整份计入 ⇒ 「每千行日志 N 个错误」与「扫描 N 行」的分母是这些文件的全部扫描行，不是最近 %1$@ 天的日志行。",
                        String(windowDays))
    }

    private var subtitle: String {
        guard let logs else { return "尚未分析，下方数值一律 --" }
        guard logs.hasData else {
            // 全读不动时 hasData 为假，只说「没有可读的日志文件」会被听成「这个项目没有日志」，
            // 而真相是「有 N 份、N 份都读不动」——**跳过份数**在这条路径上更该说出口，
            // 原因分布（权限不足 / 文件已不存在 ×N）改挂卡头那枚 ⓘ（盘点表 G 组：份数不许藏）。
            return localizedCopy("没有可读的日志文件，下方数值一律 --") + skippedCountNote(logs)
        }
        return localizedFormat("扫描 %1$@ 行 · %2$@ 个文件",
                              NumberFormat.grouped(logs.totalLinesScanned),
                              NumberFormat.grouped(logs.scannedFiles.count)) + skippedCountNote(logs)
    }

    /// 「已跳过 N 份读取失败」——份数留在屏上，它决定这一页的 0 能不能信。
    private func skippedCountNote(_ logs: LogSummary) -> String {
        guard let failed = logs.readFailedFiles, failed.isEmpty == false else { return "" }
        return localizedFormat(" · 已跳过 %1$@ 份读取失败", NumberFormat.grouped(failed.count))
    }

    /// 进 ⓘ 的完整句：同样是被跳过，权限问题用户自己能修，文件消失是另一回事。
    ///
    /// 崩溃证据那一句（含"为什么崩溃数比崩溃通道文件数小"）也挂这里 ——
    /// 屏上只留四枚读数与一句副标题，长解释按风格契约 8 收进 ⓘ。
    private var skippedReasonHelp: String? {
        guard let logs else { return nil }
        var lines: [String] = []
        if let failed = logs.readFailedFiles, failed.isEmpty == false {
            let grouped = Dictionary(grouping: failed.map { $0.readFailure ?? localizedCopy("未记录原因") }, by: { $0 })
            let reasons = grouped.keys.sorted().map { "\($0) ×\(NumberFormat.grouped(grouped[$0]?.count ?? 0))" }
            lines.append(localizedFormat("已跳过 %1$@ 份读取失败，原因分布：%2$@。",
                                         NumberFormat.grouped(failed.count),
                                         reasons.joined(separator: localizedCopy("、"))))
        }
        if logs.hasCrashEvidenceToReport {
            // 八种原因**逐条分开**上屏：整句由 `CrashEvidenceReadout` 从落盘的九格快照按名字接回
            // （RD-60 那座桥）。判"有没有可说的"与 CLI 用的是同一个入口（`hasCrashEvidenceToReport`），
            // 视图这里只接已经拼好的整句，一个汉字都不在这里拼。
            lines.append(logs.crashEvidenceFootnote(windowDays: windowDays))
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// 卡头右侧：ⓘ（跳过原因分布）在前、风险徽标在后，两者都可能缺席。
    /// `GlassSection` 只有一个 `trailing:` 槽，所以两处共用一个 ViewBuilder。
    private var headerTrailing: AnyView? {
        AnyView(HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
            if let help = skippedReasonHelp { CopyHelpBadge(help) }
            if let logs, logs.hasData { RiskBadge(risk: logs.overallRisk) }
        })
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
            return localizedFormat("占扫描行 %1$@", NumberFormat.percent(share, precision: 2))
        }
    }
}
