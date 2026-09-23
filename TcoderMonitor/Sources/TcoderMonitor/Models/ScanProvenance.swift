import Foundation

/// 提交号的**唯一一把缩短尺子**：凡「给人看 / 落盘的提交号」都从 `abbreviated` 出。
///
/// 为什么立在这里而不是各分析器自己 `prefix(n)`：2026-09-22 R5c 用一条对表用例抓到
/// Git 那一路走 `git rev-parse --short=7`（存 7 位）而覆盖率那一路自己 `prefix(12)`（存 12 位），
/// 于是**同一份报告里两个格子把同一个提交写成两个串** —— 读的人只会得出"两把尺子有一把是错的"。
/// 缩短宽度取 12：`--short=7` 在大仓会撞歧义（git 自己的 `--abbrev` 不够用时会长），
/// 而 40 位全长既占版面也没人逐字读。
enum CommitIdentity {
    static let abbreviatedLength = 12

    /// 传进来是全长还是已经短过都安全：只取前缀，不猜长度。
    static func abbreviated(_ sha: String) -> String {
        String(sha.prefix(abbreviatedLength))
    }
}

/// 一份报告的**来源与版本**：谁产的、用哪个版本的工具与判据、在被扫项目的哪个提交上、当时工作区干不干净。
///
/// 为什么单独立一个结构：报告里每条结论（「这个函数 CC 41」「依赖 X 有 CVE」「覆盖率 44%」）
/// 只有绑到「提交 + 工具版本 + 判据版本」才可复核。缺它时复扫一次数字变了，
/// 分不清是**代码变了**还是**尺子变了** —— 本仓这两种事故都发生过。
///
/// 落盘规矩：**量不到的一律留 nil**（外加一句原因），不许用空串、`"?"` 或 `false`
/// 冒充「量到了、而且没问题」。全部字段 Optional 是 `Models/**` 那条硬规矩：
/// 旧 JSON 缺键时解码不能整份失败。
struct ScanProvenance: Codable, Equatable, Sendable {

    /// `ProjectReport` 落盘结构的版本。改字段形状（不是新增 Optional）必须抬它。
    static let currentSchemaVersion = 1

    /// 检测规则戳。**人工维护**：改判据（阈值 / 正则 / 口径 / 归类）时与代码同批改这一行。
    ///
    /// 边界（不许假装没有）：本仓还没有「从规则表自动导出版本号」的机制，
    /// 所以这一栏只保证「抬过戳的报告能被区分」，**不保证没人漏抬**。
    /// 漏抬的后果由「同一提交复扫读数变化」那条对表兜，而不是由它自己兜。
    static let rulesVersionStamp = "2026.09-r1"

    /// 当前构建配置。CLI 的 `--version` 与报告溯源共用这一把尺子（原来在 `CLIConfig` 里，已指到这里）。
    static let buildConfiguration: String = {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }()

    /// `bundle 标识 + 版本号`。SwiftPM 直跑没有 bundle —— 明说，而不是打个 `?` 让人以为读到了。
    static var bundleIdentity: String {
        let bundle = Bundle.main
        guard let id = bundle.bundleIdentifier, !id.isEmpty else { return "未打包（SwiftPM 直跑）" }
        let version = (bundle.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        return "\(id) \(version)"
    }

    /// 「构建口径 · bundle」——报告里写这一串，是为了让「同一份代码两次量得不一样」
    /// 能被归到 release/debug 或换版上，而不是归到「分析器抽风」。
    static var toolIdentity: String { "\(buildConfiguration) · \(bundleIdentity)" }

    var schemaVersion: Int?
    var toolVersion: String?
    var rulesVersion: String?
    /// 产出入口：`cli` / `gui`。CLI↔GUI 对表要靠它分辨样本来自哪条路。
    var producedBy: String?
    /// 本次实际扫描的根目录（范围边界。Git 那路可能另有仓库根，两者都要能看见）。
    var scannedRoot: String?
    /// `.git` 真正所在。与 `scannedRoot` 不同时**必须上屏** —— 实测：扫一个非仓库子目录时，
    /// Git 那一路按「向上定位」找到了**外层仓库**的提交号，此时若不写清仓库根，
    /// 读数就会把「外层仓库的 HEAD」冒充成「被扫目录的 HEAD」（同一个仓里套着的子目录最容易撞）。
    var resolvedGitRoot: String?
    var sourceCommit: String?
    var sourceBranch: String?
    /// 扫描时工作区有没有未提交改动。nil = **没量到**（不是仓库 / git 不可用 / 探测超时）。
    var workingTreeDirty: Bool?
    /// 未提交改动条数（`git status --porcelain` 的行数）。
    var dirtyEntryCount: Int?
    /// `workingTreeDirty == nil` 的原因；量到了就留空。
    var dirtyProbeNote: String?

    init() {}

    /// 从一份已装配好的报告取来源信息。
    ///
    /// 只**读** Git 那一路已经拿到的结论，不再另起一个 `git` 进程 —— 两处各查一次
    /// 迟早会分叉（一处看到仓库根、一处看到用户选的子目录）。
    init(report: ProjectReport, scannedRoot: String, producedBy: String) {
        self.init()
        schemaVersion = Self.currentSchemaVersion
        toolVersion = Self.toolIdentity
        rulesVersion = Self.rulesVersionStamp
        self.producedBy = producedBy
        self.scannedRoot = scannedRoot
        guard let git = report.git else {
            dirtyProbeNote = "Git 那一路没有产出结果，提交号与工作区状态都无从谈起"
            return
        }
        sourceCommit = git.headSHA.isEmpty ? nil : git.headSHA
        sourceBranch = git.branch.isEmpty ? nil : git.branch
        if let root = git.resolvedRepositoryRoot, root != scannedRoot { resolvedGitRoot = root }
        workingTreeDirty = git.workingTreeDirty
        dirtyEntryCount = git.dirtyEntryCount
        if git.workingTreeDirty == nil {
            dirtyProbeNote = git.dirtyProbeNote.isEmpty ? "未做工作区探测" : git.dirtyProbeNote
        }
    }

    /// 一行式读数，供 CLI 文本与界面共用。
    ///
    /// 每一格**量不到就打「未记录」**：这一串是给人抄进证据链的，空格会被读成「没有改动」。
    var oneLineSummary: String {
        let commit = sourceCommit ?? "未记录"
        let branch = sourceBranch ?? "未记录"
        let dirty: String
        switch workingTreeDirty {
        case .none: dirty = "未量到（\(dirtyProbeNote ?? "原因未记录")）"
        case .some(true): dirty = "有未提交改动 \(dirtyEntryCount.map(String.init) ?? "?") 条"
        case .some(false): dirty = "干净"
        }
        return "提交 \(commit)（\(branch)）· 工作区 \(dirty) · 工具 \(toolVersion ?? "未记录") · 规则 \(rulesVersion ?? "未记录")"
            + relocationNote
    }

    /// 仓库根与所扫目录不一致时**必须自己说出来**：否则「外层仓库的提交号」会被读成
    /// 「被扫目录的提交号」，而后者往往根本不是仓库。相等时整段留空，不去凑一行废话。
    private var relocationNote: String {
        guard let root = resolvedGitRoot else { return "" }
        return " · 注意：提交号来自外层仓库 \(root)"
    }
}
