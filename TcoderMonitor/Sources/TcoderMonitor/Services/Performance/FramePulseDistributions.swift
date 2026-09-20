import Foundation

/// `FramePulse` 的**分位与分布**分片（WS-X6 规模债切片，2026-09-21）。
///
/// `FramePulse.swift` 被本 App 自己扫成「巨大文件」（>400 行）。探针的四条语义
/// （只有 `TCODER_PERF_PROBE=1` 才创建 `CVDisplayLink`、关闭时零副作用、
/// 读数落文件而非 stdout、hitch 阈值 1.5× 期望间隔）都在原文件里，一行未动；
/// 搬来的这三个纯函数/纯类型本来就写着「与 `CVDisplayLink` 解耦、测试可脱离探针直接喂数」，
/// 它们与探针生命周期无耦合，是最该独立成章的那一层。
/// 逐字搬迁：函数体与文档注释一个字符未改（脚本比对过），只加了下面这行 import。

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
