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
        var head: String
        var paths: [String]
    }

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
            out.append(Row(pages: pages, head: String(line[headRange]), paths: paths))
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

    // MARK: - 元测试：两个方向都要红过一次

    func test_freshnessRulerCatchesStaleRowsAndMissingPages() {
        let table = """
        | 页 | 最近一次实拍 | 此后依赖面 |
        |---|---|---|
        | 总览 | `evidence-abc1234-x/` | 无（`git log abc1234..HEAD -- TcoderMonitor/Sources/TcoderMonitor/Views/DashboardView.swift` 空）|
        | Git 洞察 / 贡献者 | `evidence-def5678-y/` | 无（`git log def5678..HEAD -- TcoderMonitor/Sources/TcoderMonitor/Design/ChartTokens.swift` 空）|
        """
        let found = Self.rows(in: table)
        XCTAssertEqual(found.count, 2, "两行都该解析出来（第二行管两页）")
        XCTAssertEqual(found[1].pages, ["Git 洞察", "贡献者"], "一行管多页时页名要拆开")
        XCTAssertEqual(found[1].paths,
                       ["TcoderMonitor/Sources/TcoderMonitor/Design/ChartTokens.swift"])

        // ① 依赖面动过 ⇒ 必须判过期。
        let touched: (String, [String]) -> [String] = { head, paths in
            head == "def5678" ? ["\(paths.first ?? "?") 改了"] : []
        }
        let expired = Self.stale(found, log: touched)
        XCTAssertEqual(expired.count, 1, "只有那一行该被判过期")
        XCTAssertTrue(expired[0].contains("Git 洞察"), "报的要能指到页：\(expired)")

        // ② 谁都没动 ⇒ 不许误报。
        XCTAssertTrue(Self.stale(found, log: { _, _ in [] }).isEmpty,
                      "全绿的仓库被判过期 ⇒ 这条判据会逼人删掉它")

        // ③ 省略号写法不成锚：那行必须**不被解析**，于是那一页在名册里消失 ⇒ 判红。
        let abbreviated = Self.rows(in: "| 总览 | x | 无（`git log 1f3ac55..HEAD -- …DashboardHero.swift` 空）|")
        XCTAssertTrue(abbreviated.isEmpty,
                      "省略号写法必须**整行不作数**：留着它，判据会去查一个不存在的路径"
                    + "（永远为空、永远绿）；整行不作数，那一页就从名册里消失、当场判红")
        XCTAssertFalse(Self.pagesWithoutRows(in: Self.rows(in: table)).isEmpty,
                       "合成表只覆盖 3 页，名册必须报出缺的那些页")
    }
}
