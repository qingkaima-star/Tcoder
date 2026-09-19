import SwiftUI
import Charts

/// Chief-engineer owned home screen. Aggregates contract data only — it never
/// reaches into a workstream's service.
struct DashboardView: View {
    @Environment(AppState.self) private var state

    private var report: ProjectReport? { state.selectedReport }
    private var snapshot: SystemSnapshot? { state.monitor.latestSnapshot }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                heroRow
                metricGrid
                HStack(alignment: .top, spacing: 14) {
                    codeScaleCard
                    livePerformanceCard
                }
                HStack(alignment: .top, spacing: 14) {
                    recentCommitsCard
                    topErrorsCard
                }
                if let error = state.lastError {
                    BannerRow(text: error, style: .warning)
                }
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: Hero

    private var heroRow: some View {
        HStack(alignment: .top, spacing: 14) {
            HealthRing(
                score: report?.health?.overall,
                grade: report?.health?.grade,
                trend: report?.health?.trendDelta
            )
            .frame(width: 170, height: 150)
            .frame(maxWidth: .infinity)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.gridLine))

            VStack(alignment: .leading, spacing: 10) {
                if let health = report?.health {
                    Text("工程健康评分").font(.caption).foregroundStyle(.secondary)
                    if !health.strengths.isEmpty || !health.issues.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(health.strengths.prefix(3), id: \.self) { item in
                                Label(item, systemImage: "plus.circle.fill")
                                    .foregroundStyle(Theme.healthy)
                            }
                            ForEach(health.issues.prefix(3), id: \.self) { item in
                                Label(item, systemImage: "minus.circle.fill")
                                    .foregroundStyle(Theme.danger)
                            }
                        }
                        .font(.caption)
                        .lineLimit(1)
                    }
                    if !health.narrative.isEmpty {
                        Text(health.narrative)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                } else {
                    Text("尚未分析").font(.headline)
                    Text("点击右上角「重新分析」开始扫描代码规模、Git 历史、日志与依赖。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.gridLine))
        }
    }

    // MARK: Metric tiles

    private var metricGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
            MetricTile(
                label: "CPU",
                value: snapshot.map { "\((($0.cpuUsage) * 100).rounded(.toNearestOrAwayFromZero))" } ?? "--",
                unit: "%",
                caption: "\(snapshot?.cpuCoreCount ?? 0) 核 · 负载 \(String(format: "%.2f", snapshot?.loadAverage1 ?? 0))",
                tint: Theme.accent,
                systemImage: "cpu"
            )
            MetricTile(
                label: "Memory",
                value: snapshot.map { ByteFormat.string($0.memoryUsedBytes, precision: 1) } ?? "--",
                caption: snapshot.map { "共 \(ByteFormat.string($0.memoryTotalBytes, precision: 0)) · \(Int(($0.memoryFraction * 100).rounded()))%" } ?? "",
                tint: Theme.accent,
                systemImage: "memorychip"
            )
            MetricTile(
                label: "今日错误",
                value: NumberFormat.grouped(report?.logs?.todayErrorCount ?? 0),
                caption: report.map { "崩溃 \($0.logs?.crashCount ?? 0) · 异常 \($0.logs?.exceptionCount ?? 0)" } ?? "未接入日志",
                tint: Theme.danger,
                systemImage: "exclamationmark.triangle"
            )
            MetricTile(
                label: "最近提交",
                value: DateFormat.sinceDescription(report?.git?.lastCommitAt).replacingOccurrences(of: " 前", with: ""),
                unit: DateFormat.sinceDescription(report?.git?.lastCommitAt).hasSuffix("前") ? "" : "",
                caption: report.map { "\($0.git?.totalCommits ?? 0) 次提交 · \($0.git?.activeAuthorCount ?? 0) 人" } ?? "无 Git 数据",
                tint: Theme.healthy,
                systemImage: "arrow.triangle.branch"
            )
        }
    }

    // MARK: Cards

    private var codeScaleCard: some View {
        SectionCard("代码规模", subtitle: report?.code.map { "最近扫描 \(DateFormat.sinceDescription($0.scannedAt))" }, icon: IconName.code.rawValue) {
            if let code = report?.code {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(NumberFormat.grouped(code.codeLines))
                            .font(Theme.heroNumber)
                            .foregroundStyle(Theme.accent)
                        Text("有效代码行").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(code.languages.prefix(5)) { share in
                        LanguageBar(share: share)
                    }
                    HStack(spacing: 14) {
                        StatLine(label: "文件", value: NumberFormat.grouped(code.totalFiles))
                        StatLine(label: "注释行", value: NumberFormat.grouped(code.commentLines))
                        StatLine(label: "空行", value: NumberFormat.grouped(code.blankLines))
                    }
                    .font(.caption)
                }
            } else {
                EmptyStateView(icon: "doc.text", title: "暂无代码数据", message: "选择项目目录后自动统计。")
            }
        }
    }

    private var livePerformanceCard: some View {
        SectionCard(
            "实时性能",
            subtitle: "本机 · 每 1.5 秒采样",
            icon: IconName.pulse.rawValue,
            trailing: AnyView(
                Button {
                    state.monitor.sampleNow()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            )
        ) {
            if state.monitor.history.count > 2 {
                CPUHistoryChart(snapshots: Array(state.monitor.history.suffix(90)))
                    .frame(height: 96)
                HStack(spacing: 14) {
                    StatLine(label: "磁盘", value: ByteFormat.rate((snapshot?.diskReadBytesPerSecond ?? 0) + (snapshot?.diskWriteBytesPerSecond ?? 0)))
                    StatLine(label: "网络", value: ByteFormat.bitRate((snapshot?.networkInBytesPerSecond ?? 0) + (snapshot?.networkOutBytesPerSecond ?? 0)))
                    StatLine(label: "进程", value: NumberFormat.grouped(snapshot?.processCount ?? 0))
                }
                .font(.caption)
            } else {
                EmptyStateView(icon: "waveform", title: "正在采集…", message: "首个采样点到达后显示曲线。")
            }
        }
    }

    private var branchSubtitle: String? {
        guard let branch = report?.git?.branch, !branch.isEmpty else { return nil }
        return "分支 \(branch)"
    }

    private var recentCommitsCard: some View {
        SectionCard("最近提交", subtitle: branchSubtitle, icon: IconName.git.rawValue) {
            if let git = report?.git, !git.recentCommits.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(git.recentCommits.prefix(6)) { commit in
                        HStack(alignment: .top, spacing: 8) {
                            Text(String(commit.sha.prefix(7)))
                                .font(Theme.monoSmall)
                                .foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(commit.subject).font(.caption).lineLimit(1)
                                Text("\(commit.author) · \(DateFormat.sinceDescription(commit.date))")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 4)
                            VStack(alignment: .trailing, spacing: 0) {
                                if commit.additions > 0 {
                                    Text("+\(NumberFormat.grouped(commit.additions))")
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(Theme.healthy)
                                }
                                if commit.deletions > 0 {
                                    Text("-\(NumberFormat.grouped(commit.deletions))")
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(Theme.danger)
                                }
                            }
                        }
                        if commit.id != git.recentCommits.prefix(6).last?.id {
                            Divider().opacity(0.4)
                        }
                    }
                }
            } else {
                EmptyStateView(icon: "arrow.triangle.branch", title: "无 Git 历史", message: "该目录不是 Git 仓库，或提交记录为空。")
            }
        }
    }

    private var topErrorsCard: some View {
        SectionCard("Top Errors", subtitle: report?.logs.map { "共 \($0.errorCount + $0.exceptionCount) 条错误" }, icon: IconName.logs.rawValue) {
            if let logs = report?.logs, !logs.topErrors.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(logs.topErrors.prefix(5)) { cluster in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            SeverityBadge(severity: cluster.severity)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(cluster.displayMessage).font(.caption.monospaced()).lineLimit(1)
                                Text("首次 \(cluster.firstSeenDescription) · 最近 \(cluster.lastSeenDescription)")
                                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 4)
                            Text("\(cluster.count) 次")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(Theme.danger)
                        }
                    }
                }
            } else {
                EmptyStateView(
                    icon: "checkmark.seal",
                    title: "未发现错误",
                    message: "在项目内放置 Logs/error.log 或 crash.log，或用「附加日志文件」手动选择。"
                )
            }
        }
    }
}

// MARK: - Dashboard building blocks

struct HealthRing: View {
    var score: Int?
    var grade: HealthGrade?
    var trend: Int?

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.gridLine, lineWidth: 12)
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(score ?? 0, 100)) / 100))
                .stroke(
                    Theme.color(forScore: score ?? 0),
                    style: StrokeStyle(lineWidth: 12, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.smooth(duration: 0.6), value: score)
            VStack(spacing: 0) {
                Text(score.map(String.init) ?? "--")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.color(forScore: score ?? 0))
                HStack(spacing: 4) {
                    Text("/100").font(.system(size: 10)).foregroundStyle(.tertiary)
                    if let grade {
                        Text(grade.rawValue)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.color(forScore: score ?? 0))
                    }
                    if let trend, trend != 0 {
                        Text(trend > 0 ? "↑\(trend)" : "↓\(abs(trend))")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(trend > 0 ? Theme.healthy : Theme.danger)
                    }
                }
            }
        }
        .padding(14)
    }
}

struct LanguageBar: View {
    var share: LanguageShare

    private static let palette: [Color] = [
        Color(red: 0.95, green: 0.45, blue: 0.35),
        Color(red: 0.45, green: 0.68, blue: 0.98),
        Color(red: 0.62, green: 0.78, blue: 0.45),
        Color(red: 0.82, green: 0.60, blue: 0.90),
        Color(red: 0.98, green: 0.78, blue: 0.40),
        Color(red: 0.45, green: 0.82, blue: 0.78),
    ]

    var body: some View {
        HStack(spacing: 8) {
            Text(share.language)
                .font(.system(size: 10))
                .frame(width: 72, alignment: .leading)
                .lineLimit(1)
            MiniBarGauge(
                fraction: share.share,
                tint: Self.palette[abs(share.language.hashValue) % Self.palette.count],
                height: 5
            )
            Text(NumberFormat.percent(share.share, precision: 0))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }
}

struct StatLine: View {
    var label: String
    var value: String

    var body: some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.tertiary)
            Text(value).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.primary)
        }
        .font(.system(size: 10))
    }
}

struct CPUHistoryChart: View {
    var snapshots: [SystemSnapshot]

    var body: some View {
        Chart(snapshots) { snapshot in
            AreaMark(
                x: .value("时间", snapshot.timestamp),
                y: .value("CPU", snapshot.cpuUsage * 100)
            )
            .interpolationMethod(.monotone)
            .foregroundStyle(
                LinearGradient(
                    colors: [Theme.accent.opacity(0.45), Theme.accent.opacity(0.04)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            LineMark(
                x: .value("时间", snapshot.timestamp),
                y: .value("CPU", snapshot.cpuUsage * 100)
            )
            .interpolationMethod(.monotone)
            .foregroundStyle(Theme.accent)
            .lineStyle(StrokeStyle(lineWidth: 1.6))
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) { _ in
                AxisGridLine().foregroundStyle(Theme.gridLine)
                AxisValueLabel().font(.system(size: 8))
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisValueLabel(format: .dateTime.hour().minute(), centered: false)
                    .font(.system(size: 8))
            }
        }
    }
}

enum BannerStyle {
    case warning, info, error

    var color: Color {
        switch self {
        case .warning: return Theme.caution
        case .info: return Theme.accent
        case .error: return Theme.danger
        }
    }

    var icon: String {
        switch self {
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }
}

struct BannerRow: View {
    var text: String
    var style: BannerStyle = .info

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: style.icon).foregroundStyle(style.color).font(.system(size: 12))
            Text(text).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(style.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(style.color.opacity(0.3)))
    }
}
