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
//  3. **细账缺席就说未统计**：拿不到台账（旧报告落盘的 JSON、崩溃那一路失败）时，
//     逐条原因一律说「本次未统计」，**绝不**回落到任何一把平行尺子去估一个数。
//     `nil`（没统计）与 `0`（统计过、真的没有）在本文件里是两个不同的出口。
//  4. **量纲不许混**：旧脚注那句 `max(0, 崩溃通道文件数 - crashCount)` 是**份数减次数**
//     ——一份报告可以含两次事件，于是这个差在两种方向上都会错。
//     现在份数只与份数相减（`crashChannelFileCount - filesWithCountedEvidence`），
//     而 `filesWithCountedEvidence` 只能由台账给出 ⇒ 细账缺席时这一格必须是 nil。
//
//  ⚠️ 契约缺口（写在 Obsidian `130 WS-R20 崩溃证据细账.md`，由总工落 `Models/LogInsights.swift`）：
//  `LogSummary` 里没有承接台账的格子，所以**视图现在拿不到 evidence**，
//  `evidence` 参数在生产路径上恒为 nil（只有单测与 `analyzeWithEvidence` 的直接调用方喂得出真值）。
//  字段落地后接线是一行：把 `evidence:` 传进来。本文件那一条**假话**已经先改掉：
//  旧脚注写着「逐条原因待 LogSummary 落盘崩溃证据字段后展示」，
//  而账其实早就算完了 —— 那是 RD-60 ③ 点名的未完成项，不在这里留。
//

import Foundation

/// 崩溃证据细账的上屏装配口。**只拼话，不判定、不读盘、不改判据。**
enum CrashEvidenceReadout {

    /// 一次脚注要用的全部读数。构造它需要台账在场，缺哪一格就留 `nil` ——
    /// `nil` 的意思是**没统计**，不是零。
    struct Reading: Equatable, Sendable {
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
        var unmeasuredGaps: String?
        /// 出过可计数事件的**份数**（只能由台账给出）。`nil` = 没统计。
        var filesWithCountedEvidence: Int?
    }

    /// 唯一一次装配。`evidence` 缺席时**不猜测**：只把已落盘的三格说出口。
    static func reading(from summary: LogSummary, evidence: CrashEvidenceLedger?,
                        windowDays: Int) -> Reading {
        let channelFiles = summary.scannedFiles.filter { $0.role == .crash }.count
        let failedFiles = (summary.readFailedFiles ?? []).filter { $0.role == .crash }.count
        guard let evidence else {
            return Reading(windowDays: windowDays,
                           countedCrashCount: summary.crashCount,
                           crashChannelFileCount: channelFiles,
                           readFailedFileCount: failedFiles,
                           separatedReasons: nil,
                           unmeasuredGaps: nil,
                           filesWithCountedEvidence: nil)
        }
        return Reading(windowDays: windowDays,
                       countedCrashCount: summary.crashCount,
                       crashChannelFileCount: channelFiles,
                       readFailedFileCount: failedFiles,
                       separatedReasons: evidence.statement,
                       unmeasuredGaps: evidence.unknownStatement,
                       filesWithCountedEvidence: evidence.countablePaths.count)
    }

    /// 卡头 ⓘ 里那一段完整脚注。**全仓唯一的崩溃证据上屏话**。
    static func footnote(_ reading: Reading, readFailureReasons: [String: Int] = [:]) -> String {
        var parts: [String] = []

        if let reasons = reading.separatedReasons {
            parts.append("最近 \(reading.windowDays) 天为窗口，逐条原因如下：" + reasons)
        } else {
            parts.append("窗口内确认崩溃 \(reading.countedCrashCount) 次，只统计有真实事件证据的报告")
        }

        // 未产出可计数证据的**份数**：只在台账在场时才算得出（份数减份数）。
        if let counted = reading.filesWithCountedEvidence {
            let silentFiles = Swift.max(0, reading.crashChannelFileCount - counted)
            if silentFiles > 0 {
                parts.append("另有 \(silentFiles) 份崩溃通道文件未产出可计数的证据，逐条原因见上")
            }
        } else if reading.crashChannelFileCount > 0 {
            parts.append("崩溃通道读到 \(reading.crashChannelFileCount) 份报告；"
                + "未产出可计数的证据是几种原因、各占几份，本次未统计（这份报告落盘时还没有崩溃证据细账）")
            // 台账在场时「读取失败 N 份」是八种原因之一，已由上面那句带出来；
            // 缺席时这一格只剩已落盘的那本账可说，份数不许与次数相减去推。
            if reading.readFailedFileCount > 0 {
                parts.append("其中 \(reading.readFailedFileCount) 份读取失败，未参与判定")
            }
        } else if reading.readFailedFileCount > 0 {
            parts.append("崩溃通道里 \(reading.readFailedFileCount) 份读取失败，未参与判定")
        }

        if let gaps = reading.unmeasuredGaps {
            parts.append("未测准：" + gaps)
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
