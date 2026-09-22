import Foundation

//  RD-26 · 三处静默截断里的第一、二处：**发现阶段的 40 文件上限**与
//  **解析阶段的 `return nil`**。原来它们都把"我没看/我没读动"洗成了"这里没有东西"。
//     发现：`while … { if depth > 6 || out.found.count >= 40 { continue } … }` —— 命中上限后
//           剩下的目录**不下潜也不计数**，界面上就是"该项目只有这些报告"。
//     解析：`guard size > 0, size <= maxReportBytes, let text = try? String(…) else { return nil }`
//           —— 空文件、>20 MiB、非 UTF-8 三种原因合成一次静默丢弃。
//  这一页把它们换成**带原因的计数**，交给 `CoverageMergePlanner` 上屏。

// MARK: - 发现阶段的账

struct CoverageDiscoveryStats: Equatable, Sendable {
    var foundCount = 0
    /// 枚举失败（权限 / 悬空软链接 / 竞态中消失）的目录数。落盘走既有契约字段
    /// `CoverageMetrics.unreadableDirectoryCount`（三态：nil 没统计 / 0 都读得动 / >0 不完整）。
    var unreadableDirectories = 0
    /// 因为文件上限而**没有下潜**的目录数（旧实现静默跳过的工作）。
    var directoriesSkippedByFileCap = 0
    /// 因为深度上限而没有下潜的目录数。
    var directoriesSkippedByDepth = 0
    var fileCap = CoverageReportDiscovery.maxReportFiles
    var depthCap = CoverageReportDiscovery.maxDepth

    var isComplete: Bool {
        unreadableDirectories == 0 && directoriesSkippedByFileCap == 0
            && directoriesSkippedByDepth == 0
    }

    /// 每一条"没看完"都要出声。**上限本身不是缺陷，静默才是。**
    var notes: [String] {
        var out: [String] = []
        if directoriesSkippedByFileCap > 0 {
            out.append("发现阶段命中 \(fileCap) 个报告文件上限，"
                + "另有 \(directoriesSkippedByFileCap) 个目录没有下潜")
        }
        if directoriesSkippedByDepth > 0 {
            out.append("命中 \(depthCap) 层深度上限，\(directoriesSkippedByDepth) 个目录没有下潜")
        }
        if unreadableDirectories > 0 {
            out.append("\(unreadableDirectories) 个目录读不动（权限或已消失）")
        }
        return out
    }
}

// MARK: - 解析失败的原因

enum CoverageParseFailureReason: String, Codable, Sendable, CaseIterable {
    case emptyFile
    case oversize
    case notUtf8
    case unreadable
    case unrecognizedFormat
    /// 读到了、也认得格式，但里面**没有可用的分母**（LF/total/lines-valid 全是 0）。
    /// 单独一档是因为它与"读不动"是两件事：这份报告真实存在，只是没测出东西。
    case noUsableNumbers

    var note: String {
        switch self {
        case .emptyFile: return "空文件"
        case .oversize: return "超过单份上限"
        case .notUtf8: return "非 UTF-8"
        case .unreadable: return "读不到内容"
        case .unrecognizedFormat: return "文件名在候选清单里但认不出格式"
        case .noUsableNumbers: return "读到了但没有可用的行覆盖数字"
        }
    }
}

struct CoverageParseFailure: Equatable, Sendable {
    var path: String
    var reason: CoverageParseFailureReason
    /// 报告自身的字节数（拿不到就 nil，不许写 0 冒充"真的是空文件"）。
    var byteCount: Int?
}

// MARK: - 发现

enum CoverageReportDiscovery {
    /// 一次分析最多收集多少份报告文件。**上限保留**（遍历要有界），区别是命中它会出声。
    static let maxReportFiles = 40
    static let maxDepth = 6

    /// Deliberately NOT `ScanOptions.skipDirectories`: that list skips `coverage`,
    /// `target` and `build`, which is exactly where these reports live.
    static let thirdPartyDirectories: Set<String> = [
        "node_modules", "bower_components", "vendor", "Pods", "Carthage", "pub",
        ".git", ".build", ".swiftpm", "DerivedData", "venv", ".venv", "__pycache__",
        ".pytest_cache", ".mypy_cache", ".gradle", ".dart_tool", ".next", ".nuxt",
        ".turbo", ".parcel-cache", "xcuserdata", ".idea", ".vscode",
    ]

    struct Outcome: Sendable {
        var found: [URL] = []
        var stats = CoverageDiscoveryStats()
    }

    static func discover(in root: URL) -> Outcome {
        var out = Outcome()
        var queue: [(URL, Int)] = [(root, 0)]

        while let (directory, depth) = queue.popLast() {
            if depth > maxDepth {
                out.stats.directoriesSkippedByDepth += 1
                continue
            }
            if out.found.count >= maxReportFiles {
                out.stats.directoriesSkippedByFileCap += 1
                continue
            }
            let children: [URL]
            do {
                children = try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]
                )
            } catch {
                out.stats.unreadableDirectories += 1
                continue
            }

            for child in children {
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if values?.isDirectory == true {
                    if thirdPartyDirectories.contains(child.lastPathComponent) { continue }
                    queue.append((child, depth + 1))
                } else if CoverageReportFormat.allFileNames.contains(child.lastPathComponent) {
                    out.found.append(child)
                }
            }
        }
        out.found.sort { $0.path < $1.path }        // 输入顺序不影响读数（复现性）
        out.stats.foundCount = out.found.count
        return out
    }
}
