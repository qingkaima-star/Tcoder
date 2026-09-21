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
