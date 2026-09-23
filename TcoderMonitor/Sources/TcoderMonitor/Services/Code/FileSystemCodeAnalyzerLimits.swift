import Foundation

/// OWNER: 集成轮 · WS-INT —— `FileSystemCodeAnalyzer` 的「扫描覆盖度台账」分片。
///
/// **这一整块是从 `Services/Code/FileSystemCodeAnalyzer.swift` 逐字节搬出来的**，
/// `CodeScanCoverage` 一个判据、一条阈值、一处顺序、一句文案都没动。
/// 搬的原因只有规模：R1 在 `analyzeWithCoverage` 的文档注释与 `JavaSignatureDeclines.notes`
/// 拼接上加了几行、R2 在同一个类型里加了词法完整性/分区退回那几格，两家各自都没越线，
/// 合到集成分支就是 403 行，同时被 `SourcesSizeAuditTests` 与 `CodeComplexityDebtTests`
/// 点名（口径同源，都是产品侧 `FileSystemCodeAnalyzer.mediumFileLines` = 400 行）。
/// 按 AGENTS.md §3 横切约束 4：**按类型整块搬去新文件才是修复**，
/// 往 `hugeFileWorkList` 里塞条目是挂账，不算。
///
/// 形状与本包既有分片一致（`ComplexityCounting.swift` / `FunctionScanning.swift` 同理）：
/// 只写 `extension FileSystemCodeAnalyzer`，不新建第二个类型宿主。
extension FileSystemCodeAnalyzer {
    /// 一次扫描的「看到了多少、被哪条上限切掉了多少」。
    ///
    /// 背景（WS-D 诚实性审计 P1 #7）：扫描器本来就维护 `truncatedByMaxFiles` /
    /// `visitedFileCount` / `skippedFileCount`，但原先 `analyze` 只取 `scan.files`，
    /// 四个字段连同「2MB 单文件上限、30 项 skipDirectories、扩展名白名单、20 万行/文件截断」
    /// 一起被丢掉，UI 于是把一份**部分测量**呈现成完整测量。这里一个都不再丢。
    ///
    /// 契约缺口**已闭合**（批次 P7-C 3-2）：`CodeMetrics.scanLimitations` 承接
    /// `limitationSummary`，代码规模页据此挂一条"本次是部分测量"的提示。
    struct CodeScanCoverage: Sendable {
        var visitedEntryCount: Int
        var includedFileCount: Int
        var skippedFileCount: Int
        var truncatedByMaxFiles: Bool
        var maxFiles: Int
        var maxFileBytes: Int
        /// 超过 20 万行、只统计了前 20 万行的文件数
        var lineTruncatedFileCount: Int
        /// 归一化行数触到重复检测滑窗上限（2 万行/文件）而被丢弃后半部分的文件数
        var filesHittingDuplicateLineCap: Int
        /// 因每指纹片段预算而未展开成明细片段的拷贝窗口数
        var duplicateFragmentsDroppedByBudget: Int
        /// 榜单截断到 20 块时丢掉的块数与它们覆盖的行数
        var duplicateBlocksDroppedByCap: Int
        var duplicateLinesOutsideReportedBlocks: Int
        /// 遍历中读不动的目录数（权限 / 竞态消失）。这些子树里的文件**一个都没看到**，
        /// 与"看了、没有"是两件事 —— 见 `SourceScanResult.unreadableDirectoryCount`。
        var unreadableDirectoryCount: Int = 0
        /// R2（RD-06 / RD-07）：**函数识别这一路的词法完整性汇总**，各文件 `LexIntegrity` 相加。
        /// `hasAnomaly` 为真 ⇒ 函数条数、边界、复杂度都是在「有些行没进统计」的范围里量出来的，
        /// 是一份**部分测量**：HEAD 之前这一格不存在，未闭合模板串把后面整段吃掉时，
        /// 界面上读起来就是「这个仓库 0 个函数」。
        var lexIntegrity: ComplexityEngine.LexIntegrity = ComplexityEngine.LexIntegrity()
        /// 有词法异常的文件数（异常分布在几个文件上，比"共 N 处"更有用）
        var lexAnomalousFileCount: Int = 0
        /// 命中了函数签名、但边界推不出来而放弃的总数
        var unboundedFunctionSignatureCount: Int = 0
        /// `.vue` 分区认不出来、退回旧 `<script` 粗判掩码的文件数
        var vueRegionFallbackFileCount: Int = 0
        var skipLedger: SourceSkipLedger = SourceSkipLedger()
        // MARK: R6（RD-14~17）新增的三格 —— 全部走 `limitationSummary` 同一个出口，
        // 因此**天生有两个读者**：界面 `CodeMetricsView` 的扫描边界 ⓘ 与 CLI `score` 的「未量准」段。
        // 声明顺序必须在最后：`coverage(from:duplication:options:lex:)` 用的是合成出的
        // 逐参数初始化器，插在中途会把既有调用点的实参顺序打乱。
        /// 文件角色分档累计（RD-14）。判据在 `SourceFileRoleRules.swift`。
        var roleTally: SourceRoleTally = SourceRoleTally()
        /// 遍历「跟不跟」的现场计数（RD-15）：软链接 / 嵌套仓库 / 包状目录 / 名单外被剪的目录。
        var treeFollowing: SourceTreeFollowingLedger = SourceTreeFollowingLedger()
        /// 榜外未列重复块的稳定坐标（RD-17）。空 = 没有榜外块。
        var duplicateBlockCoordinatesOutsideBoard: [String] = []
        /// 重复率那一格的口径自述，仅在榜内/榜外两个数真的分叉时才非空。
        var duplicationBoardCaliber: String = ""

        /// 有任一**上限**真的生效过 ⇒ 这份数字是部分测量，UI 不得当成全量展示。
        /// 注意不含「按规则主动排除」：跳过 vendor/二进制是范围定义，不是被截断。
        var isPartial: Bool {
            truncatedByMaxFiles || lineTruncatedFileCount > 0 || skippedFileCount > 0
                || filesHittingDuplicateLineCap > 0 || duplicateFragmentsDroppedByBudget > 0
                || duplicateBlocksDroppedByCap > 0 || unreadableDirectoryCount > 0
                || lexIntegrity.hasAnomaly || unboundedFunctionSignatureCount > 0
                || vueRegionFallbackFileCount > 0
        }

        /// 有多少条目是按规则排除的（范围问题），与「被上限切掉」分开报，两件事混在一起用户就没法判断偏差方向。
        var excludedEntryCount: Int { skipLedger.skippedFileTotal }
        var excludedLineCount: Int { skipLedger.skippedLineTotal }

        /// 完整的「少掉的部分去哪了」清账，一行一条原因。`skipLedgerAuditRan` 为 false 时
        /// 如实标注行数未统计，不会把 0 当成「这些文件没有行」。
        func skipClearing() -> [String] {
            skipLedger.clearing(linesCounted: skipLedger.linesCounted)
        }

        /// §6 统一形状的**扫描范围**读数（RD-15 第二件）。产品路径永远 `observed = true`；
        /// `notObserved` 那一支留给没有台账的报告（旧 JSON / 只拿到 `CodeMetrics` 的下游），
        /// 它渲染出的句子与「排除了 0 个」必须不同 —— 这条由 `SourceScanScopeTests` 钉住。
        var scopeReadout: SourceScanScopeReadout {
            SourceScanScopeReadout.build(ledger: skipLedger,
                                         encounteredEntryTotal: visitedEntryCount + skipLedger.skippedFileTotal,
                                         cappedRemaining: truncatedByMaxFiles,
                                         unreadableDirectoryCount: unreadableDirectoryCount,
                                         following: treeFollowing)
        }

        /// R6 那三条读数走的是**另一个出口**而不是挤进 `limitationSummary`：
        /// 后者已经有 48 行，本包的 `CodeComplexityDebtTests` 管 50 行/函数这条线。
        /// 与它同一条纪律：零命中不出声；同一次装配里由 `analyzeWithCoverage` 拼进
        /// `CodeMetrics.scanLimitations` ⇒ 界面与 CLI 同时拿到，不留只有一个读者的读数。
        var surfaceNotes: [String] {
            var lines: [String] = []
            lines.append(contentsOf: roleTally.notes)
            lines.append(contentsOf: treeFollowing.notes)
            lines.append(contentsOf: scopeReadout.notes)
            // RD-52：这一句原先把榜外坐标的**同一串 id** 再抄一遍（口径句里已经点过名），
            // 于是一条上限被撑成两千多字符、还在同一份报告里出现两次。
            // 现在坐标只在 `DuplicationResult.boardCaliberNote` 里点名一次，
            // 机器可读数落在 `CodeMetrics.duplicateBlockCoordinatesOutsideBoard`（同一个来源）。
            if duplicationBoardCaliber.isEmpty == false { lines.append(duplicationBoardCaliber) }
            return lines
        }

        /// 逐条带真实数字的限制说明，供横幅/脚注直接展示。
        var limitationSummary: [String] {
            var lines: [String] = []
            if truncatedByMaxFiles {
                lines.append("达到单次扫描文件上限 \(NumberFormat.grouped(maxFiles))，其余文件未读，结果偏小。")
            }
            if lineTruncatedFileCount > 0 {
                lines.append("\(NumberFormat.grouped(lineTruncatedFileCount)) 个文件超过 20 万行，只统计了前 20 万行。")
            }
            if skippedFileCount > 0 {
                lines.append("\(NumberFormat.grouped(skippedFileCount)) 个文件被跳过（超过 \(ByteFormat.string(UInt64(maxFileBytes))) 单文件上限、二进制或语言表未收录）。")
            }
            if skipLedger.skippedFileTotal > 0 {
                // 逐条原因的清账（条数 + 体积 + 行数到底统没统计），顶掉以前那句
                // 「另有 N 个条目按规则未纳入统计。」—— 那句只给一个总数，读者既不知道
                // 少在哪一类，也无从知道"行数"是没数还是数了是 0。
                // 审计模式（`countSkippedLines`）要额外读盘、预算 400 MB，产品默认不开：
                // 这一页的性能预算留给杀手功能，但**没数过就得写没数过**。
                lines.append(contentsOf: skipClearing())
            }
            if unreadableDirectoryCount > 0 {
                lines.append("\(NumberFormat.grouped(unreadableDirectoryCount)) 个目录读不动（权限不够或已消失），"
                    + "这些子树里的文件一个都没看到 —— 少掉的不是数量，是**看过的范围**。")
            }
            if filesHittingDuplicateLineCap > 0 {
                lines.append("\(NumberFormat.grouped(filesHittingDuplicateLineCap)) 个文件的重复检测只看前 2 万归一化行。")
            }
            if duplicateFragmentsDroppedByBudget > 0 || duplicateBlocksDroppedByCap > 0 {
                lines.append("重复率按全量命中计算，但明细榜单截断到 20 块、片段展开受指纹预算限制"
                    + "（本次未展开 \(NumberFormat.grouped(duplicateFragmentsDroppedByBudget)) 处拷贝、"
                    + "未列出 \(NumberFormat.grouped(duplicateBlocksDroppedByCap)) 个块 / "
                    + "\(NumberFormat.grouped(duplicateLinesOutsideReportedBlocks)) 行）。")
            }
            // R2：「配不平 / 边界不可信 / 分区退回」必须进同一本限制账，否则部分测量在屏上与全量一模一样。
            lines.append(contentsOf: lexIntegrity.limitations)
            if lexAnomalousFileCount > 0 {
                lines.append("上述词法问题分布在 \(NumberFormat.grouped(lexAnomalousFileCount)) 个文件里："
                    + "这些文件的函数条数与复杂度**只能当部分测量读**，不能读成「这个文件没有函数」。")
            }
            if unboundedFunctionSignatureCount > 0 {
                lines.append("\(NumberFormat.grouped(unboundedFunctionSignatureCount)) 处函数签名命中后"
                    + "边界推不出来（花括号配不平或未闭合），这些函数没有进入统计。")
            }
            if vueRegionFallbackFileCount > 0 {
                lines.append("\(NumberFormat.grouped(vueRegionFallbackFileCount)) 个 .vue 文件没被认出任何顶格"
                    + " SFC 区块，函数识别退回旧的 `<script` 粗判掩码 —— 这些文件的模板区可能混进了代码统计。")
            }
            return lines
        }
    }
}
