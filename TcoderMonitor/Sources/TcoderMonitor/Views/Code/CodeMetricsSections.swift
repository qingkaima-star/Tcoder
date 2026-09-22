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

    // 盘点表 B8（留短藏长 ●）：卡名那句完整读法（「只代表历史备注，不代表当前缺陷」）
    // 改变的是"这堆标记该怎么读"，正是该进 ⓘ 的那半句；屏上留原句的头「源码里留下的待办标记」。
    var body: some View {
        GlassSection(
            "标记事项与扫描信息",
            subtitle: "源码里留下的待办标记",
            icon: .info,
            trailing: AnyView(CopyHelpBadge("源码里留下的待办标记，只代表历史备注，不代表当前缺陷"))
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

                // 盘点表 B9 / B10 对同一个槽位判了两支：
                // 零标记那支整句就是「扫过了、没找到」的诚实凭据（≤22 字，无可再藏），**保持常驻**；
                // FIXME 那支判的是「藏」——「通常表示已知缺陷 + 建议核对」是对读数的解读，
                // 屏上只留一枚问号，FIXME 的条数本来就在上面那条读数带里各占一格。
                if code.fixmeCount > 0 {
                    CopyHelpBadge(Self.markerNote(code))
                } else {
                    DataCaption(text: Self.markerNote(code))
                }
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
        // 盘点表 B12（巨大文件榜的非空支，判「删」：后半「点击条目在 Finder 中显示」是操作提示，
        // 行尾那枚图标自己就带 help）→ 整条进 ⓘ，挂在卡名右侧那一行。
        // B11（空支，● 留短藏长）这次**不动**：那支屏上只剩卡名 + 一句空态，
        // 再拆出「行数是单文件总行数」只是把同一句话念两遍，完整读法仍是常驻更稳。
        GlassSection(
            "巨大文件（按行数降序）",
            subtitle: code.hugeFiles.isEmpty ? Self.subtitle(code) : nil,
            icon: .duplicate,
            trailing: code.hugeFiles.isEmpty ? nil
                : AnyView(CopyHelpBadge(Self.subtitle(code)))
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
    /// **但只交代一次**：同卡上方那枚 `DataDisclosureButton` 已经写着「展开其余 N 个未展示」，
    /// 这里再念一遍"另有 N 个未展示"就是用户点名的"同一句念两遍"（页尾实拍
    /// `.scratch/evidence-8de2d17/light-tail/代码规模.png`：两行相隔 40pt 逐字重复）。
    /// 本行只留按钮**没有**的那一半 —— 列出多少 / 一共多少。
    static func truncationNote(_ code: CodeMetrics, shown: Int) -> String {
        let total = code.hugeFiles.count
        guard total > shown else {
            return "共 \(NumberFormat.grouped(total)) 个，已全部展示。"
        }
        return "当前列出 \(NumberFormat.grouped(shown)) / \(NumberFormat.grouped(total)) 个。"
    }

    static func largestLineCount(_ code: CodeMetrics) -> Int {
        max(code.largestFileLineCount, code.hugeFiles.map(\.lineCount).max() ?? 0)
    }

    static func subtitle(_ code: CodeMetrics) -> String {
        if code.hugeFiles.isEmpty { return "行数是单文件总行数（含空行与注释）" }
        return localizedFormat("共 %1$@ 个 · 最大 %2$@ 行 · 点击条目在 Finder 中显示",
                                NumberFormat.grouped(code.hugeFiles.count),
                                NumberFormat.grouped(largestLineCount(code)))
    }
}

// MARK: - 重复与复杂度概览（明细在「复杂度风险」页）

/// 概览段。**这一页已有 56pt 主角，所以重复率从 34pt 降到 22pt 读数带**
/// ——「两个 28pt 以上数字争位」就是旧页「没有主次」的定量形态。
struct CodeDuplicationSummarySection: View {
    let code: CodeMetrics

    // 盘点表 B14（判「藏」的导流句）：这句只说"这里只有概览、明细在别页"，
    // 卡名「重复与复杂度概览」已经把这件事讲完了一半，所以整句进 ⓘ，
    // 与风险徽标同排挂在卡名右侧（那一行就是它原来的位置）。
    var body: some View {
        GlassSection(
            "重复与复杂度概览",
            icon: .complexity,
            trailing: AnyView(HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xxs) {
                CopyHelpBadge("仅概览数字，明细见「复杂度风险」页")
                RiskBadge(risk: code.overallRisk)
            })
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

                // 条 + 它自己的口径说明走同一行：独立成行的 ⓘ 会在卡片左下角
                // 长出一枚没有邻居的灰点（页尾实拍 `.scratch/evidence-8de2d17/light-tail/代码规模.png`）。
                HStack(alignment: .center, spacing: Theme.Spacing.xxs) {
                    MiniBarGauge(fraction: code.duplicationRatio,
                                 // 这根条的**长度**是重复率，而卡上那三个彩色（读数 2.4%、条、
                                 // 卡头「风险：中」）原本全取 `overallRisk`：条于是同时说两件事
                                 // ——长度说重复率、颜色说整档风险。一个语义一处着色：判档留在
                                 // 读数与徽标上，条退回数据块蓝（与巨大文件榜同一处理）。
                                 tint: ChartSeries.dataMarkColor,
                                 height: DataGaugeHeight.metric)
                        .frame(maxWidth: .infinity)
                    // 盘点表 B17（判「删」：重复块本卡读数带已占一格，复杂度上榜在
                    // 「复杂度风险」页的读数带占一格）。本轮 B 守恒线不许删，整条进 ⓘ。
                    // 顺带把原来两段 `+` 拼的串改成一条带位置参数的整句键 ——
                    // 拼串在运行时永远查不中（双语方案 §7.1），整句模板才有一条真键可登记。
                    CopyHelpBadge(localizedFormat("重复块 %1$@ 个 · 复杂度上榜 %2$@ 个函数",
                                                  NumberFormat.grouped(code.duplicatedBlocks.count),
                                                  NumberFormat.grouped(code.topComplexFunctions.count)))
                }
            }
        }
    }
}
