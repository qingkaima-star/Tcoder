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
        /// 「留短藏长」的 ⓘ 那半截（`EmptyStateView` 自带的 `help:` 槽）。
        /// 为什么随文案一起走：这一族的三种态由本文件单点产出，页面只做一次转发；
        /// 让页面自己再决定哪句进 ⓘ 就会出现同一空态在两个页面两种详略。
        var help: String? = nil
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
                // 盘点表「留短藏长」：屏上留"该点哪里"这一句（读完就能动手）；后半
                // 「完成后这里会显示真实的文件数…」是**预告**（等于没说，与性能页那条
                // 判「藏」的采样预告同形），整句进 ⓘ。「还没测」这件事由上面的 title 常驻承担。
                message: localizedCopy("点击「重新分析」开始扫描该目录。"),
                help: localizedFormat("点击「重新分析」开始扫描该目录。\n完成后这里会显示真实的文件数、行数与%1$@。", page)
            )
        case .measuredEmpty:
            return EmptyCopy(
                icon: .emptyTray,
                title: "扫描结果为空",
                // 一整句 = 一个键：拆成 `"…\n" + "…"` 时运行时查表的是拼接后的整串，
                // 半句键永远等不到（守卫 1c 抓到，批次 P5）。
                message: "扫描已完成，但没有识别到任何源码文件（构建产物、依赖目录与不受支持的后缀会被跳过）。\n这是测得的结果，不是没有扫描，因此不给任何风险结论。"
            )
        }
    }
}

// MARK: 榜单口径（RD-17 ·「榜长冒充总数」那一族）

/// 「这块数字是**榜**的还是**总体**的」——代码两页共用的判定。
///
/// 为什么必须有这一层：重复明细榜被 `DuplicationEngine.maxBlocks` 截过，而
/// `CodeMetrics.duplicatedBlocks` 装的就是那份榜。直接读它的 `count` 当"这个仓库有多少
/// 重复块"，在大仓库上是把问题**报小**（巨大文件那一格已经为同一件事补了 `hugeFileCount`）。
///
/// 引擎其实算得出榜外还剩多少：`DuplicationResult.blocksDroppedByCap` 与
/// `linesOutsideReportedBlocks`。但这两个数只活在 `scanLimitations` 那句中文说明里，
/// 契约里没有承接字段 ⇒ 这里只做两件不造假的事：
/// ① 读数标签按「榜内」出水（`count` 是榜长，永远不是总体数，所以**不加条件**也成立）；
/// ② 把引擎那句"未列出 N 个块 / M 行"原样带上屏，让榜外那一半看得见。
/// **没有**从那句散文里抠数字回来做算术 —— 那等于造第二把尺子。
enum CodeBoardTruth {
    /// 明细榜的封顶长度。读引擎那一份，不在这里另抄一个 20。
    static var duplicationBlockCap: Int { DuplicationEngine.maxBlocks }

    /// 「榜外还有多少块/行没列」那一条限制说明，由引擎产出（`CodeScanCoverage.limitationSummary`）。
    /// `nil` = 本次没有明细被上限切掉 ⇒ 此时"榜长就是总数"这句话才是真的。
    ///
    /// ⚠️ 这里按**句式**认领，不是按前缀瞎找：`AdviceWordingBoardTests` 里有一条对账断言钉着
    /// 「引擎那句话仍然含这个标记」，谁改了文案没改这里，先红在对账上。
    static let outsideBoardMarker = "明细榜单截断"

    static func outsideBoardNote(_ code: CodeMetrics) -> String? {
        code.scanLimitations?.first { $0.contains(outsideBoardMarker) }
    }

    /// 榜长的**唯一取法**。名字里就写着 Board：它是榜内条数，不是这个仓库的重复块总数。
    /// 真总数要等契约里那一格（`duplicatedBlockCount`，与巨大文件的 `hugeFileCount` 同形状），
    /// 在那之前任何消费方都不许把这一串读成总数 —— 标签、量词、页尾句都由本文件配平。
    static func duplicationBoardCount(_ code: CodeMetrics) -> Int {
        code.duplicatedBlocks.count
    }

    /// 榜长能不能被读成"这个仓库的重复块总数"：**榜满了就不能**。
    ///
    /// 判据只取「榜长 ≥ 上限」这一条，刻意**不**依赖台账里有没有那句话——
    /// CLI 实跑（`.scratch/r7-cli`，409 行的 .ts + .swift）抓到过这个形状：
    /// 榜内 4 块、`blocksDroppedByCap = 0`，但 `fragmentsDroppedByBudget = 1066`，
    /// 于是台账照样产出一句"明细榜单截断…"。按句判"榜被截了"会把**没满的榜说成满了**，
    /// 那是把一件没发生的事渲染出来（与"把没量到渲染成没有问题"对称的另一头）。
    /// 反向偏差只有一格：恰好 20 块时多说一句"榜内"，那句话依旧是真话（它确实在榜内）。
    static func boardAtCap(_ code: CodeMetrics) -> Bool {
        duplicationBoardCount(code) >= duplicationBlockCap
    }

    /// 「重复块」这一格读数的标签：只有榜满了才需要「榜内」这个限定，
    /// 榜没满时"榜内"反而是一句让人找下文的话。
    static func duplicationSlotLabel(_ code: CodeMetrics) -> String {
        localizedCopy(boardAtCap(code) ? "重复块（榜内）" : "重复块")
    }

    /// 展开按钮的量词（`noun:` 不是查表入口，所以这里给的是上屏原文，与"个重复块"同性质）。
    static func duplicationHiddenRowsNoun(_ code: CodeMetrics) -> DisclosureNoun {
        boardAtCap(code) ? .cappedBlocks : .duplicateBlocks
    }

    /// 重复率口径句里的那个词（同一句里"约 X 行 / 有效代码 Y 行"是**全仓**口径，两件事要分开）。
    static func duplicationBlockWord(_ code: CodeMetrics) -> String {
        boardAtCap(code) ? "榜内重复块" : "重复块"
    }

    /// 页尾那句。三态：
    /// ① 榜满 ⇒ 只说"榜内只列"，并点名上限，**绝不**说"已全部列出"；
    /// ② 榜没满但本页折叠了 ⇒ 说"列出多少 / 一共多少"；
    /// ③ 榜没满且全展示了 ⇒ 这时"已全部列出"才是真话（并把上限一起写出来，让人看得见尺子）。
    /// 台账那句（榜外还有多少块/行、多少处拷贝没展开）**原样追加**：它是引擎产出的数据，
    /// 不是这里造的文案 —— 也从没把它抠成数字参与算术，那是第二把尺子。
    static func duplicationTruncationNote(_ code: CodeMetrics, shown: Int) -> String {
        let listed = duplicationBoardCount(code)
        let cap = duplicationBlockCap
        let base: String
        if listed >= cap {
            base = localizedFormat("榜内只列 %1$@ 个（明细榜上限 %2$@ 块）· 本页当前列出 %3$@ 个。",
                                   NumberFormat.grouped(listed), NumberFormat.grouped(cap),
                                   NumberFormat.grouped(shown))
        } else if listed > shown {
            base = localizedFormat("当前列出 %1$@ / %2$@ 个。",
                                   NumberFormat.grouped(shown), NumberFormat.grouped(listed))
        } else {
            base = localizedFormat("共 %1$@ 个重复块，已全部列出（榜未触顶，上限 %2$@ 块）。",
                                   NumberFormat.grouped(listed), NumberFormat.grouped(cap))
        }
        guard let outside = outsideBoardNoteFromFields(code) ?? outsideBoardNote(code).map({ localizedCopy($0) })
        else { return base }
        return base + " " + outside
    }

    /// 由**字段**装配的榜外说明（RD-48）。
    ///
    /// 为什么优先走这条：`outsideBoardNote` 是"按句式去中文台账里认领一句话"，
    /// 引擎改了文案而这里没改标记，披露就静默消失（R7 交回时自己点明了这个耦合，并对账钉住它）。
    /// 字段落地后数字有了直传通道，页尾这句改由数装配；**旧报告没有这些格** ⇒ 返回 `nil`，
    /// 调用方退回认领句子那条路，两种来源都不许让榜外那一半看不见。
    /// ⚠️ 仍然**不做加法**：这里不合成"总块数"。撞 id 那一格（RD-85）落成读数之后，
    /// 「榜内 + 榜外 + 合并掉 == 原始命中」这条账平了，但屏上这句只逐条点名三项，
    /// 不把三项加成一个数再印 —— 加出来的那个数一旦被读成"这个仓库有多少处克隆"，
    /// 就把"原始命中"和"去重后的块"两把尺子又混回一把了。
    static func outsideBoardNoteFromFields(_ code: CodeMetrics) -> String? {
        let merged = code.duplicatedBlocksDroppedByIdCollision ?? 0
        guard let dropped = code.duplicatedBlocksDroppedByCap,
              let outsideLines = code.duplicatedLinesOutsideReportedBlocks,
              dropped > 0 || outsideLines > 0 || merged > 0 else { return nil }
        var note = ""
        if dropped > 0 || outsideLines > 0 {
            note = localizedFormat("另有 %1$@ 个块 / %2$@ 行未列入榜内。",
                                   NumberFormat.grouped(dropped), NumberFormat.grouped(outsideLines))
        }
        if merged > 0 {
            // 旧话术一字未动（第 21 类盲区：加新维度时旧句必须原样），这句只在有数时才出声。
            if !note.isEmpty { note += " " }
            note += localizedFormat("另有 %1$@ 处重复命中与别处合并为一条（同一组文件、同一长度）。",
                                    NumberFormat.grouped(merged))
            // RD-86：数之外还要点名坐标，否则这句仍然只是一条无法反驳的账（RD-17 老账）。
            // ⚠️ 但**点名条数归 `DuplicationResult.proseCoordinateBudget` 那把尺子管**，不是取样上限：
            // 字段里那 6 条是给读机器的人看的，散文只负责让人看到长什么样（RD-52 原话）。
            // 第一版这里 join 了整串取样 ⇒ 一句页尾被六条坐标撑长，而多出来的那几条并没有因此更可核对。
            if let spots = code.duplicateBlockCoordinatesMergedById, !spots.isEmpty {
                let named = min(spots.count, DuplicationResult.proseCoordinateBudget)
                note += " " + localizedFormat("被合并的那几处在：%1$@。",
                                             spots.prefix(named).joined(separator: localizedListSeparator()))
                if spots.count > named {
                    note += localizedFormat("（另有 %1$@ 处未点名）", NumberFormat.grouped(spots.count - named))
                }
            }
        }
        if let fragments = code.duplicateFragmentsNotExpandedCount, fragments > 0 {
            note += " " + localizedFormat("另有 %1$@ 处拷贝因指纹预算未展开。", NumberFormat.grouped(fragments))
        }
        return note.isEmpty ? nil : note
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

    /// 把坐标还原成能打开的路径：**全站唯一的一个入口**（Finder 定位与「用默认应用打开」都走它）。
    /// 树里现在同时存在两种坐标形状，两条分支各有真读者，一条都不能删：
    /// · **相对**被扫根 —— 重复块坐标（`DuplicatedFragment.path`，RD-61 第二半之后
    ///   在 `DuplicationScanState.fragmentOf` 那一处就定成相对），走 `appendingPathComponent` 那一支；
    /// · **绝对** —— 巨大文件榜与复杂度热点榜（`FileSystemCodeAnalyzer` 给的是 `url.path`），
    ///   以及**改前落盘的旧报告**里那批重复块坐标，走 `hasPrefix("/")` 那一支。
    /// 根由调用方从 `report.project.path` 传入，与装配 `provenance.scannedRoot` 用的是同一个串，
    /// 所以「拼回去」与「谁产的这份报告」不会分叉。
    static func resolvedURL(_ path: String, root: String) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        if !root.isEmpty { return URL(fileURLWithPath: root).appendingPathComponent(path) }
        return URL(fileURLWithPath: path)
    }

    static func duration(_ durationMs: Int) -> String {
        guard durationMs >= 1_000 else {
            return localizedFormat("%@ 毫秒", NumberFormat.grouped(durationMs))
        }
        return localizedFormat("%@ 秒", String(format: "%.2f", Double(durationMs) / 1_000))
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
            // 单位必须走查表的整句键。原来是 `"\(NumberFormat.grouped(...)) 行"` ——
            // 插值出来的串不是键，英文态永远命中不了（2026-09-21 英文九页实拍抓到，
            // 同文件下面那行 `localizedCount("%lld 行", …)` 一直是对的写法）。
            detail: localizedCount("%lld 行", share.lineCount),
            fraction: share.share,
            // 语言名就写在条的左边，颜色不携带信息 —— 与 `Theme.Share.Row`
            // 同一判断（用户实拍：代码规模页一个小区块里绿/棕/琥珀/红/蓝五色）。
            // 同上：占比条是数据块，走 `ChartSeries.dataMarkColor`；
            // "颜色不携带信息"这条论证反对的是**不同色相区分序列**，不是数据块的颜色。
            tint: ChartSeries.dataMarkColor,
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
        HStack(alignment: .center, spacing: DataRowMetrics.cellGap) {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                HStack(alignment: .center, spacing: DataRowMetrics.cellGap) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text(CodeViewFormat.fileName(hotspot.path))
                            .font(CodeGitType.tableIdentifier)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(CodeViewFormat.directoryTail(hotspot.path, root: root))
                            .font(CodeGitType.path)
                            // 路径是元数据、可以弱，但**不能用 `.tertiary`**：
                            // 本轮把 `.tertiary` 从五页整体清零，因为「弱」这件事
                            // 已经由 10pt 字号表达了，再降透明度就滑向"可以不读"。
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tableCell(DataColumns.column(columns, 0))

                    MiniBarGauge(fraction: fraction,
                                 // 柱长是**体量**（本文件行数 / 全仓最大行数），风险在下一列已有徽标；
                                 // 涂风险色等于一个字形说两件事，页尾实拍里九行全绿被读成"九个体量都是好事"。
                                 tint: ChartSeries.dataMarkColor,
                                 height: DataGaugeHeight.inline)
                        .frame(maxWidth: .infinity)
                        .tableCell(DataColumns.column(columns, 1))

                    Text(localizedCount("%lld 行", hotspot.lineCount))
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
        .dataTableRow()
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
                .accessibilityLabel(Text(localizedFormat("用默认应用打开 %@", CodeViewFormat.fileName(path))))
        }
        .buttonStyle(.plain)
        .frame(minWidth: Theme.Layout.minHitTarget, minHeight: Theme.Layout.minHitTarget)
        .help(Text(localizedFormat("用默认应用打开 %@", CodeViewFormat.fileName(path))))
    }
}
