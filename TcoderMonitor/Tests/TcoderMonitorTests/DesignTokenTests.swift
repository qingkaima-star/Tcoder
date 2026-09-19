import AppKit
import CoreText
import XCTest

@testable import TcoderMonitor

/// WS-G 设计系统基座单测。
///
/// 这一层没有可截图的纯 UI 断言，能自动验的就是**令牌表的数学性质**：
/// 对比度、字号下限、等宽数字、色阶单调、符号可解析。这些恰好是"重样九页时
/// 会被人顺手改坏"的东西，所以钉死在这里。
///
/// 所有断言都从令牌本身取数（`ColorToken.contrastRatio` / `composited`），
/// 不复制一份颜色表——否则测试会和实现各自漂移。
final class DesignTokenTests: XCTestCase {

    private let appearances: [DesignAppearance] = [.light, .dark]

    /// 任务与 WS-H §10 共同要求的验收线。
    private let textLine: Double = 4.5
    private let graphicLine: Double = 3.0

    private func label(_ role: Theme.SemanticRole, _ appearance: DesignAppearance) -> String {
        "\(role.name)/\(appearance == .light ? "浅色" : "深色")"
    }

    // MARK: - A. 语义色文字层：浅深双向 ≥ 4.5:1

    func testSemanticTextTierClearsWCAG_AA_InBothAppearances() {
        for role in Theme.Semantic.measurable {
            for appearance in appearances {
                let ratio = role.contrastTextOnSurface(in: appearance)
                XCTAssertGreaterThanOrEqual(
                    ratio, textLine,
                    "\(label(role, appearance)) 文字层对比度 \(String(format: "%.2f", ratio)) 低于 \(textLine):1"
                )
            }
        }
    }

    /// badge 是同色半透明底，合成后仍然要够 4.5:1——这是最常被打穿的一条。
    func testSemanticTextClearsWCAG_AA_OnBadgeFill() {
        for role in Theme.Semantic.measurable {
            for appearance in appearances {
                let ratio = role.contrastTextOnBadgeFill(in: appearance)
                XCTAssertGreaterThanOrEqual(
                    ratio, textLine,
                    "\(label(role, appearance)) 在 badge 底色上的文字对比度只有 \(String(format: "%.2f", ratio))"
                )
            }
        }
    }

    func testAccentTextTierClearsWCAG_AA_EvenThoughItsGraphicFollowsSystem() {
        // accent 的图形色随用户强调色（无法数值断言），但文字层是钉死的。
        for appearance in appearances {
            let ratio = Theme.Semantic.accent.contrastTextOnSurface(in: appearance)
            XCTAssertGreaterThanOrEqual(
                ratio, textLine,
                "accent \(label(Theme.Semantic.accent, appearance)) 文字层不达标"
            )
        }
    }

    // MARK: - B. 图形色层：浅深双向 ≥ 3:1（非文本验收线）

    func testSemanticGraphicTierClearsNonTextContrastLine() {
        for role in Theme.Semantic.measurable {
            for appearance in appearances {
                let ratio = role.contrastGraphicOnSurface(in: appearance)
                XCTAssertGreaterThanOrEqual(
                    ratio, graphicLine,
                    "\(label(role, appearance)) 图形色 \(String(format: "%.2f", ratio)):1 低于非文本 \(graphicLine):1 验收线"
                )
            }
        }
    }

    // MARK: - C. 填充之上的前景：逐角色、逐外观择优后仍 ≥ 4.5:1

    func testOnFillForegroundClearsWCAG_AA_InBothAppearances() {
        for role in Theme.Semantic.measurable {
            for appearance in appearances {
                let ratio = role.contrastOnOwnFill(in: appearance)
                XCTAssertGreaterThanOrEqual(
                    ratio, textLine,
                    "\(label(role, appearance)) 的 onFill 前景放在本角色填充上只有 \(String(format: "%.2f", ratio))"
                )
            }
        }
    }

    /// critical 是唯一需要翻转 onFill 的角色：浅底深红配白、深底浅鲑红配墨。
    /// 这条守住"onFill 必须是双层"这个结论，谁把它改回单值就会在这里炸。
    func testCriticalRoleNeedsAppearanceDependentForeground() {
        let critical = Theme.Semantic.critical
        XCTAssertNotEqual(critical.onFill.light, critical.onFill.dark,
                          "critical 的 onFill 已退化成单值，必有一侧低于 4.5:1")
    }

    // MARK: - D. 排版：字号下限与等宽数字

    func testNoTypeTokenGoesBelowThe10PointFloor() {
        for token in Theme.Typo.all {
            XCTAssertGreaterThanOrEqual(token.size, 10,
                                        "\(token.name) 是 \(token.size)pt，低于全仓 10pt 硬下限")
        }
    }

    /// 指标实时跳动时数字宽度不能变，这是监控类 App 的底线。
    func testEveryNumericTierUsesMonospacedDigits() {
        for token in Theme.Typo.numericTiers {
            XCTAssertTrue(token.monospacedDigits, "\(token.name) 承载数字却没开 monospacedDigit")
        }
    }

    func testTypeScaleIsMonotonicallyOrderedAndHasNoDuplicateSizesByRole() {
        let sizes = Theme.Typo.all.map { $0.size }
        XCTAssertTrue(sizes.allSatisfy { $0 >= 10 })
        // 大字三档必须彼此拉得开，否则 tile 与 hero 会糊成同一级
        XCTAssertGreaterThan(Theme.Typo.heroMetric.size, Theme.Typo.metricNumber.size)
        XCTAssertGreaterThan(Theme.Typo.metricNumber.size, Theme.Typo.metricMid.size)
        XCTAssertGreaterThan(Theme.Typo.metricMid.size, Theme.Typo.pageTitle.size)
        XCTAssertGreaterThan(Theme.Typo.pageTitle.size, Theme.Typo.cardTitle.size)
    }

    /// WS-H §4.1：弃用 `.rounded`，向活动监视器的原生观感靠拢。
    func testNoTypeTokenUsesRoundedDesign() {
        for token in Theme.Typo.all where token.design == .rounded {
            XCTFail("\(token.name) 仍在用 .rounded 设计，规范已明确要求退回 SF 默认")
        }
    }

    // MARK: - E. 栅格与圆角：防重新发散

    func testRadiusScaleMatchesSpecifiedFiveSteps() {
        XCTAssertEqual(Theme.Radius.none, 0)
        XCTAssertEqual(Theme.Radius.sm, 6)
        XCTAssertEqual(Theme.Radius.md, 10)
        XCTAssertEqual(Theme.Radius.card, 16, "内容卡圆角按 WS-H §3.3 定为 16，不是历史的 10")
        XCTAssertGreaterThan(Theme.Radius.full, Theme.Radius.card)
    }

    func testSpacingScaleSitsOnThe4PointGrid() {
        let onGrid: [CGFloat] = [
            Theme.Spacing.xxs, Theme.Spacing.xs, Theme.Spacing.sm, Theme.Spacing.md,
            Theme.Spacing.lg, Theme.Spacing.xl, Theme.Spacing.xxl, Theme.Spacing.section,
            Theme.Spacing.gutter, Theme.Spacing.cardPadding, Theme.Spacing.tilePadding,
        ]
        for value in onGrid {
            XCTAssertEqual(value.truncatingRemainder(dividingBy: 4), 0,
                           "\(value) 不在 4pt 刻度上")
        }
        // chip = 6 是 WS-H §9 的显式值，它不在刻度上属于规范自身的缺口，单列在此备案
        XCTAssertEqual(Theme.Spacing.chip, 6)
    }

    func testLayoutAnchorsMatchSpecifiedWidths() {
        XCTAssertEqual(Theme.Layout.maxWidthReading, 1040)
        XCTAssertEqual(Theme.Layout.maxWidthOverview, 1120)
        XCTAssertEqual(Theme.Layout.maxWidthDense, 1240)
        XCTAssertEqual(Theme.Layout.tileMinWidth, 220)
        XCTAssertLessThan(Theme.Layout.tileMinWidth, Theme.Layout.twoColumnMinWidth)
        XCTAssertGreaterThanOrEqual(Theme.Layout.minHitTarget, 20, "可点区不得小于 20pt")
    }

    // MARK: - F. 健康分色阶：单调、无蓝档、未评分不着色

    func testHealthScoreColorScaleIsMonotonicAndBlueFree() {
        let severityRank: [String: Int] = [
            "success": 0, "healthy": 1, "warning": 2, "danger": 3, "critical": 4,
        ]
        // 分数从 100 降到 1，严重度只能升不能降
        var previous = -1
        for score in stride(from: 100, through: 1, by: -1) {
            let role = Theme.Semantic.role(forScore: score)
            XCTAssertNotEqual(role.name, "accent",
                              "分数 \(score) 落到了 accent（蓝），违反一色一义")
            let rank = severityRank[role.name] ?? -1
            XCTAssertGreaterThanOrEqual(rank, previous,
                                        "分数 \(score) 的色阶从 rank \(previous) 回退到 \(rank)，不再单调")
            previous = rank
        }
        XCTAssertEqual(Theme.Semantic.role(forScore: 100).name, "success")
        XCTAssertEqual(Theme.Semantic.role(forScore: 1).name, "danger")
    }

    /// 未评分必须不着色——0 分和"没数据"是两件事（呼应 WS-D 诚实线）。
    func testNilScoreFallsBackToNeutralAndNeverDanger() {
        XCTAssertEqual(Theme.Semantic.role(forScore: nil).name, "neutral")
        XCTAssertNotEqual(Theme.Semantic.role(forScore: nil).name, "danger")
    }

    // MARK: - G. 数据契约的穷尽映射

    func testEveryRiskLevelMapsToARole() {
        for risk in RiskLevel.allCases {
            let role = Theme.Semantic.role(for: risk)
            XCTAssertFalse(role.name.isEmpty)
        }
        XCTAssertEqual(Theme.Semantic.role(for: .critical).name, "critical")
        XCTAssertEqual(Theme.Semantic.role(for: .none).name, "neutral")
    }

    func testEveryLogSeverityMapsToARoleWithoutReadingColorHex() {
        for severity in LogSeverity.allCases {
            let role = Theme.Semantic.role(for: severity)
            XCTAssertFalse(role.name.isEmpty, "\(severity) 没有语义色映射")
        }
        XCTAssertEqual(Theme.Semantic.role(for: .crash).name, "critical")
        XCTAssertEqual(Theme.Semantic.role(for: .debug).name, "neutral")
    }

    /// 注册表完整性：新增角色必须同时进 `all`、名字唯一；`measurable` 只允许少一个
    /// accent（它随用户系统强调色，数值不可断言）。防止有人加了角色却忘了补对比度断言。
    func testSemanticRegistryIsCompleteAndUniquelyNamed() {
        let all = Theme.Semantic.all
        XCTAssertEqual(Set(all.map(\.name)).count, all.count, "语义角色有重名")
        XCTAssertEqual(Theme.Semantic.measurable.count + 1, all.count,
                       "all 与 measurable 之间只应差 accent 一项，多出来的角色必须补对比度断言")
        XCTAssertEqual(all.filter { $0.systemGraphic != nil }.count, 1,
                       "只能有一个角色走系统动态色")
    }

    // MARK: - H. 图表色板：全 App 唯一一套

    func testChartPaletteHasEightDistinctSeries() {
        XCTAssertEqual(Theme.Chart.count, 8)
        for appearance in [.light, .dark] as [DesignAppearance] {
            var seen: Set<String> = []
            for index in 0..<Theme.Chart.count {
                let hex = Theme.Chart.pair(at: index).token(in: appearance).sRGBHex
                XCTAssertTrue(seen.insert(hex).inserted, "浅色板出现重复色 #\(hex)")
            }
        }
    }

    /// 色板回绕必须稳定：越界索引不能 panic，且落回同一组色。
    func testChartPaletteWrapsAroundSafely() {
        XCTAssertEqual(Theme.Chart.pair(at: 0).light, Theme.Chart.pair(at: 8).light)
        XCTAssertEqual(Theme.Chart.pair(at: 3).light, Theme.Chart.pair(at: -5).light)
    }

    /// 已上报的规范缺口：WS-H §5.4 的 8 色板在**可辨性**上实测不合格——
    /// 浅色下 #FF9F0A(橙) 与 #A2845E(棕) 色相只差 3°、#FF3B30(红) 与 #A2845E(棕)
    /// 亮度比只有 1.01，肉眼几乎同色；深色下 #BF5AF2(紫) 与 #FF375F(粉) 同样是 1.00。
    /// 这里只钉"不得比实测更差"的地板，真正的调色是 needs-design-decision，交总工/WS-H 定夺。
    func testChartPaletteSeparationDoesNotGetWorseThanMeasuredFloor() {
        for appearance in appearances {
            let colors = (0..<Theme.Chart.count).map { Theme.Chart.pair(at: $0).token(in: appearance) }
            var worst = Double.greatestFiniteMagnitude
            for i in 0..<colors.count {
                for j in (i + 1)..<colors.count {
                    worst = min(worst, colors[i].contrastRatio(with: colors[j]))
                }
            }
            XCTAssertGreaterThanOrEqual(
                worst, 0.99,
                "\(appearance == .light ? "浅色" : "深色")板可辨性进一步恶化：最劣成对对比度 \(String(format: "%.2f", worst))")
        }
    }

    // MARK: - I. 中文回退（规范要求的"中文用 PingFang SC"，实测而非注释）

    func testChineseGlyphsFallBackToPingFangSC() throws {
        let probe = "健康评分" as CFString
        let base = CTFontCreateWithName("Helvetica" as CFString, 13, nil)
        let resolved = CTFontCreateForString(base, probe, CFRange(location: 0, length: CFStringGetLength(probe)))
        let name = CTFontCopyPostScriptName(resolved) as String
        XCTAssertTrue(name.hasPrefix("PingFang"),
                      "系统对汉字的回退字体是 \(name)，不是 PingFang SC——字族策略需要重估")
    }

    // MARK: - J. 图标登记表

    /// WS-H §6.1 要求每个符号名过非空校验；登记不进来的名字在旧系统上会画成空白。
    func testEveryRegisteredSymbolResolvesOnThisSystem() {
        var unresolvable: [String] = []
        for name in IconName.allCases {
            if NSImage(systemSymbolName: name.rawValue, accessibilityDescription: nil) == nil {
                unresolvable.append("\(name): \(name.rawValue)")
            }
            if let selected = name.selectedSymbol,
               NSImage(systemSymbolName: selected, accessibilityDescription: nil) == nil {
                unresolvable.append("\(name).selected: \(selected)")
            }
            if NSImage(systemSymbolName: name.fallbackSymbol, accessibilityDescription: nil) == nil {
                unresolvable.append("\(name).fallback: \(name.fallbackSymbol)")
            }
        }
        XCTAssertTrue(unresolvable.isEmpty, "以下符号本机解析不到：\(unresolvable)")
    }

    /// 图标的尺寸/字重必须从"它旁边的文字是哪一档"推导。可自动验的部分：
    /// 五档角色必须各自绑定一个**不同**的文本样式——否则 `role` 参数形同虚设，
    /// 迟早有人退回裸 `.system(size:)`。
    /// （不能拿 `Font` 本身比：`String(describing: Font)` 五档全打印成同一个 box，测不出东西。）
    func testIconRolesBindFiveDistinctTextStyles() {
        let roles = IconRole.allCases
        for (i, a) in roles.enumerated() {
            for b in roles.dropFirst(i + 1) {
                XCTAssertNotEqual(a.textStyle, b.textStyle,
                                  "\(a) 与 \(b) 绑了同一个文本样式 \(a.textStyle)，档位形同虚设")
            }
        }
    }

    /// 每个登记图标都有默认档，且 `ThemedIcon` 不传 role 时用的就是它。
    func testEveryIconHasADefaultRole() {
        for name in IconName.allCases {
            XCTAssertTrue(IconRole.allCases.contains(name.role),
                          "\(name.rawValue) 的默认档不在 IconRole 集合里")
        }
    }

    // MARK: - L. 缺证据不得渲染成结论（WS-G P0 + WS-I §3.4）

    /// P0 本体：`RiskLevel.none` 在离线默认态下几乎对所有项目成立
    /// （`riskLevel` 只看 `vulnerableCount`），所以对勾会把"我们没查"画成"我们查了、是安全的"。
    func testUnverifiedRiskBadgeNeverDrawsACheckmark() {
        for risk in RiskLevel.allCases {
            let p = RiskBadge.presentation(risk: risk, verified: false)
            XCTAssertNotEqual(p.icon, .noRisk,
                              "未核对态下的 \(risk.rawValue) 仍然画出了对勾")
            XCTAssertEqual(p.role.name, "neutral", "未核对必须走中性色，不得带倾向")
            XCTAssertEqual(p.text, "未核对")
        }
    }

    /// 反向保险：`.none` 也被代码规模/复杂度等维度复用，那里的"无风险"是**真结论**，
    /// 不能因为 P0 被一起改掉。
    func testVerifiedNoRiskBadgeStillEarnsItsCheckmark() {
        let p = RiskBadge.presentation(risk: .none, verified: true)
        XCTAssertEqual(p.icon, .noRisk, "真核对过的无风险不该被降级成问号")
        XCTAssertEqual(p.text, "风险 无")
    }

    /// 「无风险」与「未核对」共用 neutral 色（RiskLevel.none 本就映射到 neutral），
    /// 所以区分必须落在**图标 + 文字**这两个通道上——这正是 WS-H §10「不许只靠颜色表意」。
    func testNoRiskAndUnverifiedAreToldApartByIconAndTextNotByColor() {
        let clean = RiskBadge.presentation(risk: .none, verified: true)
        let unknown = RiskBadge.presentation(risk: .none, verified: false)
        XCTAssertEqual(clean.role.name, unknown.role.name, "两者同色是预期，别把它当 bug 改")
        XCTAssertNotEqual(clean.icon, unknown.icon)
        XCTAssertNotEqual(clean.text, unknown.text)
    }

    func testUnverifiedIconIsRegisteredAndDistinctFromNoRisk() {
        XCTAssertNotEqual(IconName.unverified.rawValue, IconName.noRisk.rawValue)
        XCTAssertNotNil(NSImage(systemSymbolName: IconName.unverified.rawValue,
                                accessibilityDescription: nil))
    }

    /// "没查到" 必须显示 `--`；真 0 必须照原样显示 0。两者混同就是 WS-D 反复强调的那类事故。
    func testMetricTileRendersMissingValueAsPlaceholderNotZero() {
        XCTAssertEqual(Theme.Placeholder.missingValue, "--")
        XCTAssertEqual(MetricTile.displayValue(nil), "--")
        XCTAssertNotEqual(MetricTile.displayValue(nil), "0",
                          "缺数据被渲染成 0，等于凭空造出一个好消息")
        XCTAssertEqual(MetricTile.displayValue("0"), "0", "真 0 必须原样显示")
    }

    func testMetricTileDropsCallerTintWhenThereIsNoValue() {
        XCTAssertTrue(MetricTile.forcesNeutralTint(for: nil),
                      "无值时仍在沿用调用方给的倾向色")
        XCTAssertFalse(MetricTile.forcesNeutralTint(for: "0"),
                       "真 0 是有数据的结论，不该被中性化")
        XCTAssertFalse(MetricTile.forcesNeutralTint(for: "42"))
    }

    // MARK: - M. 与 WS-I 设计债清单的对应（防止我把已修的又漏回去）

    /// WS-I §4：全仓 `.monospacedDigit()` 命中 0，根因在 `Theme.metricNumber/heroNumber` 没开。
    /// 这一条就是那个"改一处全站生效"的落点，必须已经修好。
    func testLargeNumberTokensAreMonospacedNow() {
        XCTAssertTrue(Theme.Typo.metricNumber.monospacedDigits,
                      "WS-I §4 指出的根因未修：metricNumber 仍不等宽")
        XCTAssertTrue(Theme.Typo.heroMetric.monospacedDigits)
        XCTAssertFalse(Theme.Typo.metricNumber.design == .rounded)
        XCTAssertFalse(Theme.Typo.heroMetric.design == .rounded)
    }

    /// WS-I §2.5：badge 底色透明度在 0.12 / 0.14 / 0.15 之间漂移，现收成一档。
    func testBadgeTintAlphaIsASingleValue() {
        XCTAssertEqual(Theme.Palette.Opacity.badgeFill, 0.15)
    }

    // MARK: - N. 玻璃闸门

    func testGlassEngineReportsOneDeterministicMode() {
        let first = GlassEngine.mode
        XCTAssertEqual(first, GlassEngine.mode)
        XCTAssertEqual(first.isLiquid, GlassEngine.mode == .liquid)
    }

    /// 闸门只许有"真玻璃 / 材质兜底"两种形态。出现第三种，说明有人把内容层
    /// 也接上了可用性分支——那会重新引入"旧系统上另一套长相"这个本要被消灭的问题。
    func testGlassGateIsStrictlyBinary() {
        XCTAssertEqual(GlassMode.allCases.count, 2,
                       "GlassMode 多出了一档，内容层不再保证跨系统同形")
    }
}
