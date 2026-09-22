import Foundation

// OWNER: WS-R6 文件角色与扫描范围（RD-15 / 工单第二、第三件）—— 扫描范围读数与"跟不跟"台账。
//
// 这一档要回答的是三句话，而它们必须是**三个不同的读数**：
//   ① 「排除了 0 个」——遍历走完了，确实一条都没被排除；
//   ② 「没统计排除」——这一份报告压根没有范围台账（旧 JSON / 只拿到 metrics 的下游）；
//   ③ 「排除了 N 个，但 N 棵子树里面有多少文件我们不知道」——范围本身不完整。
// 把 ② 渲染成 ①、或把 ③ 写成"这个项目没有 X"，就是本文件存在的理由。
//
// 形状走 §6 的链契约：`totalCount / displayedCount / undisplayedCount / unmeasuredScope`，
// 与 `HugeFileReadoutGuardTests` 那套"分母不许读被 prefix 截过的数组"同一条纪律。

// MARK: - 三态计数

/// 「数过了」与「没数」不是一个类型。`.measured(0)` 读作"数了，是 0"；
/// `.notCounted` 读作"这一路没数" —— 两者渲染出的中文永远不同（`SourceScanScopeTests` 钉这条）。
enum SourceScopeCount: Sendable, Equatable {
    case measured(Int)
    case notCounted(reason: String)

    var measuredValue: Int? {
        if case let .measured(value) = self { return value }
        return nil
    }

    /// 带单位的读数。`unit` 由调用方给（"个条目"/"行"），因为同一个三态要复用在不同量纲上。
    func describe(unit: String) -> String {
        switch self {
        case let .measured(value): return "\(NumberFormat.grouped(value)) \(unit)"
        case let .notCounted(reason): return "未统计（\(reason)）"
        }
    }
}

// MARK: - 遍历"跟不跟"台账

/// 遍历过程中关于**树的结构**的现场计数：符号链接、嵌套版本库、包状目录、被枚举器剪掉的目录。
/// 只观察、不改判定 —— 加入它的整个目的是让"跟着 symlink 会不会重复计数"这类问题
/// 有一个数可查，而不是由 `FileManager.enumerator` 的默认行为看着办。
struct SourceTreeFollowingLedger: Sendable, Equatable {
    /// 文件软链接数（刻意不读，见 `SourceTreeScanner` 的遍历不变式）
    var symbolicLinkFileCount = 0
    /// 目录软链接数（刻意不进入；其内部文件数**未统计**）
    var symbolicLinkDirectoryCount = 0
    /// 指向不存在目标的软链接（枚举器给出的 `isSymbolicLink` 条目里，目标 stat 失败的那些）
    var danglingSymbolicLinkCount = 0
    /// 被扫根自身是否是一个版本库工作树（根下第一层有 `.git`/`.hg`/`.svn`）
    var rootRepositoryDetected = false
    /// 根之下又出现的版本库目录数（= 嵌套仓库 / submodule 的工作树数）
    var nestedRepositoryCount = 0
    /// 其中形状是 submodule 的（`.git` 是**文件**，内容写着 `gitdir: …`）
    var submoduleMarkerCount = 0
    /// 命中 `packageExtensions` 名单、按包状目录剪掉的目录数
    var listedPackageDirectoryCount = 0
    /// **名单外**却被枚举器剪掉的目录数：Foundation 的 `.skipsPackageDescendants`
    /// 判据是「这个目录像不像 bundle」（例：目录里有 `Info.plist`），与我们那份后缀名单不是一回事。
    /// 修前这一格永远是 0 而东西确实被剪了 —— `*.xcarchive` 就是这么静默消失的（RD-15 现场）。
    var unlistedPackageDirectoryCount = 0
    /// 未列名单却被剪掉的目录名样本（可点名）
    var unlistedPackageDirectoryExamples: [String] = []
    /// 达到 `maxFiles` 后进入探测模式、直接收工的位置数（其余候选文件数量未知）
    var stoppedAtFileCap = false

    static let repositoryMarkerNames: Set<String> = [".git", ".hg", ".svn", ".bzr"]
    static let exampleLimit = 6

    /// 记录一个版本库标记（`.git` 目录/文件）。**只观察**，不改变任何归类判定。
    /// `isAtScanRoot` 由调用方按「标记的父目录就是被扫根」给出。
    mutating func observeRepositoryMarker(isDirectory: Bool, isAtScanRoot: Bool) {
        if isAtScanRoot {
            rootRepositoryDetected = true
            return
        }
        nestedRepositoryCount += 1
        if isDirectory == false { submoduleMarkerCount += 1 }
    }

    mutating func observeSymbolicLink(isDirectory: Bool, targetResolvable: Bool) {
        if isDirectory { symbolicLinkDirectoryCount += 1 } else { symbolicLinkFileCount += 1 }
        if targetResolvable == false { danglingSymbolicLinkCount += 1 }
    }

    mutating func observePackageDirectory(listed: Bool, name: String) {
        if listed {
            listedPackageDirectoryCount += 1
            return
        }
        unlistedPackageDirectoryCount += 1
        if unlistedPackageDirectoryExamples.count < Self.exampleLimit {
            unlistedPackageDirectoryExamples.append(name)
        }
    }

    /// 被剪掉子树、因而**内部文件数未知**的目录总数。
    var prunedSubtreeRootCount: Int {
        symbolicLinkDirectoryCount + listedPackageDirectoryCount + unlistedPackageDirectoryCount
    }

    /// 三条"跟不跟"的口径，逐条带现场数字。零命中的那一条不出声
    /// （常驻的"我们是近似"等于噪声），但**一旦有数就必须有名字**：
    /// 只报"排除了若干目录"而不说内部有多少文件没看，就是 ③ 冒充 ①。
    var notes: [String] {
        var lines: [String] = []
        appendSymbolicLinkNote(into: &lines)
        appendRepositoryNote(into: &lines)
        appendPackageNote(into: &lines)
        return lines
    }

    private func appendSymbolicLinkNote(into lines: inout [String]) {
        let total = symbolicLinkFileCount + symbolicLinkDirectoryCount
        guard total > 0 else { return }
        var line = "符号链接 \(NumberFormat.grouped(total)) 条刻意不跟随"
            + "（文件软链接 \(symbolicLinkFileCount) · 目录软链接 \(symbolicLinkDirectoryCount)）："
            + "跟进去会让同一份源码被数两次、并且可能读到仓库之外，所以这里的 0 是**选择不看**，"
            + "不是「这个项目没有软链接引入的源码」"
        if symbolicLinkDirectoryCount > 0 {
            line += "；\(NumberFormat.grouped(symbolicLinkDirectoryCount)) 棵被链接进来的子树内部文件数未统计"
        }
        if danglingSymbolicLinkCount > 0 {
            line += "；其中 \(NumberFormat.grouped(danglingSymbolicLinkCount)) 条目标不存在（悬空）"
        }
        lines.append(line)
    }

    private func appendRepositoryNote(into lines: inout [String]) {
        guard nestedRepositoryCount > 0 || rootRepositoryDetected else { return }
        var line = "版本库边界：被扫根" + (rootRepositoryDetected ? "自身是" : "自身不是") + "一个工作树"
        if nestedRepositoryCount > 0 {
            line += "；根之下又发现 \(NumberFormat.grouped(nestedRepositoryCount)) 个仓库标记"
                + "（其中 submodule 形状 \(NumberFormat.grouped(submoduleMarkerCount)) 个）"
                + " —— **口径：它们的工作树已并入本次统计，不按子仓库另算**。"
                + "扫描器不咨询 git（不跑 `git ls-files` / 不读 `.gitmodules`），"
                + "所以既不会漏掉未跟踪源码，也不会把子仓另算一份；"
                + "要「子仓另算」必须先有 git 侧身份，那属 R10 溯源那一路。"
        }
        lines.append(line)
    }

    private func appendPackageNote(into lines: inout [String]) {
        guard listedPackageDirectoryCount > 0 || unlistedPackageDirectoryCount > 0 else { return }
        var line = "包状目录不下潜 \(NumberFormat.grouped(listedPackageDirectoryCount)) 个（按名单）"
        if unlistedPackageDirectoryCount > 0 {
            line += "、\(NumberFormat.grouped(unlistedPackageDirectoryCount)) 个（按系统 bundle 判定，"
                + "名单外：\(unlistedPackageDirectoryExamples.prefix(3).joined(separator: "、"))）"
        }
        line += "：`.lproj`/`.app`/`.framework` 这类目录里放的是资源与二进制，不是手写源码，"
            + "枚举器交出目录后就止步；**其内部文件数在审计模式之外不统计**（台账里那条 0 读作「没数」）。"
        lines.append(line)
    }
}

// MARK: - §6 形状的扫描范围读数

/// 一次扫描的范围读数：看到多少、逐条列出了多少、没列出的多少、以及**没量的范围**。
struct SourceScanScopeReadout: Sendable, Equatable {

    /// 遍历看到的条目总数（纳入 + 剔除；目录、软链接、隐藏项这些"条目"也在内）。
    var totalCount: SourceScopeCount = .notCounted(reason: "本次没有范围台账")
    /// 逐条点名到样本里的条目数（每个原因桶最多 `SourceSkipLedger.sampleLimit` 条样本）。
    var displayedCount = 0
    /// 被排除但**没有**留下路径样本的条目数 = `max(0, total - displayed)`。
    var undisplayedCount = 0
    /// 没量到 / 量不准的范围，一行一条。
    var unmeasuredScope: [String] = []
    /// 被排除条目的**行数**读数：非审计模式永远是 `.notCounted`。
    var excludedLineCount: SourceScopeCount = .notCounted(reason: "非审计模式不读被剔除文件")
    /// 排除条目里的"类"数与列出的类数（清账一行一条原因，这里对得上）。
    var reasonClassTotal = 0
    var reasonClassDisplayed = 0
    /// 被排除的条目总数（"0" 与"没数"的对照就落在这里 + `totalCount`）。
    var excludedFileTotal = 0
    /// 是否真的做过范围统计。false = 这一份报告没有台账，读什么数都不许当"没有"。
    var observed = false

    /// 没有台账时的读数（旧 JSON、只拿到 `CodeMetrics` 的下游都走这一条）。
    /// 它与"扫完了、真的 0 条排除"**必须是两个不同的值** —— 这条是本流的硬判据。
    static var notObserved: SourceScanScopeReadout { SourceScanScopeReadout() }

    static func build(ledger: SourceSkipLedger, encounteredEntryTotal: Int,
                      cappedRemaining: Bool, unreadableDirectoryCount: Int,
                      following: SourceTreeFollowingLedger) -> SourceScanScopeReadout {
        var readout = SourceScanScopeReadout()
        readout.observed = true
        readout.totalCount = .measured(encounteredEntryTotal)
        readout.displayedCount = ledger.buckets.values.map { min($0.files, SourceSkipLedger.sampleLimit) }
            .reduce(0, +)
        readout.undisplayedCount = max(0, ledger.skippedFileTotal - readout.displayedCount)
        readout.excludedLineCount = ledger.linesCounted
            ? .measured(ledger.skippedLineTotal)
            : .notCounted(reason: "产品扫描不读被剔除文件的内容，审计模式才会数")
        readout.reasonClassTotal = ledger.buckets.count
        readout.reasonClassDisplayed = ledger.buckets.count
        readout.excludedFileTotal = ledger.skippedFileTotal
        readout.unmeasuredScope = unmeasuredLines(ledger: ledger, cappedRemaining: cappedRemaining,
                                                  unreadableDirectoryCount: unreadableDirectoryCount,
                                                  following: following)
        return readout
    }

    /// 「哪些范围没量到」，逐条。返回空数组 = 真的没有未量到的范围（不是"没统计未量到的范围"）。
    static func unmeasuredLines(ledger: SourceSkipLedger, cappedRemaining: Bool,
                                unreadableDirectoryCount: Int,
                                following: SourceTreeFollowingLedger) -> [String] {
        var lines: [String] = []
        // 只收「**范围本身**没量到」的那几条。文件上限、行数没统计这些 `limitationSummary`
        // 已经逐条说过，这里重复一遍就是噪声；唯一两边都在的是「读不动的目录」——
        // 那一格必须同时进 `unmeasuredScope`，因为它是 `blocksAbsenceClaims` 的门，
        // 而不只是一句提示（见下面那段的注释）。
        let pruned = following.prunedSubtreeRootCount
        if pruned > 0 {
            lines.append("\(NumberFormat.grouped(pruned)) 棵被剪枝的目录子树内部文件数未统计"
                + "（枚举器交出目录后就止步；审计模式才会逐个进去数）。")
        }
        // 读不动的目录是**第三种**没看完：既不是"排除了"（有规则、有条数），也不是"没数行数"
        // （范围看到了、只是没读内容），而是**这一片子树根本没见过**。
        // 不把它收进来的后果很具体：`blocksAbsenceClaims` 会为假，于是「这个项目没有测试码」
        // 在一棵被权限挡住一半的树上读起来像真结论（RD-15 未知态，`SourceScopeTruthTests` 钉）。
        if unreadableDirectoryCount > 0 {
            lines.append("\(NumberFormat.grouped(unreadableDirectoryCount)) 个目录本次读不动，"
                + "其内部的文件一个都没有看到 —— 这一份是**没看完**，"
                + "不是「那些子树里没有源码」。")
        }
        if ledger.skippedFileTotal > 0 && ledger.linesCounted == false {
            lines.append("\(NumberFormat.grouped(ledger.skippedFileTotal)) 个被剔除条目的行数未统计"
                + "（产品扫描不读被剔除文件的内容，审计模式才会数）。")
        }
        return lines
    }

    /// 进入 `scanLimitations` 的两句顶格读数。`unmeasuredScope` 的逐条内容
    /// 由 `SourceSkipLedger.clearing` 那一段一起带出去，这里不重复。
    var notes: [String] {
        guard observed else {
            return ["本次没有扫描范围台账 —— 「排除了 0 个」这句话**不成立**，"
                + "成立的只有「没统计排除」（旧报告结构里没有这一栏时会走到这里）。"]
        }
        // 干净的一次扫描（什么都没排除、也没有未量准的范围）**不出声**：
        // 常驻的"范围说明"等于把噪声当诚实，也会把"一个上限都没碰到"的既有断言挤掉。
        guard undisplayedCount > 0 || excludedFileTotal > 0 || unmeasuredScope.isEmpty == false else {
            return []
        }
        var lines: [String] = ["扫描范围：遍历看到 \(totalCount.describe(unit: "个条目"))、"
            + "逐条留名的 \(NumberFormat.grouped(displayedCount)) 个、未留名 \(NumberFormat.grouped(undisplayedCount)) 个、"
            + "未量准的范围 \(NumberFormat.grouped(unmeasuredScope.count)) 条。"]
        lines.append("被剔除条目的行数：\(excludedLineCount.describe(unit: "行"))。")
        return lines
    }

    /// `unmeasuredScope` 非空时，「这个项目没有 X」这类句子必须不成立 ——
    /// 这条判据的可执行形式：任何"没有/为 0"的结论句都要先过这个门。
    var blocksAbsenceClaims: Bool { observed == false || unmeasuredScope.isEmpty == false }
}

// MARK: - 谁会被剪掉：包状目录与 bundle 判定

// 本流的判据落在 `SourceTreeScanner` 上：「这个目录为什么不下潜」必须能逐条回答，
// 而它有两把尺子 —— 我们自己的后缀名单，以及 Foundation 枚举器 `.skipsPackageDescendants`
// 那套 bundle 判定。两边都要记账，否则台账解释不掉的空白就会被读成「这里没有文件」。
// 下面三段是从 `SourceScanTrail.swift` 整块搬进来的（搬的原因只有 400 行闸门，判据一字未改）。
/// 可见性：这三段原先是 `SourceScanTrail.swift` 里的 `private`，跨文件后必须放宽到模块内可见
/// （本仓已有四处同样处理，见 `FunctionRecognition.swift` 顶部说明）。**除可见性外没有任何变化**。
extension SourceTreeScanner {
    /// 包状目录：macOS 的 bundle 后缀。`FileManager` 的 `.skipsPackageDescendants` 按这套规则剪枝，
    /// 这里必须用同一套名单，否则台账归因和枚举器实际行为不一致。
    static let packageExtensions: Set<String> = [
        "app", "framework", "bundle", "xcodeproj", "xcworkspace", "lproj", "xcassets",
        "dsym", "playbook", "kext", "component", "plugin", "pkg", "prefpane",
        "colorpicker", "imgblock", "qd", "rule", "stage", "workflow", "mdimporter",
        "qlgenerator", "sdef", "spotlightizer", "termext", "webplugin", "internetplug-in",
    ]

    func isPackageDirectory(_ name: String) -> Bool {
        Self.packageExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// 复刻 `.skipsPackageDescendants` 的现场判据：Foundation 把「目录里住着 `Info.plist`」
    /// 当成 bundle —— 交出目录本身之后就不再进入其内容。这不是本流另起一把尺子，
    /// 而是给"已经发生却没人记账"的那次剪枝补一个问得到的入口
    /// （实测 `MyApp.xcarchive/` 整棵消失、台账一个字没有；`SourceScanScopeTests`
    /// 用「该子树里的文件一个都没进统计」这条反向钉住两者一致）。
    /// 代价：每个名单外目录多一次 `fileExists`（只做元数据、绝不读内容）。
    /// **保留边界**：LaunchServices 还认别的线索（UTI / `LSUIElement` 之类），
    /// 靠那些被判成 bundle 的目录这里仍然判不出来 —— 那类留白如实记在 R6 交回汇报里。
    func enumeratorPrunesDirectory(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("Info.plist").path)
    }

    /// 台账归因键：名单内的保持原样（后缀小写），名单外被 bundle 判定剪掉的
    /// 没有后缀可指（例如只因为塞了一个 `Info.plist` 就被剪的目录），退化成目录名本身。
    func packageRuleKey(_ name: String, listed: Bool) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        if listed, ext.isEmpty == false { return ext }
        return ext.isEmpty ? name : ext
    }
}
