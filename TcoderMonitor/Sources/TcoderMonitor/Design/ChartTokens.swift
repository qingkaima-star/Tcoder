import SwiftUI

// MARK: - 图表：全 App 唯一一套色板 + 序列登记 + 轴与容器
//
// 为什么色板要收成"只能按号取"：WS-H 定则要全仓只有一套图表调色板，
// 而《45》§2.1 实测到两套散色 + 一个**功能缺陷**——`LanguageBar` 用
// `language.hashValue % count` 取色，Swift 的 `hashValue` 每进程随机播种，
// **同一门语言每次启动换一个颜色**。页面自己补了 FNV-1a，于是又变成两处各一份。
// 现在取号与稳定哈希都在这一处，页面拿不到裸色值（`palette` 已收 private）。
//
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

        /// 按稳定键取色值本体。Swift Charts 的 `foregroundStyle(by:)` 这类场合要的是
        /// `Color`/十六进制而不是索引，用它拿——页面因此不必绕过号位自己凑色。
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

        // MARK: 序列号位登记

        /// 每条序列占一个号位。**新增图表必须在这里登记**，不在页面里挑颜色——
        /// 否则"同一指标在不同页不同色"会重新长出来（《45》§2.1 的根因）。
        /// 号位间隔留了空档，是为了让语义相近的序列落在色板同区段。
        enum Series {
            static let cpu = 0            // 蓝 · 主/自身数据
            static let memory = 2         // 橙 · 关注
            static let disk = 4           // 紫 · 分类 A
            static let network = 6        // 青 · 分类 C
            static let healthTrend = 0    // 蓝 · 与 CPU 同为"自身主数据"，不同屏不冲突
            static let commitActivity = 1 // 绿 · 正向
            static let duplication = 3    // 红 · 风险
            static let coverage = 5       // 粉

            /// 全部已登记号位，供单测校验没有越界与语义撞车。
            static let allRegistered: [(name: String, index: Int)] = [
                ("cpu", cpu), ("memory", memory), ("disk", disk), ("network", network),
                ("healthTrend", healthTrend), ("commitActivity", commitActivity),
                ("duplication", duplication), ("coverage", coverage),
            ]
        }

        // MARK: 轴

        /// 一条纵轴。`minValue != 0` 就是**收窄过的轴**——它会放大波动观感，
        /// 所以 `isZoomed` 必须被容器显式标注出来，不能悄悄用收窄轴吓人。
        struct Axis: Equatable {
            let minValue: Double
            let step: Double
            let maxValue: Double

            init(minValue: Double = 0, step: Double, maxValue: Double) {
                self.minValue = minValue
                self.step = step
                self.maxValue = maxValue
            }

            var isZoomed: Bool { minValue > 0 }

            var ticks: [Double] {
                guard step > 0 else { return [minValue] }
                var out: [Double] = []
                var value = minValue
                while value <= maxValue + 1e-9 {
                    out.append(value)
                    value += step
                }
                return out
            }

            /// Swift Charts 的 y 值域。
            var domain: ClosedRange<Double> { minValue...maxValue }
        }

        enum Scale {
            /// 峰值上方留 20% 呼吸，曲线不顶格。
            static let headroom = 1.2
            static let desiredTickCount = 4
            static let percentMax = 100.0
            static let percentTicks: [Double] = [0, 25, 50, 75, 100]

            /// 百分比轴（CPU、覆盖率、重复率）。
            static let percent = Axis(step: 25, maxValue: percentMax)
        }

        /// 带轴标注的曲线容器：外层内容卡 + 左侧刻度列 + 「轴已收窄」显式提示。
        ///
        /// 轴标签一律 10pt 等宽（全仓文字下限），数字右对齐——
        /// 这样刻度列不会因为 100/25 位数不同而左右跳。
        struct Panel<Content: View>: View {
            var title: String?
            var axis: Axis
            var seriesIndex: Int
            var height: CGFloat
            /// 轴标签的格式化，默认取整数。
            var labelFor: (Double) -> String
            @ViewBuilder var content: Content

            init(
                title: String? = nil,
                axis: Axis,
                seriesIndex: Int = 0,
                height: CGFloat = Theme.Layout.chartMinHeight,
                labelFor: @escaping (Double) -> String = { String(Int($0.rounded())) },
                @ViewBuilder content: () -> Content
            ) {
                self.title = title
                self.axis = axis
                self.seriesIndex = seriesIndex
                self.height = height
                self.labelFor = labelFor
                self.content = content()
            }

            var body: some View {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    if let title {
                        HStack(spacing: Theme.Spacing.xs) {
                            Text(title).font(Theme.Typo.cardTitle.font)
                            Spacer(minLength: Theme.Spacing.xs)
                            if axis.isZoomed {
                                // 收窄轴必须写明：不写就是拿轴范围制造恐慌
                                Theme.Notice.inline("纵轴已从 \(labelFor(axis.minValue)) 起",
                                                     role: Theme.Semantic.info)
                            }
                        }
                    }
                    HStack(alignment: .top, spacing: Theme.Spacing.xxs) {
                        VStack(spacing: 0) {
                            ForEach(Array(axis.ticks.reversed().enumerated()), id: \.offset) { _, tick in
                                Text(labelFor(tick))
                                    .font(Theme.Typo.monoLabel.font)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                        .frame(width: Theme.Layout.axisLabelWidth)
                        .frame(maxHeight: .infinity)
                        content
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(height: height)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
