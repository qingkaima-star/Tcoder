/// OWNER: WS-X3 TestSplit —— 自 DesignTokenCacheGuardTests.swift 拆出，走缓存的行为读数：千次访问命中、整表扫不新建。用例本体未改，只是搬了家。
import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import TcoderMonitor

extension DesignTokenCacheGuardTests {

    /// 靶子 1：动态色包装对象。1000 次访问 = 0 次新构造（阈值 ≤1，容 lazy 落进窗口）。
    func test_dynamicColorHitsCacheOver1000Accesses() {
        warmUpAllTokens()
        let before = DesignTokenMeter.count(.dynamicColor)
        var consumed = 0
        for _ in 0..<1000 {
            // 读一次不产生构造；`String(reflecting:)` 是防止 -O 把整段循环折叠掉。
            consumed += String(reflecting: Theme.Semantic.danger.textColor).count
        }
        XCTAssertGreaterThan(consumed, 0)
        let built = DesignTokenMeter.count(.dynamicColor) - before
        XCTAssertLessThanOrEqual(built, 1,
                                 "同一枚语义色访问 1000 次新构造了 \(built) 个动态包装对象 —— 又回到每次访问现造")
        // 全站的缓存规模也必须是常数级：改前仅取色点每 tick 就 ~500 个。
        XCTAssertLessThanOrEqual(DesignTokenMeter.count(.dynamicColor), 64,
                                 "全 App 的动态色包装对象已超过 64 枚，说明有令牌没进缓存")
    }

    /// 靶子 1 的遍历口径：模拟"一个 tick 里把所有语义色各取一遍"，命中必须是 100%。
    func test_fullTokenSweepOver100RoundsBuildsNothing() {
        warmUpAllTokens()
        let beforeColor = DesignTokenMeter.count(.dynamicColor)
        let beforeSRGB = DesignTokenMeter.count(.sRGBColor)
        let beforeFont = DesignTokenMeter.count(.font)
        for round in 0..<100 {
            for role in Theme.Semantic.all {
                _ = String(reflecting: role.textColor).count
                _ = String(reflecting: role.graphicColor).count
                _ = String(reflecting: role.badgeFill(in: round % 2 == 0 ? .light : .dark)).count
            }
            for tier in Theme.Typo.all { _ = String(reflecting: tier.font).count }
            for index in 0..<Theme.Chart.count { _ = String(reflecting: Theme.Chart.color(at: index)).count }
            _ = String(reflecting: Theme.Chart.areaGradient(at: round % Theme.Chart.count,
                                                            intensity: .soft)).count
        }
        XCTAssertEqual(DesignTokenMeter.count(.dynamicColor) - beforeColor, 0, "100 轮遍历里又造了动态色包装器")
        XCTAssertEqual(DesignTokenMeter.count(.sRGBColor) - beforeSRGB, 0, "100 轮遍历里又造了分量色")
        XCTAssertEqual(DesignTokenMeter.count(.font) - beforeFont, 0, "100 轮遍历里又造了 Font")
    }

    /// 靶子 2：`TypeToken.font`。183 处 `.font(` 共用这 13 枚缓存。
    func test_typeTokenFontHitsCacheOver1000Accesses() {
        warmUpAllTokens()
        let before = DesignTokenMeter.count(.font)
        var consumed = ""
        for _ in 0..<1000 { consumed += String(reflecting: Theme.Typo.metricNumber.font) }
        XCTAssertFalse(consumed.isEmpty)
        let built = DesignTokenMeter.count(.font) - before
        XCTAssertLessThanOrEqual(built, 1,
                                 "访问 1000 次 metricNumber.font 新构造了 \(built) 个 Font —— 排版令牌又每次访问现造")
        // 图标那一侧同理：五档 `IconRole.font` 也只该有那五枚。
        let beforeIcons = DesignTokenMeter.count(.font)
        for _ in 0..<1000 { _ = String(reflecting: IconRole.badge.font).count }
        XCTAssertEqual(DesignTokenMeter.count(.font) - beforeIcons, 0, "IconRole.font 没吃到缓存")
    }

    /// 靶子 3：`areaGradient`。改前每次调用现造，Mark 逐点调用 = 每 tick 上百个。
    func test_areaGradientHitsCacheOver1000Lookups() {
        _ = Theme.Chart.areaGradient(at: 0)          // lazy 建表
        let builtForTable = DesignTokenMeter.count(.gradient)
        let expected = Theme.Chart.count * Theme.Chart.Intensity.allCases.count
        XCTAssertEqual(builtForTable, expected,
                       "渐变表构造了 \(builtForTable) 个对象，与「号位 × 强度档 = \(expected)」不符 —— 要么表没生效，要么有出口在现造")
        var consumed = 0
        for round in 0..<1000 {
            let gradient = Theme.Chart.areaGradient(at: round % Theme.Chart.count,
                                                    intensity: round % 2 == 0 ? .specTop : .soft)
            consumed += String(reflecting: gradient).count
        }
        XCTAssertGreaterThan(consumed, 0)
        XCTAssertEqual(DesignTokenMeter.count(.gradient) - builtForTable, 0,
                       "1000 次查表期间又构造了渐变 —— areaGradient 没在查表")
    }

    func test_designLayerNeverConstructsTokensPerAccess() throws {
        let files = try designFiles()
        let bodies = Self.computedBodies(in: files)

        // 分母三件套：真读到文件、真解析出计算属性、真扫到内容。
        // 空扫描器得零分也算绿，是本仓已知假绿模式。
        XCTAssertGreaterThanOrEqual(files.count, 10, "Design/ 只扫到 \(files.count) 个文件")
        XCTAssertGreaterThanOrEqual(bodies.count, 40,
                                   "只解析出 \(bodies.count) 个计算属性体，解析口径可疑（地板见注释）")
        let scannedLines = files.reduce(0) { $0 + $1.content.split(separator: "\n").count }
        XCTAssertGreaterThan(scannedLines, 1500, "只读到 \(scannedLines) 行，路径口径可疑")

        // 反向自证：这些名字必须仍以"计算属性"形态被解析到，说明解析器真在认体。
        let names = Set(bodies.map(\.name))
        for canary in ["textColor", "graphicColor", "onFillColor", "topOpacity",
                       "shadowColor", "referenceSurface", "isLiquid", "body"] {
            XCTAssertTrue(names.contains(canary),
                          "解析器没认到计算属性「\(canary)」—— 它可能已退化成空扫描器，上面那条 0 容忍就是假的")
        }

        let hits = Self.perAccessConstructorHits(in: files)
        XCTAssertTrue(hits.isEmpty,
                      "Design 层的计算属性体内出现了「每次访问现造」的写法（C 包靶子复发）：\n" + hits.joined(separator: "\n"))
    }

    /// 靶子 1 的复发检测：`color` 这个名字在 `Design/**` 里不得再是计算属性。
    /// （`IconRole.font` 仍**是**计算属性，只是它的体只 return 缓存，所以名字检查只收 `color`；
    /// `font` 由上面那条 `Font.system(` 的构造点判据守。）
    func test_colorTokenPropertyIsStoredNotComputed() throws {
        let bodies = Self.computedBodies(in: try designFiles())
        let recomputed = bodies.filter { $0.name == "color" }
        XCTAssertTrue(recomputed.isEmpty,
                      "`color` 又变回计算属性了，每次访问都会 new 动态色包装器：\(recomputed.map { "\($0.path):\($0.line)" })")
    }

    /// 靶子 3 的复发检测：`areaGradient` 出口必须**查表**，不得自己 `LinearGradient(...)`。
    /// 它改前是 `static func`，所以只扫计算属性的那条形状守卫抓不到它 —— 这条补上。
    func test_areaGradientAccessorReadsTheTableInsteadOfBuilding() throws {
        let file = try XCTUnwrap(try designFiles().first { $0.path.hasSuffix("ChartTokens.swift") },
                                 "扫不到 Design/ChartTokens.swift")
        let body = try XCTUnwrap(Self.block(containing: "static func areaGradient", in: file.content),
                                 "找不到 areaGradient 的函数体，出口被改名或删除了")
        XCTAssertFalse(body.contains("LinearGradient("),
                       "areaGradient 又在现造 LinearGradient —— 它被图表 Mark 逐点调用，就是每 tick 上百个对象")
        XCTAssertTrue(body.contains("areaGradientTable"),
                      "areaGradient 没有走 (强度档, 号位) 缓存表")
        let maker = try XCTUnwrap(Self.block(containing: "static func makeAreaGradient", in: file.content),
                                  "构造点 makeAreaGradient 不见了：表拿什么预计算？")
        XCTAssertTrue(maker.contains("LinearGradient("),
                      "构造点里已没有 LinearGradient —— 全表是空的，缓存就是假的")
    }

    /// 靶子 2 的复发检测：`TypeToken.font` 必须与档位一起在 init 里算一次。
    func test_typeTokenFontIsBuiltInInitAndCachedPerTier() throws {
        let file = try XCTUnwrap(try designFiles().first { $0.path.hasSuffix("ThemeTokens.swift") })
        XCTAssertTrue(file.content.contains("let font: Font"),
                      "TypeToken.font 不再是存储属性（改回计算属性 = 183 处 `.font(` 每次访问重造 Font）")
        let initBlock = try XCTUnwrap(Self.block(containing: "init(name: String, size: CGFloat", in: file.content))
        XCTAssertTrue(initBlock.contains("self.font ="),
                      "TypeToken.init 里没有构造 font，那 `let font: Font` 从哪来？")
        XCTAssertTrue(initBlock.contains("monospacedDigits ?"),
                      "init 里必须保留「数值档开等宽数字」这条判断，缓存不能把它弄丢")
    }

}
