import SwiftUI

// MARK: - Git 洞察页各分区（WS-L）
//
// 从 `GitInsightsView.swift` 拆出来：那个文件已经 500+ 行，再加内容就撞上
// `SelfScanDogfoodTests` 的 800 行棘轮（全仓 ceiling 9，只剩 1 个余量）。
// 拆分优先于加长。

// MARK: - 空态

extension GitDataAbsence {
    /// 数据不在场时的空态视图。三态措辞由 `GitDataAbsence.copy` 决定，
    /// 页面只负责给"数据在场却仍然没有这一份明细"的兜底说法。
    @ViewBuilder func emptyState(fallback: () -> EmptyStateView) -> some View {
        if let copy {
            EmptyStateView(icon: copy.icon, title: copy.title, message: copy.message)
        } else {
            fallback()
        }
    }
}

enum GitInsightsEmptyState {
    static var missingAnalysis: some View {
        EmptyStateView(
            icon: .git,
            title: "尚未分析 Git 历史",
            message: "选择一个本地仓库目录后点击「重新分析」。\n分析完成后这里会显示提交趋势、24×7 活跃分布与最近提交记录。\n"
                + ShellGitAnalyzer.attemptedLocationsText(upward: ShellGitAnalyzer.maxUpwardHops,
                                                         nested: ShellGitAnalyzer.maxNestedDepth)
        )
    }
}

// MARK: - 仓库来源

/// 「分析的是哪个仓、怎么找到的」必须一眼可见：只要定位结果偏离了用户所选目录，
/// 就用提示条说清楚，绝不静默地拿另一个仓库的数字冒充。
///
/// 本轮去掉了它外面那层 `GlassCard`（一块带描边的灰盒）。它承载的是**事实**而不是
/// 一个可点对象，所以层级反而要往上走：改成与其他分区同形的 `GlassSection`。
/// 偏离时的 `DataNotice` 原样保留 —— 那是状态告警，不是装饰。
struct GitRepositorySourceSection: View {
    let git: GitInsights
    let selectedPath: String

    var body: some View {
        let root = git.resolvedRepositoryRoot ?? ""
        if isRelocated {
            DataNotice(text: "分析的是另一个仓库：\(root)\n\(Self.discoveryCaption(git))",
                       role: git.discoveryMode == .nestedSubdirectory
                           ? Theme.Semantic.warning : Theme.Semantic.neutral,
                       icon: .riskWarning, iconLabel: "仓库定位偏离")
        } else {
            GlassSection("仓库来源", subtitle: Self.discoveryCaption(git), icon: .git) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    DataFieldRow(label: "路径",
                                 value: root.isEmpty ? "来源未记录" : root,
                                 style: .path,
                                 // 盘点表 D7「留短藏长」：屏上留「来源未记录」这个态，
                                 // 「旧数据 / 重新分析后可见」这半段解释进 hover。
                                 // 取 `DataFieldRow` 自带的 `help:` 而不是另挂一枚 ⓘ：
                                 // 悬停目标正是它所解释的那一行路径，卡片里也不至于
                                 // 叠出两枚问号（D6 那枚就在下面一行）。
                                 // 整句与 `help:` 写在同一行：ⓘ 落点判定按行扫，
                                 // 换行会让这一串被读成「仍然常驻屏上」而不是「已收进 ⓘ」。
                                 help: root.isEmpty ? "来源未记录（旧数据，重新分析后可见）" : nil)
                    // 盘点表 D6「藏」：这一句回答的是「为什么定位到了这里」，
                    // 是不改变任何数字读法的次级解释 ⇒ 屏上只留一枚 ⓘ，字面一字未改。
                    CopyHelpBadge(Self.discoveryDetail(git))
                }
            }
        }
    }

    private var isRelocated: Bool {
        let root = git.resolvedRepositoryRoot ?? ""
        return git.discoveryMode != .selectedDirectory
            || (!root.isEmpty && ShellGitAnalyzer.canonicalPath(root) != ShellGitAnalyzer.canonicalPath(selectedPath))
    }

    static func discoveryCaption(_ git: GitInsights) -> String {
        switch git.discoveryMode {
        case .selectedDirectory: return "所选目录即仓库"
        case .parentDirectory: return "向上 \(NumberFormat.grouped(git.discoveryHops)) 层找到"
        case .nestedSubdirectory: return "向下 \(NumberFormat.grouped(git.discoveryHops)) 层找到"
        case .none: return "未找到仓库"
        }
    }


    /// 把「为什么」和「结果」分开写：用户所选目录在仓库内部还是仓库本身不在这里再重复一遍路径。
    static func discoveryDetail(_ git: GitInsights) -> String {
        switch git.discoveryMode {
        case .selectedDirectory: return "所选目录本身就是仓库根"
        case .parentDirectory: return "所选目录在仓库内部，历史按父仓库统计"
        case .nestedSubdirectory: return "所选目录本身不是仓库，已改用它下面的子仓库"
        case .none: return "该目录下没有可用的 Git 仓库"
        }
    }

}

// MARK: - 提交口径（诚实性修正的落点）

/// 常驻的口径条：把「含合并的真值」和「作者/代码行实际统计的非合并窗口」一次讲清。
///
/// 之前这两套数字在同一屏上并存却从不解释（界面「提交总数 62」vs 作者表求和 48），
/// 用户自己去对账就会发现我们漏了一步。现在它不需要点任何东西就能看到差额的去向。
struct GitCommitScopeSection: View {
    let git: GitInsights

    var body: some View {
        let scope = git.commitScope
        DataNotice(text: Self.message(for: scope),
                   role: scope.isWindowTruncated ? Theme.Semantic.warning : Theme.Semantic.neutral,
                   icon: scope.isWindowTruncated ? .riskWarning : .info,
                   iconLabel: "提交统计口径")
    }

    static func message(for scope: GitHistoryScope) -> String {
        guard scope.isWindowTruncated else { return scope.headline }
        return scope.headline + "。趋势、时段分布与作者占比都只是这段窗口的分布，不代表全部历史。"
    }

}

// MARK: - 24×7 活跃分布

struct GitActivitySection: View {
    let git: GitInsights

    var body: some View {
        GlassSection(
            "24×7 活跃分布",
            // 盘点表 D9「留短藏长」：屏上留的是**那条真限制本身**（数据源只有边际分布，
            // Z 类不许整条藏），ⓘ 里是完整的近似口径原句 —— 一字未改，所以英文目录里
            // 那条整句键仍然是活的（`LocalizationGuardTests` 守卫 3 会抓烂尾键）。
            subtitle: "数据源只有边际分布" + git.commitScope.windowSuffix,
            icon: .chartLine,
            trailing: AnyView(CopyHelpBadge("数据源只有边际分布 · 单元格是小时与星期两档归一的近似强度"))
        ) {
            if GitActivityHeatmap.hasNoTimestamps(hourCounts: git.activityByHour,
                                                  weekdayCounts: git.activityByWeekday) {
                EmptyStateView(
                    icon: .emptyUnknown,
                    title: "暂无时段分布",
                    message: "提交记录里没有可解析的时间戳，因此无法给出任何时段结论。"
                )
            } else {
                // 24×7 矩阵是「有行列结构、需要横向对齐扫读」的内容，属于契约 3 里
                // 允许进井的那一类。
                DataTableWell {
                    GitActivityHeatmap(hourCounts: git.activityByHour, weekdayCounts: git.activityByWeekday)
                }
                DataFootnote(text: Self.busiestCaption(git))
            }
        }
    }

    static func busiestCaption(_ git: GitInsights) -> String {
        guard let hour = git.busiestHour else { return "小时分布为空，只有星期分布可用" }
        return "最活跃时段：\(hour):00 · 按各作者本地时区合并，未做时区归一"
    }

}

// MARK: - 仓库信息

struct GitRepositoryInfoSection: View {
    let git: GitInsights

    var body: some View {
        GlassSection("仓库信息",
                     subtitle: localizedFormat("分析于 %@", LogRecency.describe(git.analyzedAt)),
                     icon: .git) {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                VStack(spacing: DataRowMetrics.rowGap) {
                    // 分支名不再涂蓝：它是一段文本，不是一个可点对象。
                    DataFieldRow(label: "当前分支", value: git.branch.isEmpty ? "未记录" : git.branch,
                                 style: .text)
                    DataRowSeparator()
                    DataFieldRow(label: "HEAD", value: git.headSHA.isEmpty ? "未记录" : git.headSHA,
                                 style: .path)
                    DataRowSeparator()
                    DataFieldRow(label: "远端", value: git.remoteURL.isEmpty ? "未配置" : git.remoteURL,
                                 style: .path)
                }

                ReadoutStrip {
                    DataReadout(label: "触达文件", value: NumberFormat.grouped(git.filesTouched),
                                unit: "个")
                    DataBandSeparator()
                    // 新增/删除保留语义色：增=绿、删=红 是契约 5 明确留色的那一类。
                    DataReadout(label: "新增", value: NumberFormat.signed(git.totalAdditions),
                                unit: "行", role: Theme.Semantic.success)
                    DataBandSeparator()
                    DataReadout(label: "删除", value: NumberFormat.signed(-git.totalDeletions),
                                unit: "行", role: Theme.Semantic.danger)
                    DataBandSeparator()
                    DataReadout(label: "首次提交", value: Self.firstCommitCaption(git),
                                caption: Self.scopeCaption(git))
                }
            }
        }
    }

    /// 「首次提交」这一格有两种**不同**的空：
    /// 是仓库、也确实一次提交都没有 → 「查了，结果是空」（`measuredEmpty`，文字槽位给「无记录」）；
    /// 压根不是仓库 / 没跑过分析 → 「没查」（`notAnalysed`，给 `--`）。
    /// 两者以前共用一个 `--`，用户就没法分辨「这仓库是空的」和「我们没看」。
    static func firstCommitCaption(_ git: GitInsights) -> String {
        if let first = git.firstCommitAt { return DateFormat.day.string(from: first) }
        return (git.isRepository && git.totalCommits == 0)
            ? DataAbsence.measuredEmpty.textDisplay
            : DataAbsence.notAnalysed.display
    }


    /// 「首次提交」在窗口截断时其实是窗口起点，不能让用户读成仓库诞生日。
    static func scopeCaption(_ git: GitInsights) -> String {
        git.commitScope.isWindowTruncated ? "窗口起点，非仓库首次提交" : "仓库首次提交"
    }

}

// MARK: - 所选目录下的其它仓库

/// 所选目录本身不是仓库、下面又躺着好几个仓库时，把全部候选摊开，
/// 并标明当前分析的是哪一个——让用户自己决定要不要单独添加某个。
struct GitNestedCandidatesSection: View {
    let git: GitInsights

    private static let columns: [DataGridColumn] = [
        DataGridColumn("目录"),
        DataGridColumn("提交", 72),
        DataGridColumn("分支", 120),
        DataGridColumn("最近", 96),
    ]

    var body: some View {
        if git.nestedCandidates.count > 1 {
            GlassSection(
                "所选目录下发现 \(NumberFormat.grouped(git.nestedCandidates.count)) 个仓库",
                // 盘点表 D8「留短藏长」：屏上留「只分析了一个」这个事实（不藏的理由是
                // Z 类：藏掉它，用户会拿这一页的提交数当成整个目录树的数）。
                // 后半句「怎么单独分析其中一个」是操作指引 → 进 ⓘ。ⓘ 里放**整句原句**
                // （短标签是它的前缀），于是中英两侧的键与判据一个字都没变。
                subtitle: "当前只分析了提交数最多的那一个",
                icon: .package,
                trailing: AnyView(CopyHelpBadge("当前只分析了提交数最多的那一个；要单独分析其中某个，直接把它添加为项目"))
            ) {
                DataTableWell {
                    DataTableHeader(columns: Self.columns)
                    ForEach(git.nestedCandidates) { candidate in
                        GitNestedCandidateRow(candidate: candidate,
                                              isAnalyzed: candidate.path == git.resolvedRepositoryRoot,
                                              columns: Self.columns)
                    }
                }
            }
        }
    }
}

// MARK: - 最近提交

struct GitRecentCommitsSection: View {
    let git: GitInsights

    /// 折叠态一行一提交，20 行会把这一组撑成一堵墙（自查清单第 4 条：一组 > 6 行
    /// 同类条目就拆或收进可展开区）。收成 8 行 + 展开，**「显示 N / M 条」那句
    /// 副标题跟着实际展示数走**，展开之后必须改成「已全部展示」，不能停在 8 上骗人。
    static let displayLimit = 8

    @State private var expanded = false

    var body: some View {
        let rows = visibleRows
        GlassSection(
            "最近提交",
            subtitle: git.recentCommits.isEmpty
                ? "无提交记录"
                : localizedFormat("显示 %1$@ / %2$@ 条",
                                   NumberFormat.grouped(rows.count),
                                   NumberFormat.grouped(git.recentCommits.count)),
            icon: .processes
        ) {
            if git.recentCommits.isEmpty {
                git.commitAbsence.emptyState {
                    EmptyStateView(
                        icon: .unverified,
                        title: "本次没有取回最近提交明细",
                        // 盘点表 D15 判「留短藏长」，本轮**原句照旧整段上屏**：
                        // 这一段是 `GitDataAbsence` 三分态共用的兜底空态，卡头挂 ⓘ 会在
                        // 「不适用 / 零提交」那两态里说错话，而 `EmptyStateView` 的
                        // `IconName` 初始化器不转发 `action:`（见汇报的契约缺口）。
                        message: "历史里有提交，但提交记录本身没有带回任何一行（旧报告或分析中断都会这样）。\n趋势与作者统计仍按已解析的部分给出，这里只说明明细缺失。"
                    )
                }
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    DataTableWell {
                        DataTableHeader(columns: DataColumns.recentCommits)
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, commit in
                            GitCommitRow(commit: commit)
                            if index < rows.count - 1 {
                                DataRowSeparator()
                            }
                        }
                    }
                    if git.recentCommits.count > Self.displayLimit {
                        DataDisclosureButton(expanded: expanded,
                                             hiddenCount: git.recentCommits.count - Self.displayLimit,
                                             noun: "条提交") {
                            expanded.toggle()
                        }
                    }
                }
            }
        }
    }

    private var visibleRows: [CommitRecord] {
        expanded ? git.recentCommits : Array(git.recentCommits.prefix(Self.displayLimit))
    }
}
