//
// 日志发现：项目内递归 + ~/Library/Logs/<项目名> + 本 App 自己的 DiagnosticReports
//
// 从 LogParsing.swift 拆出：只为控制单文件长度，语义与拆分前完全一致。
//
import Foundation

// MARK: - 日志发现

// MARK: - 日志发现

enum LogDiscovery {

    /// 项目内发现 + ~/Library/Logs/<项目名>/ + ~/Library/Logs/DiagnosticReports/*.ips
    static func discover(projectRoot: URL, projectName: String, withinDays: Int, maxFiles: Int) -> [DiscoveredLog] {
        guard maxFiles > 0 else { return [] }
        var unique: [String: DiscoveredLog] = [:]

        func register(_ url: URL) {
            let key = canonicalPath(of: url)
            guard unique[key] == nil else { return }
            let values = attributes(of: url)
            guard values.isFile else { return }
            let modified = values.modifiedAt ?? Date.distantPast
            unique[key] = DiscoveredLog(url: URL(fileURLWithPath: key),
                                        role: role(for: url, in: projectRoot),
                                        sizeBytes: values.sizeBytes,
                                        modifiedAt: modified)
        }

        for url in projectLogCandidates(root: projectRoot) { register(url) }
        for url in libraryLogCandidates(projectName: projectName) { register(url) }
        for url in diagnosticReportCandidates(withinDays: withinDays, projectName: projectName) { register(url) }

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

    static func projectLibraryLogDirectory(projectName: String) -> URL {
        let trimmed = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "Tcoder" : trimmed
        return libraryLogsDirectory().appendingPathComponent(name, isDirectory: true)
    }

    // MARK: 发现细节

    static let maxDepth = 6
    static let directoryBudget = 4_000
    static let entryBudget = 60_000

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

    private static func projectLogCandidates(root: URL) -> [URL] {
        var result: [URL] = []
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return result }

        struct Frame { var url: URL; var depth: Int }
        var stack: [Frame] = [Frame(url: root, depth: 0)]
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .nameKey]
        var directoriesLeft = directoryBudget
        var entriesLeft = entryBudget

        while let frame = stack.popLast() {
            guard directoriesLeft > 0, entriesLeft > 0 else { break }
            directoriesLeft -= 1
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: frame.url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
            ) else { continue }

            for entry in entries {
                entriesLeft -= 1
                if entriesLeft <= 0 { break }
                let values = try? entry.resourceValues(forKeys: Set(keys))
                // 符号链接既不跟随也不读取：不会成环，也不会顺链接逃到仓库外的资产目录
                if values?.isSymbolicLink == true { continue }

                if values?.isDirectory == true {
                    if frame.depth >= maxDepth { continue }
                    if isSkippedDirectory(entry, root: root) { continue }
                    stack.append(Frame(url: entry, depth: frame.depth + 1))
                    continue
                }
                if values?.isRegularFile == false { continue }
                if isLogFile(entry) { result.append(entry) }
            }
        }
        return result
    }

    private static func libraryLogCandidates(projectName: String) -> [URL] {
        let directory = projectLibraryLogDirectory(projectName: projectName)
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .nameKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.filter { url in
            guard url.pathExtension.lowercased() == "log" else { return false }
            let values = try? url.resourceValues(forKeys: Set(keys))
            return values?.isSymbolicLink != true && values?.isRegularFile != false
        }
    }

    private static func diagnosticReportCandidates(withinDays: Int, projectName: String) -> [URL] {
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
            guard isOwnDiagnosticReport(url, projectName: projectName) else { return false }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isSymbolicLink != true, values?.isRegularFile != false else { return false }
            guard let cutoff else { return true }
            guard let modified = values?.contentModificationDate else { return false }
            return modified >= cutoff
        }
    }

    /// 崩溃报告归属规则（明确定死，不再隐式混合）：
    ///
    /// **只认「报告主名 == 被监控项目名」整段相等**，不做子串匹配。
    /// Apple 的报告名形如 `TcoderMonitor-2026-09-19-081233.ips`，主名是日期前的那一段；
    /// 只有它整体等于项目名（不区分大小写）才算这个项目的崩溃。
    ///
    /// 因此项目叫 "Tcoder" **不会**再把本工具自己（`TcoderMonitor`）的崩溃报告混进来 ——
    /// 之前用前缀子串匹配时两者会互相命中。想看本工具自身健康，就把它的构建目录作为
    /// 一个独立项目添加（项目名就是 `TcoderMonitor`），归属仍然显式。
    static func isOwnDiagnosticReport(_ url: URL, projectName: String) -> Bool {
        let token = projectName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard token.count >= 3 else { return false }
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        // 主名 = 第一个「-20xx-」日期段之前的部分；取不到就整串当主名。
        let head = name.range(of: "-20[0-9][0-9]-", options: .regularExpression).map { range in
            String(name[..<range.lowerBound])
        } ?? name
        return head == token
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

    private static func libraryLogsDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
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
