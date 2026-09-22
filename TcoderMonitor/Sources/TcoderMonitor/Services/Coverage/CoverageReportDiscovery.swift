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
    /// 因为文件上限而**没有下潜**的目录（点名到目录，相对被扫根、稳定序）。
    var fileCapSkippedDirectories: [String] = []
    /// 因为深度上限而没有下潜的目录（同上）。
    var depthSkippedDirectories: [String] = []
    /// 读不动的目录（同上）。**"读不动"也是"没看"**，所以同样要逐条点名。
    var unreadableDirectoryPaths: [String] = []
    /// 看到了、但因 40 份上限**没交给解析/合并**的报告文件（相对被扫根、稳定序）。
    /// R5b 之前的形状是"命中上限就连列都不列" ⇒ 这些文件根本不存在于任何账上（静默丢弃）。
    var overCapReportPaths: [String] = []
    var fileCap = CoverageReportDiscovery.maxReportFiles
    var depthCap = CoverageReportDiscovery.maxDepth

    /// 两条计数口径的旧形状（`Int`）由上面的点名清单算出来 —— **不留第二个数**，
    /// 免得"计数"与"清单"哪天各说一套（`CoverageContractFieldTests` 钉着两者一致）。
    var directoriesSkippedByFileCap: Int { fileCapSkippedDirectories.count }
    var directoriesSkippedByDepth: Int { depthSkippedDirectories.count }

    /// 三类"没看"的目录合起来逐条点名（落盘进 `CoverageMetrics.unexaminedDirectories`）。
    var unexaminedDirectoryPaths: [String] {
        Set(depthSkippedDirectories + fileCapSkippedDirectories + unreadableDirectoryPaths).sorted()
    }

    var isComplete: Bool {
        unreadableDirectories == 0 && directoriesSkippedByFileCap == 0
            && directoriesSkippedByDepth == 0
    }

    /// 披露那几句**不在这里造**：三道截断共用 §6.1 一个形状，唯一生产者是
    /// `CoverageDisplayShape.statementParts`（历史上这里就是一套平行说法）。
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

    /// 遍历是**路径升序的确定性 DFS**：children 先按路径排序再逆序入栈，
    /// 于是 `contentsOfDirectory` 那个**未定义顺序**再也参与不了"哪 40 份进合并"这件事
    /// （RD-39 那类"只在整套跑时红"就是环境形状混进了判定）。
    ///
    /// R5b 改的三件事（**都不放宽上限**，`maxReportFiles` 与 `maxDepth` 一字未动）：
    /// 1. 命中 40 份上限后，那些"不再下潜"的目录**照样各列一层名字**（`namesOnly` 模式：
    ///    列本层、绝不再入队）⇒ 超限的报告能**逐条点名**，不再"连列都不列"。
    ///    代价是每个被跳过的目录多一次列目录，遍历深度与广度都仍有界。
    /// 2. 超限的取舍改成"先收全、按路径排序、再切前 40 份"⇒ 同一棵树两次扫，
    ///    被丢掉的必须是同一批文件（旧实现取决于枚举顺序，谁被丢是偶然的）。
    /// 3. "没下潜 / 深到没看 / 读不动"三类目录**逐条点名**（旧实现只有三个计数）。
    static func discover(in root: URL) -> Outcome {
        var out = Outcome()
        var seen: [URL] = []
        var queue: [(directory: URL, depth: Int, namesOnly: Bool)] = [(root, 0, false)]

        while let entry = queue.popLast() {
            let (directory, depth, namesOnly) = entry
            if depth > maxDepth {
                // 点名坐标只在**真下潜**的那一批里记，免得同一目录被记两次。
                if !namesOnly { out.stats.depthSkippedDirectories.append(relative(directory, to: root)) }
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
                if !namesOnly { out.stats.unreadableDirectoryPaths.append(relative(directory, to: root)) }
                continue
            }

            var subdirectories: [URL] = []
            for child in children.sorted(by: { $0.path < $1.path }) {
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if values?.isDirectory == true {
                    if thirdPartyDirectories.contains(child.lastPathComponent) { continue }
                    subdirectories.append(child)
                } else if CoverageReportFormat.allFileNames.contains(child.lastPathComponent) {
                    seen.append(child)
                }
            }
            // 上限已命中：本层的报告名已经收进 `seen`（要能点名），**但不再正常下潜**；
            // 子目录只以 `namesOnly` 各列一层 —— 目的是"超限的那份能报出文件名"，不是继续扫盘。
            if seen.count >= maxReportFiles {
                if !namesOnly {
                    for sub in subdirectories {
                        out.stats.fileCapSkippedDirectories.append(relative(sub, to: root))
                    }
                }
                queue.append(contentsOf: subdirectories.reversed().map { ($0, depth + 1, true) })
                continue
            }
            // 逆序入栈 ⇒ `popLast` 取出的是路径升序。
            queue.append(contentsOf: subdirectories.reversed().map { ($0, depth + 1, false) })
        }

        let ordered = seen.sorted { $0.path < $1.path }
        out.found = Array(ordered.prefix(maxReportFiles))
        out.stats.overCapReportPaths = ordered.dropFirst(maxReportFiles).map { relative($0, to: root) }
        out.stats.foundCount = out.found.count
        return out
    }

    /// 点名用的**稳定坐标**：相对被扫根（切不出来才退回绝对路径，并在那里标注）。
    /// 绝对路径当坐标 ⇒ 换机器、换沙箱前缀就换键（本轮实测踩过 `/var` ↔ `/private/var`）。
    private static func relative(_ url: URL, to root: URL) -> String {
        CoverageReportIdentity.relativePath(of: url.path, root: root) ?? url.path
    }
}
