import SwiftUI

// MARK: - 图表：全 App 唯一一套色板 + 稳定取号
//
// 为什么色板要收成"只能按号取"：WS-H 定则要全仓只有一套图表调色板，
// 而《45》§2.1 实测到两套散色 + 一个**功能缺陷**——`LanguageBar` 用
// `language.hashValue % count` 取色，Swift 的 `hashValue` 每进程随机播种，
// **同一门语言每次启动换一个颜色**。页面自己补了 FNV-1a，于是又变成两处各一份。
// 现在取号与稳定哈希都在这一处，页面拿不到裸色值（`palette` 已收 private）。
//
// 只留**有调用方**的东西：`Series` 号位表、`Axis`/`Scale`/`Panel` 已在 #28 里删掉——
// WS-M 的 `ChartSeries`/`ChartAxis`/`ChartScale` 是活的且是超集，页面容器事实标准是
// `GlassSection` + 真 `AxisMarks`，我那份手搓标签的 Panel 属降级实现。
// 增强对比（increase contrast）第三套仍缺：需要 Asset Catalog，
// 而 `Package.swift` 未声明 `resources:` 且不归我所有 → 契约缺口，见笔记 66。

extension Theme {
    enum Chart {
        /// 唯一色值来源。`private` 是刻意的：任何新入口都必须经过 `pair(at:)` 的
        /// 越界回绕，页面拿不到数组，也就没法"顺手挑一个颜色"。
        private static let palette: [ColorTokenPair] = [
            ColorTokenPair(light: ColorToken(hex: 0x0A82FF), dark: ColorToken(hex: 0x0A84FF)), // 主 / 自身数据
            ColorTokenPair(light: ColorToken(hex: 0x34C759), dark: ColorToken(hex: 0x30D158)), // 正向
            ColorTokenPair(light: ColorToken(hex: 0xFF9F0A), dark: ColorToken(hex: 0xFFD60A)), // 关注
            ColorTokenPair(light: ColorToken(hex: 0xFF3B30), dark: ColorToken(hex: 0xFF453A)), // 风险
            ColorTokenPair(light: ColorToken(hex: 0xAF52DE), dark: ColorToken(hex: 0xBF5AF2)), // 分类 A
            ColorTokenPair(light: ColorToken(hex: 0xFF2D55), dark: ColorToken(hex: 0xFF375F)), // 分类 B
            ColorTokenPair(light: ColorToken(hex: 0x64D2FF), dark: ColorToken(hex: 0x64D2FF)), // 分类 C
            ColorTokenPair(light: ColorToken(hex: 0xA2845E), dark: ColorToken(hex: 0xAC8E68)), // 分类 D
        ]

        static var count: Int { palette.count }

        static func pair(at index: Int) -> ColorTokenPair {
            // Swift 的 % 对负数返回负值，直接下标会 panic；这里显式归一。
            let wrapped = ((index % palette.count) + palette.count) % palette.count
            return palette[wrapped]
        }

        /// 取序列色（自动回绕，跟随深浅外观）。
        static func color(at index: Int) -> Color {
            pair(at: index).color
        }

        /// 稳定取号：FNV-1a 64 位。**不要再用 `hashValue`**——它每进程随机播种。
        /// `lowercased()` 让 `Swift` 与 `swift` 落到同一号位。
        static func index(forLabel label: String) -> Int {
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for scalar in label.lowercased().unicodeScalars {
                hash ^= UInt64(scalar.value)
                hash = hash &* 0x0000_0100_0000_01B3
            }
            return Int(hash % UInt64(max(1, palette.count)))
        }

        /// 按稳定键取分类色（语言、作者、生态……同一键跨启动永远同色）。
        static func color(forLabel label: String) -> Color {
            color(at: index(forLabel: label))
        }

        /// 按稳定键取色值本体（Swift Charts 的 `foregroundStyle(by:)` 这类场合要的是
        /// `Color`/十六进制而不是索引，用它拿，页面不必绕过号位凑色）。
        /// **有外部消费者**：`ShellDesignTests` 用它断言"按键取色"与"按号取色"两条路径
        /// 必须同色——#28 曾把它当零引用删掉，结果把 WS-K 的测试编译弄红。别再删。
        static func token(forLabel label: String,
                          in appearance: DesignAppearance = .light) -> ColorToken {
            pair(at: index(forLabel: label)).token(in: appearance)
        }

        /// 面积渐变顶到底的强度档。`specTop` 是 WS-H §5.4 的定档（0.30→0.02）；
        /// `soft` 是 WS-M 在实时密集曲线上实测的观感档（0.16→0.02）——
        /// 他们当时只能在页面里自造常量，这里收成一档可选强度，
        /// 是否把默认从 `specTop` 改到 `soft` 交总工定夺。
        enum Intensity: Hashable {
            case specTop
            case soft

            var topOpacity: Double {
                switch self {
                case .specTop: return Theme.Palette.Opacity.gradientTop
                case .soft: return Theme.Palette.Opacity.gradientAreaSoft
                }
            }
        }

        /// 曲线面积渐变：顶到底同色，强度按档。
        static func areaGradient(at index: Int, intensity: Intensity = .specTop) -> LinearGradient {
            let color = self.color(at: index)
            return LinearGradient(
                stops: [
                    .init(color: color.opacity(intensity.topOpacity), location: 0),
                    .init(color: color.opacity(Theme.Palette.Opacity.gradientFloor), location: 1),
                ],
                startPoint: .top, endPoint: .bottom)
        }
    }
}
