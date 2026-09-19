import AppKit
import SwiftUI

// MARK: - 代码类两页共用件（WS-L）
//
// 从 `CodeMetricsView.swift` 拆出：路径格式化、数据闸门、空态与巨大文件行都被
// 「代码规模」与「复杂度风险」两页共用，留在任何一个页面文件里都会让对方依赖自己的布局。

// MARK: 数据闸门

/// 把「没扫过」「扫过了但确实是空的」「有数据」三态收在一个判定里。
///
/// 两页以前各写一遍 `guard totalFiles > 0 || totalLines > 0`，写歪一次就会把
/// 「没有源码文件」渲染成指标全 0，读起来像"这个项目零风险"。
enum CodeDataGate {
    enum State: Equatable {
        case notAnalysed
        case measuredEmpty
        case analysed
    }

    static func state(of code: CodeMetrics?) -> State {
        guard let code else { return .notAnalysed }
        return code.totalFiles > 0 || code.totalLines > 0 ? .analysed : .measuredEmpty
    }

    /// 有数据时才返回指标，其余两态交给 `emptyCopy`。
    static func metrics(of code: CodeMetrics?) -> CodeMetrics? {
        state(of: code) == .analysed ? code : nil
    }

    struct EmptyCopy {
        let icon: IconName
        let title: String
        let message: String
    }

    /// 两种"没有数字可看"的说法必须不同：一个是**还没测**，一个是**测了、真的是空的**。
    static func emptyCopy(for code: CodeMetrics?, page: String) -> EmptyCopy? {
        switch state(of: code) {
        case .analysed:
            return nil
        case .notAnalysed:
            return EmptyCopy(
                icon: .code,
                title: "尚无代码扫描结果",
                message: "点击「重新分析」开始扫描该目录。\n完成后这里会显示真实的文件数、行数与\(page)。"
            )
        case .measuredEmpty:
            return EmptyCopy(
                icon: .emptyTray,
                title: "扫描结果为空",
                message: "扫描已完成，但没有识别到任何源码文件（构建产物、依赖目录与不受支持的后缀会被跳过）。\n"
                    + "这是测得的结果，不是没有扫描，因此不给任何风险结论。"
            )
        }
    }
}

// MARK: 路径与数字格式化

enum CodeViewFormat {
    static func fileName(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    /// 相对项目根目录的路径；未命中根目录时退回原始路径。
    static func relativePath(_ path: String, root: String) -> String {
        if !root.isEmpty, path.hasPrefix(root) {
            var rest = String(path.dropFirst(root.count))
            if rest.hasPrefix("/") { rest.removeFirst() }
            if !rest.isEmpty { return rest }
        }
        return path
    }

    /// 展示用路径尾部：目录过多时省略中间段，只保留末尾 `keep` 段（含文件名）。
    static func pathTail(_ path: String, root: String, keep: Int = 3) -> String {
        let parts = relativePath(path, root: root).split(separator: "/").map(String.init)
        guard parts.count > keep + 1 else { return relativePath(path, root: root) }
        return "…/" + parts.suffix(keep).joined(separator: "/")
    }

    /// 只取目录部分，同样省略中间段。
    static func directoryTail(_ path: String, root: String, keep: Int = 3) -> String {
        let parts = relativePath(path, root: root).split(separator: "/").map(String.init)
        guard parts.count > 1 else { return "项目根目录" }
        let directories = parts.dropLast()
        if directories.count > keep + 1 {
            return "…/" + directories.suffix(keep).joined(separator: "/")
        }
        return directories.joined(separator: "/")
    }

    /// 扫描器给的是绝对路径；万一是相对路径就按项目根补齐，保证 Finder 动作可用。
    static func resolvedURL(_ path: String, root: String) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        if !root.isEmpty { return URL(fileURLWithPath: root).appendingPathComponent(path) }
        return URL(fileURLWithPath: path)
    }

    static func duration(_ durationMs: Int) -> String {
        guard durationMs >= 1_000 else { return "\(NumberFormat.grouped(durationMs)) 毫秒" }
        return String(format: "%.2f 秒", Double(durationMs) / 1_000)
    }
}

// MARK: 语言占比行

/// 一行语言占比。取代冻结在 `DashboardView` 里的 `LanguageBar`——那个组件用 6 个裸
/// `Color(red:green:blue:)` 且以 `hashValue % palette.count` 取色，`hashValue` 每进程随机化，
/// 于是**同一门语言每次启动换一种颜色**（WS-I §2.1①）。这里改走单一 `Theme.Chart` + FNV-1a。
struct CodeLanguageShareRow: View {
    let share: LanguageShare
    let onOpenHint: String

    var body: some View {
        DataShareBarRow(
            label: share.language,
            detail: "\(NumberFormat.grouped(share.lineCount)) 行",
            fraction: share.share,
            tint: CodeGitCategoryColor.color(for: share.language),
            percentPrecision: 1
        )
        .help(onOpenHint)
    }

    static func hint(_ share: LanguageShare) -> String {
        "\(share.language)：\(NumberFormat.grouped(share.fileCount)) 个文件 · "
            + "\(NumberFormat.grouped(share.lineCount)) 有效代码行 · "
            + "占比 \(NumberFormat.percent(share.share, precision: 1))"
    }
}

// MARK: 巨大文件行

/// 一行巨大文件。整行可点在 Finder 中定位，行尾图标是次要动作（默认应用打开）；
/// 两个动作各自带无障碍标签，不靠颜色表意。
struct CodeHotspotRow: View {
    let hotspot: FileHotspot
    let root: String
    let largestLineCount: Int

    private var columns: [DataGridColumn] { DataColumns.hugeFiles }

    var body: some View {
        let url = CodeViewFormat.resolvedURL(hotspot.path, root: root)
        HStack(alignment: .center, spacing: Theme.Spacing.sm) {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                HStack(alignment: .center, spacing: Theme.Spacing.sm) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text(CodeViewFormat.fileName(hotspot.path))
                            .font(CodeGitType.tableIdentifier)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(CodeViewFormat.directoryTail(hotspot.path, root: root))
                            .font(CodeGitType.path)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tableCell(DataColumns.column(columns, 0))

                    MiniBarGauge(fraction: fraction,
                                 tint: Theme.Semantic.role(for: hotspot.risk).graphicColor,
                                 height: DataGaugeHeight.inline)
                        .frame(maxWidth: .infinity)
                        .tableCell(DataColumns.column(columns, 1))

                    Text("\(NumberFormat.grouped(hotspot.lineCount)) 行")
                        .font(CodeGitType.number(Theme.Typo.monoSmall))
                        .foregroundStyle(.secondary)
                        .tableCell(DataColumns.column(columns, 2))

                    RiskBadge(risk: hotspot.risk, showIcon: false)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .tableCell(DataColumns.column(columns, 3))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(url.path)\n\(hotspot.suggestion)")

            CodeOpenFileButton(path: hotspot.path, root: root)
                .tableCell(DataColumns.column(columns, 4))
        }
        .padding(.vertical, Theme.Spacing.xxs)
    }

    private var fraction: Double {
        guard largestLineCount > 0 else { return 0 }
        return min(1, max(0, Double(hotspot.lineCount) / Double(largestLineCount)))
    }
}

/// 行尾「用默认应用打开」。图标是纯动作，所以必须带无障碍标签与 help（[LG] / WS-H §6.1）。
struct CodeOpenFileButton: View {
    let path: String
    let root: String

    var body: some View {
        Button {
            NSWorkspace.shared.open(CodeViewFormat.resolvedURL(path, root: root))
        } label: {
            CodeGitSymbol.decorated(CodeGitSymbol.openExternal, role: .badge)
                .foregroundStyle(Theme.Semantic.accent.textColor)
                .accessibilityLabel("用默认应用打开 \(CodeViewFormat.fileName(path))")
        }
        .buttonStyle(.plain)
        .frame(minWidth: Theme.Layout.minHitTarget, minHeight: Theme.Layout.minHitTarget)
        .help("用默认应用打开 \(CodeViewFormat.fileName(path))")
    }
}
