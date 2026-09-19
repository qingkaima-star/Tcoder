import SwiftUI

/// OWNER: WS-B / 子代理4 —— 依赖与安全页。
/// 数据来自 `report?.dependencies`；「没跑过分析」和「真没有清单」是两种空状态。
struct DependenciesView: View {
    var report: ProjectReport?

    @Environment(AppState.self) private var state
    @State private var expanded: Set<String> = []

    private static let rowLimit = 40
    private static let metricColumns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    var body: some View {
        @Bindable var state = state

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                NetworkOptionsCard(
                    allowNetwork: $state.allowNetworkLookups,
                    canRescan: state.selectedProject != nil && !state.isScanning,
                    rescan: { state.scanSelected() }
                )
                if let deps = report?.dependencies {
                    if deps.ecosystems.isEmpty {
                        EmptyStateView(
                            icon: "shippingbox",
                            title: "项目中未发现可识别的依赖清单",
                            message: "扫描完成，但没有找到 package.json、Package.swift、pom.xml、go.mod 等清单文件。\n如果依赖声明在自定义脚本里，这一页为空是真实结果。"
                        )
                        .frame(maxWidth: .infinity, minHeight: 240)
                    } else {
                        summaryGrid(deps)
                        overviewCard(deps)
                        ForEach(deps.ecosystems) { eco in
                            ecosystemCard(eco)
                        }
                        advisoriesCard(deps)
                    }
                } else {
                    EmptyStateView(
                        icon: "shippingbox.fill",
                        title: "尚未执行依赖分析",
                        message: "该项目还没有依赖分析结果。点击右上「重新分析」开始扫描。\n需要最新版本与漏洞库在线核对时，先打开下方的联网开关。"
                    )
                    .frame(maxWidth: .infinity, minHeight: 240)
                }
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: - Summary

    private func summaryGrid(_ deps: DependencyReport) -> some View {
        let total = max(1, deps.totalDependencies)
        return LazyVGrid(columns: Self.metricColumns, spacing: 12) {
            MetricTile(
                label: "依赖总数",
                value: NumberFormat.grouped(deps.totalDependencies),
                unit: "项",
                caption: "覆盖 \(deps.ecosystems.count) 个生态",
                tint: Theme.accent,
                systemImage: "shippingbox.fill"
            )
            MetricTile(
                label: "运行时 / 开发",
                value: "\(NumberFormat.grouped(deps.productionCount)) / \(NumberFormat.grouped(deps.devCount))",
                caption: "开发依赖不随产物发布",
                tint: Theme.neutral,
                systemImage: "point.forward.to.point.capsulepath"
            )
            MetricTile(
                label: "版本过旧",
                value: NumberFormat.grouped(deps.outdatedCount),
                unit: "项",
                caption: "占依赖总数 \(NumberFormat.percent(Double(deps.outdatedCount) / Double(total), precision: 0))",
                tint: deps.outdatedCount > 0 ? Theme.caution : Theme.healthy,
                systemImage: "arrow.down.circle"
            )
            MetricTile(
                label: "漏洞数",
                value: NumberFormat.grouped(deps.vulnerableCount),
                unit: "条",
                caption: deps.vulnerableCount > 0 ? "命中内置快照与安全公告" : "未发现已知漏洞",
                tint: Theme.color(for: deps.riskLevel),
                systemImage: "exclamationmark.shield.fill"
            )
        }
    }

    private func overviewCard(_ deps: DependencyReport) -> some View {
        SectionCard(
            "风险总览",
            subtitle: "分析于 \(LogRecency.describe(deps.analyzedAt)) · \(DateFormat.full.string(from: deps.analyzedAt))",
            icon: "shield.lefthalf.filled",
            trailing: AnyView(RiskBadge(risk: deps.riskLevel))
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    StatLine(label: "生态", value: NumberFormat.grouped(deps.ecosystems.count))
                    StatLine(label: "依赖", value: NumberFormat.grouped(deps.totalDependencies))
                    StatLine(label: "过旧", value: NumberFormat.grouped(deps.outdatedCount))
                    StatLine(label: "漏洞", value: NumberFormat.grouped(deps.vulnerableCount))
                    Spacer(minLength: 0)
                }
                HStack(spacing: 16) {
                    StatLine(label: "联网查询", value: deps.networkLookupPerformed ? "是" : "否")
                    StatLine(
                        label: "版本来源",
                        value: deps.ecosystems.contains { eco in
                            eco.dependencies.contains { $0.versionCheckSource == .onlineRegistry }
                        } ? "含在线源" : "仅内置快照"
                    )
                    Spacer(minLength: 0)
                }
                Text("生态：\(deps.distinctEcosystemNames.joined(separator: "、"))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if !deps.networkLookupNote.isEmpty {
                    BannerRow(text: deps.networkLookupNote, style: .info)
                }
            }
        }
    }

    // MARK: - Per ecosystem

    private func ecosystemCard(_ eco: EcosystemReport) -> some View {
        SectionCard(
            eco.ecosystem.displayName,
            subtitle: eco.manifestPath,
            icon: "doc.text.fill",
            trailing: AnyView(RiskBadge(risk: eco.riskLevel))
        ) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 14) {
                    StatLine(label: "锁文件", value: eco.lockfileName ?? "未发现")
                    StatLine(label: "依赖", value: NumberFormat.grouped(eco.dependencies.count))
                    Spacer(minLength: 0)
                }
                if !eco.frameworkMarkers.isEmpty {
                    HStack(spacing: 4) {
                        Text("框架标记")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        ForEach(eco.frameworkMarkers, id: \.self) { marker in
                            Text(marker)
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Theme.accent.opacity(0.12), in: Capsule())
                        }
                    }
                }
                dependencyTable(eco)
            }
        }
    }

    @ViewBuilder
    private func dependencyTable(_ eco: EcosystemReport) -> some View {
        let sorted = eco.dependencies.sorted {
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.version < $1.version
        }
        let isExpanded = expanded.contains(eco.id)
        let visible = isExpanded ? sorted : Array(sorted.prefix(Self.rowLimit))

        if sorted.isEmpty {
            Text("该清单没有解析出可枚举的依赖项。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                DependencyTableHeader(count: sorted.count)
                Divider().opacity(0.4)
                ForEach(visible) { record in
                    DependencyRow(record: record, vulnerableCount: record.knownVulnerabilities.count)
                }
            }
            if sorted.count > Self.rowLimit {
                Button(isExpanded ? "收起" : "展开其余 \(NumberFormat.grouped(sorted.count - Self.rowLimit)) 项") {
                    if isExpanded {
                        expanded.remove(eco.id)
                    } else {
                        expanded.insert(eco.id)
                    }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(Theme.accent)
            }
        }
    }

    // MARK: - Vulnerabilities

    private func advisoriesCard(_ deps: DependencyReport) -> some View {
        let items = vulnerabilityItems(deps)
        return SectionCard(
            "安全公告",
            subtitle: items.isEmpty
                ? "内置快照与安全公告均未命中"
                : "共 \(NumberFormat.grouped(items.count)) 条 · 影响 \(NumberFormat.grouped(deps.vulnerableCount)) 个依赖",
            icon: "exclamationmark.triangle.fill"
        ) {
            if items.isEmpty {
                Text("内置快照未发现已知漏洞。")
                    .font(.caption)
                    .foregroundStyle(Theme.healthy)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(items) { item in
                        VulnerabilityRow(item: item)
                        if item.id != items.last?.id {
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
        }
    }

    /// 离线快照与在线公告合并成同一个视图行模型（不往 Models 里加类型）。
    private func vulnerabilityItems(_ deps: DependencyReport) -> [VulnerabilityItem] {
        var items: [VulnerabilityItem] = []
        for vuln in deps.offlineVulnerabilities {
            items.append(VulnerabilityItem(
                id: "off-\(vuln.id)",
                severity: vuln.severity,
                aliases: vuln.cveIdentifiers,
                targets: vuln.affectedDependencies.isEmpty ? [vuln.package] : vuln.affectedDependencies,
                range: "\(vuln.package) \(vuln.vulnerableRange)",
                summary: vuln.summary,
                advice: vuln.fixedVersion.map { "建议升级至 \($0)" },
                score: nil,
                source: vuln.ecosystem.displayName
            ))
        }
        for advisory in deps.advisories {
            items.append(VulnerabilityItem(
                id: "adv-\(advisory.id)",
                severity: advisory.severity,
                aliases: advisory.aliases,
                targets: advisory.affectedPackages,
                range: nil,
                summary: advisory.summary,
                advice: advisory.details.isEmpty ? nil : advisory.details,
                score: advisory.cvssScore,
                source: advisory.source.isEmpty ? advisory.ecosystem.displayName : advisory.source
            ))
        }
        return items.sorted {
            if $0.severity.rank != $1.severity.rank { return $0.severity.rank > $1.severity.rank }
            return $0.id < $1.id
        }
    }
}

// MARK: - Supporting types

private struct VulnerabilityItem: Identifiable {
    let id: String
    let severity: RiskLevel
    let aliases: [String]
    let targets: [String]
    let range: String?
    let summary: String
    let advice: String?
    let score: Double?
    let source: String
}

private struct NetworkOptionsCard: View {
    @Binding var allowNetwork: Bool
    var canRescan: Bool
    var rescan: () -> Void

    var body: some View {
        SectionCard("分析选项", subtitle: "联网核对会显著变慢，离线时仍会用内置快照", icon: "network") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Toggle("分析时联网查询最新版本与漏洞库", isOn: $allowNetwork)
                        .toggleStyle(.switch)
                        .font(.callout)
                    Spacer(minLength: 8)
                    Button(action: rescan) {
                        Label("重新分析", systemImage: "arrow.clockwise")
                    }
                    .disabled(!canRescan)
                    .help("对当前项目重新执行全部分析器")
                }
                if allowNetwork {
                    Text("开启后需要重新执行分析才会生效。")
                        .font(.caption)
                        .foregroundStyle(Theme.caution)
                } else {
                    Text("当前为离线模式，版本与漏洞结论来自内置快照。")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

private struct DependencyTableHeader: View {
    var count: Int

    var body: some View {
        HStack(spacing: 8) {
            Text("依赖（\(NumberFormat.grouped(count))）")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("声明版本").frame(width: DepColumns.version, alignment: .trailing)
            Text("已知最新").frame(width: DepColumns.latest, alignment: .trailing)
            Text("作用域").frame(width: DepColumns.scope, alignment: .trailing)
            Text("状态").frame(width: DepColumns.status, alignment: .trailing)
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.tertiary)
    }
}

/// 列宽在表头与数据行之间共用（文件级 private 对本文件所有类型可见）。
private enum DepColumns {
    static let version: CGFloat = 78
    static let latest: CGFloat = 78
    static let scope: CGFloat = 46
    static let status: CGFloat = 60
}

private struct DependencyRow: View {
    let record: DependencyRecord
    let vulnerableCount: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(record.name)
                .font(Theme.monoSmall)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(record.manifestPath)
            Text(record.version)
                .font(Theme.monoSmall)
                .foregroundStyle(.secondary)
                .frame(width: DepColumns.version, alignment: .trailing)
            Text(record.latestKnownVersion ?? "—")
                .font(Theme.monoSmall)
                .foregroundStyle(record.latestKnownVersion == nil ? Color.secondary : Color.primary)
                .frame(width: DepColumns.latest, alignment: .trailing)
            Text(record.scope.rawValue)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .frame(width: DepColumns.scope, alignment: .trailing)
            Text(statusText)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(statusTint)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(statusTint.opacity(0.14), in: RoundedRectangle(cornerRadius: 3))
                .frame(width: DepColumns.status, alignment: .trailing)
                .help("版本数据来源：\(record.versionCheckSource.rawValue)；共 \(NumberFormat.grouped(vulnerableCount)) 条已知漏洞")
        }
    }

    private var statusText: String {
        if vulnerableCount > 0 { return "有漏洞" }
        return record.isProbablyOutdated ? "过旧" : "正常"
    }

    private var statusTint: Color {
        if vulnerableCount > 0 { return Theme.danger }
        return record.isProbablyOutdated ? Theme.caution : Theme.healthy
    }
}

private struct VulnerabilityRow: View {
    let item: VulnerabilityItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Theme.color(for: item.severity))
                .frame(width: 4, height: 34)
                .help("严重度 \(item.severity.rawValue)")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.severity.rawValue)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.color(for: item.severity))
                    if let score = item.score {
                        Text(String(format: "CVSS %.1f", score))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text(item.source)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Text(item.summary).font(.caption).lineLimit(2)
                Text(targetsLine)
                    .font(Theme.monoSmall)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if let advice = item.advice {
                    Text(advice)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.healthy)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
        }
    }

    private var targetsLine: String {
        let prefix = item.range.map { "\($0) → " } ?? ""
        let list = item.targets.prefix(4).joined(separator: ", ")
        let more = item.targets.count > 4 ? " 等 \(item.targets.count) 项" : ""
        return "\(prefix)\(list)\(more)"
    }
}
