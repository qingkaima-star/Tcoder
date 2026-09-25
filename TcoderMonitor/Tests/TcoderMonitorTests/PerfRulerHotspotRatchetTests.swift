import XCTest
@testable import TcoderMonitor

/// OWNER: WS-X5（接手 WS-X2 RuntimeServices）。
///
/// **性能两把尺子自己的**热点棘轮：`scripts/perf_harness.sh`、`scripts/perf_selfcheck.sh`、
/// `scripts/perf_preflight.sh`、`scripts/trace_report.py` 与它的五个 python 兄弟
/// （解析层两件、`perf_trace_threads.py`、`perf_trace_summary.py`、`perf_framepulse.py`）
/// ——函数圈复杂度 / 函数行数 / 文件行数只减不增。
///
/// 为什么要有这一条：这两把尺子的输出是**别人的验收依据**（AGENTS.md 第四轮红线 1
/// 「帧率结论只认 perf_harness.sh 的读数」），而它们恰好是全仓 CC 最高的一批函数所在处
/// （`cmd_summary` CC 63、`cmd_selfcheck` CC 44）。尺子烂在没人复核的那一天的话，
/// 之后所有"从 X 降到 Y"的结论都无据可查。
///
/// 尺子不是我自己写的：直接调产品侧的 `SourceTreeScanner` + `ComplexityEngine`，
/// 与 `LogHotspotRatchetTests`（同一下属包的姊妹门）、自扫报告同一个函数、同一把尺子。
///
/// 阈值写死为字面量，口径来源与 `LogHotspotRatchetTests` 一字一样：
/// - 16 = `SelfScanHarnessCase.complexFunctionBar`；
/// - 50 = 本轮收口判据「函数 ≤ 50 行」；
/// - 800 = `SelfScanHarnessCase.toolHighFileLines`（分母含 `.sh`/`.py`，`ceiling = 0`）。
/// **要放宽必须先向总工说明理由。**
final class PerfRulerHotspotRatchetTests: XCTestCase {

    static let complexityBar = 16
    static let functionLineBar = 50
    static let fileLineBar = 800

    /// 九把尺子文件（`scripts/` 下）。`perf_framepulse.py` 与两个解析层模块一起纳入，
    /// 是因为 `cmd_selfcheck` 第 1 项要求"三层文件齐全"——它们同生共死。
    ///
    /// 后三名（WS-X6 规模债切片，2026-09-21）不是新写的尺子，是**从前三把里搬出来的**：
    /// `perf_trace_threads.py` / `perf_trace_summary.py` 自 `trace_report.py` 搬出，
    /// `perf_preflight.sh` 自 `perf_harness.sh` 搬出。不点名它们，本门的分母会从 101 个函数
    /// 静默掉到 67 个——尺子照样"绿"，只是不再量那 34 个函数。
    /// **搬出去的文件必须继续被量着**，否则"按职责拆文件"就等价于"拆到守卫看不见的地方"。
    ///
    /// 又漏了一次、又是我自己造成的：`perf_provenance.sh`（今早自 preflight/verify 搬出）
    /// 与 `perf_probes.sh`（2026-09-21 探针族自 preflight 搬出，为的是还 400 行口径）
    /// 都没点进来。这两把尺子量的是"产物身份"和"有没有人在动"——正好是最不该看不见的那两维。
    /// 第三次的同一个坑是今晚自己又踩的：`perf_switch.sh`（switch 档为还 400 行口径搬出）。
    /// ⇒ 规矩写在这里没用，**清单不会自己长大**；搬文件那一笔必须同批改这个集合。
    static let rulerScripts: Set<String> = [
        "perf_harness.sh", "perf_selfcheck.sh", "perf_preflight.sh", "trace_report.py",
        "perf_trace_xml.py", "perf_trace_metrics.py", "perf_trace_threads.py",
        "perf_trace_summary.py", "perf_framepulse.py",
        "perf_provenance.sh", "perf_probes.sh", "perf_switch.sh",
        "perf_pulse.sh",
        // 2026-09-21：`perf_selfcheck.sh` 涨到 835 行撞 ≤800 棘轮，按"拆开它、不拧阈值"
        // 把 27 项反例按主题搬进下面三块。**搬走的名额必须继续被量**——不然"拆"就成了
        // 给新文件免检的通道（这一条教训来自 `X3TestSizeAuditTests` 那次拆文件把守卫拆丢）。
        "perf_selfcheck_ruler_shapes.sh", "perf_selfcheck_gates.sh",
        "perf_selfcheck_eligibility.sh",
        // 2026-09-22：新增的"谁可能漏下孤儿实例"清单（只读、不判别家）。
        // 新尺子必须一进门就被量 —— 否则"新建文件"本身就是免检通道（同一族的教训见上面那段）。
        "perf_launcher_audit.sh",
        // 2026-09-23：包 5（补测改动前基线）新写的 rev 树准备器。新建的尺子必须当场被量，
        // 否则"新建文件"本身就是免检通道（同一族教训见上面 09-21/09-22 那两段）。
        "perf_measure_rev.sh",
        // 09-23 同一条规矩的第二次自犯：新写的"同档取值一致性"尺子差点没点进来。
        "perf_trio_agreement.py",
        // 09-23 中午：这条分支把自己撑过了「巨大文件 400 行」口径（preflight 448、gates 587、
        // eligibility 500、harness 454、summary 413），按"拆文件才是修复"搬出五片。
        // **搬出来的每一片都照样要点名进来**——拆文件如果顺手免检，那拆本身就是新的通道
        // （这条教训在上面 09-21 那段注释里已经写过一次，今天是第二次用到它）。
        "perf_measure_io.sh", "perf_report.sh", "perf_trace_frames.py",
        "perf_selfcheck_launchers.sh", "perf_selfcheck_tables.sh",
        // 09-24 第七维·预热：`preflight_context` 涨到 410 行撞 400 口径，按"拆文件才是修复"
        // 搬出 `perf_warmup.sh`。**搬出来的那片照样要点名**——第四次用这条教训（前三次见上面注释）。
        "perf_warmup.sh",
        // 09-24 同一条规矩的第五次：`app-update` 三口径（28/17/16）收成一条规则，
        // 从 `perf_trace_metrics.py` 搬出 `perf_update_caliber.py`（那文件当时 408 行撞 400 口径）。
        // 搬出来的判据照样要点名进分母——不点名就等于给它开了免检通道。
        "perf_update_caliber.py",
        // 09-24 同一天第六次：`phase_blame` 加了第三路输入后 CC 涨到 18（门 CC<16），
        // 按"拆，不抬线"把归因判据层搬进 `perf_blame_caliber.py`（一格一个函数）。搬出来必须点名。
        "perf_blame_caliber.py",
        // 09-25 包 45/46：「同树只许一条测量链」这道闸与归属行的有界显示搬成库文件
        // （排程器本体不可 source——一 source 就开始等窗口，反例点不到函数）。
        // 新建文件必须当场被量：这是这条规矩第五次被用到（前面四次都写在上面上面的注释里）。
        "perf_chain_guard.sh", "perf_selfcheck_chain.sh",
        // 09-25 缺陷 #56 的根治：一批 T2 测量的驱动棒原来一趟一份躺在 `.scratch/`（无 trap、不在任何尺子射程内），
        // 搬成 `scripts/perf_run_batch.sh` 之后才归第 29 项（起实例必须有 kill + trap）管得到。
        // 搬过来必须当场被量：这是"新建文件必须点名"第六次被用到；而它自带的第 59/60 项是**行为级**的
        // （真起子进程量"TERM 之后多久收尾"），因为第 29 项那类文本审计只看"有没有 trap 这一行"，
        // 我 06:44 就是被它放过了一次（有 trap、但长 sleep 把收尾拖到 200 秒之后）。
        "perf_run_batch.sh", "perf_selfcheck_trap.sh",
        // 09-25 #39：`perf_selfcheck_launchers.sh` 又涨回 **396/400**——`trap` 那一刀（`81213d7`）
        // 搬走 67 行之后它重新长了回来，同一个尺寸债**第二次到期**。按"拆，不抬线"把
        // 反例 48/49/51/52（冷启动档页名/归属 + 窗口负载判定）整段搬进 `windows.sh`
        // （判据与 ok/fail 文案逐字未动，拆前拆后 61 项输出逐字 diff 过）。
        // 搬出来的那片照样要点名：这是"新建/搬出的文件必须当场被量"**第七次**落到这张表上。
        "perf_selfcheck_windows.sh",
        // 09-25 #70：判废趟的原始 trace 回收（判据在 `perf_reclaim.py`，收尾那一族从
        // preflight 整族搬进 `perf_reclaim.sh`，反例 61 单开一块 `hygiene.sh`，因为
        // `eligibility` 当时 388/400 只剩 12 行）。**新建/搬出的文件当场点名**——
        // 这是这条规矩第八次落到这张表上（前七次见上面注释），不点名就等于免检。
        "perf_reclaim.py", "perf_reclaim.sh", "perf_selfcheck_hygiene.sh",
        // 09-25 #89：搬家后同一批产物分在三处（原地／仓库根／perf-base-rescue），
        // 清树之前必须先能"按批名定位 + 指明权威份"——新文件必须进名单，
        // 否则 `testRosterCoversEveryScriptOnDisk` 的反向守卫会把"新建文件"当成免检通道（那条守卫本来就是为这个建的）。
        "perf_artifact_locator.py",
        // 09-25 #55：等窗这一族加进"挂死同窗补一次"之后排程器到 **404/400**，
        // 按"拆，不抬线"把 `wait_for` 与四个 `cond_*` 搬进 `perf_window_gates.sh`（逐字节原文）。
        // `cond_instance_ready` **没跟着搬**——第 29 项要求"起实例的那份脚本必须有 trap"，
        // 那条守卫把这次搬家逼回原形（细节写在库文件头注）。搬出来的那片照样要点名：
        // 这是"新建/搬出的文件必须当场被量"**第九次**落到这张表上。
        // 同笔连带改了一处下游守卫：第 36 项原来只扫排程器里的 `open "$START_BIN"`，
        // 搬家期间它**一行都扫不到而静默变空**，所以改成两处都扫 + 给分母加断言。
        "perf_window_gates.sh",
        // 09-25 #39 第三次到期：`perf_selfcheck_gates.sh` 到 **395/400**（这根是最紧的一弦），
        // 把"这批量的是哪份内容、在什么条件下量的"那三项（38/40/53）整段搬进
        // `perf_selfcheck_context.sh`——判据与 ok/fail 文案逐字未动，拆前拆后各跑一次
        // selfcheck 并把输出归一后逐字 diff。搬出来的那片照样要点名：
        // 这是"新建/搬出的文件必须当场被量"**第十次**落到这张表上。
        "perf_selfcheck_context.sh",
        // 09-25 同一条债第四次到期：`perf_selfcheck_eligibility.sh` 到 **388/400**，
        // 把"一个读数怎么被解释成结论"那三项（26/27/41）搬进 `perf_selfcheck_attribution.sh`
        // （388→294 / 新块 110 行，逐字搬，拆前拆后 selfcheck 输出归一后逐字 diff）。
        // 第十一次用这条规矩：**搬出去的那片照样要点名**。
        "perf_selfcheck_attribution.sh",
        // 09-25 #43/#73：长 update → 调用栈归因的新尺子。**第十二次**用同一条规矩——
        // 上面那十一段注释讲的是同一件事：`rulerScripts` 是写死的名单，而扫描处是
        // `guard rulerScripts.contains(...) else { continue }`，所以"新建文件"本身就是
        // 一条免检通道，除非当场点名。这次仍然漏了（合入前一格），是手工
        // `ls scripts | grep '^perf_'` 与名单求差集才发现的 ⇒ 反向守卫记在任务 #75。
        "perf_update_stacks.py",
        // 09-25 #76 的连带一步：`perf_trace_summary.py` 涨到 417 行撞「巨大文件 400」口径，
        // 按"拆文件才是修复"把样本资格与基线新鲜度那一层搬进 `perf_eligibility.py`（三枚函数一字未动）。
        // **第十三次**用同一条规矩：搬出来的那片当场点名——不点名就等于给它开免检通道。
        // （这次是在同一笔里点的，没有等 `ls | comm` 事后抓。）
        "perf_eligibility.py",
        // 09-25 #75：**第十四次，也是最后一次**用这条规矩手动点名。这一次把剩下五把
        // 从没进过名单的尺子一次补齐（`ls scripts/` 与名单求差集现量），并且在下面
        // `testRosterCoversEveryScriptOnDisk` 里装上反向守卫——从此"新建文件"不再是免检通道，
        // 前十三次那种"漏了→注释里认一次→再漏"的循环到此为止。
        // 逐把说明：
        //   · `perf_cadence.py`（p95 那半句的两把预算与相对地板判据）——它有两枚函数贴着 50 行线，
        //     点名之前先按"拆，不抬线"把 `report` 里的脉冲交叉核对与 `against_baseline` 的
        //     算术/判定各搬一刀，拆前拆后拿真产物跑五格、输出逐字 diff 为空（同 #39 的做法）；
        //   · `perf_wait_window.sh`（等窗那一族的宿主，最长函数 `cond_instance_ready`）；
        //   · `perf_who_holds_the_slot.sh`（"谁占着窗口"那份只读诊断，#81 刚给它补了一态）；
        //   · `perf_synth_scroll.swift`（两枚函数）。⚠ 点名 **不等于**执行：合成滚动那一枚
        //     仍然在"停止一切点击与滚动测试"的禁令里（AGENTS §2.2），这里量的是它的代码。
        // `perf_raise.swift` 走下面的豁免表：它是 27 行**顶层脚本、零个函数**，
        // 一进门就被"每个尺子文件都要真被认出函数"那一分母门判红（实测就是这么红的）。
        "perf_cadence.py", "perf_wait_window.sh", "perf_who_holds_the_slot.sh",
        "perf_synth_scroll.swift",
    ]

    /// 盘上 `scripts/` 里"不进函数级名单"的文件：逐条写**为什么函数级两条尺没有可量对象**。
    /// 目标是这张表**永远是空的**。留一行就得在评审时讲清理由——
    /// "它超标了所以先豁免"是抬 `functionLineBar` 的另一种写法，不算理由。
    /// ⚠ 豁免只免**函数级**：文件长度那一尺仍然量它（`testRulerFilesStayAtOrBelowEightHundredLines`
    /// 取的是"名单 ∪ 豁免表"），否则"豁免"就会变成第二根免检通道。
    static let rosterExemptions: [String: String] = [
        "perf_raise.swift": "整份 27 行是顶层脚本（CommandLine + activate），零个函数"
            + " ⇒ 圈复杂度与函数行数两条尺没有可量对象；文件行数那一尺照常量它。",
    ]

    /// 名单与盘上事实必须**双向相等**。
    /// 为什么必须有这条：`rulerScripts` 是写死的，而扫描处是
    /// `guard rulerScripts.contains(...) else { continue }` ⇒ **不点名的新尺子静默免检**；
    /// 而原来那条断言只反方向管（名单有、盘上没 ⇒ 红）。同一族错我自己犯到第十三次，
    /// 前三次都靠事后手工 `ls scripts | grep '^perf_'` 与名单求差集，
    /// 所以这条规矩要从"我记得"搬进"这条测试替我记得"。
    func testRosterCoversEveryScriptOnDisk() throws {
        let entries = try FileManager.default.contentsOfDirectory(atPath: Self.scriptsRoot.path)
        // ⚠ 全集不是"只有 perf_ 前缀"：`trace_report.py` 是最早那把尺、名字没带前缀。
        // 只按前缀取全集会把它算成"名单有、盘上没有"的假 phantom。
        let onDisk = entries.filter {
            ($0.hasPrefix("perf_") || $0 == "trace_report.py")
                && ["sh", "py", "swift"].contains(($0 as NSString).pathExtension)
        }.sorted()
        XCTAssertFalse(onDisk.isEmpty,
                       "一个尺子文件都没扫到 = 路径或扩展名判据失效，这条门会永真绿")
        let unlisted = onDisk.filter {
            !Self.rulerScripts.contains($0) && Self.rosterExemptions[$0] == nil
        }
        XCTAssertTrue(unlisted.isEmpty,
                      "盘上有 \(unlisted.count) 把尺子既没点名也没豁免：\(unlisted.sorted())")
        let phantoms = Self.rulerScripts.filter { !onDisk.contains($0) }.sorted()
        XCTAssertTrue(phantoms.isEmpty,
                      "名单里 \(phantoms.count) 把不在盘上（改名或删文件没同步名单）：\(phantoms)")
        let mute = Self.rosterExemptions.filter {
            $0.value.trimmingCharacters(in: .whitespaces).isEmpty
        }
        XCTAssertTrue(mute.isEmpty, "豁免必须逐条写理由，空格子等于免检：\(mute.keys.sorted())")
    }

    /// 包根（`TcoderMonitor/`）：本文件 → TcoderMonitorTests → Tests → TcoderMonitor。
    static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    static var scriptsRoot: URL { packageRoot.appendingPathComponent("scripts") }

    /// 与 `SelfScanHarnessCase.wcStyleLineCount` / `LogHotspotRatchetTests` 同一把尺子。
    static func wcStyleLineCount(_ text: String) -> Int {
        let newlines = text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        return text.hasSuffix("\n") ? newlines : newlines + 1
    }

    struct Scanned {
        var file: String
        var candidate: FunctionCandidate
        var key: String { "\(file).\(candidate.name)" }
        var complexity: Int { candidate.complexity }
    }

    /// 用工具自己的引擎把六把尺子里每个函数过一遍。
    func rulerFunctions() async throws -> [Scanned] {
        let result = await SourceTreeScanner(options: .default).scan(root: Self.scriptsRoot)
        XCTAssertFalse(result.files.isEmpty,
                       "扫 scripts/ 一个文件都没有 = 路径解析静默失效，这条门会永真绿")
        var all: [Scanned] = []
        for file in result.files {
            let base = file.url.deletingPathExtension().lastPathComponent
            guard Self.rulerScripts.contains(file.url.lastPathComponent) else { continue }
            all += ComplexityEngine.functions(in: file).map { Scanned(file: base, candidate: $0) }
        }
        // 分母门：每个尺子文件都必须真的被认出函数，认不出就是引擎对这些扩展名失效了。
        for name in Self.rulerScripts {
            let base = (name as NSString).deletingPathExtension
            let hit = all.contains { $0.file == base }
            XCTAssertTrue(hit, "\(name) 一个函数都没数到：尺子文件名变了还是引擎认出函数了？")
        }
        return all
    }

    func testRulerFunctionsStayBelowTheComplexityBar() async throws {
        let functions = try await rulerFunctions()
        XCTAssertGreaterThan(functions.count, 60,
                             "尺子文件只认出 \(functions.count) 个函数，分母异常，热点榜数不到东西不能算通过")
        let ranked = functions.sorted {
            if $0.complexity != $1.complexity { return $0.complexity > $1.complexity }
            return $0.key < $1.key
        }
        let roster = ranked.map { "  \($0.key) CC\($0.complexity) \($0.candidate.lineCount)行" }
        print("【WS-X5 尺子热点】分母 \(functions.count) 个函数，CC 最高的若干个：\n"
            + roster.prefix(15).joined(separator: "\n"))
        let strays = functions.filter { $0.complexity >= Self.complexityBar }
            .map { "\($0.key) CC\($0.complexity)" }
        XCTAssertTrue(strays.isEmpty,
                      "尺子里出现名单口径的高复杂度函数（≥\(Self.complexityBar)）：\(strays.sorted().joined(separator: ", "))")
        let long = functions.filter { $0.candidate.lineCount > Self.functionLineBar }
            .map { "\($0.key) \($0.candidate.lineCount)行" }
        XCTAssertTrue(long.isEmpty, "尺子函数超过 \(Self.functionLineBar) 行：\(long.sorted().joined(separator: ", "))")
    }

    func testRulerFilesStayAtOrBelowEightHundredLines() throws {
        let fm = FileManager.default
        var over: [String] = []
        var counted = 0
        // 名单 **∪** 豁免表：豁免只免"函数级"那两条尺，文件长度这一尺不许被一起免掉
        // （否则 `rosterExemptions` 就成了第二根免检通道——正是 #75 要堵的那类形状）。
        let lengthFace = Set(Self.rulerScripts).union(Self.rosterExemptions.keys).sorted()
        for name in lengthFace {
            let url = Self.scriptsRoot.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                XCTFail("读不到尺子文件 \(name)：它被改名或删除了")
                continue
            }
            counted += 1
            let lines = Self.wcStyleLineCount(text)
            print("  \(name) \(lines) 行")
            if lines > Self.fileLineBar { over.append("\(name) \(lines) 行") }
        }
        XCTAssertEqual(counted, lengthFace.count, "清单（名单∪豁免）里的每把尺都必须都在，少一把这条门就是空的")
        XCTAssertTrue(over.isEmpty, "撞 ≤\(Self.fileLineBar) 行棘轮的尺子：\(over.sorted().joined(separator: ", "))——拆开它，别拧阈值")
    }

    /// **元测试**：上面那条 CC 门必须抓得住坏例。往 /tmp 造一个已知高 CC 的 python 夹具，
    /// 引擎数不出 ≥16 的话，主门就是永真绿（AGENTS.md 第四轮红线 6：守卫要配元测试）。
    func testComplexityBarCatchesASyntheticHotRulerFunction() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tcoder-x5-ruler-probe",
                                                                                isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fixture = """
        def x5_probe_hot(a, b):
            if a and b:
                return 1
            for i in a:
                if i or b:
                    continue
            while b:
                if a:
                    break
            if a and b or a:
                return 2
            for i in b:
                for j in i:
                    if a or b:
                        return 3
            if a:
                return 4
            elif b:
                return 5
            while a and b:
                return 6
            return 0
        """
        let url = dir.appendingPathComponent("x5_probe.py")
        try fixture.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }

        let files = await SourceTreeScanner(options: .default).scan(root: dir).files
        XCTAssertEqual(files.count, 1, "夹具没被扫到（分母 0），下面那句断言就没意义")
        let measured = ComplexityEngine.functions(in: files.first!)
        XCTAssertEqual(measured.map(\.name), ["x5_probe_hot"], "函数名没认出来，CC 榜也数不到东西")
        XCTAssertGreaterThanOrEqual(measured[0].complexity, Self.complexityBar,
                                    "18 处判定的合成夹具都过不了 \(Self.complexityBar) 这条线，"
                                    + "说明本门的 CC 判定空转（实得 \(measured[0].complexity)）")
        print("【WS-X5 元测试】合成坏例 x5_probe_hot CC=\(measured[0].complexity) ≥ \(Self.complexityBar) —— 门抓得住坏例")
    }

    // MARK: - 话术串里的命令替换（2026-09-23 21:44 抓到两处，两处都是我自己写的）

    /// 一行里**双引号串内部**出现反引号 ⇒ bash 把它当命令替换**真的执行**。
    /// 只看引号内部：注释里的反引号不执行、合法写法（`$( … )`）本来就该用；
    /// 整条判据管的是「把反引号当中文引号用」这一种形状——它只有跑起来才露，
    /// 而露出来的症状是「那行少了一个词 + stderr 多一行 command not found」，不是报错。
    static func backtickInsideDoubleQuotes(_ line: String) -> Bool {
        var inQuotes = false
        var escaped = false
        for ch in line {
            if escaped { escaped = false; continue }
            if ch == "\\" { escaped = inQuotes; continue }
            if ch == "\"" { inQuotes.toggle(); continue }
            if ch == "`" && inQuotes { return true }
        }
        return false
    }

    /// 只判会被执行的**输出行**（`echo` / `printf`），注释行跳过。
    static func proseSubstitutionOffenders(in content: String) -> [Int] {
        content.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            .compactMap { entry in
                let trimmed = entry.element.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("#"),
                      trimmed.contains("echo ") || trimmed.contains("printf ") else { return nil }
                return backtickInsideDoubleQuotes(String(entry.element)) ? entry.offset + 1 : nil
            }
    }

    func test_rulerScriptsDoNotRunSubstitutionInsideProse() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.scriptsRoot.path)
            .filter { $0.hasSuffix(".sh") }.sorted()
        XCTAssertGreaterThan(names.count, 10,
                             "scripts/ 只数到 \(names.count) 个 .sh ⇒ 读盘坏了，这条绿没有含义")
        var offenders: [String] = []
        var scannedLines = 0
        for name in names {
            let text = try String(contentsOf: Self.scriptsRoot.appendingPathComponent(name), encoding: .utf8)
            scannedLines += text.split(separator: "\n", omittingEmptySubsequences: false).count
            offenders += Self.proseSubstitutionOffenders(in: text).map { "\(name):\($0)" }
        }
        XCTAssertGreaterThan(scannedLines, 3_000, "总共只读到 \(scannedLines) 行 ⇒ 判据在空转")
        XCTAssertTrue(offenders.isEmpty,
                      "这些话术行会被 bash 真的执行（双引号里的反引号是命令替换）：\(offenders)")
    }

    /// 元测试双向：坏样例必须被抓且行号要对；两处合法写法（`$( … )`、注释里的反引号）不许被抓。
    /// 只断言"抓得住"的守卫是半个空转——它可能其实在什么都抓。
    func test_proseSubstitutionJudgeHasTeethBothWays() {
        let bad = "  echo \"==> 采集跑完：能不能进表由 `report` 与一致性判\""
        XCTAssertEqual(Self.proseSubstitutionOffenders(in: "x\n" + bad + "\ny"), [2],
                       "行号没指到那一行（拿到 \(Self.proseSubstitutionOffenders(in: "x\n" + bad + "\ny"))）")
        let okSubstitution = "  echo \"名册现量：$(printf '%s' \"$known\" | tr '\\n' ' ')\""
        let okComment = "  # 这里写反引号不执行：`report`"
        XCTAssertTrue(Self.proseSubstitutionOffenders(in: [okSubstitution, okComment].joined(separator: "\n")).isEmpty,
                      "合法写法不许被抓：$() 是看得见的替换，注释不执行")
    }
}
