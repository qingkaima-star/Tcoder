import Foundation
import XCTest
@testable import TcoderMonitor

/// OWNER: WS-R37 评分支路可达性（分支 `ws/rd27-reach`）—— 本族夹具与**盘上独立真值**。
///
/// 这一族只回答一个问题：**那几条「缺证据不给分」的评分支路，真项目走不走得到。**
/// 所以夹具必须满足两条，缺一条整个族的结论就不成立：
///
/// 1. **不经手搓 `HealthInputs`**。`ScoreEvidenceFloorTests` 那一族证的是「评分器在那个数的
///    基础上会说什么」，本族证的是「真分析器会不会长出那个数」。入口只有 `CLIScan`
///    （与 GUI 同一批分析器、同一个 `WeightedHealthScorer`）与 `GuiSideReportReplay`。
/// 2. **夹具根在被测仓库之外，祖先链上没有任何 `.git`**。`ShellGitAnalyzer.resolveRepository`
///    向上爬 6 层、`LogProjectIdentity.projectAnchor` 向上爬 8 层 —— 只要夹具落在
///    `/Users/one/Documents/Tcoder`（含各工作树的 `.scratch/`）任何一层，
///    「不是仓库」那一格就永远造不出来，Git 两维会读到**宿主仓库**的历史（本仓踩过这个坑）。
///    另一头 `/tmp` 里的**孤儿夹具**会喂假绿，所以这里每次开一个带 UUID 的唯一子目录、
///    事前拒绝已存在、事后自清，并把「盘上到底有什么」独立数一遍交给 `discrepancies` 对账。
enum R37ReachFixture {

    /// 本族夹具的产品名/署名前缀（唯一化，避免与本机真实 App 的崩溃报告撞名）。
    static let tokenPrefix = "R37Reach"

    // MARK: - 沙箱

    /// 建一个**本次专属**的夹具根；祖先链上有 `.git` 就直接判败（不许静默造出一个假形状）。
    static func makeSandbox(file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tcoder-r37-reach-\(UUID().uuidString)", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path),
                       "唯一子目录竟然已存在 ⇒ 可能是上一趟的孤儿夹具，拒绝复用", file: file, line: line)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let holder = firstGitAncestor(of: root) {
            XCTFail("夹具根 \(root.path) 的祖先 \(holder) 带 .git ⇒ Git 两维会读到宿主仓库，"
                    + "「不是仓库」与「零提交」这两格都造不出真形状", file: file, line: line)
        }
        return root
    }

    /// 向上找到第一枚 `.git`（含 worktree 的 `.git` 文件形式）；没有返回 nil。
    static func firstGitAncestor(of url: URL, limit: Int = 10) -> String? {
        var cursor = url
        for _ in 0..<limit {
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path { return nil }
            if FileManager.default.fileExists(atPath: parent.appendingPathComponent(".git").path) {
                return parent.path
            }
            cursor = parent
        }
        return nil
    }

    /// 一个「别的路都正常」的项目底座：清单给日志一个产品名，源码给代码那一路一点输入。
    static func makeProject(named name: String, under sandbox: URL) throws -> URL {
        let root = sandbox.appendingPathComponent(name, isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: root.appendingPathComponent("Sources", isDirectory: true),
                                    withIntermediateDirectories: true)
        try manager.createDirectory(at: root.appendingPathComponent("Logs", isDirectory: true),
                                    withIntermediateDirectories: true)
        try "name: \"\(name)\"\n".write(to: root.appendingPathComponent("Package.swift"),
                                        atomically: true, encoding: .utf8)
        for index in 1...6 {
            let body = """
            import Foundation

            enum R37Part\(index) {
                /// 说明：第 \(index) 块的作用。
                static func value() -> Int { \(index) }
            }

            """
            try body.write(to: root.appendingPathComponent("Sources/R37Part\(index).swift"),
                           atomically: true, encoding: .utf8)
        }
        return root
    }

    // MARK: - 真 git 仓库（身份钉在夹具内，不继承宿主与全局配置）

    /// 建一个有 `count` 笔提交的仓库，作者轮流署名，提交时间每天错开一笔（节奏档要够真）。
    /// ⚠ 署名只认 **`GIT_AUTHOR_NAME` 环境变量**：`-c user.name=` 会被它盖掉
    ///   （实测：不这么写，12 笔全落在默认身份上，「多人/单人」那一格就造不出真形状）。
    static func makeRepository(at root: URL, count: Int, authors: [String] = ["R37 Solo"]) throws {
        try git(["init", "-q", "-b", "main"], in: root)
        for index in 1...max(1, count) {
            let name = authors[(index - 1) % authors.count]
            try "commit \(index) by \(name)\n".appendFile(to: root.appendingPathComponent("history.txt"))
            try git(["add", "-A"], in: root)
            let stamp = DateFormatter.r37CommitStamp(daysAgo: count - index)
            try git(["-c", "commit.gpgsign=false", "-c", "core.hooksPath=", "commit", "-qm",
                     "commit \(index) by \(name)"], in: root,
                    environment: ["GIT_AUTHOR_DATE": stamp, "GIT_COMMITTER_DATE": stamp,
                                  "GIT_AUTHOR_NAME": name, "GIT_COMMITTER_NAME": name,
                                  "GIT_AUTHOR_EMAIL": email(of: name), "GIT_COMMITTER_EMAIL": email(of: name)])
        }
    }

    /// 署名 → 邮箱（同一署名恒得同一邮箱，否则 `authorStats` 会按邮箱拆成两个人）。
    static func email(of name: String) -> String {
        let local = name.lowercased().replacingOccurrences(of: " ", with: ".")
        return "\(local)@tcoder.local"
    }

    /// `git init` 之后什么都不提交 —— 工单形状 ③ 的字面版本。
    static func makeEmptyRepository(at root: URL) throws {
        try git(["init", "-q", "-b", "main"], in: root)
    }

    /// 上游真值：`rev-list --count HEAD`（含合并），失败时把 git 的原文交回来。
    static func revListCount(at root: URL) -> String {
        (try? gitOutput(["rev-list", "--count", "HEAD"], in: root)) ?? "命令失败"
    }

    /// 独立真值：这个目录到底是不是仓库（自己起一条 git 问，不信被测那一路的结论）。
    static func isGitRepository(at root: URL) -> Bool {
        let answer = (try? gitOutput(["rev-parse", "--show-toplevel"], in: root)) ?? "命令失败"
        return answer.hasPrefix("/") && answer.contains("非零退出") == false
    }

    /// 上游真值：最新一笔的作者日期原文（`%aI`）。
    static func authorDateStamp(at root: URL) -> String {
        (try? gitOutput(["log", "-1", "--pretty=format:%aI"], in: root)) ?? "命令失败"
    }

    // MARK: - git 进程（身份与签名钉死在命令行里，不读宿主配置）

    /// 跑一条 git，失败即判败（夹具没搭起来不许继续往下断言）。
    @discardableResult
    static func git(_ args: [String], in root: URL, environment: [String: String] = [:]) throws -> [String] {
        let (status, output) = try run(args, in: root, environment: environment)
        XCTAssertEqual(status, 0, "git \(args.joined(separator: " ")) 失败：\(output.prefix(200))")
        return output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// 只读的一条 git（上游真值用）；非零退出把 stderr 原文交出去，不猜一个数。
    static func gitOutput(_ args: [String], in root: URL) throws -> String {
        let (status, output) = try run(args, in: root, environment: [:])
        return status == 0 ? output.trimmingCharacters(in: .whitespacesAndNewlines)
                           : "git \(args.first ?? "") 非零退出（\(status)）：\(output.prefix(160))"
    }

    private static func run(_ args: [String], in root: URL,
                            environment: [String: String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        // 全局/系统配置一律不读：宿主机器上的 user.name、commit.gpgsign、init.defaultBranch
        // 都不该决定夹具形状（否则换台机器结论就变，正是「继承宿主 git 身份」那一类假缺陷）。
        process.arguments = ["-c", "core.excludesFile=/dev/null",
                             "-c", "init.defaultBranch=main"] + args
        process.currentDirectoryURL = root
        var env = ProcessInfo.processInfo.environment
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_SYSTEM"] = "/dev/null"
        env["GIT_AUTHOR_NAME"] = "R37 Fixture"
        env["GIT_AUTHOR_EMAIL"] = "r37@tcoder.local"
        env["GIT_COMMITTER_NAME"] = "R37 Fixture"
        env["GIT_COMMITTER_EMAIL"] = "r37@tcoder.local"
        environment.forEach { env[$0] = $1 }
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    // MARK: - 日志与崩溃报告（全部复用仓里已有的那把尺子）

    /// 一份真形状 `.ips`（行数由 `R11DenominatorFixture.ipsText` 撑起来）。
    static func writeCrashReport(in directory: URL, product: String, lines: Int = 400) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = DateFormatter.r37FileName.string(from: Date())
        let url = directory.appendingPathComponent("\(product)-\(stamp).ips")
        try R11DenominatorFixture.ipsText(procName: product, incident: UUID().uuidString,
                                          eventDate: Date(), totalLines: lines)
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 一份真日志（`lines` 行、`every` 行一条 ERROR；0 = 全 INFO）。
    /// 参数是**项目根**：`R11DenominatorFixture.writeLog` 自己会往 `<项目根>/Logs/app.log` 落，
    /// 传子目录进去就会变成 `Logs/Logs/app.log`（实测踩过）。
    @discardableResult
    static func writeLog(under project: URL, lines: Int, every: Int) throws -> URL {
        try R11DenominatorFixture.writeLog(to: project, lines: lines, every: every)
    }

    // MARK: - 盘上独立真值（不经过任何被测代码）

    /// 盘上：每个日志/崩溃文件**真的有**多少行（数 0x0A，`wc -l` 同一口径）。
    static func diskLineCounts(of urls: [URL]) throws -> [String: Int] {
        var result: [String: Int] = [:]
        for url in urls { result[url.lastPathComponent] = try R11DenominatorFixture.newlineCount(of: url) }
        return result
    }

    /// 分析器读数与盘上真值对账，交回**每一条不合**。空数组 = 这份读数是夹具喂出来的。
    ///
    /// 这一枚是本族的「喂了假输入就判败」闸门：它同时检查
    /// ① 盘上有的文件分析器必须认到（没认到＝上游根本没读夹具，后面的断言都是空的）、
    /// ② 每个文件的行数必须与盘上一字相同、
    /// ③ `totalLinesScanned` 必须等于**非崩溃**那些文件的盘上行数之和（RD-46b 的分母口径）。
    static func discrepancies(logs: LogSummary, onDisk: [(url: URL, lines: Int)]) -> [String] {
        var problems: [String] = []
        let scannedByName = Dictionary(grouping: logs.scannedFiles) {
            URL(fileURLWithPath: $0.path).lastPathComponent
        }.mapValues { $0.reduce(0) { $0 + $1.lineCount } }
        var denominatorFromDisk = 0
        for entry in onDisk {
            let name = entry.url.lastPathComponent
            guard let read = scannedByName[name] else {
                problems.append("盘上有 \(name)（\(entry.lines) 行），分析器却没读到 ⇒ 夹具没喂进去")
                continue
            }
            if read != entry.lines { problems.append("\(name) 盘上 \(entry.lines) 行 · 分析器 \(read) 行") }
            if !name.lowercased().hasSuffix(".ips") { denominatorFromDisk += entry.lines }
        }
        if logs.totalLinesScanned != denominatorFromDisk {
            problems.append("分母 \(logs.totalLinesScanned) ≠ 盘上非崩溃日志行数之和 \(denominatorFromDisk)")
        }
        return problems
    }
}

private extension String {
    /// 追加写（夹具要往同一个文件里连写多笔，好让 `git add -A` 每笔都有活干）。
    func appendFile(to url: URL) throws {
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(Data(utf8))
        } else {
            try write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

extension DateFormatter {
    /// `.ips` 的文件名时间戳：苹果那一套是 `yyyy-MM-dd-HHmmss`，归属判定按 `-20xx-` 切主名，
    /// 换个格式就会掉进「只有文件名像」那一档而不是「确认崩溃」。
    static let r37FileName: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()

    /// 提交日期（`GIT_AUTHOR_DATE` 吃 ISO 8601）。逐笔错开一天，避免「首末同一瞬间」。
    static func r37CommitStamp(daysAgo: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss+0000"
        return formatter.string(from: Date().addingTimeInterval(-Double(daysAgo) * 86_400))
    }
}
