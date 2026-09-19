import SwiftUI

/// 总览首屏。
///
/// 本轮把每一块「平涂卡 + 1px 描边」换成基座的内容层（标准材质 + `Radius.card` 16
/// + 20pt 内边距，靠间距与材质分层、不再描边），并把所有「没数据」的地方从 0 / 红色
/// 改成 `--` + 中性 + 明说原因的三态句式（WS-H §7.3）。
/// 外壳件（评分环、占比条、读数行、横幅）在 `Views/Shell/**`。
struct DashboardView: View {
    @Environment(AppState.self) private var state

    private var report: ProjectReport? { state.selectedReport }
    private var snapshot: SystemSnapshot? { state.monitor.latestSnapshot }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HealthHeroCard(health: report?.health)
                metricGrid
                LazyVGrid(columns: cardColumns, alignment: .leading,
                          spacing: Theme.Spacing.gutter) {
                    codeScaleCard
                    livePerformanceCard
                    recentCommitsCard
                    topErrorsCard
                }
                if let error = state.lastError {
                    failureCard(error)
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.top, Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.xl)
            .frame(maxWidth: Theme.Layout.maxWidthOverview)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
    }

    /// 栅格列宽全部走基座锚点，不再写死「一行四列」：窗口收窄时自动折行（WS-H §3.2）。
    private var tileColumns: [GridItem] {
        [GridItem(.adaptive(minimum: Theme.Layout.tileMinWidth),
                  spacing: Theme.Spacing.gutter)]
    }

    private var cardColumns: [GridItem] {
        [GridItem(.adaptive(minimum: Theme.Layout.twoColumnMinWidth),
                  spacing: Theme.Spacing.gutter)]
    }

    // MARK: 指标 tile

    /// 四枚 tile 的三态口径：
    /// 「没有测到」一律传 `value: nil`，由 `MetricTile` 渲染成 `--` + 中性色；
    /// 真 0 是结论，照实传 `"0"`。原来 CPU 缺值传 `"--"` 而今日错误缺值传 `0`，
    /// 同一块屏上两种自相矛盾的说法并存（WS-I §3.4）。
    private var metricGrid: some View {
        LazyVGrid(columns: tileColumns, spacing: Theme.Spacing.gutter) {
            cpuTile
            memoryTile
            errorTile
            commitTile
        }
    }

    private var cpuTile: some View {
        MetricTile(
            label: "CPU",
            value: snapshot.map { String(Int(($0.cpuUsage * 100).rounded())) },
            unit: "%",
            caption: snapshot.map {
                "\(NumberFormat.grouped($0.cpuCoreCount)) 核 · 负载 \(String(format: "%.2f", $0.loadAverage1))"
            },
            tint: Theme.Semantic.info.textColor,
            systemImage: IconName.cpu.rawValue
        )
    }

    private var memoryTile: some View {
        MetricTile(
            // 「Memory」→「内存」：WS-H §7.1 点名的必修项
            label: "内存",
            value: snapshot.map { ByteFormat.string($0.memoryUsedBytes, precision: 1) },
            caption: snapshot.map {
                "共 \(ByteFormat.string($0.memoryTotalBytes, precision: 0)) · "
                    + NumberFormat.percent($0.memoryFraction, precision: 0)
            },
            tint: Theme.Semantic.info.textColor,
            systemImage: IconName.memory.rawValue
        )
    }

    private var errorTile: some View {
        let logs = report?.logs
        let caption: String?
        if logs?.hasData == true {
            caption = "崩溃 \(NumberFormat.grouped(logs?.crashCount ?? 0)) · "
                + "异常 \(NumberFormat.grouped(logs?.exceptionCount ?? 0))"
        } else {
            caption = logs == nil ? ShellCopy.notAnalyzed("错误日志")
                : ShellCopy.cannotAnalyze("未接入任何日志文件")
        }
        return MetricTile(
            label: "今日错误",
            value: logs?.hasData == true ? NumberFormat.grouped(logs?.todayErrorCount ?? 0) : nil,
            caption: caption,
            tint: Theme.Semantic.danger.textColor,
            systemImage: IconName.riskWarning.rawValue
        )
    }

    private var commitTile: some View {
        MetricTile(
            label: "最近提交",
            value: report?.git.map {
                DateFormat.sinceDescription($0.lastCommitAt).replacingOccurrences(of: " 前", with: "")
            },
            caption: report?.git.map {
                "\(NumberFormat.grouped($0.totalCommits)) 次提交 · "
                    + "\(NumberFormat.grouped($0.activeAuthorCount)) 位贡献者"
            } ?? ShellCopy.notAnalyzed("Git 历史"),
            tint: Theme.Semantic.info.textColor,
            systemImage: IconName.git.rawValue
        )
    }

    // MARK: 内容卡

    private var codeScaleCard: some View {
        GlassSection("代码规模",
                     subtitle: report?.code.map { "最近扫描 \(DateFormat.sinceDescription($0.scannedAt))" },
                     icon: .code) {
            if let code = report?.code {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xxs) {
                        Text(NumberFormat.grouped(code.codeLines))
                            .font(Theme.Typo.metricNumber.font)
                            .foregroundStyle(Theme.Semantic.info.textColor)
                        Text("有效代码行")
                            .font(Theme.Typo.label.font)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(code.languages.prefix(5)) { share in
                        // 占比条统一走基座件：全仓原本有三套（我的 LanguageBar、
                        // WS-L 的 DataShareBarRow、基座的 Theme.Share.Row），
                        // 基座那套正是为取代前两套而建却零引用。取色也必须走基座的
                        // 稳定键入口，页面不再自带一份哈希。
                        Theme.Share.Row(
                            label: share.language,
                            fraction: share.share,
                            percentText: NumberFormat.percent(share.share, precision: 0))
                    }
                    HStack(spacing: Theme.Spacing.md) {
                        StatLine(label: "文件", value: NumberFormat.grouped(code.totalFiles))
                        StatLine(label: "注释行", value: NumberFormat.grouped(code.commentLines))
                        StatLine(label: "空行", value: NumberFormat.grouped(code.blankLines))
                    }
                    coverageStrip
                }
            } else {
                EmptyStateView(icon: IconName.code.rawValue,
                               title: ShellCopy.notAnalyzed("代码规模"),
                               message: "选择项目目录后自动统计。")
            }
        }
    }

    private var livePerformanceCard: some View {
        GlassSection("实时性能",
                     subtitle: "本机 · 每 1.5 秒采样",
                     icon: .performance,
                     trailing: AnyView(
                        GlassButton("立即采样", icon: .refresh, style: .bordered) {
                            state.monitor.sampleNow()
                        }
                     )) {
            if state.monitor.history.count > 2 {
                CPUHistoryChart(snapshots: Array(state.monitor.history.suffix(90)))
                    .frame(minHeight: Theme.Layout.chartMinHeight)
                HStack(spacing: Theme.Spacing.md) {
                    StatLine(label: "磁盘", value: snapshotRate(snapshot?.diskReadBytesPerSecond,
                                                                snapshot?.diskWriteBytesPerSecond,
                                                                rate: ByteFormat.rate))
                    StatLine(label: "网络", value: snapshotRate(snapshot?.networkInBytesPerSecond,
                                                                snapshot?.networkOutBytesPerSecond,
                                                                rate: ByteFormat.bitRate))
                    StatLine(label: "进程",
                             value: snapshot.map { NumberFormat.grouped($0.processCount) }
                                 ?? Theme.Placeholder.missingValue)
                }
            } else {
                EmptyStateView(icon: IconName.performance.rawValue,
                               title: "正在采集…",
                               message: "首个采样点到达后显示曲线。")
            }
        }
    }

    private var recentCommitsCard: some View {
        GlassSection("最近提交", subtitle: branchSubtitle, icon: .git) {
            if let git = report?.git, !git.recentCommits.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    ForEach(git.recentCommits.prefix(6)) { commit in
                        CommitRow(commit: commit)
                        if commit.id != git.recentCommits.prefix(6).last?.id {
                            Divider()
                        }
                    }
                }
            } else {
                EmptyStateView(
                    icon: IconName.git.rawValue,
                    title: report?.git == nil ? ShellCopy.notAnalyzed("Git 历史")
                                             : ShellCopy.scannedButFoundNone("提交记录"),
                    message: ShellCopy.cannotAnalyze("该目录不是 Git 仓库，或提交记录为空")
                )
            }
        }
    }

    private var topErrorsCard: some View {
        GlassSection("高频错误",
                     subtitle: report?.logs.map {
                         "共 \(NumberFormat.grouped($0.errorCount + $0.exceptionCount)) 条错误"
                     },
                     icon: .logs) {
            if let logs = report?.logs, logs.hasData, !logs.topErrors.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    ForEach(logs.topErrors.prefix(5)) { cluster in
                        ErrorClusterRow(cluster: cluster)
                    }
                }
            } else {
                EmptyStateView(
                    icon: (report?.logs?.hasData == true) ? IconName.noRisk.rawValue
                        : IconName.emptyTray.rawValue,
                    title: (report?.logs?.hasData == true)
                        ? ShellCopy.scannedButFoundNone("错误")
                        : ShellCopy.notAnalyzed("错误日志"),
                    message: (report?.logs?.hasData == true)
                        ? "已扫描 \(NumberFormat.grouped(report?.logs?.scannedFiles.count ?? 0)) 个日志文件，没有命中错误行。"
                        : "在项目内放置 Logs/error.log 或 crash.log，或用「附加日志文件」手动选择。"
                )
            }
        }
    }

    // MARK: 局部块

    private var branchSubtitle: String? {
        guard let branch = report?.git?.branch, !branch.isEmpty else { return nil }
        return "分支 \(branch)"
    }

    /// 测试覆盖率只在仓库真出了报告时才出现，没报告就不画，避免读成一个假的 0%。
    @ViewBuilder
    private var coverageStrip: some View {
        if let coverage = report?.coverage, coverage.hasData {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Divider()
                HStack(spacing: Theme.Spacing.md) {
                    StatLine(label: "单元测试",
                             value: coverage.unit.map { Self.percentOf100($0.linePercent) } ?? "无报告")
                    StatLine(label: "集成测试",
                             value: coverage.integration.map { Self.percentOf100($0.linePercent) } ?? "无报告")
                    StatLine(label: "整体行覆盖",
                             value: coverage.overallLinePercent.map { Self.percentOf100($0, precision: 1) }
                                 ?? Theme.Placeholder.missingValue)
                    Spacer(minLength: Theme.Spacing.xs)
                    RiskBadge(risk: coverage.riskLevel, showIcon: false)
                }
                if let branch = coverage.overallBranchPercent {
                    Text("分支覆盖 \(Self.percentOf100(branch, precision: 1)) · 来源 "
                         + coverage.reports.map { $0.toolName }.joined(separator: " / "))
                        .font(Theme.Typo.microLabel.font.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// `CoverageMetrics.linePercent` 已经是 0...100，而 `NumberFormat.percent` 收的是
    /// 0...1 的 fraction（它自己会乘 100）。两者不能直接对接，这里就地换算一次。
    static func percentOf100(_ percent: Double, precision: Int = 0) -> String {
        NumberFormat.percent(percent / 100, precision: precision)
    }

    /// 读写两个方向求和。快照缺席时给 `--` ——
    /// 旧写法 `(snapshot?.diskRead ?? 0) + (… ?? 0)` 会把「没采到」报成 `0 B/s`，
    /// 在监控 App 里这是一句假的好消息（WS-I §3.4）。
    private func snapshotRate(_ read: UInt64?, _ write: UInt64?,
                              rate: (UInt64) -> String) -> String {
        guard let read, let write else { return Theme.Placeholder.missingValue }
        return rate(read + write)
    }

    /// 部分失败必须可行动：点名哪些分析器没跑成，并给重试，
    /// 而不是留一份永远不会自愈的旧报告。
    private func failureCard(_ message: String) -> some View {
        let failed = report?.failedSections ?? []
        return HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            ThemedIcon(.riskWarning, role: .inlineText, selected: true)
                .foregroundStyle(Theme.Semantic.warning.textColor)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                if !failed.isEmpty {
                    Text("未能完成：\(failed.joined(separator: "、"))")
                        .font(Theme.Typo.cardTitle.font)
                        .foregroundStyle(Theme.Semantic.warning.textColor)
                    Text(message)
                        .font(Theme.Typo.narrative.font)
                        .lineSpacing(Theme.Typo.narrative.lineSpacing)
                        .foregroundStyle(.secondary)
                } else {
                    Text(message)
                        .font(Theme.Typo.narrative.font)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: Theme.Spacing.sm)
            GlassButton("重试", style: .bordered, isEnabled: !state.isScanning) {
                state.scanSelected()
            }
        }
        .padding(Theme.Spacing.sm)
        .bannerTintedSurface(Theme.Semantic.warning)
    }
}

// MARK: - 卡内两行条目

private struct CommitRow: View {
    var commit: CommitRecord

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.xs) {
            Text(String(commit.sha.prefix(7)))
                .font(Theme.Typo.monoSmall.font)
                .foregroundStyle(Theme.Semantic.info.textColor)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(commit.subject)
                    .font(Theme.Typo.narrative.font)
                    .lineLimit(1)
                Text("\(commit.author) · \(DateFormat.sinceDescription(commit.date))")
                    .font(Theme.Typo.microLabel.font.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: Theme.Spacing.xs)
            VStack(alignment: .trailing, spacing: Theme.Spacing.xxs) {
                if commit.additions > 0 {
                    Text("+\(NumberFormat.grouped(commit.additions))")
                        .font(Theme.Typo.microLabel.font.monospacedDigit())
                        .foregroundStyle(Theme.Semantic.success.textColor)
                }
                if commit.deletions > 0 {
                    Text("−\(NumberFormat.grouped(commit.deletions))")
                        .font(Theme.Typo.microLabel.font.monospacedDigit())
                        .foregroundStyle(Theme.Semantic.danger.textColor)
                }
            }
        }
    }
}

private struct ErrorClusterRow: View {
    var cluster: ErrorCluster

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
            SeverityBadge(severity: cluster.severity)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(cluster.displayMessage)
                    .font(Theme.Typo.monoSmall.font)
                    .lineLimit(1)
                Text("首次 \(cluster.firstSeenDescription) · 最近 \(cluster.lastSeenDescription)")
                    .font(Theme.Typo.microLabel.font)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: Theme.Spacing.xs)
            Text("\(cluster.count) 次")
                .font(Theme.Typo.metricMid.font)
                .foregroundStyle(Theme.Semantic.danger.textColor)
        }
    }
}
