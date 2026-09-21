import SwiftUI

// 本文件是 `Views/Code/CodeMetricsSections.swift` 的分片：「代码规模」页里
// **只被这一页用到**的三个分组（标记事项与扫描信息 / 巨大文件 / 重复与复杂度概览）。
// 拆的理由是机械的：页面文件被本 App 自扫点名越过「巨大文件」线。
// **一个取值、一句文案都没改**，搬的只是文件位置。
//
// 为什么不并进同目录的 `CodeViewSupport.swift`：那个文件的职责写在其顶部——
// 「两页共用件」，而这三段是页面私有分组，塞进去会让那句说明变成假话。
// 页面入口、`CodeMetricsSummaryGrid`、`CodeScaleSection`（含本页唯一的主角读数）
// 与不变式行留在 `CodeMetricsView.swift`：`CodeGitBorderlessTests` 的页面归属表
// 按那个文件名找入口与 `Theme.Page.Scaffold`，`DesignAbsenceStateTests` 按它找单点引用。
// 下面自宿主文件逐字搬入，`// MARK:` 小节名与全部注释照旧。

// MARK: - 标记事项与扫描信息

struct CodeMarkersSection: View {
    let code: CodeMetrics

    var body: some View {
        GlassSection(
            "标记事项与扫描信息",
            subtitle: "源码里留下的待办标记，只代表历史备注，不代表当前缺陷",
            icon: .info
        ) {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                ReadoutStrip {
                    DataReadout(label: "TODO", value: NumberFormat.grouped(code.todoCount),
                                caption: "处")
                    DataBandSeparator()
                    DataReadout(label: "FIXME", value: NumberFormat.grouped(code.fixmeCount),
                                caption: "处",
                                role: code.fixmeCount > 0 ? Theme.Semantic.warning : nil)
                    DataBandSeparator()
                    DataReadout(label: "标记合计",
                                value: NumberFormat.grouped(code.todoCount + code.fixmeCount),
                                caption: "处")
                    DataBandSeparator()
                    DataReadout(label: "每千行标记",
                                value: String(format: "%.2f", Self.markerDensityPerKilo(code)),
                                caption: "条 / 千行有效代码")
                }

                VStack(spacing: DataRowMetrics.rowGap) {
                    DataFieldRow(label: "扫描耗时", value: CodeViewFormat.duration(code.durationMs),
                                 style: .number)
                    DataRowSeparator()
                    DataFieldRow(label: "扫描时间",
                                 value: DateFormat.full.string(from: code.scannedAt), style: .number)
                    DataRowSeparator()
                    DataFieldRow(label: "距今", value: DateFormat.sinceDescription(code.scannedAt),
                                 style: .number)
                }

                DataCaption(text: Self.markerNote(code))
            }
        }
    }

    static func markerDensityPerKilo(_ code: CodeMetrics) -> Double {
        guard code.codeLines > 0 else { return 0 }
        return Double(code.todoCount + code.fixmeCount) * 1_000 / Double(code.codeLines)
    }

    /// 零标记要写成"扫过、没找到"，而不是留一片空白让人以为没扫。
    static func markerNote(_ code: CodeMetrics) -> String {
        if code.todoCount + code.fixmeCount == 0 {
            return "已完成扫描：\(NumberFormat.grouped(code.totalFiles)) 个文件里没有 TODO / FIXME 标记。"
        }
        return "FIXME \(NumberFormat.grouped(code.fixmeCount)) 处通常表示已知缺陷，"
            + "建议优先在对应文件里核对。"
    }
}

// MARK: - 巨大文件

struct CodeHotspotSection: View {
    let code: CodeMetrics
    let root: String
    var rowLimit: Int = CodeMetricsView.hotspotRowLimit

    @State private var expanded = false

    var body: some View {
        GlassSection(
            "巨大文件（按行数降序）",
            subtitle: Self.subtitle(code),
            icon: .duplicate
        ) {
            if code.hugeFiles.isEmpty {
                EmptyStateView(
                    icon: .noRisk,
                    title: "本次扫描未发现巨大文件",
                    message: localizedFormat("已完成扫描，单文件行数峰值为 %1$@ 行，未超过阈值。这是测得的结果，不是没扫。",
                                             NumberFormat.grouped(code.largestFileLineCount))
                )
            } else {
                let rows = visibleRows
                DataTableWell {
                    DataTableHeader(columns: DataColumns.hugeFiles)
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, hotspot in
                        CodeHotspotRow(hotspot: hotspot, root: root,
                                       largestLineCount: Self.largestLineCount(code))
                        if index < rows.count - 1 {
                            DataRowSeparator()
                        }
                    }
                }
                if code.hugeFiles.count > rowLimit {
                    DataDisclosureButton(expanded: expanded,
                                        hiddenCount: code.hugeFiles.count - rowLimit,
                                        noun: "个未展示") {
                        expanded.toggle()
                    }
                }
                DataFootnote(text: Self.truncationNote(code, shown: rows.count))
            }
        }
    }

    private var visibleRows: [FileHotspot] {
        expanded ? code.hugeFiles : Array(code.hugeFiles.prefix(rowLimit))
    }

    /// 折叠状态必须自己交代，不然「8 行」会被读成「一共只有 8 个」。
    static func truncationNote(_ code: CodeMetrics, shown: Int) -> String {
        let total = code.hugeFiles.count
        guard total > shown else {
            return "共 \(NumberFormat.grouped(total)) 个，已全部展示。"
        }
        return "另有 \(NumberFormat.grouped(total - shown)) 个未展示 · 当前列出 "
            + "\(NumberFormat.grouped(shown)) / \(NumberFormat.grouped(total)) 个。"
    }

    static func largestLineCount(_ code: CodeMetrics) -> Int {
        max(code.largestFileLineCount, code.hugeFiles.map(\.lineCount).max() ?? 0)
    }

    static func subtitle(_ code: CodeMetrics) -> String {
        if code.hugeFiles.isEmpty { return "行数是单文件总行数（含空行与注释）" }
        return "共 \(NumberFormat.grouped(code.hugeFiles.count)) 个 · 最大 "
            + "\(NumberFormat.grouped(largestLineCount(code))) 行 · 点击条目在 Finder 中显示"
    }
}

// MARK: - 重复与复杂度概览（明细在「复杂度风险」页）

/// 概览段。**这一页已有 56pt 主角，所以重复率从 34pt 降到 22pt 读数带**
/// ——「两个 28pt 以上数字争位」就是旧页「没有主次」的定量形态。
struct CodeDuplicationSummarySection: View {
    let code: CodeMetrics

    var body: some View {
        GlassSection(
            "重复与复杂度概览",
            subtitle: "仅概览数字，明细见「复杂度风险」页",
            icon: .complexity,
            trailing: AnyView(RiskBadge(risk: code.overallRisk))
        ) {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                ReadoutStrip {
                    DataReadout(label: "重复代码率",
                                value: NumberFormat.percent(code.duplicationRatio, precision: 1),
                                caption: "的代码行落在重复块内",
                                role: Theme.Semantic.role(for: code.overallRisk))
                    DataBandSeparator()
                    DataReadout(label: "重复块", value: NumberFormat.grouped(code.duplicatedBlocks.count),
                                unit: "个")
                    DataBandSeparator()
                    DataReadout(label: "超长函数", value: NumberFormat.grouped(code.longFunctions),
                                unit: "个")
                    DataBandSeparator()
                    DataReadout(label: "平均函数长度", value: NumberFormat.grouped(code.averageFunctionLength),
                                caption: "仅统计 ≥2 行的函数",
                                unit: "行")
                }

                MiniBarGauge(fraction: code.duplicationRatio,
                             tint: Theme.Semantic.role(for: code.overallRisk).graphicColor,
                             height: DataGaugeHeight.metric)
                DataFootnote(text: "重复块 \(NumberFormat.grouped(code.duplicatedBlocks.count)) 个 · "
                             + "复杂度上榜 \(NumberFormat.grouped(code.topComplexFunctions.count)) 个函数")
            }
        }
    }
}
