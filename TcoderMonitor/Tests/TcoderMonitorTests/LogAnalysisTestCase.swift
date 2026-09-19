import Foundation
import XCTest
@testable import TcoderMonitor

/// 日志分析测试的共用底座：临时目录 + 路径判定。
/// 拆自 LogAnalysisTests.swift，各拆分类继承它即可（WS-V）。
class LogAnalysisTestCase: XCTestCase {
    // MARK: 临时目录

    func makeTempDir(_ tag: String) throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tcoder-logtest-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let captured = base
        addTeardownBlock {
            try? FileManager.default.removeItem(at: captured)
        }
        return base
    }

    /// 判断路径是否位于夹具目录之下。macOS 的 `/var` 与 `/private/var` 是同一份，
    /// FileManager 有时会给出解析软链后的形式，所以几种写法都接受。
    func isUnder(_ path: String, root: URL) -> Bool {
        let variants: [String] = [
            root.path,
            root.standardizedFileURL.path,
            root.resolvingSymlinksInPath().path,
            root.path.replacingOccurrences(of: "/private/var/", with: "/var/"),
        ]
        return variants.contains { path.hasPrefix($0) }
    }

    // MARK: 1. parseTimestamp —— 九种格式

}
