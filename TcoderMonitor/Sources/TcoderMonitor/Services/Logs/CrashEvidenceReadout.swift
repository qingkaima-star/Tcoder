//
//  崩溃证据那本细账 → 屏上那两句的**唯一装配口**（RD-60，台账 §48）。
//
//  形状照 `Services/Coverage/CoverageDisplayShape.swift`：
//  装配口住在 `Services/**`，视图只接已经拼好的串、不改写一个汉字。
//
//  ## 为什么必须新立这一个文件
//
//  RD-60 立案时实读到的是：`CrashEvidenceLedger.statement` 与 `unknownStatement` 把八种原因
//  分开算好了，却在 `Sources/**` 里**零生产读者**；屏上真正上屏的是
//  `LogSummary.crashEvidenceFootnote(...)`，它从**已落盘的趋势桶**另算一遍
//  （`historicalCrashCount`），于是同一个量有两把尺子，而且**分母不同**。
//  两把尺子的差值不是理论风险，已由 `CrashEvidenceRulerReproductionTests` 在同一个总体上
//  量出双向偏差（一边漏报窗口外的真崩溃报告，一边把普通日志的 FATAL 行算成历史崩溃）。
//
//  ## 本文件立的规矩
//
//  1. **只有一个装配口**：崩溃脚注的每一个汉字都在这里拼，别处（含 `Views/Logs/**`）
//     只许把返回值原样上屏。`CrashEvidenceReadoutGuardTests` 钉着这条。
//     唯一的调用点是 `FileLogAnalyzer.swift` 里 `LogSummary.crashEvidenceFootnote`
//     那一行转发（视图只认那一个入口）。
//  2. **不重算任何数**：八种原因**逐字**取自 `CrashEvidenceLedger.statement` /
//     `unknownStatement`（本函数只做串接与加窗口标签），一个数都不重新推导。
//     趋势桶那条路已经断开 —— 它把 `.fatal` 与 `.crash` 折进同一个格子
//     （`LogClustering.buckets`），拿它说「确认崩溃」是把两种证据混成一桶。
//  3. **细账缺席就说未统计**：拿不到台账、落盘九格也不齐（旧报告落盘的 JSON、崩溃那一路没跑）时，
//     逐条原因一律说「本次未统计」，**绝不**回落到任何一把平行尺子去估一个数。
//     `nil`（没统计）与 `0`（统计过、真的没有）在本文件里是两个不同的出口。
//     八种原因的**来路**也分三态记在 `Reading.origin` 上：台账直接在场 / 只从落盘九格接回 /
//     两者都没有。第三种来路决定「哪些没测准」那句说不说得出（见 `persistedFieldsGapsNotice`）。
//  4. **量纲不许混**：旧脚注那句 `max(0, 崩溃通道文件数 - crashCount)` 是**份数减次数**
//     ——一份报告可以含两次事件，于是这个差在两种方向上都会错。
//     现在份数只与份数相减（`crashChannelFileCount - filesWithCountedEvidence`），
//     而 `filesWithCountedEvidence` 只能由台账给出 ⇒ 细账缺席时这一格必须是 nil。
//
//  ## 接线状态（RD-60 第二半，R24）
//
//  契约已由总工落在 `LogSummary.crashEvidence`（九格全 Optional，`nil`=没统计 / `0`=查过真的是 0）。
//  三段各就各位：
//  · **写者**：`FileLogAnalyzer.analyzeWithEvidence` 在**同一次**分析里把台账九格直传进快照
//    （同一个 `ledger`、同一次遍历 —— 不为凑字段再 build 一遍台账）；
//  · **读者**：`readingFromFields(from:windowDays:)` 照 `CoverageMetrics.displayShapeFromFields`
//    的样子**按名字接回** —— 任一格缺席 ⇒ 整枚 `Reading` 为 `nil`，不重算、不换算、
//    **不拿 `crashCount` 顶替**；
//  · **出口**：视图 ⓘ 与 `score` 的文本读数都只经本文件的 `footnote`，八种原因逐条分开。
//
//  ⚠️ 仍开着的契约缺口（R24 报总工，不在这里绕过去）：九格承接的是**计数**，而
//  `unknownStatement` 那句「哪些没测准」吃的三项输入（当前构建键、观察到的构建版本数、
//  归属缺项的分布）在契约里没有格子 ⇒ 从落盘接回的那一路**说不出**这句。
//  本文件不猜、也不静默省略：由 `footnote` 明说这一格未落盘（`persistedFieldsGapsNotice`）。
//  RD-60 ③ 点名的那句"欠账已经欠出去了"的假话**已经长不回来**了
//  （账现在就在盘上，`CrashEvidenceReadoutGuardTests` 与 `CrashEvidenceWiringTests` 各钉一条）。
//

import Foundation

/// 崩溃证据细账的上屏装配口。**只拼话，不判定、不读盘、不改判据。**
enum CrashEvidenceReadout {

    /// 八种原因的分档计数 —— 那句「逐条原因」的**唯一生产者**吃的形状。
    ///
    /// 为什么要把这个形状单独立出来：那句话原本长在
    /// `CrashEvidenceLedger.statement` 里，于是**只有台账在场**才说得出；而台账不落盘
    /// （`LogAnalysisProviding.analyze` 的签名只回 `LogSummary`）。契约现在有九格快照，
    /// 视图与 CLI 手里只剩落盘的那几格 ⇒ 措辞必须从**同一处**产出，否则屏上那句与账上那句
    /// 迟早分叉（RD-43/51 同族）。所以：台账把自己的八枚数包成这个形状、快照按名字包成同一个形状，
    /// 两边都交给这里拼 —— 形状照 `CoverageDisplayShape.statementParts`。
    struct ReasonCounts: Equatable, Sendable {
        var counted: Int
        var historical: Int
        var staleBuild: Int
        var undated: Int
        var suspected: Int
        var parseFailed: Int
        var readFailed: Int
        var duplicates: Int

        /// 「测到了什么」那一句。**措辞逐字**沿用台账原来那句（一个数都不重新推导）。
        ///
        /// RD-60 第二半（R25b）：八条各是一枚**整句槽型键**（`%lld` 在句子里，量词跟着数走），
        /// 不是把「确认崩溃 」+ 数字 +「 次计入」拼出去 —— 英文语序会反转
        /// （`4 confirmed crashes counted`），而且 `次`/`份` 两支单复数只能由 `.stringsdict` 选。
        /// 中文态逐字不变：`String(format:` 填 `%lld` 与原来的 `\(...)` 打出来一模一样。
        var statement: String {
            var parts: [String] = []
            parts.append(localizedCount("确认崩溃 %lld 次计入", counted))
            if historical > 0 { parts.append(localizedCount("历史报告 %lld 次在窗口外", historical)) }
            if staleBuild > 0 { parts.append(localizedCount("旧构建 %lld 次未算当前版本", staleBuild)) }
            if undated > 0 { parts.append(localizedCount("无事件时间 %lld 次单列", undated)) }
            if suspected > 0 { parts.append(localizedCount("疑似报告 %lld 份", suspected)) }
            if parseFailed > 0 { parts.append(localizedCount("解析失败 %lld 份", parseFailed)) }
            if readFailed > 0 { parts.append(localizedCount("读取失败 %lld 份", readFailed)) }
            if duplicates > 0 { parts.append(localizedCount("同一事件去重合并 %lld 份", duplicates)) }
            return parts.joined(separator: " · ")
        }
    }

    /// 一次脚注要用的全部读数。构造它需要台账在场或落盘九格齐全，缺哪一格就留 `nil` ——
    /// `nil` 的意思是**没统计**，不是零。
    struct Reading: Equatable, Sendable {
        /// 八种原因从哪儿来。三态分开是因为「哪些没测准」那句只有前两种来路说得出一半。
        enum Origin: Equatable, Sendable {
            /// 同一次分析的台账直接在场（`analyzeWithEvidence` 的直接调用方）。
            case ledger
            /// 只从**落盘的九格**按名字接回 —— 视图与 CLI 在生产路径上拿到的就是这一种。
            case persistedFields
            /// 两者都没有（旧报告落盘时还没有这一格）⇒ 明说未统计。
            case notMeasured
        }

        /// 观察窗口天数，只用于把话说明白（「最近 7 天之外」），不参与任何判定。
        var windowDays: Int
        /// 窗口内计入的确认崩溃**次数**（与 `LogSummary.crashCount` 同源，由台账算好）。
        var countedCrashCount: Int
        /// 崩溃通道**读到几份**报告（份数，读成功的那些）。
        var crashChannelFileCount: Int
        /// 其中几份读取失败（份数，单独一本账，与上一格不重叠）。
        var readFailedFileCount: Int
        /// 八种原因分开算好的那一句 —— **逐字来自 `CrashEvidenceLedger.statement`**。
        /// `nil` = 本次没有细账（旧报告 / 那一路没跑）。
        var separatedReasons: String?
        /// 「哪些没测准」那一句 —— 逐字来自 `CrashEvidenceLedger.unknownStatement`。
        /// 从落盘九格接回的那一路**给不出**这一句（九格里没有它的判据输入）。
        var unmeasuredGaps: String?
        /// 出过可计数事件的**份数**（只能由台账给出）。`nil` = 没统计。
        var filesWithCountedEvidence: Int?
        /// 上面这些数的来路。
        var origin: Origin
    }

    /// 唯一一次装配。`evidence` 缺席时**先看落盘的九格**，两者都没有才说未统计：
    /// 这一条顺序就是 RD-60 要的那座桥，**不许**在中间插任何"拿 `crashCount` 估一个数"的回落。
    static func reading(from summary: LogSummary, evidence: CrashEvidenceLedger?,
                        windowDays: Int) -> Reading {
        if let evidence {
            return Reading(windowDays: windowDays,
                           countedCrashCount: summary.crashCount,
                           crashChannelFileCount: crashChannelFiles(in: summary),
                           readFailedFileCount: crashChannelReadFailures(in: summary),
                           separatedReasons: evidence.statement,
                           unmeasuredGaps: evidence.unknownStatement,
                           filesWithCountedEvidence: evidence.countablePaths.count,
                           origin: .ledger)
        }
        if let fromFields = readingFromFields(from: summary, windowDays: windowDays) {
            return fromFields
        }
        return Reading(windowDays: windowDays,
                       countedCrashCount: summary.crashCount,
                       crashChannelFileCount: crashChannelFiles(in: summary),
                       readFailedFileCount: crashChannelReadFailures(in: summary),
                       separatedReasons: nil,
                       unmeasuredGaps: nil,
                       filesWithCountedEvidence: nil,
                       origin: .notMeasured)
    }

    /// 从**落盘的那九格**按名字接回一枚读数（照 `CoverageMetrics.displayShapeFromFields` 的形状）。
    ///
    /// · 九格**任一**缺席 ⇒ `nil`：那一版根本没统计过。把缺的格子补成 `0` 就是
    ///   把「没数」说成「没有」（RD-26/46b 那一族），拿 `crashCount` 顶替第一格同样是造数；
    /// · 齐了才拼「逐条原因」，措辞走唯一生产者 `ReasonCounts.statement`
    ///   —— 与台账在场那一路**同一处**，谁也不许自己另拼一句；
    /// · `unmeasuredGaps` 在这一路只能留 `nil`：那句吃的三项输入都不在九格里（契约缺口，
    ///   已报总工）。`footnote` 对这一路会明说，不静默省略。
    static func readingFromFields(from summary: LogSummary, windowDays: Int) -> Reading? {
        guard let snapshot = summary.crashEvidence,
              let counts = snapshot.reasonCounts,
              let filesWithCounted = snapshot.filesWithCountedEvidence else { return nil }
        return Reading(windowDays: windowDays,
                       countedCrashCount: counts.counted,
                       crashChannelFileCount: crashChannelFiles(in: summary),
                       readFailedFileCount: crashChannelReadFailures(in: summary),
                       separatedReasons: counts.statement,
                       unmeasuredGaps: nil,
                       filesWithCountedEvidence: filesWithCounted,
                       origin: .persistedFields)
    }

    /// 崩溃通道**读到几份**（份数）。两处来路共用这一处，别处不再各数一遍。
    static func crashChannelFiles(in summary: LogSummary) -> Int {
        summary.scannedFiles.filter { $0.role == .crash }.count
    }

    /// 崩溃通道里**读不动**几份（份数，与上一格不重叠：失败的那些不在 `scannedFiles`）。
    static func crashChannelReadFailures(in summary: LogSummary) -> Int {
        (summary.readFailedFiles ?? []).filter { $0.role == .crash }.count
    }

    /// 「哪些没测准」那一句从落盘九格**接不回来**时说的实话。
    ///
    /// 这一句关于的是**现在还没落盘的那三项输入**（构建版本分桶与归属缺项），
    /// 不是 RD-60 ③ 立掉的那句假话 —— 八种原因现在已经在屏上了，缺的是"哪些没测准"那一半。
    /// 不许把它改成静默省略：省略会被读成"没有要补的账"。
    static let persistedFieldsGapsNotice =
        "「哪些没测准」那一句的判据输入未落盘，这里只呈现逐条原因"

    /// 卡头 ⓘ 里那一段完整脚注。**全仓唯一的崩溃证据上屏话**。
    static func footnote(_ reading: Reading, readFailureReasons: [String: Int] = [:]) -> String {
        var parts: [String] = []

        if let reasons = reading.separatedReasons {
            // 混槽整句键：第 1 槽 `%1$lld`（窗口天数，英文要分 `1 day` / `30 days`）、
            // 第 2 槽 `%2$@`（已经各自查过表的逐条原因整串）。
            // 原来这一句是「中文字面量 + 变量」拼出去的 ⇒ 拼完的整串永远查不中（守卫 1d 那一族）。
            // 走 `localizedCount(_:count:note:)` 这条路（本仓既有的混槽出口，不另造机制）：
            // 字符串槽先以一枚不含数字的占位符落地，补完千分位才换回真值。
            parts.append(localizedCount("最近 %1$lld 天为窗口，逐条原因如下：%2$@",
                                         count: reading.windowDays, note: reasons))
        } else {
            // 整句键，且是**目录里已有**的那一枚（批次 P69c 登记、`Localizable.stringsdict`
            // 顶层键 `窗口内确认崩溃 %lld 次，只统计有真实事件证据的报告`，one/other 两支）。
            // RD-60 之前这句话由 `FileLogAnalyzer` 用查表打出来，搬进本装配口时退化成了裸插值
            // ⇒ 键还活着、没人查，`test_p69CountKeysAreLookedUpAtTheirProducers` 当场判红。
            // 中文态一字未动：`String(format: 键, 4)` 就是「窗口内确认崩溃 4 次，…」。
            parts.append(localizedCount("窗口内确认崩溃 %lld 次，只统计有真实事件证据的报告",
                                         reading.countedCrashCount))
        }

        // 未产出可计数证据的**份数**：只在台账在场时才算得出（份数减份数）。
        if let counted = reading.filesWithCountedEvidence {
            let silentFiles = Swift.max(0, reading.crashChannelFileCount - counted)
            if silentFiles > 0 {
                // 整句键：量词 `份` 与数字分槽，英文侧 `A further %lld file …` / `… %lld files …`
                // 两支由 `.stringsdict` 选；中文态填完就是原来那句，一字未动。
                parts.append(localizedCount("另有 %lld 份崩溃通道文件未产出可计数的证据，逐条原因见上",
                                            silentFiles))
            }
        } else if reading.crashChannelFileCount > 0 {
            // 原来这一句是**两条中文字面量用 `+` 拼**出去的（守卫 1d 点名的形状：
            // 拼完的整串永远对不上任何一条键，英文态半英半中）。现在登记成一整条键，
            // 一个 `%lld` 槽，中文态填完与原来那两段的接续一字不差。
            parts.append(localizedCount(
                "崩溃通道读到 %lld 份报告；未产出可计数的证据是几种原因、各占几份，本次未统计（这份报告落盘时还没有崩溃证据细账）",
                reading.crashChannelFileCount))
            // 台账在场时「读取失败 N 份」是八种原因之一，已由上面那句带出来；
            // 缺席时这一格只剩已落盘的那本账可说，份数不许与次数相减去推。
            if reading.readFailedFileCount > 0 {
                parts.append(localizedCount("其中 %lld 份读取失败，未参与判定",
                                            reading.readFailedFileCount))
            }
        } else if reading.readFailedFileCount > 0 {
            parts.append(localizedCount("崩溃通道里 %lld 份读取失败，未参与判定",
                                         reading.readFailedFileCount))
        }

        if let gaps = reading.unmeasuredGaps {
            parts.append("未测准：" + gaps)
        } else if reading.origin == .persistedFields {
            // 只有落盘九格时这一句接不回来（它的三项输入没进契约）。
            // 与其静默省略，不如明说这一格还欠着 —— 静默消失会被读成"没有要补的账"。
            parts.append(persistedFieldsGapsNotice)
        }

        // 读取失败的原因分布来自已落盘的 `readFailedFiles`，与细账里那句「读取失败 N 份」
        // 是同一件事的两半（份数在细账、原因为什么在这里），所以这里不再报一遍数。
        let reasons = readFailureReasons.sorted { $0.key < $1.key }
            .map { "\($0.key) ×\($0.value)" }
        if reasons.isEmpty == false {
            parts.append("读取失败的原因分布：" + reasons.joined(separator: "、"))
        }
        return parts.joined(separator: " · ") + "。"
    }

    /// 把 `LogSummary.readFailedFiles` 里的原因归成「原因 → 几份」。
    /// 抽成函数是为了让唯一装配口之外**没有第二处**拼这句话。
    static func readFailureDistribution(_ summary: LogSummary) -> [String: Int] {
        let failed = (summary.readFailedFiles ?? []).filter { $0.role == .crash }
        return Dictionary(grouping: failed.compactMap { $0.readFailure }, by: { $0 })
            .mapValues { $0.count }
    }
}

// MARK: - 两条来路各自把「八种原因」凑成同一个形状

extension CrashEvidenceLedger {
    /// 台账的八种原因：八枚读数的**原样转发**，这里不做任何加减。
    /// 为什么放在装配口这一侧：那句话的唯一生产者必须是 `ReasonCounts.statement` 一处，
    /// 台账与落盘快照都往它身上包，屏上那句与账上那句才不可能分叉。
    var reasonCounts: CrashEvidenceReadout.ReasonCounts {
        CrashEvidenceReadout.ReasonCounts(counted: countedCrashCount,
                                          historical: historicalConfirmedCount,
                                          staleBuild: staleBuildConfirmedCount,
                                          undated: undatedConfirmedCount,
                                          suspected: suspectedCount,
                                          parseFailed: parseFailedCount,
                                          readFailed: readFailedCount,
                                          duplicates: duplicateCount)
    }
}

extension CrashEvidenceSnapshot {
    /// 落盘九格里的**八枚原因计数**按名字接回来。任一格缺席 ⇒ `nil`：那一版根本没统计过，
    /// 不许把缺的格子补成 `0`（`0` 说的是"查过了、真的没有"）。
    /// 第九格 `filesWithCountedEvidence` 是**份数**、量纲不同，由
    /// `CrashEvidenceReadout.readingFromFields` 单独按名字接，两处都齐了才谈得上接回。
    var reasonCounts: CrashEvidenceReadout.ReasonCounts? {
        guard let counted = countedCrashCount,
              let historical = historicalConfirmedCount,
              let staleBuild = staleBuildConfirmedCount,
              let undated = undatedConfirmedCount,
              let suspected = suspectedCount,
              let parseFailed = parseFailedCount,
              let readFailed = readFailedCount,
              let duplicates = duplicateCount else { return nil }
        return CrashEvidenceReadout.ReasonCounts(counted: counted, historical: historical,
                                                 staleBuild: staleBuild, undated: undated,
                                                 suspected: suspected, parseFailed: parseFailed,
                                                 readFailed: readFailed, duplicates: duplicates)
    }
}
