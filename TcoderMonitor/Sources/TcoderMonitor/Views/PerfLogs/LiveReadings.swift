import SwiftUI

// MARK: - WS-M 三页共用的「读数在场性」层
//
// 这一层只回答一个问题：**这个数字到底有没有被取到**。
// 监控 App 最容易翻车的地方就是把「没取到」渲染成 0 或绿色正常（WS-D 已在此抛过真问题），
// 所以判据必须集中在一处、可被单测钉死，页面里不允许再写 `?? 0`。
//
// 规范落点：《40 WS-H》§7.3 三态句式 + §4.3 格式化器（不造第二套）。

// MARK: - 采样上下文

/// 「有没有上一帧」必须显式带进视图：CPU、磁盘、网络都是**差分**指标，
/// 只有首个样本时引擎按契约给 0，那 0 是「还没法算」，不是「机器空转」。
struct SampleContext: Equatable {
    let snapshot: SystemSnapshot?
    let historyCount: Int
    let isPaused: Bool

    /// 速率类指标需要两个点相减，因此少于 2 帧时一律不可信。
    var hasDerivative: Bool { snapshot != nil && historyCount >= 2 }

    @MainActor
    static func from(_ monitor: MachSystemMonitor) -> SampleContext {
        SampleContext(snapshot: monitor.latestSnapshot,
                      historyCount: monitor.history.count,
                      isPaused: !monitor.isRunning)
    }
}

// MARK: - 系统级读数的三态判定

enum SystemReadings {
    /// 全机 CPU 占用（0...1，1 = 所有核跑满）。无差分帧时给 nil。
    static func cpuFraction(_ ctx: SampleContext) -> Double? {
        guard let snapshot = ctx.snapshot, ctx.hasDerivative else { return nil }
        return min(max(snapshot.cpuUsage, 0), 1)
    }

    /// 把全机占用率换算成「几个核在用」。活动监视器的专业感来自给得出核数，
    /// 而不是把一个百分比堆到几百。
    static func coresInUse(_ ctx: SampleContext) -> Double? {
        guard let fraction = cpuFraction(ctx), let cores = ctx.snapshot?.cpuCoreCount, cores > 0 else { return nil }
        return fraction * Double(cores)
    }

    static func coreCount(_ ctx: SampleContext) -> Int? {
        guard let cores = ctx.snapshot?.cpuCoreCount, cores > 0 else { return nil }
        return cores
    }

    /// 内存口径与活动监视器一致：`总量 −（空闲 + 推测 + 可清除）`。
    ///
    /// ⚠️ 这里必须挡住一种假读数：采样引擎读 `vm_statistics64` 失败时返回**全零页计数**，
    /// 于是「可回收 = 0」→「已用 = 总量」→ 界面会画出一个 100% 占满的红色内存。
    /// 引擎侧的修法是加成功位（`Services/Performance` 不归本流），视图侧先把它接住：
    /// 已用 ≥ 总量在真机上不可能长期成立（空闲页为 0 的瞬间也会被压缩），一律按未取到处理。
    static func memoryUsedBytes(_ ctx: SampleContext) -> UInt64? {
        guard let snapshot = ctx.snapshot, snapshot.memoryTotalBytes > 0 else { return nil }
        guard snapshot.memoryUsedBytes < snapshot.memoryTotalBytes else { return nil }
        return snapshot.memoryUsedBytes
    }

    static func memoryTotalBytes(_ ctx: SampleContext) -> UInt64? {
        guard let snapshot = ctx.snapshot, snapshot.memoryTotalBytes > 0 else { return nil }
        return snapshot.memoryTotalBytes
    }

    static func memoryFraction(_ ctx: SampleContext) -> Double? {
        guard let used = memoryUsedBytes(ctx), let total = memoryTotalBytes(ctx), total > 0 else { return nil }
        return Double(used) / Double(total)
    }

    /// 内存压力由同一个可疑分母推导，所以跟着一起作废，不能单独信。
    static func memoryPressure(_ ctx: SampleContext) -> MemoryPressure? {
        guard memoryFraction(ctx) != nil, let pressure = ctx.snapshot?.memoryPressure, pressure != .unknown else { return nil }
        return pressure
    }

    /// 内核内存读数不可信时的说明句——空态必须给原因，不是留白。
    static func memoryGapReason(_ ctx: SampleContext) -> String? {
        guard let snapshot = ctx.snapshot, snapshot.memoryTotalBytes > 0 else { return nil }
        guard memoryUsedBytes(ctx) == nil else { return nil }
        return "本次未取到可信的空闲 / 可清除页计数"
    }

    /// 曲线只画可信的内存点。一个假 100% 尖峰会把整条曲线压扁，比少画一点更糟；
    /// 被剔除的数量必须在卡面上写出来，不能悄悄丢。
    static func trustedMemoryPoints(_ history: [SystemSnapshot]) -> [SystemSnapshot] {
        history.filter { snapshot in
            snapshot.memoryTotalBytes > 0 && snapshot.memoryUsedBytes < snapshot.memoryTotalBytes
        }
    }

    static func rejectedMemoryPoints(_ history: [SystemSnapshot]) -> Int {
        history.count - trustedMemoryPoints(history).count
    }

    static func diskBytesPerSecond(_ ctx: SampleContext) -> UInt64? {
        guard let snapshot = ctx.snapshot, ctx.hasDerivative else { return nil }
        return snapshot.diskReadBytesPerSecond &+ snapshot.diskWriteBytesPerSecond
    }

    static func diskReadBytesPerSecond(_ ctx: SampleContext) -> UInt64? {
        guard let snapshot = ctx.snapshot, ctx.hasDerivative else { return nil }
        return snapshot.diskReadBytesPerSecond
    }

    static func diskWriteBytesPerSecond(_ ctx: SampleContext) -> UInt64? {
        guard let snapshot = ctx.snapshot, ctx.hasDerivative else { return nil }
        return snapshot.diskWriteBytesPerSecond
    }

    static func networkBytesPerSecond(_ ctx: SampleContext) -> UInt64? {
        guard let snapshot = ctx.snapshot, ctx.hasDerivative else { return nil }
        return snapshot.networkInBytesPerSecond &+ snapshot.networkOutBytesPerSecond
    }

    static func networkInBytesPerSecond(_ ctx: SampleContext) -> UInt64? {
        guard let snapshot = ctx.snapshot, ctx.hasDerivative else { return nil }
        return snapshot.networkInBytesPerSecond
    }

    static func networkOutBytesPerSecond(_ ctx: SampleContext) -> UInt64? {
        guard let snapshot = ctx.snapshot, ctx.hasDerivative else { return nil }
        return snapshot.networkOutBytesPerSecond
    }

    /// 内存口径声明。活动监视器只画一个百分比，用户会读成「还剩多少可用」——
    /// 这一行把口径写在数旁边（WS-M 验收点 3）。
    static let memoryCaliber = "口径 = 总量 −（空闲 + 推测 + 可清除），与活动监视器一致；这是「在用」，不是「剩余可用」。"
}

// MARK: - 进程级读数的三态判定

enum ProcessMetric {
    /// 真实用户态进程至少 1 个线程；0 只可能是 `task_info` 没返回（内核任务 / 无权限）。
    static func threads(of process: ProcessSnapshot) -> Int? {
        process.threadCount > 0 ? process.threadCount : nil
    }

    /// 进程至少持有 stdin/stdout/stderr 三个描述符；0 = 本轮预算截断或无权限，不是「没打开文件」。
    static func openFiles(of process: ProcessSnapshot) -> Int? {
        process.openFileCount > 0 ? process.openFileCount : nil
    }

    /// `cpuUsage` 已经是「单核等价」之和（1.0 = 占满一个核），直接当核当量用。
    static func cpuCores(of process: ProcessSnapshot) -> Double {
        max(0, process.cpuUsage)
    }

    static func residentBytes(of process: ProcessSnapshot) -> UInt64 {
        process.memoryBytes
    }

    /// 组内求和只在「至少有一个进程取到」时成立；全组都没取到就返回 nil，
    /// 否则汇总卡会把「一个都没读到」显示成 0。
    static func groupThreads(of group: ProcessGroupSnapshot) -> Int? {
        sum(group.matchedProcesses.map(threads(of:)))
    }

    static func groupOpenFiles(of group: ProcessGroupSnapshot) -> Int? {
        sum(group.matchedProcesses.map(openFiles(of:)))
    }

    /// 「N/M 个进程取到」里的 N，用于把截断这件事量化到组，不藏进脚注。
    static func threadsCovered(in group: ProcessGroupSnapshot) -> Int {
        group.matchedProcesses.compactMap(threads(of:)).count
    }

    static func openFilesCovered(in group: ProcessGroupSnapshot) -> Int {
        group.matchedProcesses.compactMap(openFiles(of:)).count
    }

    static func peakMemory(of group: ProcessGroupSnapshot) -> UInt64? {
        guard !group.matchedProcesses.isEmpty else { return nil }
        return group.matchedProcesses.map(\.memoryBytes).max()
    }

    private static func sum(_ values: [Int?]) -> Int? {
        let present = values.compactMap { $0 }
        guard !present.isEmpty else { return nil }
        return present.reduce(0, +)
    }
}

// MARK: - 显示层：三态一律走这里

/// 把「可选读数」变成界面文字。规则只有一条：**没证据不产出数字**。
enum Live {
    static let missing = Theme.Placeholder.missingValue

    static func text(_ raw: String?) -> String { raw ?? missing }

    static func grouped(_ value: Int?) -> String {
        guard let value else { return missing }
        return NumberFormat.grouped(value)
    }

    static func percent(_ fraction: Double?, precision: Int = 0) -> String {
        guard let fraction else { return missing }
        return NumberFormat.percent(fraction, precision: precision)
    }

    /// 核当量：活动监视器的进程 CPU 是「占了几个核」，不是把百分比堆到几百。
    static func cores(_ cores: Double?) -> String {
        guard let cores else { return missing }
        return String(format: "%.2f", cores)
    }

    static func fixed(_ value: Double?, digits: Int) -> String {
        guard let value else { return missing }
        return String(format: "%.\(digits)f", value)
    }

    static func bytes(_ value: UInt64?, precision: Int = 1) -> String {
        guard let value else { return missing }
        return ByteFormat.string(value, precision: precision)
    }

    static func rate(_ value: UInt64?) -> String {
        guard let value else { return missing }
        return ByteFormat.rate(value)
    }

    static func bitRate(_ value: UInt64?) -> String {
        guard let value else { return missing }
        return ByteFormat.bitRate(value)
    }

    /// 渲染结果是不是占位符。用它决定着色，不重复实现判空。
    static func isMissing(_ displayed: String) -> Bool { displayed == missing }

    /// 占位符必须剥掉调用方的倾向色（「没数据」不该带任何颜色立场）。
    /// 单独做成谓词是为了可测：`Color` 由动态 NSColor 包出来，两次取值不相等。
    static func forcesNeutral(_ displayed: String) -> Bool { isMissing(displayed) }

    static func tint(_ displayed: String, real: Color) -> Color {
        forcesNeutral(displayed) ? Theme.Semantic.neutral.textColor : real
    }
}
