import XCTest

/// 对外产品名守卫：应用只叫 **Tcoder**。
///
/// 之前「Tcoder 项目监控」同时出现在窗口标题、页面标题和 `CFBundleName` 三处，
/// 而 Finder 里的包又叫 `Tcoder Monitor.app` —— 四个名字指同一个产品，用户问的
/// 「这个应用到底叫什么」没有唯一答案。规约里项目只叫 Tcoder，这条把它钉成断言。
///
/// 按仓库惯例，扫描型尺子必须配元测试：否则「路径打错 → 零命中 → 常绿」是废尺。
final class ProductNameGuardTests: XCTestCase {

    /// 包根：本文件 → TcoderMonitorTests → Tests → TcoderMonitor。
    /// 测试进程 CWD 不是包根，用相对路径会静默扫不到东西还判通过。
    private static let packageRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let longForms = ["项目监控", "Tcoder Monitor"]

    private static func longFormHits(in text: String) -> [String] {
        longForms.filter { text.contains($0) }
    }

    func testBundleNamesAreExactlyTcoder() throws {
        let data = try Data(contentsOf: Self.packageRoot.appendingPathComponent("Resources/Info.plist"))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let info = try XCTUnwrap(plist, "Info.plist 解析不出字典")
        for key in ["CFBundleName", "CFBundleDisplayName"] {
            XCTAssertEqual(info[key] as? String, "Tcoder", "\(key) 必须正好是 Tcoder，实得 \(String(describing: info[key]))")
        }
    }

    func testSourcesCarryNoLongFormProductName() throws {
        let sources = Self.packageRoot.appendingPathComponent("Sources/TcoderMonitor", isDirectory: true)
        let files = try Self.swiftFiles(under: sources)
        var offenders: [String] = []
        for url in files {
            let hits = Self.longFormHits(in: try String(contentsOf: url, encoding: .utf8))
            if hits.isEmpty == false { offenders.append("\(url.lastPathComponent): \(hits)") }
        }
        XCTAssertGreaterThanOrEqual(files.count, 100,
                                    "扫到的文件数只有 \(files.count)，说明目录解析已失效，本断言是空转的")
        XCTAssertTrue(offenders.isEmpty, "产品名被写长了：\(offenders)")
    }

    /// 递归取 `.swift`：目录不存在时 `contentsOfDirectory` 直接抛，不会退化成"零命中判通过"。
    private static func swiftFiles(under dir: URL) throws -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
        var collected: [URL] = []
        for url in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: []) {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isDirectory == true {
                collected.append(contentsOf: try swiftFiles(under: url))
            } else if values.isRegularFile == true, url.pathExtension == "swift" {
                collected.append(url)
            }
        }
        return collected
    }

    /// 元测试：证明上面那把尺子量得动东西，且不误伤正确写法。
    func testLongFormDetectorMatchesBadSampleAndIgnoresGoodOne() {
        XCTAssertEqual(Self.longFormHits(in: #"Text("Tcoder 项目监控")"#), ["项目监控"])
        XCTAssertEqual(Self.longFormHits(in: "APP=\"dist/Tcoder Monitor.app\""), ["Tcoder Monitor"])
        XCTAssertTrue(Self.longFormHits(in: #"WindowGroup("Tcoder")"#).isEmpty)
    }
}
