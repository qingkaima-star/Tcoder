//
// 崩溃证据的四态、应用与构建归属、事件时间来源、去重与窗口台账（R4 日志链，RD-21~24）。
//
// 为什么单独成文件：整改前「是不是崩溃」是一个布尔（`LogEvent.isCrash`），
// 而一个布尔只能表达「是 / 不是」，表达不了「名字像但没证据」「读不动」「内容损坏」
// 这三种**知道程度不同**的状态。台账 §6.2 要的四态在这里各占一个 case，
// 并且**只有 `.confirmed` 有权增加 `crashCount`**。
//
// 纪律：
// 1. 纯逻辑、nonisolated，可在 `Task.detached` 里跑；不碰 AppState / ProjectStore。
// 2. 这里的类型**都不落盘**（`Models/**` 是冻结区）。要进报告 JSON 的形状全部登记在
//    Obsidian `110 WS-R4` 的 `## 契约缺口`，由总工落 Optional 字段后再把这里上提。
// 3. 事件时间只承认「报告里的时间字段 / 报告文件名里的时间 / 日志行内时间戳」三种来源。
//    **文件 mtime 永远不算事件时间** —— 它只用于发现候选（见 `LogDiscovery`）。
//

import Foundation

// MARK: - 四态

/// 一份崩溃候选文件的证据状态。四态互斥，且**没有第五态**：
/// 拿不准的一律往前三种走，不许为了"看起来有结论"而判成 `.confirmed`。
enum CrashEvidenceState: String, Sendable, CaseIterable {
    /// 有真实事件证据：崩溃类型 / 信号 / 线程或堆栈 / 终止原因，至少命中一类。
    case confirmed
    /// 名字或目录把它带进崩溃通道，但读成功且内容里没有任何崩溃证据。
    case suspected
    /// 内容已经损坏或不是预期格式：读到了字节，却取不出可信字段。
    case parseFailed
    /// 打不开 / 读不动（权限、文件已不存在…）。**没核对过**，与「核对过、零命中」相反。
    case readFailed

    /// 面向用户的一句话名字（中文短名，用于读数卡与脚注）。
    var label: String {
        switch self {
        case .confirmed: return "确认崩溃"
        case .suspected: return "疑似报告"
        case .parseFailed: return "解析失败"
        case .readFailed: return "读取失败"
        }
    }

    /// 这一态是否允许增加 `crashCount`（以及是否允许进扣分）。判据只有一条：有真实事件证据。
    var contributesToCrashCount: Bool { self == .confirmed }
}

// MARK: - 事件时间来源

/// 事件时间从哪来。`.unavailable` 是**必须能表达**的一档：
/// 整改前 `ipsDate` 与文本崩溃通道都会回落到文件 mtime，
/// 于是「没有时间戳的报告」被伪装成「刚刚发生的崩溃」并落进窗口计数。
enum CrashEventTimeSource: String, Sendable, CaseIterable {
    case reportField       // .ips 的 timestamp / 文本报告的 Date/Time
    case reportFileName    // Apple 报告名里的 `2026-09-21-101112`
    case logLineTimestamp  // 日志行首的时间戳
    case unavailable       // 没有任何事件时间 —— 不许用 mtime 冒充

    var isRealEventTime: Bool { self != .unavailable }
}

// MARK: - 应用与构建归属

/// 一份报告自报的「我是谁、哪个版本、什么环境、为什么终止」。
///
/// RD-23 要求归属**显式绑定**而不是靠目录名猜：这五个维度全部来自报告自身字段，
/// 缺哪一项就留 `nil`（缺失本身是要出声的信息，不是可以悄悄省略的细节）。
struct AppBuildIdentity: Sendable, Equatable {
    var processName: String?
    var bundleID: String?
    var appVersion: String?      // 原样，如 "2.0 (9)"
    var buildVersion: String?    // "2.0 (9)" 的括号内段
    var osVersion: String?       // 采集环境
    var product: String?
    var terminationReason: String?

    /// 一个身份维度都没读到 —— 这时不许说"归属本项目"，只能说"归属未知"。
    var isUnknown: Bool {
        processName == nil && bundleID == nil && appVersion == nil
    }

    /// 缺失清单（供界面写「构建归属未知：未记 app_version / bundleID」）。
    var missingFields: [String] {
        var missing: [String] = []
        if processName == nil { missing.append("进程名") }
        if bundleID == nil { missing.append("bundleID") }
        if appVersion == nil { missing.append("构建版本") }
        if terminationReason == nil { missing.append("终止原因") }
        if osVersion == nil { missing.append("采集环境") }
        return missing
    }

    /// 分组与"旧构建"判定用的键：优先完整版本串，退到构建号、再退到进程名。
    var versionKey: String? {
        if let appVersion, !appVersion.isEmpty { return appVersion }
        if let buildVersion, !buildVersion.isEmpty { return buildVersion }
        return nil
    }

    var displayText: String {
        let name = processName ?? bundleID ?? "未知进程"
        guard let version = versionKey else { return name + "（版本未知）" }
        return "\(name) \(version)"
    }
}

// MARK: - 单条记录

/// 一条崩溃证据。`.confirmed` 是**每事件**一条（一份报告可以有多次崩溃），
/// 其余三态是**每文件**一条（那一份根本没有可读的事件）。
struct CrashEvidenceRecord: Sendable, Equatable {
    var path: String
    var state: CrashEvidenceState
    /// 这一态的**原因**：读失败的的系统原因、解析失败的卡在哪一步、疑似的为什么疑似。
    var reason: String?
    var eventDate: Date?
    var eventTimeSource: CrashEventTimeSource
    var fileModifiedAt: Date
    var identity: AppBuildIdentity
    var signature: String?
    var incidentID: String?
    var lineNumber: Int = 0
    /// 被并掉的那一份留下的「并进了谁」（只在 `duplicates` 里有值）。
    var duplicateOf: String? = nil

    /// 去重键。三级：incident id（同一事件的多份报告必然同 id）→ 签名 + 事件时间
    /// → **都没有就不去重**（宁可重复也不误并两个真事件）。
    var dedupKey: String? {
        if let incident = incidentID?.trimmingCharacters(in: .whitespacesAndNewlines),
           incident.isEmpty == false {
            return "incident:" + incident.lowercased()
        }
        guard let signature, signature.isEmpty == false, let eventDate else { return nil }
        // 同一签名 + 同一秒 + 同一进程 = 同一次崩溃的另一份报告
        return "sig:\(signature)@\(Int(eventDate.timeIntervalSince1970))@\(identity.processName ?? "")"
    }

    var hasEventTime: Bool { eventTimeSource.isRealEventTime && eventDate != nil }

    /// 同键之内被并掉的那一份：记下它并进了谁，路径仍然留着（可追溯）。
    func markingDuplicateOf(_ keeperPath: String) -> CrashEvidenceRecord {
        var copy = self
        copy.duplicateOf = keeperPath
        return copy
    }
}

// MARK: - 台账

/// 崩溃证据台账：四态各自的计数、去重结果、窗口与构建归属的切分。
///
/// 它同时回答三个问题，而且三者不许互相借用数字：
/// ① **测到了什么**（计数）；② **凭什么算进扣分**（`countablePaths`）；
/// ③ **哪些是没测准的部分**（`unknownStatement`）。
struct CrashEvidenceLedger: Sendable, Equatable {
    /// 去重后保留的记录，按（状态、事件时间倒序、路径）稳定排序。
    var records: [CrashEvidenceRecord] = []
    /// 被并掉的重复记录（同一事件的另一份报告），各自带着它自己的路径。
    var duplicates: [CrashEvidenceRecord] = []
    var windowCutoff: Date?

    // MARK: 构造

    /// 去重 + 排序 + 归类。纯函数，输入顺序不影响输出（稳定性靠 path 兜底全序）。
    static func build(records: [CrashEvidenceRecord], windowCutoff: Date?) -> CrashEvidenceLedger {
        var keepers: [CrashEvidenceRecord] = []
        var dropped: [CrashEvidenceRecord] = []
        var byKey: [String: Int] = [:]
        for record in records.sorted(by: preferredOrder) {
            guard let key = record.dedupKey else {
                keepers.append(record)
                continue
            }
            if let index = byKey[key] {
                dropped.append(record.markingDuplicateOf(keepers[index].path))
                continue
            }
            byKey[key] = keepers.count
            keepers.append(record)
        }
        return CrashEvidenceLedger(records: keepers.sorted(by: displayOrder),
                                   duplicates: dropped,
                                   windowCutoff: windowCutoff)
    }

    /// 同键之内谁留下：**确认崩溃优先**，其次事件时间可信的，最后路径字典序（全序 ⇒ 可复现）。
    static func preferredOrder(_ lhs: CrashEvidenceRecord, _ rhs: CrashEvidenceRecord) -> Bool {
        if lhs.state != rhs.state { return stateRank(lhs.state) < stateRank(rhs.state) }
        if lhs.hasEventTime != rhs.hasEventTime { return lhs.hasEventTime }
        if lhs.eventDate != rhs.eventDate {
            return (lhs.eventDate ?? .distantPast) > (rhs.eventDate ?? .distantPast)
        }
        return lhs.path < rhs.path
    }

    static func stateRank(_ state: CrashEvidenceState) -> Int {
        switch state {
        case .confirmed: return 0
        case .parseFailed: return 1
        case .suspected: return 2
        case .readFailed: return 3
        }
    }

    /// 展示顺序：状态 -> 事件时间新到旧 -> 路径。
    static func displayOrder(_ lhs: CrashEvidenceRecord, _ rhs: CrashEvidenceRecord) -> Bool {
        if lhs.state != rhs.state { return stateRank(lhs.state) < stateRank(rhs.state) }
        let left = lhs.eventDate ?? .distantPast
        let right = rhs.eventDate ?? .distantPast
        if left != right { return left > right }
        return lhs.path < rhs.path
    }

    /// 有真实事件时间、且事件时间落在观察窗口内的确认崩溃。
    var confirmedInWindow: [CrashEvidenceRecord] {
        records.filter { $0.state == .confirmed && $0.isCountable(inWindowAt: windowCutoff) }
    }

    /// 窗口外的确认崩溃 = **历史报告**，与当前窗口分开展示，绝不静默丢弃。
    var historicalConfirmed: [CrashEvidenceRecord] {
        records.filter { record in
            record.state == .confirmed && record.hasEventTime
                && record.isCountable(inWindowAt: windowCutoff) == false
        }
    }

    /// 没有事件时间的确认崩溃：是真崩溃，但无法归入任何窗口 ⇒ 单列。
    var undatedConfirmed: [CrashEvidenceRecord] {
        records.filter { $0.state == .confirmed && $0.hasEventTime == false }
    }

    func records(in state: CrashEvidenceState) -> [CrashEvidenceRecord] {
        records.filter { $0.state == state }
    }

    func count(in state: CrashEvidenceState) -> Int { records(in: state).count }

    var confirmedCount: Int { count(in: .confirmed) }
    var suspectedCount: Int { count(in: .suspected) }
    var parseFailedCount: Int { count(in: .parseFailed) }
    var readFailedCount: Int { count(in: .readFailed) }

    /// 出现在多于一份报告里的构建版本（次数 + 最近一次事件时间）。
    /// 只有一个版本时**无法区分新旧构建** —— 这个事实必须说出来，不许默认"就是当前版本"。
    var versionsObserved: [(key: String, count: Int, newest: Date?)] {
        var order: [String] = []
        var table: [String: (count: Int, newest: Date?)] = [:]
        for record in records where record.state == .confirmed {
            guard let key = record.identity.versionKey else { continue }
            if table[key] == nil { order.append(key) }
            let existing = table[key] ?? (0, nil)
            let newest = [existing.newest, record.eventDate].compactMap { $0 }.max()
            table[key] = (existing.count + 1, newest)
        }
        return order.map { key in
            let value = table[key] ?? (0, nil)
            return (key, value.count, value.newest)
        }
    }

    /// 「当前构建」= 确认崩溃里**事件时间最新**的那个版本。只在出现 ≥2 个版本时启用，
    /// 单版本时没有新旧可分（返回 nil），旧构建判定因此不会拿一个不存在的基准去比。
    var currentBuildKey: String? {
        let observed = versionsObserved
        guard observed.count >= 2 else { return nil }
        return observed.sorted { lhs, rhs in
            let left = lhs.newest ?? .distantPast
            let right = rhs.newest ?? .distantPast
            if left != right { return left > right }
            return lhs.key < rhs.key
        }.first?.key
    }

    /// 旧构建的确认崩溃：版本明确不同于当前构建 ⇒ 不算当前版本缺陷（RD-23）。
    var staleBuildConfirmed: [CrashEvidenceRecord] {
        guard let current = currentBuildKey else { return [] }
        return records.filter { record in
            record.state == .confirmed
                && record.isCountable(inWindowAt: windowCutoff)
                && record.identity.versionKey != nil
                && record.identity.versionKey != current
        }
    }

    /// **唯一**允许进 `crashCount` 与扣分的集合：窗口内 + 有事件时间 + 非旧构建。
    var countableConfirmed: [CrashEvidenceRecord] {
        let stale = Set(staleBuildConfirmed.map { $0.path + "#\( $0.lineNumber)" })
        return confirmedInWindow.filter { stale.contains($0.path + "#\($0.lineNumber)") == false }
    }

    var countablePaths: Set<String> { Set(countableConfirmed.map(\.path)) }
    var countedCrashCount: Int { countableConfirmed.count }
    var duplicateCount: Int { duplicates.count }
    var undatedConfirmedCount: Int { undatedConfirmed.count }
    var historicalConfirmedCount: Int { historicalConfirmed.count }
    var staleBuildConfirmedCount: Int { staleBuildConfirmed.count }

    // MARK: 说人话

    /// 一句「测到了什么」。分数旁边的解释、界面脚注与 CLI 的文本读数共用它。
    ///
    /// RD-60 之后**措辞不在这个文件里**：它住在唯一生产者 `CrashEvidenceReadout.ReasonCounts.statement`，
    /// 这里只把台账自己那八枚读数包成那个形状再交出去。为什么必须这样：`LogSummary.crashEvidence`
    /// 落盘的是**计数**，视图与 CLI 手里只有那些计数，如果台账自己再拼一句、快照另拼一句，
    /// 屏上那句与账上那句迟早分叉（RD-43/51 同族）。八种原因一条都不许在这里被合成一个数。
    var statement: String { reasonCounts.statement }

    /// 「哪些没测准」——缺证据的一律留在这里出声，而不是变成一个 0。
    var unknownStatement: String? {
        var parts: [String] = []
        if undatedConfirmedCount > 0 {
            parts.append("\(undatedConfirmedCount) 次确认崩溃没有事件时间戳，无法归入窗口")
        }
        if let current = currentBuildKey {
            parts.append("按构建版本分桶，当前构建 \(current)")
        } else {
            parts.append(versionsObserved.isEmpty
                ? "报告未自报构建版本，无法区分新旧构建"
                : "只出现一个构建版本，新旧无法区分")
        }
        let missing = records.flatMap { $0.identity.missingFields }
        if missing.isEmpty == false {
            let counts = Dictionary(grouping: missing, by: { $0 })
                .sorted { $0.key < $1.key }
                .map { "\($0.key) 缺 \($0.value.count) 份" }
            parts.append("归属维度不完整：" + counts.joined(separator: "、"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - 记录级窗口判定

extension CrashEvidenceRecord {
    /// 窗口内判定：**必须有真实事件时间**；没有事件时间的记录永远不算"窗口内"。
    func isCountable(inWindowAt cutoff: Date?) -> Bool {
        guard hasEventTime, let date = eventDate else { return false }
        guard let cutoff else { return true }
        return date >= cutoff
    }
}

// MARK: - 事件时间窗口切分（非崩溃类事件同一条口径）

/// 按事件时间把事件切成三份。`mtime` 不参与 —— 它只用于「发现候选」。
enum LogEventWindowSplit {
    struct Result: Sendable {
        var inWindow: [LogEvent] = []
        var undated: [LogEvent] = []
        var outOfWindow: [LogEvent] = []
    }

    /// - Parameter exemptPaths: **用户显式附加**的那些文件的路径。
    ///   它们不参与窗口裁剪（人刚点上来一份 400 天前的日志，因为日期老就被静默丢掉，
    ///   比窗口口径更让人意外 —— 这条例外在界面上要写成「用户选的例外范围」）。
    ///   例外只覆盖**行级计数**：崩溃是否够格进 `crashCount` 仍然要求有真实事件时间，
    ///   否则"手工附加一份没时间戳的报告"就成了绕过 RD-21 的后门。
    static func split(_ events: [LogEvent], cutoff: Date?, exemptPaths: Set<String> = []) -> Result {
        var result = Result()
        for event in events {
            let exempt = exemptPaths.contains(event.sourceLogPath)
            guard let date = event.date, event.eventTimeSource.isRealEventTime else {
                if exempt { result.inWindow.append(event) } else { result.undated.append(event) }
                continue
            }
            if exempt {
                result.inWindow.append(event)
            } else if let cutoff, date < cutoff {
                result.outOfWindow.append(event)
            } else {
                result.inWindow.append(event)
            }
        }
        return result
    }
}
