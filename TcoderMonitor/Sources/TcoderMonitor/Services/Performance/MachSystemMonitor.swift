import Foundation
import Observation

// MARK: - 细粒度读数格（P 心跳链路包 · 给三家的目标契约）
//
// 【为什么要拆】xctrace 在产物 `465f5a6` 上量到：1.5 秒一次心跳引起 app-update
// 10.8~24.8 ms（预算 8.33 ms），主线程 64.3% 的样本落在
// `ViewGraphRootValueUpdater._updateViewGraph` / `AG::Graph::UpdateStack::update()`。
// render 相位是健康的（p95 4.05 ms），所以缺的不是 GPU 时间，是**一次 publish 的失效面**。
//
// 【机制】`@Observable` 的失效是**按属性记账**的：这一 tick 写了哪一格，读过那一格的
// 视图就得重算 body。旧实现一次 tick 连写 9~10 个属性，于是总览页、侧栏、性能页
// 整棵 body 跟着每次心跳重算。
//
// 【计算属性是同一个坑的另一半】旧 `processesByMemory` 每次访问都对 260~920 个进程
// 现做一次全量 `sorted`，并且「计算属性对底层的读」会被记成依赖，读它的视图每 tick
// 都被判成"可能变了"。本机实测（release、`-O` 探针）：900 元素全量排序 12.1 µs/每次访问、
// `Array(history.suffix(90))` 0.4 µs/每次访问——单次都不致命，致命的是它们被
// **每一次 body 求值**重复执行，全部堆进视图图更新。
//
// 【本文件的改法】派生值一律在采集侧（后台线程）算一次、存成数组；
// 写出去之前先比一次等值，**值没变就不换引用**，那一格这次 tick 完全不失效。
// 已用运行期探针（`withObservationTracking` 分别注册到两格）验证过：
// 写 A 格不会唤醒只读 B 格的观察者，同值写入不产生第二次唤醒。

// MARK: - 一格一个观察对象

/// 细粒度读数格。用 `let` 挂在 `MachSystemMonitor` 上——`let` 不进观察图，读它零成本，
/// 写入永远发生在格子自己的 `value` 上，所以视图只会被自己读的那一格带动。
@MainActor
@Observable
final class PerfCell<Value: Equatable> {
    private(set) var value: Value

    init(_ initial: Value) { self.value = initial }

    /// 只在值真的变了时才写。返回 `false` 表示这一格这次 tick 一个字节都没动、不失效。
    @discardableResult
    func apply(_ next: Value) -> Bool {
        guard next != value else { return false }
        value = next
        return true
    }
}

// MARK: - 每一格的形状（只搬证据，不重做三态判定）

/// CPU 与负载。`usage` 是**差分**量：没有上一帧就没有它，给 `nil` 而不是 0（T8）。
nonisolated struct PerfCPULead: Equatable, Sendable {
    var usage: Double?
    var coreCount: Int
    /// 负载三项与 `SystemSnapshot` 同口径（Models 冻结，非 Optional，见报告「契约缺口」）。
    var load1: Double
    var load5: Double
    var load15: Double
    var thermal: ThermalState
    var uptimeSeconds: TimeInterval

    static let empty = PerfCPULead(usage: nil, coreCount: 0, load1: 0, load5: 0, load15: 0,
                                   thermal: .nominal, uptimeSeconds: 0)
}

/// 内存。三态判定的**唯一归属**仍是 `Views/PerfLogs/LiveReadings.swift` 的
/// `SystemReadings.memoryUsedBytes(_:)`：这里只搬原始证据（含 `pressure == .unknown`
/// 这个"内核没给页计数"的信号），不许在本文件里再造第二套 guard——
/// 两套口径并存时，错的那套常在喂数据（本仓教训）。
nonisolated struct PerfMemoryLead: Equatable, Sendable {
    var usedBytes: UInt64
    var totalBytes: UInt64
    var pressure: MemoryPressure

    static let empty = PerfMemoryLead(usedBytes: 0, totalBytes: 0, pressure: .unknown)
}

/// 磁盘与网络的每秒速率。四项全是差分量，无上一帧一律 `nil`（T8）。
nonisolated struct PerfRateLead: Equatable, Sendable {
    var diskReadBytesPerSecond: UInt64?
    var diskWriteBytesPerSecond: UInt64?
    var networkInBytesPerSecond: UInt64?
    var networkOutBytesPerSecond: UInt64?

    static let empty = PerfRateLead(diskReadBytesPerSecond: nil, diskWriteBytesPerSecond: nil,
                                    networkInBytesPerSecond: nil, networkOutBytesPerSecond: nil)
}

/// 进程计数口径：全系统数（sysctl）、本轮真取到指标的子集、有没有被预算截断。
/// `countIsSystemWide == false` 时上面那个数只是本用户可见子集，视图不许再宣称"全系统"。
nonisolated struct PerfProcessLedger: Equatable, Sendable {
    var systemWideCount: Int
    var countIsSystemWide: Bool
    var measuredCount: Int
    var metricsTruncated: Bool

    static let empty = PerfProcessLedger(systemWideCount: 0, countIsSystemWide: false,
                                         measuredCount: 0, metricsTruncated: false)
}

/// 心跳本身：这一帧是什么时候的、攒了多少点。和读数分开成格，
/// 是为了让"上次采样 / 采样点"这类小读数不必拖着整个 `SystemSnapshot` 重算。
nonisolated struct PerfPulse: Equatable, Sendable {
    var sampleAt: Date?
    var historyCount: Int

    static let empty = PerfPulse(sampleAt: nil, historyCount: 0)
}

/// 一帧的全部派生结果。`nonisolated` + 纯函数构造：能在单测里直接喂两帧同样的输入，
/// 断言"没变的那一格不会换引用"，不需要真去扫机器。
nonisolated struct PerfLeads: Sendable {
    var cpu: PerfCPULead
    var memory: PerfMemoryLead
    var rates: PerfRateLead
    var ledger: PerfProcessLedger
    var cpuRanking: [ProcessSnapshot]
    var memoryRanking: [ProcessSnapshot]
    var groups: [ProcessGroupSnapshot]

    /// 全部排序、切片、组匹配都在**这一处、这一次**做完，且调用方决定在哪个线程跑
    /// （现在跑在后台）。主线程一次都不许再排。
    static func derive(previous: SystemCounters?,
                       snapshot: SystemSnapshot,
                       sweep: ProcessSweep,
                       totalProbe: ProcessCountProbe,
                       groups: [TrackedProcessGroup],
                       topLimit: Int) -> PerfLeads {
        // 差分量的在场性是同一个条件：有没有上一帧。视图侧 `SampleContext.hasDerivative`
        // （历史点数 ≥ 2）与这里等价，不是第二套口径。
        let derivative = previous != nil
        var cpuLead = PerfCPULead.empty
        cpuLead.usage = derivative ? snapshot.cpuUsage : nil
        cpuLead.coreCount = snapshot.cpuCoreCount
        cpuLead.load1 = snapshot.loadAverage1
        cpuLead.load5 = snapshot.loadAverage5
        cpuLead.load15 = snapshot.loadAverage15
        cpuLead.thermal = snapshot.thermalState
        cpuLead.uptimeSeconds = snapshot.uptimeSeconds

        var rateLead = PerfRateLead.empty
        if derivative {
            rateLead.diskReadBytesPerSecond = snapshot.diskReadBytesPerSecond
            rateLead.diskWriteBytesPerSecond = snapshot.diskWriteBytesPerSecond
            rateLead.networkInBytesPerSecond = snapshot.networkInBytesPerSecond
            rateLead.networkOutBytesPerSecond = snapshot.networkOutBytesPerSecond
        }

        return PerfLeads(
            cpu: cpuLead,
            memory: PerfMemoryLead(usedBytes: snapshot.memoryUsedBytes,
                                   totalBytes: snapshot.memoryTotalBytes,
                                   pressure: snapshot.memoryPressure),
            rates: rateLead,
            ledger: PerfProcessLedger(systemWideCount: totalProbe.count,
                                      countIsSystemWide: totalProbe.isSystemWide,
                                      measuredCount: sweep.processes.count,
                                      metricsTruncated: sweep.truncated),
            cpuRanking: Array(sweep.processes.sorted { $0.cpuUsage > $1.cpuUsage }.prefix(topLimit)),
            memoryRanking: Array(sweep.processes.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(topLimit)),
            groups: ProcessInspector.groupSnapshots(for: groups, processes: sweep.processes)
        )
    }
}

/// 进程计数的一次探测结果。
nonisolated struct ProcessCountProbe: Sendable {
    var count: Int
    /// true = 走 `sysctl(KERN_PROC_ALL)`，与 `ps -A` / `top` 同源；
    /// false = sysctl 没问到，`count` 退成本用户可见子集，视图要改口径显示。
    var isSystemWide: Bool
}

// MARK: - 交互期暂停的来源

/// 谁按下了暂停。集合语义：**同一个来源重复 begin 只算一票**，
/// 多个调用方（滚动、拖窗、切页）各自 begin/end，只有全部归还才恢复——
/// 谁都不许拿自己那一票的结束去提前解冻别人的。
enum LivePauseSource: Hashable, Sendable {
    case pointerStream      // 滚动 / 拖拽（`AppState` 的 NSEvent 本地监视器）
    case windowDrag         // 拖窗、live resize
    case pageTransition     // 切页动画
    case custom(String)
}

// MARK: - 心跳链路

/// Owns the periodic sampling loop. Heavy Mach/libproc work runs off the main actor;
/// only the readout cells are touched on main.
/// `@Observable` is required: AppState only publishes the reference, so without it
/// SwiftUI never re-renders as the samples arrive.
@MainActor
@Observable
final class MachSystemMonitor: SystemMonitoringProviding {
    private let sampler = SystemSampler()
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    /// 上一**帧**（不是上一发布帧）的累计量。交互暂停期间照样推进，
    /// 这样恢复出来的速率仍然是逐帧差分，不会把整段暂停摊成一帧。
    @ObservationIgnored private var previousCounters: SystemCounters?
    @ObservationIgnored private var previousProcesses: [Int32: ProcessCPUState] = [:]
    @ObservationIgnored private var lastCollectedAt = Date()
    @ObservationIgnored private var isCollecting = false
    @ObservationIgnored private var managedGroups: [TrackedProcessGroup] = TrackedProcessGroup.builtInDefaults

    /// 真实历史环形缓冲：每一帧都必须进来，**包括交互暂停期间没往界面写的帧**
    /// （规范红线：严禁把暂停期画成 0 或空白）。
    @ObservationIgnored private var frames: [SystemSnapshot] = []

    // MARK: 细粒度格（三家的目标契约；名字要稳）

    /// 读数只在这里落格。`let` 不进观察图 → 读 `monitor.cpu` 本身不产生依赖，
    /// 产生依赖的是 `monitor.cpu.value`，于是只有 CPU 这一格变时才有人重算。
    let cpu = PerfCell<PerfCPULead>(.empty)
    let memory = PerfCell<PerfMemoryLead>(.empty)
    let rates = PerfCell<PerfRateLead>(.empty)
    let ledger = PerfCell<PerfProcessLedger>(.empty)
    let pulse = PerfCell<PerfPulse>(.empty)
    let cpuRanking = PerfCell<[ProcessSnapshot]>([])
    let memoryRanking = PerfCell<[ProcessSnapshot]>([])
    let groupRanking = PerfCell<[ProcessGroupSnapshot]>([])
    /// 曲线滚动窗口（最旧的在前，正好 `curveWindowPoints` 个点）。
    /// 给 `PerformanceView.chartWindow` 与总览页 `CPUHistoryChart` 用：以前每家每次
    /// body 都自己 `Array(history.suffix(90))`，现在一 tick 只切一次。
    let curve = PerfCell<[SystemSnapshot]>([])

    // MARK: 粗粒度兼容层（三家迁走之前必须保持每 tick 更新，棘轮盯调用点数）

    private(set) var latestSnapshot: SystemSnapshot?
    private(set) var history: [SystemSnapshot] = []
    private(set) var topProcesses: [ProcessSnapshot] = []
    private(set) var trackedGroups: [ProcessGroupSnapshot] = []
    private(set) var isRunning = false

    /// 按内存降序的榜单。**存储属性**：以前是计算属性，每次访问对全量进程现排序，
    /// 而计算属性对底层的读会被记成依赖 → 整棵 body 每 tick 抖一次。
    /// 排序现在在采集侧（后台线程）做，见 `PerfLeads.derive`。
    private(set) var processesByMemory: [ProcessSnapshot] = []

    /// 本轮真正取到指标的进程数。无权限时它小于 `latestSnapshot.processCount`
    /// （后者是全系统总数），视图要把两者都显示出来，不能拿子集冒充全集。
    private(set) var measuredProcessCount = 0

    /// 打开文件数枚举被时间预算截断过，进程句柄列要标注「部分」。
    private(set) var processMetricsTruncated = false

    /// 采集在飞：按钮转圈用的就是这个，**不是**"缺数据"占位态（缺数据仍走 `--`）。
    private(set) var isCollectingForDisplay = false

    /// 最近一轮扫到的全量进程，只在内存里留一帧，用来做组刷新的正确排名。
    /// `@ObservationIgnored`：全仓视图零读点（已核），把它留在观察图里只会白搭一次失效面。
    @ObservationIgnored private(set) var allProcesses: [ProcessSnapshot] = []

    // MARK: 交互期暂停（T3）

    /// 暂停中的来源集合。空 = 正常刷新。
    @ObservationIgnored private var livePauseSources: Set<LivePauseSource> = []
    /// 视图可选读它来解释"为什么数不跳"。**没有**新增任何"未刷新"字面，
    /// 现成的说法只有 `SampleContext.isPaused` 那条横幅（用户手动暂停时才出现）。
    private(set) var isInteractionPaused = false
    /// 暂停期间攒下的帧（只留最新一帧的派生榜单，避免把 900 进程的数组按秒堆几十份）。
    @ObservationIgnored private var pendingLatestBatch: SampleBatch?

    // 后台采样闭包里要用，标 nonisolated 免得跨 actor 取值。
    nonisolated private static let historyCapacity = 600
    nonisolated private static let topProcessLimit = 20

    /// 曲线滚动窗口点数。`PerformanceView.chartPointLimit` 与总览页都是 90，
    /// 这里收成一处，免得两个页面各切一次、各说一套。
    nonisolated static let curveWindowPoints = 90

    // MARK: 诊断（不进观察图，给单测与探针读）

    struct PublishStats: Equatable {
        var ticks = 0
        var writes = 0
        var skips = 0
    }

    @ObservationIgnored private(set) var lastPublishStats = PublishStats()

    // MARK: Surfaces PerformanceView expects

    var lastSampleAt: Date? { latestSnapshot?.timestamp }

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

    // MARK: 采样节拍唯一真值（性能 spec §5.1）
    //
    // 此前节拍在 `AppState` 与 `toggleRunning()` 里各写了一次 `1_500`，
    // 而界面有 4 处把「1.5 秒」当字面量写死、还有 1 处把它写进算术
    // （`PerformanceView.windowSeconds`）。改节拍只动一处必然说谎。
    // 所以：数值只在这里定义一次，展示文案与窗口秒数都从它派生。

    nonisolated static let defaultSampleIntervalMilliseconds: UInt64 = 1_500

    /// 实际生效的节拍（`start(intervalMilliseconds:)` 记下的那个，含 500ms 下限）。
    private(set) var sampleIntervalMilliseconds: UInt64 = MachSystemMonitor.defaultSampleIntervalMilliseconds

    /// 页面副标题/提示语唯一该用的节拍文案，例：「1.5 秒」。
    var sampleIntervalText: String {
        let seconds = Double(sampleIntervalMilliseconds) / 1000
        return seconds == seconds.rounded()
            ? "\(Int(seconds)) 秒"
            : String(format: "%.1f 秒", seconds)
    }

    /// 曲线滚动窗口的秒数——**由节拍派生**，不许页面自己乘一个魔法数。
    func windowSeconds(pointCount: Int) -> TimeInterval {
        Double(pointCount) * Double(sampleIntervalMilliseconds) / 1000
    }

    // MARK: Lifecycle

    func start(intervalMilliseconds: UInt64) {
        guard loopTask == nil else { return }
        isRunning = true
        let milliseconds = max(500, intervalMilliseconds)
        sampleIntervalMilliseconds = milliseconds
        loopTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
                if Task.isCancelled { break }
                await self?.scheduleCollection()
            }
        }
        // First sample arrives immediately so the dashboard is not blank for one interval.
        Task { @MainActor in self.scheduleCollection() }
    }

    /// Pause/resume for the performance page.
    func toggleRunning() {
        if isRunning {
            stop()
        } else {
            start(intervalMilliseconds: sampleIntervalMilliseconds)
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        isRunning = false
    }

    @discardableResult
    func sampleNow() -> SystemSnapshot? {
        // 协议要求「同步算一次并返回」，T7 要求全量 sweep 不得占主线程。两者的接法是：
        // **只有一帧都没有**（冷启动）时才就地算一次——那时屏幕上没有任何旧值可显示，
        // 就地算比"先空一屏再补"更诚实；此后一律交后台，主线程只回最近一帧。
        // 实测本机一轮全量 sweep 0.36 ms、`SystemSampler.read` 0.10 ms、旧 `processCount()`
        // 整块缓冲 0.11 ms（含 623 KB 分配），合起来就是这条同步路径原先压在主线程上的量。
        if frames.isEmpty, !isCollecting {
            ingest(collectBatch(elapsed: currentElapsed()))
            return latestSnapshot
        }
        scheduleCollection()
        return latestSnapshot
    }

    // MARK: 交互期暂停入口（三家的契约）
    //
    // 用法（引用计数式，同一个来源重复调用只算一票）：
    //     monitor.beginInteractionPause(.pageTransition)
    //     // …切页动画期间不往界面写任何东西…
    //     monitor.endInteractionPause(.pageTransition)
    // 滚动与拖窗不用页面自己接：`AppState` 里的 `NSEvent` 本地监视器已经按
    // `.pointerStream` / `.windowDrag` 接管，并按"停止 150 毫秒后恢复"归还在途票。
    //
    // 暂停期**照样采集、照样进环形缓冲**，只是一格都不写：
    // 屏幕上保持真实末值，恢复后曲线里是完整的真实轨迹——既没有 0，也没有空白。

    func beginInteractionPause(_ source: LivePauseSource = .pointerStream) {
        livePauseSources.insert(source)
        _ = publishValue(\.isInteractionPaused, true)
    }

    func endInteractionPause(_ source: LivePauseSource = .pointerStream) {
        guard !livePauseSources.isEmpty else { return }   // 没 begin 过的 end 不许把状态往反里带
        livePauseSources.remove(source)
        guard livePauseSources.isEmpty else { return }    // 还有别人的票 → 谁都不许单独解冻
        _ = publishValue(\.isInteractionPaused, false)
        // 暂停期间攒下的"在途"旗标按真实状态补一次（整段暂停只写这一次）。
        _ = publishValue(\.isCollectingForDisplay, isCollecting)
        drainPendingFrames()
    }

    // MARK: Sampling

    /// 一次采样的产物。nonisolated 才能在后台线程构造后回投主线程。
    nonisolated private struct SampleBatch {
        let counters: SystemCounters
        let sweep: ProcessSweep
        let snapshot: SystemSnapshot
        let leads: PerfLeads
    }

    private func currentElapsed() -> TimeInterval {
        max(0.05, Date().timeIntervalSince(lastCollectedAt))
    }

    /// 所有 Mach / libproc / sysctl 调用都集中在这里同步执行，由调用方决定在哪个线程跑。
    /// 派生（排序、组匹配）也在这一层做完 → 主线程只负责"写格"。
    private nonisolated static func collect(sampler: SystemSampler,
                                            previousCounters: SystemCounters?,
                                            previousProcesses: [Int32: ProcessCPUState],
                                            groups: [TrackedProcessGroup],
                                            elapsed: TimeInterval) -> SampleBatch {
        let counters = sampler.read()
        let sweep = ProcessInspector.sweep(previous: previousProcesses, elapsed: elapsed)
        // 总数走 sysctl（与 top / 活动监视器同源）；sweep 只能覆盖本用户可查询的子集。
        // 探针数直接复用这一轮已经枚举到的可见 pid 数，不再为拿一个整数第二次遍历内核。
        let totalProbe = ProcessInspector.processCountProbe(visiblePIDCount: sweep.visiblePIDCount)
        let snapshot = sampler.snapshot(previous: previousCounters, current: counters,
                                        processCount: totalProbe.count)
        let leads = PerfLeads.derive(previous: previousCounters, snapshot: snapshot, sweep: sweep,
                                     totalProbe: totalProbe, groups: groups,
                                     topLimit: topProcessLimit)
        return SampleBatch(counters: counters, sweep: sweep, snapshot: snapshot, leads: leads)
    }

    private func collectBatch(elapsed: TimeInterval) -> SampleBatch {
        MachSystemMonitor.collect(sampler: sampler, previousCounters: previousCounters,
                                  previousProcesses: previousProcesses, groups: managedGroups,
                                  elapsed: elapsed)
    }

    /// 定时器与手动刷新共用的入口：只安排一次后台采集，不碰界面。
    private func scheduleCollection() {
        guard !isCollecting else { return }
        // 一轮 libproc 全量扫描可能几百毫秒；没有这把锁定时器会叠出多个并发扫描，
        // 既拖慢主线程回投也把 previous 计数搞乱。
        isCollecting = true
        // 暂停期一格都不写：这条也一样，界面上保持"最后一次真实写入"的样子。
        if !isInteractionPaused { _ = publishValue(\.isCollectingForDisplay, true) }

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
            await MainActor.run { [weak self] in self?.ingest(batch) }
        }
    }

    /// 主线程上唯一处理一帧的地方：先推进差分链，再决定"写界面"还是"只攒着"。
    private func ingest(_ batch: SampleBatch) {
        isCollecting = false

        // 差分链在**采集侧**推进，跟有没有往界面写无关：
        // 暂停期间攒下的每一帧都是和它前一帧相减的，恢复时不会把整段暂停摊成一个速率。
        previousCounters = batch.counters
        previousProcesses = batch.sweep.states
        lastCollectedAt = Date()

        // 真实历史：每帧都进环形缓冲，容量淘汰只留最新（T8 语义一字未改）。
        frames.append(batch.snapshot)
        if frames.count > Self.historyCapacity {
            frames.removeFirst(frames.count - Self.historyCapacity)
        }

        guard !isInteractionPaused else {
            // 只留最新一帧的派生榜单：一帧的进程榜是几百个结构体，
            // 把暂停期间每一帧都攒下去，恢复前内存能涨几十 MB，那才是新的卡顿源。
            // 历史帧本身（约 112 字节/帧）已经全部进了 `frames`，一帧都没丢。
            pendingLatestBatch = batch
            return
        }
        _ = publishValue(\.isCollectingForDisplay, false)
        publish(batch)
    }

    /// 恢复：把暂停期间攒下的帧补进粗粒度历史，再用最新一帧写一次格。
    /// 一次写完 → 视图图只更新一次，不是"每攒一帧抖一次"。
    private func drainPendingFrames() {
        guard let batch = pendingLatestBatch else { return }
        pendingLatestBatch = nil
        publish(batch)
    }

    /// 写界面。全部写入都过等值闸门：值没变的那一格连引用都不换。
    private func publish(_ batch: SampleBatch) {
        var stats = PublishStats(ticks: lastPublishStats.ticks + 1)
        let leads = batch.leads

        func writeCell<Value: Equatable>(_ cell: PerfCell<Value>, _ next: Value) {
            if cell.apply(next) { stats.writes += 1 } else { stats.skips += 1 }
        }

        // 1) 细粒度格
        writeCell(cpu, leads.cpu)
        writeCell(memory, leads.memory)
        writeCell(rates, leads.rates)
        writeCell(ledger, leads.ledger)
        writeCell(cpuRanking, leads.cpuRanking)
        writeCell(memoryRanking, leads.memoryRanking)
        writeCell(groupRanking, leads.groups)

        // 2) 粗粒度兼容层：三家迁到细粒度格之前必须照样每 tick 更新。
        //    同值不写（`measuredProcessCount`、`processMetricsTruncated`、内存榜
        //    这些经常整帧不变，以前是无脑换新引用拖着整棵 body 重算）。
        latestSnapshot = batch.snapshot
        write(\.topProcesses, leads.cpuRanking, &stats)
        write(\.processesByMemory, leads.memoryRanking, &stats)
        write(\.trackedGroups, leads.groups, &stats)
        write(\.measuredProcessCount, leads.ledger.measuredCount, &stats)
        write(\.processMetricsTruncated, leads.ledger.metricsTruncated, &stats)
        allProcesses = batch.sweep.processes        // 不进观察图

        // 3) 历史与曲线窗口
        history = frames
        writeCell(pulse, PerfPulse(sampleAt: batch.snapshot.timestamp, historyCount: frames.count))
        writeCell(curve, Array(frames.suffix(Self.curveWindowPoints)))

        lastPublishStats = stats
    }

    /// 只有值真的变了才写：不换引用 → 读了这一格的视图不失效。
    @discardableResult
    private func publishValue<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<MachSystemMonitor, Value>,
                                                _ next: Value) -> Bool {
        guard self[keyPath: keyPath] != next else { return false }
        self[keyPath: keyPath] = next
        return true
    }

    /// `publish` 内部用的同值闸门（要把计数写进局部 `stats`，所以和上面那条分开）。
    @discardableResult
    private func write<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<MachSystemMonitor, Value>,
                                         _ next: Value,
                                         _ stats: inout PublishStats) -> Bool {
        guard self[keyPath: keyPath] != next else {
            stats.skips += 1
            return false
        }
        stats.writes += 1
        self[keyPath: keyPath] = next
        return true
    }

    private func refreshGroups() {
        // 用全量进程而不是 CPU top-N：常驻但空闲的服务（Redis、Nginx）恰恰是用户要盯的组，
        // 只从 CPU 榜里找会让它们显示成 0 进程。
        let next = ProcessInspector.groupSnapshots(for: managedGroups, processes: allProcesses)
        trackedGroups = next
        groupRanking.apply(next)
    }
}
