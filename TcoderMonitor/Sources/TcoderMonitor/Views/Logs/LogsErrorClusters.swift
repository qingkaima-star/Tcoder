import SwiftUI

// MARK: - 高频错误（原「Top Errors」，术语按《40 WS-H》§7.1 全中文化）

struct LogsErrorClustersCard: View {
    let logs: LogSummary?

    var body: some View {
        GlassSection("高频错误", subtitle: subtitle, icon: .logs) {
            if let clusters, !clusters.isEmpty {
                // 每条签名是「签名 + 原文 + 时间 + 可展开」的多行块，
                // 块与块之间必须是组间档（16），不能再和块内部的 4pt 挤在同一个数上。
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    ForEach(Array(clusters.enumerated()), id: \.element.id) { index, cluster in
                        LogErrorClusterRow(cluster: cluster)
                        if index < clusters.count - 1 { Divider() }
                    }
                }
            } else {
                emptyState
            }
        }
    }

    private var clusters: [ErrorCluster]? { logs?.topErrors }

    private var subtitle: String? {
        guard let logs, logs.hasData, let clusters = clusters else { return nil }
        return "共 \(NumberFormat.grouped(clusters.count)) 类签名 · 按出现次数排序"
    }

    @ViewBuilder
    private var emptyState: some View {
        if logs == nil {
            EmptyStateView(icon: IconName.emptyUnknown.rawValue,
                           title: "尚无错误签名数据",
                           message: "该项目还没有日志分析结果，点「重新分析」后再来查看聚类。")
        } else if let logs, !logs.hasData {
            EmptyStateView(icon: IconName.emptyUnknown.rawValue,
                           title: "没有可读的日志文件",
                           message: "在项目目录或 ~/Library/Logs 放入 error.log、crash.log，或用「附加日志」手动选择后重新分析。")
        } else if let logs {
            // ② 查了但空的句式：给出扫过的行数，让「0」成为一个结论而不是空白。
            EmptyStateView(icon: IconName.noRisk.rawValue,
                           // 三态句式全站只有一个出处：WS-K 在 Views/Shell 里定的 ShellCopy。
                           title: ShellCopy.scannedButFoundNone("错误级别日志"),
                           message: "本次扫了 \(NumberFormat.grouped(logs.totalLinesScanned)) 行，"
                               + "没有命中错误、异常或崩溃级别的行。")
        }
    }
}

/// 单条错误签名：签名 + 原文 + 首次 / 最近 + 可展开的样例与堆栈。
struct LogErrorClusterRow: View {
    let cluster: ErrorCluster

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                SeverityBadge(severity: cluster.severity)
                // 签名是这一行的主角：原来靠 accent 蓝把自己拎出来，而蓝在这套体系里
                // 只代表交互 / 选中。改走 11pt 等档（`monoLabel`，专为代码标识符设的档），
                // **层级靠字号与等宽字族分，不靠色相分**。
                Text(cluster.signature)
                    .font(Theme.Typo.monoLabel.font)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .flexCell()
                    .help(cluster.signature)
                LiveNumber("\(NumberFormat.grouped(cluster.count)) 次", tier: Theme.Typo.monoBody)
                    .numberCell(PerfLogWidths.count)
            }

            Text(cluster.displayMessage)
                .font(Theme.Typo.narrative.font)
                .foregroundStyle(.secondary)
                .lineSpacing(Theme.Typo.narrative.lineSpacing)
                .lineLimit(2)
                .textSelection(.enabled)

            Text("第一次 \(firstSeenText) · 最近 \(lastSeenText)")
                .font(Theme.Typo.microLabel.font)
                .foregroundStyle(.tertiary)

            if hasDetail { detailDisclosure }
        }
        .padding(.vertical, Theme.Spacing.xxs)
    }

    /// 时间取不到时写 --，不写「从未」——「从未」听起来像调查过的结论。
    private var firstSeenText: String {
        cluster.firstSeen.map { DateFormat.sinceDescription($0) } ?? Live.missing
    }

    private var lastSeenText: String {
        cluster.lastSeen.map { DateFormat.sinceDescription($0) } ?? Live.missing
    }

    private var hasDetail: Bool {
        !cluster.sampleLines.isEmpty || !cluster.stackTopFrames.isEmpty || !cluster.sourceFile.isEmpty
    }

    private var detailDisclosure: some View {
        DisclosureGroup {
            detail.padding(.top, Theme.Spacing.xxs)
        } label: {
            Text("样例与堆栈")
                .font(Theme.Typo.label.font)
                .foregroundStyle(.secondary)
        }
        .tint(Theme.Semantic.accent.textColor)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            if !cluster.sampleLines.isEmpty {
                detailTitle("样例行")
                ForEach(Array(cluster.sampleLines.prefix(5).enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .top, spacing: Theme.Spacing.xxs) {
                        Text("\(index + 1)")
                            .font(Theme.Typo.monoSmall.font)
                            .foregroundStyle(.tertiary)
                            .numberCell(PerfLogWidths.sampleIndex)
                        Text(line)
                            .font(Theme.Typo.monoSmall.font)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
            }

            if !cluster.stackTopFrames.isEmpty {
                detailTitle("堆栈顶帧")
                ForEach(Array(cluster.stackTopFrames.prefix(6).enumerated()), id: \.offset) { _, frame in
                    HStack(alignment: .top, spacing: Theme.Spacing.xxs) {
                        ThemedIcon(.disclose, role: .badge).foregroundStyle(.secondary)
                        Text(frame)
                            .font(Theme.Typo.monoSmall.font)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .textSelection(.enabled)
                    }
                }
            }

            if !cluster.sourceFile.isEmpty {
                Text("来源文件 \(cluster.sourceFile)")
                    .font(Theme.Typo.monoSmall.font)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(cluster.sourceFile)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.xs)
        .surface(layer: .contentInset, shape: .rounded(Theme.Radius.sm))
    }

    private func detailTitle(_ text: String) -> some View {
        Text(text).font(Theme.Typo.microLabel.font).foregroundStyle(.tertiary)
    }
}
