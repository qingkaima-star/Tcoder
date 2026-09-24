import SwiftUI

/// OWNER: WS-L —— 依赖与安全页。
///
/// 2026-09-19 表格观感统一（WS-L）：依赖表改走 `Views/CodeGit` 的列宽单一来源
/// （原 `DepColumns` 并入 `DataColumns.dependencies`），状态列改走设计系统的
/// `SemanticBadge`（原来自造了一套 `size: 9 / padding 5,2 / cornerRadius 3 / opacity 0.14`
/// 的胶囊，与 `SeverityBadge` 并存），字号与间距全部取自 `Design/` 令牌。
///
/// **判定逻辑一律没动**：`DependencySafetyVerdict` / `DependencyRowStatus` 仍与
/// `GitDependencyTests` 共用同一份口径——那三条"离线零命中不得画绿"的诚实线由测试钉着。
struct DependenciesView: View {
    var report: ProjectReport?

    @Environment(AppState.self) private var state
    @State private var expanded: Set<String> = []

    var body: some View {
        Theme.Page.Scaffold {
            Theme.Page.Header(title: "依赖分析", icon: .package)
            GroupStack {
                NetworkOptionsCard(
                    allowNetwork: Bindable(state).allowNetworkLookups,
                    canRescan: state.selectedProject != nil && !state.isScanning,
                    rescan: { state.scanSelected() }
                )
            }
            if let deps = report?.dependencies {
                if deps.ecosystems.isEmpty {
                    EmptyStateView(
                        icon: .package,
                        title: "项目中未发现可识别的依赖清单",
                        // 一整句 = 一个键。原来拆成 `"…\n" + "…"` 两段拼，
                        // 运行时送进查表的是**拼接后的整串**，目录里那条半句键永远查不中
                        // （英文态照旧显示中文，而守卫 1/2/3 全绿 —— 批次 P5 新守卫抓到）。
                        message: "扫描完成，但没有找到 package.json、Package.swift、pom.xml、go.mod 等清单文件。",
                        help: "如果依赖声明在自定义脚本里，这一页为空是真实结果。"
                    )
                } else {
                    GroupStack {
                        DependencyOverviewSection(deps: deps)
                        DependencySummaryGrid(deps: deps)
                        // RD-13c：六档 scope 分开汇总。此前页面只有一对「运行时 / 开发」，
                        // 测试与构建依赖被并进"运行时"，那句"开发依赖不随产物发布"就没有依据。
                        DependencyScopeBreakdown(deps: deps)
                    }
                    ForEach(deps.ecosystems) { eco in
                        DependencyEcosystemSection(
                            eco: eco,
                            vulnerabilityUnchecked: deps.hasVulnerabilityCoverage == false,
                            isExpanded: expanded.contains(eco.id),
                            toggle: { toggle(eco.id) }
                        )
                    }
                    GroupStack {
                        DependencyAdvisoriesSection(deps: deps)
                    }
                }
            } else {
                EmptyStateView(
                    icon: .package,
                    title: "尚未执行依赖分析",
                    message: "该项目还没有依赖分析结果。点击「重新分析」开始扫描。",
                    help: "需要最新版本与漏洞库在线核对时，先打开上方的联网开关。"
                )
            }
        }
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
        }
    }
}

// MARK: - 指标条

/// 主角 = **依赖总数**，其余三条走无面读数带。
///
/// 为什么主角不是「漏洞数」：离线未核对时 `vulnerableCount` 恒为 0，而 56pt 的一个 0
/// 会被读成「安全」—— 那正是本页最不该出现的误读（`emptyCaption` 那句
/// 「0 条命中只是没有查，不是没有病」就是为了堵它）。把重音给**不含歧义的测得总量**，
/// 漏洞数留在带里、由 `verdict.role` 说话，`mayClaimSafe` 为假时它旁边就是「未核对」。
///
/// 旧形态是 4 块各涂 accent / neutral / warning|success / verdict色 的灰盒：
/// 前两个是给数据上色（契约 5 禁止），后两个是状态（保留，改走 `role:`）。
/// 「依赖总数」那句不含传递依赖的口径说明**跟着升到主角的 note 槽**，一个字没丢。
struct DependencySummaryGrid: View {
    let deps: DependencyReport

    var body: some View {
        let verdict = DependencySafetyVerdict(deps)
        GlassSection("依赖规模", subtitle: "按清单文件统计", icon: .package) {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                DataHeroReadout(value: NumberFormat.grouped(deps.totalDependencies),
                                unit: "项",
                                // 「N 个生态」这个数已经站在下面读数带的第一格里了，
                                // 主角的 note 只留口径本身（"不含传递依赖"是必须读到的那句）。
                                note: "清单直接声明，不含锁文件解析出的传递依赖")

                ReadoutStrip {
                    // ⓘ 收纳轮（盘点表 H 组「生态 caption」判**藏**）：这句是纯指路
                    // （生态名单确实逐字写在上方「风险总览」的「生态」行里），整句进 hover。
                    // `MetricTile.caption` 是 String 槽、没有 ⓘ 位，所以把 tooltip 挂在**整格**
                    // 上（悬停目标是 label+数字那一块，不是一个小图标像素），
                    // 与下方「漏洞数」格挂 `summaryCaption` 的既有形状一致。
                    // 键面一字未动（`Localizable.strings` 已有该整句键）⇒ 屏上不留半句、不新增待登记键。
                    // `caption == nil` 时 MetricTile 仍按 `TileCaptionLayout.reserveLines` 留白，
                    // 同排四格的底边不会差一截。
                    MetricTile(
                        label: "生态",
                        value: NumberFormat.grouped(deps.ecosystems.count),
                        unit: "个"
                    )
                        .help(localizedCopy("清单来源，名单在上方「风险总览」"))
                    DataBandSeparator()
                    MetricTile(
                        label: "运行时 / 开发",
                        value: "\(NumberFormat.grouped(deps.productionCount)) / \(NumberFormat.grouped(deps.devCount))",
                        caption: "开发依赖不随产物发布"
                    )
                    DataBandSeparator()
                    MetricTile(
                        label: "版本过旧",
                        value: deps.outdatedCount > 0 || deps.totalDependencies > 0
                            ? NumberFormat.grouped(deps.outdatedCount) : nil,
                        role: deps.outdatedCount > 0
                            ? Theme.Semantic.warning : Theme.Semantic.success,
                        symbol: CodeGitSymbol.outdated,
                        unit: "项",
                        caption: Self.outdatedCaption(deps)
                    )
                    DataBandSeparator()
                    MetricTile(
                        label: "漏洞数",
                        value: NumberFormat.grouped(deps.vulnerableCount),
                        role: verdict.role,
                        icon: .vulnerable,
                        unit: "条",
                        caption: verdict.tileCaption
                    )
                    // 全口径（覆盖哪些生态、快照截至何时、几项有版本数据）**上屏一次**
                    // 就够了 —— 它已经在上方「风险总览」的口径条里逐字写着。
                    // 这里挂成 tooltip 而不是删掉：`summaryCaption` 那份全文仍然一 hover 就在，
                    // #25 那组诚实线断言盯的也是它（见 HonestyP1SnapshotDateTests）。
                        .help(verdict.summaryCaption)
                }
            }
        }
    }

    /// 0 只有在"确实比对过版本"时才是结论；没有任何版本数据时，0 只是没查。
    static func outdatedCaption(_ deps: DependencyReport) -> String {
        let total = max(1, deps.totalDependencies)
        let share = NumberFormat.percent(Double(deps.outdatedCount) / Double(total), precision: 0)
        guard deps.totalDependencies > 0 else { return localizedCopy("没有可判定的依赖") }
        return deps.outdatedCount > 0
            ? localizedFormat("占依赖总数 %1$@", share)
            : localizedCopy("已比对版本数据，未发现落后项")
    }
}

// MARK: - 风险总览

struct DependencyOverviewSection: View {
    let deps: DependencyReport

    var body: some View {
        let verdict = DependencySafetyVerdict(deps)
        GlassSection(
            "风险总览",
            subtitle: localizedFormat("分析于 %1$@ · %2$@",
                                      LogRecency.describe(deps.analyzedAt),
                                      DateFormat.full.string(from: deps.analyzedAt)),
            icon: .clean,
            trailing: AnyView(SafetyVerdictBadge(verdict: verdict))
        ) {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                // 这一节**不再摆一条读数带**：原来这里的「生态/依赖/过旧/漏洞」四格
                // 与上一节「依赖规模」的 hero + 读数带是同一批数（隔 32pt 说两遍，
                // 且两带格数不同、分隔线错位）。数只在上一次，这一节只留**它独有的东西**：
                // 结论徽标 + 三行来源核对。
                VStack(spacing: DataRowMetrics.rowGap) {
                    DataFieldRow(label: "联网查询",
                                 value: deps.networkLookupPerformed ? "是" : "否", style: .text,
                                 valueColor: deps.networkLookupPerformed
                                     ? Theme.Semantic.success.textColor
                                     : Theme.Semantic.neutral.textColor)
                    DataRowSeparator()
                    DataFieldRow(label: "版本来源",
                                 value: Self.versionSourceCaption(deps),
                                 style: .text,
                                 // 原来吃 `Theme.Semantic.role(for: deps.riskLevel)`：
                                 // `riskLevel` 在零命中时返回 `.none`，而"零命中"在默认
                                 // 离线态下只是"没查"（批次 P7-B）。这一格改走同一份判定。
                                 valueColor: DependencySafetyVerdict(deps).role.textColor)
                    DataRowSeparator()
                    DataFieldRow(label: "生态", value: deps.distinctEcosystemNames.joined(separator: localizedListSeparator()),
                                 style: .text)
                }

                if !deps.networkLookupNote.isEmpty {
                    DataNotice(text: deps.networkLookupNote, role: Theme.Semantic.neutral, icon: .info,
                               iconLabel: "联网核对说明")
                }
            }
        }
    }

    static func versionSourceCaption(_ deps: DependencyReport) -> String {
        deps.ecosystems.contains { eco in
            eco.dependencies.contains { $0.versionCheckSource == .onlineRegistry }
        } ? "含在线源" : "仅内置快照"
    }
}

// MARK: - 单个生态

struct DependencyEcosystemSection: View {
    let eco: EcosystemReport
    /// 整份报告**没有漏洞核对覆盖**（默认不联网、也没带回公告）。
    /// 这时"这个生态无风险"是一句没有证据的话：`eco.riskLevel` 里的 `.none`
    /// 混着"查了没病"与"根本没查"两种意思，展示层必须把它们分开
    /// （判定本体不动，评分与排序仍读 `riskLevel`）。批次 P7-B。
    let vulnerabilityUnchecked: Bool
    let isExpanded: Bool
    let toggle: () -> Void

    static let rowLimit = 12

    /// 卡头的风险槽。**只有"没查出问题"这一档需要核对覆盖背书**：
    /// `.low`/`.medium` 来自锁文件里的过期比例，那是离线也算得出的事实，照旧显示。
    @ViewBuilder
    private var riskSlot: some View {
        if vulnerabilityUnchecked && eco.riskLevel == .none {
            SemanticBadge("未核对", role: Theme.Semantic.neutral, icon: .unverified)
                .help(localizedCopy("默认不联网时漏洞判定恒为 0 条，这是「没有查」，不是「没有病」"))
        } else {
            RiskBadge(risk: eco.riskLevel)
        }
    }

    var body: some View {
        GlassSection(
            eco.ecosystem.displayName,
            subtitle: eco.manifestPath,
            icon: .package,
            trailing: AnyView(riskSlot)
        ) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                VStack(spacing: DataRowMetrics.rowGap) {
                    DataFieldRow(
                        label: "锁文件",
                        value: eco.lockfileName.map {
                            localizedFormat("%1$@（只说明可复现，未计入依赖数）", $0)
                        } ?? localizedCopy("未发现"),
                        style: .text)
                    DataFieldRow(label: "依赖", value: NumberFormat.grouped(eco.dependencies.count),
                                 style: .number)
                }

                if !eco.frameworkMarkers.isEmpty {
                    HStack(alignment: .center, spacing: Theme.Spacing.xs) {
                        Text("框架标记")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        ForEach(eco.frameworkMarkers, id: \.self) { marker in
                            SemanticBadge(marker, role: Theme.Semantic.neutral)
                        }
                    }
                }

                DependencyTable(eco: eco, isExpanded: isExpanded, toggle: toggle)
            }
        }
    }
}

/// 依赖表：表头与数据行共用同一份列定义，名称列左对齐、其余尾对齐等宽。
struct DependencyTable: View {
    let eco: EcosystemReport
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        let sorted = Self.sortedNames(eco.dependencies)
        let visible = isExpanded ? sorted : Array(sorted.prefix(DependencyEcosystemSection.rowLimit))

        if sorted.isEmpty {
            DataCaption(text: "该清单没有解析出可枚举的依赖项。")
        } else {
            DataTableWell {
                DataTableHeader(columns: DataColumns.dependencies)
                ForEach(visible) { record in
                    DependencyRow(record: record)
                    if record.id != visible.last?.id {
                        DataRowSeparator()
                    }
                }
            }
            if sorted.count > DependencyEcosystemSection.rowLimit {
                // 展开/收起是**控件**，所以 accent 在它身上合法（契约 5 的交互语义）。
                // 计数走 `DisclosureNoun` 那把整句键（P56）：这里以前是
                // `"展开其余 \(n) 项"` 拼串 ⇒ 英文态整句中文，且英语的单复数无处安放。
                GlassButton(isExpanded ? "收起"
                            : localizedCount(DisclosureNoun.items.expandKey,
                                             sorted.count - DependencyEcosystemSection.rowLimit),
                            style: .bordered, action: toggle)
            }
            // ⓘ 收纳轮（盘点表 H 组「DependencyTable.countNote」判留短藏长）：
            // 屏上只留"展示了多少项"（折叠必须被计数交代），多出来的那半句排序口径进 hover。
            // 走 Design 已有的 `DataOptionalHelp`：`help == nil` 时它一个东西都不挂，
            // 所以"已全部展示"那一支不会凭空多一次落点。
            DataFootnote(text: Self.countLabel(total: sorted.count, shown: visible.count))
                .modifier(DataOptionalHelp(help: sorted.count > visible.count
                    ? Self.countNote(total: sorted.count, shown: visible.count)
                    : nil))
        }
    }

    static func sortedNames(_ dependencies: [DependencyRecord]) -> [DependencyRecord] {
        dependencies.sorted {
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.version < $1.version
        }
    }

    /// 屏上那一句：原句里"计数"那一层，逐字取前半。**整句键**——写成插值字面串就等于让
    /// 英文态那句英文中间掉进一段中文；本仓依赖清单为空，这条分支只在换个大仓时才上屏（P67 拿 Homebrew 抓到）。
    static func countLabel(total: Int, shown: Int) -> String {
        guard total > shown else {
            return localizedFormat("共 %1$@ 项，已全部展示。", NumberFormat.grouped(total))
        }
        return localizedFormat("当前展示 %1$@ / %2$@ 项。",
                               NumberFormat.grouped(shown), NumberFormat.grouped(total))
    }

    /// 折叠必须被计数交代：只显示 12 行而不说「共 N 项」，用户会把 12 当成全部。
    /// **整句**（含排序口径）现在是 ⓘ 里那一句，屏上的短句是它的前半 —— 两个落点不重叠。
    static func countNote(total: Int, shown: Int) -> String {
        // 全部展示时"完整读法"与"屏上短句"是同一句话 ⇒ 引用，不留第二份字面。
        guard total > shown else { return countLabel(total: total, shown: shown) }
        return localizedFormat("当前展示 %1$@ / %2$@ 项 · 按名称排序。",
                               NumberFormat.grouped(shown), NumberFormat.grouped(total))
    }
}

// MARK: - 安全公告

struct DependencyAdvisoriesSection: View {
    let deps: DependencyReport

    var body: some View {
        let items = DependencyVulnerabilityItems.merged(from: deps)
        GlassSection(
            "安全公告",
            subtitle: Self.subtitle(items: items, deps: deps),
            icon: .riskSevere
        ) {
            if items.isEmpty {
                DataNotice(text: Self.emptyCaption(deps),
                           role: DependencySafetyVerdict(deps).role,
                           icon: DependencySafetyVerdict(deps).badgeIcon,
                           iconLabel: "漏洞核对状态")
            } else {
                VStack(spacing: DataRowMetrics.rowGap) {
                    ForEach(items) { item in
                        VulnerabilityRow(item: item)
                        if item.id != items.last?.id {
                            DataRowSeparator()
                        }
                    }
                }
            }
        }
    }

    static func subtitle(items: [VulnerabilityItem], deps: DependencyReport) -> String {
        items.isEmpty
            ? localizedCopy("内置快照与安全公告均未命中")
            : localizedFormat("共 %1$@ 条 · 影响 %2$@ 个依赖",
                              NumberFormat.grouped(items.count),
                              NumberFormat.grouped(deps.vulnerableCount))
    }

    /// 空列表不等于「没有漏洞」：默认离线时 `vulnerableCount` 恒为 0，那是「没查」。
    /// RD-68：分派收回 `DependencySafetyVerdict.advisoryEmptyCaption` —— 视图里再 `switch`
    /// 一次"是不是 `.clean`"就是第二把尺子（那正是「已完成核对」在部分覆盖时上屏的走法）。
    static func emptyCaption(_ deps: DependencyReport) -> String {
        DependencySafetyVerdict(deps).advisoryEmptyCaption
    }
}
