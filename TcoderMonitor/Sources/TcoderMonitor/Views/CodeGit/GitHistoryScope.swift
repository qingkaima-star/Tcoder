import Foundation

// MARK: - Git 提交口径（WS-L 诚实性修正）
//
// 背景（WS-J 实测，结论钉在 `SelfScanDogfoodTests.testRepositoryDoesNotGrowMoreHugeFiles`
// 之前的那条 Git 自检门里）：
//
// * `GitInsights.totalCommits` = `git rev-list --count HEAD`，**含合并提交**。
// * `GitInsights.commitsAnalyzed` = `git log --no-merges -n <窗口上限>` 真正解析到的条数，
//   **不含合并**。作者表、增删行、时段分布一律以它为准。
// * `GitInsights.historyTruncated` = `commitsAnalyzed < totalCommits`，
//   比的是两个不同口径，于是**只要仓库历史里有过一次合并，这个旗标就永远为真**。
//
// 用户看得见的问题：页头写「总提交数 62」，下面的作者表求和是 48，页面从不解释差 14 是什么。
// 本文件把两个口径拆开并写进界面。合并数能算成精确值的前提是**窗口没被打满**
// （`commitsAnalyzed < 窗口上限` 说明非合并历史已全部读完，剩下的差额只可能是合并）；
// 窗口打满时（Homebrew 实测 total 50,666 / 窗口 20,000）差额里混着没读到的更早历史，
// 只能如实说"窗口内"，不许把它报成合并数。
//
// 不改 `Models/**` 与 `Services/**`：全部由现有字段派生。

struct GitHistoryScope: Equatable {
    /// 仓库真值，含合并。
    let totalCommits: Int
    /// 实际解析到的非合并提交数——作者与代码行统计的分母。
    let nonMergeCommitsAnalysed: Int
    /// `git log -n` 的窗口上限。
    let windowLimit: Int

    /// 差额能归因到哪一处。
    enum Basis: Equatable {
        /// 窗口未打满：非合并历史已完整解析，差额**全部**是合并提交。
        case complete(mergeCount: Int)
        /// 窗口打满：差额 = 合并 + 未读到的更早历史，现有字段拆不开。
        case windowCapped
        /// 旧报告里没有 `commitsAnalyzed`（缺字段=0）而总数大于 0：口径未知。
        case unknown
    }

    init(totalCommits: Int, nonMergeCommitsAnalysed: Int, windowLimit: Int) {
        self.totalCommits = max(0, totalCommits)
        self.nonMergeCommitsAnalysed = max(0, nonMergeCommitsAnalysed)
        self.windowLimit = max(1, windowLimit)
    }

    init(_ git: GitInsights, windowLimit: Int = ShellGitAnalyzer.maxCommits) {
        self.init(totalCommits: git.totalCommits,
                  nonMergeCommitsAnalysed: git.commitsAnalyzed,
                  windowLimit: windowLimit)
    }

    var basis: Basis {
        guard totalCommits > 0 else { return .complete(mergeCount: 0) }
        guard nonMergeCommitsAnalysed > 0 else { return .unknown }
        guard nonMergeCommitsAnalysed < windowLimit else { return .windowCapped }
        return .complete(mergeCount: max(0, totalCommits - nonMergeCommitsAnalysed))
    }

    /// 精确合并数；窗口打满或旧数据口径未知时为 nil——宁可不写，也不写一个算不准的数。
    var mergeCount: Int? {
        if case .complete(let merges) = basis { return merges }
        return nil
    }

    /// 是否真的发生了窗口截断。**不等于** `GitInsights.historyTruncated`：
    /// 那个旗标被合并提交污染，只在有合并历史的仓库上恒真。
    var isWindowTruncated: Bool { basis == .windowCapped }

    /// 作者与代码行统计的分母。口径未知时退回旧行为（含合并总数），并在文案里说明。
    var authorBasis: Int { nonMergeCommitsAnalysed > 0 ? nonMergeCommitsAnalysed : totalCommits }

    /// 差额是否只是"没算合并"，而不是"没读全历史"。
    var mergesExplainTheGap: Bool {
        guard let mergeCount else { return false }
        return mergeCount > 0
    }

    // MARK: 文案

    /// 页面上那行必须让用户自己也能对上账的主口径句。
    var headline: String {
        let total = "共 \(NumberFormat.grouped(totalCommits)) 次提交"
        switch basis {
        case .complete(let merges) where merges > 0:
            return "\(total)（含 \(NumberFormat.grouped(merges)) 次合并）· 作者与代码行统计基于 "
                + "\(NumberFormat.grouped(nonMergeCommitsAnalysed)) 次非合并提交"
        case .complete:
            return "\(total) · 历史中没有合并提交，作者与代码行统计覆盖全部 "
                + "\(NumberFormat.grouped(nonMergeCommitsAnalysed)) 次提交"
        case .windowCapped:
            return "\(total)（含合并）· 作者与代码行统计只覆盖最近 "
                + "\(NumberFormat.grouped(nonMergeCommitsAnalysed)) 次非合并提交，更早的历史未纳入"
        case .unknown:
            return "\(total)（含合并）· 这份报告没有记录非合并提交数，作者与代码行仍按旧口径统计，"
                + "重新分析后可拆分"
        }
    }

    /// 「总提交数」磁贴的副标题：先把合并交代清楚，再给节奏数字。
    var totalTileCaption: String {
        switch basis {
        case .complete(let merges) where merges > 0:
            return "含 \(NumberFormat.grouped(merges)) 次合并 · 非合并 "
                + "\(NumberFormat.grouped(nonMergeCommitsAnalysed)) 次"
        case .complete:
            return "无合并提交 · 已覆盖全部历史"
        case .windowCapped:
            return "含合并 · 非合并窗口 " + NumberFormat.grouped(nonMergeCommitsAnalysed) + " 次"
        case .unknown:
            return "旧报告未记录窗口口径"
        }
    }

    /// 「作者数」磁贴的副标题。
    func authorTileCaption(authorCount: Int) -> String {
        switch basis {
        case .windowCapped:
            return "近 \(NumberFormat.grouped(nonMergeCommitsAnalysed)) 次提交窗口内 · "
                + "\(NumberFormat.grouped(authorCount)) 人"
        case .unknown:
            return "\(NumberFormat.grouped(authorCount)) 人 · 分母口径未记录"
        case .complete(let merges):
            return "\(NumberFormat.grouped(authorCount)) 人 · 基于非合并提交"
                + (merges > 0 ? "（已排除 \(NumberFormat.grouped(merges)) 次合并）" : "")
        }
    }

    /// 图表/明细卡副标题后缀：窗口没盖住全部历史时必须挂在每张图上。
    var windowSuffix: String {
        isWindowTruncated
            ? " · 近 \(NumberFormat.grouped(nonMergeCommitsAnalysed)) 次提交窗口内"
            : ""
    }
}

extension GitInsights {
    /// 视图侧口径派生的取用入口，避免每个卡片各自拼字段。
    var commitScope: GitHistoryScope { GitHistoryScope(self) }

    /// 与占比分母同口径的人均提交占比；分母为 0 时返回 nil（不返回 0）。
    func authorShare(of author: AuthorStats) -> Double? {
        let base = commitScope.authorBasis
        guard base > 0 else { return nil }
        return Double(author.commits) / Double(base)
    }
}
