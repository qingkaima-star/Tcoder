import Foundation

/// 无头模式的自我口径。`doctor` 存在的理由是：**AI 在相信任何读数之前，
/// 得先知道自己用的是哪个二进制** —— 本仓的 release/debug 绝对值不可混比，
/// 而"改了代码却量到上一个头的数"这类事故靠 `verify_provenance.sh` 才拦得住。
enum CLIConfig {
    /// 整体硬上限。超了只能报「超时未回」并退出，不许把"没量到"降级成"量到 0"。
    static let hardTimeout: TimeInterval = 600

    static var binaryPath: String { CommandLine.arguments.first ?? "?" }

    static var buildConfiguration: String { ScanProvenance.buildConfiguration }

    static var bundleIdentity: String { ScanProvenance.bundleIdentity }

    static var versionLine: String {
        "tcoder · \(buildConfiguration) · \(bundleIdentity) · \(binaryPath)"
    }
}

/// stdout 只放读数，stderr 放警告与人的话 —— 这样 `tcoder scan … | jq` 才不会被进度行打断。
enum CLIOutput {
    static func line(_ text: String) { write(text + "\n", to: FileHandle.standardOutput) }
    static func fail(_ text: String) { write("!! " + text + "\n", to: FileHandle.standardError) }

    /// `--out=` 只写调用方指定的路径；App 的支持目录与分数历史一律不碰。
    static func write(_ text: String, to path: String) {
        do {
            try text.data(using: .utf8)?.write(to: URL(fileURLWithPath: path))
            line("已写出 \(path)")
        } catch {
            fail("写 \(path) 失败：\(error.localizedDescription)")
        }
    }

    private static func write(_ text: String, to handle: FileHandle) {
        handle.write(Data(text.utf8))
    }
}
