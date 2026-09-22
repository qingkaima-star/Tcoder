import Foundation
import XCTest

/// OWNER: 总工（设计总监线）—— 九页实拍复核的**过期判据**。
///
/// 读 `docs/界面-乱的清单.md` 里那张「每页最近一次实拍在哪个头」的表，
/// 对每一行把它自己写出的那条 `git log <头>..HEAD -- <依赖面>` 真的跑一遍，
/// **非空即判红**：那一页的实拍已经过期，屏上可能有没人看过的变化。
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

        var expired: [String] = []
        for row in found {
            let touched = try Self.runGitLog(head: row.head, paths: row.paths)
            if !touched.isEmpty {
                expired.append("\(row.pages.joined(separator: "/")) 停在 \(row.head)，"
                             + "此后动了 \(touched.count) 个文件：\(touched.prefix(3).joined(separator: " "))")
            }
        }
        XCTAssertTrue(expired.isEmpty,
                      "这些页的实拍已经过期，屏上可能有没人看过的变化 —— 重拍那一页并更新表里的头：\n"
                    + expired.joined(separator: "\n"))
        print("【实拍新鲜度】表里 \(found.count) 行、覆盖 \(Set(found.flatMap(\.pages)).count) 页 → 过期 0 行")
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

    func test_everyRowActuallyHasAllFourShotsAtTheHeadItClaims() throws {
        let url = Self.repoRoot.appendingPathComponent(Self.catalogPath)
        let rows = Self.rows(in: try String(contentsOf: url, encoding: .utf8))
        XCTAssertFalse(rows.isEmpty, "表读不出行 ⇒ 下面这条会空转")
        let evidenceRoot = Self.repoRoot.appendingPathComponent(".scratch")
        // RD-55（总工改）：`.scratch/` 是 gitignore 的 ⇒ 取证产物只存在于**拍图的那棵树**。
        // 这一格的职责是「账里声称有证据，证据就得齐、rev 就得对」，不是「每棵树都得自己拍过一遍」；
        // 后者让任何非拍图树（别人的工作树、CI、另一台机器）门禁必红，而红的原因与当次改动无关 ——
        // 那既不证明证据存在，也不证明它不存在，只是把一条好守卫变成落地路障。
        // 所以：**一棵树里一份 evidence-* 都没有 ⇒ 显式跳过并点名路径**；
        // 目录只要在，就照原样逐格钉（少一张图、rev 不符、缺 PROVENANCE 都仍然红）。
        let hasAnyEvidence = ((try? FileManager.default.contentsOfDirectory(atPath: evidenceRoot.path)) ?? [])
            .contains { $0.hasPrefix("evidence-") }
        if hasAnyEvidence == false {
            throw XCTSkip("这棵树没有取证产物（\(evidenceRoot.path) 下无 evidence-*）"
                + " ⇒ 本条只钉「有产物就要齐」，产物生成在哪棵树不归它管")
        }
        let gaps = Self.evidenceGaps(in: rows, root: evidenceRoot,
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
        let shots = rows.reduce(0) { $0 + Self.expectedShots(for: $1).count } * Self.evidenceModes.count
        print("【实拍格数】表里 \(rows.count) 行 → 实际查 \(shots) 格，全在、rev 全对")
    }

    // MARK: - 元测试：两个方向都要红过一次

    /// 合成表：两行、第二行管两页。拆成两条元测试共用（50 行的函数上限在这儿）。
    static let syntheticTable = """
        | 页 | 最近一次实拍 | 此后依赖面 |
        |---|---|---|
        | 总览 | `evidence-abc1234-x/` | 无（`git log abc1234..HEAD -- TcoderMonitor/Sources/TcoderMonitor/Views/DashboardView.swift` 空）|
        | Git 洞察 / 贡献者 | `evidence-def5678-y/` | 无（`git log def5678..HEAD -- TcoderMonitor/Sources/TcoderMonitor/Design/ChartTokens.swift` 空）|
        """

    /// 解析器自己：行、页名拆分、以及**省略号写法整行不作数**。
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
