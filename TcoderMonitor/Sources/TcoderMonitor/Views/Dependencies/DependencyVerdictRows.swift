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
    /// **两个维度都核对过**且无公告：这才是"真核对过的干净"。
    case verifiedSafe
    /// 版本这一路有结果、漏洞这一路没核对成（默认离线态就是它）。
    case versionOnly
    /// 连版本都没有可比对。
    case unchecked
    /// 发起了但失败 / 超时 / 解不出来。
    case checkFailed
    /// 声明的是范围且没有锁文件把它解析成确切版本 ⇒ 安装版本没量到。
    case versionUnresolved
    /// 该生态不在数据源覆盖范围内（OSV 不收 SwiftPM / CocoaPods）。
    case unsupported
    /// 生态支持、版本也可查，但被单次上限 / 时间预算挡在门外。
    case budgetExcluded

    /// 一条依赖的状态 = **两个核对维度的结构化结局**，不再由"数据来源种类"推出。
    ///
    /// 旧实现在这里是 `switch record.versionCheckSource { case .onlineRegistry: return .verifiedSafe }`
    /// —— 单条依赖"安全"的结论是由"版本数据从哪来"推的，npm 版本查成功就发绿，
    /// 而从没问过"这条的漏洞核对到底成功了没有"（RD-11 点名的正是这一步）。
    /// 现在两个维度各读各的账，只有 `(版本=已核对, 漏洞=已核对)` 才允许 `.verifiedSafe`。
    static func of(_ record: DependencyRecord) -> DependencyRowStatus {
        if !record.knownVulnerabilities.isEmpty { return .vulnerable(count: record.knownVulnerabilities.count) }
        let version = DependencyEvidence.versionState(of: record)
        let vulnerability = DependencyEvidence.vulnerabilityState(of: record)
        if version.isCovered, DependencyVersionIdentity.of(record).outdatedness == .older { return .outdated }
        switch (version, vulnerability) {
        case (.checked, .checked): return .verifiedSafe
        case (.checked, _): return .versionOnly
        case (.failed, _), (_, .failed): return .checkFailed
        case (.budgetExcluded, _), (_, .budgetExcluded): return .budgetExcluded
        case (.versionUnresolved, _), (_, .versionUnresolved): return .versionUnresolved
        case (.ecosystemUnsupported, _), (_, .ecosystemUnsupported): return .unsupported
        // 其余组合（含"版本没发起、漏洞却查出了东西"这类账本不自洽）一律按未核对呈现：
        // 拿不准的时候**往保守那侧靠**，绝不因为分支没写完就发绿。
        case (.notAttempted, _), (_, .notAttempted): return .unchecked
        }
    }

    var text: String {
        switch self {
        case .vulnerable: return "有漏洞"
        case .outdated: return "过旧"
        case .verifiedSafe: return "正常"
        case .versionOnly: return "仅版本比对"
        case .unchecked: return "未核对"
        case .checkFailed: return "核对失败"
        case .versionUnresolved: return "版本未解析"
        case .unsupported: return "生态不支持"
        case .budgetExcluded: return "未进批次"
        }
    }

    var role: Theme.SemanticRole {
        switch self {
        case .vulnerable: return Theme.Semantic.danger
        case .outdated: return Theme.Semantic.warning
        case .verifiedSafe: return Theme.Semantic.success
        case .checkFailed: return Theme.Semantic.warning
        case .versionOnly, .unchecked, .versionUnresolved, .unsupported, .budgetExcluded:
            return Theme.Semantic.neutral
        }
    }

    /// 色 + 文字 + 图标三通道：色觉障碍与灰度打印下结论仍然可读（WS-H §10）。
    var badgeIcon: IconName {
        switch self {
        case .vulnerable: return .vulnerable
        case .outdated: return .riskWarning
        case .verifiedSafe: return .noRisk
        case .checkFailed: return .riskWarning
        case .versionUnresolved, .unsupported, .budgetExcluded, .unchecked: return .unverified
        case .versionOnly: return .info
        }
    }

    /// 每一格都要能回答"为什么是这个结论、依据是什么、还缺什么"。
    /// 语义一律读结构化状态，不读中文说明（RD-13）。
    func tooltip(record: DependencyRecord) -> String {
        let identity = DependencyVersionIdentity.of(record)
        let version = DependencyEvidence.versionState(of: record)
        let vulnerability = DependencyEvidence.vulnerabilityState(of: record)
        var base = "版本数据来源：\(record.versionCheckSource.rawValue)；声明版本 \(record.version)"
        if let resolved = record.resolvedVersion {
            base += "；实际解析 \(resolved)（来自 \(record.resolvedVersionSource ?? "已解析产物")）"
        }
        if let latest = identity.latestKnownVersion { base += "；最新已知 \(latest)" }
        switch self {
        case .vulnerable(let count):
            return "\(base)；\(count) 条已知漏洞：\(record.knownVulnerabilities.joined(separator: "、"))"
        case .outdated:
            return "\(base)；按已解析/声明的确切版本比较为落后；漏洞核对状态：\(vulnerability.rawValue)"
        case .verifiedSafe:
            return "\(base)；版本与漏洞两路均已核对，无已知公告"
        case .versionOnly:
            return "\(base)；只比对了版本新旧，漏洞这一路的状态是「\(vulnerability.rawValue)」"
        case .unchecked:
            return "\(base)；两路都未发起核对（默认不联网），无可比对结论"
        case .checkFailed:
            return "\(base)；核对请求发出后失败或超时（版本路：\(version.rawValue)／漏洞路：\(vulnerability.rawValue)）"
        case .versionUnresolved:
            return "\(base)；声明的是范围且无锁文件解析值 ⇒ 安装版本没量到，不比对也不查询"
        case .unsupported:
            return "\(base)；该生态不在数据源覆盖范围内（\((record.ecosystem.displayName))）"
        case .budgetExcluded:
            return "\(base)；版本可查但被单次上限/时间预算挡在批次之外，未发起核对"
        }
    }
}

// MARK: 安全结论

/// 「零漏洞」有几层完全不同的含义，必须分开给结论，而且**结论与逐条依赖读同一份账**。
///
/// 默认 `allowNetworkLookups = false`，此时 `vulnerableCount` 恒为 0：如果就据此画绿，
/// 等于把「根本没查」说成「查了且没病」。
///
/// RD-11 的根因修正：旧实现的闸门是 `DependencyReport.hasVulnerabilityCoverage`，
/// 而它写的是 `networkLookupPerformed || !advisories.isEmpty` —— 那个字段的原话就是
/// "**尝试过**"（`attempted > 0`），于是"发过请求"被当成"核对过"。
/// 现在闸门读逐条落账后的**漏洞核对成功条数**：一条都没核对成，就不许出现 `.clean`。
enum DependencySafetyVerdict: Equatable {
    /// 真的有命中。
    case findings(count: Int, risk: RiskLevel)
    /// 没联网、也没拿到任何在线公告 —— 零命中只是"未判定"。
    case unchecked(coveredCount: Int, total: Int, uncoveredEcosystems: [String])
    /// 逐条漏洞核对确实成功过（全部覆盖时才是完整的"干净"结论）。
    case clean(coveredCount: Int, total: Int)

    init(_ report: DependencyReport) {
        self.init(report, ledger: DependencyEvidence.ledger(for: report))
    }

    /// 账本由调用方传入：评分侧、CLI 侧都用同一个 `DependencyEvidence.ledger(for:)`，
    /// 不再各自读一遍字段（那会长出第二把尺子）。
    init(_ report: DependencyReport, ledger: DependencyEvidenceLedger) {
        let total = ledger.totalCount
        if report.vulnerableCount > 0 {
            self = .findings(count: report.vulnerableCount, risk: report.riskLevel)
        } else if ledger.vulnerabilityCheckedCount > 0 {
            self = .clean(coveredCount: ledger.vulnerabilityCheckedCount, total: total)
        } else {
            self = .unchecked(coveredCount: ledger.versionCheckedCount, total: total,
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
        case .findings(_, let risk): return "风险：\(risk.rawValue)"
        case .unchecked: return "未核对"
        case .clean: return "已核对"
        }
    }

    /// 读数带格子里的脚注：**只报核对状态 + 全口径在哪儿**。
    ///
    /// `summaryCaption` 那份全文在上方「风险总览」的口径条里已经逐字说过一遍，
    /// 同一屏再贴一遍就是清单 3.16 的"一屏说四遍"（实拍那条脚注占了 4 行，
    /// 把四格读数带撑成高低不齐）。**压缩重复 ≠ 删诚实性信息**：状态词一个不删，
    /// 覆盖范围、快照日期、未覆盖生态全部留在权威落点那一处。
    var tileCaption: String {
        switch self {
        case .findings: return "命中详情见下方「安全公告」"
        case .unchecked: return "未联网核对，全口径见上方「风险总览」"
        case .clean: return "已联网核对，覆盖范围见上方「风险总览」"
        }
    }

    /// 「漏洞数」磁贴的副标题：绿色 all-clear 只在真的核对过时才允许出现。
    var summaryCaption: String {
        switch self {
        case .findings(let count, _):
            return "命中 \(NumberFormat.grouped(count)) 条内置快照与安全公告"
        case .unchecked(let covered, let total, let uncovered):
            var text = localizedFormat("未联网核对，仅内置快照（覆盖 npm / Maven / Python），%@",
                                         DependencySnapshot.asOfText)
            text += total == 0
                ? localizedCopy("· 无依赖可核对")
                : localizedFormat("· %1$@ / %2$@ 项有版本数据",
                                  NumberFormat.grouped(covered), NumberFormat.grouped(total))
            if !uncovered.isEmpty {
                text += localizedFormat("· 未覆盖生态：%@", uncovered.joined(separator: localizedCopy("、")))
            }
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
                .help(localizedCopy("默认不联网时漏洞判定恒为 0 条，这是「没有查」，不是「没有病」"))
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
            /// 严重度左侧标尺：宽度取描边强调档，**高度跟着这一行的内容走**。
            /// 原来写死 `maxHeight: xl + lg`（44pt），而一条公告的正文最多 5 段约 90pt
            /// —— 标尺在半路就断了，行左边界看起来错位一半。`maxHeight: .infinity`
            /// 在 `HStack(alignment: .top)` 里就是"取同排最高兄弟的高度"。
            Capsule()
                .fill(role.graphicColor)
                .frame(width: Theme.Stroke.emphasis)
                .frame(maxHeight: .infinity)
                .accessibilityLabel(Text(localizedFormat("严重度：%@", item.severity.rawValue)))
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
