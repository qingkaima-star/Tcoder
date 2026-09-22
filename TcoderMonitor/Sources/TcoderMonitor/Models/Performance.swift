import Foundation

// MARK: - System & process performance

struct SystemSnapshot: Codable, Equatable, Identifiable, Sendable {
    var timestamp: Date = Date()

    /// Unique enough at 1.5s sampling intervals; lets Swift Charts bind directly.
    var id: TimeInterval { timestamp.timeIntervalSince1970 }

    /// 0...1 across all cores (1.0 == every core saturated).
    var cpuUsage: Double = 0
    var cpuCoreCount: Int = 0
    var memoryUsedBytes: UInt64 = 0
    var memoryTotalBytes: UInt64 = 0
    var memoryPressure: MemoryPressure = .normal

    /// Bytes per second, sampled between the two previous ticks.
    var diskReadBytesPerSecond: UInt64 = 0
    var diskWriteBytesPerSecond: UInt64 = 0
    var networkInBytesPerSecond: UInt64 = 0
    var networkOutBytesPerSecond: UInt64 = 0

    var loadAverage1: Double = 0
    var loadAverage5: Double = 0
    var loadAverage15: Double = 0
    var processCount: Int = 0
    /// 默认值是 **`.unknown`（未量到）而不是 `.nominal`（正常）**（RD-34）。
    /// 这一度是 `.nominal`，后果比 `init(processInfoValue:)` 的 `default` 更隐蔽：
    /// `SystemSnapshot()` 只要被构造出来、还没被采样器填过，它就已经在说"温度正常"——
    /// "一帧都没采到"和"采到了但这一项读失败"都会长出同一个绿脸。
    /// 改默认值时查过全部构造点：`Sources` 里只有 `SystemSampler.snapshot` 一处（它随后即赋值），
    /// `Tests` 里三处 `SystemSnapshot()` 全部走属性默认值，无显式传参、无二层转发把新默认盖回旧值。
    var thermalState: ThermalState = .unknown
    var uptimeSeconds: TimeInterval = 0

    var memoryFraction: Double {
        memoryTotalBytes == 0 ? 0 : Double(memoryUsedBytes) / Double(memoryTotalBytes)
    }
}

enum MemoryPressure: String, Codable, Sendable, CaseIterable {
    case normal = "正常"
    case warning = "偏高"
    case critical = "紧张"
    case unknown = "未知"
}

/// 机身热压力档位。**`rawValue` 就是上屏中文**（与 `MemoryPressure` 同一形状）。
///
/// RD-34：这个枚举原先只有四档，而 `init(processInfoValue:)` 用 `default: self = .nominal`
/// 收尾 —— 任何不认识的值（含"这一项压根没读到"由调用方喂进来的哨兵）都被翻译成"正常"。
/// 那正是"没有证据也给好结论"，与 AGENTS §4「数据缺失时不要显示为 0 假装是真实结果」同类。
/// 现在第五档 `.unknown` 是**显式缺席档**：量不到就走它，永不落到 `.nominal`。
///
/// ⚠️ 保留的边界（这一条仍然判不了，别当成已彻底修好）：
/// 在不支持热压力上报的机器上，`ProcessInfo.thermalState` **恒回 `.nominal`**，
/// 而系统没有受支持的 API 能问出"这台机器到底会不会报"。所以 `.nominal` 在那里
/// 依然可能是"这台机器根本没有这个概念"。本层能做到的极限是：**读不到 / 读不懂时绝不说正常**，
/// 并把那半句残余如实留在性能页的 ⓘ 里。
enum ThermalState: String, Codable, Sendable, CaseIterable {
    case nominal = "正常"
    case fair = "尚可"
    case serious = "偏热"
    case critical = "过热"
    /// 显式缺席档。只能由"没读到"或"读到的值不认识"产出，**不许**由默认分支顺手落到这里以外。
    case unknown = "未量到"

    /// 内核上报的 0...3 与四档一一对应；**其余一律 `.unknown`**（旧写法是 `default: .nominal`）。
    init(processInfoValue: Int) {
        switch processInfoValue {
        case 0: self = .nominal
        case 1: self = .fair
        case 2: self = .serious
        case 3: self = .critical
        default: self = .unknown
        }
    }

    /// 探针**压根没给值**与**给了个不认识的数**——两条缺席路共用这一个入口，
    /// 免得失焦的那半在各消费点自己写一次 `?? .nominal`。
    static func from(processInfoValue: Int?) -> ThermalState {
        guard let processInfoValue else { return .unknown }
        return ThermalState(processInfoValue: processInfoValue)
    }

    /// 这一档是不是一个测得的结论。评分与文案都拿它当闸门：`false` 时既不计分也不说"正常"。
    var isMeasured: Bool { self != .unknown }
}

struct ProcessSnapshot: Codable, Equatable, Hashable, Identifiable, Sendable {
    var pid: Int32
    var name: String
    var cpuUsage: Double          // 0...1 per core-equivalent, can exceed 1 on multicore
    var memoryBytes: UInt64
    var threadCount: Int
    var openFileCount: Int
    var startTime: Date?
    /// 可执行文件的绝对路径（`proc_pidpath`）。`nil` = **这一条没取到**（无权限 / 进程刚退出）。
    ///
    /// **旧字段名是 `commandLine`，那个名字在撒两个谎**（整改意见第九节点名的"名字兜底"）：
    /// ① 它从来不是 argv —— 本 App 只读可执行路径，不读任何人的命令行参数；
    /// ② `proc_pidpath` 失败时它装的是**进程名**（旧写法 `commandLinePath ?? name`），
    ///    于是"命令行里出现过这个词"与"只是进程名相同"在下游长得一模一样 ——
    ///    弱证据就这样被冒充成强归因。现在路径与名字各住各的字段，
    ///    两个消费点（`ProcessInspector.matches` 的匹配、进程表的 hover）各自显式表态。
    /// 形状保持 `Optional`：这样旧数据缺这一键也解得开（得 `nil`），不会整份解码失败。
    var executablePath: String?
    var parentPID: Int32

    var id: Int32 { pid }
    var normalizedCPU: Double { max(0, min(cpuUsage, Double(ProcessInfoWrapper.processorCount))) }
}

/// 用户关心的进程分组，例如「Java 服务」= 可执行路径或进程名命中某个模式的**全系统**进程。
struct TrackedProcessGroup: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: UUID
    var title: String
    var matchPattern: String
    var isBuiltIn: Bool

    init(id: UUID = UUID(), title: String, matchPattern: String, isBuiltIn: Bool = false) {
        self.id = id
        self.title = title
        self.matchPattern = matchPattern
        self.isBuiltIn = isBuiltIn
    }

    /// ⚠️ 边界（整改意见第九节）：`matchPattern` 匹配的是**整台机器**上的进程，
    /// 与当前选中的项目**没有任何关系** —— 分组快照因此不得被读成"这个项目的占用"。
    /// 下面这五条是写死的通用服务名，**不是**从项目名派生的：
    /// 「拿项目名去撞进程名」这种用弱证据冒充强归因的写法在这里不许长出来
    /// （守卫：`MachineVsProjectBoundaryTests`）。
    static let builtInDefaults: [TrackedProcessGroup] = [
        TrackedProcessGroup(title: "Java 服务", matchPattern: "java", isBuiltIn: true),
        TrackedProcessGroup(title: "Node 服务", matchPattern: "node", isBuiltIn: true),
        TrackedProcessGroup(title: "MySQL", matchPattern: "mysqld", isBuiltIn: true),
        TrackedProcessGroup(title: "Redis", matchPattern: "redis-server", isBuiltIn: true),
        TrackedProcessGroup(title: "Nginx", matchPattern: "nginx", isBuiltIn: true),
    ]
}

/// 一个分组的汇总。名字里之所以没有"项目"两个字：它的成员是**按匹配模式在全系统里查出来的**，
/// 命中多少算多少，本项目有没有在跑不影响这个数。
struct ProcessGroupSnapshot: Codable, Equatable, Identifiable, Sendable {
    var group: TrackedProcessGroup
    var matchedProcesses: [ProcessSnapshot]

    var id: UUID { group.id }
    var processCount: Int { matchedProcesses.count }
    var totalCPU: Double { matchedProcesses.reduce(0) { $0 + $1.cpuUsage } }
    var totalMemoryBytes: UInt64 { matchedProcesses.reduce(0) { $0 + $1.memoryBytes } }
    var totalThreads: Int { matchedProcesses.reduce(0) { $0 + $1.threadCount } }
    var totalOpenFiles: Int { matchedProcesses.reduce(0) { $0 + $1.openFileCount } }
}

enum ProcessInfoWrapper {
    static let processorCount = ProcessInfo.processInfo.activeProcessorCount
    static let physicalMemory = ProcessInfo.processInfo.physicalMemory
}

struct PerformanceHistory {
    var snapshots: [SystemSnapshot] = []
    var capacity: Int = 600

    mutating func append(_ snapshot: SystemSnapshot) {
        snapshots.append(snapshot)
        if snapshots.count > capacity { snapshots.removeFirst(snapshots.count - capacity) }
    }

    mutating func removeAll() { snapshots.removeAll() }
}
