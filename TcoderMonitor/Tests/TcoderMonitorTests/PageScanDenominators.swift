import Foundation

/// **页面扫描集的分母只许有这一份。**
///
/// 为什么要有这个文件：同一件事的个数此前被抄在四个地方
/// （`CodeGitRestyleTests` 与 `CodeGitBorderlessTests+ScannerMeta` 各一份 15，
/// `ShellBorderlessTests` 与 `ShellDesignTests` 各一份 9）。
/// 每拆一次文件就要人记起改几处，漏一处就是 9~14 例红 ——
/// 收官轮实测踩过两次（WS-X7 落地漏改"外壳那两处 8"红 9 例；
/// 本流拆分时又差点漏改 Code 那两处）。
///
/// 数值本身仍是**判据**不是常数：它钉的是"这条流名下有几个视图文件"，
/// 归属被动过就要响。改这里 = 承认归属变了，必须同时改四处的说明文案，
/// 所以文案里的分母一律插值，不再手写第二遍。
enum PageScanDenominators {
    /// WS-L / WS-P 名下 `Views/{Code,Git,Dependencies,CodeGit}` 的 `.swift` 文件数。
    /// Code 6 / Git 5 / Dependencies 5 / CodeGit 2。
    /// · 15 → 16（WS-X8）：`DependenciesView.swift` 里的 `NetworkOptionsCard` 搬成同目录分片。
    /// · 16 → 18（R3 B 组）：`DependencyVerdictRows.swift` 被拆到 429 行，按 400 口径整块搬出
    ///   `DependencyAdvisoryRows.swift`（c789b2a）；RD-13c 的六档 scope 另起
    ///   `DependencyScopeBreakdown.swift`。**改的是文件归属，不是判定阈值** ——
    ///   两笔都在 `Views/Dependencies/` 名下，页面数与"每页拥有哪些文件"的 roster
    ///   （`CodeGitRestyleTests.pageFiles`）都没动，所以只有这个总数要跟着认。
    static let codeGitPageFiles = 18

    /// 外壳层扫描集：3 个页面文件（`RootView` / `ProjectDetailView` / `DashboardView`）
    /// 加 `Views/Shell/` 下的 6 个分件。
    static let shellLayerFiles = 9

    static var codeGitRosterText: String {
        "WS-L/WS-P 名下应有 \(codeGitPageFiles) 个视图文件（Code 6 / Git 5 / Dependencies 5 / CodeGit 2）"
    }

    static var shellRosterText: String {
        "外壳应是 3 个页面文件 + Shell/ 下 \(shellLayerFiles - 3) 个分件"
    }
}
