import Foundation

/// 无头模式的命令词表与参数解析。
/// 由 `TcoderMonitorApp.init()` 调用 —— 这也是它出现在产品代码路径上的凭证。
enum CLIRouter {

    /// 只有 argv[1] **精确等于**这些词才进无头模式。
    ///
    /// 为什么必须这么窄：现有取证链会给 GUI 传 `-ApplePersistenceIgnoreState YES`，
    /// LaunchServices 起 App 会传 `-psn_…`。它们都以 `-` 开头、都不在这张表里，
    /// 于是"命中即 CLI、不命中即 GUI"，没有第三种猜法。
    static let headlessWords: Set<String> = ["scan", "score", "doctor", "--help", "-h", "help", "--version"]

    static func isHeadlessInvocation(argv: [String]) -> Bool {
        guard argv.count >= 2 else { return false }
        return headlessWords.contains(argv[1])
    }

    static func parse(argv: [String]) -> CLIParseResult {
        guard let word = argv[safe: 1] else { return .usage("缺少子命令。") }
        switch word {
        case "--help", "-h", "help": return .request(CLIRequest(mode: .help))
        case "--version": return .request(CLIRequest(mode: .version))
        case "scan": return parseTarget(.scan, word: word, argv: argv)
        case "score": return parseTarget(.score, word: word, argv: argv)
        case "doctor": return parseTarget(.doctor, word: word, argv: argv)
        default: return .usage("未知子命令：\(word)")
        }
    }

    private static func parseTarget(_ mode: CLIMode, word: String, argv: [String]) -> CLIParseResult {
        var req = CLIRequest(mode: mode)
        var index = 2
        while index < argv.count {
            let token = argv[index]
            switch token {
            case "--allow-network": req.allowNetwork = true
            case "--compact": req.compact = true
            case _ where token.hasPrefix("--out="):
                req.outPath = String(token.dropFirst("--out=".count))
            case _ where token.hasPrefix("--log="):
                let logPath = String(token.dropFirst("--log=".count))
                // 不存在就直接拒绝：悄悄收下会让读数的"运行稳定性缺席"看起来像项目真没日志，
                // 而实情是命令行打错了一个字母。
                guard FileManager.default.fileExists(atPath: logPath) else {
                    return .usage("--log 指向的文件不存在：\(logPath)")
                }
                req.logPaths.append(logPath)
            case _ where token.hasPrefix("--window-days="):
                let raw = String(token.dropFirst("--window-days=".count))
                guard let days = Int(raw), days > 0 else {
                    return .usage("--window-days 要是一个正整数：\(raw)")
                }
                req.windowDays = days
            case _ where token.hasPrefix("-"):
                return .usage("未知参数：\(token)")
            case _ where req.path == nil:
                req.path = token
            case _ where req.path != nil:
                return .usage("只接受一个目标路径，多出来的是：\(token)")
            default:
                return .usage("无法解析的参数：\(token)")
            }
            index += 1
        }
        // doctor 可以不带路径（纯自检）；scan / score 不带路径没有意义。
        if req.path == nil && mode != .doctor { return .usage("\(word) 需要一个目标路径。") }
        return .request(req)
    }

    /// 解析层就能定的退出码；`nil` 表示"参数没问题，继续去跑"。
    static func exitCode(for result: CLIParseResult) -> CLIExit? {
        switch result {
        case .usage: return .usage
        case let .request(req):
            switch req.mode {
            case .help, .version: return .ok
            case .scan, .score, .doctor: return nil
            }
        }
    }

    /// 入口：跑完返回退出码，调用方负责 `exit()`。
    static func main(argv: [String]) -> Int32 {
        let parsed = parse(argv: argv)
        if let early = exitCode(for: parsed) {
            announce(parsed)
            return early.rawValue
        }
        guard case let .request(req) = parsed else { return CLIExit.usage.rawValue }
        return req.mode == .doctor ? runDoctor(req) : runReport(req)
    }

    private static func announce(_ result: CLIParseResult) {
        switch result {
        case let .usage(problem):
            CLIOutput.fail(problem)
            CLIOutput.line(usageText)
        case let .request(req):
            CLIOutput.line(req.mode == .version ? CLIConfig.versionLine : usageText)
        }
    }

    private static func runReport(_ req: CLIRequest) -> Int32 {
        // 「路径不可用」是**根本没开跑**那一档，必须同步回，不许借道并发池与信号量：
        // 上一版把它丢进 `Task.detached` 里判，真二进制上那一档会连着启动流程一起卡住
        // （回归测试见 `CLIProcessTests.test_realProcess_unusablePathExitsThreeFast`）。
        guard let target = req.path, CLIScan.validatedURL(for: target) != nil else {
            CLIOutput.fail("路径不可用：\(req.path ?? "")（不存在、不是目录或不可读）")
            return CLIExit.badPath.rawValue
        }
        let scan = CLIScan()
        var outcome = CLIScanOutcome(report: nil, exit: .allFailed, problem: "未开跑")
        let gate = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            outcome = await scan.outcome(path: req.path ?? "", allowNetwork: req.allowNetwork,
                                         extraLogPaths: req.logPaths, windowDays: req.windowDays)
            gate.signal()
        }
        if gate.wait(timeout: .now() + CLIConfig.hardTimeout) == .timedOut {
            // 「超时未回」和「这一路没数据」是两件事，混为一谈就成了假读数。
            CLIOutput.fail("超过 \(Int(CLIConfig.hardTimeout)) 秒未回，本次不出结论。")
            return CLIExit.allFailed.rawValue
        }
        guard let report = outcome.report else {
            CLIOutput.fail(outcome.problem ?? "被扫路径不可用。")
            return outcome.exit.rawValue
        }
        guard req.mode == .scan else {
            // `windowDays` 必须一路传到崩溃那句脚注：本次扫描用的是 `--window-days`，
            // 读数里那句「最近 N 天为窗口」要是写死一个默认值就自相矛盾（RD-60 的 CLI 出口）。
            CLIOutput.line(CLIScoreText.render(report, exit: outcome.exit, windowDays: req.windowDays))
            return outcome.exit.rawValue
        }
        let json = (try? CLIScan.json(report, compact: req.compact)) ?? "{}"
        if let out = req.outPath { CLIOutput.write(json, to: out) }
        CLIOutput.line(json)
        return outcome.exit.rawValue
    }

    /// `doctor` 的"我是谁"那几行。抽成函数只为它能被断言 ——
    /// 这一族文字存在的意义就是：**相信任何读数之前，先知道自己用的是哪一版尺子。**
    /// 立 R10 第 0 条的现场：`ScanProvenance.rulesVersionStamp` 已经落进报告与 `score` 输出，
    /// 但 `doctor` 只打构建口径与 bundle，"我在用哪一版判据"这一格在它最该出现的地方缺席。
    static func doctorIdentityLines() -> [String] {
        ["  二进制 = \(CLIConfig.binaryPath)",
         "  构建口径 = \(CLIConfig.buildConfiguration)",
         "  bundle = \(CLIConfig.bundleIdentity)",
         "  检测规则戳 = \(ScanProvenance.rulesVersionStamp)",
         "  报告结构版本 = v\(ScanProvenance.currentSchemaVersion)"]
    }

    private static func runDoctor(_ req: CLIRequest) -> Int32 {
        CLIOutput.line("tcoder doctor")
        for line in doctorIdentityLines() { CLIOutput.line(line) }
        guard let raw = req.path else { return CLIExit.ok.rawValue }
        guard let url = CLIScan.validatedURL(for: raw) else {
            CLIOutput.fail("路径不可用：\(raw)（不存在、不是目录或不可读）")
            return CLIExit.badPath.rawValue
        }
        CLIOutput.line("  目标 = \(url.path)")
        CLIOutput.line("  是 Git 仓库 = \(CLIScan.looksLikeRepository(url) ? "是" : "否")")
        return CLIExit.ok.rawValue
    }

    static var usageText: String {
        """
        用法：
          tcoder scan  <path> [--out=<file>] [--compact] [--allow-network]      输出 ProjectReport JSON
          tcoder score <path> [--allow-network] [--log=<file>…] [--window-days=<n>]   只打读数（失败路在前）
          tcoder doctor [<path>]                                             自检：我在用哪个二进制、目标是否可读

        退出码：0 五路全成 / 2 报告可用但有路失败 / 3 路径不可用 / 4 五路全失败或超时 / 64 用法错
        入参与 GUI 逐字对齐：ScanOptions.default、allowNetwork=false（除非 --allow-network）、
          withinDays=7（除非 --window-days）、extraLogURLs=[]（除非 --log=，可重复 = 界面的「附加日志文件」）
        无头模式不写盘：不碰 TCODER_SUPPORT_DIR、projects.json、reports/、score-history.json
        """
    }
}

enum CLIMode: Equatable {
    case scan, score, doctor, help, version
}

struct CLIRequest: Equatable {
    var mode: CLIMode
    var path: String?
    var outPath: String?
    var compact = false
    var allowNetwork = false
    /// 对应界面的「附加日志文件」：界面能手动指，CLI 少这个入口就会把"没找到约定位置的日志"
    /// 报成"这项目没有日志"。可重复。
    var logPaths: [String] = []
    /// 对应 `AppState.logWindowDays`，不传就用 GUI 的默认值，免得两条路各一套窗口口径。
    var windowDays = CLIScan.logWindowDays
}

enum CLIParseResult: Equatable {
    case request(CLIRequest)
    case usage(String)
}

enum CLIExit: Int32, Equatable {
    case ok = 0
    case partial = 2
    case badPath = 3
    case allFailed = 4
    case usage = 64

    /// 五路里失败几路 → 哪一档。**没有"静默成功"这一档。**
    static func failedSections(_ count: Int) -> CLIExit {
        if count <= 0 { return .ok }
        if count >= CLIScan.sectionLabels.count { return .allFailed }
        return .partial
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
