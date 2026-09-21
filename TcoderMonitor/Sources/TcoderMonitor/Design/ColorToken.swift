import AppKit
import SwiftUI

// MARK: - 令牌构造计数器（诊断，不是公开 API）

/// 令牌对象**被构造出来**的次数。
///
/// 为什么要有这个东西：C 包的验收指标是"每 tick 命中缓存的比例"，而"命中"必须数得出来。
/// 只扫源码形状（计算属性体内不许出现构造式）有一种盲区 —— 把 `NSColor(name:)` 挪进一个
/// 私有 `static func`、然后让计算属性逐次调用它，形状守卫就看不见每次访问现造了。
/// 计数器直接落在**构造点本身**，那种写法照样会被数出来。
///
/// 为什么不是 `@MainActor`（备案，与派单口径的偏离）：构造点在 `TypeToken.init` /
/// `DualColor.init` 这些**非隔离**的位置 —— 令牌是跨线程可读的值类型，AppKit 解析
/// 动态色也可能发生在后台线程。把计数器标 `@MainActor` 会让这些 init 直接编译不过，
/// 而把令牌类型整体标 `@MainActor` 会外溢成页面层的隔离冲突。
/// 这里改用 `NSLock` 守：计数丢一次就是"命中数没数出来"的假绿，比慢更贵。
enum DesignTokenMeter {
    enum Channel: String, CaseIterable, Hashable {
        /// `DualColor` / `ColorTokenPair` 的那个动态色包装对象
        case dynamicColor
        /// `ColorToken` 的 `Color` + `NSColor`
        case sRGBColor
        /// `TypeToken` 的 `Font`
        case font
        /// `Theme.Chart` 的 `LinearGradient`
        case gradient
    }

    private static let lock = NSLock()
    private static var counts: [Channel: Int] = [:]

    static func record(_ channel: Channel) {
        lock.lock()
        counts[channel, default: 0] += 1
        lock.unlock()
    }

    static func count(_ channel: Channel) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[channel] ?? 0
    }
}

/// 设计系统的颜色计量单位：0...1 的 sRGB 分量 + WCAG 数学。
///
/// 令牌层（`Sources/TcoderMonitor/Design/**`）是全仓唯一允许出现十六进制字面量的地方。
/// 页面只能通过 `Theme.Semantic.*` / `Theme.Palette.*` 这类语义名取色。
/// 把分量存成数值而不是 `Color`，是为了让单测能脱离屏幕渲染算出对比度。
///
/// ⚠️ **性能红线（2026-09-20 性能 spec §5 的 C 包）**：本文件三个 `color` 口子
/// （`ColorToken` / `DualColor` / `ColorTokenPair`）**一律是存储属性，不是计算属性**。
/// 改前每次访问都 new 一个 `NSColor(name: nil) {}` 再包一层 `Color(nsColor:)`，
/// 而取色点大量落在 `ForEach` / 图表 Mark 闭包里 —— 实测每 tick 约 500 个动态色对象，
/// 直接把 app-update 相位撑到 10.8~24.8ms（预算 8.33ms）。
/// **缓存的是那个包装对象本身**：动态 `NSColor` 的语义是"渲染时刻按当前 appearance 求值"，
/// 所以同一个包装对象在深色下仍然解析出深色值（已由 `DesignTokenCacheGuardTests` 的
/// 行为守卫在无 GUI 单测环境里实测证明）。缓存"解析出来的固定 RGB 值"才是错的，
/// 那等于把深色模式钉死。同一条结论由形状守卫钉住：`Design/**` 的计算属性体内
/// 不得再出现 `NSColor(name:` / `LinearGradient(` / `Font.system(`。
struct ColorToken: Hashable {
    let red: Double
    let green: Double
    let blue: Double

    init(r: Double, g: Double, b: Double) {
        self.red = r
        self.green = g
        self.blue = b
        self.color = Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
        self.nsColor = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        DesignTokenMeter.record(.sRGBColor)
    }

    /// `0xB3261E` 形式的六位数。
    init(hex: UInt32) {
        self.init(
            r: Double((hex >> 16) & 0xFF) / 255,
            g: Double((hex >> 8) & 0xFF) / 255,
            b: Double(hex & 0xFF) / 255
        )
    }

    /// 构造一次即复用的 `Color`。**不是**计算属性，理由见类型头注释。
    let color: Color

    /// 同上，收的是 `NSColor` 那一层：动态包装器每次被解析都会回到 `DualColor` 的闭包里
    /// 取一个分量色，这里让它取的是**同一个实例**（`NSColor` 不可变，共享安全），
    /// 于是"解析一次 = new 一个 NSColor"也一并归零。
    let nsColor: NSColor

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

    // MARK: 身份判定（刻意不含 `color` / `nsColor`）

    /// `color` 与 `nsColor` 是**缓存的派生量**，不参与身份：显式写出来，等于把
    /// "`Hashable` 合成结果不因新增存储属性而改变"这句话钉在代码里，而不是留给编译器
    /// 合成去漂移。
    static func == (lhs: ColorToken, rhs: ColorToken) -> Bool {
        lhs.red == rhs.red && lhs.green == rhs.green && lhs.blue == rhs.blue
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(red)
        hasher.combine(green)
        hasher.combine(blue)
    }
}

/// 浅深两套取值。文字类语义色必须成对声明：单一色值不可能同时在 `#FFFFFF` 和 `#1E1E1E`
/// 两种表面上达到 4.5:1（见 `DesignTokenTests`）。
struct DualColor: Hashable {
    let light: ColorToken
    let dark: ColorToken

    /// 跟随系统外观自动切换的 `Color`：**构造一次，全站复用**（理由见 `ColorToken` 类型头注释）。
    let color: Color

    init(lightHex: UInt32, darkHex: UInt32) {
        self.init(light: ColorToken(hex: lightHex), dark: ColorToken(hex: darkHex))
    }

    init(light: ColorToken, dark: ColorToken) {
        self.light = light
        self.dark = dark
        self.color = Color(nsColor: Self.makeDynamicNSColor(light: light, dark: dark))
        DesignTokenMeter.record(.dynamicColor)
    }

    func token(in appearance: DesignAppearance) -> ColorToken {
        switch appearance {
        case .light: return light
        case .dark: return dark
        }
    }

    /// 动态 `NSColor` 包装器的唯一构造点。
    ///
    /// 它是**函数而不是计算属性**，这是有意的：计算属性体 = 每次访问现造，
    /// 正是本轮 C 包要消灭的写法（`DesignTokenCacheGuardTests` 的形状守卫按体判，
    /// `DesignTokenMeter` 的命中数守卫按构造点判 —— 两把尺子不共享同一个盲区）。
    /// 闭包本身**必须留在 `NSColor(name: nil) {}` 里**：它表达的是"渲染时按当次
    /// appearance 在 light/dark 两套令牌之间选一套"，缓存它不等于缓存某个 RGB 值。
    ///
    /// 计数落在 `DualColor.init`（一个包装对象 = 一次），不在这里：这里若被逐次调用，
    /// `init` 也就在被逐次调用，同一口径。
    static func makeDynamicNSColor(light: ColorToken, dark: ColorToken) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return (isDark ? dark : light).nsColor
        }
    }

    /// 身份只看两套令牌，与改前的合成结果逐字相同（`color` 是派生缓存）。
    static func == (lhs: DualColor, rhs: DualColor) -> Bool {
        lhs.light == rhs.light && lhs.dark == rhs.dark
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(light)
        hasher.combine(dark)
    }
}

/// 一对（浅色模式, 深色模式）的裸值组合，不包 `Color`，供图表色板按索引取用与断言。
struct ColorTokenPair: Hashable {
    let light: ColorToken
    let dark: ColorToken

    /// 动态 `Color`，与 `DualColor.color` 同一套包装器（复用其构造点，不重复实现闭包）。
    let color: Color

    init(light: ColorToken, dark: ColorToken) {
        self.light = light
        self.dark = dark
        self.color = DualColor(light: light, dark: dark).color
    }

    init(lightHex: UInt32, darkHex: UInt32) {
        self.init(light: ColorToken(hex: lightHex), dark: ColorToken(hex: darkHex))
    }

    func token(in appearance: DesignAppearance) -> ColorToken {
        switch appearance {
        case .light: return light
        case .dark: return dark
        }
    }

    /// 同上：身份只看两套令牌，与改前的合成结果逐字相同。
    static func == (lhs: ColorTokenPair, rhs: ColorTokenPair) -> Bool {
        lhs.light == rhs.light && lhs.dark == rhs.dark
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(light)
        hasher.combine(dark)
    }
}

enum DesignAppearance: CaseIterable, Hashable {
    case light
    case dark

    /// 对比度 harness 的参考背景。**批次 P6 起取"两层里更差的那一面"**。
    ///
    /// 原来它钉的是 `NSColor.controlBackgroundColor`（aqua `#FFFFFF` / darkAqua `#1E1E1E`），
    /// 那是"地面纯白"时代的正确参考。新语言是**灰画布 + 白卡**，同一支墨可能落在
    /// 两个面上：浅色下 `#F7F7F7` 比白底更暗 ⇒ 深字对比更低；
    /// 深色下卡面 `#1C1E22` 比画布 `#0E0E10` 更亮 ⇒ 浅字对比更低。
    /// 取各自更差的一面，"过线"才意味着**落在哪一层都过线**。
    ///
    /// ⚠ 这是**加严**，不是为了让谁通过：改完之后如果有角色掉线，正解是把它调深/调亮，
    ///   不是把这行改回去（本仓红线：阈值不许为了刷分而动）。
    var referenceSurface: ColorToken {
        switch self {
        case .light: return ColorToken(hex: 0xF7F7F7)   // = Palette.Surface.ground
        case .dark: return ColorToken(hex: 0x1C1E22)    // = Palette.Surface.card
        }
    }
}
