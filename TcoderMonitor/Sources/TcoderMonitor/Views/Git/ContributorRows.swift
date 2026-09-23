import SwiftUI

// MARK: - 贡献者页的行件与分析口径（WS-L）
//
// 从 `ContributorsView.swift` 拆出：整页连行件一起写会撞上 800 行棘轮。
// 这里的 `ContributorAnalysis` 是纯函数集合，占比分母与 Bus Factor 阈值都能被单测直接钉住。

enum ContributorAnalysis {
    /// 视图自己按提交数降序，不依赖上游数组顺序；同分时按显示名升序，保证刷新后榜位不跳。
    static func sorted(_ authors: [AuthorStats]) -> [AuthorStats] {
        authors.sorted {
            if $0.commits != $1.commits { return $0.commits > $1.commits }
            return displayName($0) < displayName($1)
        }
    }

    static func displayName(_ author: AuthorStats) -> String {
        if !author.name.isEmpty { return author.name }
        return author.email.isEmpty ? "未知作者" : author.email
    }

    static func email(_ author: AuthorStats) -> String {
        author.email.isEmpty ? "无邮箱记录" : author.email
    }

    /// 近 30 天有过提交的作者。窗口用 `activeAuthorCount` 的口径读不出来，所以在这算。
    static func recentlyActive(_ authors: [AuthorStats], now: Date = Date()) -> [AuthorStats] {
        authors.filter { author in
            guard let last = author.lastCommitAt else { return false }
            return now.timeIntervalSince(last) <= 30 * 86_400
        }
    }

    /// 头像与占比条的分类色：全 App 唯一一套 `Theme.Chart`，按邮箱稳定哈希取色。
    ///
    /// 必须稳定：Swift 的 `hashValue` 每进程随机化，用它取色会让同一位作者
    /// 每次启动换一种颜色（旧实现正是如此，WS-I §2.1① 点名）。
    static func color(for email: String) -> Color {
        CodeGitCategoryColor.color(for: email)
    }

    /// 与 `GitInsights.busFactorRisk` 同一套阈值，但分母换成**非合并窗口**：
    /// 模型是冻结的，它拿含合并的 `totalCommits` 做分母，仓库越大越低估集中度风险。
    static func busFactorRisk(_ git: GitInsights) -> RiskLevel {
        let base = git.commitScope.authorBasis
        guard let top = git.topAuthor, base > 0 else { return .none }
        let share = Double(top.commits) / Double(base)
        if git.activeAuthorCount <= 1 && base > 50 { return .critical }
        if share > 0.7 { return .high }
        if share > 0.5 { return .medium }
        return .low
    }

    /// 排名不再按名次发色。旧写法是榜首 accent 蓝、2~3 名 teal、其余 neutral ——
    /// 那正是本轮根因 ④「蓝色同时是数据色和交互色」在贡献者页的形态：名次这个**顺序信息**
    /// 已经由数字本身与排序表达了，再涂一层蓝只是让 1 号看起来像可点元素。
    /// 现在一律纯墨（`rank` 是本页这一列的重音），颜色留给真正的语义（Bus Factor 结论、增删）。

    /// 目录热点：字典无序，按次数降序、目录名升序取前 3。
    static func topDirectories(_ author: AuthorStats, limit: Int = 3) -> [(String, Int)] {
        author.topDirectories
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit)
            .map { ($0.key, $0.value) }
    }
}

// MARK: - 贡献者行

struct ContributorRow: View {
    let author: AuthorStats
    let rank: Int
    let git: GitInsights

    /// 头像边长：24 可点区下限 + 一档间距，与相邻 13pt 正文成比例。
    private static let avatarSide: CGFloat = Theme.Layout.minHitTarget + Theme.Spacing.xxs

    /// 份额条与 24 小时分布一律**纯墨**，不再按作者邮箱稳定取序列色。
    /// 与 `Theme.Share.Row` 同一判断：作者名字就写在这两行的左边，颜色在这里不携带
    /// 任何信息，只把页面切成橙/绿两条彩带（用户实拍：#1 橙 95.3%、#2 绿 4.7%）。
    /// 收成墨之后，最长的那根条自然成为重点，而 24 小时分布回到参考图那种
    /// 「单色按强度加浓」的直方图。
    /// 身份装饰色（头像圈）。**结构**，走纯墨/灰阶，不是数据块。
    private var tint: Color { Theme.Palette.Surface.ink }

    /// 数据块色（占比条 + 时段条）。原来这两处与头像共用一个 `tint`，
    /// 于是"改数据块颜色"必然顺手把头像也涂蓝 —— 一个变量服务两个语义，
    /// 是"同一属性两份规则"的另一种形态。批次 P6 拆成两个。
    private var dataTint: Color { ChartSeries.dataMarkColor }

    private var share: Double? {
        guard let value = git.authorShare(of: author) else { return nil }
        return min(1, max(0, value))
    }

    /// 这一格的**态**：`authorShare` 给不出数，是因为分母（非合并提交数）为 0，
    /// 属「算不出」而不是「没扫」——两者的字面必须不同（《42》§14.3 第 1 条）。
    private var shareAbsence: DataAbsence {
        DataAbsence.optional(share.map { NumberFormat.percent($0, precision: 1) },
                             absent: .indeterminate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DataRowMetrics.cellGap) {
                ContributorAvatar(author: author, tint: tint, side: Self.avatarSide)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    HStack(spacing: Theme.Spacing.xs) {
                        Text("#\(NumberFormat.grouped(rank))")
                            .font(CodeGitType.number(Theme.Typo.microLabel))
                            .foregroundStyle(Theme.Palette.Surface.ink)
                        Text(ContributorAnalysis.displayName(author))
                            .font(CodeGitType.prose(Theme.Typo.body).weight(.semibold))
                            .lineLimit(1)
                    }
                    Text(ContributorAnalysis.email(author))
                        .font(CodeGitType.path)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    ContributorDirectoryChips(author: author)
                }
                Spacer(minLength: Theme.Spacing.sm)
                VStack(alignment: .trailing, spacing: Theme.Spacing.xxs) {
                    Text(localizedCount("%lld 次", author.commits))
                        .font(CodeGitType.number(Theme.Typo.metricMid))
                    Text("\(NumberFormat.signed(author.additions)) / \(NumberFormat.signed(-author.deletions))")
                        .font(CodeGitType.number(Theme.Typo.monoSmall))
                        .foregroundStyle(.secondary)
                        // 这里的 `Text(...)` 壳是多余的：`localizedFormat` 已经查过表，
                        // `.help` 另有收 `String` 的重载（本文件 `shareAbsence.help(denominator:)`
                        // 那一格、`GitInsightsView` 的 `.help(Self.latestCommitCaption(git))` 都是它）。
                        // 屏上、悬停上的一模一样，改的只有**尺子能不能看见这句住在 hover**：
                        // `TooltipMigrationGuardTests` 的承载位正则认 `.help(localizedFormat("…`，
                        // 中间夹一层 `Text(` 就落到 `.skipped` ⇒ 一句真 hover 被数成常驻长句。
                        .help(localizedFormat("代码变更量 %1$@ 行 · 触达 %2$@ 个文件",
                                              NumberFormat.grouped(author.totalChurn),
                                              NumberFormat.grouped(author.filesTouched)))
                    Text(author.lastActiveDescription)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: DataRowMetrics.cellGap) {
                MiniBarGauge(fraction: share ?? 0, tint: dataTint, height: DataGaugeHeight.inline)
                    .frame(maxWidth: .infinity)
                Text(shareAbsence.display)
                    .font(CodeGitType.number(Theme.Typo.microLabel))
                    .foregroundStyle(.secondary)
                    .tableCell(DataColumns.column(DataColumns.shareBar, 1))
                    .help(shareAbsence.help(denominator: localizedCopy("报告里的非合并提交数"))
                          ?? "占非合并提交 \(NumberFormat.grouped(git.commitScope.authorBasis)) 次的比例")
            }

            ContributorHourRow(counts: author.activityByHour, tint: dataTint)
        }
        .dataTableRow()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(localizedFormat("第 %1$@ 位 · %2$@，%3$@ 次提交，新增 %4$@ 行，删除 %5$@ 行",
                                                 NumberFormat.grouped(rank),
                                                 ContributorAnalysis.displayName(author),
                                                 NumberFormat.grouped(author.commits),
                                                 NumberFormat.grouped(author.additions),
                                                 NumberFormat.grouped(author.deletions))))
    }
}

/// 作者首字母色标。
///
/// 观感换掉了：原来是"分类色实心圆 + 白字 + 白描边"，而 `Theme.Chart` 里深色模式的黄
/// (`#FFD60A`) 上放白字只有约 1.5:1，等于把字母糊掉。现在统一成"同色环形描边 + 同色字母 +
/// 15% 同色底"，与全站徽标同一套语言，深浅两种外观都不需要为每个色值再配一个 onFill。
struct ContributorAvatar: View {
    let author: AuthorStats
    let tint: Color
    var side: CGFloat = Theme.Layout.minHitTarget + Theme.Spacing.xxs

    var body: some View {
        Text(Self.initial(author: author))
            .font(CodeGitType.prose(Theme.Typo.cardTitle))
            .foregroundStyle(tint)
            .frame(width: side, height: side)
            .background(tint.opacity(Theme.Palette.Opacity.badgeFill), in: Circle())
            .overlay(Circle().strokeBorder(tint, lineWidth: Theme.Stroke.hairline * 2))
            .help("\(ContributorAnalysis.displayName(author)) · \(ContributorAnalysis.email(author))")
    }

    /// 中文取首字、拉丁取首字母大写；空名回退邮箱首字符，最后才是 `?`。
    static func initial(author: AuthorStats) -> String {
        func firstUpper(_ source: String) -> String? {
            let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let first = trimmed.first else { return nil }
            return String(first).uppercased()
        }
        return firstUpper(author.name) ?? firstUpper(author.email) ?? "?"
    }
}

/// 目录热点胶囊。用设计系统的 `SemanticBadge`（10pt Medium、`Spacing.chip` 内边距、
/// 同色 0.15 底、胶囊），取代原先本文件里手写的 `size: 9 + padding 5/2 + opacity(0.12)`。
struct ContributorDirectoryChips: View {
    let author: AuthorStats

    var body: some View {
        let directories = ContributorAnalysis.topDirectories(author)
        if directories.isEmpty {
            Text("未记录目录")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        } else {
            // 胶囊是这一行的**第三级**信息，不许反过来决定行宽：三位长目录名 + 四位数
            // 提交数 ≈ 380pt 的固有宽度，会把姓名与邮箱挤到中间截断（实拍可见）。
            // `ViewThatFits` 从"全展开"逐档退到"只报个数"，装不下的收进 `+N` 并把
            // 完整清单挂在 tooltip —— 退档只丢视觉，不丢信息。
            ViewThatFits(in: .horizontal) {
                Self.row(directories, folded: [])
                Self.row(Array(directories.prefix(2)),
                         folded: Array(directories.dropFirst(2)))
                Self.row(Array(directories.prefix(1)),
                         folded: Array(directories.dropFirst()))
                Self.row([], folded: directories)
            }
        }
    }

    @ViewBuilder
    static func row(_ shown: [(String, Int)], folded: [(String, Int)]) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, entry in
                chip(entry)
            }
            if !folded.isEmpty {
                SemanticBadge("+\(NumberFormat.grouped(folded.count))",
                              role: Theme.Semantic.neutral)
                    .help(folded.map { changeHelp($0.0, $0.1) }
                        .joined(separator: "\n"))
            }
        }
    }

    /// 「路径 · N 次改动」这句 hover 的**唯一权威落点**。
    /// 模板在两处各写一遍会被 `test_noVerbatimLongSentenceTwiceOnOnePage` 判成
    /// "同一页逐字重复的口径长句"—— 那次说得对：一处改字，另一处必然忘记跟上。
    static func changeHelp(_ path: String, _ count: Int) -> String {
        localizedFormat("%1$@ · %2$@ 次改动", path, NumberFormat.grouped(count))
    }

    static func chip(_ entry: (String, Int)) -> some View {
        SemanticBadge("\(tail(entry.0)) · \(NumberFormat.grouped(entry.1))",
                      role: Theme.Semantic.neutral)
            .help(changeHelp(entry.0, entry.1))
    }

    static func tail(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}

/// 单成员 24 小时分布，高度按该成员自己的峰值归一。
/// 柱高与间距属图表几何（WS-I §9 豁免），但颜色与空档一律走令牌：
/// 空格子用系统分隔色，不再自造 `Color.primary.opacity(0.06)`。
///
/// **性能（P-1）**：旧实现每行 24 根 `RoundedRectangle` + 24 个 `.help`（30 名作者 = 720 形状 +
/// 720 tooltip 修饰），`peak` 每柱重算。现改为**单个 `Canvas` 一次画完 24 柱**（1 个视图实例、
/// 1 次 `peak` 计算），悬停仍按格给 tooltip，信息零丢失。
struct ContributorHourRow: View {
    let counts: [Int]
    let tint: Color

    private static let height: CGFloat = Theme.Layout.minHitTarget
    /// 有提交的小时柱从 0.15 起、按峰值线性推到 0.40：两端都取透明度刻度，不再乘自造的系数。
    private static let idleAlpha = Theme.Palette.Opacity.badgeFill
    private static let peakAlpha = Theme.Palette.Opacity.gradientMid
    /// 标签列宽：两个汉字 + 余量。
    /// 「时段」两字 11pt ≈ 22pt，原来给 24pt 加上列内余量后**竖排成了两行**
    /// （实拍：「时」「段」上下叠）。留到 34pt 并把这条写清楚：它是**量出来的**，不是手感。
    private static let labelWidth: CGFloat = 34
    private static let bars = 24
    /// 浮层**预留**出来的那一截高度。浮层必须落在自己预留的布局空间里，
    /// 不能用 `offset` 推到宿主外面 —— 原来 `offset(y: height + 2)` 把它推到
    /// 下一条贡献者的行上（本条带只有 20pt 高，浮层约 22pt），等于用浮层盖内容。
    private static let tooltipReserve: CGFloat = 20
    /// 浮层宽度的保守上界（用于贴右边界时往回夹，避免溢出列宽）。
    private static let tooltipMaxWidth: CGFloat = 150

    @State private var hoveredHour: Int? = nil
    @State private var hoverX: CGFloat = 0

    /// 柱宽与命中宽**必须是同一个公式**。原来 Canvas 里扣了柱间 gap、
    /// `onContinuousHover` 里没扣，24 根柱累计偏移到 23 号柱约 44pt ≈ 两格，
    /// 鼠标停在 21:00 上浮层却写 23:00 —— 读数指错小时，这是正确性缺陷不是观感。
    private static func cellWidth(_ width: CGFloat) -> CGFloat {
        let gap = Theme.Stroke.emphasis
        return max(1, (width - gap * CGFloat(bars - 1)) / CGFloat(bars))
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text("时段")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: Self.labelWidth, alignment: .leading)
            GeometryReader { geo in
                let width = geo.size.width
                let cellW = Self.cellWidth(width)
                let gap = Theme.Stroke.emphasis
                Canvas { ctx, size in
                    for hour in 0..<Self.bars {
                        let value = hour < counts.count ? counts[hour] : 0
                        let ratio = Double(value) / Double(peak)
                        let barH = value == 0
                            ? Theme.Stroke.emphasis
                            : max(Theme.Stroke.emphasis, size.height * CGFloat(ratio))
                        let x = CGFloat(hour) * (cellW + gap)
                        let rect = CGRect(x: x, y: size.height - barH, width: cellW, height: barH)
                        let color: Color = value == 0
                            ? Theme.Palette.Surface.separator
                            : tint.opacity(Self.idleAlpha + (Self.peakAlpha - Self.idleAlpha) * ratio)
                        ctx.fill(Path(roundedRect: rect, cornerRadius: 0), with: .color(color))
                    }
                }
                .frame(height: Self.height, alignment: .top)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        let idx = Int((point.x / (cellW + gap)).rounded(.down))
                        hoveredHour = (0..<Self.bars).contains(idx) ? idx : nil
                        hoverX = point.x
                    case .ended:
                        hoveredHour = nil
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let h = hoveredHour, h < counts.count {
                        Text("\(String(format: "%02d", h)):00 · \(counts[h]) 次提交")
                            .font(CodeGitType.number(Theme.Typo.microLabel))
                            .padding(Theme.Spacing.xxs)
                            // 悬停浮层悬在内容之上 —— 这正是 `.floating` 的定义场景。
                            // 原来写 `.background(.regularMaterial, …)` 是把 M0 刚砍掉的材质
                            // 请回内容层（无内容可折射时退化成平涂半透明灰，比页面底暗 6~13 阶），
                            // 而 `cornerRadius: 4` 是令牌里没有的裸魔法数。投影与底一律由基座给。
                            .surface(layer: .floating, shape: .rounded(Theme.Radius.sm))
                            .fixedSize()
                            // 纵向落在**预留带**里（条带下方 tooltipReserve），横向跟着鼠标所在柱，
                            // 并在贴右边界时往回夹，不越出这一列。
                            .offset(x: min(hoverX, max(0, width - Self.tooltipMaxWidth)),
                                    y: Self.height + Theme.Spacing.xxs)
                    }
                }
            }
            .frame(height: Self.height + Self.tooltipReserve)
        }
        .frame(height: Self.height + Self.tooltipReserve)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(localizedFormat("各小时提交分布，峰值 %@ 次", NumberFormat.grouped(peak))))
        .help(hoverHelp)
    }

    private var peak: Int { max(1, counts.max() ?? 0) }

    private var hoverHelp: String {
        let peakHour = counts.enumerated().max(by: { $0.element < $1.element })?.offset ?? 0
        return localizedFormat("各小时提交分布：峰值 %1$@ 次，最忙 %2$@:00",
                           NumberFormat.grouped(peak), String(format: "%02d", peakHour))
    }
}
