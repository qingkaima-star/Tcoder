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
        let verdict = DependencySafetyVerdict(deps)
        return LazyVGrid(columns: Self.metricColumns, spacing: 12) {
            MetricTile(
                label: "依赖总数",
                value: NumberFormat.grouped(deps.totalDependencies),
                unit: "项",
                caption: "清单直接声明，不含锁文件解析出的传递依赖 · \(deps.ecosystems.count) 个生态",
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
                caption: verdict.summaryCaption,
                tint: verdict.tint,
                systemImage: "exclamationmark.shield.fill"
            )
        }
    }

    private func overviewCard(_ deps: DependencyReport) -> some View {
        SectionCard(
            "风险总览",
            subtitle: "分析于 \(LogRecency.describe(deps.analyzedAt)) · \(DateFormat.full.string(from: deps.analyzedAt))",
            icon: "shield.lefthalf.filled",
            trailing: AnyView(SafetyVerdictBadge(verdict: DependencySafetyVerdict(deps)))
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
                    StatLine(label: "锁文件",
                             value: eco.lockfileName.map { "\($0)（只说明可复现，未计入依赖数）" } ?? "未发现")
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
                    DependencyRow(record: record)
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

    var body: some View {
        let status = DependencyRowStatus.of(record)
        return HStack(spacing: 8) {
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
            Text(status.text)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(status.tint)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(status.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 3))
                .frame(width: DepColumns.status, alignment: .trailing)
                .help(status.tooltip(record: record))
        }
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

// MARK: - 安全结论口径（视图与单元测试共用同一份判定，避免"测的是一套、渲染的是另一套"）

/// 「零漏洞」有三层完全不同的含义，必须分开给结论。
///
/// 默认 `allowNetworkLookups = false`，此时 `vulnerableCount` 恒为 0：如果就据此画绿，
/// 等于把「根本没查」说成「查了且没病」。判定一律走 `DependencyReport.hasVulnerabilityCoverage`。
enum DependencySafetyVerdict: Equatable {
    /// 真的有命中。
    case findings(count: Int, risk: RiskLevel)
    /// 没联网、也没拿到任何在线公告 —— 零命中只是"未判定"。
    case unchecked(coveredCount: Int, total: Int, uncoveredEcosystems: [String])
    /// 做过在线核对（或已带回公告），结论才是"干净"。
    case clean(coveredCount: Int, total: Int)

    init(_ report: DependencyReport) {
        let records = report.ecosystems.flatMap(\.dependencies)
        let covered = records.filter { $0.versionCheckSource != .none }.count
        let total = report.totalDependencies
        if report.vulnerableCount > 0 {
            self = .findings(count: report.vulnerableCount, risk: report.riskLevel)
        } else if report.hasVulnerabilityCoverage {
            self = .clean(coveredCount: covered, total: total)
        } else {
            self = .unchecked(coveredCount: covered, total: total,
                              uncoveredEcosystems: ManifestDependencyAnalyzer.ecosystemsWithoutOfflineRules(in: report))
        }
    }

    /// 允许出现"绿色 = 安全"结论的唯一两种状态。
    var mayClaimSafe: Bool {
        switch self {
        case .findings, .unchecked: return false
        case .clean: return true
        }
    }

    var tint: Color {
        switch self {
        case .findings(let count, _) where count > 0: return Theme.danger
        case .findings(_, let risk): return Theme.color(for: risk)
        case .unchecked: return Theme.neutral
        case .clean: return Theme.healthy
        }
    }

    var badgeText: String {
        switch self {
        case .findings(_, let risk): return "风险 \(risk.rawValue)"
        case .unchecked: return "未核对"
        case .clean: return "已核对"
        }
    }

    /// 「漏洞数」磁贴的副标题：绿色 all-clear 只在真的核对过时才允许出现。
    var summaryCaption: String {
        switch self {
        case .findings(let count, _):
            return "命中 \(NumberFormat.grouped(count)) 条内置快照与安全公告"
        case .unchecked(let covered, let total, let uncovered):
            var text = "未联网核对，仅内置快照（覆盖 npm / Maven / Python）"
            text += total == 0 ? "· 无依赖可核对" : "· \(NumberFormat.grouped(covered)) / \(NumberFormat.grouped(total)) 项有版本数据"
            if !uncovered.isEmpty { text += "· 未覆盖生态：\(uncovered.joined(separator: "、"))" }
            return text
        case .clean(let covered, let total):
            if covered == 0 { return "已联网核对，但无可比对版本数据的依赖" }
            if covered >= total { return "全部 \(NumberFormat.grouped(total)) 项已比对，未发现已知漏洞" }
            return "\(NumberFormat.grouped(covered)) / \(NumberFormat.grouped(total)) 项已比对，未发现已知漏洞"
        }
    }
}

/// 单条依赖的状态徽章。绿只给"确实拿到在线结论"的行 ——
/// 几百行未核对的依赖挂几百个常驻绿徽章，就是几百条没依据的 all-clear。
enum DependencyRowStatus: Equatable {
    case vulnerable(count: Int)
    case outdated
    /// 版本来源是在线源，且无公告：这是真核对过的干净。
    case verifiedSafe
    /// 只有内置快照比对了版本，漏洞层面没联网查过。
    case versionOnly
    /// 连版本都没有可比对。
    case unchecked

    static func of(_ record: DependencyRecord) -> DependencyRowStatus {
        if !record.knownVulnerabilities.isEmpty { return .vulnerable(count: record.knownVulnerabilities.count) }
        if record.isProbablyOutdated { return .outdated }
        switch record.versionCheckSource {
        case .onlineRegistry: return .verifiedSafe
        case .bundledSnapshot: return .versionOnly
        case .none: return .unchecked
        }
    }

    var text: String {
        switch self {
        case .vulnerable: return "有漏洞"
        case .outdated: return "过旧"
        case .verifiedSafe: return "正常"
        case .versionOnly: return "仅版本比对"
        case .unchecked: return "未核对"
        }
    }

    var tint: Color {
        switch self {
        case .vulnerable: return Theme.danger
        case .outdated: return Theme.caution
        case .verifiedSafe: return Theme.healthy
        case .versionOnly, .unchecked: return Theme.neutral
        }
    }

    func tooltip(record: DependencyRecord) -> String {
        let base = "版本数据来源：\(record.versionCheckSource.rawValue)；声明版本 \(record.version)"
        switch self {
        case .vulnerable(let count): return "\(base)；\(count) 条已知漏洞：\(record.knownVulnerabilities.joined(separator: "、"))"
        case .outdated: return "\(base)；内置/在线最新为 \(record.latestKnownVersion ?? "未知")，未联网核对漏洞"
        case .verifiedSafe: return "\(base)；在线核对过，无已知公告"
        case .versionOnly: return "\(base)；只比对了版本新旧，漏洞层面未联网核对"
        case .unchecked: return "\(base)；无可比对数据（版本不可解析或该生态无快照）"
        }
    }
}

/// 未核对时用中性徽章并写明"未核对"，不复用 `RiskBadge(.none)` 的绿底对勾。
/// （`Theme.swift` 的 `RiskBadge` 归 WS-G，本文件不改它。）
private struct SafetyVerdictBadge: View {
    let verdict: DependencySafetyVerdict

    var body: some View {
        switch verdict {
        case .findings(_, let risk):
            RiskBadge(risk: risk)
        case .clean:
            RiskBadge(risk: .none)
        case .unchecked:
            Text(verdict.badgeText)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.neutral)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Theme.neutral.opacity(0.14), in: Capsule())
                .help("默认不联网时漏洞判定恒为 0 条，这是「没有查」，不是「没有病」")
        }
    }
}
