import Foundation
import XCTest
@testable import TcoderMonitor

/// WS-M 名下的设计债棘轮（《45 WS-I》§6 建议的 `DesignDebtGuardTests` 的可落地子集）。
///
/// 口径：只扫本流负责的四个目录（性能 / 日志 / 健康 / 三页共用层），断言的是
/// 「**这些目录里一个都不许有**」。整行注释豁免——说明文里必须提到被禁的写法。
/// 别的页面还有存量债（归 WS-K / WS-L），这里不越权，也不替别人宣布达标。
final class PerformanceDesignDebtGuardTests: XCTestCase {

    private static var viewsRoot: URL {
        // .../TcoderMonitor/Tests/TcoderMonitorTests/本文件 → 上溯三级 = TcoderMonitor/
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TcoderMonitorTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // TcoderMonitor
            .appendingPathComponent("Sources/TcoderMonitor/Views")
    }

    private static let ownedDirectories = ["Performance", "Logs", "Health", "PerfLogs"]

    /// 禁用的**旧转发层**令牌：值本身没错，但页面应当写 Design/ 的语义名。
    private static let legacyTokens = [
        "Theme.accent", "Theme.healthy", "Theme.caution", "Theme.danger", "Theme.critical",
        "Theme.neutral", "Theme.cardBackground", "Theme.subtleBackground", "Theme.gridLine",
        "Theme.monoSmall", "Theme.monoBody", "Theme.metricNumber", "Theme.heroNumber", "Theme.color(for",
    ]

    private static let bannedPatterns: [(name: String, pattern: String)] = [
        ("裸字号 .system(size:", "\\.system\\(size:"),
        ("页内色值字面量", "Color\\(red:|Color\\(hex:"),
        ("自造圆角", "cornerRadius:"),
        ("内容卡 1px 描边", "strokeBorder"),
        ("散写透明度", "\\.opacity\\(0\\."),
        ("页面散写可用性判断", "#available"),
        ("品牌词污染", "[Mm]ona"),
        ("就地造等宽 / 圆体数字", "design: \\.(rounded|monospaced)"),
    ]

    private func swiftFiles(in directory: String) -> [URL] {
        let root = Self.viewsRoot.appendingPathComponent(directory)
        var result: [URL] = []
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                result.append(url)
            }
        }
        return result.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private struct ScannedLine {
        let number: Int
        let text: String
    }

    private func codeLines(of url: URL) throws -> (all: [ScannedLine], nonComment: [ScannedLine]) {
        let content = try String(contentsOf: url, encoding: .utf8)
        let all = content.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            .map { ScannedLine(number: $0.offset + 1, text: String($0.element)) }
        let code = all.filter { !$0.text.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        return (all, code)
    }

    func testOwnedPagesCarryNoBannedPatterns() throws {
        var violations: [String] = []
        var scanned = 0
        for directory in Self.ownedDirectories {
            for file in swiftFiles(in: directory) {
                scanned += 1
                let lines = try codeLines(of: file).nonComment
                for banned in Self.bannedPatterns {
                    let regex = try NSRegularExpression(pattern: banned.pattern, options: [])
                    for line in lines {
                        let range = NSRange(line.text.startIndex..., in: line.text)
                        if regex.firstMatch(in: line.text, options: [], range: range) != nil {
                            violations.append("\(directory)/\(file.lastPathComponent):\(line.number) [\(banned.name)] \(line.text.trimmingCharacters(in: .whitespaces))")
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(scanned, 10, "扫不到足够文件说明路径口径变了，这条棘轮会假绿")
        XCTAssertTrue(violations.isEmpty, "发现 \(violations.count) 处：\n" + violations.joined(separator: "\n"))
    }

    func testOwnedPagesDoNotUseLegacyForwardingTokens() throws {
        var violations: [String] = []
        for directory in Self.ownedDirectories {
            for file in swiftFiles(in: directory) {
                for line in try codeLines(of: file).nonComment
                where Self.legacyTokens.contains(where: { line.text.contains($0) }) {
                    violations.append("\(directory)/\(file.lastPathComponent):\(line.number) \(line.text)")
                }
            }
        }
        XCTAssertTrue(violations.isEmpty,
                      "仍在引用 App/Theme.swift 的旧转发名，应改走 Design/ 语义令牌：\n"
                        + violations.joined(separator: "\n"))
    }

    /// 与本流自己也要过的 800 行闸门同口径（全行数，含注释）。
    func testOwnedFilesStayUnderTheHugeFileBar() throws {
        for directory in Self.ownedDirectories {
            for file in swiftFiles(in: directory) {
                let total = try codeLines(of: file).all.count
                XCTAssertLessThan(total, 800, "\(file.lastPathComponent) 已经 \(total) 行，该拆了")
            }
        }
    }
}
