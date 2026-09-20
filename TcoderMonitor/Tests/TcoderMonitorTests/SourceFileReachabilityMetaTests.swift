import Foundation
import XCTest
@testable import TcoderMonitor

// MARK: - 「④static 简写」证据的两条元测试
//
// **为什么单独成文**：`SourceFileReachabilityTests.swift` 在 2026-09-20 时正好 **800 行**，
// 而 `SelfScanDogfoodTests` 的 800 行闸门是「> 800 即红、`ceiling = 0`、不许放宽」。
// 按本仓规矩「**闸门不降、阈值不动——把文件拆开才是修复**」，这两条新加的元测试就拆出来。
//
// 拆分的唯一代价：它们用到的几个 helper 必须从 `private` 放成 `internal`
// （`private` 在同类型的**跨文件** extension 里不可见）。已在原文件对应声明处
// 逐条注明「为什么不再 private」，免得下一个人又把它改回去、然后在这儿踩编译错。
// MARK: - 可达性守卫的「合成夹具」元测试（从 `SourceFileReachabilityTests.swift` 拆出）
//
// **为什么单独成文**：`SourceFileReachabilityTests.swift` 在 2026-09-20 时正好 **800 行**，
// 而 `SelfScanDogfoodTests` 的 800 行闸门是「> 800 即红、`ceiling = 0`、不许放宽」。
// 按本仓规矩「**闸门不降、阈值不动——把文件拆开才是修复**」，本轮新增的两条元测试
// 连同主题相同的「元测试 3：分母为 0 必须判失败」一起搬到这里：
//
//   - `testStaticShorthandNeedsTheOwnerInScope` —— 同名成员不得给零调用文件「白送」证据
//   - `testLeadingDotRegexRequiresABareDot`     —— 直接钉前导点取词式本身
//   - `testEmptyScanIsReportedAsFailure`        —— 分母为 0 / 路径解析半失效必须判失败
//
// **拆分的代价，写在这里免得下一个人踩坑**：这几个 helper 必须从 `private` 放成
// `internal` —— `private` 在同类型的**跨文件** extension 里不可见。原文件顶部有对应说明，
// **别再改回 `private`**：改回去这个文件立刻编不过。
extension SourceFileReachabilityTests {

    /// **这条是为一个真实漏网补的，不是假想。** `Services/Performance/FramePulse.swift`
    /// 在产品代码里零调用（红线 8 明写「必须接线进产品代码后才允许合入」），却因为
    /// `leadingDotRE` 少了前导限制、把 `NSWorkspace.shared` 也收成了「前导点简写」，
    /// 被 5 处毫无关系的同名成员送出一条「④static 简写」证据，于是被判「在用」。
    /// 下面用**同形状**的合成夹具把规则钉死：带接收者的 `X.member` 不算前导点简写。
    func testStaticShorthandNeedsTheOwnerInScope() {
        let collide = """
        import Foundation
        struct WSUProbeCollide {
            static let shared = WSUProbeCollide()
            func wsuProbeCollideBody() -> Int { 1 }
        }
        """
        // 见证文件：真的在用**系统类型**的同名成员 `NSWorkspace.shared`，
        // 但**全文不提** `WSUProbeCollide`（这与真仓里 `Views/Code/CodeRiskRows.swift` 的形状一致）。
        // 它与下面 Caller 互相引用，所以两个文件都各自有真证据、不该被判死。
        let ownerlessWitness = """
        import AppKit
        enum WSUProbeUnrelatedDoor {
            static func wsuProbeOpen() -> String {
                _ = WSUProbeCaller.wsuProbeCall()
                return NSWorkspace.shared.description
            }
        }
        """
        let caller = """
        import Foundation
        enum WSUProbeCaller {
            static func wsuProbeCall() -> String { WSUProbeUnrelatedDoor.wsuProbeOpen() }
        }
        """
        let out = Self.buildOutcome(synth([("WSUProbeCollide.swift", collide, true),
                                           ("WSUProbeUnrelatedDoor.swift", ownerlessWitness, true),
                                           ("WSUProbeCaller.swift", caller, true)]), whitelist: [])
        let bogus = out.evidence["WSUProbeCollide.swift"] ?? []
        XCTAssertTrue(bogus.isEmpty,
                      "零调用文件靠**同名成员**拿到了证据——守卫会被这样骗过去：\(bogus)")
        XCTAssertTrue(out.unused.contains("WSUProbeCollide.swift"),
                      "同名成员给零调用文件背了书（在用：\(out.inUse)）")
        XCTAssertFalse(out.inUse.contains("WSUProbeCollide.swift"),
                      "零调用文件被判「在用」了，守卫等于零")
        XCTAssertTrue(out.inUse.contains("WSUProbeUnrelatedDoor.swift"),
                      "见证文件自己有调用点，不该被连坐判死；在用：\(out.inUse)")
        XCTAssertTrue(out.inUse.contains("WSUProbeCaller.swift"),
                      "互引用的一方被判死，说明这条规则误杀了正常代码；在用：\(out.inUse)")
    }

    /// 元测试的另一半，直接钉**取词式本身**：前导点必须是真前导。
    /// 这条对着"正则名不副实"这个具体死法——`leadingDotRE` 少了 `(?<![\w.])` 时，
    /// 下面第一个样例就会被误收，而那一处误收在真仓里刚好放过了一个零调用实现文件。
    func testLeadingDotRegexRequiresABareDot() {
        func members(_ text: String) -> [String] {
            let ns = text as NSString
            return Self.leadingDotRE.matches(in: text, range: NSRange(location: 0, length: ns.length))
                .map { ns.substring(with: $0.range(at: 1)) }
        }
        XCTAssertTrue(members("NSWorkspace.shared.description").isEmpty,
                      "带接收者的 `X.member` 被当成了前导点简写——这一处误收会白送证据")
        XCTAssertTrue(members("let s = FramePulse.shared").isEmpty,
                      "`FramePulse.shared` 不是前导点简写（它是②限定引用该管的事）")
        XCTAssertEqual(members("let role: Role = .requestAddProject"), ["requestAddProject"],
                       "真的前导点简写收不到了——合法的证据来源被切断")
        XCTAssertEqual(members("picker: .hidden, count: .max"), ["hidden", "max"],
                       "同行多处前导点简写只收到一个")
    }

    // MARK: - 元测试 3：分母为 0 必须判失败

    func testEmptyScanIsReportedAsFailure() {
        let g = Self.gate(ScanOutcome(), whitelist: [])
        XCTAssertFalse(g.pass, "分母为 0 却判通过 = 永真绿")
        XCTAssertTrue(g.reasons.first?.hasPrefix("分母为 0") == true, "必须点名分母问题：\(g.reasons)")
        // 只有测试文件、实现面为空，同样不许蒙过去
        let onlyTests = Self.buildOutcome(synth([("WSUBare.swift", "struct WSUBare { let x = 1 }", false)]),
                                          whitelist: [])
        XCTAssertFalse(Self.gate(onlyTests, whitelist: []).pass, "实现面为 0 而测试面非 0，也必须失败")
        // 分母虚高（路径解析半失效）也要失败：合成 2 个实现文件 < 100
        let tiny = Self.buildOutcome(synth([
            ("WSUTinyA.swift", "struct WSUTinyA { let wsuTinyField = 1 }", true),
            ("WSUTinyB.swift", "enum WSUTinyB { static func use() { _ = WSUTinyA() } }", true)]), whitelist: [])
        XCTAssertTrue(Self.gate(tiny, whitelist: []).reasons.contains { $0.contains("路径解析静默失效") },
                      "小分母必须被当成扫描器故障，而不是「真干净」")
    }
}
