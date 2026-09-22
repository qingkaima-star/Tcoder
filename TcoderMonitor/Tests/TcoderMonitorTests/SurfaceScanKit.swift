import Foundation
import XCTest

// MARK: - 扫描型守卫的公共「读真源码」底座
//
// 从 `BorderlessSurfaceGuardTests` 里分出来的：那个文件写到了 900 行，
// 撞上《仓库自扫》的「不新增超 800 行文件」闸门（上限 0，阈值不动，拆才是修复）。
//
// 为什么要抽这一份而不是两个守卫类各抄一遍：`sourceFiles` / `codeLines` / `isCode`
// 是**所有扫描型守卫的尺子本身**。两把尺子各自实现，就会一个豁免整行注释、另一个不豁免，
// 而两边的断言都会照样绿 —— 这类分歧比漏一条规则更贵，因为它让"绿"失去含义。

enum SurfaceScanKit {
    private static let packageRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TcoderMonitorTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // TcoderMonitor
    }()

    /// 扫 `Sources/TcoderMonitor/<subpath>` 下所有 .swift，返回相对该目录的路径。
    static func sourceFiles(under subpath: String) throws -> [(path: String, content: String)] {
        let root = packageRoot.appendingPathComponent("Sources/TcoderMonitor")
        let dir = root.appendingPathComponent(subpath)
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        else {
            XCTFail("扫不到 \(dir.path) —— 路径口径变了，这条守卫会假绿")
            return []
        }
        let urls = walker.compactMap { $0 as? URL }
        guard !urls.isEmpty else {
            XCTFail("\(dir.path) 下一个文件都没有 —— 路径口径变了，这条守卫会假绿")
            return []
        }
        return urls.filter { $0.pathExtension == "swift" }.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return (url.path.replacingOccurrences(of: root.path + "/", with: ""), text)
        }
    }

    /// 读 `Tests/TcoderMonitorTests/<name>`。少数判据要钉的是**测试基座自己的形状**
    /// （例：复核型断言必须从同一份快照取数），所以 Tests 侧也要有出口。
    /// 与 `sourceFiles` 同一个根、同一套失败口径：**读不到就 XCTFail**，
    /// 不许返回空串让下面的字符串断言变成空转。
    static func testSource(_ name: String) -> String? {
        let url = packageRoot.appendingPathComponent("Tests/TcoderMonitorTests/\(name)")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("读不到 \(url.path) —— 测试基座改了名字或位置，钉它形状的守卫会假绿")
            return nil
        }
        return text
    }

    /// 这一行是不是代码。所有「扫源码文本」的判据都必须先过这一道：
    /// 文档注释里**必须**能写被禁的写法本身（否则没人知道旧写法是什么），
    /// 不豁免注释的扫描器第一次跑就会判自己违规。
    static func isCode(_ line: some StringProtocol) -> Bool {
        !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
    }

    /// 去掉整行注释后的代码行。
    static func codeLines(_ content: String) -> [String] {
        content.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { isCode($0) }
    }
}
