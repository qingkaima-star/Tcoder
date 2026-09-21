import Foundation
import Observation

// MARK: - 本文件的由来（WS-X6 规模债切片，2026-09-21）
//
// 这一组类型原先住在 `MachSystemMonitor.swift`，那个文件被本 App 自己扫成「巨大文件」（>400 行）。
// 心跳链路的四条语义**一字未动**：九格「同值不写」、`publish` 的失效面、
// `TCODER_PERF_PROBE=1` 才建 displayLink、暂停期跳过的帧仍进环形缓冲。
// 搬的只是**声明的住址**：采集与写格的那一半留在 `MachSystemMonitor.swift`，
// 因为 `PerfCadenceSingleSourceTests` 按**文件路径**读节拍真值常量，那几个常量不许搬家。
// 下面那段「细粒度读数格」的说明（含「本文件的改法」一句）原文照搬，其中
// 「本文件」指的是心跳链路这一组文件：派生值在采集侧算（`MachSystemMonitor.swift`），
// 算完的格子住在这里。

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
    /// `nil` = **还没有帧**。`ThermalState` 没有 unknown case（`Models` 冻结，
    /// `init(processInfoValue:)` 的 `default` 落到 `.nominal`），所以"取不到"在这个类型里
    /// 表达不出来。留成非 Optional 的话 `.empty` 只能填 `.nominal`，而它的字面就是"正常"——
    /// **一帧都没采到时界面会显示"温度状态 正常"**，把"没测到"渲染成"没问题"。
    /// 只闭掉"没有帧"这一半：有帧但 `process_info` 读失败仍会是 `.nominal`，
    /// 那是 `Models.ThermalState` 的既记录缺口，要修得动 Models，不在这里假装已修。
    var thermal: ThermalState?
    var uptimeSeconds: TimeInterval

    static let empty = PerfCPULead(usage: nil, coreCount: 0, load1: 0, load5: 0, load15: 0,
                                   thermal: nil, uptimeSeconds: 0)
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
