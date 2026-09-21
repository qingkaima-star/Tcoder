import Foundation
import SwiftUI
import XCTest
@testable import TcoderMonitor

// MARK: - 色相族守卫（批次 P5）
//
// 从 `DesignTokenTests.swift` 拆出来住：那份加完 475 行，超了
// `X3TestSizeAuditTests` 与产品同口径的 400 行线。判据、合成样例一字未改。
// 拆的理由本身也值得记一句：**这条守卫要防的就是"两套东西干同一件事"**，
// 而测试文件超线时正确做法是拆文件，不是抬阈值。

extension DesignTokenTests {
    // MARK: - F2. 正向档只许一支绿（批次 P5 的教训机器化）

    /// 色相族。族的边界是**约定**，所以必须配元测试钉住：
    /// `#2CA94C`（草绿 124°）与 `#2AA694`（青绿 171°）都算"绿族"——
    /// 这正是当初没被抓到的那对：人眼看是"两种绿"，任何按名字写的断言都看不出。
    static func hueFamily(of token: ColorToken) -> String {
        let mx = max(token.red, token.green, token.blue)
        let mn = min(token.red, token.green, token.blue)
        let d = mx - mn
        // 低彩度一律算"无彩色"：`neutral` 的 `#8E8E93` 三通道只差 5/255，
        // 按纯几何色相它会落进 240° 被判成"蓝"。这条是元测试当场抓到的。
        guard mx > 0.0001, d / mx > 0.10 else { return "无彩色" }
        var deg: Double
        if mx == token.red { deg = 60 * (((token.green - token.blue) / d).truncatingRemainder(dividingBy: 6)) }
        else if mx == token.green { deg = 60 * ((token.blue - token.red) / d + 2) }
        else { deg = 60 * ((token.red - token.green) / d + 4) }
        if deg < 0 { deg += 360 }
        switch deg {
        case ..<16, 345...: return "红"
        case 16..<46: return "橙"
        case 46..<176: return "绿"
        case 176..<200: return "青"
        case 200..<260: return "蓝"
        case 260..<300: return "紫"
        default: return "品红"
        }
    }

    /// 正向（绿族）在色阶里出现几档。**超过一档就是"第二套强调色"**：
    /// 绿同时被 `accent` 用作交互色，所以色阶里的第二支绿无法与"可点的"区分。
    /// 反向的红档（danger/critical）不在此列 —— 两支红读作"程度阶梯"，且不与交互色相邻。
    static func duplicatedPositiveFamilies(_ roles: [(name: String, light: ColorToken,
                                                     dark: ColorToken)]) -> [String] {
        var seen: [String: [String]] = [:]
        for role in roles {
            for family in Set([hueFamily(of: role.light), hueFamily(of: role.dark)])
            where family == "绿" {
                seen[family, default: []].append(role.name)
            }
        }
        return seen.filter { $0.value.count > 1 }.map { "\($0.key)族: \($0.value.joined(separator: " / "))" }
    }

    /// 权威判定：**健康分色阶实际返回的角色**里，绿族只许一档。
    func testScoreScaleHasExactlyOneGreenTier() {
        let names = Set(stride(from: 100, through: 0, by: -1).map {
            Theme.Semantic.role(forScore: $0).name
        })
        let ramp = Theme.Semantic.measurable.filter { names.contains($0.name) }
        XCTAssertFalse(ramp.isEmpty, "分数色阶解析出 0 个角色 —— 断言没在检查任何东西")
        let clash = Self.duplicatedPositiveFamilies(ramp.map {
            (name: $0.name, light: $0.graphic.token(in: .light), dark: $0.graphic.token(in: .dark))
        })
        XCTAssertTrue(clash.isEmpty,
                      "健康分色阶里出现第二支绿（用户读到的是两套强调色）：\(clash)")
    }

    /// 元测试：这条判据必须**双向**有效 —— 合成一对"两种绿"要报，
    /// 两支红不得误报（否则它只是在替我当前的取值背书，等于一条废守卫）。
    func test_greenFamilyGuardCatchesTwoGreensButSparesTwoReds() {
        func token(_ hex: UInt32) -> ColorToken { ColorToken(hex: hex) }
        let twoGreens = Self.duplicatedPositiveFamilies([
            (name: "success", light: token(0x2CA94C), dark: token(0x30D158)),
            (name: "healthy", light: token(0x2AA694), dark: token(0x4ED8C0)),   // 退役前的 teal 档
        ])
        XCTAssertEqual(twoGreens, ["绿族: success / healthy"],
                       "合成的一对两种绿没被抓到 —— 色相族判据失灵")

        let twoReds = Self.duplicatedPositiveFamilies([
            (name: "danger", light: token(0xFF3B30), dark: token(0xFF453A)),
            (name: "critical", light: token(0xB3261E), dark: token(0xFF6961)),
        ])
        XCTAssertTrue(twoReds.isEmpty, "两支红被误判成撞族：\(twoReds)")

        let greenAndAmber = Self.duplicatedPositiveFamilies([
            (name: "success", light: token(0x2CA94C), dark: token(0x30D158)),
            (name: "warning", light: token(0xD18208), dark: token(0xFF9F0A)),
        ])
        XCTAssertTrue(greenAndAmber.isEmpty, "绿+橙两个族被误判：\(greenAndAmber)")

        // 族的边界本身也要钉住：171° 与 124° 同族、190° 属青、30° 属橙。
        XCTAssertEqual(Self.hueFamily(of: token(0x2AA694)), "绿")
        XCTAssertEqual(Self.hueFamily(of: token(0x2CA94C)), "绿")
        XCTAssertEqual(Self.hueFamily(of: token(0x0A84FF)), "蓝")
        XCTAssertEqual(Self.hueFamily(of: token(0xD18208)), "橙")
        XCTAssertEqual(Self.hueFamily(of: token(0x8E8E93)), "无彩色")
    }

}
