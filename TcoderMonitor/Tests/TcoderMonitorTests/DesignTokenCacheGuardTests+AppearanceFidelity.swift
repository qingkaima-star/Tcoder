/// OWNER: WS-X3 TestSplit —— 自 DesignTokenCacheGuardTests.swift 拆出，缓存化之后外观与调用形状一字不变（明暗两界各自解析）。用例本体未改，只是搬了家。
import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import TcoderMonitor

extension DesignTokenCacheGuardTests {

    /// 双层令牌在两套外观下各自解析出**自己那一套**值。
    /// 这就是"缓存的是包装对象、不是 RGB"的直接证据；写反了（缓存解析结果）这条必红。
    func test_cachedColorsStillResolveToTheirOwnAppearance() {
        // Surface.ink：浅 #0A0A0A / 深 #F2F2F5（无界 spec §2.1 的两个新地面令牌）
        XCTAssertEqual(Self.resolveHex(Theme.Palette.Surface.ink, under: .aqua), "0A0A0A")
        XCTAssertEqual(Self.resolveHex(Theme.Palette.Surface.ink, under: .darkAqua), "F2F2F5")
        // 语义色文字层（双层色的存在理由就是浅深各自达标）
        XCTAssertEqual(Self.resolveHex(Theme.Semantic.danger.textColor, under: .aqua), "C2251C")
        XCTAssertEqual(Self.resolveHex(Theme.Semantic.danger.textColor, under: .darkAqua), "FF6B63")
        XCTAssertEqual(Self.resolveHex(Theme.Semantic.success.textColor, under: .aqua), "157A32")
        XCTAssertEqual(Self.resolveHex(Theme.Semantic.success.textColor, under: .darkAqua), "5BE28A")
        // critical 是唯一 onFill 随外观翻转的角色
        XCTAssertEqual(Self.resolveHex(Theme.Semantic.critical.onFillColor, under: .aqua), "FFFFFF")
        XCTAssertEqual(Self.resolveHex(Theme.Semantic.critical.onFillColor, under: .darkAqua), "111111")
        // 图表色板按号位取色
        XCTAssertEqual(Self.resolveHex(Theme.Chart.color(at: 0), under: .aqua), "0A82FF")
        XCTAssertEqual(Self.resolveHex(Theme.Chart.color(at: 0), under: .darkAqua), "0A84FF")
        // 越界回绕后仍是同一枚动态色
        XCTAssertEqual(Self.resolveHex(Theme.Chart.color(at: 8), under: .darkAqua), "0A84FF")
    }

    /// 上面那条的**对照组**（行为守卫自己的元测试）：
    /// 刻意钉死成固定 RGB 的颜色，两套外观必须解析成同一个值。
    /// 若本机 `performAsCurrentDrawingAppearance` 对动态色根本不生效，那么"深浅不同"这条会红，
    /// 而不是悄悄变绿；若它对固定色也"深浅不同"，这条会红 —— 两把方向相反的锁。
    func test_resolutionHelperDistinguishesDynamicFromPinnedColors() {
        let pinned = Color(.sRGB, red: 10.0 / 255.0, green: 10.0 / 255.0, blue: 10.0 / 255.0, opacity: 1)
        let light = Self.resolveHex(pinned, under: .aqua)
        let dark = Self.resolveHex(pinned, under: .darkAqua)
        XCTAssertEqual(light, "0A0A0A", "解析器连固定色都读不出来：环境不支持，别信上面的行为守卫")
        XCTAssertEqual(light, dark, "固定色在两套外观下解析出了不同值 —— 解析器不可信")
        XCTAssertNotEqual(Self.resolveHex(Theme.Palette.Surface.ink, under: .aqua),
                          Self.resolveHex(Theme.Palette.Surface.ink, under: .darkAqua),
                          "动态色在两套外观下解析成了同一个值 = 深色模式已被钉死")
    }

    /// 缓存生效的直接证据：同一个角色的两次取色必须是**同一个包装对象**。
    /// 探针结论：两个独立 `NSColor(name: nil){}` 实例包出来的 `Color` **不**相等，
    /// 同一个实例包出来的才相等 —— 所以这条断言改前必红、改后必绿。
    func test_repeatedTokenAccessHandsBackTheSameColorWrapper() {
        XCTAssertEqual(Theme.Semantic.success.textColor, Theme.Semantic.success.textColor,
                       "两次取色不相等 = 每次访问又在现造动态色包装器")
        XCTAssertEqual(Theme.Semantic.danger.graphicColor, Theme.Semantic.danger.graphicColor,
                       "两次取色不相等 = 每次访问又在现造动态色包装器")
        XCTAssertEqual(Theme.Chart.color(at: 2), Theme.Chart.color(at: 2),
                       "图表号位色每次访问又 new 了一个包装器")
        XCTAssertEqual(Theme.Palette.Surface.ground, Theme.Palette.Surface.ground)
    }

    /// 渐变缓存里装的 stop 色**仍然是动态**的（不是被解析后钉死的 RGB）。
    /// 这条正面回击本次改造最容易犯的错：把动态色 resolve 成固定值再缓存。
    func test_areaGradientStopsAreStillAppearanceResolvingNotBaked() {
        let reflected = String(reflecting: Theme.Chart.areaGradient(at: 0))
        XCTAssertTrue(reflected.contains("AppKitPlatformColorProvider"),
                      "渐变 stop 上的色已被解析成固定 RGB 并缓存 —— 深色模式会被钉死：\(reflected.prefix(200))")
        // 对照组：固定 RGB 造的渐变不得含这个标记，否则上面那条就是永真绿
        let baked = LinearGradient(stops: [
            .init(color: Color(.sRGB, red: 0.04, green: 0.04, blue: 0.04, opacity: 1), location: 0),
        ], startPoint: .top, endPoint: .bottom)
        XCTAssertFalse(String(reflecting: baked).contains("AppKitPlatformColorProvider"),
                       "对照组失灵：固定色也带 AppKitPlatformColorProvider，那条断言证明不了任何事")
    }

    /// 编译期即成立的契约：这三类令牌的**名字、类型、参数标签**没变。
    /// 任何一处被改名或改形状，这个函数就编译不过 —— 比读 diff 可靠。
    /// 顺带核一遍缓存出来的 `Font` 与规范构造式**同值**（缓存不能把值顺手改掉）。
    func test_tokenCallShapesAreUnchangedForPageFlows() {
        let text: Color = Theme.Semantic.accent.textColor
        let graphic: Color = Theme.Semantic.accent.graphicColor
        let onFill: Color = Theme.Semantic.accent.onFillColor
        let badge: Color = Theme.Semantic.warning.badgeFill()
        let badgeDark: Color = Theme.Semantic.warning.badgeFill(in: .dark)
        let font: Font = Theme.Typo.metricNumber.font
        let iconFont: Font = IconRole.cardHeader.font
        let seriesColor: Color = Theme.Chart.color(at: 3)
        let labelColor: Color = Theme.Chart.color(forLabel: "Swift")
        let pairColor: Color = Theme.Chart.pair(at: 3).color
        let tokenColor: Color = Theme.Chart.token(forLabel: "Swift").color
        let dualColor: Color = DualColor(lightHex: 0x0A0A0A, darkHex: 0xF2F2F5).color
        let gradient: LinearGradient = Theme.Chart.areaGradient(at: 2, intensity: .soft)
        let gradientDefault: LinearGradient = Theme.Chart.areaGradient(at: 2)
        // 令牌仍可被页面按同样的标签构造（新增档位不需要改 Design）
        let tier = Theme.TypeToken(name: "probe", size: 12, weight: .regular, design: .default,
                                   monospacedDigits: false, lineSpacing: 2)
        let tierWithTracking = Theme.TypeToken(name: "probeTracking", size: 12, weight: .medium,
                                               design: .default, monospacedDigits: true,
                                               lineSpacing: 2, tracking: 0.6)

        for value in [text, graphic, onFill, badge, badgeDark, seriesColor, labelColor,
                      pairColor, tokenColor, dualColor] {
            XCTAssertEqual(Self.resolveHex(value, under: .aqua).count, 6, "有令牌解析不出值")
        }
        // 缓存出来的 Font 必须仍等于规范里的构造式（探针实测：同构建的 `Font` 可判等）。
        XCTAssertEqual(font, Font.system(size: 34, weight: .semibold, design: .default).monospacedDigit(),
                       "metricNumber 的缓存 Font 与规范构造式不同值，缓存改变了排版")
        XCTAssertEqual(Theme.Typo.monoSmall.font,
                       Font.system(size: 10, weight: .regular, design: .monospaced).monospacedDigit(),
                       "monoSmall 的缓存 Font 与规范构造式不同值")
        XCTAssertEqual(Theme.Typo.groupLabel.font,
                       Font.system(size: 10, weight: .medium, design: .default),
                       "groupLabel 的缓存 Font 与规范构造式不同值（这一档不开等宽数字）")
        XCTAssertEqual(iconFont, Font.system(.headline, weight: nil),
                       "IconRole.cardHeader 的缓存 Font 与规范构造式不同值")
        XCTAssertEqual(tier.font, Theme.Typo.narrative.font, "同为 12pt regular 的两档应同值")
        XCTAssertEqual(tierWithTracking.tracking, 0.6, accuracy: 0.0001)
        // 与**同一份规范**（12pt medium）的显式构造式比，只验证「monospacedDigits 这条判断
        // 在缓存后仍要生效」。改前这里拿 `tier.font`（12pt **regular**）去比，
        // 两边字重根本不同，是老版构造式与令牌不同值，不是缓存的问题。
        XCTAssertEqual(tierWithTracking.font,
                       Font.system(size: 12, weight: .medium, design: .default).monospacedDigit(),
                       "monospacedDigits 这条判断在缓存后仍要生效")
        XCTAssertNotEqual(tierWithTracking.font, tier.font,
                          "同一 12pt 下 regular 与 medium 必须仍是两个 Font（缓存没把字重抹平）")
        _ = gradient
        _ = gradientDefault
    }

    /// badge 底色改成缓存后仍与"图形色 × `Opacity.badgeFill`"同一口径（红线：渐变/底色
    /// 强度档必须对齐 `Theme.Palette.Opacity.*`）。这里用外观维度逐档核。
    func test_badgeFillStillMatchesItsOpacityTierInBothAppearances() {
        for role in Theme.Semantic.measurable {
            for appearance: DesignAppearance in [.light, .dark] {
                let expected = role.graphic.token(in: appearance).sRGBHex
                let fill = Self.resolveHex(role.badgeFill(in: appearance), under: appearance == .light ? .aqua : .darkAqua)
                XCTAssertEqual(fill, expected,
                               "「\(role.name)」的 \(appearance) badge 底色不再等于该外观的图形色（透明度是叠在 alpha 上，不改 RGB）")
            }
        }
        XCTAssertEqual(Theme.Palette.Opacity.badgeFill, 0.15, accuracy: 0.0001)
    }

    /// **计数尺子自己的元测试**（最重要的一条）：如果 `DesignTokenMeter` 数不到
    /// "每次访问现造"，上面那三条"命中数 ≤1"就是永真绿。
    /// 这里不造假货 —— 直接按定义构造 1000 个**新**令牌对象（新对象 = 新包装，
    /// 那是缓存的本意），要求计数器精确报出 1000。数不出来就是尺子坏了。
    func test_meterCountsConstructionsSoHitRateIsNotVacuous() {
        let beforeColor = DesignTokenMeter.count(.dynamicColor)
        for index in 0..<1000 {
            _ = DualColor(lightHex: 0x0A0A0A, darkHex: 0xF2F200 + UInt32(index % 250)).color
        }
        XCTAssertEqual(DesignTokenMeter.count(.dynamicColor) - beforeColor, 1000,
                       "构造 1000 枚新令牌，计数器没数到 1000 —— 计数通道是死的，命中数守卫全是假的")

        let beforeFont = DesignTokenMeter.count(.font)
        for index in 0..<1000 {
            _ = Theme.TypeToken(name: "probe\(index)", size: CGFloat(10 + index % 20), weight: .regular,
                                design: .default, monospacedDigits: index % 2 == 0, lineSpacing: 2).font
        }
        XCTAssertEqual(DesignTokenMeter.count(.font) - beforeFont, 1000,
                       "构造 1000 档新 Font，计数器没数到 —— Font 那条命中数断言是假的")

        // 渐变通道：能数到"表的规模"就说明它确实在数构造（见 ① 里那条 == 号位×档数 的断言）。
        XCTAssertGreaterThan(DesignTokenMeter.count(.gradient), 0, "渐变计数通道是死的")
        XCTAssertGreaterThan(DesignTokenMeter.count(.sRGBColor), 0, "分量色计数通道是死的")
    }

}
