/// OWNER: WS-X3 TestSplit —— 自 DesignTokenCacheGuardTests.swift 拆出，改前形状的扫描器反例与分母非零自证。用例本体未改，只是搬了家。
import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import TcoderMonitor

extension DesignTokenCacheGuardTests {

    /// 坏样例用的是**改造前的原样代码**（不是编出来的形状），扫描器必须逐段判红。
    func test_scannersCatchThePreChangeShapes() throws {
        // 靶子 1：改前 DualColor.color + dynamicNSColor（原样抄自 git 前的 ColorToken.swift）
        let oldColor = """
        struct DualColor {
            var color: Color { Color(nsColor: dynamicNSColor) }

            private var dynamicNSColor: NSColor {
                NSColor(name: nil) { appearance in
                    let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    return (isDark ? dark : light).nsColor
                }
            }
        }
        """
        let colorHits = Self.perAccessConstructorHits(in: [("Design/Old.swift", oldColor)])
        XCTAssertTrue(colorHits.contains { $0.contains("Color(nsColor:") }, "没抓到包装 Color：\(colorHits)")
        XCTAssertTrue(colorHits.contains { $0.contains("NSColor(name:") }, "没抓到动态 NSColor：\(colorHits)")
        XCTAssertEqual(colorHits.count, 2, "命中数与坏样例不符（应为两枚：包装器 + 动态 NSColor）：\(colorHits)")

        // 靶子 2：改前 TypeToken.font
        let oldFont = """
        struct TypeToken {
            var font: Font {
                let base = Font.system(size: size, weight: weight, design: design)
                return monospacedDigits ? base.monospacedDigit() : base
            }
        }
        """
        let fontHits = Self.perAccessConstructorHits(in: [("Design/Old.swift", oldFont)])
        XCTAssertEqual(fontHits, ["Design/Old.swift:2:font → Font.system("], "没抓到每次访问重造 Font：\(fontHits)")

        // 靶子 1 的另一处：改前 ColorTokenPair.color（多行体里的 Color(nsColor: + NSColor(name:）
        let oldPair = """
        struct ColorTokenPair {
            var color: Color {
                Color(nsColor: NSColor(name: nil) { appearance in
                    return (isDark ? dark : light).nsColor
                })
            }
        }
        """
        XCTAssertEqual(Set(Self.perAccessConstructorHits(in: [("Design/Old.swift", oldPair)])),
                       Set(["Design/Old.swift:2:color → Color(nsColor:", "Design/Old.swift:2:color → NSColor(name:"]),
                       "多行计算属性体没扫全（花括号配平失效？）")

        // 靶子 3 是 `static func`，计算属性扫描器天生看不见 —— 所以 block(containing:) 必须看得见
        let oldGradient = """
        enum Chart {
            static func areaGradient(at index: Int, intensity: Intensity = .specTop) -> LinearGradient {
                let color = self.color(at: index)
                return LinearGradient(
                    stops: [.init(color: color.opacity(intensity.topOpacity), location: 0)],
                    startPoint: .top, endPoint: .bottom)
            }
        }
        """
        let oldBody = try? XCTUnwrap(Self.block(containing: "static func areaGradient", in: oldGradient))
        XCTAssertTrue(oldBody?.contains("LinearGradient(") == true, "block 提取没抓到旧渐变体")

        // 注释豁免：文档里必须能提到被禁写法（本文件与 ColorToken 的头注释就是这种提法）
        let commented = "// var color: Color { Color(nsColor: NSColor(name: nil) { _ in .black }) }\n"
        XCTAssertTrue(Self.perAccessConstructorHits(in: [("Design/Doc.swift", commented)]).isEmpty,
                      "注释被当成代码判红了 —— 守卫会拦住所有解释「为什么禁」的注释")
        // 反对照组：同一行注释后面跟着真代码时，代码仍要被抓到（不许过度剥）
        // 反对照组：同一行注释后面跟着真代码时，代码仍要被抓到（不许过度剥）。
        // 样本里放**两个**命中写法（`Color(nsColor:` + `NSColor(name:`）——只放一个的话
        // 期望值只能是 1，而「整行被注释剥掉」这种失效会把计数打到 0，正是本样本要抓的。
        let codeAfterComment = "var color: Color { Color(nsColor: NSColor(name: nil) { _ in .black }) }  // 旧写法\n"
        XCTAssertEqual(Self.perAccessConstructorHits(in: [("Design/Mix.swift", codeAfterComment)]).count, 2,
                      "行尾注释把真代码一起剥掉了 → 守卫会假绿")

        // 误报控制：存储属性不得被认成计算属性
        let stored = """
        struct T {
            var color: Color
            var tracking: CGFloat = 0
            var sizes: [String: Int] = [:]
        }
        """
        XCTAssertTrue(Self.computedBodies(path: "Design/T.swift", content: stored).isEmpty,
                      "把存储属性认成了计算属性 → 真页面会被误判")
    }

    /// 元测试的另一半：分母必须 > 0。扫描器读不到东西时，所有"isEmpty 即通过"的断言
    /// 会集体假绿 —— 这是本仓已知死法，单独钉一条。
    func test_scannerDenominatorsAreNonZeroOnRealSource() throws {
        let files = try designFiles()
        let bodies = Self.computedBodies(in: files)
        XCTAssertGreaterThan(files.count, 0)
        XCTAssertGreaterThan(bodies.count, 0)
        XCTAssertTrue(bodies.contains { !$0.code.isEmpty }, "解析出的体全是空的 —— 花括号配平坏了")
        // 已知仍在计算属性里的构造点必须被解析到（例如 ThemedIcon 的 symbol 读字符串），
        // 同时确认扫描面覆盖到了这几个具体文件，而不是只读到某个大文件。
        let paths = Set(files.map(\.path))
        for name in ["ColorToken.swift", "ThemeTokens.swift", "ChartTokens.swift",
                     "Glass.swift", "DataTable.swift", "IconTokens.swift"] {
            XCTAssertTrue(paths.contains { $0.hasSuffix(name) }, "扫描面漏了 \(name)")
        }
    }

}
