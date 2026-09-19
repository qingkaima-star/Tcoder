import XCTest
@testable import TcoderMonitor

/// 钉住 `ByteFormat` 的**非零**路径。
///
/// 起因：Dashboard 实时网络卡片在真机上 SIGSEGV 过两次（同一栈、间隔 30 秒），
/// 崩溃点在 `ByteFormat.bitRate` 里的 `String(format:)` —— 格式串用了 `%s`
/// 却传进 Swift `String`，CoreFoundation 走到 `_platform_strlen` 对野指针取长度。
/// 当时已有的测试只覆盖了 `Live.bitRate(nil) == "--"` 这一条**空值**分支，
/// 于是修复本身没有任何东西守着：谁把 `%s` 写回去，测试仍然全绿，
/// 只有 App 渲染到那一行才崩。
///
/// 这一类 bug 不需要断言写得有多巧 —— 只要真的把非零值过一遍，
/// 复发的表现就是测试进程当场段错误，门禁必然拦下。
final class ByteFormatRegressionTests: XCTestCase {

    // MARK: - bitRate：曾经崩溃的那个函数

    func testBitRateCoversEveryUnitBoundary() {
        XCTAssertEqual(ByteFormat.bitRate(0), "0 bps")
        XCTAssertEqual(ByteFormat.bitRate(1), "8 bps")
        XCTAssertEqual(ByteFormat.bitRate(124), "992 bps")       // 进位前最后一格
        XCTAssertEqual(ByteFormat.bitRate(125), "1.0 Kbps")      // 8*125 == 1000
        XCTAssertEqual(ByteFormat.bitRate(1_000_000), "8.0 Mbps")
        XCTAssertEqual(ByteFormat.bitRate(1_000_000_000), "8.0 Gbps")
    }

    /// 单位只到 Gbps 封顶：再大的真实值也必须留在合法量纲里，不能凭空造出一个单位。
    /// 实测 2 TB/s == 16 Tbps，而表里没有 Tbps 这一档，所以显示成 16000.0 Gbps ——
    /// 这是**设计上的封顶**，不是 bug：宁可数字大也不 invent 单位。
    func testBitRateStopsAtTheLargestKnownUnit() {
        let text = ByteFormat.bitRate(2_000_000_000_000)
        XCTAssertTrue(text.hasSuffix("Gbps"), "实际得到：\(text)")
        XCTAssertEqual(text, "16000.0 Gbps")
    }

    /// 真实采样里出现过极端值；格式化不能产出 `nan` / `inf` 这类用户读不懂的字符串。
    func testBitRateNeverRendersNonFiniteJunk() {
        for bytes in [UInt64.max, UInt64.max / 8, 9_223_372_036_854_775_807] {
            let text = ByteFormat.bitRate(bytes)
            XCTAssertFalse(text.contains("nan"), "实际得到：\(text)")
            XCTAssertFalse(text.contains("inf"), "实际得到：\(text)")
            XCTAssertFalse(text.isEmpty)
        }
    }

    // MARK: - string / rate：同一族的格式串，一起守

    func testByteStringHandlesBelowFirstThresholdWithoutDecimals() {
        XCTAssertEqual(ByteFormat.string(0), "0 B")
        XCTAssertEqual(ByteFormat.string(512), "512 B")
        XCTAssertEqual(ByteFormat.string(1023), "1023 B")
    }

    func testByteStringStepsThroughPowersOf1024() {
        XCTAssertEqual(ByteFormat.string(1536), "1.5 KB")
        XCTAssertEqual(ByteFormat.string(10 * 1024 * 1024), "10.0 MB")
        XCTAssertEqual(ByteFormat.string(3 * 1024 * 1024 * 1024), "3.0 GB")
    }

    /// 精度参数是调用方控制的，它会直接拼进格式串 —— 这里钉住它真的生效。
    func testByteStringHonoursPrecision() {
        XCTAssertEqual(ByteFormat.string(1 * 1024 + 512, precision: 2), "1.50 KB")
    }

    /// PB 是表里最后一档：超出后必须停在 PB 而不是数组越界。
    func testByteStringCapsAtTheLargestUnit() {
        let text = ByteFormat.string(UInt64.max)
        XCTAssertTrue(text.hasSuffix("PB"), "实际得到：\(text)")
    }

    func testRateAppendsPerSecondSuffix() {
        XCTAssertEqual(ByteFormat.rate(1024), "1 KB/s")
        XCTAssertEqual(ByteFormat.rate(0), "0 B/s")
    }
}
