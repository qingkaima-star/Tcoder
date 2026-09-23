import SwiftUI

// MARK: - 高频错误（原「Top Errors」，术语按《40 WS-H》§7.1 全中文化）

struct LogsErrorClustersCard: View {
    let logs: LogSummary?

    var body: some View {
        GlassSection("高频错误", subtitle: subtitle, icon: .logs, trailing: sortHelp) {
            if let clusters, !clusters.isEmpty {
                // 每条签名是「签名 + 原文 + 时间 + 可展开」的多行块，
                // 块与块之间必须是组间档（16），不能再和块内部的 4pt 挤在同一个数上。
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    ForEach(Array(clusters.enumerated()), id: \.element.id) { index, cluster in
                        LogErrorClusterRow(cluster: cluster)
                        if index < clusters.count - 1 { DataRowSeparator() }
                    }
                }
            } else {
                emptyState
            }
        }
    }

    private var clusters: [ErrorCluster]? { logs?.topErrors }

    /// 屏上只留**数量**（它是这一节的信息量所在），排序口径进 ⓘ。
    private var subtitle: String? {
        guard let logs, logs.hasData, let clusters = clusters else { return nil }
        return localizedCount("共 %lld 类签名", clusters.count)
    }

    /// ⓘ 里那句是完整口径：数量 + 排序依据。数量在屏上重复一次是故意的——
    /// 读屏与 hover 都要能独立成句（半句键在英文态语序必坏）。
    private var sortHelp: AnyView? {
        guard logs?.hasData == true, let clusters else { return nil }
        return AnyView(CopyHelpBadge(localizedCount("共 %lld 类签名 · 按出现次数排序", clusters.count)))
    }

    @ViewBuilder
    private var emptyState: some View {
        if logs == nil {
            // 判词要的是「屏上的字变少」，不是「把话说三遍」：这一支整句进 ⓘ，
            // 屏上留标题那一句（「还没有结果」这个状态本身不许藏）。
            EmptyStateView(icon: IconName.emptyUnknown.rawValue,
                           title: "尚无错误签名数据",
                           message: "")
            CopyHelpBadge("该项目还没有日志分析结果，点「重新分析」后再来查看聚类。")
        } else if let logs, !logs.hasData {
            // 原因与下一步**页顶横幅已经说过一次**，这里只说本节画不出什么。
            SectionEmptyNote(text: "本窗口没有可归类的错误行。", icon: .emptyUnknown)
        } else if let logs {
            // ② 查了但空的句式：给出扫过的行数，让「0」成为一个结论而不是空白。
            // 这一句是「扫了但没命中」的诚实性告知，整句常驻，不搬。
            EmptyStateView(icon: IconName.noRisk.rawValue,
                           // 三态句式全站只有一个出处：WS-K 在 Views/Shell 里定的 ShellCopy。
                           title: ShellCopy.scannedButFoundNone(.errorLevelLogs),
                           message: localizedFormat("本次扫了 %1$@ 行，没有命中错误、异常或崩溃级别的行。",
                                                    NumberFormat.grouped(logs.totalLinesScanned)))
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
                LiveNumber(localizedCount("%lld 次", cluster.count), tier: Theme.Typo.monoBody)
                    .numberCell(PerfLogWidths.count)
            }

            Text(cluster.displayMessage)
                .font(Theme.Typo.narrative.font)
                .foregroundStyle(.secondary)
                .lineSpacing(Theme.Typo.narrative.lineSpacing)
                .lineLimit(2)
                .textSelection(.enabled)

            Text(localizedFormat("第一次 %1$@ · 最近 %2$@", firstSeenText, lastSeenText))
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
                Text(localizedFormat("来源文件 %@", cluster.sourceFile))
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
        // 同 3.9：组内小标题一律 `groupLabel`。原来这档是 `microLabel` + `.tertiary`，
        // 10pt 中灰压在一堆 10pt 元数据里，读不出"这是一个小标题"。
        Text(text).typed(Theme.Typo.groupLabel).foregroundStyle(.secondary)
    }
}
