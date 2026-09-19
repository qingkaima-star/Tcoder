//
//  内存读数的诚实性：一次内核调用失败绝不能被画成「内存 100% 占满」
//
//  缺陷（WS-D 审计 P1）：`host_statistics64` 一失败就 `return VmCounters(pageSize:)`，
//  七项页计数全 0 → `reclaimableBytes == 0` → `memoryUsedBytes` 返回 `totalBytes - 0`
//  → 视图显示「128.0 GB / 128 GB · 压力 紧张 · 占 100%」，还会把这帧连进历史曲线。
//  根因不在算术，在**返回类型把失败信号擦掉了**：`VmCounters` 无法区分
//  「这台机器真的一个空闲页都没有」和「这次什么都没读到」。
//
//  这一批用例钉的是修复后的契约；`pressure(for:available:)` 的 `available == false`
//  是 `MemoryPressure.unknown` 在本仓库里**唯一**的产出路径。
//
import XCTest
@testable import TcoderMonitor

final class PerformanceMemoryHonestyTests: XCTestCase {

    private let total: UInt64 = 128 * 1_024 * 1_024 * 1_024   // 128 GiB，审计里那台机器

    /// 造一次「vm 读数缺失」的原始采样。
    private func counters(vm: VmCounters?) -> SystemCounters {
        SystemCounters(timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                       cores: [], vm: vm,
                       diskReadBytes: 0, diskWriteBytes: 0,
                       networkInBytes: 0, networkOutBytes: 0)
    }

    // MARK: - 1. 全 0 页计数不是「真的没内存」，是不可用的读数

    func testAllZeroPageCountersAreRecognisedAsFailedRead() {
        XCTAssertFalse(VmCounters().isUsableRead,
                       "七项页计数全 0 不可能是真实机器状态，必须判为不可用")
        XCTAssertFalse(VmCounters(pageSize: 0, active: 720_505, wired: 341_465,
                                  compressed: 1_300_992, free: 400).isUsableRead,
                       "页大小为 0 时所有字节数都会算成 0，同样不可用")
        XCTAssertTrue(VmCounters(pageSize: 16_384, active: 1).isUsableRead,
                      "只要有一个非 0 页计数且页大小有效，就是可用读数")
    }

    // MARK: - 2. 失败读数不得产生「已用 = 总量」

    func testFailedVmReadDoesNotClaimMemoryFullyUsed() {
        let snapshot = SystemSampler().snapshot(previous: nil, current: counters(vm: nil),
                                                processCount: 10)
        XCTAssertNotEqual(snapshot.memoryUsedBytes, snapshot.memoryTotalBytes,
                          "内核调用失败被画成「已用 == 总量」，正是审计报的那个假 100%")
        XCTAssertNotEqual(snapshot.memoryPressure, .critical,
                          "没有任何证据时不得判「紧张」")
    }

    func testAllZeroVmCountersDoNotClaimMemoryFullyUsed() {
        // 直接走 `vmCounters()` 失败时实际返回的那个值（全 0 页计数 + 真页大小）。
        let snapshot = SystemSampler().snapshot(previous: nil,
                                                current: counters(vm: VmCounters(pageSize: 16_384)),
                                                processCount: 10)
        XCTAssertNotEqual(snapshot.memoryUsedBytes, snapshot.memoryTotalBytes,
                          "全 0 页计数经 `total - reclaimable` 会得出已用 == 总量")
    }

    // MARK: - 3. `MemoryPressure.unknown` 必须真的被产出

    func testFailedVmReadProducesUnknownPressure() {
        let snapshot = SystemSampler().snapshot(previous: nil, current: counters(vm: nil),
                                                processCount: 10)
        XCTAssertEqual(snapshot.memoryPressure, .unknown,
                       "缺读数必须落到 unknown——视图已有该档（memoryTint 走中性色）")
    }

    func testUnknownIsTheOnlyWayToReachTheUnknownCase() {
        // `unknown` 历史上是死枚举值：分数档位全由 fraction 决定，永远不会返回它。
        XCTAssertEqual(SystemSampler.pressure(for: 0, available: false), .unknown)
        XCTAssertEqual(SystemSampler.pressure(for: 1, available: false), .unknown)
        XCTAssertEqual(SystemSampler.pressure(for: 0.99, available: true), .critical,
                       "可用读数不得被顺手降级，否则这条修复会制造新的假「未知」")
    }

    // MARK: - 4. 正常路径不能被改坏

    func testUsableVmReadStillYieldsNumericPressureAndFraction() {
        let vm = VmCounters(pageSize: 16_384, active: 1_000_000, inactive: 500_000,
                            wired: 300_000, compressed: 100_000, free: 1_000_000,
                            speculative: 10, purgeable: 5)
        let snapshot = SystemSampler().snapshot(previous: nil, current: counters(vm: vm),
                                                processCount: 10)
        XCTAssertGreaterThan(snapshot.memoryUsedBytes, 0)
        XCTAssertLessThan(snapshot.memoryUsedBytes, snapshot.memoryTotalBytes)
        XCTAssertNotEqual(snapshot.memoryPressure, .unknown,
                          "有可用读数时不该给「未知」——那是把真数据也变成不可信")
    }

    // MARK: - 5. 真机首帧仍必须是可用读数（防止把修复写成「永远未知」）

    func testLiveVmReadingIsUsableOnThisMachine() {
        let vm = SystemSampler.vmCounters()
        XCTAssertNotNil(vm, "本机 host_statistics64 应当成功；失败说明测试环境异常，该报错而不是静默")
        XCTAssertEqual(vm?.isUsableRead, true)
    }
}
