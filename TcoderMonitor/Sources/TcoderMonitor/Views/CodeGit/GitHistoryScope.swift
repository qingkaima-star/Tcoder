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
        let total = localizedFormat("共 %1$@ 次提交", NumberFormat.grouped(totalCommits))
        switch basis {
        case .complete(let merges) where merges > 0:
            return localizedFormat("%1$@（含 %2$@ 次合并）· 作者与代码行统计基于 %3$@ 次非合并提交",
                                     String(total), NumberFormat.grouped(merges),
                                     NumberFormat.grouped(nonMergeCommitsAnalysed))
        case .complete:
            return localizedFormat("%1$@ · 历史中没有合并提交，作者与代码行统计覆盖全部 %2$@ 次提交",
                                     String(total), NumberFormat.grouped(nonMergeCommitsAnalysed))
        case .windowCapped:
            return localizedFormat("%1$@（含合并）· 作者与代码行统计只覆盖最近 %2$@ 次非合并提交，更早的历史未纳入",
                                     total, NumberFormat.grouped(nonMergeCommitsAnalysed))
        case .unknown:
            return localizedFormat("%1$@（含合并）· 这份报告没有记录非合并提交数，作者与代码行仍按旧口径统计，重新分析后可拆分",
                                     total)
        }
    }

    /// 「总提交数」磁贴的副标题：先把合并交代清楚，再给节奏数字。
    ///
    /// P53：这三个分支此前是 `"...含 \(n) 次合并 · 非合并 " + "\(m) 次"` 这种**先拼再上屏**的写法。
    /// 渲染侧确实查了表，但查的是**拼完之后**的整串 —— 串里带着测得值，
    /// 目录里没有任何键可能对得上，于是英文态永远出中文（`ax_body_audit` 的 B 类 2× 那条
    /// 「含 279 次合并 · 非合并 606 次」就是这么来的）。改成整句键 + 位置占位符。
    var totalTileCaption: String {
        switch basis {
        case .complete(let merges) where merges > 0:
            return localizedFormat("含 %1$@ 次合并 · 非合并 %2$@ 次",
                                     NumberFormat.grouped(merges),
                                     NumberFormat.grouped(nonMergeCommitsAnalysed))
        case .complete:
            return localizedCopy("无合并提交 · 已覆盖全部历史")
        case .windowCapped:
            return localizedFormat("含合并 · 非合并窗口 %1$@ 次",
                                     NumberFormat.grouped(nonMergeCommitsAnalysed))
        case .unknown:
            return localizedCopy("旧报告未记录窗口口径")
        }
    }

    /// 「作者数」磁贴的副标题。
    func authorTileCaption(authorCount: Int) -> String {
        switch basis {
        case .windowCapped:
            return localizedFormat("近 %1$@ 次提交窗口内 · %2$@ 人",
                                     NumberFormat.grouped(nonMergeCommitsAnalysed),
                                     NumberFormat.grouped(authorCount))
        case .unknown:
            return localizedFormat("%1$@ 人 · 分母口径未记录", NumberFormat.grouped(authorCount))
        case .complete(let merges):
            return localizedFormat("%1$@ 人 · 基于非合并提交%2$@",
                                     NumberFormat.grouped(authorCount),
                                     merges > 0
                                         ? localizedFormat("（已排除 %1$@ 次合并）",
                                                           NumberFormat.grouped(merges))
                                         : "")
        }
    }

    /// 图表/明细卡副标题后缀：窗口没盖住全部历史时必须挂在每张图上。
    ///
    /// P53：这里此前直出 `" · 近 \(n) 次提交窗口内"`。三个取用点里有两个把它当 `%3$@`
    /// 塞进**已经查表**的整句模板 —— 模板翻成了英文，插进去的这段仍是中文，
    /// 于是英文态同一行里两种语言并存，比纯中文更难读。后缀本身必须是一条键。
    var windowSuffix: String {
        isWindowTruncated
            ? localizedFormat(" · 近 %1$@ 次提交窗口内", NumberFormat.grouped(nonMergeCommitsAnalysed))
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

// MARK: - "没有数据"到底是哪一种没有

/// `40 WS-H` §7.3 的三态在 Git 页的落点。
///
/// 原来两处文案都写成"没有提交记录，**或** Git 分析被跳过"——把"查了是空的"和
/// "根本没查"塞进同一句话，用户只能自己猜。现在按数据在场情况三分，措辞互斥。
enum GitDataAbsence: Equatable {
    /// 该目录不是仓库（或被定位成了非仓库）：不适用，不是零。
    case notARepository
    /// 是仓库、分析也跑了，但真的一条提交都没有：这是测得的 0。
    case repositoryWithoutCommits
    /// 有提交，但一条都没解析成功（全是合并提交、或时间戳/作者字段读不出）。
    case commitsUnparsed(total: Int)
    /// 提交解析出来了，作者字段却一条都没有：作者数据缺失，不是「零贡献者」。
    case commitsWithoutAuthors(total: Int)
    /// 数据在场。
    case available

    var copy: GitAbsenceCopy? {
        switch self {
        case .notARepository:
            return GitAbsenceCopy(
                icon: .emptyUnknown,
                title: "该目录不是 Git 仓库",
                message: "分析器在所选目录及其上下若干层里都没有找到仓库根。\n这是「不适用」，不是「没有提交」——仓库在别处时请把它单独添加为项目。")
        case .repositoryWithoutCommits:
            return GitAbsenceCopy(
                icon: .noRisk,
                title: "已完成分析，这个仓库还没有提交",
                message: "0 次提交是这次测得的结果，不是没扫。\n提交一次普通改动后重新分析，这里就会出现趋势与作者。")
        case .commitsWithoutAuthors(let total):
            return GitAbsenceCopy(
                icon: .unverified,
                title: "解析到了提交，但没有作者信息",
                message: localizedFormat("本次解析到 %1$@ 次非合并提交，却没有一条带得出作者字段。\n这是作者数据缺失，不是「零贡献者」，因此排行与占比都不成立。",
                                         NumberFormat.grouped(total)))
        case .commitsUnparsed(let total):
            return GitAbsenceCopy(
                icon: .unverified,
                title: localizedFormat("有 %1$@ 次提交，但一条都没解析出来", NumberFormat.grouped(total)),
                message: "通常是历史里全部为合并提交，或提交的作者与时间戳字段读不出来。\n因此作者、提交趋势与时段分布都不成立，这里不给任何结论。")
        case .available:
            return nil
        }
    }
}

struct GitAbsenceCopy {
    let icon: IconName
    let title: String
    let message: String
}

extension GitInsights {
    /// 提交层面的在场判定：先看是不是仓库，再看有没有提交，最后看解析没解析出来。
    var commitAbsence: GitDataAbsence {
        guard isRepository else { return .notARepository }
        guard totalCommits > 0 else { return .repositoryWithoutCommits }
        guard commitsAnalyzed > 0 else { return .commitsUnparsed(total: totalCommits) }
        return .available
    }

    /// 作者层面的在场判定（贡献者页空态用它，与提交页的措辞互斥）。
    var authorAbsence: GitDataAbsence {
        let commits = commitAbsence
        guard case .available = commits else { return commits }
        return authors.isEmpty ? .commitsWithoutAuthors(total: commitsAnalyzed) : .available
    }
}
