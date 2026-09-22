// OWNER: R3 依赖证据链 · 「手写坐标串」扫描守卫（RD-12）
//
// 这一族用例 2026-09-22 从 `DependencyEvidenceTests.swift` **逐字节整块搬来**：
// 那边被 `X3TestSizeAuditTests` 的 400 行口径（`FileSystemCodeAnalyzer.mediumFileLines`，
// 与产品侧「巨大文件」同一把尺子）点到超限，B 组拆文件时漏了这一族。
// 搬动只换"住在哪个文件"：判据、期望值、注释一字未改，也没新增任何断言。
//
// 守卫管的是 RD-12 的病根：生产代码里再出现 `"\(name)@\(version)"` 这种手写 key，
// 就会出现"一侧用声明原文、一侧用查询身份、两边永不相等 ⇒ 总览有公告而依赖行不标记"。
// 唯一合法出口是 `DependencyVersionIdentity.coordinate(ecosystem:name:queryVersion:)`。
import XCTest
@testable import TcoderMonitor

final class DependencyCoordinateGuardTests: XCTestCase {

    // MARK: - 手写坐标串 = RD-12 的病根，扫描守卫要有牙

    /// 生产代码里**不许**再手写 `"\(name)@\(version)"` 这种 key：
    /// 一侧用声明原文、一侧用查询身份，两边永不相等 ⇒ 总览有公告而依赖行不标记。
    /// 唯一合法出口是 `DependencyVersionIdentity.coordinate(ecosystem:name:queryVersion:)`。
    static let coordinateNeedleParts = ["@\\(", "@\" +"]
    static func handBuiltCoordinateFindings(in files: [(path: String, text: String)]) -> [String] {
        files.filter { $0.path.contains("/Services/Dependencies/") || $0.path.contains("/Views/Dependencies/") }
            .compactMap { file in
                let hit = file.text.split(separator: "\n").contains { rawLine in
                    let line = rawLine.trimmingCharacters(in: .whitespaces)
                    if line.hasPrefix("//") || line.hasPrefix("///") { return false }
                    guard coordinateNeedleParts.contains(where: { line.contains($0) }) else { return false }
                    // 只有"拿**记录里的版本原文**拼 key"才算分叉；展示层把已存好的坐标
                    // 三段还原成 `lodash@4.17.15` 是合法的（它不生成 key，只还原文案）。
                    return line.contains("record.version") || line.contains(".$0.version")
                        || line.contains("record.resolvedVersion")
                }
                return hit ? file.path : nil
            }
    }

    func testNoHandBuiltCoordinateStringsRemain() throws {
        let files = try dependencyViewAndServiceSources()
        XCTAssertGreaterThan(files.count, 20, "扫描面小到这个程度说明扫描坏了，不是代码干净")
        XCTAssertTrue(Self.handBuiltCoordinateFindings(in: files).isEmpty,
                      "出现手写坐标串：\(Self.handBuiltCoordinateFindings(in: files))")
    }

    /// 元测试①：坏样例必须抓到。
    func testCoordinateGuardCatchesHandBuiltKey() {
        let bad = [(path: "Sources/TcoderMonitor/Services/Dependencies/X.swift",
                    text: #"let key = \(record.name)@\(record.version)"#)]
        XCTAssertEqual(Self.handBuiltCoordinateFindings(in: bad).count, 1)
    }

    /// 元测试②：合法形状不误伤（展示层还原文案、注释里提到旧拼法）。
    func testCoordinateGuardIgnoresLegalShapes() {
        let legal = [
            (path: "Sources/TcoderMonitor/Services/Dependencies/DependencyVersionIdentity.swift",
             text: ##"return "\(pieces[1])@\(pieces[2])""##),
            (path: "Sources/TcoderMonitor/Services/Dependencies/Y.swift",
             text: "// 旧实现一侧是 pkg@\\(version)，另一侧是 record.version —— 已删"),
            (path: "Sources/TcoderMonitor/Services/Code/Z.swift",
             text: #"let key = \(record.name)@\(record.version)"#),   // 域外，不归这条管
        ]
        XCTAssertTrue(Self.handBuiltCoordinateFindings(in: legal).isEmpty, "合法形状被误伤")
    }

    // MARK: - 辅助

    private func dependencyViewAndServiceSources() throws -> [(path: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TcoderMonitor", isDirectory: true)
        let manager = FileManager.default
        var files: [(String, String)] = []
        for directory in ["Services/Dependencies", "Views/Dependencies"] {
            let url = root.appendingPathComponent(directory, isDirectory: true)
            for name in try manager.contentsOfDirectory(atPath: url.path).sorted() where name.hasSuffix(".swift") {
                let path = url.appendingPathComponent(name).path
                guard let data = manager.contents(atPath: path), let text = String(data: data, encoding: .utf8)
                else { continue }
                files.append((path: path, text: text))
            }
        }
        return files
    }
}
