import XCTest

/// OWNER: 总工（性能轮 M0）。钉 **采样节拍只有一个真值来源**（性能 spec §5.1）。
///
/// ## 为什么要这条守卫
///
/// `docs/口径与已知限制.md` 记的是「1.5 秒在视图里有三处独立字面量」，
/// 本文件写作时实测是 **7 处**：显示字面量 4 + 写进算术 1 + 代码真值 2
/// （`AppState` 与 `MachSystemMonitor.toggleRunning()` 各写了一次 `1_500`）。
/// 节拍一改，界面文案与窗口秒数会**静默说谎**——而它同时是曲线轴的依据。
///
/// ## 两个方向都要测，否则这把尺子量的是个模糊集
///
/// 仓库里 `1.5` 这个数还有大量**与节拍无关**的合法用途：`barRadius: CGFloat = 1.5`、
/// `abs(sum - overall) <= 1.5` 容差、`max(1.5, ...)` 时间跨度下限、注释里的
/// 「1.5pt 线宽」「1.5 GB」「1.5:1 对比度」。所以：
/// ① 正向元测试证明真违规打得中；② 反向元测试证明这些同形数字不会被误判。
/// 只测正向会得到一条"看见 1.5 就红"的噪声守卫，然后被人整个关掉。
final class PerfCadenceSingleSourceTests: XCTestCase {

    private static let packageRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // → TcoderMonitorTests
        .deletingLastPathComponent()   // → Tests
        .deletingLastPathComponent()   // → TcoderMonitor（包根；再退一层就出包了）

    /// 递归列全（**只递归一层会静默漏掉 `Services/Performance/**` 这类第二层文件**，
    /// 而漏文件的表现正是"扫到 0 命中、守卫漂亮地绿"，所以这里宁可一次列全）。
    private static func swiftFiles(under relative: String) -> [URL] {
        let dir = packageRoot.appendingPathComponent(relative)
        guard let all = try? FileManager.default.subpathsOfDirectory(atPath: dir.path) else { return [] }
        return all.filter { $0.hasSuffix(".swift") }
            .map { dir.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func text(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private static func hits(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }

    /// 视图里「节拍语义」的字面量：字符串里的 `1.5 秒`，或把节拍乘进算术的 `* 1.5`。
    static let cadenceInViewPattern = #""[^"]*1\.5 秒|\* *1\.5\b"#

    /// 调用方自己传数字节拍（例 `start(intervalMilliseconds: 1_500)`）= 第二个真值来源。
    static let secondSourcePattern = #"intervalMilliseconds:\s*[0-9]"#

    /// 现状实测基线，**只减不增**。目标 0 由 WS-O（1 处）+ WS-W（4 处）在 M1 清零。
    static let cadenceInViewBaseline = 5

    // MARK: - 主门

    func testCadenceLiteralsInViewsDoNotGrowBeyondBaseline() throws {
        let files = Self.swiftFiles(under: "Sources/TcoderMonitor/Views")
        XCTAssertFalse(files.isEmpty, "视图目录一个文件都没读到——扫描面失效，此时任何计数都是假的")
        var total = 0
        var named: [String] = []
        for url in files {
            let found = Self.hits(Self.cadenceInViewPattern, in: Self.text(url))
            total += found.count
            found.forEach { named.append("\(url.lastPathComponent): \($0)") }
        }
        XCTAssertLessThanOrEqual(total, Self.cadenceInViewBaseline,
            """
            视图里写死的采样节拍从基线 \(Self.cadenceInViewBaseline) 涨到 \(total)。
            节拍真值只有 `MachSystemMonitor.defaultSampleIntervalMilliseconds` 一处，
            页面要显示节奏请改读 `state.monitor.sampleIntervalText`（秒数用 `windowSeconds(pointCount:)`），
            不要新增字面量。当前命中：\(named)
            """)
        XCTAssertTrue(total > 0,
            "基线是 \(Self.cadenceInViewBaseline)，如今数到 \(total)：若真是清零了，请同步把本条基线改成 0，"
            + "不要让一条 0>0 也成立的断言冒充守卫已经完成任务。")
    }

    func testNoSecondCadenceSourceInCode() throws {
        let files = Self.swiftFiles(under: "Sources/TcoderMonitor")
        XCTAssertFalse(files.isEmpty, "Sources 读不到文件——扫描面失效")
        var named: [String] = []
        for url in files where Self.hits(Self.secondSourcePattern, in: Self.text(url)).count > 0 {
            named.append(url.lastPathComponent)
        }
        XCTAssertTrue(named.isEmpty,
            "有人把数字节拍直接传进 start(...)：\(named)。真值只许定义一次，调用方传常量名。")
    }

    // MARK: - 元测试：正向（真违规必须打得中）

    func testGuardsFireOnRealShapedViolations() throws {
        let cadenceSample = """
        struct Card: View {
            var body: some View { Text("本机 · 每 1.5 秒采样") }
            static let window = Double(90) * 1.5
        }
        """
        XCTAssertEqual(Self.hits(Self.cadenceInViewPattern, in: cadenceSample).count, 2,
            "节拍守卫抓不住「1.5 秒」文案或 `* 1.5` 算术，它已经废了")

        let sourceSample = "monitor.start(intervalMilliseconds: 1_500)"
        XCTAssertEqual(Self.hits(Self.secondSourcePattern, in: sourceSample).count, 1,
            "第二真值守卫抓不住数字节拍，它已经废了")
    }

    // MARK: - 元测试：反向（同形但无关的 1.5 不许误伤）

    func testGuardsIgnoreNonCadenceUsesOfTheSameNumber() throws {
        let innocent = """
        private static let barRadius: CGFloat = 1.5
        /// 面积把自己的 1.5pt 曲线糊在下面；「1.5 GB」位数不同要锁宽；白字对比约 1.5:1。
        static func withinTolerance(_ sum: Double, _ overall: Int) -> Bool {
            abs(sum - Double(overall)) <= 1.5
        }
        static func span(_ first: Date, _ last: Date) -> TimeInterval {
            max(1.5, last.timeIntervalSince(first))
        }
        """
        XCTAssertTrue(Self.hits(Self.cadenceInViewPattern, in: innocent).isEmpty,
            "节拍守卫误伤了与节拍无关的 1.5：\(Self.hits(Self.cadenceInViewPattern, in: innocent))"
            + " —— 误报的守卫活不过一轮，会被连真违规一起关掉")
    }

    // MARK: - 真值来源确实存在且被消费（防止"清掉了但没人接"）

    func testSingleSourceOfTruthExistsAndIsDerivedFrom() throws {
        let monitorText = Self.text(Self.packageRoot
            .appendingPathComponent("Sources/TcoderMonitor/Services/Performance/MachSystemMonitor.swift"))
        XCTAssertEqual(Self.hits(#"defaultSampleIntervalMilliseconds: UInt64 = \d+"#, in: monitorText).count, 1,
            "节拍真值定义必须存在且只有一处")
        XCTAssertTrue(monitorText.contains("var sampleIntervalText: String"),
            "缺 `sampleIntervalText`：页面就没有不含字面量的节奏文案可用，只能回去抄字符串")
        XCTAssertTrue(monitorText.contains("func windowSeconds(pointCount: Int)"),
            "缺 `windowSeconds(pointCount:)`：窗口秒数会继续由页面自己乘一个魔法数")
    }
}
