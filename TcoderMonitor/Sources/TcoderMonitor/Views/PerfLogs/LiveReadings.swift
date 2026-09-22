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
    /// 「有没有证据」走 WS-C 在 `8333852` 定下并测过的两个公开信号：读不到页计数时
    /// 引擎把 `memoryPressure` 落成 `.unknown`、`memoryUsedBytes` 留 0，
    /// 而 `memoryTotalBytes` 是另一次独立读取、仍带真值。
    ///
    /// ⚠️ 本轮改掉一条我自己写过的启发式：原先把「已用 ≥ 总量」当假读数压掉。
    /// 引擎修好之后，`空闲 + 推测 + 可清除 == 0` 是可以**真实发生**的，
    /// 那条判据会把最该报警的一帧（内存真用满）也渲染成 `--`——藏警报比报错更糟。
    static func memoryUsedBytes(_ ctx: SampleContext) -> UInt64? {
        guard let snapshot = ctx.snapshot, snapshot.memoryTotalBytes > 0 else { return nil }
        guard snapshot.memoryPressure != .unknown else { return nil }
        guard snapshot.memoryUsedBytes > 0 else { return nil }
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

    /// 内存不可用时给具体原因——空态不能只留白，也不能只说「失败」。
    static func memoryGapReason(_ ctx: SampleContext) -> String? {
        guard let snapshot = ctx.snapshot else { return nil }
        guard memoryUsedBytes(ctx) == nil else { return nil }
        if snapshot.memoryTotalBytes == 0 { return "未取到物理内存总量" }
        if snapshot.memoryPressure == .unknown { return "内核未返回内存页计数（host_statistics64 无可用读数）" }
        return "已用字节数为 0，等同没有证据"
    }

    /// 曲线只画有证据的内存点（判据与 tile 完全同一份，避免卡和图各说一套）。
    /// 被剔除的数量必须在卡面上写出来，不能悄悄丢。
    static func trustedMemoryPoints(_ history: [SystemSnapshot]) -> [SystemSnapshot] {
        history.filter { memoryUsedBytes(SampleContext(snapshot: $0, historyCount: 1, isPaused: false)) != nil }
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

    /// 机身热压力（RD-34）。**两层缺席互不替代**，判据只在这里这一份：
    /// - `nil` = 这一帧还没到（`SampleContext.snapshot == nil`）→ 上屏 `--`；
    /// - 非 nil 且 `isMeasured == false` = 有帧但**没量到 / 量到的值不认识** → 上屏「未量到」。
    /// 页面里再写一次 `snapshot?.thermalState ?? .nominal` 就是第二把尺子，而这把尺子会把
    /// "没量到"量成"正常"——那正是 RD-34 的成因。
    static func thermalState(_ ctx: SampleContext) -> ThermalState? { ctx.snapshot?.thermalState }

    /// 热压力的上屏文案，**全仓唯一出口**（`PerformanceSystemTiles.statusStrip` 与单测读同一个函数）。
    /// 写成静态纯函数，是为了让"量不到"这一态能被真喂进来到屏上那一串字，
    /// 不必真把 App 起来等一次热压力读失败（本机造不出那种帧：不支持上报的机器恒回 nominal）。
    /// `unknown` 的原字面就是「未量到」，所以这一句**永远给不出"正常"**，除非真的量到了 nominal。
    static func thermalText(_ ctx: SampleContext) -> String {
        guard let state = thermalState(ctx) else { return Live.missing }
        return localizedCopy(state.rawValue)
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

    /// 常驻内存。**0 只可能是两路都没给值**（`rusage` 无权限、`task_info` 也没回来），
    /// 不是"这个进程占 0 字节"——真占 0 字节的进程不存在。
    /// 原来它返回非 Optional，于是同一张表里线程/打开文件都按三态显示 `--`，
    /// 只有内存这一列会诚实地把"没读到"画成"0 B"（批次 P7-B 余量）。
    static func residentBytes(of process: ProcessSnapshot) -> UInt64? {
        process.memoryBytes > 0 ? process.memoryBytes : nil
    }

    /// 组内求和只在「至少有一个进程取到」时成立；全组都没取到就返回 nil，
    /// 否则汇总卡会把「一个都没读到」显示成 0。
    static func groupThreads(of group: ProcessGroupSnapshot) -> Int? {
        sum(group.matchedProcesses.map(threads(of:)))
    }

    static func groupOpenFiles(of group: ProcessGroupSnapshot) -> Int? {
        sum(group.matchedProcesses.map(openFiles(of:)))
    }

    /// 内存合计：与 `groupThreads` 同一条判据。**注意求和本身不会因 0 而算错**，
    /// 这条 `nil` 的价值在于"一个都没读到"不再长成 `0 B`。
    static func groupMemory(of group: ProcessGroupSnapshot) -> UInt64? {
        let present = group.matchedProcesses.compactMap(residentBytes(of:))
        guard !present.isEmpty else { return nil }
        return present.reduce(0, +)
    }

    /// 「N/M 个进程取到」里的 N，用于把截断这件事量化到组，不藏进脚注。
    static func threadsCovered(in group: ProcessGroupSnapshot) -> Int {
        group.matchedProcesses.compactMap(threads(of:)).count
    }

    static func openFilesCovered(in group: ProcessGroupSnapshot) -> Int {
        group.matchedProcesses.compactMap(openFiles(of:)).count
    }

    static func memoryCovered(in group: ProcessGroupSnapshot) -> Int {
        group.matchedProcesses.compactMap(residentBytes(of:)).count
    }

    /// 单进程峰值同样要走"取到了才算"：全组都没读到时，旧写法会给出一枚
    /// `0 B` 的峰值，那是关于我们的事实，不是关于进程的。
    static func peakMemory(of group: ProcessGroupSnapshot) -> UInt64? {
        group.matchedProcesses.compactMap(residentBytes(of:)).max()
    }

    private static func sum(_ values: [Int?]) -> Int? {
        let present = values.compactMap { $0 }
        guard !present.isEmpty else { return nil }
        return present.reduce(0, +)
    }
}

// MARK: - 显示层：三态一律走这里

/// 把「可选读数」变成界面文字。规则只有一条：**没证据不产出数字**。
///
/// 这一层是 WS-M 三页的本地入口，但字面本身已收敛到全仓单点 `Design/DataAbsence.swift`：
/// 这里所有 `nil` 都属 `notAnalysed`（没采到这一帧），
/// 「查了但是空的」与「分母为 0 算不出」是另外两态，不走这个 `guard … else`。
enum Live {
    static let missing = DataAbsence.notAnalysed.display

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
