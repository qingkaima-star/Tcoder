import Foundation
import XCTest
@testable import TcoderMonitor

/// 整改意见第九节：**不允许从整机 CPU 或内存直接生成某个项目的性能结论**。
///
/// 这一族缺陷有三种形状，本文件各钉一种：
/// ① **同屏误导**——整机读数与项目读数并排摆着，却没有一个字说前两者不是后者；
/// ② **弱证据冒充强归因**——旧写法 `ProcessSnapshot.commandLine = commandLinePath ?? name`
///    让"进程名恰好相同"与"命令行里出现过这个词"在下游长得一模一样；
/// ③ **静默进分**——把机器状态接进项目评分或无头结论面。今天没有这条通路
///   （`ProjectReport` 里就没有机器段），所以钉的是"入口不许长出来"。
///
/// 【独立真值】`testProcessLedgerIsSystemWideNotProjectScoped` 自己起 `ps -A -o pid=`
/// 数一遍全系统进程数，再与 `ProcessInspector.processCountProbe` 对表：
/// 两个数同源 ⇒ 这一族口径量的确实是整台机器，项目页面上按它出的任何数
/// 都不可能是"本项目的开销"。刻意不复用 `ProcessInspector` 的实现，
/// 否则"独立真值"就变成工具自己的输出。
final class MachineVsProjectBoundaryTests: XCTestCase {

    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    /// 一份"整机很忙"的合成快照：CPU 逼近满载、内存报满、热压力过热、负载 42。
    private func busyMachine() -> SystemSnapshot {
        var snapshot = SystemSnapshot()
        snapshot.timestamp = Self.epoch
        snapshot.cpuUsage = 0.98
        snapshot.cpuCoreCount = 10
        snapshot.memoryTotalBytes = 64_000_000_000
        snapshot.memoryUsedBytes = 64_000_000_000
        snapshot.memoryPressure = .critical
        snapshot.thermalState = .critical
        snapshot.processCount = 900
        snapshot.loadAverage1 = 42
        return snapshot
    }

    private func process(pid: Int32, name: String, path: String? = nil,
                         cpu: Double = 0, memory: UInt64 = 0) -> ProcessSnapshot {
        ProcessSnapshot(pid: pid, name: name, cpuUsage: cpu, memoryBytes: memory,
                        threadCount: 1, openFileCount: 1, startTime: nil,
                        executablePath: path, parentPID: 1)
    }

    // MARK: - ① 反向断言：整机爆表 + 本项目进程不在场 ⇒ 项目侧一句结论都不许出

    /// 喂「整机高负载，但一个分组都不命中」的上下文：
    /// 分组卡只能判「零命中」，成因句只能说「全系统 N 个进程里没有命中」，
    /// 汇总四项只能是 nil，**任何一句都不许对"这个项目"下判断**。
    func testBusyMachineWithNoMatchedProcessesYieldsNoProjectVerdict() {
        let sweep = ProcessSweep(
            processes: [process(pid: 1, name: "kernel_task", path: "/System/Library/kernel", cpu: 9.4)],
            states: [:], elapsed: 1.5, truncated: false, visiblePIDCount: 1)
        let context = SampleContext(snapshot: busyMachine(), historyCount: 5, isPaused: false)
        let groups = ProcessInspector.groupSnapshots(for: TrackedProcessGroup.builtInDefaults,
                                                     processes: sweep.processes)
        XCTAssertEqual(groups.count, TrackedProcessGroup.builtInDefaults.count,
                       "零命中也要每组出一行，否则界面会把它画成「这个组被删了」")
        for group in groups {
            XCTAssertTrue(group.matchedProcesses.isEmpty, "\(group.group.title) 不该命中（夹具里只有 kernel_task）")
            XCTAssertEqual(PerformanceGroupCard.matchState(context: context, group: group), .noMatch,
                           "整机再忙，零命中的组也只能判「零命中」这一态")
            let badge = PerformanceGroupCard.badgeText(for: .noMatch)
            XCTAssertEqual(badge, "零命中")
            XCTAssertFalse(badge.contains("正常") || badge.contains("健康"), "缺席态被涂成了结论：\(badge)")
            let copy = PerformanceGroupCard.copy(for: .noMatch, pattern: group.group.matchPattern,
                                                 totalProcesses: context.snapshot?.processCount,
                                                 intervalText: "1.5 秒")
            XCTAssertTrue(copy.message.contains("全系统"),
                          "零命中的成因句必须交代它扫的是全系统，实际：\(copy.message)")
            XCTAssertFalse(copy.message.contains("该项目"),
                           "分组卡不许对「这个项目」下判断：" + copy.message)
            // 组里一个进程都没有时，三项汇总一律 nil，不许长出一个冒充全量的 0。
            XCTAssertNil(ProcessMetric.groupMemory(of: group))
            XCTAssertNil(ProcessMetric.groupThreads(of: group))
            XCTAssertNil(ProcessMetric.groupOpenFiles(of: group))
        }
    }

    /// 「占全机 %」说的是这一组占整台机器的比例；组内没命中时那一格只能是 `--`。
    func testZeroMatchGroupHasNoShareAndSaysSoOnScreen() {
        let empty = ProcessGroupSnapshot(group: TrackedProcessGroup(title: "Java 服务", matchPattern: "java"),
                                         matchedProcesses: [])
        XCTAssertEqual(empty.totalCPU, 0,
                       "求和是 0 这件事本身不错，错的是它可以被读成「这个应用不占 CPU」")
        let context = SampleContext(snapshot: busyMachine(), historyCount: 5, isPaused: false)
        XCTAssertEqual(PerformanceGroupCard.matchState(context: context, group: empty), .noMatch)
        // 屏上留的那半句 + ⓘ 里的整句，两半都得在；少一半就有人把"零命中"读成"服务挂了"。
        XCTAssertTrue(PerformanceProcessGroupsCard.zeroMatchReading.contains("没有匹配的进程"))
        XCTAssertFalse(PerformanceProcessGroupsCard.zeroMatchReading.contains("故障"),
                       "屏上短句不许自己长出结论")
    }

    /// 整机满载、本项目一个进程都不在场时，**总览页那两枚整机格子也不许变绿变红表态**。
    /// 判据归属：`SystemReadings`（三态）+ `LoadLevel`（着色）。
    func testMachineLoadNeverProducesAProjectStatement() {
        let context = SampleContext(snapshot: busyMachine(), historyCount: 5, isPaused: false)
        // 这两条只是确认"整机的数确实进得来"，否则下面那几条缺席断言全是永真绿。
        XCTAssertEqual(SystemReadings.cpuFraction(context) ?? -1, 0.98, accuracy: 1e-9)
        XCTAssertNotNil(SystemReadings.memoryUsedBytes(context))
        // 而项目侧的输入面（HealthInputs）里没有任何一格能接住这个数。
        let inputs = HealthInputs()
        XCTAssertTrue(inputs.availableDimensions.isEmpty,
                      "无证据时不该有任何维度在场，实际 \(inputs.availableDimensions.map(\.rawValue))")
        let score = WeightedHealthScorer().score(inputs)
        XCTAssertTrue(score.components.isEmpty)
        XCTAssertNil(score.verdict, "零证据时综合分必须是 nil，不许画成 0 分 E 级")
    }

    // MARK: - ② 弱证据不许冒充强归因：`commandLine` 已拆成 `executablePath`

    /// 名字与路径分家之后，"命中"要能交代清楚命中在**哪一路**，
    /// 而不是像旧写法那样把名字塞进一个叫命令行的字段里再多算一路。
    func testMatchEvidenceKeepsTheTwoRoutesApart() {
        let onlyPath = process(pid: 202, name: "wrapper", path: "/opt/homebrew/bin/java")
        XCTAssertTrue(ProcessInspector.matches(onlyPath, pattern: "java"),
                      "命中路径这一条必须仍然有效，否则拆分等于偷偷削弱匹配")
        XCTAssertFalse(ProcessInspector.matches(onlyPath, pattern: "nginx"))

        // 旧字段最坏的那一步：路径取不到时把进程名当"命令行"。现在这一路明确是缺席。
        let blind = process(pid: 203, name: "java", path: nil)
        XCTAssertNil(blind.executablePath)
        XCTAssertTrue(ProcessInspector.matches(blind, pattern: "java"), "名字命中不受影响")
        XCTAssertFalse(ProcessInspector.matches(blind, pattern: "/opt/homebrew"),
                       "路径没取到，就不许出现「命中了某个路径」这件事")
    }

    /// hover 的两态：有路径说路径；没路径就明说自己没取到，不许只上屏一个名字冒充路径。
    func testIdentityTooltipDistinguishesPathFromName() {
        let withPath = ProcessInspector.identityTooltip(for: process(pid: 301, name: "java", path: "/usr/bin/java"))
        XCTAssertTrue(withPath.contains("/usr/bin/java"), withPath)
        XCTAssertTrue(withPath.contains("不读"), "既然占了「命令行」这个位置，就得说清这里不是命令行：" + withPath)

        let withoutPath = ProcessInspector.identityTooltip(for: process(pid: 302, name: "java", path: nil))
        XCTAssertTrue(withoutPath.contains("未取到"), "路径缺席时不许只上屏一个名字：" + withoutPath)
        XCTAssertTrue(withoutPath.contains("java"))
    }

    /// 内置分组名单**不许**长成"从项目名派生"。这五条是写死的通用服务名。
    func testBuiltInGroupsAreGenericServiceNamesNotProjectNames() {
        let patterns = TrackedProcessGroup.builtInDefaults.map(\.matchPattern)
        XCTAssertEqual(patterns, ["java", "node", "mysqld", "redis-server", "nginx"])
        for group in TrackedProcessGroup.builtInDefaults {
            XCTAssertTrue(group.isBuiltIn, "\(group.title) 的 isBuiltIn 被改了")
            XCTAssertFalse(group.matchPattern.isEmpty)
        }
        // 反例钉据：本仓库的项目名与它的各种拼法一律不在名单里。
        for projectWord in ["Tcoder", "tcoder", "Monitor", "TcoderMonitor"] {
            XCTAssertFalse(patterns.contains(projectWord),
                           "内置名单里出现了项目名 \(projectWord)：那就是拿项目名撞进程名的开始")
        }
    }

    // MARK: - 防回潮：名字兜底那条路不许再长回来

    /// `ProcessSnapshot` 的 `executablePath` 这一格**不许再出现任何形式的"取不到就拿别的顶上"**。
    /// needle 不带左括号（`?? ` 紧跟在 `executablePath:` 后面才算），命中带原始行号。
    /// 为什么只钉这一格而不是全文件：`resident == 0, let task` 那类真兜底是另一回事，
    /// 把它们一起抓会让守卫天天误伤、然后被人删掉。
    func testExecutablePathHasNoNameFallback() throws {
        let files = DesignAbsenceStateTests.swiftFiles(under: "Services/Performance")
        XCTAssertFalse(files.isEmpty, "扫不到 Services/Performance，这条守卫是永真绿")
        let hits = try DesignAbsenceStateTests.scan(#"executablePath:\s*\S+\s*\?\?"#, in: files)
        XCTAssertTrue(hits.isEmpty,
                      "可执行路径又长出了名字兜底（\(hits.count) 处）——那正是第九节点名的弱证据冒充强归因：\n"
                          + DesignAbsenceStateTests.describe(hits))
    }

    /// 元测试（有牙）：合成违例真命中、两种合法写法不误判。
    func testMetaNameFallbackDetectorCatchesAndSpares() throws {
        let bad = [(path: "Services/Performance/Fake.swift", content: """
        let snapshot = ProcessSnapshot(
            pid: pid,
            executablePath: commandLinePath ?? name,
            parentPID: 1
        )
        """)]
        let hits = try DesignAbsenceStateTests.scan(#"executablePath:\s*\S+\s*\?\?"#, in: bad)
        XCTAssertEqual(hits.count, 1, "埋了一处兜底没抓到，尺子是假的")
        XCTAssertEqual(hits.first?.line, 3, "命中必须带原始行号，实际 \(hits.first?.line ?? -1)")

        let good = [(path: "Services/Performance/FakeOK.swift", content: """
        executablePath: path,
        let resident = usage?.residentBytes ?? 0
        // 旧写法 executablePath: commandLinePath ?? name 已经被拆掉了
        """)]
        XCTAssertTrue(try DesignAbsenceStateTests.scan(#"executablePath:\s*\S+\s*\?\?"#, in: good).isEmpty,
                      "合法的 ?? 兜底（另一件事）或注释里的历史提法被误判")
    }

    // MARK: - 界面必须明写边界（删掉任一句，这一条就红）

    /// 边界文案是**判据**不是装饰：整机格子与项目格子并排摆着时，少一句"这是整机的"，
    /// 读者就会把 98% 读成"这个项目把机器跑满了"。所以按文件钉原文，改一个字都要来解释。
    func testBoundarySentencesAreStillOnScreen() throws {
        let expectations: [(file: String, sentence: String, why: String)] = [
            ("PerformanceSystemTiles.swift",
             "以上是整机读数：含其它项目与系统服务的开销，不构成本项目的性能结论。",
             "性能页四枚整机读数的正下方"),
            ("PerformanceProcessGroups.swift", "与所选项目无关", "进程分组卡的副标题"),
            ("PerformanceProcessGroups.swift", "命中数为 0 只说明", "零命中的屏上读法"),
            ("DashboardReadouts.swift", "本机 CPU", "总览读数带第一枚的标签"),
            ("DashboardReadouts.swift", "本机内存", "总览读数带第二枚的标签"),
            ("PerformanceView.swift", "系统级实时读数只观测不干预", "性能页页头的口径句"),
        ]
        let files = DesignAbsenceStateTests.swiftFiles(under: "Views")
        XCTAssertGreaterThan(files.count, 40, "扫不到 Views，下面每条断言都是永真绿")
        for expectation in expectations {
            let hit = files.filter { $0.path.hasSuffix(expectation.file) }
            XCTAssertFalse(hit.isEmpty, "扫不到 \(expectation.file)")
            XCTAssertTrue(hit.contains(where: { $0.content.contains(expectation.sentence) }),
                          "边界说明丢了（\(expectation.why)）：\(expectation.file) 里找不到「\(expectation.sentence)」")
        }
    }

    /// 元测试（有牙）：把边界句删掉的合成文件必须被判"缺"，合规的那份不许误判。
    func testMetaBoundarySentenceDetectorCatchesAndSpares() throws {
        let sentence = "以上是整机读数：含其它项目与系统服务的开销，不构成本项目的性能结论。"
        func carries(_ files: [(path: String, content: String)]) -> Bool {
            files.contains(where: { $0.content.contains(sentence) })
        }
        let stripped = [(path: "Views/Performance/PerformanceSystemTiles.swift",
                         content: "struct PerformanceSystemTiles { var body: some View { NoteLine(\"这是「在用」\") } }")]
        XCTAssertFalse(carries(stripped), "删掉边界句却没判红，这条守卫就是永真绿")
        let intact = [(path: "Views/Performance/PerformanceSystemTiles.swift",
                       content: "NoteLine(\"\(sentence)\", icon: .unverified)")]
        XCTAssertTrue(carries(intact), "合规写法被误判，守卫活不过下一轮")
        XCTAssertFalse(carries([]), "空输入也算「含有边界句」，这条断言就是假的")
    }

    // MARK: - ③ 整机量进不了落盘 schema（钉的是"类型里就没地方写"）

    /// `ProjectReport` 是 CLI 与 GUI 共用的唯一 schema：它没有任何 runtime / 机器段。
    /// 这比注释可靠——想写进去就得改冻结契约，而改冻结契约要过总工。
    func testReportSchemaCarriesNoMachineReadout() throws {
        var report = ProjectReport(project: MonitoredProject(name: "fixture", path: "/tmp/not-scanned"))
        report.health = WeightedHealthScorer().score(HealthInputs())
        let text = try CLIScan.json(report, compact: true)
        for needle in ["thermalState", "cpuUsage", "memoryUsedBytes", "loadAverage",
                       "processCount", "uptimeSeconds", "SystemSnapshot", "executablePath"] {
            XCTAssertFalse(text.contains(needle),
                           "报告 JSON 里出现了整机字段 \(needle)，那等于把机器状态写成项目的属性")
        }
        XCTAssertTrue((report.health?.components ?? []).isEmpty,
                      "无证据时评分必须没有分量，实际 \(report.health?.components.count ?? -1) 条")
    }

    /// 独立真值对表：`ps -A` 自己数一遍，与 `ProcessInspector` 的计数探针同源。
    /// 进程数在两次调用之间会漂，所以只判"同一量级"并把两个原始读数打出来交给复核的人，
    /// **不设可调阈值**（调它等于把尺子改松）。
    func testProcessLedgerIsSystemWideNotProjectScoped() throws {
        let ps = ShellRunningProcesses.systemWideCount()
        let probe = ProcessInspector.processCountProbe(visiblePIDCount: ProcessInspector.visibleProcessCount())
        try XCTSkipUnless(ps > 0 && probe.count > 0,
                          "独立探针或 sysctl 没量到（ps=\(ps) probe=\(probe.count)），无法对表")
        print("【第九节对表】ps -A = \(ps) · sysctl 探针 = \(probe.count)（isSystemWide=\(probe.isSystemWide)）")
        let drift = abs(probe.count - ps)
        XCTAssertLessThanOrEqual(drift, max(30, ps / 20),
                                 "两个口径差得太远（\(probe.count) vs \(ps)），量的已不是同一件事")
        XCTAssertGreaterThan(probe.count, 0, "分母为 0 时上面那条恒真")
    }
}

/// 只为对表存在的独立探针：起 `ps -A -o pid=` 数一遍全系统进程。
/// **只读**，不给任何进程发信号；刻意不复用 `ProcessInspector` 的实现。
enum ShellRunningProcesses {
    static func systemWideCount() -> Int {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-A", "-o", "pid="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return 0
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n")
            .filter { Int($0.trimmingCharacters(in: .whitespaces)) != nil }.count
    }
}
