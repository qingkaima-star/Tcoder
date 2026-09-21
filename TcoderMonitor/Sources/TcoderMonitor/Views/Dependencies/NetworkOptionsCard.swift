import SwiftUI

// 本文件是 `Views/Dependencies/DependenciesView.swift` 的分片（WS-X8 实现文件规模闸门）。
// 搬的理由是机械的：宿主文件被本 App 自扫点名越过「巨大文件」线
// （`FileSystemCodeAnalyzer.mediumFileLines` = 400 行，此刻是 401），而这条口径由
// `SourcesSizeAuditTests` 机器把守。**一个取值、一处画法都没改**，搬的只是文件位置。
// `NetworkOptionsCard` 只被同目录的 `DependenciesView` 使用，落点因此仍在本页目录里。

// MARK: - 联网开关（控件层）

struct NetworkOptionsCard: View {
    @Binding var allowNetwork: Bool
    var canRescan: Bool
    var rescan: () -> Void

    var body: some View {
        // ⓘ 收纳轮（盘点表 H 组「联网开关卡」）：卡头副标题**留短藏长**。
        // 屏上只留"要不要联网"这一层决策（变慢），完整的口径句（含"离线时仍会用内置快照"）
        // 进副标题旁边那枚 ⓘ。`GlassSection` 的 `subtitle:` 槽不转发 `help:`，
        // 所以走全站约定形状：同容器（卡头 trailing 位）紧跟一枚 `CopyHelpBadge(原句)`，
        // 画法仍是 `Design/CopyHelp.swift` 那一处，页面没有再画一遍问号。
        //
        // **为什么这句可以藏**：盘点表 Z 节点名的是 `statusCaption`（"结论来自内置快照"），
        // 它整句留在下方那行常驻；本句只是它的预告，藏掉不减少一屏里的诚实性信息。
        GlassSection("分析选项", subtitle: "联网核对会显著变慢", icon: .network,
                     trailing: AnyView(CopyHelpBadge("联网核对会显著变慢，离线时仍会用内置快照"))) {
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
