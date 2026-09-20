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
                        message: "扫描完成，但没有找到 package.json、Package.swift、pom.xml、go.mod 等清单文件。\n"
                            + "如果依赖声明在自定义脚本里，这一页为空是真实结果。"
                    )
                } else {
                    GroupStack {
                        DependencyOverviewSection(deps: deps)
                        DependencySummaryGrid(deps: deps)
                    }
                    ForEach(deps.ecosystems) { eco in
                        DependencyEcosystemSection(
                            eco: eco,
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
                    message: "该项目还没有依赖分析结果。点击「重新分析」开始扫描。\n"
                        + "需要最新版本与漏洞库在线核对时，先打开上方的联网开关。"
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
        GlassSection("依赖规模", subtitle: "清单直接声明数 · 不含锁文件里的传递依赖", icon: .package) {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                DataHeroReadout(value: NumberFormat.grouped(deps.totalDependencies),
                                unit: "项",
                                note: "\(NumberFormat.grouped(deps.ecosystems.count)) 个生态的清单直接声明，"
                                    + "不含锁文件解析出的传递依赖")

                ReadoutStrip {
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
                        caption: verdict.summaryCaption
                    )
                }
            }
        }
    }

    /// 0 只有在"确实比对过版本"时才是结论；没有任何版本数据时，0 只是没查。
    static func outdatedCaption(_ deps: DependencyReport) -> String {
        let total = max(1, deps.totalDependencies)
        let share = NumberFormat.percent(Double(deps.outdatedCount) / Double(total), precision: 0)
        guard deps.totalDependencies > 0 else { return "没有可判定的依赖" }
        return deps.outdatedCount > 0
            ? "占依赖总数 \(share)"
            : "已比对版本数据，未发现落后项"
    }
}

// MARK: - 风险总览

struct DependencyOverviewSection: View {
    let deps: DependencyReport

    var body: some View {
        let verdict = DependencySafetyVerdict(deps)
        GlassSection(
            "风险总览",
            subtitle: "分析于 \(LogRecency.describe(deps.analyzedAt)) · "
                + DateFormat.full.string(from: deps.analyzedAt),
            icon: .clean,
            trailing: AnyView(SafetyVerdictBadge(verdict: verdict))
        ) {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                DataReadoutBand {
                    DataReadout(label: "生态", value: NumberFormat.grouped(deps.ecosystems.count),
                                caption: "个清单来源")
                    DataBandSeparator()
                    DataReadout(label: "依赖", value: NumberFormat.grouped(deps.totalDependencies),
                                caption: "项直接声明")
                    DataBandSeparator()
                    DataReadout(label: "过旧", value: NumberFormat.grouped(deps.outdatedCount),
                                caption: "项",
                                role: deps.outdatedCount > 0 ? Theme.Semantic.warning : nil)
                    DataBandSeparator()
                    DataReadout(label: "漏洞", value: NumberFormat.grouped(deps.vulnerableCount),
                                caption: verdict.mayClaimSafe ? "条已核对" : "条（未核对）",
                                role: verdict.role)
                }

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
                                 valueColor: Theme.Semantic.role(for: deps.riskLevel).textColor)
                    DataRowSeparator()
                    DataFieldRow(label: "生态", value: deps.distinctEcosystemNames.joined(separator: "、"),
                                 style: .text)
                }

                if !deps.networkLookupNote.isEmpty {
                    DataNotice(text: deps.networkLookupNote, role: Theme.Semantic.info, icon: .info,
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
    let isExpanded: Bool
    let toggle: () -> Void

    static let rowLimit = 12

    var body: some View {
        GlassSection(
            eco.ecosystem.displayName,
            subtitle: eco.manifestPath,
            icon: .package,
            trailing: AnyView(RiskBadge(risk: eco.riskLevel))
        ) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                VStack(spacing: DataRowMetrics.rowGap) {
                    DataFieldRow(
                        label: "锁文件",
                        value: eco.lockfileName.map {
                            "\($0)（只说明可复现，未计入依赖数）"
                        } ?? "未发现",
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
                GlassButton(isExpanded ? "收起"
                            : "展开其余 \(NumberFormat.grouped(sorted.count - DependencyEcosystemSection.rowLimit)) 项",
                            style: .bordered, action: toggle)
            }
            DataFootnote(text: Self.countNote(total: sorted.count, shown: visible.count))
        }
    }

    static func sortedNames(_ dependencies: [DependencyRecord]) -> [DependencyRecord] {
        dependencies.sorted {
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.version < $1.version
        }
    }

    /// 折叠必须被计数交代：只显示 12 行而不说「共 N 项」，用户会把 12 当成全部。
    static func countNote(total: Int, shown: Int) -> String {
        guard total > shown else {
            return "共 \(NumberFormat.grouped(total)) 项，已全部展示。"
        }
        return "当前展示 \(NumberFormat.grouped(shown)) / \(NumberFormat.grouped(total)) 项 · "
            + "按名称排序。"
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
            ? "内置快照与安全公告均未命中"
            : "共 \(NumberFormat.grouped(items.count)) 条 · 影响 "
                + "\(NumberFormat.grouped(deps.vulnerableCount)) 个依赖"
    }

    /// 空列表不等于「没有漏洞」：默认离线时 `vulnerableCount` 恒为 0，那是「没查」。
    static func emptyCaption(_ deps: DependencyReport) -> String {
        switch DependencySafetyVerdict(deps) {
        case .unchecked:
            return "本次未联网核对，0 条命中只是「没有查」，不是「没有病」。"
        case .clean:
            return "已完成核对，未发现已知漏洞。"
        case .findings:
            return "有命中，见上方列表。"
        }
    }
}

// MARK: - 联网开关（控件层）

struct NetworkOptionsCard: View {
    @Binding var allowNetwork: Bool
    var canRescan: Bool
    var rescan: () -> Void

    var body: some View {
        GlassSection("分析选项", subtitle: "联网核对会显著变慢，离线时仍会用内置快照", icon: .network) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(spacing: DataRowMetrics.cellGap) {
                    Toggle("分析时联网查询最新版本与漏洞库", isOn: $allowNetwork)
                        .toggleStyle(.switch)
                        .font(CodeGitType.prose(Theme.Typo.body))
                    Spacer(minLength: Theme.Spacing.sm)
                    GlassButton("重新分析", icon: .reanalyze, style: .prominent,
                                isEnabled: canRescan, action: rescan)
                        .help("对当前项目重新执行全部分析器")
                }
                Text(Self.statusCaption(allowNetwork: allowNetwork))
                    .monospacedDigit()
                    .foregroundStyle(allowNetwork
                        ? Theme.Semantic.warning.textColor
                        : Theme.Semantic.neutral.textColor)
            }
        }
    }

    static func statusCaption(allowNetwork: Bool) -> String {
        allowNetwork
            ? "开启后需要重新执行分析才会生效。"
            : "当前为离线模式，版本与漏洞结论来自内置快照。"
    }
}
