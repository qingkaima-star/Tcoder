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
        var samples: [String] = []

        var byteDescription: String { ByteFormat.string(UInt64(max(0, bytes))) }
    }

    var buckets: [SourceSkipReason: Bucket] = [:]
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

    mutating func recordAuditedLines(_ reason: SourceSkipReason, lines: Int, bytes: Int64) {
        buckets[reason, default: Bucket()].lines += lines
        auditedBytes += bytes
    }

    func entries() -> [(reason: SourceSkipReason, bucket: Bucket)] {
        buckets.sorted { lhs, rhs in
            if lhs.value.files != rhs.value.files { return lhs.value.files > rhs.value.files }
            return lhs.key.rawValue < rhs.key.rawValue
        }.map { ($0.key, $0.value) }
    }
}
