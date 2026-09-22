import Foundation

// OWNER: WS-R17 扫描范围进契约（RD-15 · 申请单 R6 §3）—— 落盘那一族读数的**上屏装配口**。
//
// 为什么单独一个文件：判据本体（`SourceScanScopeReadout` / `SourceTreeFollowingLedger` /
// `SourceSkipLedger`）本轮流**只读复用、一字不改**（工单白名单第 3 条），而那三个类型的句子
// 住的那两个文件加起来已经 500 行，把新读数塞进去就是去改别人的判据。
// ⚠️ 本文件是 `Sources/**` 新增文件 ⇒ `SourceFileReachabilityTests.censusBaseline`
// 要从 181 拧到 182，那把常量**只由总工拧**，本流没有动它。
//
// 这一档只回答一个问题：**读 JSON 与看终端的人，怎么拿到「排除了几个、那些有多少行、
// 行数到底数没数」这三个数**。判据不在这里 —— 数值全部来自 `CodeMetrics.scanSurface`
// （由 `FileSystemCodeAnalyzer.scanSurface(from:)` 直传内部台账），这里一个字都不重算。

// MARK: - 范围台账那两句上屏话（唯一装配口）

/// `CodeMetrics.scanSurface` → 上屏那两句的**唯一装配口**。
///
/// 形状与 `MixedLanguageRegionCaliber.note(_:)` / `CoverageMetrics.boardAccountingNote`
/// 同一条纪律：界面与 CLI 共用一把尺子，谁都不许另写一份中文（那是第二把尺子）。
enum CodeScanSurfaceReadout {

    /// 三个出口，**三个不同的读数**（本轮全部工作的母判据）：
    ///
    /// 1. **没有台账**（`scanSurface == nil`，或 `totalCount == nil` —— 申请单点名的就是这一态）
    ///    ⇒ 一句缺席话。绝不许长成「排除了 0 个」：那份报告压根没跑这一路。
    /// 2. **有台账、什么都没排除没剪没挡** ⇒ **一个字都不许多**（与 `SourceScanScopeReadout.notes`
    ///    同一条纪律：常驻的"范围说明"等于把噪声当诚实）。
    /// 3. **有数** ⇒ 两句纯数字装配。`excludedLineCount` 那一格走内部三态读数自己的
    ///    `describe(unit:)` —— 「0 行」与「行数未统计」永远不同，落成字段之后这条继续钉住。
    ///
    /// - Parameter code: 一份代码度量。`scanSurface` 缺席时走第 1 档，不补 0。
    static func accountingLines(_ code: CodeMetrics) -> [String] {
        guard let surface = code.scanSurface else { return [absentLedgerSentence] }
        guard surface.totalCount != nil else { return [absentLedgerSentence] }
        guard speaksUp(surface) else { return [] }
        return [encounteredSentence(surface), blindSpotSentence(surface)]
    }

    /// 缺席话：整枚字段没落盘、或有台账却没有"看到了多少条目"这个顶格读数。
    private static var absentLedgerSentence: String {
        localizedCopy("扫描范围：本次没有范围台账 —— 这一路没跑过，或这份报告出自没有这一格的旧结构，所以「排除了几个」这类读数一个都不成立。")
    }

    /// 干净扫描的判据：每一格都是量到的 0（或没记）⇒ 不出声。
    /// 任一非零 ⇒ 必须出声。这里**只读字段**，不碰 `scanLimitations` 的中文句子。
    private static func speaksUp(_ surface: CodeScanScope) -> Bool {
        (surface.reportedExcludedEntryCount ?? 0) > 0
            || (surface.unmeasuredScope?.isEmpty == false)
            || (surface.nestedRepositoryCount ?? 0) > 0
            || (surface.submoduleMarkerCount ?? 0) > 0
            || (surface.symbolicLinkFileCount ?? 0) > 0
            || (surface.symbolicLinkDirectoryCount ?? 0) > 0
            || (surface.unlistedPrunedDirectoryCount ?? 0) > 0
            || (surface.unreadableDirectoryCount ?? 0) > 0
    }

    /// 顶格那句：看到多少条目、按规则排除多少、其中逐条点名了几条。
    /// ⚠️ 相加只走 `reportedExcludedEntryCount` 这一处取法，这里不再写一遍 `displayed + undisplayed`。
    private static func encounteredSentence(_ surface: CodeScanScope) -> String {
        localizedFormat("扫描范围台账：遍历看到 %1$@ 个条目 · 按规则排除 %2$@ 个（逐条点名 %3$@ · 未点名 %4$@）· 没量到的范围 %5$@ 条。",
                        grouped(surface.totalCount),
                        grouped(surface.reportedExcludedEntryCount),
                        grouped(surface.displayedCount),
                        grouped(surface.undisplayedCount),
                        grouped(surface.unmeasuredScope?.count))
    }

    /// 第二句：那些"没看/没数"的格子各自有多少。`--` 是缺读数（`DataAbsence` 那一份口径），
    /// `0` 是量过了真的是 0 —— 两件事在同一格里也必须长得不一样。
    private static func blindSpotSentence(_ surface: CodeScanScope) -> String {
        localizedFormat("排除条目的行数：%1$@ · 仓库标记 %2$@ 个 · 其中 submodule 形状 %3$@ 个 · 软链接文件 %4$@ 个 · 目录软链接 %5$@ 个 · 名单外被系统判定剪掉的目录 %6$@ 个 · 读不动的目录 %7$@ 个。",
                        excludedLineReading(surface),
                        grouped(surface.nestedRepositoryCount),
                        grouped(surface.submoduleMarkerCount),
                        grouped(surface.symbolicLinkFileCount),
                        grouped(surface.symbolicLinkDirectoryCount),
                        grouped(surface.unlistedPrunedDirectoryCount),
                        grouped(surface.unreadableDirectoryCount))
    }

    /// 「数过了是 0」与「没数」两种读数的**唯一渲染**：
    /// · `excludedLineCount == nil` ⇒ 「行数未统计」（申请单点名的话）；
    /// · 有值 ⇒ 走内部三态读数自己的 `describe(unit:)`，与台账那句共用同一个格式化器。
    /// ⚠️ `linesCounted == false` 而 `excludedLineCount` 有数**不该同时出现**（装配口构造不出来），
    /// 真在旧 JSON 里撞上这种组合时，这里按"没数"处理 —— 宁可少给一个数，不可把没数的 0 当真数。
    private static func excludedLineReading(_ surface: CodeScanScope) -> String {
        guard surface.linesCounted != false, let lines = surface.excludedLineCount else {
            return localizedCopy("行数未统计")
        }
        return SourceScopeCount.measured(lines).describe(unit: "行")
    }

    /// 一格可选读数的上屏值：有数走千分位，没数走 `DataAbsence` 那一份 `--`。
    /// 不写 `?? 0`，也不手写占位符字面量（那两处都被设计系统守卫拦着）。
    private static func grouped(_ value: Int?) -> String {
        DataAbsence.optional(value.map { NumberFormat.grouped($0) }).display
    }
}
