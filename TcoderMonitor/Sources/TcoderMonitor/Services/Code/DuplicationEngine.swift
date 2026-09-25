import Foundation

struct DuplicationResult: Sendable {
    var ratio: Double
    var duplicatedCodeLines: Int
    var totalCodeLines: Int
    var blocks: [DuplicatedBlock]

    // MARK: 覆盖度（WS-D 诚实性审计 P1 #8：预算造成的低估原先只活在源码注释里）

    /// 因每指纹片段预算（`DupLex.maxOccurrencesPerHash` / `maxRunsPerFileAndHash`）
    /// 而未展开成片段、因而不出现在 `blocks` 明细里的拷贝窗口数。ratio 已包含它们，明细没有。
    var fragmentsDroppedByBudget: Int = 0
    /// 归一化行数触到 `maxWindowedLines` 而被丢弃后半部分的文件数 —— 这些文件后半段的克隆不参与检测。
    var filesHittingLineCap: Int = 0
    /// 按行数降序截断到 `maxBlocks` 时被丢掉的克隆块数，以及它们覆盖的代码行数。
    var blocksDroppedByCap: Int = 0
    var linesOutsideReportedBlocks: Int = 0
    /// 截断**之前**按 `DuplicatedBlock.id` 去重时**被合并掉**的原始命中数（RD-85）。
    /// `id` 只由「出现文件集合 + lineCount」拼成 ⇒ 两处等长的不同克隆撞同一个 id，
    /// 撞掉的那几块既不在 `blocks` 里、也不在 `blocksDroppedByCap` 里。
    /// 守恒式：`blocks.count + blocksDroppedByCap + blocksDroppedByIdCollision == 原始命中数`。
    var blocksDroppedByIdCollision: Int = 0
    /// 上面那些**被合并掉的命中自己的坐标**（`路径:起始行`，多处用 ` + ` 连），最多取样
    /// `DuplicationScan.outsideBoardSampleLimit` 条（RD-86：只给数不给坐标 = 读的人无法反驳，
    /// 那条老账就是 RD-17 立过的）。点的是坐标而不是 `id`：它的 id 与留下那条一字不差。
    var blocksMergedAwayCoordinates: [String] = []
    /// 榜外未列块的**稳定坐标**（`DuplicatedBlock.id` = 涉及路径排序后拼接 + 行数）。
    /// RD-17 工单点名要的东西：只留一个总数 = 读的人无法反驳、也无法去核对那 181 处在哪。
    /// 顺序 = 榜单自己的排序（行数降序 → id 升序），因此同一份输入永远给出同一串。
    var blocksOutsideBoard: [String] = []

    /// 「这一格的重复率是按什么算的」——必须**这一格自己说**，不许只靠 `scanLimitations` 里
    /// 别处的一句（看重复率的人不会先翻边界列表）。两个口径的差别是真实的：
    /// `ratio` 的分子是**全量命中的并集**，`blocks` 只是按行数取前 `maxBlocks` 块的明细。
    /// **没有任何阈值在这里被改动**：`maxBlocks = 20` 与判档门限都是冻结口径。
    var boardCaliberNote: String {
        let listed = blocks.map(\.lineCount).reduce(0, +)
        var line = "重复率 \(NumberFormat.percent(ratio, precision: 1)) 的口径是**全量命中**："
            + "\(NumberFormat.grouped(duplicatedCodeLines)) 个代码行落在重复块内 / 共 "
            + "\(NumberFormat.grouped(totalCodeLines)) 代码行（并集口径，同一行被多块覆盖只算一次）。"
        line += "明细榜单只列前 \(DuplicationEngine.maxBlocks) 块（合计 \(NumberFormat.grouped(listed)) 行，"
            + "榜单行数是各块行数相加、与并集不同尺），榜外未列 \(NumberFormat.grouped(blocksDroppedByCap)) 块 / "
            + "\(NumberFormat.grouped(linesOutsideReportedBlocks)) 行。"
        line += blocksOutsideBoard.isEmpty
            ? "榜外没有剩余块。"
            // RD-61：这里原来多缀了一个「。」——上面那句已经以「行。」收尾，
            // 拼起来在屏上就是「行。。榜外坐标…」，中文排版上是一处明显的手抖。
            : Self.coordinateDisclosure(blocksOutsideBoard) + "这些块参与分子、不参与明细。"
        return line
    }

    /// 散文点名坐标的**条数预算**（RD-52 立的那个样子：散文只负责"让人看到长什么样"，全量在字段里）。
    ///
    /// 之所以要有一个名字：这条预算今天有**两个出口**（本函数的限制说明、代码页尾 RD-86 那句合并点名）。
    /// 预算写死在默认参数里时，第二个出口只能另抄一个数 —— 我 RD-86 第一版抄的是取样上限（6），
    /// 于是页尾那句被六条绝对路径撑长，正是下面那段注释里"6 条撑到 2,407 字符"的形状。
    static let proseCoordinateBudget: Int = 3

    /// 榜外坐标的**唯一**披露形状（RD-52）：散文点前 3 条样本，**全量样本落盘**。
    ///
    /// ⚠️ 我最初把这条记成「全量坐标被静默截断」，复核后不对：引擎本来就只点
    /// `DuplicationScan.outsideBoardSampleLimit` 条（现 6 条），未点名的块数在
    /// `blocksDroppedByCap` 里 —— 那不是截断。真正的缺陷是另外两件事：
    /// 同一串 id 在一份报告里**印两遍**（口径句 + 扫描边界句），
    /// 而 JSON 里**没有承接格**，读机器的人仍要解析散文（RD-48 刚消灭过的那个形状）；
    /// 每条 id 又是「绝对路径 ; 绝对路径:行数」，6 条就把一句限制说明撑到实测 2,407 字符。
    /// 现在：散文 3 条 + 明确指回字段与计数，字段给引擎那 6 条**一条不减**。
    /// 之所以敢把散文从 6 降到 3：原先它是唯一载体，降就是藏；现在全量在字段里，
    /// 散文只负责"让人一眼看到长什么样"，没有一条样本因此消失。
    static func coordinateDisclosure(_ all: [String], limit: Int = DuplicationResult.proseCoordinateBudget) -> String {
        guard all.isEmpty == false else { return "榜外没有剩余块。" }
        let named = min(all.count, limit)
        var line = "榜外坐标（点样 \(named) 条）：\(all.prefix(named).joined(separator: " ; "))"
        if all.count > named {
            line += "；另有 \(all.count - named) 条样本未写进这句"
        }
        return line + "（全部 \(all.count) 条样本见 `code.duplicateBlockCoordinatesOutsideBoard`，"
            + "榜外未列的块数见 `code.duplicatedBlocksDroppedByCap`）。"
    }

    /// 撞 id 被合并掉那一维的**披露句**（§132：这件事此前只有 GUI 页尾说得出，CLI 的
    /// `scanLimitations` 里一个字都没有 —— 数在 `duplicatedBlocksDroppedByIdCollision` 里，
    /// 散文侧沉默 ⇒ 两个出口对同一件事说不同的话）。
    ///
    /// ⚠️ 为什么不直接调用上面那把 `coordinateDisclosure`：那一句里写死了「榜外坐标」与
    /// `duplicateBlockCoordinatesOutsideBoard`／`duplicatedBlocksDroppedByCap` 两个名字，
    /// 而这一维**既不是榜外、字段也不同** —— 复用它的字符串就是说出假的坐标来源。
    /// 复用它的**形状与预算**：`proseCoordinateBudget`（散文 3 条、全量在字段里、余数出声）。
    var mergedByIdLimitationNote: String? {
        guard blocksDroppedByIdCollision > 0 else { return nil }
        var line = "另有 \(NumberFormat.grouped(blocksDroppedByIdCollision)) 处重复命中与别处合并为一条"
            + "（同一组文件、同一长度）：它们在去重后各留一条，被合并掉的原始命中不参与明细。"
        guard blocksMergedAwayCoordinates.isEmpty == false else { return line }
        let named = min(blocksMergedAwayCoordinates.count, DuplicationResult.proseCoordinateBudget)
        line += "被合并掉的样本（点样 \(named) 条）："
            + blocksMergedAwayCoordinates.prefix(named).joined(separator: " ; ")
        if blocksMergedAwayCoordinates.count > named {
            line += "；另有 \(blocksMergedAwayCoordinates.count - named) 条样本未写进这句"
        }
        return line + "（全部 \(blocksMergedAwayCoordinates.count) 条样本见 "
            + "`code.duplicateBlockCoordinatesMergedById`，合并掉的命中数见 "
            + "`code.duplicatedBlocksDroppedByIdCollision`）。"
    }
}

enum DuplicationEngine {

    static let windowSize: Int = 6

    /// 归一化后长度低于此值的行一律丢弃。**单位是 UTF-8 字节**（`DupLex.normalizeBytes` 走字节管线，
    /// 折出来的占位符全是 ASCII，所以按字节量最贴近指纹的真实成本）。
    /// 取 4 的依据：标识符已折成 `I`，4 字节刚好放过 `i = N`、`I ( I )` 这类最短有效语句，
    /// 而 `}`、`);`、`})`、`I I`（`return keep`）这些 1~3 字节样板行全部落榜。
    /// 注意：这条只是**指纹通道**的入门门槛；对外的 `normalize(_:language:)` 还额外要求
    /// ≥3 个含字母/数字的词元（见下面 `normalize` 的注释），所以 `normalize("i = N")` 是 nil。
    static let minNormalizedBytes: Int = 4

    /// 单文件参与滑窗的归一化行数上限：超长文件（生成的/打包的）会吃掉整轮预算，硬截断。
    ///
    /// 可见性说明（2026-09-20 拆分所致，**不要改回 private**）：这两条原先是 `private static let`，
    /// 滑窗与索引阶段拆到 `DuplicationScan.swift` 之后必须放宽到模块内可见。
    /// **数值一个字没动**，阈值仍以此处为准。
    static let maxWindowedLines = 20_000
    static let maxBlocks = 20

    // MARK: - Normalization

    /// 归一化一行：折叠空白、丢弃注释、数字/字符串/标识符分别换成 `N` / `S` / `I` 占位符。
    /// 返回 nil 表示该行丢弃（空行、注释行、纯标点、以及撑不起指纹的短样板行）。
    static func normalize(_ text: String, language: String) -> String? {
        guard let bytes = DupLex.normalizeBytes(text, syntax: DupLex.buildLineSyntax(language: language)) else { return nil }
        let result = String(decoding: bytes, as: UTF8.self)
        // 对外的「这一行算不算有效代码行」判据，比指纹通道更严一档：
        // 指纹通道只要行长/词元数达标（`DupLex.normalizeBytes` 末尾四条），这里再要求 ≥3 个
        // 含字母或数字的词元，`a + b`（`I + I`，2 个）与 `return totalPayable`（`I I`）
        // 因此对外为 nil。两档不一致是刻意的：把这条 3 词元规则并回指纹通道，实测
        // Homebrew 的可检出重复行从 22297 掉到 5019（-77%），召回损失远大于噪声收益。
        let informativeTokens = result.split(separator: " ").filter { token in
            token.contains { $0.isLetter || $0.isNumber }
        }.count
        return informativeTokens >= 3 ? result : nil
    }

    // MARK: - Analysis

    /// 全库重复检测。**统计口径（与 `CodeMetrics.codeLines` 对齐）：**
    /// - 分母 `totalCodeLines` = 全部文件里 `kind == .code` 的行数之和，逐行等价于
    ///   `Σ file.codeLineCount`（注释行与空行不进分母；归一化丢掉的样板行**仍算分母**，
    ///   否则「全仓库都是 `}` 和空行」会被算成 0 行代码而虚报重复率）。
    /// - 分子 `duplicatedCodeLines` = 所有命中克隆覆盖到的代码行的**并集**大小：
    ///   同一行被多个块覆盖只计一次，因此恒有 `duplicatedCodeLines <= totalCodeLines`，
    ///   且 `ratio == Double(duplicatedCodeLines) / Double(totalCodeLines)`（不做二次截断）。
    /// - 克隆**包括同一文件内部的粘贴拷贝**（同一路径、不同 `startLine` 的两个片段），
    ///   与 jscpd / PMD-CPD 的常规口径一致：文件内部复制粘贴同样是维护风险。
    /// - `blocks` 是 ratio 的**明细样本**（按 `lineCount` 降序取前 20，且只收「至少新增一行
    ///   未被覆盖的重复行」的块），ratio 统计全部命中、不受 20 上限约束，否则大仓库的
    ///   重复率会被榜单截断人为压低。
    /// - `block.lineCount` 是**归一化后的代码行数**（滑窗只吃代码行），不是源码首末行跨度：
    ///   中间夹了注释/空行时，`startLine + lineCount` 会越过克隆的真实末行。
    ///   冻结的 `DuplicatedFragment` 只有 `startLine`、没有终点行，这是契约缺口（要精确跨度得给
    ///   `DuplicatedFragment` 加 `endLine`，由总工裁决；本文件不动 Models）。
    static func analyze(_ files: [ScannedSourceFile]) -> DuplicationResult {
        // 扫描器并发分类，`files` 的到达顺序每次运行都可能不同，而这里的贪婪锚点式扫描
        // 结果依赖处理顺序（同一棵树的 ratio 会在 ±0.2% 之间抖）。先按路径规范化排序，
        // 保证同一输入永远给出同样的 ratio / 同样的榜单，也让指纹预算留下「哪几个文件」是确定的。
        let files = files.sorted { lhs, rhs in
            if lhs.relativePath != rhs.relativePath { return lhs.relativePath < rhs.relativePath }
            return lhs.url.path < rhs.url.path
        }

        let totalCodeLines = DuplicationScan.countCodeLines(files)
        // 只有一个文件时整体不参评：冻结单测把「单文件 → ratio 0」写成了验收口径
        // （`testUnrelatedFilesReportNoDuplication`），因此纯单文件项目的内部粘贴不计。
        guard files.count >= 2, totalCodeLines >= windowSize * 2 else {
            return DuplicationResult(ratio: 0, duplicatedCodeLines: 0, totalCodeLines: totalCodeLines, blocks: [])
        }

        let indexed = DuplicationScan.buildIndex(files: files, totalCodeLines: totalCodeLines)
        var scan = indexed.scan
        let ranked = DuplicationScan.rankedBlocks(DuplicationScan.collectBlocks(files: files, scan: &scan))
        let duplicatedCodeLines = DuplicationScan.duplicatedCodeLines(scan: scan)

        let ratio = totalCodeLines == 0
            ? 0
            : min(max(Double(duplicatedCodeLines) / Double(totalCodeLines), 0), 1)
        return DuplicationResult(ratio: ratio,
                                 duplicatedCodeLines: duplicatedCodeLines,
                                 totalCodeLines: totalCodeLines,
                                 blocks: ranked.blocks,
                                 fragmentsDroppedByBudget: scan.droppedFragments,
                                 filesHittingLineCap: indexed.filesHittingLineCap,
                                 blocksDroppedByCap: ranked.droppedByCap,
                                 linesOutsideReportedBlocks: ranked.linesOutsideReportedBlocks,
                                 blocksDroppedByIdCollision: ranked.droppedByIdCollision,
                                 blocksMergedAwayCoordinates: ranked.mergedAwayCoordinates,
                                 // 榜外坐标**直传** `id`：坐标在唯一生产点（`DuplicationScanState.fragmentOf`）
                                 // 已经是相对被扫根的形状，这里不再加工（RD-61 第二半，
                                 // 原先这里挂过一次 `DuplicationScan.relativeCoordinates` 补剥前缀）。
                                 blocksOutsideBoard: ranked.outsideBoardCoordinates)
    }
}
