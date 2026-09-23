import Foundation
import XCTest

/// OWNER: 总工（设计总监线）—— 九页实拍复核的**过期判据**。
///
/// 读 `docs/界面-乱的清单.md` 里那张「每页最近一次实拍在哪个头」的表，
/// 对每一行把它自己写出的那条 `git log <头>..HEAD -- <依赖面>` 真的跑一遍，
/// **非空即过期**：那一页的实拍已经过期，屏上可能有没人看过的变化。
/// 过期之后**必须出声**（RD-57）：要么重拍那一页并更新表里的头，
/// 要么进同一份文档里的「### 待重拍积压」逐条挂账（页 / 停在 / 拧过期的提交 / 挂账人 / UTC 分钟，24 小时宽限）。
/// 判红的仍然是"屏上变了却谁也没说"这一件——只是不再拿全机唯一那格 App 窗口去卡所有人。
///
/// 为什么必须有它（而不是把表写漂亮就完事）：这张表第一次写出来就写错了两行 ——
/// 初稿把 Git 洞察 / 贡献者 / 错误日志 / 依赖分析 一起记在 `fb94e88` 那批上，
/// 理由是"这四页自己的 `Views/**` 没动"。但 `fb94e88` **早于** `ce185a2`，
/// 而 P36 改的是公共基座 `Design/ChartTokens.swift` 的时间轴锚点，
/// Git 洞察与贡献者都在用那把基座 ⇒ "自己的文件没动"不等于"屏上没变"。
/// 人会忘记依赖面、也不会回头改表，所以这句话必须每次合流后被机器重新问一遍。
///
/// ## 判据的形状
///
/// * 表里每行第三列必须写成 `git log <rev>..HEAD -- <全路径> <全路径>`。
///   **路径写全**：判据不认 `…` 省略号，省略号那格等于没写判据。
/// * 解析不出任何一行 ⇒ 直接判红。一条读不出东西的守卫比没有守卫更糟（它看起来在工作）。
/// * 九页的名字在这里点一份名册：新增一页而表里没它的行，当场判红
///   （清单不自动长大，是本仓记过好几回的那族缺陷）。
final class EvidenceFreshnessTests: XCTestCase {

    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // TcoderMonitorTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // TcoderMonitor
        .deletingLastPathComponent()   // 仓库根

    static let catalogPath = "docs/界面-乱的清单.md"

    /// 九页名册。与 `scripts/paired_page_evidence.sh` 的页名是**两份副本**——
    /// 那把尺子按名字截图，这里按名字查有没有行；两处不一致时这里会红，
    /// 因为改了页名而没改名册，名册里就会有一页在表里找不到。
    static let ninePages = ["总览", "代码规模", "复杂度风险", "Git 洞察", "贡献者",
                            "性能监控", "错误日志", "依赖分析", "健康评分"]

    struct Row {
        var pages: [String]
        var batch: String
        var head: String
        var paths: [String]
    }

    /// 一行**实际要查哪些页的图**。
    /// "全九页 · 外壳与主题"那种行管的是公共基座：它自己没有单独成图的页，
    /// 于是反过来要求它引用的那一批**九页齐全** —— 这是更强的说法，也才是它真正的意思。
    /// 抽成函数是因为**打印的格数必须与实际查的格数同源**：
    /// 上一版直接拿 `row.pages.count` 去乘 4，公共基座那一行就少报了 8 格。
    static func expectedShots(for row: Row) -> [String] {
        row.pages.contains(where: { $0.contains("全九页") })
            ? ninePages
            : row.pages.filter { ninePages.contains($0) }
    }

    /// 一套实拍要齐四格：深浅 × 顶尾。缺哪一格就报哪一格。
    struct EvidenceGap: Equatable {
        var page: String
        var batch: String
        var what: String
    }

    static let evidenceModes = ["light-top", "light-tail", "dark-top", "dark-tail"]

    // MARK: - 解析（纯函数，元测试直接喂合成 markdown）

    /// 抽出表里带 `git log <rev>..HEAD -- <路径…>` 的行。
    /// 第一列里的页名按 `/` 与 `·` 拆开（"Git 洞察 / 贡献者" 是一行管两页）。
    static func rows(in markdown: String) -> [Row] {
        let pattern = #"git log ([0-9a-f]{7,40})\.\.HEAD -- ([^`)）|]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            XCTFail("解析正则构造失败 ⇒ 这条判据根本没在跑")
            return []
        }
        var out: [Row] = []
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            // 表在文档里是**引用块**（每行前缀 `> `），先剥掉才认得出表格行。
            var line = String(raw)
            while line.hasPrefix(">") { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
            guard line.hasPrefix("| ") else { continue }
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let headRange = Range(match.range(at: 1), in: line),
                  let pathRange = Range(match.range(at: 2), in: line) else { continue }
            let cells = line.split(separator: "|", omittingEmptySubsequences: false).dropFirst().map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard let pageCell = cells.first else { continue }
            let pages = pageCell.split(whereSeparator: { $0 == "/" || $0 == "·" || $0 == "、" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            // 省略号路径**不算判据**：写 `…DashboardHero.swift` 的那一格等于没写，
            // 与其去查一个不存在的路径（永远为空、永远绿），不如让这一页从名册里消失。
            let paths = String(line[pathRange]).split(separator: " ")
                .map(String.init)
                .filter { !$0.isEmpty && !$0.contains("\u{2026}") }
            guard !paths.isEmpty else { continue }
            let batch = cells.count >= 2
                ? cells[1].replacingOccurrences(of: "`", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                : ""
            out.append(Row(pages: pages, batch: batch, head: String(line[headRange]), paths: paths))
        }
        return out
    }

    /// 哪些行已经过期。`log` 注入进来，元测试才能不依赖仓库历史测这个函数。
    static func stale(_ rows: [Row],
                      log: (_ head: String, _ paths: [String]) -> [String]) -> [String] {
        rows.flatMap { row -> [String] in
            let touched = log(row.head, row.paths)
            guard !touched.isEmpty else { return [] }
            let page = row.pages.joined(separator: "/")
            let firstThree = touched.prefix(3).joined(separator: " ")
            return [page + "：实拍停在 " + row.head + "，此后依赖面动了 "
                    + String(touched.count) + " 个文件（" + firstThree + "）"]
        }
    }

    /// 名册里哪些页在表里一行都没有。
    static func pagesWithoutRows(in rows: [Row]) -> [String] {
        let covered = Set(rows.flatMap(\.pages))
        return ninePages.filter { !covered.contains($0) }
    }

    /// 那一页的依赖面从实拍那个头到 `HEAD` **净变了哪些文件**。
    ///
    /// 为什么判过期要用净差异、而不是 `runGitLog` 的提交数（需求方 2026-09-23 13:24 授权的窄修）：
    /// 本仓规约是"每人一树、落地前必须先并 main"，而 `git log <头>..HEAD -- 路径` 数的是**历史形状**。
    /// 分支并 main 时那些内容会在合并里被重新落地一遍 ⇒ 提交数非空、内容却一字不差。
    /// 实测（这棵树的十个行）：十条全被判过期，其中**六条净差异为 0**
    /// （性能监控 / Git 洞察 / 贡献者 / 错误日志 / 依赖分析 / 全九页外壳）——
    /// 那六条在 RD-57 之后不再是"当场红"，而会变成**逼人流假欠账**的假条目：
    /// 挂了账不等于看过了，往账上写没发生过的变化是把这条守卫变成遮羞布。
    /// ⇒ 净差异只用来决定"过不过期"；**挂账对不上号仍然照 `runGitLog` 的候选提交判**（见下）。
    static func netChanged(head: String, paths: [String],
                           root: URL = EvidenceFreshnessTests.repoRoot) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["diff", "--name-only", head, "HEAD", "--"] + paths
        process.currentDirectoryURL = root
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        // 与 `runGitLog` 同一条保守规则：git 报错一律算"变了"，宁可误红不可漏红。
        guard process.terminationStatus == 0 else {
            let firstLine = text.split(separator: "\n").first.map(String.init) ?? "无输出"
            return ["git diff 失败（exit " + String(process.terminationStatus) + "）：" + firstLine]
        }
        return text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    // MARK: - 真判据

    static func runGitLog(head: String, paths: [String]) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["log", "--format=%h", "\(head)..HEAD", "--"] + paths
        process.currentDirectoryURL = repoRoot
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        // git 报错（头不存在、路径不存在）也要算"动过"：宁可误红，不可漏红。
        guard process.terminationStatus == 0 else {
            let firstLine = text.split(separator: "\n").first.map(String.init) ?? "无输出"
            return ["git log 失败（exit " + String(process.terminationStatus) + "）：" + firstLine]
        }
        return text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    func test_everyPageInTheTableStillHasFreshEvidence() throws {
        let url = Self.repoRoot.appendingPathComponent(Self.catalogPath)
        let markdown = try String(contentsOf: url, encoding: .utf8)
        let found = Self.rows(in: markdown)
        XCTAssertFalse(found.isEmpty,
                       "读不到任何一行带 `git log <头>..HEAD -- <路径>` 的表行 ⇒ "
                     + "那张逐页表改了格式或判据列被写成了省略号，这条守卫正在空转")

        let missing = Self.pagesWithoutRows(in: found)
        XCTAssertTrue(missing.isEmpty,
                      "九页名册里这些页在表中没有行（新增页面忘了登记？）：\(missing)")

        // RD-57：过期不再"立刻判红"，而是**必须出声**——过期页要么重拍、要么进「待重拍积压」逐条挂账。
        // 依赖面算过期的一条没放宽，改的只是"过期之后谁都能被这张表卡住"那件事。
        var stalePages: [(pages: [String], head: String, candidates: [String])] = []
        for row in found {
            // 过期 = **内容与实拍端不同**（净差异）。`candidates` 仍取 `git log` 的提交：
            // 「待重拍积压」第三格要指到真把那一页改了的提交，净差异只给得出文件名，给不出 sha。
            let changed = try Self.netChanged(head: row.head, paths: row.paths)
            guard !changed.isEmpty else { continue }
            stalePages.append((pages: row.pages, head: row.head,
                               candidates: try Self.runGitLog(head: row.head, paths: row.paths)))
        }
        let logged = Self.backlog(in: markdown)
        XCTAssertTrue(logged.malformed.isEmpty,
                      "「\(Self.backlogHeading)」这张表本身格式不对 ⇒ 它不许变成遮羞布，逐条修好：\n"
                    + logged.malformed.joined(separator: "\n"))
        let verdict = Self.backlogVerdict(stale: stalePages, entries: logged.entries, now: Date())
        XCTAssertTrue(verdict.unlisted.isEmpty,
                      "这些页的实拍已经过期，屏上可能有没人看过的变化 —— 重拍那一页并更新表里的头，"
                    + "或（拿不到全机唯一那格 App 窗口时）在「\(Self.backlogHeading)」登记欠拍 + 挂账人：\n"
                    + verdict.unlisted.joined(separator: "\n"))
        XCTAssertTrue(verdict.mismatched.isEmpty,
                      "挂账与实算对不上 ⇒ 挂账写错了页、抄了个别处的提交，或 UTC 时间写歪了：\n"
                    + verdict.mismatched.joined(separator: "\n"))
        XCTAssertTrue(verdict.overdue.isEmpty,
                      "欠拍超过 \(Int(Self.backlogGrace / 3_600)) 小时宽限期还不补拍 —— "
                    + "挂了账不等于看过了，抢一次 App 窗口把它清掉：\n"
                    + verdict.overdue.joined(separator: "\n"))
        for note in verdict.acknowledged {
            print("【实拍欠拍·已挂账】" + note)      // 放行，但必须大声：不许读成"查过没事"
        }
        print("【实拍新鲜度】表里 \(found.count) 行、覆盖 \(Set(found.flatMap(\.pages)).count) 页 → "
            + "过期 \(stalePages.count) 行（已挂账 \(verdict.acknowledged.count) 行、"
            + "没挂账 \(verdict.unlisted.count) 行）")
    }

    /// 净差异口径的**真 git 夹具**，两个方向都要钉住（需求方授权的窄修，见 `netChanged` 上方注释）：
    /// ① 历史动过、内容与实拍端一字不差 ⇒ **不判**过期（否则每条并过 main 的流都被逼去挂假欠账）；
    /// ② 内容真的变了 ⇒ 判过期（这条窄修不许把"看过的屏"变成"不必再看"）。
    func test_stalenessFollowsContentNotHistory() throws {
        let fx = try FixtureRepo(name: "tcoder-evidence-fx-")
        addTeardownBlock { fx.cleanup() }
        let shot = try fx.buildHistoryThatLooksTouchedButIsNot()
        XCTAssertFalse(try fx.git(["log", "--format=%h", shot + "..HEAD", "--", "a.txt"]).isEmpty,
                       "夹具没造出「历史动过、净内容未变」的形状 ⇒ 这条元测试在空转")
        XCTAssertTrue(try Self.netChanged(head: shot, paths: ["a.txt"], root: fx.root).isEmpty,
                      "内容一字不差却被判成变了 ⇒ 会把每条并过 main 的流都逼成假欠账")
        try fx.change("a.txt", "9")
        try fx.git(["commit", "-qam", "Z 这次真的改了内容"])       // 不 commit 就进不了 `diff <头> HEAD`
        XCTAssertEqual(try Self.netChanged(head: shot, paths: ["a.txt"], root: fx.root), ["a.txt"],
                       "内容真的变了却不判过期 ⇒ 这条判据被放宽成了没判据")
    }

    /// 表里每行说的"实拍过"到底成不成立：四格图都在、且每格的 `PROVENANCE` 里
    /// 记的 rev 就是表里写的那个头。
    ///
    /// 立它的理由：口径写的是"**深浅两态**九页全部实拍复核通过"，
    /// 而"某批只拍了顶拍"或"表里的头抄错了"这两种情况**都不体现在行数上**——
    /// 数得出 9 行、数不出 36 格。注入 `exists` / `provenanceRev` 是为了让这条判据
    /// 自己能被合成输入双向测到（不然它只能靠真盘上恰好有什么）。
    static func evidenceGaps(in rows: [Row],
                             root: URL,
                             exists: (URL) -> Bool,
                             provenanceRev: (URL) -> String?) -> [EvidenceGap] {
        var gaps: [EvidenceGap] = []
        for row in rows {
            // 只点名九页：像"全九页 · 外壳与主题"那种行管的是**公共基座**，
            // 它自己没有单独成图的页，证据就是它所引用的那批九页图。
            let shots = expectedShots(for: row)
            if shots.isEmpty {
                gaps.append(EvidenceGap(page: row.pages.joined(separator: "/"), batch: row.batch,
                                        what: "这一行的页名都不在九页名册里 ⇒ 它其实一格也没在查"))
                continue
            }
            for page in shots {
                for mode in evidenceModes {
                    let dir = root.appendingPathComponent(row.batch).appendingPathComponent(mode)
                    let shot = dir.appendingPathComponent("\(page).png")
                    if !exists(shot) {
                        gaps.append(EvidenceGap(page: page, batch: row.batch,
                                                what: "缺 \(mode)/\(page).png"))
                    }
                    let recorded = provenanceRev(dir.appendingPathComponent("PROVENANCE"))
                    if let recorded, recorded != row.head {
                        gaps.append(EvidenceGap(page: page, batch: row.batch,
                                                what: "\(mode) 的 PROVENANCE rev=\(recorded) 与表里的头 \(row.head) 不符"))
                    } else if recorded == nil, exists(dir) {
                        gaps.append(EvidenceGap(page: page, batch: row.batch,
                                                what: "\(mode) 没有 PROVENANCE —— 无从证明这一格是在哪个头上拍的"))
                    }
                }
            }
        }
        return gaps
    }

    /// 只挑出"这一批产物**在本树里**"的行。
    ///
    /// 为什么要这一道（**RD-58，总工改**）：`.scratch/` 是 gitignore 的 ⇒ 取证产物只存在于
    /// 拍图的那一棵树。上一版 RD-55 的口径是"本树一份 `evidence-*` 都没有才跳"，
    /// 那是**全有或全无**：一条流按需求方要的样子**只补拍变化的那一页**，
    /// 本树就从"整个跳过"翻成"整个都要查"，于是**表里其余每一行都变成红**，
    /// 而红的原因与当次改动无关 —— 既不证明证据存在，也不证明它不存在。
    /// 现在的口径是**逐行按批次判**：批次在本树 ⇒ 那一行四格齐全、rev 对得上，缺一样照旧红；
    /// 批次不在本树 ⇒ 那行不查，但**行名要打印出来**（不许把"没查"读成"查过没事"）。
    static func rowsWithEvidence(_ rows: [Row], batchPresent: (String) -> Bool) -> (checked: [Row], absent: [String]) {
        let hit = rows.filter { batchPresent($0.batch) }
        return (hit, rows.filter { !batchPresent($0.batch) }.map(\.batch))
    }

    func test_everyRowActuallyHasAllFourShotsAtTheHeadItClaims() throws {
        let url = Self.repoRoot.appendingPathComponent(Self.catalogPath)
        let rows = Self.rows(in: try String(contentsOf: url, encoding: .utf8))
        XCTAssertFalse(rows.isEmpty, "表读不出行 ⇒ 下面这条会空转")
        let evidenceRoot = Self.repoRoot.appendingPathComponent(".scratch")
        let scoped = Self.rowsWithEvidence(rows) { batch in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: evidenceRoot.appendingPathComponent(batch).path,
                                                 isDirectory: &isDir) else { return false }
            return isDir.boolValue
        }
        XCTAssertFalse(rows.allSatisfy { $0.batch.isEmpty }, "表里连批次名都没解析出来 ⇒ 这条在空转")
        if scoped.checked.isEmpty {
            throw XCTSkip("这棵树没有表里引用的任何一批产物（\(evidenceRoot.path)；表里 \(rows.count) 行的批次都不在）"
                + " ⇒ 本条只钉「有产物就要齐」，产物生成在哪棵树不归它管")
        }
        let gaps = Self.evidenceGaps(in: scoped.checked, root: evidenceRoot,
                                     exists: { FileManager.default.fileExists(atPath: $0.path) },
                                     provenanceRev: { file in
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            for line in text.split(separator: "\n") {
                if line.hasPrefix("rev=") { return String(String(line.dropFirst(4)).prefix(7)) }
            }
            return nil
        })
        XCTAssertTrue(gaps.isEmpty,
                      "逐页账里有 \(gaps.count) 格证据不成立（口径是深浅 × 顶尾四格齐全，且 rev 对得上）：\n"
                        + gaps.map { "\($0.page) @ \($0.batch)：\($0.what)" }.joined(separator: "\n"))
        let shots = scoped.checked.reduce(0) { $0 + Self.expectedShots(for: $1).count } * Self.evidenceModes.count
        print("【实拍格数】表里 \(rows.count) 行 · 本树有产物 \(scoped.checked.count) 行 → 实查 \(shots) 格，"
            + "不成立的格 \(gaps.count) 处"
            + (scoped.absent.isEmpty ? "" : "；不在本树的批次 \(Set(scoped.absent).count) 个：\(Set(scoped.absent).sorted().joined(separator: " "))"))    }

    // MARK: - 元测试：两个方向都要红过一次

    /// 合成表：两行、第二行管两页。拆成两条元测试共用（50 行的函数上限在这儿）。
    static let syntheticTable = """
        | 页 | 最近一次实拍 | 此后依赖面 |
        |---|---|---|
        | 总览 | `evidence-abc1234-x/` | 无（`git log abc1234..HEAD -- TcoderMonitor/Sources/TcoderMonitor/Views/DashboardView.swift` 空）|
        | Git 洞察 / 贡献者 | `evidence-def5678-y/` | 无（`git log def5678..HEAD -- TcoderMonitor/Sources/TcoderMonitor/Design/ChartTokens.swift` 空）|
        """

    /// 解析器自己：行、页名拆分、以及**省略号写法整行不作数**。
    /// RD-58 的元测试：逐行按批次判这一道**两个方向都要红过一次**。
    /// 只喂合成输入，不碰盘上真产物 —— 这条判据要的正是"批次在不在"这一件事，与图本身无关。
    func test_rowsWithEvidenceChecksOnlyRowsWhoseBatchIsPresent() throws {
        let rows = Self.rows(in: Self.syntheticTable)
        XCTAssertEqual(rows.count, 2, "夹具自检：合成表该读出两行")
        let firstOnly = Self.rowsWithEvidence(rows) { $0 == "evidence-abc1234-x" }
        XCTAssertEqual(firstOnly.checked.map(\.batch), ["evidence-abc1234-x"],
                       "只有一批产物时，另那行不许被拖成红（RD-58 修的就是这个）")
        XCTAssertEqual(firstOnly.absent, ["evidence-def5678-y"], "没查的行必须被点名，不许静默")

        let nonePresent = Self.rowsWithEvidence(rows) { _ in false }
        XCTAssertTrue(nonePresent.checked.isEmpty, "一批都不在还去查，等于把「没看见」当成「通过」")
        XCTAssertEqual(Set(nonePresent.absent), Set(["evidence-abc1234-x", "evidence-def5678-y"]))

        // 反向：两批都在 ⇒ 两行都要查（这条判据不许被"按批次跳过"变成永真绿）。
        let allPresent = Self.rowsWithEvidence(rows) { _ in true }
        XCTAssertEqual(allPresent.checked.count, 2, "批次齐的时候它必须逐行钉，一格都不能少查")
        XCTAssertTrue(allPresent.absent.isEmpty)
    }

    func test_tableParserReadsRowsAndRefusesAbbreviatedPaths() {
        let found = Self.rows(in: Self.syntheticTable)
        XCTAssertEqual(found.count, 2, "两行都该解析出来（第二行管两页）")
        XCTAssertEqual(found[1].pages, ["Git 洞察", "贡献者"], "一行管多页时页名要拆开")
        XCTAssertEqual(found[1].paths,
                       ["TcoderMonitor/Sources/TcoderMonitor/Design/ChartTokens.swift"])
        XCTAssertEqual(found[1].batch, "evidence-def5678-y", "批次名要留着，查格数靠它")

        // 省略号写法不成判据：留着它，判据会去查一个不存在的路径（永远为空、永远绿）；
        // 整行不作数，那一页就从名册里消失、当场判红。
        let abbreviated = Self.rows(
            in: "| 总览 | x | 无（`git log 1f3ac55..HEAD -- …DashboardHero.swift` 空）|")
        XCTAssertTrue(abbreviated.isEmpty, "省略号路径必须让整行不作数：\(abbreviated)")
        XCTAssertFalse(Self.pagesWithoutRows(in: found).isEmpty,
                       "合成表只覆盖 3 页，名册必须报出缺的那些页")
    }

    /// 过期判据两个方向：动了的必须抓到，谁都没动的不许乱咬。
    func test_staleRulerFlagsOnlyRowsWhoseDependenciesMoved() {
        let found = Self.rows(in: Self.syntheticTable)
        let touched: (String, [String]) -> [String] = { head, paths in
            head == "def5678" ? [paths.first ?? "?"] : []
        }
        let expired = Self.stale(found, log: touched)
        XCTAssertEqual(expired.count, 1, "只有那一行该被判过期：\(expired)")
        XCTAssertTrue(expired[0].contains("Git 洞察"), "报的要能指到页：\(expired)")
        XCTAssertTrue(Self.stale(found, log: { _, _ in [] }).isEmpty,
                      "全绿的仓库被判过期 ⇒ 这条判据会逼人删掉它")
    }
}
