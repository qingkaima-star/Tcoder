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

    // 检测规则戳 `rulesVersionStamp` 自 RD-81 起**不在这个文件里定义**：
    // 它取自 `ScanRulesVersion.swift` 的规则版本台账最新一格（同类型的成员，换个文件放而已）。
    // 抬戳的姿势 = 去那张表加一行，别在这里改字符串 ——
    // 「挪了戳没记账」与「记了账没挪戳」两件事都由 `ScanProvenance.rulesLedgerDefects` 判红。

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

    /// 扫描这段时间里源码动过没有（RD-31）。三态：
    /// `nil` = 没量到（原因写在 `driftNote`）、`false` = 开工与收工两枚指纹一致、`true` = 期间变了。
    ///
    /// 它与 `workingTreeDirty` **不是一回事**：那一格答的是「开工当时工作区脏不脏」，
    /// 而一份报告要五路并行跑几十秒，期间有人 `git checkout` / 编辑器保存，
    /// 落进报告的就是一批**来自不同时刻**的读数。脏工作区可以照样自始至终没动过，
    /// 干净工作区也可能在扫描中途被改（然后被 `git checkout .` 还原掉）。
    var sourceDriftDuringScan: Bool?
    /// 量不到的原因，或「变了什么」的**摘要**（只到条数/字节/路径摘要这一级）。
    ///
    /// ⚠️ 摘要里故意**不列绝对路径清单**：一份大仓报告塞进几千条路径是第二个缺陷，
    /// 而"哪几个文件动过"这件事本就不在这把尺子的能力范围内。
    /// 与 `dirtyProbeNote` 同规矩：量到了且一致 ⇒ 留空，不许编一句话凑数。
    var driftNote: String?

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
            + relocationNote + " · \(driftReading)"
    }

    /// 漂移这一句的**唯一装配口**：CLI 文本、`scan` 落盘的摘要、界面横幅三处都读它，
    /// 谁也不许自己再拼一遍（三句话各只有一份说法，是这条整改的完成标准）。
    ///
    /// 照上面 `dirty` 那个 switch 的写法：**`nil` 必须长成「未量到（原因）」**，
    /// 绝不允许被省略成"看起来没问题"；`false` 只说「两枚指纹一致」，
    /// 不说「源码没变」——这把尺子看不见等长改写（见 `SourceTreeFingerprint` 的盲区说明）。
    var driftReading: String {
        switch sourceDriftDuringScan {
        case .none:
            return localizedFormat("扫描期间源码是否变化未量到（%1$@）", driftNote ?? "原因未记录")
        case .some(true):
            return localizedFormat("扫描期间源码有变化（%1$@），本报告不是同一源码快照的一致结果",
                                   driftNote ?? "摘要未记录")
        case .some(false):
            return localizedCopy("扫描期间开工与收工两枚源码指纹一致")
        }
    }

    /// 界面上该不该出声、说什么、用哪一档颜色。**判定住在契约里**：
    /// 页面只照这一枚画，不许在 `Views/**` 里重比一次三态（那是第二把尺子）。
    ///
    /// 出声的两态：`true`（警告）与「量过而没量到」（中性，`driftNote` 在 = 这一版真的探测过）。
    /// 沉默的两态：`false`（没有问题要说，与 `relocationNote` 相等时不凑废话同规矩）、
    /// 以及**出自还没做漂移探测的旧报告**（`nil` 且没有原因：那种报告连 `provenance` 都是旧的，
    /// 凭空挂一条横幅会把"这版工具没这个能力"说成"这个项目源码有问题"）。
    /// CLI 那一行不受这条影响：三态一律照打「未量到（原因未记录）」。
    var driftNotice: DriftNotice? {
        if sourceDriftDuringScan == true { return DriftNotice(reading: driftReading, isWarning: true) }
        guard sourceDriftDuringScan == nil, driftNote != nil else { return nil }
        return DriftNotice(reading: driftReading, isWarning: false)
    }

    /// 横幅要的两件事一次给全（一句话 + 是不是警告档）。
    struct DriftNotice: Sendable, Equatable {
        var reading: String
        var isWarning: Bool
    }

    /// 收尾时比一次「开工指纹 vs 收工指纹」，把结论落进 `sourceDriftDuringScan` / `driftNote`。
    ///
    /// 两侧任意一侧没量到 ⇒ **整枚判未量到**并写清是哪一侧：
    /// 拿一枚残缺指纹去比"一致"，得到的就是一个被包装成精确结论的假绿。
    mutating func recordDrift(startingFrom start: SourceTreeFingerprint.Probe,
                              endingAt end: SourceTreeFingerprint.Probe) {
        switch (start, end) {
        case let (.measured(from), .measured(to)):
            // **两枚指纹相等 = 没漂**（`sourceDriftDuringScan == false`）。
            // 这行判据反过一次并在测试里当场红：`true` 那支必须挂"变了"，
            // 挂反了会把"改了代码"报成"快照一致"，正是本条整改反对的那类假绿。
            let consistent = from == to
            sourceDriftDuringScan = !consistent
            driftNote = consistent ? nil : SourceTreeFingerprint.driftSummary(from: from, to: to)
        case let (.notMeasured(reason), _):
            sourceDriftDuringScan = nil
            driftNote = localizedFormat("开工侧指纹没量到：%1$@", reason)
        case let (.measured, .notMeasured(reason)):
            sourceDriftDuringScan = nil
            driftNote = localizedFormat("收工侧指纹没量到：%1$@", reason)
        }
    }


    /// 仓库根与所扫目录不一致时**必须自己说出来**：否则「外层仓库的提交号」会被读成
    /// 「被扫目录的提交号」，而后者往往根本不是仓库。相等时整段留空，不去凑一行废话。
    private var relocationNote: String {
        guard let root = resolvedGitRoot else { return "" }
        return " · 注意：提交号来自外层仓库 \(root)"
    }
}

// MARK: - 扫描期间的源码指纹（RD-31）

/// 一棵源码树在某一时刻的**元数据指纹**：文件条数 + 路径集合的稳定摘要 + 字节数之和。
///
/// 为什么只有这三样，而**绝不读文件内容**：
/// - 同一棵树的指纹要在**开工前与收工后各采一次**，读内容就是把整次扫描的读盘量翻一倍，
///   而条数与字节由目录枚举器顺手交出（`URLResourceKey.fileSizeKey`），一次 stat 都不多做；
/// - 「工作区脏不脏」Git 那一路已经量了（`ScanProvenance.workingTreeDirty`）。
///   为「期间动没动」再起一个 git 进程就是第二把尺子（本文件为这件事已经立过一次规矩）；
/// - 剪枝名单**不自己抄**：走 `ScanOptions.default.skipDirectories` 与唯一的
///   `SourceSkipPlan`，相对路径走唯一的 `SourceFileClassifier.relativePath`。
///   本类型多出来的只有"再走一遍枚举器"这一步，而指纹是一件**新读数**，
///   代码扫描那一路本来就不产它（它要读内容，两件事的成本与盲区都不同）。
///
/// ⚠️ **盲区必须写在脸上**：等长改写（改一个字符又删一个字符）既不改条数也不改字节，
/// 路径集合也没动 ⇒ 判不出来。所以 `false` 那句只说「两枚指纹一致」，
/// **不许**说成「源码没变」——这正是本条整改反对的"包装成精确结论"。
///
/// 为什么住在本文件：它产出的就是 `sourceDriftDuringScan` 这一格的值，
/// 一枚读数的口径与它的承接格放在一起才不会被抄成第二份；另起文件会动普查分母（AGENTS §3 第 7 条）。
struct SourceTreeFingerprint: Sendable, Equatable {
    /// 参与指纹的常规文件条数（符号链接与被剪枝子树里的文件一律不算，与代码扫描同规则）
    var fileCount: Int
    /// 这些文件的字节数之和
    var totalBytes: Int64
    /// **路径升序**之后的稳定摘要（FNV-1a 64，十六进制）。
    ///
    /// 顺序必须确定：`FileManager` 枚举器交条目的顺序未定义，按枚举序求和就等于
    /// 让「枚举顺序」参与判定 —— 卷三 §58 结案的那条 RD-39（临时目录名字参与归类）
    /// 是同一个家族病，不犯第二次。
    var pathDigest: String

    /// 一次采样的结果。三态形状与 `ShellGitAnalyzer.workingTree(from:)` 同源：
    /// **没量到绝不允许长成"没变化"**。
    enum Probe: Sendable, Equatable {
        case measured(SourceTreeFingerprint)
        case notMeasured(reason: String)
    }
}

extension SourceTreeFingerprint {

    /// 一趟最多吃的条目数。超了就明说"没量到"，**不给一枚可能被截断的指纹**：
    /// 两侧都被削到同一个上限时，"变了"会被判成"一致"。
    static let entryBudget = 200_000

    /// 隐藏项与包状目录交给枚举器剪（与代码扫描的 `.skipsPackageDescendants` 同一档，
    /// 隐藏名单也同一条：`includeHidden == false`），被排除目录再走 `SourceSkipPlan`。
    static let enumerationOptions: FileManager.DirectoryEnumerationOptions =
        [.skipsHiddenFiles, .skipsPackageDescendants]

    /// 只问元数据，一个字节的内容都不读。
    static let resourceKeys: Set<URLResourceKey> = [
        .isRegularFileKey, .isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey,
    ]

    /// 采一枚指纹。任何"没看完"的情形一律返回 `.notMeasured(原因)`，不返回半枚指纹。
    static func probe(root: URL) -> Probe {
        guard isReadableDirectory(root) else {
            return .notMeasured(reason: "被扫根不是一个读得到的目录")
        }
        let unreadable = ScanErrorTally()          // errorHandler 是 @Sendable，碰不到局部 var
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: Array(resourceKeys),
            options: enumerationOptions,
            errorHandler: { _, _ in unreadable.addOne(); return true }
        ) else {
            return .notMeasured(reason: "根目录枚举器起不来（权限或文件系统读不动）")
        }
        var plan = SourceSkipPlan(root: root, options: .default)
        var paths: [String] = []
        var bytes: Int64 = 0
        var walked = 0
        while let url = walker.nextObject() as? URL {
            walked += 1
            if walked > entryBudget {
                return .notMeasured(reason: "树内条目超预算 \(entryBudget) 条，两侧指纹不同源、不比")
            }
            accumulate(url, root: root, plan: &plan, walker: walker, paths: &paths, bytes: &bytes)
        }
        guard unreadable.count == 0 else {
            return .notMeasured(reason: "有 \(unreadable.count) 个目录读不动，指纹不完整")
        }
        return .measured(SourceTreeFingerprint(paths: paths, totalBytes: bytes))
    }

    /// 指纹摘要：把三样测得值**逐条并排**写出来（不列绝对路径清单，见 `ScanProvenance.driftNote`）。
    ///
    /// 为什么把相等的两半也打出来：只报"变了"而不报哪个量变了，读的人无从判断
    /// 这是"多了一个文件"还是"条数字节都没动、只有路径集合动了"（= 改名/移动）。
    /// 为什么字节打**原值分组**而不是 `ByteFormat.string`：实测一次注入 20 字节的漂移，
    /// 人类可读档两侧都显示同一个 `13.8 MB` —— 那会让"字节也变了"这一支被读成"字节没变"。
    static func driftSummary(from: SourceTreeFingerprint, to: SourceTreeFingerprint) -> String {
        localizedFormat("条数 %1$@ → %2$@ · 字节 %3$@ → %4$@ · 路径摘要 %5$@ → %6$@",
                        NumberFormat.grouped(from.fileCount), NumberFormat.grouped(to.fileCount),
                        NumberFormat.grouped(Int(max(0, from.totalBytes))),
                        NumberFormat.grouped(Int(max(0, to.totalBytes))),
                        from.pathDigest, to.pathDigest)
    }

    /// 单个条目：目录只问一句"要不要剪"，文件只记相对路径与字节。
    private static func accumulate(_ url: URL, root: URL, plan: inout SourceSkipPlan,
                                   walker: FileManager.DirectoryEnumerator,
                                   paths: inout [String], bytes: inout Int64) {
        let values = try? url.resourceValues(forKeys: resourceKeys)
        if values?.isSymbolicLink == true { return }        // 与代码扫描同规则：绝不跟随
        if values?.isDirectory == true {
            if plan.consume(url) { walker.skipDescendants() }
            return
        }
        guard values?.isRegularFile == true else { return }
        paths.append(SourceFileClassifier.relativePath(for: url, root: root))
        bytes += Int64(values?.fileSize ?? 0)
    }

    private static func isReadableDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isReadableKey])
        return values?.isDirectory == true && values?.isReadable != false
    }

    /// 由「升序路径 + 字节数」造一枚指纹。排序在这里做一次，摘要与条数都取排序后的结果。
    init(paths: [String], totalBytes: Int64) {
        let sorted = paths.sorted()
        fileCount = sorted.count
        self.totalBytes = totalBytes
        pathDigest = Self.digest(ofSortedPaths: sorted)
    }

    /// FNV-1a 64：不依赖 `Hasher`（它的种子每进程随机，跨运行不可比），也不引外部依赖。
    private static func digest(ofSortedPaths paths: [String]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for path in paths {
            for byte in path.utf8 {
                hash = (hash ^ UInt64(byte)) &* 0x1000_0000_01b3
            }
            hash = (hash ^ 0x0A) &* 0x1000_0000_01b3   // 条目之间留分隔符，防止 "ab"+"c" 撞 "a"+"bc"
        }
        return String(hash, radix: 16)
    }
}

