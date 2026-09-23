import SwiftUI

// OWNER: R3 依赖证据链 · 公告行（自 DependencyVerdictRows.swift 整块搬出）
//
// 逐字搬动，未改任何判据与文案：搬的是"画公告"的那三块
// （`VulnerabilityItem` / `DependencyVulnerabilityItems.merged` / `VulnerabilityRow`）。
// 留在原文件的是两个**判定**类型（`DependencyRowStatus` / `DependencySafetyVerdict`）
// 和依赖表那一行 —— 判据必须和它的用例住在一起，配图不是判据。
// 搬动理由：`SourcesSizeAuditTests` 的 400 行口径（原文件 429 行，超限名额为 0）。
// 跨文件可见的成员由 fileprivate 升为 internal（同模块内部类型）。

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
                // 存储层是**规范坐标**（与查询/回填同一把 key），这里只负责还原成
                // `lodash@4.17.15` 给人看；不在展示层再拼一次，也不在别处另存一份。
                targets: DependencyCoordinateDisplay.texts(
                    vuln.affectedDependencies.isEmpty ? [vuln.package] : vuln.affectedDependencies),
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
                targets: DependencyCoordinateDisplay.texts(advisory.affectedPackages),
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

// MARK: 公告行

struct VulnerabilityRow: View {
    let item: VulnerabilityItem

    private var role: Theme.SemanticRole { Theme.Semantic.role(for: item.severity) }

    var body: some View {
        HStack(alignment: .top, spacing: DataRowMetrics.cellGap) {
            /// 严重度左侧标尺：宽度取描边强调档，**高度跟着这一行的内容走**。
            /// 原来写死 `maxHeight: xl + lg`（44pt），而一条公告的正文最多 5 段约 90pt
            /// —— 标尺在半路就断了，行左边界看起来错位一半。`maxHeight: .infinity`
            /// 在 `HStack(alignment: .top)` 里就是"取同排最高兄弟的高度"。
            Capsule()
                .fill(role.graphicColor)
                .frame(width: Theme.Stroke.emphasis)
                .frame(maxHeight: .infinity)
                .accessibilityLabel(Text(localizedFormat("严重度：%@", localizedCopy(item.severity.rawValue))))
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
                        .foregroundStyle(.secondary)
                    if !item.aliases.isEmpty {
                        Text(item.aliases.prefix(2).joined(separator: " "))
                            .font(CodeGitType.path)
                            .foregroundStyle(.secondary)
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

    /// 「建议升级至 X」是**修复路径的说明文字**，既不是状态也不是结论 ⇒ 结构去色（批次 P5）。
    /// 原来非 nil 时涂 info 蓝：与同页"联网核对说明"的蓝竖条一起，被两批实拍点名成
    /// "四页四种颜色的提示条"。漏洞本身的严重度色已经在那儿了，不需要第二种颜色再喊一次。
    static func adviceRole(_ item: VulnerabilityItem) -> Theme.SemanticRole {
        Theme.Semantic.neutral
    }

    static func targetsLine(_ item: VulnerabilityItem) -> String {
        let prefix = item.range.map { "\($0) → " } ?? ""
        let list = item.targets.prefix(4).joined(separator: ", ")
        let more = item.targets.count > 4 ? " 等 \(NumberFormat.grouped(item.targets.count)) 项" : ""
        return "\(prefix)\(list)\(more)"
    }
}
