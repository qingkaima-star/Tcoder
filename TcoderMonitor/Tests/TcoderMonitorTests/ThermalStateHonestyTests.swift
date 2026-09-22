import Foundation
import XCTest
@testable import TcoderMonitor

/// RD-34：`ThermalState` 以前只有 nominal/fair/serious/critical 四档，
/// 而 `init(processInfoValue:)` 用 `default: self = .nominal` 收尾，
/// `SystemSnapshot.thermalState` 的**属性默认值也是 `.nominal`**。
/// 后果：读不到热压力时报告「正常」—— 没有证据也给好结论。
///
/// 【独立真值从哪来】不是工具自己的输出，是 macOS SDK 头文件
/// `Foundation.framework/Headers/NSProcessInfo.h` 里的
/// `typedef NS_ENUM(NSInteger, NSProcessInfoThermalState)`：Nominal / Fair / Serious / Critical
/// 隐式从 0 起算，即 0/1/2/3（本文件 `testSDKValueRangeIsTheOnlyTruth` 按这四个数钉映射）。
/// 同一处头文件还写着本流**保留的边界**，见 `testResidualBlindSpotStaysDocumented`。
///
/// 【修前的可复现读数】把 main 里的旧 enum 用 `git show` 逐字节抠出来单独编译跑
/// （驱动与输出记在 Obsidian《114 WS-R8 整机与项目边界真修》）：
/// `raw=-1 / 4 / 99` 三档旧实现全部上屏「正常」，本文件钉的是修后的相反结论。
final class ThermalStateHonestyTests: XCTestCase {

    // MARK: - 反例：量不到必须是「未量到」，不许落到「正常」

    /// 四档之外的任何原始值 → `.unknown`；上屏含「未量到」且**不含**「正常」。
    func testUnrecognizedRawValueBecomesNotMeasured() {
        for raw in [-1, 4, 99, Int.min, Int.max] {
            let state = ThermalState(processInfoValue: raw)
            XCTAssertEqual(state, .unknown, "raw=\(raw) 被认成了 \(state)：不认识的值不许有结论")
            XCTAssertFalse(state.isMeasured, "raw=\(raw) 明明是量不到，却报告 isMeasured")
        }
        let displayed = SystemReadings.thermalText(thermalContext(.unknown))
        XCTAssertTrue(displayed.contains("未量到"), "上屏没说出「未量到」，实际「\(displayed)」")
        XCTAssertFalse(displayed.contains("正常"), "量不到却上屏「正常」，实际「\(displayed)」")
    }

    /// 探针压根没给值（`nil`）与给了个越界值，两条缺席路必须落到同一档。
    func testProbeWithoutValueAndBogusValueShareOneAbsence() {
        XCTAssertEqual(ThermalState.from(processInfoValue: nil), .unknown)
        XCTAssertEqual(ThermalState.from(processInfoValue: 7), .unknown)
        XCTAssertEqual(ThermalState.from(processInfoValue: 0), .nominal, "0 是真 nominal，不许一并推倒")
    }

    /// 走到**采样器**那一层的反例：注入一个问不到的探针，整帧必须是「未量到」。
    ///
    /// 这条专门钉工单点的那个坑（改默认值时显式传参/二层转发把新默认盖回旧值）：
    /// `SystemSampler.snapshot` 里 `SystemSnapshot()` 先给 `.unknown`，紧接着这一格被探针覆写；
    /// 只改属性默认值而漏掉那一行，屏幕上仍是旧行为。
    func testSamplerAbsenceReachesSnapshot() {
        XCTAssertEqual(frame(from: SystemSampler(thermalReading: { nil })).thermalState, .unknown)
        XCTAssertEqual(frame(from: SystemSampler(thermalReading: { 42 })).thermalState, .unknown)
        // 同一条注入缝的正向对照：探针给 1 必须是 fair。
        // 没有这条，上面两条「什么都算 unknown」的判据也能全绿。
        XCTAssertEqual(frame(from: SystemSampler(thermalReading: { 1 })).thermalState, .fair)
    }

    /// 双向元测试：真 nominal 的样本必须仍判 nominal，四档逐个按 SDK 的 0/1/2/3 钉。
    func testSDKValueRangeIsTheOnlyTruth() {
        let measured: [(Int, ThermalState)] = [(0, .nominal), (1, .fair), (2, .serious), (3, .critical)]
        XCTAssertEqual(measured.map(\.0), ThermalState.processInfoValueSpace,
                       "取值域与 SDK 的 NSProcessInfoThermalState 不再是同一份口径")
        for (raw, expected) in measured {
            let state = ThermalState(processInfoValue: raw)
            XCTAssertEqual(state, expected, "SDK 的 \(raw) 档被映射成了 \(state)")
            XCTAssertTrue(state.isMeasured, "\(state) 是测得的档，不许报缺席")
        }
        // 五档、字面互不相同 ⇒ 判据不可能退化成「什么都算 unknown」。
        XCTAssertEqual(ThermalState.allCases.count, 5)
        XCTAssertEqual(Set(ThermalState.allCases.map(\.rawValue)).count, 5)
    }

    /// 双向元测试：真 nominal 的样本上屏仍含「正常」，不许为了过反例把正向判据一起废掉。
    func testNominalSampleStillDisplaysNormal() {
        XCTAssertEqual(SystemReadings.thermalText(thermalContext(.nominal)), "正常")
        XCTAssertFalse(SystemReadings.thermalText(thermalContext(.nominal)).contains("未量到"))
    }

    /// 两层缺席互不替代：无帧 → `--`；有帧但量不到 → 「未量到」。
    func testTwoLayersOfAbsenceStayDistinct() {
        let noFrame = SystemReadings.thermalText(SampleContext(snapshot: nil, historyCount: 0, isPaused: false))
        XCTAssertEqual(noFrame, Live.missing, "一帧都没有时该是占位符，实际「\(noFrame)」")
        XCTAssertFalse(noFrame.contains("正常"), "无帧却上屏「正常」")

        let unreadFrame = SystemReadings.thermalText(thermalContext(.unknown))
        XCTAssertNotEqual(unreadFrame, noFrame,
                          "「没帧」与「有帧但量不到」塌成同一句，用户就分不出该等还是该修")
    }

    /// 一帧都没采到时，`SystemSnapshot()` 自己就得说「未量到」。
    /// 旧属性默认值是 `.nominal`，`PerfReadoutCells` 当年只能把 `thermal` 留成 Optional 绕开它。
    func testFreshSnapshotDefaultsToNotMeasured() {
        XCTAssertEqual(SystemSnapshot().thermalState, .unknown,
                       "空快照的热压力是 \(SystemSnapshot().thermalState)：没测到却带结论")
        XCTAssertFalse(SystemSnapshot().thermalState.isMeasured)
    }

    // MARK: - 落盘兼容：四档时代写的 JSON 必须照样解得开

    /// 四档时代的四个原字面逐个回灌解码，值一个不许变味、也不许被判成缺席。
    func testLegacyFourTierValuesStillDecode() throws {
        let legacy: [(String, ThermalState)] = [
            ("正常", .nominal), ("尚可", .fair), ("偏热", .serious), ("过热", .critical),
        ]
        for (raw, expected) in legacy {
            let snapshot = try decodeSnapshot(thermalLiteral: raw)
            XCTAssertEqual(snapshot.thermalState, expected, "旧值「\(raw)」解出来变了味")
            XCTAssertTrue(snapshot.thermalState.isMeasured, "旧四档都是测得的档，不许判成缺席")
        }
    }

    /// 新增档能往返：落盘的「未量到」再解回来仍是缺席，不会被补成「正常」。
    func testUnknownRoundTripsThroughJSON() throws {
        var snapshot = SystemSnapshot()
        snapshot.thermalState = .unknown
        snapshot.timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let data = try JSONEncoder().encode(snapshot)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("未量到"), "落盘里没留下缺席档：\(text.prefix(240))")
        XCTAssertEqual(try JSONDecoder().decode(SystemSnapshot.self, from: data).thermalState, .unknown)
    }

    /// 把一条**已知约束**钉成断言而不是注释：`thermalState` 至今是非 Optional 属性，
    /// 所以「整键缺席」在这里等于**整份解不开**，不是"缺席档"。
    /// 今天 `SystemSnapshot` 不落盘（只有 `ProjectReport` 落），所以这不构成缺陷；
    /// 但谁要把它接进 `ProjectReport`，这条会当场红给他看 —— 那时必须改成 `ThermalState?`，
    /// 而不是给自己补一个 `.nominal` 默认值（那正是 RD-34 的成因）。
    func testAbsentKeyFailsInsteadOfSilentlyBecomingNominal() throws {
        let data = try JSONEncoder().encode(SystemSnapshot())
        guard var object = try JSONSerialization.jsonObject(with: data, options: .mutableContainers)
                as? [String: Any] else {
            return XCTFail("夹具不是 JSON 对象，无从删键")
        }
        XCTAssertNotNil(object.removeValue(forKey: "thermalState"), "夹具里没有那一键，删它无从谈起")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(SystemSnapshot.self, from: stripped),
                             "非 Optional 属性缺键必须判解码失败；它若悄悄解成 .nominal，"
                                 + "就是把「没落这一项」冒充成「量到了正常」")
    }

    // MARK: - ②保留的边界（拿 SDK 原文钉住，别让下一轮以为已彻底修好）

    /// 本流只做到「读不到绝不说正常」。**仍然判不了的那一半**由 SDK 头文件原文写着：
    /// 不支持热压力上报的机器上 `thermalState` 恒回 `NSProcessInfoThermalStateNominal`，
    /// 而系统没有受支持 API 能问出「这台机器到底会不会报」——所以那种机器上「正常」
    /// 仍可能是「没这回事」。这一条不许被写成「unknown 已覆盖全部缺席」，
    /// 所以把它钉成两处文字断言：产线代码里必须留着这句说明。
    func testResidualBlindSpotStaysDocumented() throws {
        let cells = try filesInPerformanceLayer("PerfReadoutCells.swift")
        XCTAssertTrue(cells.contains { $0.content.contains("恒回") },
                      "读数格里那条「恒回 nominal」的残余边界说明被删了：RD-34 只修了一半")
        XCTAssertTrue(cells.contains { $0.content.contains("未量到") },
                      "两态互不替代的说明要留在格子那边，别只住在视图里")
        let sampler = try filesInPerformanceLayer("SystemSampler.swift")
        XCTAssertTrue(sampler.contains { $0.content.contains("ThermalState.from(processInfoValue:") },
                      "采样器不再走这一条产出点，本文件的说明要一起改")
    }

    // MARK: - 夹具

    private func thermalContext(_ state: ThermalState) -> SampleContext {
        var snapshot = SystemSnapshot()
        snapshot.thermalState = state
        snapshot.timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        return SampleContext(snapshot: snapshot, historyCount: 2, isPaused: false)
    }

    private func frame(from sampler: SystemSampler) -> SystemSnapshot {
        sampler.snapshot(previous: nil, current: SystemCounters(), processCount: 1)
    }

    /// 用今世的完整编码当底座，只把 `thermalState` 那一个值换成旧字面 ——
    /// 这样"旧 JSON"里其余的键与今天的 schema 一字不差，测的确实只有那一档的兼容性。
    private func decodeSnapshot(thermalLiteral raw: String) throws -> SystemSnapshot {
        let text = try JSONEncoder().encode(SystemSnapshot())
        var json = String(decoding: text, as: UTF8.self)
        let currentLiteral = "\"thermalState\":\"\(ThermalState.unknown.rawValue)\""
        guard json.contains(currentLiteral) else {
            throw FixtureError(why: "夹具没造出缺席档，换成旧字面的断言无从谈起：\(json.prefix(240))")
        }
        json = json.replacingOccurrences(of: currentLiteral, with: "\"thermalState\":\"\(raw)\"")
        return try JSONDecoder().decode(SystemSnapshot.self, from: Data(json.utf8))
    }

    /// 只取 `Services/Performance/**` 里名字匹配的文件；扫不到就当场判败（分母 > 0）。
    private func filesInPerformanceLayer(_ suffix: String) throws -> [(path: String, content: String)] {
        let files = DesignAbsenceStateTests.swiftFiles(under: "Services/Performance")
        XCTAssertFalse(files.isEmpty, "扫不到 Services/Performance，这条说明断言就是永真绿")
        let matched = files.filter { $0.path.hasSuffix(suffix) }
        XCTAssertFalse(matched.isEmpty, "扫不到 \(suffix)，说明断言没有对象")
        return matched
    }
}

// MARK: - 防回潮守卫：整机读数不得进项目评分与无头 CLI 的结论面

extension ThermalStateHonestyTests {

    /// 评分与 CLI 的输入面**不许**出现任何机器读数。
    ///
    /// 为什么钉「没有」而不是「缺席时不计分」：`HealthInputs` 只有 code/git/logs/deps/coverage 五样，
    /// 热压力这一维从来不存在，`unknown` 也就无从"落进缺席维度"。一旦有人把它接进去，
    /// `.unknown` 会以「这一维满分或零分」的形态进综合分，而那一维量的根本不是这个项目。
    /// 把入口钉死比事后判缺席便宜得多，也更接近用户要的边界。
    ///
    /// needle 不带左括号，命中带原始行号；整行注释由 `DesignAbsenceStateTests.scan` 豁免。
    func testMachineReadingsCannotReachScoringOrCLI() throws {
        let needles = ["thermalState", "ThermalState", "SystemSnapshot", "latestSnapshot",
                       "memoryPressure", "cpuUsage"]
        for (directory, label) in [("Services/Health", "健康评分"), ("Services/CLI", "无头 CLI")] {
            let files = DesignAbsenceStateTests.swiftFiles(under: directory)
            XCTAssertFalse(files.isEmpty, "扫不到 \(directory)，这条守卫是永真绿")
            for needle in needles {
                let hits = try DesignAbsenceStateTests.scan(needle, in: files)
                XCTAssertTrue(hits.isEmpty,
                              "\(label)侧读到整机量 \(needle)（\(hits.count) 处）："
                                  + "那会把「某一秒的机器状态」说成「这个项目的属性」\n"
                                  + DesignAbsenceStateTests.describe(hits))
            }
        }
    }

    /// 元测试（证明上面那条有牙）：合成违例真命中、合法样例不误判、空扫描不能当通过。
    func testMetaMachineReadoutGuardCatchesAndSpares() throws {
        let bad = [(path: "Services/Health/Fake.swift", content: """
        import Foundation
            let frame = latestSnapshot
            let thermal = snapshot.thermalState
        """)]
        let hits = try DesignAbsenceStateTests.scan("thermalState", in: bad)
        XCTAssertEqual(hits.count, 1, "埋了一处违例没抓到，尺子是假的")
        XCTAssertEqual(hits.first?.line, 3, "命中必须带原始行号，实际 \(hits.first?.line ?? -1)")
        XCTAssertTrue(hits.first?.file.contains("Fake.swift") == true, "报错必须指到文件")

        let good = [(path: "Services/Health/FakeOK.swift", content: """
        // 以前这里读过 snapshot.thermalState，RD-34 之后整机量一律不进评分
            let score = HealthCurves.complexity(hotspots: hotspots)
        """)]
        XCTAssertTrue(try DesignAbsenceStateTests.scan("thermalState", in: good).isEmpty,
                      "注释里的历史提法被误判，这条守卫活不过下一轮")

        let empty: [(path: String, content: String)] = []
        XCTAssertTrue(try DesignAbsenceStateTests.scan("thermalState", in: empty).isEmpty)
        XCTAssertNotEqual(empty.count, 1, "空输入也能凑出分母，说明扫描面必须另钉 > 0")
        XCTAssertFalse(DesignAbsenceStateTests.swiftFiles(under: "Services/Health").isEmpty,
                       "真源码扫不到文件 = 路径坏了，上面所有元测试通过也没意义")
    }
}

extension ThermalState {
    /// SDK 里 `NSProcessInfoThermalState` 的取值域（Nominal..Critical 隐式 0...3）。
    /// 写成一份，免得「哪些原始值算认识」这件事在各处再抄一遍数字。
    /// 这条是**测试侧的独立真值**（抄自 SDK 头文件），故意不放进 `Sources`，
    /// 否则判据与期望值就成了同一份代码自证。
    static let processInfoValueSpace: [Int] = [0, 1, 2, 3]
}

/// 夹具自证的失败：造不出被测对象时**当场报错**，不许退化成"什么都没测到所以通过"。
private struct FixtureError: Error, CustomStringConvertible {
    let why: String
    var description: String { why }
}
