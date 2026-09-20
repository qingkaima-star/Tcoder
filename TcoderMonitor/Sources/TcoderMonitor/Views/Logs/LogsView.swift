import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// OWNER: WS-M / 错误日志页。
///
/// 数据全部来自 `report?.logs`；三态口径见《40 WS-H》§7.3：
/// **没分析 / 没有可读文件 = `--`**，**分析了但没命中 = 真 0 + 「未发现」**。
/// 交互（重新分析 / 附加日志文件 / 时间窗口）一律走 `AppState` 已提供的 API。
struct LogsView: View {
    var report: ProjectReport?

    @Environment(AppState.self) private var state

    /// 改窗口 / 清空附加文件后，若当前无法自动重算，用它提示用户手动重算。
    @State private var pendingRescanNote: String?

    private static let windowChoices: [Int] = [1, 3, 7, 14, 30]
    private static let logFileExtensions = ["log", "out", "txt", "ips", "crash", "text", "json", "diag"]

    var body: some View {
        @Bindable var state = state

        Theme.Page.Scaffold(maxWidth: Theme.Layout.maxWidthReading) {
                header(window: $state.logWindowDays)
                banners
                LogsMetricGrid(logs: report?.logs, code: report?.code)
                LogsTrendCard(logs: report?.logs)
                LogsErrorClustersCard(logs: report?.logs)
                LogsAffectedFilesCard(logs: report?.logs)
                LogsScannedFilesCard(logs: report?.logs)
        }
        .onChange(of: state.logWindowDays) { _, _ in rescanForNewWindow() }
    }

    // MARK: - 页内小标题与工具条（页头归 WS-O；控件层是本页唯一一处真玻璃落点）

    private func header(window: Binding<Int>) -> some View {
        // 原来整块 header 挂着 `.padding(md)` + `.surface(layer: .content)` ——
        // 内容层现在什么都不画，那是一次空操作，而它为已经不存在的盒子留了 16pt 内边距，
        // 把标题与正文之间的组间距吃掉了一截。一并去掉。
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Theme.Page.Header(title: "错误日志分析",
                              icon: .logs,
                              subtitle: subtitle,
                              isDemo: report?.project.isDemo == true,
                              actions: { actions(window: window) })
            if let note = pendingRescanNote {
                NoteLine(note, role: Theme.Semantic.warning, icon: .riskWarning)
            }
            if !attachedItems.isEmpty { attachedFilesLine }
        }
    }

    /// 时间窗口与三个动作都属**控件**，走 `.chrome` 层（`GlassToolbar` 自己就是控件层）。
    /// 扫描进度是状态，不是控件，所以它在工具条旁边而不里面。
    private func actions(window: Binding<Int>) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            if state.isScanning {
                HStack(spacing: Theme.Spacing.xxs) {
                    ProgressView().controlSize(.small)
                    Text(state.phase.label)
                        .font(Theme.Typo.label.font)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Text("时间窗口")
                .typed(Theme.Typo.label)
                .foregroundStyle(.secondary)
            // 一排纯文字选档，替掉 `.pickerStyle(.segmented)`：后者给选中项画一枚
            // **灰底胶囊**，那是白底改造之后全站仅剩的一处"灰底选中"，与侧栏的
            // 实心绿选中态、与参考图的 `Week / Month / Quarter / Year` 都对不齐；
            // 而且 `.fixedSize()` 明确拒绝压缩，窄窗口下这一行会横向溢出页边距（清单 2.12）。
            TextSegmentedPicker(options: Self.windowChoices,
                                label: { "最近 \($0) 天" },
                                selection: window.wrappedValue,
                                onSelect: { window.wrappedValue = $0 })
                .accessibilityLabel("时间窗口")
                .help("切换后自动重新分析（示例项目与扫描进行中除外）")
            controls
        }
    }

    private var controls: some View {
        GlassToolbar {
            GlassButton("重新分析", icon: .reanalyze, isEnabled: canRescan) {
                pendingRescanNote = nil
                state.scanSelected()
            }
            GlassButton("附加日志", icon: .attach, isEnabled: state.selectedProject != nil) {
                chooseLogFiles()
            }
            GlassButton("清空附加", icon: .remove, isEnabled: !attachedItems.isEmpty) {
                clearAttachedFiles()
            }
        }
    }

    private var canRescan: Bool { !state.isScanning && state.selectedProject != nil }

    private var subtitle: String {
        guard let logs = report?.logs else {
            return "时间窗口 \(state.logWindowDays) 天 · 当前项目尚未分析"
        }
        return "分析于 \(DateFormat.sinceDescription(logs.analyzedAt)) · 时间窗口 \(state.logWindowDays) 天"
            + " · 扫描 \(NumberFormat.grouped(logs.totalLinesScanned)) 行"
    }

    @ViewBuilder
    private var banners: some View {
        if report?.logs == nil {
            BannerRow(text: "该项目还没有日志分析结果。选择项目目录后点「重新分析」，或手动附加本地日志文件。",
                      style: .info)
        } else if report?.logs?.hasData == false {
            BannerRow(text: "项目目录与 ~/Library/Logs 里都没有找到可解析的日志文件。用「附加日志」手动选择 error.log、crash.log 后重新分析。",
                      style: .warning)
        }
        if let error = state.lastError {
            BannerRow(text: error, style: .error)
        }
    }

    // MARK: - 附加文件

    /// 已附加的日志文件。
    ///
    /// 原来每条是一个 `.contentInset` 胶囊，横向排在一根滚动条里 —— 井只许给
    /// 表格 / 日志列表 / 代码块（风格契约 3），一枚展示用的文件名不是井，
    /// 而这排灰盒正是「界面发脏」的一分子。改成「计数小标题 + 逐行文件名（带体积）」，
    /// `.help` 里的完整路径与体积一个字都没少；文件名抬到 11pt 等宽，
    /// 因为它现在是这一行唯一的主角，不再靠灰底把自己从地面上拎出来。
    private var attachedFilesLine: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text("已附加 \(NumberFormat.grouped(attachedItems.count)) 个文件")
                .typed(Theme.Typo.groupLabel)
                .foregroundStyle(.secondary)
            ForEach(attachedItems) { item in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                    Text(item.url.lastPathComponent)
                        .font(Theme.Typo.monoLabel.font)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(item.sizeBytes.map { Live.bytes($0) } ?? Live.missing)
                        .typed(Theme.Typo.microLabel)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .help(item.url.path)
            }
        }
    }

    /// 换窗口后尽量立刻重算；做不到（正在扫描 / 示例项目）时才提示手动重算。
    private func rescanForNewWindow() {
        guard let project = state.selectedProject else { return }
        if project.isDemo {
            pendingRescanNote = "示例项目使用内置固定数据，时间窗口不影响结果。"
        } else if state.isScanning {
            pendingRescanNote = "改窗口后需重新分析。"
        } else {
            pendingRescanNote = nil
            state.scan(project: project)
        }
    }

    private func chooseLogFiles() {
        guard let project = state.selectedProject else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "选择要一并分析的日志文件，例如 error.log、crash.log、app.log"
        panel.prompt = "附加"
        panel.allowedContentTypes = Self.logFileExtensions.compactMap { UTType(filenameExtension: $0) }
        if FileManager.default.fileExists(atPath: project.path) {
            panel.directoryURL = project.url
        }
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        let existing = Set((state.extraLogURLs[project.id] ?? []).map(\.path))
        let fresh = panel.urls.filter { !existing.contains($0.path) }
        guard !fresh.isEmpty else { return }
        state.attachLogFiles(to: project.id, urls: fresh)
        pendingRescanNote = nil
        state.scan(project: project)
    }

    private func clearAttachedFiles() {
        guard let project = state.selectedProject else { return }
        guard !attachedItems.isEmpty else { return }
        state.clearAttachedLogs(for: project.id)
        pendingRescanNote = "清空附加文件后需重新分析。"
    }

    private var attachedItems: [AttachedLogItem] {
        guard let project = state.selectedProject else { return [] }
        var seen = Set<String>()
        var items: [AttachedLogItem] = []
        for url in state.extraLogURLs[project.id] ?? [] {
            guard !seen.contains(url.path) else { continue }
            seen.insert(url.path)
            items.append(AttachedLogItem(url: url, sizeBytes: Self.fileSize(of: url)))
        }
        return items
    }

    private static func fileSize(of url: URL) -> UInt64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attrs[.size] as? NSNumber else { return nil }
        return number.uint64Value
    }
}

/// 附加文件条目：列表在附加时已按路径去重，所以用路径当稳定 id。
///
/// 它原来还配一个 `.contentInset` 胶囊视图 `AttachedLogFileChip`，本轮随井一起退场
/// （见 `attachedFilesLine` 的说明）；这层数据本身仍在用，不能删。
struct AttachedLogItem: Identifiable {
    let url: URL
    let sizeBytes: UInt64?

    var id: String { url.path }
}
