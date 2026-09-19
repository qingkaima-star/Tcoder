import AppKit
import SwiftUI

/// 设计系统的颜色计量单位：0...1 的 sRGB 分量 + WCAG 数学。
///
/// 令牌层（`Sources/TcoderMonitor/Design/**`）是全仓唯一允许出现十六进制字面量的地方。
/// 页面只能通过 `Theme.Semantic.*` / `Theme.Palette.*` 这类语义名取色。
/// 把分量存成数值而不是 `Color`，是为了让单测能脱离屏幕渲染算出对比度。
struct ColorToken: Hashable {
    let red: Double
    let green: Double
    let blue: Double

    init(r: Double, g: Double, b: Double) {
        self.red = r
        self.green = g
        self.blue = b
    }

    /// `0xB3261E` 形式的六位数。
    init(hex: UInt32) {
        self.init(
            r: Double((hex >> 16) & 0xFF) / 255,
            g: Double((hex >> 8) & 0xFF) / 255,
            b: Double(hex & 0xFF) / 255
        )
    }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }

    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }

    /// 相对亮度（WCAG 2.x 定义）。
    var relativeLuminance: Double {
        func linearize(_ channel: Double) -> Double {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(red) + 0.7152 * linearize(green) + 0.0722 * linearize(blue)
    }

    /// WCAG 对比度，1.0...21.0。
    func contrastRatio(with other: ColorToken) -> Double {
        let lighter = max(relativeLuminance, other.relativeLuminance)
        let darker = min(relativeLuminance, other.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// 以 `alpha` 叠加到 `background` 上的结果色，用于算 badge 底色这类半透明合成。
    func composited(over background: ColorToken, alpha: Double) -> ColorToken {
        ColorToken(
            r: red * alpha + background.red * (1 - alpha),
            g: green * alpha + background.green * (1 - alpha),
            b: blue * alpha + background.blue * (1 - alpha)
        )
    }

    var sRGBHex: String {
        func byte(_ channel: Double) -> String {
            String(format: "%02X", Int((channel * 255).rounded()))
        }
        return byte(red) + byte(green) + byte(blue)
    }
}

/// 浅深两套取值。文字类语义色必须成对声明：单一色值不可能同时在 `#FFFFFF` 和 `#1E1E1E`
/// 两种表面上达到 4.5:1（见 `DesignTokenTests`）。
struct DualColor: Hashable {
    let light: ColorToken
    let dark: ColorToken

    init(lightHex: UInt32, darkHex: UInt32) {
        self.light = ColorToken(hex: lightHex)
        self.dark = ColorToken(hex: darkHex)
    }

    func token(in appearance: DesignAppearance) -> ColorToken {
        switch appearance {
        case .light: return light
        case .dark: return dark
        }
    }

    /// 跟随系统外观自动切换的 `Color`。
    var color: Color { Color(nsColor: dynamicNSColor) }

    private var dynamicNSColor: NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return (isDark ? dark : light).nsColor
        }
    }
}

/// 一对（浅色模式, 深色模式）的裸值组合，不包 `Color`，供图表色板按索引取用与断言。
struct ColorTokenPair: Hashable {
    let light: ColorToken
    let dark: ColorToken

    init(light: ColorToken, dark: ColorToken) {
        self.light = light
        self.dark = dark
    }

    init(lightHex: UInt32, darkHex: UInt32) {
        self.light = ColorToken(hex: lightHex)
        self.dark = ColorToken(hex: darkHex)
    }

    func token(in appearance: DesignAppearance) -> ColorToken {
        switch appearance {
        case .light: return light
        case .dark: return dark
        }
    }

    var color: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return (isDark ? dark : light).nsColor
        })
    }
}

enum DesignAppearance: CaseIterable, Hashable {
    case light
    case dark

    var referenceSurface: ColorToken {
        switch self {
        // 实测值：NSColor.controlBackgroundColor 在 aqua = #FFFFFF、darkAqua = #1E1E1E
        // （用编译产物 resolve 两个 NSAppearance 得到，见笔记 42）
        case .light: return ColorToken(hex: 0xFFFFFF)
        case .dark: return ColorToken(hex: 0x1E1E1E)
        }
    }
}
