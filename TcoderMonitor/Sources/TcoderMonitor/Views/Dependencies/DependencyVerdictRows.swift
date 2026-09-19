import SwiftUI

// MARK: - 依赖页的行件与结论口径（WS-L）
//
// `DependencySafetyVerdict` 与 `DependencyRowStatus` 是**视图与单元测试共用的一份判定**
// （`GitDependencyTests` 直接断言这两个类型），重样只换渲染，不改任何判据与文案：
// 「默认不联网时 vulnerableCount 恒为 0」这条线一旦被渲染成绿色 all-clear，就是把
// 「根本没查」说成「查了且没病」。
//
// 状态胶囊改走设计系统的 `SemanticBadge`（10pt Medium + `Spacing.chip` 内边距 +
// 同色 0.15 底 + 胶囊 + 图标双通道）。原来这里自造了第五套胶囊
// （`size:9 .bold` + `padding 5/2` + `cornerRadius 3` + `opacity 0.14`），WS-I §3.1 点名。

// MARK: 单条依赖的状态

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

    var role: Theme.SemanticRole {
        switch self {
        case .vulnerable: return Theme.Semantic.danger
        case .outdated: return Theme.Semantic.warning
        case .verifiedSafe: return Theme.Semantic.success
        case .versionOnly, .unchecked: return Theme.Semantic.neutral
        }
    }

    /// 色 + 文字 + 图标三通道：色觉障碍与灰度打印下结论仍然可读（WS-H §10）。
    var badgeIcon: IconName {
        switch self {
        case .vulnerable: return .vulnerable
        case .outdated: return .riskWarning
        case .verifiedSafe: return .noRisk
        case .versionOnly: return .info
        case .unchecked: return .unverified
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

// MARK: 安全结论

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

    var role: Theme.SemanticRole {
        switch self {
        case .findings(let count, _) where count > 0: return Theme.Semantic.danger
        case .findings(_, let risk): return Theme.Semantic.role(for: risk)
        case .unchecked: return Theme.Semantic.neutral
        case .clean: return Theme.Semantic.success
        }
    }

    var badgeIcon: IconName {
        switch self {
        case .findings: return .riskSevere
        case .unchecked: return .unverified
        case .clean: return .clean
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

/// 未核对时用中性徽标并写明"未核对"，不复用 `RiskBadge(.none)` 的绿底对勾。
struct SafetyVerdictBadge: View {
    let verdict: DependencySafetyVerdict

    var body: some View {
        switch verdict {
        case .findings(_, let risk):
            RiskBadge(risk: risk)
        case .clean:
            RiskBadge(risk: .none)
        case .unchecked:
            SemanticBadge(verdict.badgeText, role: verdict.role, icon: verdict.badgeIcon)
                .help("默认不联网时漏洞判定恒为 0 条，这是「没有查」，不是「没有病」")
        }
    }
}

// MARK: 公告行模型

/// 离线快照与在线公告合并成同一个视图行模型（不往 Models 里加类型）。
struct VulnerabilityItem: Identifiable {
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

enum DependencyVulnerabilityItems {
    static func merged(from deps: DependencyReport) -> [VulnerabilityItem] {
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

// MARK: 依赖行

struct DependencyRow: View {
    let record: DependencyRecord

    private var columns: [DataGridColumn] { DataColumns.dependencies }
    private var status: DependencyRowStatus { .of(record) }

    var body: some View {
        HStack(spacing: DataRowMetrics.cellGap) {
            Text(record.name)
                .font(CodeGitType.tableIdentifier)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .tableCell(DataColumns.column(columns, 0))
                .help(record.manifestPath)

            Text(record.version)
                .font(CodeGitType.number(Theme.Typo.monoSmall))
                .foregroundStyle(.secondary)
                .tableCell(DataColumns.column(columns, 1))

            Text(record.latestKnownVersion ?? Theme.Placeholder.missingValue)
                .font(CodeGitType.number(Theme.Typo.monoSmall))
                .foregroundStyle(record.latestKnownVersion == nil
                    ? Theme.Semantic.neutral.textColor : Color.primary)
                .tableCell(DataColumns.column(columns, 2))

            Text(record.scope.rawValue)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .tableCell(DataColumns.column(columns, 3))

            SemanticBadge(status.text, role: status.role, icon: status.badgeIcon)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .tableCell(DataColumns.column(columns, 4))
                .help(status.tooltip(record: record))
        }
        .dataTableRow()
    }
}

// MARK: 公告行

struct VulnerabilityRow: View {
    let item: VulnerabilityItem

    private var role: Theme.SemanticRole { Theme.Semantic.role(for: item.severity) }

    var body: some View {
        HStack(alignment: .top, spacing: DataRowMetrics.cellGap) {
            /// 严重度左侧标尺：宽度取描边强调档，高度随行内容拉伸，不再钉死 34pt。
            Capsule()
                .fill(role.graphicColor)
                .frame(width: Theme.Stroke.emphasis)
                .frame(maxHeight: Theme.Spacing.xl + Theme.Spacing.lg)
                .accessibilityLabel("严重度 \(item.severity.rawValue)")
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                    SemanticBadge(item.severity.rawValue, role: role, icon: severityIcon)
                    if let score = item.score {
                        Text(String(format: "CVSS %.1f", score))
                            .font(CodeGitType.number(Theme.Typo.microLabel))
                            .foregroundStyle(.secondary)
                    }
                    Text(item.source)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                    if !item.aliases.isEmpty {
                        Text(item.aliases.prefix(2).joined(separator: " "))
                            .font(CodeGitType.path)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Text(item.summary)
                    .monospacedDigit()
                    .lineSpacing(Theme.Typo.narrative.lineSpacing)
                    .lineLimit(2)
                Text(Self.targetsLine(item))
                    .font(CodeGitType.path)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if let advice = item.advice {
                    Text(advice)
                        .monospacedDigit()
                        .foregroundStyle(Self.adviceRole(item).textColor)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .dataTableRow()
    }

    private var severityIcon: IconName { item.severity == .none ? .clean : .vulnerable }

    /// 「建议升级至 X」是修复路径，不是"已安全"的结论，所以走 info 而不是 success。
    static func adviceRole(_ item: VulnerabilityItem) -> Theme.SemanticRole {
        item.advice == nil ? Theme.Semantic.neutral : Theme.Semantic.info
    }

    static func targetsLine(_ item: VulnerabilityItem) -> String {
        let prefix = item.range.map { "\($0) → " } ?? ""
        let list = item.targets.prefix(4).joined(separator: ", ")
        let more = item.targets.count > 4 ? " 等 \(NumberFormat.grouped(item.targets.count)) 项" : ""
        return "\(prefix)\(list)\(more)"
    }
}
