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

        /// 越界回绕。`pair(at:)` 与渐变表共用这一个口径，
        /// 免得哪天两边各算各的、同一号位对上不同颜色。
        private static func wrapped(_ index: Int) -> Int {
            // Swift 的 % 对负数返回负值，直接下标会 panic；这里显式归一。
            ((index % palette.count) + palette.count) % palette.count
        }

        static func pair(at index: Int) -> ColorTokenPair {
            palette[wrapped(index)]
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
        ///
        /// 本轮加 `CaseIterable` 只为让下面的渐变表**按 allCases 生成**，
        /// 于是"新增一档"必然自动进表，不需要谁记得去补一行。
        enum Intensity: Hashable, CaseIterable {
            case specTop
            case soft

            var topOpacity: Double {
                switch self {
                case .specTop: return Theme.Palette.Opacity.gradientTop
                case .soft: return Theme.Palette.Opacity.gradientAreaSoft
                }
            }
        }

        /// 渐变构造点。**写成函数而不是计算属性**：`LinearGradient(...)` 落在计算属性体里
        /// 就是"每次访问现造"，正是 `DesignTokenCacheGuardTests` 形状守卫判红的写法。
        private static func makeAreaGradient(at index: Int, intensity: Intensity) -> LinearGradient {
            let color = self.color(at: index)
            DesignTokenMeter.record(.gradient)
            return LinearGradient(
                stops: [
                    .init(color: color.opacity(intensity.topOpacity), location: 0),
                    .init(color: color.opacity(Theme.Palette.Opacity.gradientFloor), location: 1),
                ],
                startPoint: .top, endPoint: .bottom)
        }

        /// 按 `(强度档, 号位)` 预计算的渐变表，`static let` 保证只算一次且并发读安全。
        ///
        /// 表的完整性是**构造出来的**：外层键取 `Intensity.allCases`（新增一档自动进表），
        /// 内层长度取 `palette.count`（越界回绕与 `pair(at:)` 同一个 `wrapped(_:)`），
        /// 所以 `areaGradient(at:intensity:)` 的查表永不落空。
        private static let areaGradientTable: [Intensity: [LinearGradient]] = Dictionary(
            uniqueKeysWithValues: Intensity.allCases.map { intensity in
                (intensity, (0..<palette.count).map { makeAreaGradient(at: $0, intensity: intensity) })
            })

        /// 曲线面积渐变：顶到底同色，强度按档。
        ///
        /// **查表，不现造**（性能 spec §5 的 C 包）。本函数被图表 Mark 的
        /// `.foregroundStyle(ChartSeries.gradient(series))` 逐点调用：改前每个点都 new 一个
        /// `LinearGradient`（内含 `Gradient` 与两个 `GradientStop`），实时曲线 90 点 ×
        /// 两条序列 × 每 1.5 s 一次 publish = 每 tick 上百个渐变对象。
        /// 缓存的是不可变的 `LinearGradient` 值本身，而它两个 stop 上的 `Color` 是**动态**
        /// 包装器（见 `ColorToken` 类型头注释），所以深浅外观切换照旧在渲染时刻生效。
        static func areaGradient(at index: Int, intensity: Intensity = .specTop) -> LinearGradient {
            guard let row = areaGradientTable[intensity] else {
                // 不可达：表按 allCases 生成，覆盖所有档位。留这条兜底是为了
                // 宁可现算也不 force-unwrap（真出现了就是上面那句"覆盖所有档位"被打破）。
                return makeAreaGradient(at: index, intensity: intensity)
            }
            return row[wrapped(index)]
        }
    }
}
