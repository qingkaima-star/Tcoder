// 内置「包最新版本」快照（WS-B · 依赖安全四层里的第 1 层）
//
// 从 VulnerabilitySource.swift 按职责拆出：本文件只有离线快照表与查表逻辑，
// 不发网络请求、不含漏洞规则（规则在 VulnerabilitySource.swift，
// 在线客户端在 OsvClient.swift / NpmClient.swift，预算与限流在 DependencyNetworkLookup.swift）。
import Foundation

// MARK: - Bundled "latest known version" snapshot
//
// OWNER: WS-B / 子代理3。本文件只做三件事：
//   1. `DependencySnapshot`：内置「包最新版本」快照（离线，Swift 常量字典，不落任何资源文件）。
//   2. `VulnerabilitySource`：内置已知漏洞公告 + 离线匹配 / 聚合。
//   3. `DependencyNetworkLookup`：可选在线查询（api.osv.dev / registry.npmjs.org），
//      永不抛出、永不卡住调用方。
// 版本比较一律复用 Models 里冻结的 `DependencyVersion`，本文件不实现自己的比较逻辑。

/// 内置「最新版本」快照。
enum DependencySnapshot {

    /// 快照数据对应的日期（**只到天**），用于 UI 说明「快照截至 …」。
    ///
    /// 诚实标注：npm 条目是在该日期用 `https://registry.npmjs.org/<pkg>/latest` 实测得到的；
    /// 其他生态（Maven / SwiftPM / PyPI / Go / Cargo）是**保守取值**——只写确认存在、
    /// 且不低于该生态常见稳定版的版本号。没把握的包一律不收录（查不到返回 nil，绝不猜）。
    ///
    /// 为什么不到分钟（#35）：这张表只是「哪天抄的」一份静态常量表，分钟级没有任何依据。
    /// 旧实现在 `date(year:month:day:)` 里写死 `hour = 17` / `minute = 5`，渲染出来是
    /// 「快照截至 2026-09-19 17:05」，用户会以为我们掌握分钟级采集时刻。
    /// 追查过出处：那两个字段与当时的兜底 epoch（`1_758_272_700` = **2025**-09-19 17:05 CST）
    /// 出自同一个提交，落盘时间是本地 17:14，而全仓（含 WS-B 工作笔记与 README）
    /// 没有任何一处把 17:05 记成一次采集记录的时刻 —— 它是写代码那一下的挂钟，
    /// 兜底常量的年份还比快照早一年（改了年月、忘了改兜底）。两处一起删掉。
    static let snapshotDate: Date = DependencySnapshot.date(year: 2026, month: 9, day: 19)

    /// 「内置快照是哪天的」那一句，离线判据与降级说明**共用同一份**，
    /// 免得分析器写一遍、视图再写一遍然后各自腐烂（#25 的原始症状就是这字段谁都不说）。
    ///
    /// 措辞里刻意不出现「失败」二字：`VulnerabilityEvidence.classify` 拿
    /// `networkLookupNote.contains("失败")` 当降级判据，这句话会被拼进那个 note。
    static var asOfText: String {
        // **整句键**：这句会被插进一条已经翻译的长句里，写成插值字面串就等于
        // 英文态在那句英文中间掉进一段中文（2026-09-23 拿 Homebrew 复验实拍抓到：
        // "…built-in snapshot (npm / Maven / Python), 快照截至 2026-09-19（4 days ago）; …"）。
        localizedFormat("快照截至 %1$@（%2$@）",
                        snapshotDayText, DateFormat.sinceDescription(snapshotDate))
    }

    /// 全仓共用的日期格式化器只有 `DateFormat.full`（`yyyy-MM-dd HH:mm`），
    /// 快照只到天，所以取它输出的**日期段**——不为此新建格式化器。
    /// 切法由 `HonestyP1SnapshotDateTests` 钉住（形状为 年-月-日、整句不含时分冒号）。
    static let daySegmentLength = 10

    static var snapshotDayText: String {
        String(DateFormat.full.string(from: snapshotDate).prefix(daySegmentLength))
    }

    /// 给已有的在线核对说明补上快照日期；说明为空时原样返回，
    /// 已经带过这句话也不再重复补（避免同一屏出现两遍日期）。
    static func noteAppended(to note: String) -> String {
        guard note.isEmpty == false else { return note }
        guard note.contains(asOfText) == false else { return note }
        return note + "；" + asOfText
    }

    /// 精确查表：命中返回 latest known version，未收录返回 nil。
    ///
    /// 规则：先按 `"<ecosystem.rawValue>|<name 原样>"` 精确命中，再做「同生态内大小写不敏感」
    /// 二次命中；maven 与 gradle 互相回退（两者 `groupId:artifactId` 坐标同源）。
    static func latestKnownVersion(ecosystem: DependencyEcosystem, name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let scopes = lookupScopes(for: ecosystem)
        for scope in scopes {
            if let hit = table["\(scope)|\(trimmed)"] { return hit }
        }
        let lowered = trimmed.lowercased()
        for scope in scopes {
            if let hit = caseInsensitiveTable["\(scope)|\(lowered)"] { return hit }
        }
        return nil
    }

    /// 快照收录条目数。
    static var bundledEntryCount: Int { table.count }

    /// 便捷方法：把快照信息写回一条依赖记录（不覆盖已有的在线结果）。
    static func applySnapshotInfo(to record: DependencyRecord) -> DependencyRecord {
        var updated = record
        if updated.latestKnownVersion == nil || updated.versionCheckSource == .none {
            if let latest = latestKnownVersion(ecosystem: record.ecosystem, name: record.name) {
                updated.latestKnownVersion = latest
                updated.versionCheckSource = .bundledSnapshot
            }
        }
        return updated
    }

    /// 查表时要尝试的生态 key 顺序（maven / gradle 互为回退）。
    static func lookupScopes(for ecosystem: DependencyEcosystem) -> [String] {
        switch ecosystem {
        case .maven: return ["maven", "gradle"]
        case .gradle: return ["gradle", "maven"]
        default: return [ecosystem.rawValue]
        }
    }

    /// 把「某年某月某日」摆成 Asia/Shanghai 那一天的**日首**时刻（日粒度，见 `snapshotDate`）。
    ///
    /// 兜底值给的是 epoch 0（1970-01-01）而不是任何一个"看着像另一天"的日期：
    /// `calendar` 与 `timeZone` 都是字面量，正常系统上走不到这一支；
    /// 真走到了说明时区表被砍，那时宁可显形成一个一眼就是坏值的日期，
    /// 也不该再留一个年份写错、看着像有出处的常量（#35 就是被那样一个值骗过一次）。
    static func date(year: Int, month: Int, day: Int) -> Date {
        var comps = DateComponents()
        comps.calendar = Calendar(identifier: .gregorian)
        comps.timeZone = TimeZone(identifier: "Asia/Shanghai")
        comps.year = year
        comps.month = month
        comps.day = day
        // 不设 hour / minute：`DateComponents.date` 对缺省字段按 0 处理，结果就是那一天 0 点。
        return comps.date ?? Date(timeIntervalSince1970: 0)
    }

    /// key = "<ecosystem.rawValue>|<package name 原样>"；value = 最新已知版本。
    /// Java 条目统一放在 `maven|`，gradle 通过回退命中，避免维护两份表。
    static let table: [String: String] = [
        // ---- npm（2026-09-19 经 registry.npmjs.org 实测）----
        "npm|react": "19.3.0",
        "npm|react-dom": "19.3.0",
        "npm|vue": "3.5.43",
        "npm|vite": "8.3.0",
        "npm|typescript": "7.0.2",
        "npm|axios": "1.20.0",
        "npm|lodash": "4.18.1",
        "npm|next": "16.3.5",
        "npm|express": "5.2.1",
        "npm|@angular/core": "22.1.7",

        // ---- maven / gradle（保守取值，均为确认存在的版本）----
        "maven|org.springframework.boot:spring-boot-starter-web": "3.3.5",
        "maven|org.mybatis.spring.boot:mybatis-spring-boot-starter": "3.0.3",
        "maven|org.projectlombok:lombok": "1.18.34",
        // `io.jsonwebtoken:jjwt` 这个坐标在 0.10 起被拆成 jjwt-api / jjwt-impl / jjwt-jackson，
        // 所以该坐标本身的最后发布版本仍是 0.9.1（升级方向见内置 jjwt 漏洞规则）。
        "maven|io.jsonwebtoken:jjwt": "0.9.1",
        "maven|com.alibaba:fastjson": "1.2.83",
        "maven|org.apache.logging.log4j:log4j-core": "2.23.1",
        "maven|commons-collections:commons-collections": "3.2.2",
        "maven|com.google.guava:guava": "33.3.1-jre",
        "maven|com.squareup.okhttp3:okhttp": "4.12.0",
        "maven|io.grpc:grpc-netty-shaded": "1.66.0",
        "maven|com.fasterxml.jackson.core:jackson-databind": "2.17.2",

        // ---- SwiftPM ----
        "swiftPM|GRDB.swift": "6.24.0",
        "swiftPM|swift-log": "1.6.1",
        "swiftPM|swift-nio": "2.65.0",

        // ---- Python（小写包名）----
        "python|requests": "2.32.3",
        "python|urllib3": "2.2.3",
        "python|pydantic": "2.9.2",
        "python|django": "5.1.2",
        "python|flask": "3.0.3",
        "python|numpy": "2.1.2",
        "python|pandas": "2.2.3",

        // ---- Go（完整 module path）----
        "go|github.com/gin-gonic/gin": "1.10.0",

        // ---- Cargo ----
        "cargo|serde": "1.0.203",
        "cargo|tokio": "1.38.1",
    ]

    /// 同生态内大小写不敏感的二级索引。
    static let caseInsensitiveTable: [String: String] = {
        var index = [String: String](minimumCapacity: table.count * 2)
        for (key, value) in table {
            guard let separator = key.firstIndex(of: "|") else { continue }
            let scope = String(key[..<separator])
            let name = String(key[key.index(after: separator)...])
            index["\(scope)|\(name.lowercased())"] = value
        }
        return index
    }()
}

// MARK: - Bundled advisories

/// 一条内置已知漏洞规则。
