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
    var thermalState: ThermalState = .nominal
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

enum ThermalState: String, Codable, Sendable {
    case nominal = "正常"
    case fair = "尚可"
    case serious = "偏热"
    case critical = "过热"

    init(processInfoValue: Int) {
        switch processInfoValue {
        case 1: self = .fair
        case 2: self = .serious
        case 3: self = .critical
        default: self = .nominal
        }
    }
}

struct ProcessSnapshot: Codable, Equatable, Hashable, Identifiable, Sendable {
    var pid: Int32
    var name: String
    var cpuUsage: Double          // 0...1 per core-equivalent, can exceed 1 on multicore
    var memoryBytes: UInt64
    var threadCount: Int
    var openFileCount: Int
    var startTime: Date?
    var commandLine: String
    var parentPID: Int32

    var id: Int32 { pid }
    var normalizedCPU: Double { max(0, min(cpuUsage, Double(ProcessInfoWrapper.processorCount))) }
}

/// A group of processes the user cares about, e.g. "示例服务" == all java
/// processes whose command line matches a chosen pattern.
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

    static let builtInDefaults: [TrackedProcessGroup] = [
        TrackedProcessGroup(title: "Java 服务", matchPattern: "java", isBuiltIn: true),
        TrackedProcessGroup(title: "Node 服务", matchPattern: "node", isBuiltIn: true),
        TrackedProcessGroup(title: "MySQL", matchPattern: "mysqld", isBuiltIn: true),
        TrackedProcessGroup(title: "Redis", matchPattern: "redis-server", isBuiltIn: true),
        TrackedProcessGroup(title: "Nginx", matchPattern: "nginx", isBuiltIn: true),
    ]
}

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
