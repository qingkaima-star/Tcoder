import Foundation
import XCTest

/// 合成 git 仓库：只给这条守卫的元测试用。全局 `-c` 把身份、签名、hook 钉在夹具内，
/// 不继承宿主仓库与需求方的全局配置（否则换台机器结果就变）。
/// 拆成类型而不是测试里的闭包：Tests 侧有一条 50 行的函数上限（`X3TestSizeAuditTests`）。
final class FixtureRepo {
    let root: URL

    init(name: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(name + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func git(_ args: [String]) throws -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-c", "user.name=fx", "-c", "user.email=fx@local",
                       "-c", "commit.gpgsign=false", "-c", "core.hooksPath="] + args
        p.currentDirectoryURL = root
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        p.waitUntilExit()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard p.terminationStatus == 0 else {
            XCTFail("git \(args.joined(separator: " ")) 失败：\(text.split(separator: "\n").first ?? "")")
            return []
        }
        return text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    func change(_ name: String, _ body: String) throws {
        try body.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// 返回"实拍头"。之后 side 线把 a.txt 改成 3 再改回 2 ⇒ 历史动过这条路径、净内容与实拍头相同。
    func buildHistoryThatLooksTouchedButIsNot() throws -> String {
        try git(["init", "-q", "-b", "main"])
        try change("a.txt", "1")
        try git(["add", "a.txt"])
        try git(["commit", "-qm", "c1"])
        try change("a.txt", "2")
        try git(["commit", "-qam", "c2"])                    // ← 实拍所在头
        let shot = try git(["rev-parse", "HEAD"]).first ?? ""
        XCTAssertFalse(shot.isEmpty, "拿不到实拍头 ⇒ 夹具没搭起来")
        try git(["branch", "-f", "side", "HEAD~1"])
        try git(["checkout", "-q", "side"])
        try change("a.txt", "3")
        try git(["commit", "-qam", "X 动过这一页"])
        try change("a.txt", "2")
        try git(["commit", "-qam", "Y 顶回实拍端的内容"])
        return shot
    }
}
