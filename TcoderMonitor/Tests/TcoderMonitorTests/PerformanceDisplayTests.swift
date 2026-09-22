import Foundation
import XCTest
@testable import TcoderMonitor

/// WS-M 性能页显示层的纯函数契约。
///
/// 这一页是杀手功能，也是最容易在「数据跳动」时撒谎的地方，所以判据全部下沉成
/// 可断言的纯函数：缺证据 → `--`、真 0 → 数字、轴 → 台阶、空态 → 分得清三种原因。
final class PerformanceDisplayTests: XCTestCase {

    // MARK: - 构造真实形状的读数

    private func snapshot(used: UInt64, total: UInt64, cpu: Double = 0.25, cores: Int = 8,
                          pressure: MemoryPressure = .normal) -> SystemSnapshot {
        var snap = SystemSnapshot()
        snap.memoryUsedBytes = used
        snap.memoryTotalBytes = total
        snap.memoryPressure = pressure
        snap.cpuUsage = cpu
        snap.cpuCoreCount = cores
        snap.processCount = 400
        return snap
    }

    /// 走真实引擎，拿到 WS-C `8333852` 定义的「读不到页计数」那条快照长什么样。
    private func engineSnapshotWithFailedVmRead() -> SystemSnapshot {
        var counters = SystemCounters()
        counters.vm = VmCounters()          // 七项页计数全 0 = host_statistics64 失败的形状
        return SystemSampler().snapshot(previous: nil, current: counters, processCount: 400)
    }

    private func context(_ snap: SystemSnapshot?, frames: Int = 3, paused: Bool = false) -> SampleContext {
        SampleContext(snapshot: snap, historyCount: snap == nil ? 0 : frames, isPaused: paused)
    }

    private func process(pid: Int32, cpu: Double = 0, memory: UInt64 = 1024,
                         threads: Int, files: Int) -> ProcessSnapshot {
        ProcessSnapshot(pid: pid, name: "p\(pid)", cpuUsage: cpu, memoryBytes: memory,
                        threadCount: threads, openFileCount: files, startTime: nil,
                        commandLine: "/usr/bin/p\(pid)", parentPID: 1)
    }

    // MARK: - 三态：缺证据不给数字

    func testMissingEvidenceRendersAsPlaceholderNotZero() {
        XCTAssertEqual(Live.percent(nil), "--")
        XCTAssertEqual(Live.grouped(nil), "--")
        XCTAssertEqual(Live.cores(nil), "--")
        XCTAssertEqual(Live.bytes(nil), "--")
        XCTAssertEqual(Live.rate(nil), "--")
        XCTAssertEqual(Live.bitRate(nil), "--")
        XCTAssertEqual(Live.fixed(nil, digits: 1), "--")
        XCTAssertTrue(Live.forcesNeutral("--"))
        XCTAssertFalse(Live.forcesNeutral("0"))
    }

    /// 进程内存的三态（批次 P7-B 余量）：`rusage` 与 `task_info` 两路都没给值时是 0，
    /// 而"占 0 字节的进程"不存在，所以那个 0 必须走 `--`；合计与单进程峰值同理。
    /// 这条以前测不了：`residentBytes` 返回非 Optional，表里那一列是全表唯一
    /// 会把"没读到"画成数字的地方（线程、打开文件都已经是三态）。
    func testProcessMemoryTreatsUnreadAsMissing() {
        let unread = process(pid: 11, memory: 0, threads: 4, files: 7)
        let read = process(pid: 12, memory: 4096, threads: 2, files: 3)
        XCTAssertNil(ProcessMetric.residentBytes(of: unread), "没读到不能画成 0 B")
        XCTAssertEqual(ProcessMetric.residentBytes(of: read), 4096)

        let mixed = ProcessGroupSnapshot(
            group: TrackedProcessGroup(title: "混合组", matchPattern: "p"),
            matchedProcesses: [unread, read])
        XCTAssertEqual(ProcessMetric.groupMemory(of: mixed), 4096, "合计只加取到的")
        XCTAssertEqual(ProcessMetric.memoryCovered(in: mixed), 1, "「N/M 个进程取到」里的 N 要数得出来")
        XCTAssertEqual(ProcessMetric.peakMemory(of: mixed), 4096)

        let allUnread = ProcessGroupSnapshot(
            group: TrackedProcessGroup(title: "全空组", matchPattern: "p"),
            matchedProcesses: [unread, process(pid: 13, memory: 0, threads: 1, files: 1)])
        XCTAssertNil(ProcessMetric.groupMemory(of: allUnread), "一个都没读到不许给 0")
        XCTAssertNil(ProcessMetric.peakMemory(of: allUnread), "峰值不许把 0 当成测得的最大值")
        XCTAssertEqual(Live.bytes(ProcessMetric.groupMemory(of: allUnread)), "--")
    }

    func testRealZeroSurvivesThePlaceholderLayer() {        // 真 0 是结论，必须原样显示成 0，不能被 `--` 吞掉。
        XCTAssertEqual(Live.grouped(0), "0")
        XCTAssertEqual(Live.percent(0, precision: 0), "0%")
        XCTAssertEqual(Live.cores(0), "0.00")
    }

    func testCPUAndRatesNeedTwoFramesBeforeTheyGiveAnyNumber() {
        let snap = snapshot(used: 8_000, total: 16_000)
        XCTAssertNil(SystemReadings.cpuFraction(context(snap, frames: 1)),
                     "只有一个样本时 CPU 差分无从算起，不能报 0%")
        XCTAssertNil(SystemReadings.diskBytesPerSecond(context(snap, frames: 1)))
        XCTAssertNil(SystemReadings.networkBytesPerSecond(context(snap, frames: 1)))
        XCTAssertEqual(SystemReadings.cpuFraction(context(snap, frames: 2)), 0.25)
        XCTAssertNil(SystemReadings.cpuFraction(context(nil)))
    }

    /// 端到端接住 WS-C 的修复：引擎把失败落成「压力 unknown + 已用 0 + 总量真值」，
    /// 视图必须渲染成 `--` 并给原因，而不是「0 B · 占 0% · 正常」（那比假 100% 更安心，也更错）。
    func testFailedVmReadFromTheRealEngineRendersAsMissing() {
        let failed = engineSnapshotWithFailedVmRead()
        XCTAssertEqual(failed.memoryPressure, .unknown, "WS-C 的信号是 .unknown，本测试依赖它")
        XCTAssertEqual(failed.memoryUsedBytes, 0)
        XCTAssertGreaterThan(failed.memoryTotalBytes, 0, "总量是另一次独立读取，应当带真值")

        let ctx = context(failed)
        XCTAssertNil(SystemReadings.memoryUsedBytes(ctx))
        XCTAssertNil(SystemReadings.memoryFraction(ctx))
        XCTAssertNil(SystemReadings.memoryPressure(ctx))
        let reason = SystemReadings.memoryGapReason(ctx) ?? ""
        XCTAssertTrue(reason.contains("页计数") || reason.contains("host_statistics"), "空态要说清原因，得到的是「\(reason)」")
    }

    /// 反方向也要钉住：真的用满（空闲+推测+可清除确实为 0）必须照实显示。
    /// 我上一版把「已用 ≥ 总量」当假读数压掉，会把最该报警的一帧藏成 `--`。
    func testGenuineFullMemoryIsShownNotSuppressed() {
        let full = context(snapshot(used: 16_000, total: 16_000, pressure: .critical))
        XCTAssertEqual(SystemReadings.memoryUsedBytes(full), 16_000)
        XCTAssertEqual(SystemReadings.memoryFraction(full), 1.0)
        XCTAssertNil(SystemReadings.memoryGapReason(full))
        XCTAssertEqual(LoadLevel.role(for: SystemReadings.memoryFraction(full)).name, "danger")
    }

    func testZeroUsedBytesCountsAsNoEvidence() {
        let zero = context(snapshot(used: 0, total: 16_000))
        XCTAssertNil(SystemReadings.memoryUsedBytes(zero))
        XCTAssertNotNil(SystemReadings.memoryGapReason(zero))
    }

    func testHealthyMemoryKeepsItsNumbersAndGapReasonStaysSilent() {
        let healthy = context(snapshot(used: 9_000, total: 16_000))
        XCTAssertEqual(SystemReadings.memoryUsedBytes(healthy), 9_000)
        XCTAssertNil(SystemReadings.memoryGapReason(healthy))
        XCTAssertNil(SystemReadings.memoryGapReason(context(nil)))
    }

    func testMemoryCaliberIsStatedInWords() {
        XCTAssertTrue(SystemReadings.memoryCaliber.contains("空闲"))
        XCTAssertTrue(SystemReadings.memoryCaliber.contains("可清除"))
        XCTAssertTrue(SystemReadings.memoryCaliber.contains("剩余可用"),
                      "必须明写这不是「剩余可用」，否则用户会当成磁盘余量读")
    }

    func testUntrustedMemoryPointsAreDroppedFromTheCurve() {
        let points = [snapshot(used: 8_000, total: 16_000),
                      snapshot(used: 0, total: 16_000, pressure: .unknown),
                      snapshot(used: 16_000, total: 16_000, pressure: .critical),
                      snapshot(used: 9_000, total: 16_000)]
        // 只剔「没证据」的那一帧；真用满的一帧要留在曲线上。
        XCTAssertEqual(SystemReadings.trustedMemoryPoints(points).count, 3)
        XCTAssertEqual(SystemReadings.rejectedMemoryPoints(points), 1,
                       "剔除了几个点必须数得出来，不能悄悄丢")
    }

    func testCoresInUseConvertsMachineShareIntoCoreEquivalent() {
        XCTAssertEqual(SystemReadings.coresInUse(context(snapshot(used: 8, total: 16, cpu: 0.25, cores: 8))), 2.0)
        XCTAssertNil(SystemReadings.coresInUse(context(snapshot(used: 8, total: 16), frames: 1)))
    }

    // MARK: - 进程级在场性

    func testZeroThreadsAndHandlesMeanNotMeasuredRatherThanNone() {
        let blind = process(pid: 1, threads: 0, files: 0)
        XCTAssertNil(ProcessMetric.threads(of: blind))
        XCTAssertNil(ProcessMetric.openFiles(of: blind))

        let measured = process(pid: 2, threads: 12, files: 87)
        XCTAssertEqual(ProcessMetric.threads(of: measured), 12)
        XCTAssertEqual(ProcessMetric.openFiles(of: measured), 87)
    }

    func testGroupTotalsRefuseToSumAnEntirelyUnmeasuredSet() {
        let group = ProcessGroupSnapshot(
            group: TrackedProcessGroup(title: "后端", matchPattern: "java"),
            matchedProcesses: [process(pid: 1, threads: 0, files: 0),
                               process(pid: 2, threads: 8, files: 40)])
        XCTAssertEqual(ProcessMetric.groupThreads(of: group), 8)
        XCTAssertEqual(ProcessMetric.groupOpenFiles(of: group), 40)
        XCTAssertEqual(ProcessMetric.threadsCovered(in: group), 1, "1/2 个进程取到，覆盖度要数得出来")
        XCTAssertEqual(ProcessMetric.openFilesCovered(in: group), 1)

        let allBlind = ProcessGroupSnapshot(
            group: TrackedProcessGroup(title: "内核态", matchPattern: "kernel_task"),
            matchedProcesses: [process(pid: 0, threads: 0, files: 0)])
        XCTAssertNil(ProcessMetric.groupThreads(of: allBlind))
        XCTAssertNil(ProcessMetric.groupOpenFiles(of: allBlind))
    }

    // MARK: - 着色：一色一义 + 缺证据不给倾向色

    func testLoadLevelsAreMonotonicAndNeverUseInteractionBlue() {
        XCTAssertEqual(LoadLevel.role(for: nil).name, "neutral")
        XCTAssertEqual(LoadLevel.role(for: 0.1).name, "success")
        XCTAssertEqual(LoadLevel.role(for: 0.61).name, "warning")
        XCTAssertEqual(LoadLevel.role(for: 0.9).name, "danger")
        XCTAssertNotEqual(LoadLevel.role(for: 0.1).name, "accent",
                          "蓝只表示交互 / 选中，不能兼任「负载正常」")
    }

    func testProcessCPUColorOnlyAppearsAboveOneFullCore() {
        XCTAssertEqual(PerformanceProcessTableCard.cpuLevel(cores: nil), .absent)
        XCTAssertEqual(PerformanceProcessTableCard.cpuLevel(cores: 0.4), .idle)
        XCTAssertEqual(PerformanceProcessTableCard.cpuLevel(cores: 1.2), .busy)
        XCTAssertEqual(PerformanceProcessTableCard.cpuLevel(cores: 2.0), .heavy)
    }

    // MARK: - 空态句式（验收点 5：没匹配到 ≠ 没开启监控）

    func testGroupEmptyStateSeparatesNoMatchFromMonitoringOff() {
        let empty = ProcessGroupSnapshot(group: TrackedProcessGroup(title: "后端", matchPattern: "java"),
                                        matchedProcesses: [])
        let filled = ProcessGroupSnapshot(group: TrackedProcessGroup(title: "后端", matchPattern: "java"),
                                         matchedProcesses: [process(pid: 5, threads: 4, files: 20)])

        XCTAssertEqual(PerformanceGroupCard.matchState(context: context(nil), group: empty),
                       .waitingFirstSample)
        XCTAssertEqual(PerformanceGroupCard.matchState(
            context: context(snapshot(used: 8, total: 16), paused: true), group: empty),
            .pausedWithoutMatch)
        XCTAssertEqual(PerformanceGroupCard.matchState(
            context: context(snapshot(used: 8, total: 16)), group: empty), .noMatch)
        XCTAssertEqual(PerformanceGroupCard.matchState(
            context: context(snapshot(used: 8, total: 16), paused: true), group: filled), .matched,
            "命中了就不算空态，哪怕采样已经暂停")

        // 徽标文字必须互不相同，并排两张卡才分得出来（截图复核问题 4）。
        let badges: Set<String> = [.waitingFirstSample, .pausedWithoutMatch, .noMatch, .matched]
            .map { PerformanceGroupCard.badgeText(for: $0) }
            .reduce(into: Set<String>()) { $0.insert($1) }
        XCTAssertEqual(badges.count, 4, "四种状态共用一个徽标文字就等于没区分")
        XCTAssertEqual(PerformanceGroupCard.badgeRole(for: .noMatch).name, "neutral",
                       "零命中是「没有」，不是「危险」，不能上红")
        XCTAssertEqual(PerformanceGroupCard.badgeRole(for: .pausedWithoutMatch).name, "warning")
    }

    func testZeroMatchCopyAlwaysEndsWithANextStep() {
        for state in [GroupMatchState.waitingFirstSample, .pausedWithoutMatch, .noMatch] {
            let copy = PerformanceGroupCard.copy(for: state, pattern: "java", totalProcesses: 512)
            XCTAssertFalse(copy.title.isEmpty, "\(state) 必须有一句现状")
            XCTAssertFalse(copy.message.isEmpty, "\(state) 必须有一句原因")
            XCTAssertFalse(copy.nextStep.isEmpty, "\(state) 必须给下一步，不能只留白")
        }
        XCTAssertTrue(PerformanceGroupCard.copy(for: .pausedWithoutMatch, pattern: "java", totalProcesses: 512)
                      .message.contains("暂停"))
        XCTAssertTrue(PerformanceGroupCard.copy(for: .noMatch, pattern: "java", totalProcesses: 512)
                      .message.contains("java"))
        XCTAssertTrue(PerformanceGroupCard.copy(for: .noMatch, pattern: "java", totalProcesses: nil)
                      .message.contains("--"), "连全系统进程数都没采到时，句子里也要用 --")
    }

    // MARK: - uptime

    func testUptimeTextGranularityAndMissing() {
        XCTAssertEqual(PerformanceSystemTiles.uptimeText(3 * 86_400 + 4 * 3_600), "3 天 4 小时")
        XCTAssertEqual(PerformanceSystemTiles.uptimeText(3_700), "1 小时 1 分")
        XCTAssertEqual(PerformanceSystemTiles.uptimeText(180), "3 分")
        XCTAssertEqual(PerformanceSystemTiles.uptimeText(nil), "--")
        XCTAssertEqual(PerformanceSystemTiles.uptimeText(-1), "--")
    }

}