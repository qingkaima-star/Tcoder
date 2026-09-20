import SwiftUI

/// 总览首屏。
///
/// **本轮（WS-O / M1）按 spec §4.1 重排**，针对的是量出来的三条病灶：
///   · 「hero 卡 + 4 tile + 4 卡」全部同一表面重量 → `codeScaleCard` 里的 `182,430`
///     原本涂 `info` 蓝（`0x0A5BCC`，墨/底对比 10.7:1），而参考图最暗像素 `#000000`
///     落在**最大的数字**上。现在主读数一律 `Surface.ink`，蓝不再当数据色用（风格契约 4/5）。
///   · 「没有主次」在文字侧的另一半是四块灰盒 tile → 收成一条 `ReadoutStrip`
///     （列间发丝线），一次去掉 4 个面 + 4 份投影。
///   · 组间与组内是同一个数（`md`16 / `gutter`12）→ 版面交给基座**唯一那份**页骨架
///     `Theme.Page.Scaffold`：页边距 24 / 组间 32 / 顶底段落 40（风格契约 8）。
///     本页不再自己写 `ScrollView + VStack + padding + 限宽` —— 实测全仓并存过三份
///     同职责骨架（基座 `Page.Scaffold`、`DataPageScaffold` 逐字复制品、WS-W 的
///     `BorderlessPage` 临时变体），那正是「东一个系一个」在代码层的形态。
///   · 「代码规模」一张卡塞了 大数 + 5 条占比 + 3 个 StatLine + 覆盖率 4 行说明 → 拆成
///     代码规模 / 文件构成 / 测试覆盖率 三组，覆盖率口径说明降到 10pt 脚注。
///
/// **诚实性内容一个字都没删**（#37 / #38）：口径说明、「含测试代码 X%（不用于评分）」、
/// 报告生成时间 `generationSummaryText`、三态句式、缺数据不显示成 0 —— 全部原样在场，
/// 只降排版层级。
struct DashboardView: View {
    @Environment(AppState.self) private var state

    private var report: ProjectReport? { state.selectedReport }

    var body: some View {
        Theme.Page.Scaffold(maxWidth: Theme.Layout.maxWidthOverview) {
            HealthHeroCard(health: report?.health)
            // 紧跟 hero 的是**本机读数带**（CPU / 内存 / 今日错误 / 最近提交），
            // 再往下才是仓库静态指标。顺序理由：读数带与实时曲线同属「本机此刻」，
            // 拆开放会让眼睛在两种时间尺度之间来回跳；而它整体是一个独立子视图，
            // 1.5s 心跳的失效域只落在它身上（性能轮 O-2）。
            DashboardLiveReadout()
            scaleSegment
            listSegment
            if let error = state.lastError {
                failureCard(error)
            }
        }
    }

    /// 代码规模这一段（实时读数已单独成 `DashboardLiveReadout`，见其注释的失效域理由）。
    private var scaleSegment: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.group) {
            codeScaleGroup
            LazyVGrid(columns: pairColumns, alignment: .leading,
                      spacing: Theme.Spacing.group) {
                fileCompositionGroup
                coverageStrip
            }
        }
    }

    /// 底部两块清单（最近提交 / 高频错误）。窄窗口自动折成单列。
    private var listSegment: some View {
        LazyVGrid(columns: pairColumns, alignment: .leading,
                  spacing: Theme.Spacing.group) {
            recentCommitsGroup
            topErrorsCard
        }
    }

    /// 栅格列宽全部走基座锚点，不再写死「一行四列」：窗口收窄时自动折行（WS-H §3.2）。
    /// 列间距从 `gutter`(12) 抬到 `pageMargin`(24)：无界面里两列之间没有盒体边界，
    /// 12pt 会被读成「两列挤成一坨」。
    private var pairColumns: [GridItem] {
        [GridItem(.adaptive(minimum: Theme.Layout.twoColumnMinWidth),
                  spacing: Theme.Spacing.pageMargin)]
    }

    // MARK: 今日错误的着色（语义色只留给真有危险的那一态）

    /// 「这一格里真有危险吗」。红只留给 `>0`：`0` 是「查过、没有」这一结论，
    /// 把 0 涂成红等于对着一句定心丸拉警报。缺证据那一态由 `MetricTile` 自己
    /// 强制回 neutral（`forcesNeutralTint(for:)`），这里不重复那件事。
    /// 做成谓词而不是返回 `Color`，是为了可测 —— 动态色两次取值不相等。
    /// 被 `ShellBorderlessTests.test_onlyRealErrorsCarryTheDangerHue` 钉住，
    /// 必须留在 `DashboardView` 上（测试调 `DashboardView.hasTodayErrors`）。
    static func hasTodayErrors(_ count: Int?) -> Bool { (count ?? 0) > 0 }

    /// 读数带（`ReadoutStrip` 四枚 tile）与「实时性能」分组整体搬到 `DashboardLiveReadout`：
    /// 它们读 `state.monitor.latestSnapshot` 与 `history`，而 `DashboardView.body` 已不再读
    /// `monitor` 任何属性。这样每次心跳（每 1.5s）只会让 `DashboardLiveReadout` 这一个 body
    /// 失效重算，静态分组（代码规模 / 文件构成 / 覆盖率 / 最近提交 / 高频错误）全部原地不动
    ///（O-2，性能规格 §5.2）。

    // MARK: 分组（旧「内容卡」）

    /// 代码规模：只留**一个**主角（纯墨大数）+ 语言占比。
    ///
    /// 原来这张卡里还塞着文件构成与覆盖率四行说明 —— 一张卡五种信息，
    /// 结果什么都不是重点（spec §4.1）。现在拆成 `codeScaleGroup` /
    /// `fileCompositionGroup` / `coverageStrip` 三组。
    private var codeScaleGroup: some View {
        GlassSection("代码规模",
                     subtitle: report?.code.map { "最近扫描 \(DateFormat.sinceDescription($0.scannedAt))" },
                     icon: .code) {
            if let code = report?.code {
                VStack(alignment: .leading, spacing: Theme.Spacing.group) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                        Text(NumberFormat.grouped(code.codeLines))
                            .font(Theme.Typo.metricNumber.font)
                            // 原来这里和 tile 一样涂 `info` 蓝。蓝同时是链接与选中色，
                            // 一色两义（spec §0 根因 ④）；主读数一律纯墨。
                            .foregroundStyle(Theme.Palette.Surface.ink)
                        Text("有效代码行")
                            .font(Theme.Typo.label.font)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
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
                    }
                }
            } else {
                EmptyStateView(icon: IconName.code.rawValue,
                               title: ShellCopy.notAnalyzed("代码规模"),
                               message: "选择项目目录后自动统计。")
            }
        }
    }

    /// 文件构成：从「代码规模」那张卡里分出来的第二组。
    private var fileCompositionGroup: some View {
        GlassSection("文件构成") {
            if let code = report?.code {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    StatLine(label: "文件", value: NumberFormat.grouped(code.totalFiles))
                    StatLine(label: "注释行", value: NumberFormat.grouped(code.commentLines))
                    StatLine(label: "空行", value: NumberFormat.grouped(code.blankLines))
                }
            } else {
                Text(ShellCopy.notAnalyzed("代码规模"))
                    .font(Theme.Typo.label.font)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // 「实时性能」分组已搬到 `DashboardLiveReadout`（见本文件下方）—— 它读 `monitor`，
    // 必须从 `DashboardView.body` 的失效域里挪出去，静态分组才不随心跳重算。

    private var recentCommitsGroup: some View {
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

    /// 名字冻结：`docs/口径与已知限制.md` 用 `DashboardView.topErrorsCard` 定位「高频错误」这一组的口径，
    /// `DocReferenceRatchetTests` 钉这个锚点。**它已经不是一张卡**（无面、无描边），只是名字留着。
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
    ///
    /// #37：主读数改成**仅生产码**口径，并把口径写在同一屏。原先这里展示的是
    /// 「报告里所有文件」的加权值，而测试代码几乎必然被自己的测试覆盖到——
    /// 本机实测它占分母 43.83%、自身 86.38%，于是只加测试就能把这个数字养大。
    /// 全口径仍然展示，但明确标注「不用于评分」，只展示高的那一个是不诚实的。
    ///
    /// 本轮把它从「代码规模」那张卡里独立成一组，四行说明降到 10pt 脚注档 ——
    /// **字一个没删**，只是不再和读数抢注意力。
    @ViewBuilder
    private var coverageStrip: some View {
        if let coverage = report?.coverage, coverage.hasData {
            GlassSection("测试覆盖率") {
                // 风险徽标原挂在 `GlassSection.trailing`（需 `AnyView`，O-3 清零），
                // 现作为分组首行放进内容区，信息不丢、只降排版层级。
                RiskBadge(risk: coverage.riskLevel, showIcon: false)
                    .padding(.bottom, Theme.Spacing.xxs)
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    StatLine(label: "生产码行覆盖",
                             value: DataAbsence.optional(
                                coverage.overallLinePercent.map { Self.percentOf100($0, precision: 1) })
                                .display)
                    StatLine(label: "单元测试",
                             value: coverage.unit.map { Self.percentOf100($0.linePercent) } ?? "无报告")
                    StatLine(label: "集成测试",
                             value: coverage.integration.map { Self.percentOf100($0.linePercent) } ?? "无报告")
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(coverageCaliberLine(coverage))
                        .font(Theme.Typo.microLabel.font.monospacedDigit())
                        // 原来是 `.tertiary`：这一行里是**测得值**（含测试代码占比、差值），
                        // 测得值不得用 tertiary。降到 10pt 已经足够安静了。
                        .foregroundStyle(.secondary)
                    // #38：这些读数是把几份本地报告合起来算的，而报告本身是 .gitignore 挡着的
                    // 本地产物——不写「哪天生成的」，一份几天前的 lcov 就能长期冒充新鲜数据进健康分。
                    // 多份报告按最旧那份说（见 `CoverageMetrics.generationSummaryText`）。
                    if let generation = coverage.generationSummaryText {
                        Text(generation)
                            .font(Theme.Typo.microLabel.font.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if let branch = coverage.overallBranchPercent {
                        Text("分支覆盖 \(Self.percentOf100(branch, precision: 1)) · 来源 "
                             + coverage.reports.map { $0.toolName }.joined(separator: " / "))
                            .font(Theme.Typo.microLabel.font.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// 口径说明一行字：报告没有源文件粒度时必须明说「等同全量」，
    /// 不能让一个没区分过的数字顶着「生产码」的标签。
    private func coverageCaliberLine(_ coverage: CoverageMetrics) -> String {
        guard coverage.scopeIsSeparated, let full = coverage.allSourcesLinePercent,
              let production = coverage.overallLinePercent else {
            return "口径：报告只有汇总粒度，未区分测试代码 · 来源 "
                + coverage.reports.map { $0.toolName }.joined(separator: " / ")
        }
        let gap = full - production
        let gapText = gap >= 0.05 ? "，含测试代码 \(Self.percentOf100(full, precision: 1))（不用于评分）"
                                  : "，与含测试代码的口径一致"
        return "口径：仅生产码（已排除 Tests/、PackageTests、.build、*Tests.swift）"
            + gapText + " · 差 \(Self.percentOf100(gap, precision: 1)) 来自测试代码"
    }

    /// `CoverageMetrics.linePercent` 已经是 0...100，而 `NumberFormat.percent` 收的是
    /// 0...1 的 fraction（它自己会乘 100）。两者不能直接对接，这里就地换算一次。
    static func percentOf100(_ percent: Double, precision: Int = 0) -> String {
        NumberFormat.percent(percent / 100, precision: precision)
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

// MARK: - 实时读数区（隔离出 DashboardView 的心跳失效域）

/// 总览页的实时部分：**独立成 struct**，整体从 `DashboardView.body` 的失效域里挪出。
///
/// 它读 `state.monitor.latestSnapshot` 与 `state.monitor.history`（每 1.5s 变一次）。
/// 旧写法这些读发生在 `DashboardView.body` 求值过程中，于是一次心跳就把整页
/// （四枚 tile + 三张静态卡 + 90 点×2 mark）全量重算，主线程热点第一名是
/// `_updateViewGraph`（性能规格 §1 实测 64.3%）。隔离后，心跳只让本 body 失效，
/// 静态分组（代码规模 / 文件构成 / 覆盖率 / 最近提交 / 高频错误）原地不动（O-2）。
///
/// 当前仍订阅整份 `latestSnapshot` / `history`，未用 M0 的细粒度读模型
///（M0 尚未进 main，且 `Services/**` 不在本流可写范围）；隔离已使失效域退出静态区，
/// M0 落地后可进一步只订阅所需字段。
struct DashboardLiveReadout: View {
    @Environment(AppState.self) private var state

    private var report: ProjectReport? { state.selectedReport }
    private var snapshot: SystemSnapshot? { state.monitor.latestSnapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.group) {
            readoutStrip
            livePerformanceGroup
        }
    }

    // MARK: 读数带（旧「四枚 tile」）

    /// 四枚 tile 的三态口径：
    /// 「没有测到」一律传 `value: nil`，由 `MetricTile` 渲染成 `--` + 中性色；
    /// 真 0 是结论，照实传 `"0"`。原来 CPU 缺值传 `"--"` 而今日错误缺值传 `0`，
    /// 同一块屏上两种自相矛盾的说法并存（WS-I §3.4）。
    ///
    /// 排法换成 `ReadoutStrip` + 列间发丝线：tile 已经不是一块面了，
    /// 四块无边框文字并排会糊成一整段，发丝线替掉原来的盒体边界。
    private var readoutStrip: some View {
        ReadoutStrip {
            cpuTile
            Divider()
            memoryTile
            Divider()
            errorTile
            Divider()
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
        let count = logs?.hasData == true ? logs?.todayErrorCount : nil
        return MetricTile(
            label: "今日错误",
            value: count.map { NumberFormat.grouped($0) },
            caption: caption,
            tint: DashboardView.hasTodayErrors(count) ? Theme.Semantic.danger.textColor
                                                      : Theme.Palette.Surface.ink,
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
            systemImage: IconName.git.rawValue
        )
    }

    // MARK: 实时性能分组

    private var livePerformanceGroup: some View {
        GlassSection("实时性能",
                     subtitle: "本机 · 每 1.5 秒采样",
                     icon: .performance) {
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
                             value: DataAbsence.optional(
                                snapshot.map { NumberFormat.grouped($0.processCount) }).display)
                }
                // 「立即采样」原挂在 `GlassSection.trailing`（需 `AnyView`，O-3 清零），
                // 现移入内容区，避免为按钮在页面里引入 `AnyView`。
                HStack(spacing: Theme.Spacing.sm) {
                    Spacer(minLength: Theme.Spacing.sm)
                    GlassButton("立即采样", icon: .refresh, style: .bordered) {
                        state.monitor.sampleNow()
                    }
                }
            } else {
                EmptyStateView(icon: IconName.performance.rawValue,
                               title: "正在采集…",
                               message: "首个采样点到达后显示曲线。")
            }
        }
    }

    /// 读写两个方向求和。快照缺席时给 `DataAbsence.notAnalysed` 的字面（`--`）——
    /// 旧写法 `(snapshot?.diskRead ?? 0) + (… ?? 0)` 会把「没采到」报成 `0 B/s`，
    /// 在监控 App 里这是一句假的好消息（WS-I §3.4）。
    private func snapshotRate(_ read: UInt64?, _ write: UInt64?,
                              rate: (UInt64) -> String) -> String {
        guard let read, let write else { return DataAbsence.notAnalysed.display }
        return rate(read + write)
    }
}

// MARK: - 卡内两行条目

private struct CommitRow: View {
    var commit: CommitRecord

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.xs) {
            Text(String(commit.sha.prefix(7)))
                .font(Theme.Typo.monoSmall.font)
                // 原来涂 `info` 蓝。SHA 是**数据**不是状态，蓝要留给交互（风格契约 5）；
                // spec §0 根因 ④ 点名的 36 处里就有它。
                .foregroundStyle(.primary)
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
