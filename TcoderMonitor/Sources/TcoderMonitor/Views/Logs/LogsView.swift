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

    // MARK: - 页头与工具条（控件层：本页唯一一处真玻璃落点）

    private func header(window: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                ThemedIcon(.logs, role: .navigation)
                    .foregroundStyle(Theme.Semantic.accent.textColor)
                Text("错误日志分析").font(Theme.Typo.pageTitle.font)
                if report?.project.isDemo == true {
                    SemanticBadge("示例", role: Theme.Semantic.info)
                }
                Spacer(minLength: Theme.Spacing.sm)
                if state.isScanning {
                    HStack(spacing: Theme.Spacing.xxs) {
                        ProgressView().controlSize(.small)
                        Text(state.phase.label)
                            .font(Theme.Typo.label.font)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                controls
            }

            Text(subtitle).font(Theme.Typo.label.font).foregroundStyle(.secondary)

            HStack(spacing: Theme.Spacing.sm) {
                Text("时间窗口").font(Theme.Typo.label.font).foregroundStyle(.secondary)
                Picker("时间窗口", selection: window) {
                    ForEach(Self.windowChoices, id: \.self) { day in
                        Text("最近 \(day) 天").tag(day)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("切换后自动重新分析（示例项目与扫描进行中除外）")
                if let note = pendingRescanNote {
                    NoteLine(note, role: Theme.Semantic.warning, icon: .riskWarning)
                }
                Spacer(minLength: 0)
            }

            if !attachedItems.isEmpty { attachedFilesRow }
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(layer: .content, shape: .rounded(Theme.Radius.card))
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

    private var attachedFilesRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.xs) {
                Text("已附加 \(NumberFormat.grouped(attachedItems.count)) 个文件")
                    .font(Theme.Typo.microLabel.font)
                    .foregroundStyle(.tertiary)
                ForEach(attachedItems) { item in
                    AttachedLogFileChip(item: item)
                }
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
struct AttachedLogItem: Identifiable {
    let url: URL
    let sizeBytes: UInt64?

    var id: String { url.path }
}

/// 附加文件胶囊。尺寸与材质走内容层，不再生造 `background + strokeBorder`。
struct AttachedLogFileChip: View {
    let item: AttachedLogItem

    var body: some View {
        HStack(spacing: Theme.Spacing.xxs) {
            ThemedIcon(.attach, role: .badge).foregroundStyle(Theme.Semantic.accent.textColor)
            Text(item.url.lastPathComponent)
                .font(Theme.Typo.monoSmall.font)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(item.sizeBytes.map { Live.bytes($0) } ?? Live.missing)
                .font(Theme.Typo.microLabel.font)
                .foregroundStyle(.tertiary)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, Theme.Spacing.chip)
        .padding(.vertical, Theme.Spacing.xxs)
        .surface(layer: .contentInset, shape: .capsule)
        .help(item.url.path)
    }
}
