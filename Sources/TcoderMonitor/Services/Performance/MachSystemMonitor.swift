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

    private static let historyCapacity = 600
    private static let topProcessLimit = 40

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
        tick()
        return latestSnapshot
    }

    // MARK: Sampling

    private func tick() {
        // 一轮 libproc 全量扫描可能要几百毫秒；没有这把锁的话定时器会叠出多个并发扫描，
        // 既拖慢主线程回投也把 previous 计数搞乱。
        guard !isSampling else { return }
        isSampling = true

        let elapsed = max(0.05, Date().timeIntervalSince(lastSweepAt))
        let previousCounters = self.previousCounters
        let previousProcesses = self.previousProcesses
        let groups = self.managedGroups
        let sampler = self.sampler

        Task.detached(priority: .utility) { [weak self] in
            let counters = sampler.read()
            let sweep = ProcessInspector.sweep(previous: previousProcesses, elapsed: elapsed)
            let snapshot = sampler.snapshot(
                previous: previousCounters,
                current: counters,
                processCount: sweep.processes.count
            )
            let groupSnapshots = ProcessInspector.groupSnapshots(
                for: groups,
                processes: sweep.processes
            )
            let ranked = Array(
                sweep.processes.sorted { $0.cpuUsage > $1.cpuUsage }
                    .prefix(MachSystemMonitor.topProcessLimit)
            )

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isSampling = false
                self.previousCounters = counters
                self.previousProcesses = sweep.states
                self.lastSweepAt = Date()
                self.latestSnapshot = snapshot
                self.topProcesses = ranked
                self.allProcesses = sweep.processes
                self.trackedGroups = groupSnapshots
                self.history.append(snapshot)
                if self.history.count > Self.historyCapacity {
                    self.history.removeFirst(self.history.count - Self.historyCapacity)
                }
            }
        }
    }

    private func refreshGroups() {
        // 用全量进程而不是 CPU top-N：常驻但空闲的服务（Redis、Nginx）恰恰是用户要盯的组，
        // 只从 CPU 榜里找会让它们显示成 0 进程。
        trackedGroups = ProcessInspector.groupSnapshots(for: managedGroups, processes: allProcesses)
    }
}
