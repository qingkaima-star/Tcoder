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
    /// systemDiskIO 挂在 1.5s 高频采样上，预算更紧。
    private static let diskIOBudgetNanos: UInt64 = 300_000_000

    // MARK: - Public API

    static func processCount() -> Int {
        let bytes = proc_listallpids(nil, 0)
        guard bytes > 0 else { return 0 }
        return Int(bytes) / pidStride
    }

    /// 全系统进程枚举 + 指标。previous 为上一轮累计值。
    static func sweep(previous: [Int32: ProcessCPUState], elapsed: TimeInterval) -> ProcessSweep {
        let startedAt = monotonicNanos()
        var result = ProcessSweep(elapsed: elapsed)

        let pids = listAllPids()
        guard !pids.isEmpty else { return result }
        result.processes.reserveCapacity(pids.count)
        result.states.reserveCapacity(pids.count)

        var pathBuffer = [CChar](repeating: 0, count: pathBufferSize)
        let fdDeadline = startedAt &+ fdBudgetNanos

        for pid in pids {
            guard pid > 0 else { continue }

            let now = monotonicNanos()
            if now &- startedAt > sweepBudgetNanos {
                result.truncated = true
                break
            }

            guard var bsd = bsdInfo(for: pid) else { continue }

            let commandLinePath = executablePath(for: pid, buffer: &pathBuffer)

            var name = cString(&bsd.pbi_name)
            if name.isEmpty { name = cString(&bsd.pbi_comm) }
            if name.isEmpty, let commandLinePath { name = (commandLinePath as NSString).lastPathComponent }
            if name.isEmpty { name = "pid \(pid)" }

            let usage = rusageInfo(for: pid)
            let task = taskInfo(for: pid)

            let cpuNano = usage?.cpuNano ?? 0
            var resident = usage?.residentBytes ?? 0
            if resident == 0, let task { resident = task.pti_resident_size }

            var openFiles = 0
            if monotonicNanos() < fdDeadline {
                openFiles = openFileCount(for: pid)
            } else {
                result.truncated = true
            }

            // 没见过的 pid（新进程 / 上一轮没采到）不能瞎算，CPU 记 0。
            let cpu: Double
            if let prev = previous[pid] {
                cpu = cpuUsage(previousNano: prev.cpuNano, currentNano: cpuNano, elapsed: elapsed)
            } else {
                cpu = 0
            }

            let startSeconds = bsd.pbi_start_tvsec
            let startTime = startSeconds > 0 ? Date(timeIntervalSince1970: TimeInterval(startSeconds)) : nil

            result.processes.append(ProcessSnapshot(
                pid: pid,
                name: name,
                cpuUsage: cpu,
                memoryBytes: resident,
                threadCount: task.map { Int($0.pti_threadnum) } ?? 0,
                openFileCount: openFiles,
                startTime: startTime,
                commandLine: commandLinePath ?? name,
                parentPID: Int32(bitPattern: bsd.pbi_ppid)
            ))
            result.states[pid] = ProcessCPUState(pid: pid, cpuNano: cpuNano, residentBytes: resident)
        }
        return result
    }

    /// 全系统累计磁盘读写字节；调用方自己做两次差。预算外的进程跳过累加。
    static func systemDiskIO() -> (readBytes: UInt64, writeBytes: UInt64) {
        let startedAt = monotonicNanos()
        var read: UInt64 = 0
        var write: UInt64 = 0
        for pid in listAllPids() {
            guard pid > 0 else { continue }
            if monotonicNanos() &- startedAt > diskIOBudgetNanos { break }
            guard let usage = rusageInfo(for: pid) else { continue }
            read &+= usage.diskReadBytes
            write &+= usage.diskWriteBytes
        }
        return (read, write)
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

    private struct RusageInfo {
        var cpuNano: UInt64
        var residentBytes: UInt64
        var diskReadBytes: UInt64
        var diskWriteBytes: UInt64
    }

    private static func listAllPids() -> [pid_t] {
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

    private static func bsdInfo(for pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let read = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info,
                               Int32(MemoryLayout<proc_bsdinfo>.size))
        guard read > 0 else { return nil }
        return info
    }

    private static func taskInfo(for pid: Int32) -> proc_taskinfo? {
        var info = proc_taskinfo()
        let read = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info,
                               Int32(MemoryLayout<proc_taskinfo>.size))
        guard read == Int32(MemoryLayout<proc_taskinfo>.size) else { return nil }
        return info
    }

    private static func openFileCount(for pid: Int32) -> Int {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return 0 }
        return Int(bytes) / MemoryLayout<proc_fdinfo>.stride
    }

    private static func executablePath(for pid: Int32, buffer: inout [CChar]) -> String? {
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
    private static func rusageInfo(for pid: Int32) -> RusageInfo? {
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
    private static func monotonicNanos() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}
