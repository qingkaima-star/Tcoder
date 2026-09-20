import CoreFoundation
import CoreGraphics
import CoreVideo
import Foundation
import os

// swiftlint:disable:next type_body_length
/// App 内常驻帧探针 —— xctrace 之外的**第二把尺子**（性能 spec §4.2）。
///
/// ## 为什么需要第二把尺子
/// `scripts/perf_harness.sh` 那把外部尺子只能事后 attach 录 20~25 秒，
/// 而且要人手工起 Instruments 链路；它看不见"这个 hitch 落在哪一次心跳里"。
/// 本探针在进程内跑，把 `CVDisplayLink` 的真实出帧节拍与主线程 runloop 唤醒
/// 做成**同一条时间轴**，于是"每 1.5 秒把自己钉住 5~7 帧"这句话可以被直接数出来。
/// 两把尺子不得共享同一盲区：外部尺子量"系统看到的帧"，内部尺子量"我们自己占住主线程多久"。
///
/// ## 零开销承诺（AGENTS.md 第四轮红线 8）
/// `TCODER_PERF_PROBE` 不等于 `"1"` 时，`startIfNeeded()` 立刻返回 false，
/// **连 `CVDisplayLink` 都不创建**（不是创建了再不调用），也不注册 runloop observer、
/// 不开文件句柄。产品路径上唯一的接线动作就是调这一个方法。
///
/// ## 为什么读数必须写文件
/// 仓库实测教训：`swift test` 会丢掉子进程 stdout 的后半段，取证 print 落文件才算数。
/// 输出路径取 `TCODER_PERF_OUT`，缺省 `/tmp/tcoder-framepulse-<pid>.txt`。
///
/// ## 已用编译探针确认的能力（spec §2）
/// - `CVDisplayLinkCreateWithActiveCGDisplays` / `CVDisplayLinkStart`：macOS 14 可用。
/// - `CGDisplayCopyDisplayMode(...).refreshRate`：真实 Hz **必须运行时读**，不许硬编码 120
///   （外接 4K 与内建屏都可能是 60/120，帧预算随屏幕变）。
/// - `os_signpost` 走**老式 `OSSignpostID` API**；`OSSignposter` 的新式成员在本 SDK 签名不同。
/// - `CADisplayLink` 在 macOS **不可用**、MetricKit 的 `MX*Diagnostic` 在 macOS **不存在**，
///   所以这里没有任何 iOS 方案可抄。
public final class FramePulse: @unchecked Sendable {

    // MARK: - 开关与路径（产品代码只读这几个量）

    /// 探针总开关。只有显式 `TCODER_PERF_PROBE=1` 才为真——默认关闭。
    public static let isProbeEnabled: Bool = {
        ProcessInfo.processInfo.environment["TCODER_PERF_PROBE"] == "1"
    }()

    /// 读数落盘路径（缺省按 pid 分文件，免得多个实例互相写同一个文件）。
    public static var outputPath: String {
        let env = ProcessInfo.processInfo.environment["TCODER_PERF_OUT"]
        if let env, !env.isEmpty { return env }
        return "/tmp/tcoder-framepulse-\(getpid()).txt"
    }

    /// 单例。接线点只有一个（`AppState` 启动完成后调 `startIfNeeded()`），由总工落。
    public static let shared = FramePulse()

    // MARK: - 内部状态

    /// 环形缓冲容量：120 Hz 下约 83 秒，够跑完一轮 `perf_harness.sh idle`（25 s）。
    static let ringCapacity = 10_000
    /// 心跳看门狗环形缓冲：1.5 s 一拍，4096 拍 ≈ 102 分钟。
    static let heartbeatCapacity = 4_096

    private let lock = NSLock()
    private var displayLink: CVDisplayLink?
    private var fileHandle: FileHandle?
    private var signpostLog: OSLog?

    /// 帧间隔样本（ms），最新在末尾，满了就丢最老的。
    private var frameIntervals: [Double] = []
    /// 累计量不随环形缓冲丢弃——hitch 总数必须是从启动到关闭的全量。
    private var totalFrameCount = 0
    private var totalHitchCount = 0
    private var largestIntervalMs = 0.0
    private var heartbeatGaps: [Double] = []
    private var lastWakeUptime: Double?
    private var largestHeartbeatGapMs = 0.0
    private var heartbeatTickCount = 0
    /// 相位账本：每个心跳周期里出现了几次超帧。
    private var ticksWithHitch = 0
    private var hitchesSinceLastTick = 0
    private var framesSinceLastTick = 0
    private var tickLedger: [String] = []

    private var expectedIntervalMs = 1000.0 / 60.0
    private var measuredRefreshHz = 0.0
    private var refreshRateSource = "未测"
    private var startedAt = Date()
    private var isRunning = false

    // MARK: - 生命周期

    /// 幂等启动。返回是否真的起来了（false = 开关未开，**未产生任何副作用**）。
    @discardableResult
    public func startIfNeeded() -> Bool {
        guard Self.isProbeEnabled else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard !isRunning else { return true }

        let rate = Self.readRefreshRate()
        measuredRefreshHz = rate.hz
        refreshRateSource = rate.source
        expectedIntervalMs = rate.hz > 1.0 ? 1000.0 / rate.hz : 1000.0 / 60.0

        openFile()
        signpostLog = OSLog(subsystem: "com.tcoder.monitor", category: "FramePulse")
        startHeartbeatObserver()
        startDisplayLink()
        isRunning = true
        startedAt = Date()
        writeHeaderLocked()
        return true
    }

    /// 停表并把最终汇总落盘（App 退出前调用；不调也不影响正确性）。
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning else { return }
        isRunning = false
        if let link = displayLink {
            CVDisplayLinkStop(link)
        }
        displayLink = nil
        writeLineLocked(makeSummaryLineLocked())
        if let observer = heartbeatObserver {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
        heartbeatObserver = nil
        try? fileHandle?.close()
        fileHandle = nil
    }

    deinit {
        if let handle = fileHandle { try? handle.close() }
    }

    // MARK: - 真实刷新率（不许硬编码 120）

    /// 运行时读当前主屏的显示模式；读不到再退回全模式表的 max，再退回 60 并**如实标注来源**。
    static func readRefreshRate() -> (hz: Double, source: String) {
        let main = CGMainDisplayID()
        if let mode = CGDisplayCopyDisplayMode(main), mode.refreshRate > 0 {
            return (Double(mode.refreshRate), "CGDisplayCopyDisplayMode(current)")
        }
        if let modes = CGDisplayCopyAllDisplayModes(main, nil) as? [CGDisplayMode] {
            let best = modes.map { Double($0.refreshRate) }.max() ?? 0
            if best > 0 { return (best, "CGDisplayCopyAllDisplayModes(max)") }
        }
        return (0, "读不到，兜底 60Hz")
    }

    // MARK: - CVDisplayLink（真实出帧节拍）

    private func startDisplayLink() {
        var link: CVDisplayLink?
        let status = CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard status == kCVReturnSuccess, let link else {
            writeLineLocked("# 探针启动失败：CVDisplayLinkCreateWithActiveCGDisplays -> \(status)")
            return
        }
        let bridge = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(link, displayLinkCallback, bridge)
        CVDisplayLinkStart(link)
        displayLink = link
    }

    /// `CVDisplayLink` 回调跑在高优先级非主线程上——这正是它适合当尺子的原因：
    /// 主线程被钉住时，它照样按屏幕节拍进来。
    fileprivate func recordFrameOutput(at uptime: Double) {
        lock.lock()
        defer { lock.unlock() }
        totalFrameCount += 1
        framesSinceLastTick += 1
        guard let last = lastFrameUptime else {
            lastFrameUptime = uptime
            return
        }
        let intervalMs = (uptime - last) * 1000.0
        lastFrameUptime = uptime
        guard intervalMs > 0, intervalMs < 10_000 else { return }
        append(&frameIntervals, intervalMs, capacity: Self.ringCapacity)
        if intervalMs > largestIntervalMs { largestIntervalMs = intervalMs }
        // 超 1.5× 期望间隔 = 一次 hitch（与 Core Animation 的 hitch 定义同数量级，
        // 阈值写在 spec §4.2，不许为了好看调宽）。
        if intervalMs > expectedIntervalMs * 1.5 {
            totalHitchCount += 1
            hitchesSinceLastTick += 1
            signpostHitchLocked(intervalMs: intervalMs)
        }
    }

    private var lastFrameUptime: Double?

    // MARK: - 主线程心跳看门狗

    private var heartbeatObserver: CFRunLoopObserver?

    /// `CFRunLoopObserver` 观察 `.afterWaiting`：两次唤醒之间的间隔 = 主线程被占住多久。
    /// 选 afterWaiting 而不是 beforeWaiting，是因为"醒来"这个事件本身就是可交付的读数：
    /// 它一旦被拉长，拉长的那段就是用户感觉到的卡。
    private func startHeartbeatObserver() {
        let bridge = Unmanaged.passUnretained(self).toOpaque()
        let mask: CFRunLoopActivity = [.afterWaiting]
        // 实测签名：CFRunLoopObserverCreateWithHandler(allocator, activities, repeats, order, block)
        // —— 活动掩码在前、order 在后，写成 (allocator, runLoop, ...) 编不过。
        guard let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, mask.rawValue, true, 0, { [weak self] _, activity in
                guard activity == .afterWaiting else { return }
                _ = bridge  // 保留 C 指针版实现供 stop/restart 用；handler 版走 weak self
                self?.recordHeartbeatWake(at: Self.monotonicSeconds())
            }) else { return }
        _ = mask
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        heartbeatObserver = observer
    }

    private func recordHeartbeatWake(at time: Double) {
        lock.lock()
        defer { lock.unlock() }
        if let last = lastWakeUptime {
            let gapMs = max(0, (time - last) * 1000.0)
            append(&heartbeatGaps, gapMs, capacity: Self.heartbeatCapacity)
            if gapMs > largestHeartbeatGapMs { largestHeartbeatGapMs = gapMs }
        }
        lastWakeUptime = time
        heartbeatTickCount += 1
        let tickHadHitch = hitchesSinceLastTick > 0
        if tickHadHitch { ticksWithHitch += 1 }
        // 相位读数：这一拍里出了几帧、超了几帧。120 Hz × 1.5 s ≈ 180 帧是"满拍"。
        tickLedger.append("tick=\(heartbeatTickCount) frames=\(framesSinceLastTick) "
                          + "hitch=\(hitchesSinceLastTick) maxGapMs=\(f1(largestHeartbeatGapMs))")
        if tickLedger.count > 240 { tickLedger.removeFirst(tickLedger.count - 240) }
        hitchesSinceLastTick = 0
        framesSinceLastTick = 0
        if heartbeatTickCount % 20 == 0 { writeLineLocked(makeSummaryLineLocked()) }
    }

    // MARK: - 读数

    /// 当前汇总，一行、字段名固定（与 spec §1 表格逐列对得上）。
    public var summaryLine: String {
        lock.lock()
        defer { lock.unlock() }
        return makeSummaryLineLocked()
    }

    /// 调用方必须已持有 `lock`（属性 `summaryLine` 与内部落盘共用这一份实现）。
    private func makeSummaryLineLocked() -> String {
        let p50 = percentile(frameIntervals, 0.50)
        let p95 = percentile(frameIntervals, 0.95)
        let p99 = percentile(frameIntervals, 0.99)
        let run = max(0.001, Date().timeIntervalSince(startedAt))
        return "hz=\(f1(measuredRefreshHz))(\(refreshRateSource)) "
            + "期望间隔=\(f2(expectedIntervalMs))ms "
            + "帧数=\(totalFrameCount) 帧间隔p50=\(f2(p50)) p95=\(f2(p95)) p99=\(f2(p99)) max=\(f2(largestIntervalMs))ms "
            + "hitch(>1.5x)=\(totalHitchCount) hitch/s=\(f2(Double(totalHitchCount) / run)) "
            + "心跳拍数=\(heartbeatTickCount) 心跳最大间隔=\(f1(largestHeartbeatGapMs))ms "
            + "心跳p50=\(f1(percentile(heartbeatGaps, 0.50))) p95=\(f1(percentile(heartbeatGaps, 0.95))) "
            + "带hitch的拍=\(ticksWithHitch)/\(heartbeatTickCount)"
    }

    /// 供 UI / 日志消费的只读快照（字段与 `summaryLine` 同一批数，别在别处二次计算）。
    public struct Readout: Sendable {
        public var refreshHz: Double
        public var refreshRateSource: String
        public var expectedIntervalMs: Double
        public var frameCount: Int
        public var frameP50Ms: Double
        public var frameP95Ms: Double
        public var frameP99Ms: Double
        public var frameMaxMs: Double
        public var hitchCount: Int
        public var heartbeatTicks: Int
        public var heartbeatMaxGapMs: Double
        public var ticksWithHitch: Int
    }

    public var readout: Readout {
        lock.lock()
        defer { lock.unlock() }
        return Readout(refreshHz: measuredRefreshHz, refreshRateSource: refreshRateSource,
                       expectedIntervalMs: expectedIntervalMs, frameCount: totalFrameCount,
                       frameP50Ms: percentile(frameIntervals, 0.50),
                       frameP95Ms: percentile(frameIntervals, 0.95),
                       frameP99Ms: percentile(frameIntervals, 0.99),
                       frameMaxMs: largestIntervalMs, hitchCount: totalHitchCount,
                       heartbeatTicks: heartbeatTickCount,
                       heartbeatMaxGapMs: largestHeartbeatGapMs, ticksWithHitch: ticksWithHitch)
    }

    /// 相位账本尾部（最多 240 拍），用来回答"hitch 落在第几拍"。
    public var phaseLedger: [String] {
        lock.lock()
        defer { lock.unlock() }
        return tickLedger
    }

    // MARK: - 落盘

    private func openFile() {
        let path = Self.outputPath
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        fileHandle = FileHandle(forWritingAtPath: path)
        fileHandle?.seekToEndOfFile()
    }

    private func writeHeaderLocked() {
        writeLineLocked("# FramePulse 启动 \(Self.stamp(startedAt)) pid=\(getpid()) "
                        + "开关=TCODER_PERF_PROBE=1 探针线程=CVDisplayLink(非主线程)")
        writeLineLocked("# 期望间隔来自运行时读到的真实 Hz，不硬编码 120")
        // 【语义边界必须写在读数旁边】`心跳最大间隔` 是主线程 runloop 两次「结束等待」之间的
        // **唤醒间隔**，不是"主线程被占住了多久"：那段时间没有任何事件，间隔同样会很大。
        // 拿它当占用时长读，会把"机器很闲"读成"主线程卡了 1.5 秒"。
        writeLineLocked("# 语义提醒：心跳拍数/心跳最大间隔 = runloop 唤醒之间的间隔，不是主线程占用时长；"
                        + "空闲无事件时它同样会很大")
        writeLineLocked("# 要量主线程占用与帧预算，用 xctrace 的 app-update 相位（perf_harness.sh idle）；"
                        + "本文件的帧间隔 p95 才是 T1（交互期 hitch）的直接对象")
    }

    private func writeLineLocked(_ line: String) {
        guard let handle = fileHandle else { return }
        let text = line + "\n"
        if let data = text.data(using: .utf8) { handle.write(data) }
    }

    private func signpostHitchLocked(intervalMs: Double) {
        guard let log = signpostLog else { return }
        // 老式 os_signpost 宏（spec §2 探针确认过的形状）。
        // 注意：`OSSignposter` 的新式 `emit` / `signpost` 成员在本 SDK 签名不同，别照抄。
        os_signpost(.event, log: log, name: "FramePulse hitch",
                    "interval_ms=%f expected_ms=%f", intervalMs, expectedIntervalMs)
    }

    // MARK: - 小工具

    /// 单调时钟（`CLOCK_UPTIME_RAW`，与 mach_absolute_time 同域、即 CACurrentMediaTime 的域）。
    /// 不用 `CACurrentMediaTime()`：那要多 import 一个 QuartzCore，而本文件只用 Foundation 就能拿。
    static func monotonicSeconds() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
    }

    private func append(_ bucket: inout [Double], _ value: Double, capacity: Int) {
        bucket.append(value)
        if bucket.count > capacity { bucket.removeFirst(bucket.count - capacity) }
    }

    private func f1(_ v: Double) -> String { String(format: "%.1f", v) }
    private func f2(_ v: Double) -> String { String(format: "%.2f", v) }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

/// `CVDisplayLink` 要的 C 函数指针：真正的活都在 `recordFrameOutput` 里。
private func displayLinkCallback(_ displayLink: CVDisplayLink, _ now: UnsafePointer<CVTimeStamp>,
                                 _ outputTime: UnsafePointer<CVTimeStamp>,
                                 _ flagsIn: CVOptionFlags,
                                 _ flagsOut: UnsafeMutablePointer<CVOptionFlags>,
                                 _ context: UnsafeMutableRawPointer?) -> CVReturn {
    let uptime = FramePulse.monotonicSeconds()
    if let context {
        Unmanaged<FramePulse>.fromOpaque(context).takeUnretainedValue().recordFrameOutput(at: uptime)
    }
    return kCVReturnSuccess
}

// MARK: - 分位数（与 trace_report.py 同一定义）

/// 分位取法与 `scripts/trace_report.py` 的 `percentile()` 一字对齐：`values[min(n-1, Int(n*p))]`。
/// 两把尺子若各用一套分位定义，"内部 p95 好了、外部 p95 没好"这种争论就没法判。
func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let ordered = values.sorted()
    let index = min(ordered.count - 1, Int(Double(ordered.count) * p))
    return ordered[max(0, index)]
}

/// 帧间隔分布（纯函数，测试可脱离 `CVDisplayLink` 直接喂数）。
struct FrameIntervalDistribution {
    var values: [Double] = []
    var capacity = FramePulse.ringCapacity

    mutating func record(_ ms: Double) {
        guard ms > 0 else { return }
        values.append(ms)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }

    func hitchCount(expectedIntervalMs: Double, factor: Double = 1.5) -> Int {
        values.filter { $0 > expectedIntervalMs * factor }.count
    }

    var p50: Double { percentile(values, 0.50) }
    var p95: Double { percentile(values, 0.95) }
    var p99: Double { percentile(values, 0.99) }
    var maximum: Double { values.max() ?? 0 }
}

/// 心跳看门狗的间隔统计（纯函数）。
struct HeartbeatGapDistribution {
    var values: [Double] = []
    var capacity = FramePulse.heartbeatCapacity

    mutating func record(gapMs: Double) {
        guard gapMs >= 0 else { return }
        values.append(gapMs)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }

    var p50: Double { percentile(values, 0.50) }
    var p95: Double { percentile(values, 0.95) }
    var p99: Double { percentile(values, 0.99) }
    var maximum: Double { values.max() ?? 0 }
    var isEmpty: Bool { values.isEmpty }
}
