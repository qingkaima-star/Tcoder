import Foundation

// OWNER: Workstream A (静态代码分析). 剔除台账的数据类型；判定与记账点在 SourceFileClassifier.swift。
//
// 从 SourceFileClassifier.swift 拆出来只有一个原因：这个工作流自己定的红线是
// 「800 行以上的文件不得增加」（SelfScanDogfoodTests），台账类型留在扫描器里会把
// SourceFileClassifier.swift 顶到 925 行。拆开也确实是两件事：一边是遍历判定，一边是记账格式。

/// 剔除原因。每条都必须对应扫描循环里一个真实判定分支，禁止出现「其他」这类兜底枚举 ——
/// 否则台账又变回一个解释不了的总数。
///
/// 注意 `hiddenEntry` 在审计模式下也**不会**被读内容：隐藏项里常有 `.env`、密钥之类，
/// 数行数的收益远不值得把它们读进内存，台账只记条数与字节。
enum SourceSkipReason: String, Sendable, CaseIterable {
    case symbolicLink                 // 文件/目录软链接：刻意不跟随（不逃逸、不死循环）
    case hiddenEntry                  // 以 `.` 开头且 includeHidden = false
    case skippedDirectory             // 命中 skipDirectories 的目录本身（子树随之剔除，是「根因」那一条）
    case excludedDirectoryNested      // 已剔除目录之下的子目录（根因已记在父目录，避免重复归因）
    case excludedDirectoryContent     // 已剔除目录之下的文件（仅审计模式才会逐个见到）
    case notARegularFile              // 设备文件、FIFO 等
    case missingExtension             // 无后缀：LICENSE、README、Makefile
    case binaryExtension              // ScanOptions.binaryExtensions
    case unsupportedExtension         // 语言目录表里没有的后缀（.cmake / .bazel / .txt …）
    case oversize                     // 超过 ScanOptions.maxFileBytes
    case unreadable                   // 读不出内容（权限、IO 错误、非目录）
    case prunedPackageDir             // `.app` / `.dSYM` 等包状目录本身：枚举器交出目录但不再进入其内容
    case prunedPackageContents        // 包状目录内部的文件（仅审计模式展开归因）
    case prunedHiddenContents         // 隐藏目录内部的文件（仅审计模式展开；只记条数与字节，绝不读内容）
    case beyondFileCap                // 达到 maxFiles 之后未处理的部分（数量未知，只标记发生过）
}

extension SourceSkipReason {
    /// 这一类条目的行数到底数没数过：目录本身、符号链接、隐藏项、读不出内容的，
    /// 一律 false —— 它们显示「0 行」就是把「没数」当成「没有」，正是本工作流反对的那类过头宣称。
    var linesAreCountable: Bool {
        switch self {
        case .excludedDirectoryContent, .missingExtension, .binaryExtension,
             .unsupportedExtension, .oversize, .prunedPackageContents:
            return true
        case .symbolicLink, .hiddenEntry, .skippedDirectory, .excludedDirectoryNested,
             .notARegularFile, .unreadable, .prunedPackageDir, .prunedHiddenContents,
             .beyondFileCap:
            return false
        }
    }

    /// 展示用中文名。放在类型扩展里而不是散在渲染代码里，保证台账与 UI 用同一套说法。
    var displayName: String {
        switch self {
        case .symbolicLink: return "符号链接（刻意不跟随）"
        case .hiddenEntry: return "隐藏条目"
        case .skippedDirectory: return "命中的排除目录"
        case .excludedDirectoryNested: return "排除目录之下的子目录"
        case .excludedDirectoryContent: return "排除目录里的文件"
        case .notARegularFile: return "非常规文件（设备/FIFO）"
        case .missingExtension: return "无后缀文件"
        case .binaryExtension: return "二进制后缀"
        case .unsupportedExtension: return "语言表未收录的后缀"
        case .oversize: return "超过单文件体积上限"
        case .unreadable: return "读不出内容"
        case .prunedPackageDir: return "包状目录（不进入其内容）"
        case .prunedPackageContents: return "包状目录里的文件"
        case .prunedHiddenContents: return "隐藏目录里的文件"
        case .beyondFileCap: return "达到文件上限后未处理"
        }
    }
}

/// 剔除台账：产品要能回答「总数为什么比 `find` 少」，取证要能回答「少掉的那 5 万行去哪了」。
/// 默认（`auditLineBudget == 0`）只记条数与字节数，字节数来自枚举器已预取的 `fileSizeKey`，
/// **不额外读文件**，因此对扫描耗时零影响。审计模式下才会读出被剔除文件的真实行数，
/// 受 `auditLineBudget` 字节预算约束，超预算时 `linesBudgetExhausted` 如实置位。
struct SourceSkipLedger: Sendable {
    struct Bucket: Sendable {
        var files: Int = 0
        var bytes: Int64 = 0
        /// 仅审计模式填充；非审计模式恒为 0，UI 不得当成真实行数展示。
        var lines: Int = 0
        /// 命中的具体规则项：目录名、后缀、超限阈值等 → 次数。
        var rules: [String: Int] = [:]
        /// 审计模式下按根因（如被剔除的顶层目录名）累计的行数，回答「vendor/ 丢了多少行」。
        var lineRules: [String: Int] = [:]
        var samples: [String] = []

        var byteDescription: String { ByteFormat.string(UInt64(max(0, bytes))) }
    }

    var buckets: [SourceSkipReason: Bucket] = [:]
    /// 本次扫描是否真的把被剔除条目的行数数过（审计模式）。false 时 `Bucket.lines` 恒为 0，
    /// 展示层必须写「行数未统计」而不是 0 —— 又一次「缺数据当零」不能发生在台账自己身上。
    var linesCounted = false
    var linesBudgetExhausted = false
    var auditedBytes: Int64 = 0
    /// 达到 maxFiles 后是否确实还有候选文件未处理（与 `truncatedByMaxFiles` 同义，供台账自洽检查）。
    var cappedRemaining = false

    static let sampleLimit = 5
    /// 审计模式的默认字节预算：400MB。够把 Homebrew 这类仓库里被剔除的源码全部数一遍行数，
    /// 又不至于在大仓上把磁盘读满。
    static let defaultAuditBudget: Int64 = 400 * 1_000 * 1_000

    var skippedFileTotal: Int { buckets.values.map(\.files).reduce(0, +) }
    var skippedByteTotal: Int64 { buckets.values.map(\.bytes).reduce(0, +) }

    /// 审计模式还剩多少字节预算可用来数行数。
    func remainingAuditBytes(within budget: Int64) -> Int64 { max(0, budget - auditedBytes) }
    var skippedLineTotal: Int { buckets.values.map(\.lines).reduce(0, +) }

    mutating func record(_ reason: SourceSkipReason, path: String, bytes: Int64, rule: String?) {
        var bucket = buckets[reason] ?? Bucket()
        bucket.files += 1
        bucket.bytes += max(0, bytes)
        if let rule { bucket.rules[rule, default: 0] += 1 }
        if bucket.samples.count < Self.sampleLimit { bucket.samples.append(path) }
        buckets[reason] = bucket
    }

    mutating func recordAuditedLines(_ reason: SourceSkipReason, lines: Int, bytes: Int64, anchor: String? = nil) {
        buckets[reason, default: Bucket()].lines += lines
        if let anchor { buckets[reason, default: Bucket()].lineRules[anchor, default: 0] += lines }
        auditedBytes += bytes
    }

    /// 行数最多的前几个根因，形如 `vendor=352784`。
    func topLineRules(_ reason: SourceSkipReason, limit: Int = 6) -> String {
        let rules = buckets[reason]?.lineRules ?? [:]
        return rules.sorted(by: Self.byCountThenName).prefix(limit)
            .map { "\(String($0.key.prefix(22)))=\($0.value)" }.joined(separator: " ")
    }

    /// 计数降序、**计数相同按名字升序**；本文件三处渲染共用这一把尺子。
    ///
    /// 那半句「按名字升序」才是重点：这三处排完的清单会**直接进 `scanLimitations` 的散文**，
    /// 而只按计数排时，计数相同的条目（全部 ×1 是常态）相对次序由 `Dictionary` 的遍历序决定。
    /// 后果是「同一个总体、同一台机器，跑两次得到两句不一样的话」——
    /// RD-54 就是拿真 GUI 落盘与真 CLI 落盘对表时抓出来的：
    /// 「命中：.gitignore ×2、.build ×1、.git ×1」对上「…、.git ×1、.build ×1」判 4 处不等。
    /// 散文不可复现，逐字段对表就永远有假红/假绿的空间。
    static func byCountThenName(_ lhs: (key: String, value: Int),
                                _ rhs: (key: String, value: Int)) -> Bool {
        if lhs.value != rhs.value { return lhs.value > rhs.value }
        return lhs.key < rhs.key
    }


    /// 把台账渲染成可直接展示的清账：一行一条原因，带文件数、行数、体积与行数最高的几个根因。
    /// `auditLineBudget == 0`（产品默认路径）时行数恒为 0，此时如实写「行数未统计」，
    /// 绝不把 0 当成「这些条目没有行」——那又是一次「缺数据当零」。
    func clearing(topRootCauses: Int = 4, linesCounted: Bool) -> [String] {
        entries().map { reason, bucket in
            var line = "\(reason.displayName) · \(NumberFormat.grouped(bucket.files)) 个条目"
            if linesCounted, reason.linesAreCountable {
                line += " · \(NumberFormat.grouped(bucket.lines)) 行"
            } else if reason.linesAreCountable {
                line += " · 行数未统计"
            } else if case .prunedHiddenContents = reason {
                line += " · 行数不统计（隐藏项刻意不读内容）"
            } else {
                line += " · 行数不适用（不是被读的文件）"
            }
            if bucket.bytes > 0 { line += " · \(bucket.byteDescription)" }
            if linesCounted, reason.linesAreCountable, !bucket.lineRules.isEmpty {
                let causes = bucket.lineRules.sorted(by: Self.byCountThenName).prefix(topRootCauses)
                    .map { "\($0.key) \(NumberFormat.grouped($0.value)) 行" }
                    .joined(separator: "、")
                line += "；按根因：\(causes)"
            } else if bucket.rules.isEmpty == false {
                let causes = bucket.rules.sorted(by: Self.byCountThenName).prefix(topRootCauses)
                    .map { "\($0.key) ×\($0.value)" }.joined(separator: "、")
                line += "；命中：\(causes)"
            }
            return line
        }
    }

    func entries() -> [(reason: SourceSkipReason, bucket: Bucket)] {
        buckets.sorted { lhs, rhs in
            if lhs.value.files != rhs.value.files { return lhs.value.files > rhs.value.files }
            return lhs.key.rawValue < rhs.key.rawValue
        }.map { ($0.key, $0.value) }
    }
}
