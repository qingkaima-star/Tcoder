import Foundation
import XCTest
@testable import TcoderMonitor

// MARK: - 图表色板只许「一系蓝 + 中性灰」
//
// 权威 = `docs/界面语言-对齐AiX.md` §3/§6。批次 P6 把 `Theme.Chart.palette`
// 从八支色相（蓝绿黄红紫粉青棕）改成同色相明度分档 + 中性灰收尾。
//
// 依据是参考图的像素普查（2 倍图，只统计有饱和度的像素）：蓝约 **11,500** 个，
// 而绿 184 / 黄 135 / 红 129 —— 那三个是**状态小圆点**，不是图表色；
// 环图里未被强调的那一块是灰。所以"图表可以有五种颜色"在参考图里根本不成立，
// 成立的是"一系蓝 + 其余压灰"。

extension DesignTokenTests {

    /// WCAG 相对亮度。`ColorToken.red/green/blue` 是 0...1 的线性分量，
    /// 这里自己算，避免为了一个测试数去给产品类型加只服务测试的 API。
    static func wcagLuminance(_ token: ColorToken) -> Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(token.red) + 0.7152 * lin(token.green) + 0.0722 * lin(token.blue)
    }

    /// 色板里出现的**有彩色族**（"无彩色"不计：灰收尾那几档本来就该是灰）。
    static func chartChromaticFamilies(in appearance: DesignAppearance) -> [String] {
        (0..<Theme.Chart.count).compactMap { index in
            let family = hueFamily(of: Theme.Chart.pair(at: index).token(in: appearance))
            return family == "无彩色" ? nil : family
        }
    }

    /// 相邻号位的亮度差。分档靠明度，那明度就必须真的拉得开 ——
    /// 否则"一系蓝"会退成"一坨蓝"，多序列图反而更难读（这条改动的反面教材）。
    static func adjacentLuminanceGaps(in appearance: DesignAppearance,
                                      slots: Range<Int>) -> [Double] {
        let lums = slots.map { wcagLuminance(Theme.Chart.pair(at: $0).token(in: appearance)) }
        return zip(lums, lums.dropFirst()).map { abs($0.0 - $0.1) }
    }

    func test_chartPaletteIsOneHueFamilyInBothAppearances() {
        for appearance in [DesignAppearance.light, .dark] {
            let families = Set(Self.chartChromaticFamilies(in: appearance))
            XCTAssertEqual(families, ["蓝"],
                           "\(appearance) 图表色板出现第二支色相：\(families)。"
                         + "参考图普查证明它只有一系蓝 + 灰；引入紫/棕/粉就是把「没有主次」请回来。")
        }
    }

    /// 前五个号位是"多序列靠明度分档"的那一系蓝，相邻号位必须看得出差别。
    func test_chartBlueRampIsDistinguishable() {
        for appearance in [DesignAppearance.light, .dark] {
            let gaps = Self.adjacentLuminanceGaps(in: appearance, slots: 0..<5)
            let tooClose = gaps.filter { $0 < 0.05 }
            XCTAssertTrue(tooClose.isEmpty,
                          "\(appearance) 蓝档里有相邻两档亮度差 <0.05"
                        + "（实测 \(gaps.map { String(format: "%.3f", $0) })）——"
                        + "同色相分档的前提是拉得开，否则多序列图从「五颜六色」退化成「一团蓝」。")
        }
    }

    /// 反向元测试：判据不许空转，也不许把收尾的灰当成"只有一个色相"的功劳。
    func test_chartHueRulerIsNotAFalseGreen() {
        let families = Self.chartChromaticFamilies(in: .light)
        XCTAssertFalse(families.isEmpty, "一条都没分类出来 = 判据在空转（全灰也会被放过）")
        XCTAssertTrue(families.allSatisfy { $0 == "蓝" }, "真色板自己先不过关：\(families)")

        // 收尾三档必须确实落在"无彩色"，否则上面那条"只许一支"是假绿。
        let neutrals = (5..<Theme.Chart.count).map {
            Self.hueFamily(of: Theme.Chart.pair(at: $0).token(in: .light))
        }
        XCTAssertEqual(Set(neutrals), ["无彩色"],
                       "收尾档不是无彩色，那「一系蓝」的判据就漏了它们：\(neutrals)")

        // 亮度尺子的两向：同一支色相但明度相同 → 必须报 0 差；
        // 黑白两档 → 必须报接近 1。尺子坏了的话上面那条分档断言就是摆设。
        XCTAssertEqual(Self.adjacentLuminanceGaps(in: .light, slots: 0..<1), [],
                       "只有一个号位时应无相邻差")
        let blackWhite = [ColorToken(hex: 0x000000), ColorToken(hex: 0xFFFFFF)]
        let gap = abs(Self.wcagLuminance(blackWhite[0]) - Self.wcagLuminance(blackWhite[1]))
        XCTAssertGreaterThan(gap, 0.99, "相对亮度算错了，分档判据不可信")
    }
}
