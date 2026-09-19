import Foundation

// MARK: - 原始计数器快照

/// 单个核心的累计 tick（CPU_STATE_* 四类，保留内核的 32 位位模式）。
struct CoreTicks: Sendable, Equatable {
    var user: UInt32 = 0
    var system: UInt32 = 0
    var idle: UInt32 = 0
    var nice: UInt32 = 0
}

/// `vm_statistics64` 里我们真正要的几页计数，统一换算成字节口径所需的页数。
struct VmCounters: Sendable, Equatable {
    var pageSize: UInt64 = 4096
    var active: UInt64 = 0
    var inactive: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var free: UInt64 = 0
    var speculative: UInt64 = 0
    var purgeable: UInt64 = 0

    var reclaimableBytes: UInt64 {
        (free &+ speculative &+ purgeable) &* pageSize
    }
}

/// 一次原始读数的全部累积量：调用方存起来与下一次相减得到速率。
struct SystemCounters: Sendable, Equatable {
    var timestamp: Date = Date()
    var cores: [CoreTicks] = []
    var vm: VmCounters = VmCounters()
    var diskReadBytes: UInt64 = 0
    var diskWriteBytes: UInt64 = 0
    var networkInBytes: UInt64 = 0
    var networkOutBytes: UInt64 = 0
}

// MARK: - 采样器

/// OWNER: Workstream C（系统计数器采样）。nonisolated、无状态，可在后台线程反复调用。
struct SystemSampler: Sendable {
    init() {}

    /// 一次性原始读取；任何系统调用失败都退化为 0 / 空数组，不抛错、不 crash。
    func read() -> SystemCounters {
        let timestamp = Date()
        let disk = ProcessInspector.systemDiskIO()
        let network = Self.networkBytes()
        return SystemCounters(
            timestamp: timestamp,
            cores: Self.coreTicks(),
            vm: Self.vmCounters(),
            diskReadBytes: disk.readBytes,
            diskWriteBytes: disk.writeBytes,
            networkInBytes: network.inbound,
            networkOutBytes: network.outbound
        )
    }

    /// 由前后两次采样构造 `SystemSnapshot`；previous 为 nil 时速率类字段一律 0。
    func snapshot(previous: SystemCounters?, current: SystemCounters, processCount: Int) -> SystemSnapshot {
        var snapshot = SystemSnapshot()
        snapshot.timestamp = current.timestamp
        snapshot.cpuCoreCount = ProcessInfo.processInfo.activeProcessorCount
        snapshot.processCount = processCount
        snapshot.uptimeSeconds = ProcessInfo.processInfo.systemUptime
        snapshot.thermalState = ThermalState(processInfoValue: ProcessInfo.processInfo.thermalState.rawValue)

        snapshot.cpuUsage = Self.cpuUsage(previous: previous?.cores ?? [], current: current.cores)
        snapshot.memoryTotalBytes = ProcessInfo.processInfo.physicalMemory
        snapshot.memoryUsedBytes = Self.memoryUsedBytes(current.vm, totalBytes: snapshot.memoryTotalBytes)
        snapshot.memoryPressure = Self.pressure(for: snapshot.memoryFraction)

        if let previous {
            let elapsed = current.timestamp.timeIntervalSince(previous.timestamp)
            snapshot.diskReadBytesPerSecond = Self.bytesPerSecond(
                previous: previous.diskReadBytes, current: current.diskReadBytes, elapsed: elapsed)
            snapshot.diskWriteBytesPerSecond = Self.bytesPerSecond(
                previous: previous.diskWriteBytes, current: current.diskWriteBytes, elapsed: elapsed)
            snapshot.networkInBytesPerSecond = Self.bytesPerSecond(
                previous: previous.networkInBytes, current: current.networkInBytes, elapsed: elapsed)
            snapshot.networkOutBytesPerSecond = Self.bytesPerSecond(
                previous: previous.networkOutBytes, current: current.networkOutBytes, elapsed: elapsed)
        }

        var loads = [Double](repeating: 0, count: 3)
        let filled = getloadavg(&loads, 3)
        if filled > 0 { snapshot.loadAverage1 = max(0, loads[0]) }
        if filled > 1 { snapshot.loadAverage5 = max(0, loads[1]) }
        if filled > 2 { snapshot.loadAverage15 = max(0, loads[2]) }

        return snapshot
    }
}

// MARK: - 纯函数派生（单测直接调用，不做任何系统调用）

extension SystemSampler {
    /// 全机 CPU 占用 = 1 - 空闲增量/总增量，夹在 0...1。
    static func cpuUsage(previous: [CoreTicks], current: [CoreTicks]) -> Double {
        // 核数变了（热插拔/休眠唤醒）时逐核配对没有意义，直接给 0。
        guard previous.count == current.count, !current.isEmpty else { return 0 }

        var totalDelta: UInt64 = 0
        var idleDelta: UInt64 = 0
        for index in 0..<current.count {
            let before = previous[index]
            let now = current[index]
            // 任一项回退说明计数器被重置（重启、时钟源切换），这一帧不可信。
            guard now.user >= before.user, now.system >= before.system,
                  now.idle >= before.idle, now.nice >= before.nice else { return 0 }
            let user = UInt64(now.user - before.user)
            let system = UInt64(now.system - before.system)
            let idle = UInt64(now.idle - before.idle)
            let nice = UInt64(now.nice - before.nice)
            totalDelta &+= user &+ system &+ idle &+ nice
            idleDelta &+= idle &+ nice
        }

        guard totalDelta > 0 else { return 0 }
        let usage = 1.0 - Double(idleDelta) / Double(totalDelta)
        guard usage.isFinite else { return 0 }
        return min(max(usage, 0), 1)
    }

    /// 与活动监视器同口径：已用 = 总量 -（free + speculative + purgeable）。
    /// inactive 是文件缓存但监视器仍计入已用，所以不能只算 active+wired+compressed。
    static func memoryUsedBytes(_ vm: VmCounters, totalBytes: UInt64) -> UInt64 {
        let reclaimable = vm.reclaimableBytes
        if reclaimable >= totalBytes {
            // 页计数瞬时不一致时退化为「active + wired + 压缩器占用」，至少不会是负数。
            return min(totalBytes, (vm.active &+ vm.wired &+ vm.compressed) &* vm.pageSize)
        }
        return totalBytes - reclaimable
    }

    static func bytesPerSecond(previous: UInt64, current: UInt64, elapsed: TimeInterval) -> UInt64 {
        // 累积量下降 = 接口重建 / 进程重启，无法反推速率。
        guard current >= previous, elapsed > 0, elapsed.isFinite else { return 0 }
        let rate = Double(current - previous) / elapsed
        guard rate.isFinite, rate >= 0 else { return 0 }
        let ceiling = 1e18  // 远超真实 NVMe/网卡带宽，纯防 Double→UInt64 转换溢出
        if rate >= ceiling { return UInt64.max }
        return UInt64(rate)
    }

    static func pressure(for fraction: Double) -> MemoryPressure {
        if fraction >= 0.85 { return .critical }
        if fraction >= 0.7 { return .warning }
        return .normal
    }
}

// MARK: - Darwin 调用封装（全部失败退化为 0 / 空）

private extension SystemSampler {
    /// host_processor_info(PROCESSOR_CPU_LOAD_INFO) → 每核四项 tick。
    static func coreTicks() -> [CoreTicks] {
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        var processorCount: natural_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                         &processorCount, &info, &infoCount)
        defer {
            // 这块缓冲区由内核分配，必须归还，否则每帧都在漏。
            // 只在调用成功且计数合理时释放：拿一个错乱的长度去 vm_deallocate 会连带卸掉别的映射。
            if result == KERN_SUCCESS, infoCount > 0, let pointer = info {
                let bytes = vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
                vm_deallocate(mach_task_self_, vm_address_t(bitPattern: pointer), bytes)
            }
        }

        let statesPerCore = max(1, Int(CPU_STATE_MAX))
        guard result == KERN_SUCCESS, Int(infoCount) >= statesPerCore, let table = info else { return [] }
        let cores = min(Int(processorCount), Int(infoCount) / statesPerCore)
        guard cores > 0 else { return [] }

        return (0..<cores).map { core in
            let offset = statesPerCore * core
            return CoreTicks(
                user: UInt32(bitPattern: table[offset + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: table[offset + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: table[offset + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: table[offset + Int(CPU_STATE_NICE)])
            )
        }
    }

    /// host_statistics64(HOST_VM_INFO64) → 页计数；pageSize 用内核页大小（Apple Silicon 16 KB）。
    static func vmCounters() -> VmCounters {
        let pageSize: UInt64 = vm_kernel_page_size > 0 ? UInt64(vm_kernel_page_size) : 4096

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: max(1, Int(count))) { rebased in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebased, &count)
            }
        }
        guard result == KERN_SUCCESS else { return VmCounters(pageSize: pageSize) }

        return VmCounters(
            pageSize: pageSize,
            active: UInt64(stats.active_count),
            inactive: UInt64(stats.inactive_count),
            wired: UInt64(stats.wire_count),
            compressed: UInt64(stats.compressor_page_count),
            free: UInt64(stats.free_count),
            speculative: UInt64(stats.speculative_count),
            purgeable: UInt64(stats.purgeable_count)
        )
    }

    /// getifaddrs 累加 AF_LINK 字节数；lo0 是回环，算进去会凭空造出流量。
    static func networkBytes() -> (inbound: UInt64, outbound: UInt64) {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return (0, 0) }
        defer { freeifaddrs(first) }

        var inbound: UInt64 = 0
        var outbound: UInt64 = 0
        var cursor = first
        while let entry = cursor?.pointee {
            cursor = entry.ifa_next
            guard let address = entry.ifa_addr, Int32(address.pointee.sa_family) == AF_LINK else { continue }
            if let name = entry.ifa_name, String(cString: name) == "lo0" { continue }
            guard let data = entry.ifa_data else { continue }
            // libc 给的是 32 位 if_data（不是 if_data64），单接口每 4 GiB 归零一次；
            // 归零那一帧 current < previous，由 bytesPerSecond 退化成 0。
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            inbound &+= UInt64(stats.ifi_ibytes)
            outbound &+= UInt64(stats.ifi_obytes)
        }
        return (inbound, outbound)
    }
}
