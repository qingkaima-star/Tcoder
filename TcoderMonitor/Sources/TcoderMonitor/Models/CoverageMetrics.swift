import Foundation

// MARK: - 覆盖率口径（#37）

/// 「覆盖率分母里算不算项目自己的测试代码」这件事的**唯一**判定处。
///
/// 为什么要单独拎出来：测试代码几乎必然被自己的测试覆盖到（本机实测 86.38%），
/// 把它算进分母会让总分母里约 44% 是高分样本，于是**一行生产码都不改善、
/// 只往 `Tests/` 加测试，全口径覆盖率也会自己涨**（`ee8e7b9`→`1e6319d` 实测
/// 生产码 46.84%→46.85% 几乎没动，全口径 64.00%→64.19%）。
/// 这个数字直接进健康评分，所以它必须是「生产码被覆盖多少」，不是「代码里有多少被跑过」。
///
/// 全量口径并没有丢：它作为次要字段仍然存在
/// （`CoverageReport.allLinesCovered` / `CoverageMetrics.allSourcesLinePercent`），
/// 界面与取证都能读到，只是不再参与评分。
enum CoverageScope {
    /// SwiftPM 的测试目录段。真实 lcov 给的是绝对路径，所以带斜杠匹配。
    static let testDirectoryMarker = "/Tests/"
    /// SwiftPM 测试产物里那条 `TcoderMonitorPackageTests.xctest/…` 路径。
    static let packageTestsMarker = "PackageTests"
    /// 构建中间产物里的副本，不是源码。
    static let buildDirectoryMarker = "/.build/"
    /// 约定俗成的测试文件名后缀。
    static let swiftTestFileSuffix = "Tests.swift"

    /// true = 计入评分分母。四条排除条件任一命中即算测试/派生产物。
    /// 空路径按「不确定的不算进生产码」处理：宁可少给分，也不把未知来源当生产码。
    static func isProductionSource(path: String) -> Bool {
        guard !path.isEmpty else { return false }
        if path.contains(testDirectoryMarker) { return false }
        if path.contains(packageTestsMarker) { return false }
        if path.contains(buildDirectoryMarker) { return false }
        if (path as NSString).lastPathComponent.hasSuffix(swiftTestFileSuffix) { return false }
        return true
    }
}

// MARK: - Test coverage

/// Parsed from coverage reports the repository already produces
/// (lcov, istanbul summary, JaCoCo, clover/pytest). Absence is reported as
/// `hasData == false` rather than 0%, so the UI never shows a fake score.
struct CoverageMetrics: Codable, Equatable, Sendable {
    var analyzedAt: Date = Date()
    var reports: [CoverageReport] = []
    var scannedFileCount: Int = 0
    /// 本次遍历里**读不动的目录数**（权限、悬空软链接、竞态中消失的目录）。
    ///
    /// 存在理由：目录枚举失败以前被 `try?` 吞成空数组，于是一个根本没被看过的子树
    /// 在界面上长成"这个项目没有覆盖率报告"——那是关于我们的事实，不是关于项目的。
    /// 三态必须分开：`nil` = 那次的版本没统计过这件事；`0` = 每个目录都读得动（一句真话）；
    /// `> 0` = 扫描面不完整，"没找到报告"这个结论不成立。
    /// **Optional 是落盘兼容要求**：非 Optional 带默认值会让旧报告整份解码失败。
    var unreadableDirectoryCount: Int? = nil

    // MARK: R5b · 上限与截断的显示形状（§6.1 全站同形，口径见 `docs/R5b-覆盖率身份层契约字段清单.md`）
    //
    // 以下 8 格一律 **additive + Optional**：既有成员一字未动。
    // `nil` = 那一版根本没统计过（旧报告），`0` = 统计过且结论是"没有"（一句真话），`>0` = 有东西被摘掉。
    // 三态压成两态就是本轮要修的病：**"没统计" 不等于 "没问题"**。
    // 写：`CoverageAnalyzer.analyzeWithLedger`（数值由 `CoverageDisplayShape` 一处算好抄进来）。
    // 读：`scripts/report_parity.py`（GUI↔CLI 对表）、覆盖率页页尾句（待总工接线）、
    //     `CoverageChainProofTests` / `CoverageContractFieldTests` 的恒等式断言。

    /// 命中报告份数上限（40 份）而**没能交给解析/合并**的合法报告份数。
    /// `nil` = 旧报告没统计过 ⇒「未统计是否有报告被上限丢弃」；
    /// `0` = 一份都没丢；`>0` ⇒「另有 N 份未合并」+ 逐条点名（见 `undisplayedReports`）。
    /// **不许由 `reports.count` 或份数反推**，也不许把"没量到"渲染成"没有问题"。
    var droppedByCap: Int? = nil

    /// 「这个总数可不可信」。**三态**：`nil` = 压根没给总数（缺证据 ≠ 不可信）；
    /// `false` = 给了总数但进总数的报告身份不齐 ⇒「总数不可信：N 份报告缺 <格>，已分开呈现」；
    /// `true` = 进总数的每份四格身份互证齐全。
    /// 写：`CoverageMergeConfidence.verdict`（**只看身份，不看份数**）。
    var mergeConfident: Bool? = nil

    /// §6.1 显示形状①：真实总数 = 已看到的候选 + **已点名**的超限项。
    /// 深于上限根本没下潜的部分**不在**这个数里（它进 `unmeasuredScope`），
    /// 所以这一格必须与那句"没测/测不准的范围"一起读，**单独读它是低估**。
    var truncationTotalCount: Int? = nil

    /// §6.1 显示形状②：真正交给解析/合并的份数（与 `scannedFileCount` 同源，守卫钉着）。
    var displayedCount: Int? = nil

    /// §6.1 显示形状③：`max(0, truncationTotalCount - displayedCount)`，
    /// 逐条坐标在 `undisplayedReports`（文件）与 `unexaminedDirectories`（目录）。
    var undisplayedCount: Int? = nil

    /// §6.1 坐标①：超限没交给合并的**报告文件**，相对被扫根、稳定序（可点名、可 diff）。
    /// 一行摘要不算台账 ⇒ 这一格必须逐条给路径。
    var undisplayedReports: [String]? = nil

    /// §6.1 坐标②：因深度上限或份数上限**没下潜**的目录，相对被扫根、稳定序。
    /// 只给路径不给原因：原因与计数在 `unmeasuredScope` 那句里。
    var unexaminedDirectories: [String]? = nil

    /// §6.1 那句话：人话 + 计数（「N 个目录深于 6 层没看、M 个目录读不动…」）。
    /// **这一格非空时，"该项目没有覆盖率报告"这句话不成立**（有用例钉着）。
    var unmeasuredScope: String? = nil

    /// 「有可用于评分的覆盖率数据」。
    /// 一份只统计到测试代码的报告**不算有数据**——否则全测试码的报告会以
    /// 一个没有生产码含义的百分比混进评分。
    var hasData: Bool { reports.contains { $0.linesTotal > 0 } }

    var unit: CoverageReport? { reports.first { $0.kind == .unit } }
    var integration: CoverageReport? { reports.first { $0.kind == .integration } }

    /// **计分口径**：跨报告加权的生产码行覆盖率（`linesTotal == 0` 的报告不进分母）。
    /// 名字保留 `overall` 是为了不牵动 WS-C 名下的 `WeightedHealthScorer`——
    /// 它读的就是这个属性，于是评分自动跟着口径走，而不需要那边配合改代码。
    /// 全口径请看 `allSourcesLinePercent`。
    var overallLinePercent: Double? {
        let scored = reports.filter { $0.linesTotal > 0 }
        guard !scored.isEmpty else { return nil }
        let total = scored.reduce(0) { $0 + $1.linesTotal }
        guard total > 0 else { return nil }
        let covered = scored.reduce(0) { $0 + $1.linesCovered }
        return Double(covered) / Double(total) * 100
    }

    /// **全口径**（含测试代码等一切被统计到的文件），只作次要读数与取证，不参与评分。
    /// 报告没有文件粒度时它等于 `overallLinePercent`。
    var allSourcesLinePercent: Double? {
        let withAll = reports.filter { ($0.allLinesTotal ?? 0) > 0 }
        guard !withAll.isEmpty else { return overallLinePercent }
        let total = withAll.reduce(0) { $0 + ($1.allLinesTotal ?? 0) }
        let covered = withAll.reduce(0) { $0 + ($1.allLinesCovered ?? 0) }
        guard total > 0 else { return nil }
        return Double(covered) / Double(total) * 100
    }

    /// 至少有一份报告能按源文件区分口径。假 = 生产码数字其实等同全量，界面必须说明。
    var scopeIsSeparated: Bool { reports.contains { $0.isScopeSeparated } }

    /// 「这些读数有多新（或多旧）」的一句总说明，多份报告时按**最旧**那份说。
    ///
    /// 口径：加权总分是把几份报告合起来算的，所以它的新鲜度只能等于最陈旧那份的新鲜度；
    /// 说成"最新的那份"就是拿好消息骗人。没有生成时间的报告**单独计数**（失败面往大报），
    /// 一份都没有时间时整句退化成「未知生成时间」，而不是干脆不显示。
    var generationSummaryText: String? {
        guard reports.isEmpty == false else { return nil }
        let dated = reports.compactMap { $0.generatedAt }
        let undated = reports.count - dated.count

        var text: String
        if let oldest = dated.min() {
            text = "最旧报告生成于 \(DateFormat.full.string(from: oldest))（\(DateFormat.sinceDescription(oldest))）"
        } else {
            text = "报告为未知生成时间（不按新鲜数据计）"
        }
        if undated > 0 && dated.isEmpty == false {
            text += "，另 \(undated) 份无生成时间"
        }
        if reports.count > 1 {
            text += "·共 \(reports.count) 份"
        }
        return text
    }

    var overallBranchPercent: Double? {
        let scored = reports.filter { $0.branchesTotal != nil && ($0.branchesTotal ?? 0) > 0 }
        guard !scored.isEmpty else { return nil }
        let total = scored.reduce(0) { $0 + ($1.branchesTotal ?? 0) }
        let covered = scored.reduce(0) { $0 + $1.branchesCovered }
        guard total > 0 else { return nil }
        return Double(covered) / Double(total) * 100
    }

    var riskLevel: RiskLevel {
        guard let line = overallLinePercent else { return .none }
        switch line {
        case 80...: return .none
        case 60..<80: return .low
        case 40..<60: return .medium
        default: return .high
        }
    }
}

struct CoverageReport: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case unit = "单元测试"
        case integration = "集成测试"
        case combined = "整体"
        case unknown = "未区分"
    }

    /// 这份报告能不能按源文件区分口径。
    enum ScopeGranularity: String, Codable, Sendable {
        case perSourceFile = "按源文件区分"
        case aggregateOnly = "只有汇总粒度"
    }

    var path: String
    var kind: Kind
    var toolName: String
    /// **计分口径**：生产码。`scopeGranularity == .aggregateOnly` 时它等同全量。
    var linesCovered: Int
    var linesTotal: Int
    var branchesCovered: Int
    var branchesTotal: Int?
    var methodsCovered: Int
    var methodsTotal: Int

    /// 次要字段：全口径（含测试代码）。
    /// **一律 Optional**——`ProjectReport` 会经 `ProjectStore` 落盘，
    /// 给旧 JSON 加非 Optional 键会让整份报告解码失败（`ProjectStoreRoundTripTests` 钉着这条）。
    var allLinesCovered: Int?
    var allLinesTotal: Int?
    var allBranchesCovered: Int?
    var allBranchesTotal: Int?
    var scopeGranularity: ScopeGranularity?

    /// 这份报告**是什么时候生成的**（取自报告文件自身的 mtime）。
    ///
    /// 为什么必须有：覆盖率产物是仓库自己生成的本地文件（`.gitignore` 挡着、没有 git 历史），
    /// 一份几天前的 lcov 与一份刚刚跑出来的 lcov 在界面上长得一模一样，
    /// 于是陈旧数据可以长期冒充新鲜结论进健康评分（#38，与内置快照的 #25 同族）。
    ///
    /// **必须 Optional**：同上面那批字段一条理由。拿不到时间时是「未知」，
    /// 由 `generationText` 明说，绝不当成新鲜。
    /// 与 #35 的分别：这里的时分级的是文件系统真实记录的分钟，不是我们替用户编的精度。
    var generatedAt: Date?

    // MARK: R5b · 报告身份四格 + 运行证据档（additive，口径见 `docs/R5b-覆盖率身份层契约字段清单.md` §1）
    //
    // 为什么必须有：合并后**只剩一个百分比**，读的人无法知道分母是不是同一份源码、
    // 有没有被上限丢掉、两份是不是同一次测试运行的两种落法。R5 把四类身份的**计算**建好了，
    // 但身份只活在内存里的派生类型上 ⇒ **没落盘 = 上不了屏 = 换个人读不到**。
    // 这五格就是"落盘那半"。写：`CoverageAnalyzer.parse` 建好、`CoverageMergePlanner` 结算 runKey 后盖章。
    // 读：去重判定（`CoverageRunIdentity`）、覆盖率页"来源"标签（待总工接线）、`report_parity.py`。
    // 一律 Optional：**旧报告里根本没有这一格 ⇒ 必须是 nil，不能补 `""` 或 `0`**。

    /// 格式身份的**键**（`CoverageReportFormat.rawValue`，如 `lcov` / `istanbulSummary` / `unrecognized`）。
    /// 与 `toolName`（中文展示名、两张表）不是一回事：**键不许拿去给人看，展示名不许拿去判身份**。
    /// `nil` = 旧报告没记过这一格 ⇒「格式未记录（旧报告，不声称与任何一份同源）」；
    /// `"unrecognized"` = 文件名在候选清单里但认不出格式 ⇒「认不出格式，不与任何报告合并」。
    /// **两者不是同一件事，不许都渲染成 nil。**
    var format: String?

    /// 运行身份键（"同一次运行"的分组键）。写：`CoverageRunIdentity.assignRunKeys`
    /// （证据 = 同目录共位 + 正文互证），由规划器结算后盖到报告上。
    /// `nil` = 认不出 ⇒ 该报告**不参与任何去重**（宁可留重复，也不许凭猜合并掉证据）。
    var runKey: String?

    /// 模块键：报告相对被扫根、剥掉"产物目录段"后剩下的相对目录（`""` = 仓库根）。
    /// `nil` = 相对形状切不出来（报告在被扫目录之外）⇒「模块未知（报告在被扫目录之外）」。
    /// **不许把绝对路径原样当模块键**（换机器就换键，本轮实测踩过 `/var` ↔ `/private/var`）。
    var moduleKey: String?

    /// 源码身份：**本次扫描时**被扫仓库的提交指纹（`git rev-parse HEAD` 短哈希，读不到 ⇒ `nil`）。
    ///
    /// ⚠️ 边界写死（两层绑定不许混）：这一格说的是"我扫的时候源码在 X"，
    /// **不是**"这份产物产自 X"。覆盖率产物侧压根没有写着它测哪个提交的格子，
    /// 所以 `mtime ≥ X 的时刻` 只能支持"未见更早证据"，**绝不允许**渲染成"绑定在该提交上"。
    /// 报告自报的提交号（若某天真能解析出来）是**另一格**，不许拿这一格回填它。
    /// `nil` ⇒「未绑定提交（非 git 或 git 读失败），不按新鲜数据声称」。
    var sourceFingerprint: String?

    /// `sourceFingerprint` 这个提交号**是从哪个仓库读到的**，相对被扫根的坐标：
    /// `"."` = 被扫目录自己就是仓库根；`".."` / `"../.."` = 提交身份来自**父链上那个更大的仓库**。
    /// 为什么必须有这一格（派单外新增，理由写进汇报）：`CoverageSourceState` 会沿父链找 `.git`
    /// （用户扫"某个仓库的子目录"时这是对的），于是外层仓库的 HEAD 可以冒充"这个项目自己的提交"
    /// —— 本仓 §25 已经把这条形状命名为缺陷。没有这一格，`sourceFingerprint` 单独读就是一句假话。
    /// `nil` = 压根没读到仓库（与 `sourceFingerprint == nil` 同因）。
    var sourceRepository: String?

    /// `runKey` **凭的是哪条证据**（`CoverageRunEvidence.rawValue`）。
    /// 只有键没有"凭什么"，读的人无法分辨"同一次运行的对偶落法"与"恰好放进同一个目录"，
    /// 后者不足以声称同源 ⇒ 键相同而证据不足时**不去重**。`nil` = 旧报告没记过 / 压根没键。
    var runEvidence: String?

    /// 面向用户的一句「这份报告是哪生成的」。未知就直说未知，不挤出时间、也不说"最新"。
    var generationText: String {
        guard let generatedAt else { return "报告为未知生成时间（不按新鲜数据计）" }
        return "报告生成于 \(DateFormat.full.string(from: generatedAt))（\(DateFormat.sinceDescription(generatedAt))）"
    }

    var id: String { path }

    var isScopeSeparated: Bool { scopeGranularity == .perSourceFile }

    var linePercent: Double {
        linesTotal == 0 ? 0 : Double(linesCovered) / Double(linesTotal) * 100
    }
    var branchPercent: Double? {
        guard let total = branchesTotal, total > 0 else { return nil }
        return Double(branchesCovered) / Double(total) * 100
    }
    /// 全口径行覆盖率，仅用于展示与取证。分母为 0 时返回 nil 而不是 0%。
    var allLinePercent: Double? {
        guard let total = allLinesTotal, total > 0 else { return nil }
        return Double(allLinesCovered ?? 0) / Double(total) * 100
    }
}
