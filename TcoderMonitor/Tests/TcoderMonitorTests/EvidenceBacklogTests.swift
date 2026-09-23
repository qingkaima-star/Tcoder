import Foundation
import XCTest

/// R21 · **RD-57** —— 实拍新鲜度门禁的「批量补拍 + 可见积压」形状（需求方 2026-09-23 选的形状①）。
///
/// # 它要解决的真事
/// `EvidenceFreshnessTests` 抓的是一件对的事：**屏上的字变了而没人看过**。
/// 但它今天的形状是"过期即判红"，而**重拍要抢全机唯一那格 App 窗口**（AGENTS 横切约束 2/2.1）⇒
/// 谁改了 `Views/**` 或口径生产者，就得在窗口排到自己之前一直红着，
/// 而红着的人既不能合并、也不能把那一页的证据补上 —— 于是历史上真的出现过
/// 「一条好守卫变成落地路障」（RD-55 那次已经为此放宽过一回"这棵树没产物就跳过"）。
/// 2026-09-23 02:07 复测：main `2b4988b` 十行**全新鲜**（过期 0 行），
/// 而当时排队待落的分支里有两条（`ws/rd20-rolefields` / `ws/rd18-duptotal`）
/// 在自己那一份**旧表副本**上报「Git 洞察 停在 0f1d586，被 848ff90 拧过期」——
/// merge main 之后归零。⇒ 咬人的主因有两个，一个是**表副本落后于 main**（合流就好），
/// 另一个才是**真·改屏无人复核**（本文件治的就是这第二个，P53 把口径生产者列进依赖面之后它只会更常见）。
///
/// # 现在的形状
/// 过期页必须**逐条挂账**（页名 + 它停在哪个头 + 是哪个提交把它拧过期的 + 挂账人 + UTC 分钟）：
///   * 挂了账、且在 24 小时宽限内 ⇒ 放行，但**大声打印欠拍名单**（不许读成"查过没事"）；
///   * **没挂账** ⇒ 红；挂账点名的提交不在实算的候选里、或"停在"的头与实算不符 ⇒ 红
///     （抄一个旧提交糊不过去：那个 sha 必须真在 `头..HEAD -- 依赖面` 的结果里）；
///   * 挂账超过 24 小时 ⇒ 红（**欠拍过夜可以，欠三天等于没有**）；
///   * 挂账表本身格式不对（缺挂账人、提交不是 sha、时间不是 UTC 分钟、时间在未来） ⇒ 红
///     （这张表不许变成遮羞布）。
/// **判据本身一点没放宽**：依赖面动了一页就算过期，这条不变；变的只是
/// "过期之后必须先说出来、并且限时"，而不是"过期之后所有人都别想合并"。
extension EvidenceFreshnessTests {

    /// 一行挂账。`loggedAt` 解析不出来的行**进不了这个类型**（会被算成格式坏、当场判红）。
    struct BacklogEntry {
        var pages: [String]
        var head: String
        var agedBy: String
        var owner: String
        var loggedAt: Date
    }

    static let backlogHeading = "### 待重拍积压"
    static let backlogGrace: TimeInterval = 86_400   // 24 小时；只许往下调，不许为了放行往上调

    /// 逐行解析挂账表（本仓规矩：机械文本手术一律按整行处理，不按偏移切）。
    /// 返回 `(可用条目, 格式坏的行的说明)` —— 坏行绝不静默跳过。
    /// 拆成 `backlogRows` / `backlogCells` / `backlogEntry` 三小段是
    /// `X3TestSizeAuditTests` 那条「Tests 里函数圈复杂度 <16」的线逼的（合成一段实测 CC=20）：
    /// **闸门不许抬，只能拆**。三段各自仍可单独被元测试喂合成输入。
    static func backlog(in markdown: String) -> (entries: [BacklogEntry], malformed: [String]) {
        var entries: [BacklogEntry] = []
        var malformed: [String] = []
        for line in backlogRows(in: markdown) {
            if let entry = backlogEntry(from: line) {
                entries.append(entry)
            } else {
                malformed.append("\(line)　←要 5 格齐全：页 / 停在(sha) / 拧过期的提交(sha) / 挂账人 / UTC 分钟")
            }
        }
        return (entries, malformed)
    }

    /// 本节里的**数据行**：剥引用块前缀、跳过空行与表头分隔行，遇到下一个 `##` 或 `---` 就结束。
    static func backlogRows(in markdown: String) -> [String] {
        var rows: [String] = []
        var inside = false
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw)
            // 与 `rows(in:)` **同一套写法**：这张表就住在那张表旁边，而那份文档里的机器读表
            // 一律是引用块（每行前缀 `> `）。这里不剥 `>` 的话，"表被搬进引用块"这件事
            // 会让解析器读到零行、判据静默变成永真绿 —— 两条读同一张表的尺子必须同构。
            while line.hasPrefix(">") { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
            if line.hasPrefix(backlogHeading) { inside = true; continue }
            guard inside else { continue }
            if line.hasPrefix("##") || line.hasPrefix("---") { break }        // 本节结束
            if line.isEmpty || !line.hasPrefix("|") { continue }
            let first = backlogCells(line).first ?? ""
            if first.hasPrefix("---") || first.contains("页") { continue }      // 表头与分隔行
            rows.append(line)
        }
        return rows
    }

    /// 一行切成格子。`split` 默认丢掉首尾空段，必须显式留着再 drop，
    /// 否则第一格与最后一格会被一起吃掉（本仓踩过）。
    static func backlogCells(_ line: String) -> [String] {
        line.split(separator: "|", omittingEmptySubsequences: false)
            .dropFirst().dropLast()
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// 一行 ⇒ 一条挂账；任何一格不合规就返回 `nil`，由调用方点名（不许静默放行）。
    static func backlogEntry(from line: String) -> BacklogEntry? {
        let cells = backlogCells(line)
        guard cells.count == 5, let when = backlogDate(from: cells[4]) else { return nil }
        let pages = cells[0].split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let head = cells[1].replacingOccurrences(of: "`", with: "")
        let agedBy = cells[2].replacingOccurrences(of: "`", with: "")
        let owner = cells[3]
        let isSha = agedBy.count >= 7 && agedBy.allSatisfy { $0.isHexDigit }
        let isHead = head.count >= 7 && head.allSatisfy { $0.isHexDigit }
        guard !pages.isEmpty, isHead, isSha, !owner.isEmpty, owner != "—" else { return nil }
        return BacklogEntry(pages: pages, head: head, agedBy: agedBy, owner: owner, loggedAt: when)
    }

    private static func backlogDate(from text: String) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        let halves = text.split(separator: " ").map(String.init)
        guard halves.count == 2 else { return nil }
        let day = halves[0].split(separator: "-").compactMap { Int($0) }
        let clock = halves[1].split(separator: ":").compactMap { Int($0) }
        guard day.count == 3, clock.count == 2 else { return nil }
        var components = DateComponents()
        components.year = day[0]; components.month = day[1]; components.day = day[2]
        components.hour = clock[0]; components.minute = clock[1]
        return calendar.date(from: components)
    }

    /// 纯函数：把"实算出来的过期页"与"挂账表"对起来。
    /// 四个清单都要被调用方拿去判红/打印，**不许只看 `acknowledged` 非空就放行**。
    /// `candidates` 是那一页依赖面在 `头..HEAD` 里**真的**动过的提交（新→旧），
    /// 挂账点名的 sha 必须是其中之一 —— 否则"点错了页"与"编一个旧提交"都糊得过去。
    static func backlogVerdict(stale: [(pages: [String], head: String, candidates: [String])],
                               entries: [BacklogEntry],
                               now: Date,
                               grace: TimeInterval = backlogGrace)
        -> (unlisted: [String], mismatched: [String], overdue: [String], acknowledged: [String]) {
        var unlisted: [String] = []
        var mismatched: [String] = []
        var overdue: [String] = []
        var acknowledged: [String] = []
        for page in stale {
            let label = page.pages.joined(separator: "/")
            let hits = entries.filter { entry in entry.pages.contains(where: page.pages.contains) }
            guard let hit = hits.first else {
                unlisted.append("\(label)（停在 \(page.head)，被 \(page.candidates.prefix(3).joined(separator: " "))"
                    + " 等 \(page.candidates.count) 笔拧过期）⇒ 没挂账：要么重拍那一页，"
                    + "要么在「\(Self.backlogHeading)」登记欠拍 + 挂账人")
                continue
            }
            guard hit.head == page.head, page.candidates.contains(hit.agedBy) else {
                mismatched.append("\(label)：实算停在 \(page.head)、候选 \(page.candidates.prefix(3))，"
                    + "挂账却写 \(hit.agedBy)@\(hit.head)")
                continue
            }
            let age = now.timeIntervalSince(hit.loggedAt)
            guard age >= -3_600 else {
                mismatched.append("\(label)：挂账时间在未来（\(Self.backlogStamp(hit.loggedAt))），"
                    + "UTC 分钟得手写，写错了这一格等于没挂")
                continue
            }
            if age > grace {
                overdue.append("\(label) 已挂账 \(Int(age / 3_600)) 小时"
                    + "（宽限 \(Int(grace / 3_600)) 小时），挂账人 \(hit.owner)")
            } else {
                acknowledged.append("\(label) ← \(hit.agedBy)（\(hit.owner)，"
                    + "\(Int(age / 3_600)) 小时前挂的）")
            }
        }
        return (unlisted, mismatched, overdue, acknowledged)
    }

    /// 挂账表里那个时间格的正写法（**与解析器同一把尺子**：UTC 到分钟）。
    static func backlogStamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    // MARK: - 元测试（两个方向都要红过一次，本仓规矩：扫描/解析型判据不配元测试迟早永真绿）

    func test_meta_backlogParserRejectsMalformedRows() throws {
        let good = "| 总览 | `95cccd7` | `7f56172` | WS-P 代码与Git | 2026-09-23 01:00 |"
        let markdown = "\(Self.backlogHeading)\n\n| 页 | 停在 | 拧过期的提交 | 挂账人 | 挂账时间(UTC) |\n"
            + "|---|---|---|---|---|\n"
            + good + "\n"
            + "| 性能监控 | `abc1234` | 无 | WS-X | 2026-09-23 01:00 |\n"            // 提交不是 sha
            + "| 健康评分 | `abc1234` | `def5678` |  | 2026-09-23 01:00 |\n"          // 缺挂账人
            + "| 错误日志 | `abc1234` | `def5678` | WS-M | 昨天下午 |\n"                // 时间读不出
        let parsed = Self.backlog(in: markdown)
        XCTAssertEqual(parsed.entries.count, 1, "只有一格合规：\(parsed.entries.map(\.pages))")
        XCTAssertEqual(parsed.malformed.count, 3, "三格坏行都必须被点名，不许静默跳过：\(parsed.malformed)")
        XCTAssertEqual(parsed.entries.first?.pages, ["总览"])

        // 反向：本节一行都没有（当前的 main 就是这种状态）⇒ 零条目零坏行，不是"解析坏了"。
        let empty = Self.backlog(in: "\(Self.backlogHeading)\n\n当前无积压。\n")
        XCTAssertTrue(empty.entries.isEmpty && empty.malformed.isEmpty, "\(empty)")

        // 同一张表搬进引用块（文档里那台机器表就是这个画法）⇒ 必须读出一样的东西。
        // 这条不是凑数：解析器一旦不剥 `>`，本节改个排版就静默读到零行，判据当场变永真绿。
        let quoted = Self.backlog(in: markdown.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }.joined(separator: "\n"))
        XCTAssertEqual(quoted.entries.count, parsed.entries.count, "引用块里的同一张表要读得一样")
        XCTAssertEqual(quoted.malformed.count, parsed.malformed.count)
    }

    func test_meta_backlogVerdictHasFourIndependentOutcomes() throws {
        let now = Date(timeIntervalSince1970: 1_758_600_000)         // 2026-09-23 06:40 UTC
        let entry = EvidenceFreshnessTests.BacklogEntry(
            pages: ["总览"], head: "95cccd7", agedBy: "7f56172", owner: "WS-P",
            loggedAt: now.addingTimeInterval(-3_600))
        let stale = [(pages: ["总览"], head: "95cccd7", candidates: ["7f56172", "abcdef0"])]
        let ok = Self.backlogVerdict(stale: stale, entries: [entry], now: now)
        XCTAssertEqual(ok.acknowledged.count, 1, "刚挂账且提交在候选里 ⇒ 只进 acknowledged：\(ok)")
        XCTAssertTrue(ok.unlisted.isEmpty && ok.mismatched.isEmpty && ok.overdue.isEmpty)

        XCTAssertTrue(Self.backlogVerdict(stale: stale, entries: [], now: now).unlisted.count == 1,
                      "没挂账的过期页必须进 unlisted（这才是「不许悄悄过期」的那一牙）")
        // 抄一个**不在候选里**的旧提交：糊不过去。
        let invented = [EvidenceFreshnessTests.BacklogEntry(pages: ["总览"], head: "95cccd7",
                                                            agedBy: "1111111", owner: "WS-P",
                                                            loggedAt: entry.loggedAt)]
        XCTAssertEqual(Self.backlogVerdict(stale: stale, entries: invented, now: now).mismatched.count, 1,
                       "点名的提交不在实算候选里 ⇒ 要红")
        // "停在"的头抄错（把别页的头抄过来）也要红。
        let wrongHead = [EvidenceFreshnessTests.BacklogEntry(pages: ["总览"], head: "1111111",
                                                             agedBy: "7f56172", owner: "WS-P",
                                                             loggedAt: entry.loggedAt)]
        XCTAssertEqual(Self.backlogVerdict(stale: stale, entries: wrongHead, now: now).mismatched.count, 1)
        // 时间写在未来 ⇒ 这一格等于没挂。
        let future = [EvidenceFreshnessTests.BacklogEntry(pages: ["总览"], head: "95cccd7",
                                                          agedBy: "7f56172", owner: "WS-P",
                                                          loggedAt: now.addingTimeInterval(6 * 3_600))]
        XCTAssertEqual(Self.backlogVerdict(stale: stale, entries: future, now: now).mismatched.count, 1,
                       "UTC 分钟是手写的，写错了不许悄悄放行")
        // 欠拍过夜 ⇒ 红，否则这张表变成永久遮羞布。
        let ancient = [EvidenceFreshnessTests.BacklogEntry(pages: ["总览"], head: "95cccd7",
                                                           agedBy: "7f56172", owner: "WS-P",
                                                           loggedAt: now.addingTimeInterval(-100 * 3_600))]
        XCTAssertEqual(Self.backlogVerdict(stale: stale, entries: ancient, now: now).overdue.count, 1)
        // 没过期却挂着账 ⇒ 不红（补拍完忘了删这一格是常事），但也进不了 acknowledged。
        XCTAssertTrue(Self.backlogVerdict(stale: [], entries: [entry], now: now).acknowledged.isEmpty)
    }
}
