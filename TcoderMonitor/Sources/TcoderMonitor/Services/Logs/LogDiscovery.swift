//
// 日志发现：项目内递归 + ~/Library/Logs/<项目名> + 本 App 自己的 DiagnosticReports
//
// 从 LogParsing.swift 拆出：只为控制单文件长度，语义与拆分前完全一致。
//
import Foundation

// MARK: - 日志发现

// MARK: - 日志发现

enum LogDiscovery {

    /// 项目内发现 + `~/Library/Logs/<身份令牌>/` + `~/Library/Logs/DiagnosticReports/*.ips`
    ///
    /// `identity` 是 `LogProjectIdentity.resolve(scanRoot:)` 的结果 —— **不是**
    /// `projectRoot.lastPathComponent`。理由见那个类型头注：拿目录名当应用身份，
    /// 会让"扫仓库根"与"扫子目录"得到两份不同的自动输入（RD-23）。
    ///
    /// `withinDays` 对**三个发现来源一起生效**（<= 0 表示不限制）：日志页把窗口写在工具栏上，
    /// 只裁崩溃报告、把工程日志与 ~/Library/Logs 全量收进来，等于「7 天」下面摆着全部历史。
    /// ⚠️ 这里的 mtime 裁剪只是**候选筛选上界**（一个 90 天没被写过的文件不可能含最近 7 天的
    /// 新条目），它不等于"最近 N 天"这个结论 —— 那一条在 `LogAggregator` 里按**事件时间**落实。
    /// 修改时间读不到的文件按「无法证明在窗口内」处理，与 `.ips` 那条规则同一个口径。
    static func discover(projectRoot: URL, identity: LogProjectIdentity,
                         withinDays: Int, maxFiles: Int) -> [DiscoveredLog] {
        guard maxFiles > 0 else { return [] }
        var unique: [String: DiscoveredLog] = [:]
        let cutoff: Date? = withinDays > 0 ? Date().addingTimeInterval(-Double(withinDays) * 86_400) : nil

        func register(_ url: URL) {
            let key = canonicalPath(of: url)
            guard unique[key] == nil else { return }
            let values = attributes(of: url)
            guard values.isFile else { return }
            let modified = values.modifiedAt ?? Date.distantPast
            if let cutoff, modified < cutoff { return }
            unique[key] = DiscoveredLog(url: URL(fileURLWithPath: key),
                                        role: role(for: url, in: projectRoot),
                                        sizeBytes: values.sizeBytes,
                                        modifiedAt: modified)
        }

        for url in projectLogCandidates(root: projectRoot) { register(url) }
        for url in libraryLogCandidates(identity: identity) { register(url) }
        for url in diagnosticReportCandidates(withinDays: withinDays, identity: identity) { register(url) }

        return unique.values
            .sorted { lhs, rhs in
                if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
                return lhs.url.path < rhs.url.path
            }
            .prefix(maxFiles)
            .map { $0 }
    }

    static func role(for url: URL, in projectRoot: URL?) -> LogFileRole {
        let name = url.lastPathComponent.lowercased()
        let haystack: String
        if let projectRoot {
            let relative = relativePath(of: url, root: projectRoot)
            haystack = relative == url.path ? url.path.lowercased() : relative.lowercased()
        } else {
            haystack = url.path.lowercased()
        }

        // 崩溃特征优先于 error 字样：DiagnosticReports 的 .ips 名字常同时含两者，归错类会让崩溃整类证据消失
        if url.pathExtension.lowercased() == "ips" || haystack.contains("diagnosticreports") { return .crash }
        if name.contains("crash") { return .crash }
        if name.contains("error") || name.contains("exception") { return .error }
        if name.contains("audit") || name.contains("systemlog") || name.contains("system.log") { return .system }
        if name.contains("build") || name.contains("gradle-worker") || name.contains("npm-debug") { return .build }
        return .application
    }

    static func diagnosticReportsDirectory() -> URL {
        libraryLogsDirectory().appendingPathComponent("DiagnosticReports", isDirectory: true)
    }

    /// 本项目可能写日志的目录：锚点名 + 每个自报产品名各一个 `~/Library/Logs/<名字>`。
    /// 只查锚点名会漏掉"目录叫 repo、产品叫 App"的常见形状，那正是漏报的一半来源。
    static func projectLibraryLogDirectories(identity: LogProjectIdentity) -> [URL] {
        identity.attributionTokens.sorted().map { token in
            libraryLogsDirectory().appendingPathComponent(token, isDirectory: true)
        }
    }

    // MARK: 发现细节

    static let maxDepth = 6
    static let directoryBudget = 4_000
    static let entryBudget = 60_000

    /// 取证用的 `~/Library/Logs` 根目录覆盖（R4 十条夹具里的"归属混合"用例要靠它）。
    ///
    /// 为什么必须有显式开关而不是让测试去碰真的 `~/Library/Logs/DiagnosticReports`：
    /// 那个目录是**全机所有 App** 的报告，其中绝大多数属于别的工程，
    /// 规约禁止读取（AGENTS §-1 禁区），而且拿它当夹具等于把测试结果绑到这台机器上。
    /// 与 `ProjectStore` 的 `TCODER_SUPPORT_DIR` 同一个套路：只在进程环境里给，
    /// 生产路径不经过它，所以产品行为一字未变。
    static let libraryLogsDirectoryOverrideKey = "TCODER_LIBRARY_LOGS_DIR"

    static let skippedDirectoryNames: Set<String> = [
        "node_modules", "build", ".build", ".git", ".svn", "dist", "out", "target", "bin", "obj",
        "DerivedData", "Pods", "Carthage", "venv", ".venv", "__pycache__", "vendor", ".next",
        ".gradle", "xcuserdata",
    ]

    /// 含斜杠的相对路径黑名单（整棵子树跳过）
    static let skippedRelativePaths: [String] = ["Resources/raw"]

    static let logExtensions: Set<String> = ["log", "out"]
    static let crashExtensions: Set<String> = ["ips"]

    /// 名字像日志但实际是二进制 / 压缩产物，别交给行解析器
    static let rejectedExtensions: Set<String> = [
        "zip", "gz", "tgz", "bz2", "xz", "zst", "7z", "dmg", "pkg", "app", "framework", "dylib", "so",
        "a", "o", "class", "jar", "war", "png", "jpg", "jpeg", "gif", "pdf", "icns", "ttf", "otf",
        "woff", "woff2", "mp4", "mov", "db", "db-wal", "db-shm", "sqlite", "sqlite3", "pack", "idx",
        "pyc", "map",
    ]

    /// 一次项目目录深度优先遍历的可变预算与栈。
    /// 三个量原先都是 `projectLogCandidates` 的局部变量，抽出来只为让「逐条目分类」
    /// 那段能独立成一个短函数；**预算初值、递减顺序、`break` 的位置一字未改**。
    private struct LogDirectoryWalk {
        struct Frame { var url: URL; var depth: Int }

        let root: URL
        var stack: [Frame]
        var directoriesLeft: Int
        var entriesLeft: Int
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .nameKey]

        init(root: URL, directoryBudget: Int, entryBudget: Int, maxDepth: Int) {
            self.root = root
            self.stack = [Frame(url: root, depth: 0)]
            self.directoriesLeft = directoryBudget
            self.entriesLeft = entryBudget
        }

        /// 一个目录里的全部条目 -> 追加日志文件、追加待下潜的子目录。
        /// 四条跳过规则（符号链接、深度上限、跳过名单、非普通文件）与 `isLogFile`
        /// 这条纳入判据，全部照抄拆分前。
        mutating func consume(_ entries: [URL], frame: Frame, maxDepth: Int, into result: inout [URL]) {
            for entry in entries {
                entriesLeft -= 1
                if entriesLeft <= 0 { break }
                let values = try? entry.resourceValues(forKeys: Set(keys))
                // 符号链接既不跟随也不读取：不会成环，也不会顺链接逃到仓库外的资产目录
                if values?.isSymbolicLink == true { continue }

                if values?.isDirectory == true {
                    if frame.depth >= maxDepth { continue }
                    if LogDiscovery.isSkippedDirectory(entry, root: root) { continue }
                    stack.append(Frame(url: entry, depth: frame.depth + 1))
                    continue
                }
                if values?.isRegularFile == false { continue }
                if LogDiscovery.isLogFile(entry) { result.append(entry) }
            }
        }
    }

    private static func projectLogCandidates(root: URL) -> [URL] {
        var result: [URL] = []
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return result }

        var walk = LogDirectoryWalk(root: root, directoryBudget: directoryBudget,
                                    entryBudget: entryBudget, maxDepth: maxDepth)
        while let frame = walk.stack.popLast() {
            guard walk.directoriesLeft > 0, walk.entriesLeft > 0 else { break }
            walk.directoriesLeft -= 1
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: frame.url, includingPropertiesForKeys: walk.keys, options: [.skipsHiddenFiles]
            ) else { continue }

            walk.consume(entries, frame: frame, maxDepth: maxDepth, into: &result)
        }
        return result
    }

    private static func libraryLogCandidates(identity: LogProjectIdentity) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .nameKey]
        var result: [URL] = []
        for directory in projectLibraryLogDirectories(identity: identity) {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
            ) else { continue }
            result.append(contentsOf: entries.filter { url in
                guard url.pathExtension.lowercased() == "log" else { return false }
                let values = try? url.resourceValues(forKeys: Set(keys))
                return values?.isSymbolicLink != true && values?.isRegularFile != false
            })
        }
        return result
    }

    private static func diagnosticReportCandidates(withinDays: Int, identity: LogProjectIdentity) -> [URL] {
        let directory = diagnosticReportsDirectory()
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .nameKey,
                                      .contentModificationDateKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }
        let cutoff: Date? = withinDays > 0 ? Date().addingTimeInterval(-Double(withinDays) * 86_400) : nil
        return entries.filter { url in
            guard url.pathExtension.lowercased() == "ips" else { return false }
            // 先按归属过滤再读内容：DiagnosticReports 是全机共用目录，
            // 绝大多数文件属于本机其他应用，规约禁止读取（AGENTS.md 禁区）。
            guard isOwnDiagnosticReport(url, identity: identity) else { return false }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isSymbolicLink != true, values?.isRegularFile != false else { return false }
            guard let cutoff else { return true }
            guard let modified = values?.contentModificationDate else { return false }
            return modified >= cutoff
        }
    }

    /// 崩溃报告归属规则（明确定死，不再隐式混合）：
    ///
    /// **只认「报告主名 ∈ 项目身份令牌」整段相等**，不做子串匹配。
    /// Apple 的报告名形如 `TcoderMonitor-2026-09-19-081233.ips`，主名是日期前的那一段；
    /// 令牌来自 `LogProjectIdentity`（锚点名 + 项目自己声明的产品名），
    /// 与"从哪个目录添加项目"无关 —— 整改前用 `lastPathComponent`，
    /// 于是扫根与扫子目录会各自漏掉对方那份报告（RD-23）。
    ///
    /// 因此项目叫 "Tcoder" **不会**再把本工具自己（`TcoderMonitor`）的崩溃报告混进来，
    /// 除非它在 `Package.swift` 里确实声明了这个产品名（那种情况下它就是同一个项目）。
    static func isOwnDiagnosticReport(_ url: URL, identity: LogProjectIdentity) -> Bool {
        let tokens = identity.attributionTokens.filter { $0.count >= 3 }
        guard tokens.isEmpty == false else { return false }
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        // 主名 = 第一个「-20xx-」日期段之前的部分；取不到就整串当主名。
        let head = name.range(of: "-20[0-9][0-9]-", options: .regularExpression).map { range in
            String(name[..<range.lowerBound])
        } ?? name
        return tokens.contains(head)
    }

    private static func isLogFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if rejectedExtensions.contains(ext) { return false }
        if logExtensions.contains(ext) { return true }
        if crashExtensions.contains(ext) { return true }
        let parent = url.deletingLastPathComponent().lastPathComponent.lowercased()
        guard parent == "logs" else { return false }
        // 只有在 Logs/ 目录里 txt 才算日志，避免把满树的 README.txt 吞进来
        if ext == "txt" || ext == "err" || ext == "trace" || ext == "logrotate" { return true }
        return ext.isEmpty
    }

    private static func isSkippedDirectory(_ url: URL, root: URL) -> Bool {
        if skippedDirectoryNames.contains(url.lastPathComponent) { return true }
        let relative = relativePath(of: url, root: root)
        for skipped in skippedRelativePaths where relative == skipped || relative.hasPrefix(skipped + "/") {
            return true
        }
        return false
    }

    private static func relativePath(of url: URL, root: URL) -> String {
        let path = url.path
        let base = root.path
        guard path.hasPrefix(base) else { return path }
        let trimmed = path.dropFirst(base.count)
        return trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : String(trimmed)
    }

    private static func canonicalPath(of url: URL) -> String {
        // resolvingSymlinksInPath 顺带把 /private/var 这类系统别名归一，去重因此更准
        return url.resolvingSymlinksInPath().path
    }

    static func libraryLogsDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment[libraryLogsDirectoryOverrideKey],
           override.isEmpty == false {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
    }

    private struct FileAttributes {
        var sizeBytes: Int64 = 0
        var modifiedAt: Date?
        var isFile: Bool = true
    }

    private static func attributes(of url: URL) -> FileAttributes {
        var result = FileAttributes()
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            result.isFile = false
            return result
        }
        if let number = attrs[.size] as? NSNumber { result.sizeBytes = number.int64Value }
        result.modifiedAt = attrs[.modificationDate] as? Date
        if let type = attrs[.type] as? FileAttributeType, type != .typeRegular { result.isFile = false }
        return result
    }
}
