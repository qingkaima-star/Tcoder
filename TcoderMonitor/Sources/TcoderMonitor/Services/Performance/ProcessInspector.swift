import Foundation

// MARK: - Read-only process inspection (libproc)
//
// OWNER: Workstream C — 进程检查器。负责人与采样器只按下面的公开签名调用。
//
// 只读纪律：本文件只调用 proc_listallpids / proc_pidinfo / proc_pidpath /
// proc_pid_rusage 这四类查询接口，全部是取信息用的。不对任何进程做写操作，
// 不终止、不干预、不申请对方的 task port，也不打开被枚举进程的文件
// （可执行路径只拿来做展示与匹配）。

struct ProcessCPUState: Sendable, Equatable {
    var pid: Int32
    /// 累计 CPU 时间（ri_user_time + ri_system_time），纳秒。
    var cpuNano: UInt64
    var residentBytes: UInt64
}

struct ProcessSweep: Sendable {
    var processes: [ProcessSnapshot] = []
    /// pid -> 本轮累计值，调用方原样存下来喂给下一轮。
    var states: [Int32: ProcessCPUState] = [:]
    var elapsed: TimeInterval = 0
    var truncated: Bool = false
    /// 本轮从内核拿到的**可见 pid 总数**（不等于 `processes.count`：无权限的、
    /// 中途退出的都会少）。调用方拿它当"本用户可查询子集"的探针数，
    /// 免得为这一个整数再遍历一次内核。
    var visiblePIDCount: Int = 0
}

enum ProcessInspector {

    // MARK: - Budgets & constants

    private static let pidStride = MemoryLayout<pid_t>.stride

    /// pid 数量上限：极端机器上宁可少采几个，也不无界分配内存。
    private static let maxPIDCount = 100_000

    /// proc_pidpath 要求 PROC_PIDPATHINFO_MAXSIZE(4*MAXPATHLEN)，该宏在 Swift 侧不可见，只能手算。
    private static let pathBufferSize = 4 * Int(MAXPATHLEN)

    /// 打开文件数最贵（要为整个 fd 表问一次内核），超预算就只丢 fd 数，其余指标照收。
    private static let fdBudgetNanos: UInt64 = 600_000_000
    /// sweep 硬预算：超过直接返回已收集的部分，宁可少几个进程也不能拖死后台线程。
    private static let sweepBudgetNanos: UInt64 = 1_500_000_000

    // MARK: - Public API

    /// 全系统进程数。
    ///
    /// 不能用 `proc_listallpids`：无权限时它只返回本用户可见的那部分（实测本机 260 个），
    /// 而 `ps -A` / `top` 报 1000 以上。`sysctl(KERN_PROC_ALL)` 与它们同源，
    /// 所以总数走 sysctl；逐进程的指标仍只能覆盖可见子集（这是无 root 的硬限制）。
    static func processCount() -> Int { processCountProbe(visiblePIDCount: nil).count }

    /// 只探长度、不搬数据的进程数探测。
    ///
    /// 旧实现为拿一个整数分配了整块 `kinfo_proc` 缓冲：本机 962 个进程时
    /// `kinfo_proc.stride = 648` → 每次 tick 白分配 **623 KB**，实测中位耗时
    /// 108.5 µs；而 `sysctl(old=NULL)` 只回填所需字节数，`length / stride` 就是个数，
    /// 实测中位 26.9 µs、25 次采样里 `length % stride` 恒为 0（即余数不撒谎）。
    ///
    /// `visiblePIDCount` 由同一轮 sweep 顺手带回来，避免第二次遍历内核；
    /// 没带时就地数一次（`proc_listallpids` 实测中位 6.5 µs）。
    ///
    /// 计数语义没为了降本动过一个字：拿不到 sysctl 就如实报"只是可见子集"
    /// （`isSystemWide == false`），绝不猜一个数，也绝不拿子集冒充全集。
    static func processCountProbe(visiblePIDCount: Int?) -> ProcessCountProbe {
        let visible = visiblePIDCount ?? visibleProcessCount()
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var length = 0
        let stride = MemoryLayout<kinfo_proc>.stride
        guard stride > 0, sysctl(&mib, 3, nil, &length, nil, 0) == 0, length >= stride else {
            return ProcessCountProbe(count: visible, isSystemWide: false)
        }
        // 可见子集必然是全系统的一部分，两者取大只是防内核在两次调用之间给出漂移的小值。
        return ProcessCountProbe(count: max(length / stride, visible), isSystemWide: true)
    }

    /// 本用户可逐进程查询指标的进程数。
    /// 注意 `proc_listallpids(nil, 0)` 的返回值只是缓冲区容量建议，实测 254 而真实只能取回 83，
    /// 所以这里以实际枚举结果为准。
    static func visibleProcessCount() -> Int {
        let enumerated = listAllPids().count
        if enumerated > 0 { return enumerated }
        let bytes = proc_listallpids(nil, 0)
        guard bytes > 0 else { return 0 }
        return Int(bytes) / pidStride
    }

    /// 全系统进程枚举 + 指标。previous 为上一轮累计值。
    ///
    /// 原先这里是 71 行 / CC 24 的一整段（自扫点名本包剩下的最后一个热点）。
    /// 现在 `sweep` 只管「拿到 pid 名单 + 两处预算的止损」，单个 pid 怎么取数、名字怎么退、
    /// CPU 怎么算，全交给 `SweepProbes.snapshot(for:)`。
    /// **两处预算的语义没动**：sweep 硬预算超时是 `break`（宁可少几个进程），
    /// fd 超预算只丢 fd 数并标 truncated，其余指标照收。
    static func sweep(previous: [Int32: ProcessCPUState], elapsed: TimeInterval) -> ProcessSweep {
        let startedAt = monotonicNanos()
        var result = ProcessSweep(elapsed: elapsed)

        let pids = listAllPids()
        result.visiblePIDCount = pids.count
        guard !pids.isEmpty else { return result }
        result.processes.reserveCapacity(pids.count)
        result.states.reserveCapacity(pids.count)

        var probes = SweepProbes(startedAt: startedAt, previous: previous, elapsed: elapsed)
        for pid in pids {
            guard pid > 0 else { continue }

            if monotonicNanos() &- startedAt > sweepBudgetNanos {
                result.truncated = true
                break
            }
            guard let snapshot = probes.snapshot(for: pid) else { continue }
            if probes.fdBudgetExhausted { result.truncated = true }

            result.processes.append(snapshot.process)
            result.states[pid] = snapshot.state
        }
        return result
    }

    /// 一轮 sweep 里逐 pid 的取数上下文：上一轮累计值、窗口长度、fd 预算的截止点，
    /// 以及 `proc_pidpath` 那块跨 pid 复用的路径缓冲区（原先这些都是 `sweep` 的局部量）。
    struct SweepProbes {
        let startedAt: UInt64
        let previous: [Int32: ProcessCPUState]
        let elapsed: TimeInterval
        let fdDeadline: UInt64
        var pathBuffer = [CChar](repeating: 0, count: ProcessInspector.pathBufferSize)
        /// 本轮里至少有一个 pid 因为过了 fd 预算而没拿到打开文件数。
        var fdBudgetExhausted = false

        init(startedAt: UInt64, previous: [Int32: ProcessCPUState], elapsed: TimeInterval) {
            self.startedAt = startedAt
            self.previous = previous
            self.elapsed = elapsed
            fdDeadline = startedAt &+ ProcessInspector.fdBudgetNanos
        }

        /// 一个 pid 的展示快照 + 下一轮要用的累计值。拿不到 bsd 信息（无权限 / 刚退出）就不算这个进程。
        mutating func snapshot(for pid: Int32) -> (process: ProcessSnapshot, state: ProcessCPUState)? {
            guard var bsd = ProcessInspector.bsdInfo(for: pid) else { return nil }
            let commandLinePath = ProcessInspector.executablePath(for: pid, buffer: &pathBuffer)
            let usage = ProcessInspector.rusageInfo(for: pid)
            let task = ProcessInspector.taskInfo(for: pid)

            let cpuNano = usage?.cpuNano ?? 0
            var resident = usage?.residentBytes ?? 0
            if resident == 0, let task { resident = task.pti_resident_size }
            let openFiles = openFileCountIfAffordable(pid)
            let name = ProcessInspector.processName(bsd: &bsd, pid: pid, commandLinePath: commandLinePath)

            // 没见过的 pid（新进程 / 上一轮没采到）不能瞎算，CPU 记 0。
            let cpu: Double
            if let prev = previous[pid] {
                cpu = ProcessInspector.cpuUsage(previousNano: prev.cpuNano, currentNano: cpuNano,
                                               elapsed: elapsed)
            } else {
                cpu = 0
            }

            return (ProcessSnapshot(
                pid: pid,
                name: name,
                cpuUsage: cpu,
                memoryBytes: resident,
                threadCount: task.map { Int($0.pti_threadnum) } ?? 0,
                openFileCount: openFiles,
                startTime: ProcessInspector.startTime(of: bsd),
                commandLine: commandLinePath ?? name,
                parentPID: Int32(bitPattern: bsd.pbi_ppid)
            ), ProcessCPUState(pid: pid, cpuNano: cpuNano, residentBytes: resident))
        }

        /// 打开文件数最贵（要为整个 fd 表问一次内核），超预算就只丢这一个指标，其余照收。
        mutating func openFileCountIfAffordable(_ pid: Int32) -> Int {
            guard ProcessInspector.monotonicNanos() < fdDeadline else {
                fdBudgetExhausted = true
                return 0
            }
            return ProcessInspector.openFileCount(for: pid)
        }
    }

    /// 进程名的逐级退回：libproc 的 pbi_name → pbi_comm → 可执行路径末段 → `pid N`。
    static func processName(bsd: inout proc_bsdinfo, pid: Int32, commandLinePath: String?) -> String {
        var name = cString(&bsd.pbi_name)
        if name.isEmpty { name = cString(&bsd.pbi_comm) }
        if name.isEmpty, let commandLinePath { name = (commandLinePath as NSString).lastPathComponent }
        if name.isEmpty { name = "pid \(pid)" }
        return name
    }

    /// 内核不给启动时间（字段为 0）时返回 nil，视图才显示 `--` 而不是伪造 epoch。
    static func startTime(of bsd: proc_bsdinfo) -> Date? {
        let startSeconds = bsd.pbi_start_tvsec
        guard startSeconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(startSeconds))
    }

    /// 没有匹配的 group 也返回空快照，视图才能显示「未检测到进程」而不是伪造 0。
    static func groupSnapshots(for groups: [TrackedProcessGroup],
                               processes: [ProcessSnapshot]) -> [ProcessGroupSnapshot] {
        groups.map { group in
            let matched = processes
                .filter { matches($0, pattern: group.matchPattern) }
                .sorted { $0.cpuUsage > $1.cpuUsage }
            return ProcessGroupSnapshot(group: group, matchedProcesses: matched)
        }
    }

    /// 不区分大小写的子串匹配：命中进程名或完整可执行路径。
    static func matches(_ process: ProcessSnapshot, pattern: String) -> Bool {
        let needle = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return false }
        if process.name.lowercased().contains(needle) { return true }
        return process.commandLine.lowercased().contains(needle)
    }

    /// 多核可以 >1，不做 0...1 截断（ProcessSnapshot.cpuUsage 的契约）。
    static func cpuUsage(previousNano: UInt64, currentNano: UInt64, elapsed: TimeInterval) -> Double {
        guard elapsed > 0, elapsed.isFinite else { return 0 }
        guard currentNano >= previousNano else { return 0 }   // 进程重启或计数回绕
        let window = elapsed * 1_000_000_000
        guard window > 0, window.isFinite else { return 0 }
        return Double(currentNano - previousNano) / window
    }

    // MARK: - Per-pid libproc probes

    /// 可见性说明（2026-09-20 拆分所致）：原先是 `private`，`SweepProbes.snapshot(for:)` 取不到就
    /// 放宽到模块内可见。它仍嵌在 `ProcessInspector` 之下，不进模块命名空间，字段一个没动。
    struct RusageInfo {
        var cpuNano: UInt64
        var residentBytes: UInt64
        var diskReadBytes: UInt64
        var diskWriteBytes: UInt64
    }

    static func listAllPids() -> [pid_t] {
        let needed = proc_listallpids(nil, 0)
        guard needed > 0 else { return [] }
        // pid 数在两次调用之间可能变化，留 256 个余量并封顶。
        let capacity = min(Int(needed) / pidStride + 256, maxPIDCount)
        guard capacity > 0 else { return [] }

        var pids = [pid_t](repeating: 0, count: capacity)
        let filled = pids.withUnsafeMutableBufferPointer { ptr -> Int in
            guard let base = ptr.baseAddress, ptr.count * pidStride <= Int(Int32.max) else { return 0 }
            let bytes = proc_listallpids(base, Int32(ptr.count * pidStride))
            guard bytes > 0 else { return 0 }
            return min(Int(bytes) / pidStride, ptr.count)
        }
        guard filled > 0 else { return [] }
        return Array(pids.prefix(filled))
    }

    static func bsdInfo(for pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let read = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info,
                               Int32(MemoryLayout<proc_bsdinfo>.size))
        guard read > 0 else { return nil }
        return info
    }

    static func taskInfo(for pid: Int32) -> proc_taskinfo? {
        var info = proc_taskinfo()
        let read = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info,
                               Int32(MemoryLayout<proc_taskinfo>.size))
        guard read == Int32(MemoryLayout<proc_taskinfo>.size) else { return nil }
        return info
    }

    static func openFileCount(for pid: Int32) -> Int {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return 0 }
        return Int(bytes) / MemoryLayout<proc_fdinfo>.stride
    }

    static func executablePath(for pid: Int32, buffer: inout [CChar]) -> String? {
        guard !buffer.isEmpty else { return nil }
        return buffer.withUnsafeMutableBufferPointer { ptr -> String? in
            guard let base = ptr.baseAddress else { return nil }
            let written = proc_pidpath(pid, base, UInt32(ptr.count))
            guard written > 0 else { return nil }
            let text = decode(UnsafeBufferPointer(start: base, count: ptr.count))
            return text.isEmpty ? nil : text
        }
    }

    /// v4 -> v3 -> v2 -> v0 逐级降级；任一失败（EPERM / 进程刚退出）就换下一档。
    static func rusageInfo(for pid: Int32) -> RusageInfo? {
        var v4 = rusage_info_v4()
        if callRusage(pid, flavor: RUSAGE_INFO_V4, info: &v4) {
            return RusageInfo(cpuNano: v4.ri_user_time &+ v4.ri_system_time,
                              residentBytes: v4.ri_resident_size,
                              diskReadBytes: v4.ri_diskio_bytesread,
                              diskWriteBytes: v4.ri_diskio_byteswritten)
        }
        var v3 = rusage_info_v3()
        if callRusage(pid, flavor: RUSAGE_INFO_V3, info: &v3) {
            return RusageInfo(cpuNano: v3.ri_user_time &+ v3.ri_system_time,
                              residentBytes: v3.ri_resident_size,
                              diskReadBytes: v3.ri_diskio_bytesread,
                              diskWriteBytes: v3.ri_diskio_byteswritten)
        }
        var v2 = rusage_info_v2()
        if callRusage(pid, flavor: RUSAGE_INFO_V2, info: &v2) {
            return RusageInfo(cpuNano: v2.ri_user_time &+ v2.ri_system_time,
                              residentBytes: v2.ri_resident_size,
                              diskReadBytes: v2.ri_diskio_bytesread,
                              diskWriteBytes: v2.ri_diskio_byteswritten)
        }
        var v0 = rusage_info_v0()
        if callRusage(pid, flavor: RUSAGE_INFO_V0, info: &v0) {
            return RusageInfo(cpuNano: v0.ri_user_time &+ v0.ri_system_time,
                              residentBytes: v0.ri_resident_size,
                              diskReadBytes: 0,
                              diskWriteBytes: 0)
        }
        return nil
    }

    /// proc_pid_rusage 的第三参数在 Swift 侧被导入为 `UnsafeMutablePointer<rusage_info_t?>?`
    /// （C 签名是 `rusage_info_t *buffer`，而 rusage_info_t 本身是 void*）。内核直接把结构体
    /// 抄进这个地址，所以沿用 C 调用方的写法：把结构体自身地址原样传下去，实测 rc=0。
    private static func callRusage<T>(_ pid: Int32, flavor: Int32, info: inout T) -> Bool {
        withUnsafeMutablePointer(to: &info) { structPtr in
            let slot = UnsafeMutableRawPointer(structPtr)
                .assumingMemoryBound(to: Optional<UnsafeMutableRawPointer>.self)
            return proc_pid_rusage(pid, flavor, slot) == 0
        }
    }

    // MARK: - Small utilities

    /// 只在字段自身范围内取到第一个 NUL 为止，越界的字节一律不读。
    private static func decode(_ bytes: UnsafeBufferPointer<CChar>) -> String {
        var ascii: [UInt8] = []
        ascii.reserveCapacity(min(bytes.count, 64))
        for byte in bytes {
            if byte == 0 { break }
            ascii.append(UInt8(bitPattern: byte))
        }
        return String(decoding: ascii, as: UTF8.self)
    }

    private static func cString<T>(_ value: inout T) -> String {
        withUnsafeBytes(of: &value) { raw in decode(raw.bindMemory(to: CChar.self)) }
    }

    /// 单调时钟，避免用户改系统时间导致预算算歪。
    static func monotonicNanos() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}
