import Foundation
import Observation

/// Owns the periodic sampling loop. Heavy Mach/libproc work runs off the main actor;
/// only the four published properties are touched on main.
/// `@Observable` is required: AppState only publishes the reference, so without it
/// SwiftUI never re-renders as the samples arrive.
@MainActor
@Observable
final class MachSystemMonitor: SystemMonitoringProviding {
    private let sampler = SystemSampler()
    private var loopTask: Task<Void, Never>?
    private var previousCounters: SystemCounters?
    private var previousProcesses: [Int32: ProcessCPUState] = [:]
    private var lastSweepAt = Date()
    private var isSampling = false
    private var managedGroups: [TrackedProcessGroup] = TrackedProcessGroup.builtInDefaults

    private(set) var latestSnapshot: SystemSnapshot?
    private(set) var history: [SystemSnapshot] = []
    private(set) var topProcesses: [ProcessSnapshot] = []
    private(set) var trackedGroups: [ProcessGroupSnapshot] = []
    private(set) var isRunning = false

    /// 最近一轮扫到的全量进程，只在内存里留一帧，用来做「按内存排序」的正确排名。
    private(set) var allProcesses: [ProcessSnapshot] = []

    /// 本轮真正取到指标的进程数。无权限时它小于 `latestSnapshot.processCount`
    /// （后者是全系统总数），视图要把两者都显示出来，不能拿子集冒充全集。
    private(set) var measuredProcessCount = 0

    /// 打开文件数枚举被时间预算截断过，进程句柄列要标注「部分」。
    private(set) var processMetricsTruncated = false

    // 后台采样闭包里要用，标 nonisolated 免得跨 actor 取值。
    nonisolated private static let historyCapacity = 600
    nonisolated private static let topProcessLimit = 40

    // MARK: Surfaces PerformanceView expects

    var lastSampleAt: Date? { latestSnapshot?.timestamp }

    /// 按内存降序 —— 从全量进程里排，不能从 CPU top-N 里排，否则内存大户只要不忙就永远看不到。
    var processesByMemory: [ProcessSnapshot] {
        Array(allProcesses.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(Self.topProcessLimit))
    }

    func groups() -> [TrackedProcessGroup] { managedGroups }

    @discardableResult
    func addGroup(title: String, matchPattern: String) -> TrackedProcessGroup? {
        let pattern = matchPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return nil }
        if let existing = managedGroups.first(where: {
            $0.matchPattern.caseInsensitiveCompare(pattern) == .orderedSame
        }) {
            return existing
        }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = TrackedProcessGroup(
            title: name.isEmpty ? pattern : name,
            matchPattern: pattern
        )
        managedGroups.append(group)
        refreshGroups()
        return group
    }

    func removeGroup(id: UUID) {
        managedGroups.removeAll { $0.id == id }
        refreshGroups()
    }

    /// Register extra matchers for a project (e.g. a service named after the repo).
    func ensureGroup(title: String, matchPattern: String) {
        guard managedGroups.contains(where: { $0.title == title }) == false else { return }
        addGroup(title: title, matchPattern: matchPattern)
    }

    // MARK: Lifecycle

    func start(intervalMilliseconds: UInt64) {
        guard loopTask == nil else { return }
        isRunning = true
        let milliseconds = max(500, intervalMilliseconds)
        loopTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
                if Task.isCancelled { break }
                await self?.tick()
            }
        }
        // First sample arrives immediately so the dashboard is not blank for 1.5s.
        Task { @MainActor in self.tick() }
    }

    /// Pause/resume for the performance page.
    func toggleRunning() {
        if isRunning {
            stop()
        } else {
            start(intervalMilliseconds: 1_500)
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        isRunning = false
    }

    @discardableResult
    func sampleNow() -> SystemSnapshot? {
        // 协议要求「同步算一次并返回」，所以手动刷新就在调用线程跑完（全量 sweep 实测 0–8ms）。
        // 后台定时器在跑时不抢同一次采样，直接回最近一帧。
        guard !isSampling else { return latestSnapshot }
        publish(collectBatch(elapsed: currentElapsed()))
        return latestSnapshot
    }

    // MARK: Sampling

    /// 一次采样的产物。nonisolated 才能在后台线程构造后回投主线程。
    nonisolated private struct SampleBatch {
        let counters: SystemCounters
        let sweep: ProcessSweep
        let snapshot: SystemSnapshot
        let groupSnapshots: [ProcessGroupSnapshot]
        let top: [ProcessSnapshot]
    }

    private func currentElapsed() -> TimeInterval {
        max(0.05, Date().timeIntervalSince(lastSweepAt))
    }

    /// 所有 Mach / libproc / sysctl 调用都集中在这里同步执行，由调用方决定在哪个线程跑。
    private nonisolated static func collect(sampler: SystemSampler,
                                            previousCounters: SystemCounters?,
                                            previousProcesses: [Int32: ProcessCPUState],
                                            groups: [TrackedProcessGroup],
                                            elapsed: TimeInterval) -> SampleBatch {
        let counters = sampler.read()
        let sweep = ProcessInspector.sweep(previous: previousProcesses, elapsed: elapsed)
        // 总数走 sysctl（与 top / 活动监视器同源）；sweep 只能覆盖本用户可查询的子集。
        let totalProcesses = ProcessInspector.processCount()
        let snapshot = sampler.snapshot(previous: previousCounters, current: counters,
                                        processCount: totalProcesses)
        let groupSnapshots = ProcessInspector.groupSnapshots(for: groups, processes: sweep.processes)
        let top = Array(sweep.processes.sorted { $0.cpuUsage > $1.cpuUsage }.prefix(topProcessLimit))
        return SampleBatch(counters: counters, sweep: sweep, snapshot: snapshot,
                           groupSnapshots: groupSnapshots, top: top)
    }

    private func collectBatch(elapsed: TimeInterval) -> SampleBatch {
        MachSystemMonitor.collect(sampler: sampler, previousCounters: previousCounters,
                                  previousProcesses: previousProcesses, groups: managedGroups,
                                  elapsed: elapsed)
    }

    private func publish(_ batch: SampleBatch) {
        isSampling = false
        previousCounters = batch.counters
        previousProcesses = batch.sweep.states
        lastSweepAt = Date()
        latestSnapshot = batch.snapshot
        topProcesses = batch.top
        allProcesses = batch.sweep.processes
        measuredProcessCount = batch.sweep.processes.count
        processMetricsTruncated = batch.sweep.truncated
        trackedGroups = batch.groupSnapshots
        history.append(batch.snapshot)
        if history.count > Self.historyCapacity {
            history.removeFirst(history.count - Self.historyCapacity)
        }
    }

    private func tick() {
        // 一轮 libproc 全量扫描可能几百毫秒；没有这把锁定时器会叠出多个并发扫描，
        // 既拖慢主线程回投也把 previous 计数搞乱。
        guard !isSampling else { return }
        isSampling = true

        let sampler = self.sampler
        let previousCounters = self.previousCounters
        let previousProcesses = self.previousProcesses
        let groups = self.managedGroups
        let elapsed = currentElapsed()

        Task.detached(priority: .utility) {
            let batch = MachSystemMonitor.collect(sampler: sampler,
                                                  previousCounters: previousCounters,
                                                  previousProcesses: previousProcesses,
                                                  groups: groups,
                                                  elapsed: elapsed)
            await MainActor.run { [weak self] in self?.publish(batch) }
        }
    }

    private func refreshGroups() {
        // 用全量进程而不是 CPU top-N：常驻但空闲的服务（Redis、Nginx）恰恰是用户要盯的组，
        // 只从 CPU 榜里找会让它们显示成 0 进程。
        trackedGroups = ProcessInspector.groupSnapshots(for: managedGroups, processes: allProcesses)
    }
}
