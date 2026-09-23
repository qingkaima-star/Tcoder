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
        Theme.Page.Scaffold {
            Theme.Page.Header(title: "总览", icon: .dashboard)
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
    ///
    /// **页面级单列**。旧的 `LazyVGrid(pairColumns)` 两列量出三条病灶（`7b4ec25` 那批 36 张页尾
    /// 配 `card_edges` 逐带量）：不渲染的那格照样占栅格槽位 ⇒ 297pt 画布洞；同一行两张卡
    /// 不共顶线（1065px vs 1593px）；而两列本身是把卡**压到内容最小宽之下**才挤出来的
    /// （两张各需 > 463pt，容器只有 951pt），那属「溢出/挤压」而不是排版问题。
    /// 守卫 `ShellBorderlessTests.test_dashboardIsSingleColumnWithNoCardPairGrid`。
    private var scaleSegment: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.group) {
            codeScaleGroup
            fileCompositionGroup
            coverageStrip
        }
    }

    /// 底部两块清单（最近提交 / 高频错误）。同上，单列。
    private var listSegment: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.group) {
            recentCommitsGroup
            topErrorsCard
        }
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
                     subtitle: report?.code.map { localizedFormat("最近扫描 %@", DateFormat.sinceDescription($0.scannedAt)) },
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
                               title: ShellCopy.notAnalyzed(.codeSize),
                               message: "选择项目目录后自动统计。")
            }
        }
    }

    /// 文件构成：从「代码规模」那张卡里分出来的第二组。三格**横排**——
    /// 单列化之后这张卡有 951pt 宽，竖排三行会把右侧四分之三留空（乱清单 §5 那一行）。
    /// 刻意不升格成 `MetricTile`：这三格是次级读数，最重的字号要留给页顶那条读数带
    /// （风格契约 4），所以沿用 `StatLine` 那一档，只把每格撑成等宽三栏。
    private var fileCompositionGroup: some View {
        GlassSection("文件构成") {
            if let code = report?.code {
                HStack(spacing: Theme.Spacing.lg) {
                    StatLine(label: "文件", value: NumberFormat.grouped(code.totalFiles))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    DataBandSeparator()
                    StatLine(label: "注释行", value: NumberFormat.grouped(code.commentLines))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    DataBandSeparator()
                    StatLine(label: "空行", value: NumberFormat.grouped(code.blankLines))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text(ShellCopy.notAnalyzed(.codeSize))
                    .font(Theme.Typo.label.font)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // 「实时性能」分组已搬到 `DashboardLiveReadout`（见 `Views/Shell/DashboardReadouts.swift`）—— 它读 `monitor`，
    // 必须从 `DashboardView.body` 的失效域里挪出去，静态分组才不随心跳重算。

    private var recentCommitsGroup: some View {
        GlassSection("最近提交", subtitle: branchSubtitle, icon: .git) {
            if let git = report?.git, !git.recentCommits.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    ForEach(git.recentCommits.prefix(6)) { commit in
                        CommitRow(commit: commit)
                        if commit.id != git.recentCommits.prefix(6).last?.id {
                            DataRowSeparator()
                        }
                    }
                }
            } else {
                EmptyStateView(
                    icon: IconName.git.rawValue,
                    title: report?.git == nil ? ShellCopy.notAnalyzed(.gitHistory)
                                             : ShellCopy.scannedButFoundNone(.commits),
                    message: ShellCopy.cannotAnalyze(.notAGitRepo)
                )
            }
        }
    }

    /// 名字冻结：`docs/口径与已知限制.md` 用 `DashboardView.topErrorsCard` 定位「高频错误」这一组的口径，
    /// `DocReferenceRatchetTests` 钉这个锚点。**它已经不是一张卡**（无面、无描边），只是名字留着。
    private var topErrorsCard: some View {
        GlassSection("高频错误",
                     subtitle: report?.logs.map {
                         localizedFormat("共 %1$@ 条错误",
                                           NumberFormat.grouped($0.errorCount + $0.exceptionCount))
                     },
                     icon: .logs) {
            if let logs = report?.logs, logs.hasData, !logs.topErrors.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    ForEach(logs.topErrors.prefix(5)) { cluster in
                        ErrorClusterRow(cluster: cluster)
                    }
                }
            } else {
                let scanned = report?.logs?.hasData == true
                // 屏上留判定本身（「没有命中错误行」是 C 名单要求的承诺句），次级说明整句进 ⓘ。
                EmptyStateView(
                    icon: scanned ? IconName.noRisk.rawValue : IconName.emptyTray.rawValue,
                    title: scanned ? ShellCopy.scannedButFoundNone(.errors) : ShellCopy.notAnalyzed(.errorLogs),
                    message: scanned ? "没有命中错误行。" : "用「附加日志文件」手动选择。",
                    help: scanned
                        ? localizedFormat("已扫描 %1$@ 个日志文件，没有命中错误行。",
                                          NumberFormat.grouped(report?.logs?.scannedFiles.count ?? 0))
                        : "在项目内放置 Logs/error.log 或 crash.log，或用「附加日志文件」手动选择。"
                )
            }
        }
    }

    // MARK: 局部块

    private var branchSubtitle: String? {
        guard let branch = report?.git?.branch, !branch.isEmpty else { return nil }
        return localizedFormat("分支 %@", branch)
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
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xxs) {
                        // 盘点表 A 组第 1 条「留短藏长 ●」：屏上留短标签，完整口径整句进 ⓘ。
                        Text(Self.coverageCaliberTag(coverage))
                            .font(Theme.Typo.microLabel.font.monospacedDigit())
                            // 原来是 `.tertiary`：这一行里是**测得值**（含测试代码占比、差值），
                            // 测得值不得用 tertiary。降到 10pt 已经足够安静了。
                            .foregroundStyle(.secondary)
                        CopyHelpBadge(DashboardCoverageHelp.text(coverage))
                    }
                    // #38：这些读数是把几份本地报告合起来算的，而报告本身是 .gitignore 挡着的
                    // 本地产物——不写「哪天生成的」，一份几天前的 lcov 就能长期冒充新鲜数据进健康分。
                    // 多份报告按最旧那份说（见 `CoverageMetrics.generationSummaryText`）。
                    if let generation = coverage.generationSummaryText {
                        Text(generation)
                            .font(Theme.Typo.microLabel.font.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if let branch = coverage.overallBranchPercent {
                        Text(localizedFormat("分支覆盖 %1$@ · 来源 %2$@",
                                                 Self.percentOf100(branch, precision: 1),
                                                 coverage.reports.map { $0.toolName }
                                                     .joined(separator: " / ")))
                            .font(Theme.Typo.microLabel.font.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// 屏上短标签 = `coverageCaliberLine` 三条整句各自的前缀子串（不新造修辞），判据与那个 guard 同一条。
    static func coverageCaliberTag(_ coverage: CoverageMetrics) -> String {
        guard coverage.scopeIsSeparated, coverage.allSourcesLinePercent != nil,
              coverage.overallLinePercent != nil else { return localizedCopy("口径：报告只有汇总粒度") }
        return localizedCopy("口径：仅生产码")
    }

    /// 口径说明一行字：报告没有源文件粒度时必须明说「等同全量」，
    /// 不能让一个没区分过的数字顶着「生产码」的标签。
    static func coverageCaliberLine(_ coverage: CoverageMetrics) -> String {
        let sources = coverage.reports.map { $0.toolName }.joined(separator: " / ")
        guard coverage.scopeIsSeparated, let full = coverage.allSourcesLinePercent,
              let production = coverage.overallLinePercent else {
            return localizedFormat("口径：报告只有汇总粒度，未区分测试代码 · 来源 %1$@", sources)
        }
        let gap = full - production
        // 三种情况 = 三条**整句键**。原来这里是「前缀键 + 碎片键 + 后缀碎片」拼出来的，
        // 英文里三段的位置和中文不一样（`差 X 来自测试代码` 要挪到句中），
        // 碎片各翻一次必然拼出坏英文 —— 整句成键是唯一不撒谎的做法。
        if gap < 0.05 {
            return localizedCopy("口径：仅生产码（已排除 Tests/、PackageTests、.build、*Tests.swift），与含测试代码的口径一致")
        }
        return localizedFormat("口径：仅生产码（已排除 Tests/、PackageTests、.build、*Tests.swift），含测试代码 %1$@（不用于评分） · 差 %2$@ 来自测试代码",
                               Self.percentOf100(full, precision: 1),
                               Self.percentOf100(gap, precision: 1))
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
                    Text(localizedFormat("未能完成：%1$@", failed.joined(separator: "、")))
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
        .bannerRuleSurface(Theme.Semantic.warning)
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
                // 冻结区 additive（AGENTS §3 的 P54 行）：长标题裁得掉，但被裁的那一半必须有去处
                Text(commit.subject)
                    .font(Theme.Typo.narrative.font).lineLimit(1).help(commit.subject)
                Text("\(commit.author) · \(DateFormat.sinceDescription(commit.date))")
                    .font(Theme.Typo.microLabel.font.monospacedDigit())
                    .foregroundStyle(.secondary)
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
                // 裁一行可以，被裁掉的那一半必须有去处（P55 窄态实测：格宽 557pt / 单行需 624pt）
                Text(cluster.displayMessage)
                    .font(Theme.Typo.monoSmall.font).lineLimit(1).help(cluster.displayMessage)
                Text(localizedFormat("首次 %1$@ · 最近 %2$@",
                                      cluster.firstSeenDescription,
                                      cluster.lastSeenDescription))
                    .font(Theme.Typo.microLabel.font)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Theme.Spacing.xs)
            Text(localizedCount("%lld 次", cluster.count))
                // 千分位与等宽：日志页同一事实写成 `NumberFormat.grouped(...)`，
                // 这里原来直接插 `cluster.count` → 同屏一个 12,345 一个 12345。
                .font(Theme.Typo.metricMid.font.monospacedDigit())
                .foregroundStyle(Theme.Semantic.danger.textColor)
                .lineLimit(1)
        }
    }
}
