// 依赖清单解析 · SwiftPM Package.swift + CocoaPods Podfile（WS-B）
import Foundation

// MARK: - Swift Package Manager / Package.swift

extension ManifestParsers {
    /// Package.swift -> [DependencyRecord]，scope 全为 .runtime。`.package(path:)` 是本地模块，不计入。
    static func swiftPackageDependencies(_ text: String, manifestPath: String) -> [DependencyRecord] {
        let ns = text as NSString
        let needle = ".package("
        var records: [DependencyRecord] = []
        var searchStart = 0
        while searchStart < ns.length {
            let window = NSRange(location: searchStart, length: ns.length - searchStart)
            let found = ns.range(of: needle, options: [], range: window)
            if found.location == NSNotFound { break }
            let argumentsStart = found.location + found.length
            guard let argumentsLength = closingArgumentsLength(after: argumentsStart, in: ns) else {
                searchStart = argumentsStart
                continue
            }
            let arguments = ns.substring(with: NSRange(location: argumentsStart, length: argumentsLength))
            searchStart = argumentsStart + argumentsLength
            let body = stripSlashComment(arguments)
            if let entry = swiftPackageEntry(body) {
                records.append(record(entry.name, entry.version, .swiftPM, .runtime, manifestPath))
            }
        }
        return dedupe(records)
    }

    /// 从 `.package(` 之后扫描配对括号，返回参数文本长度；括号不配对返回 nil。
    static func closingArgumentsLength(after start: Int, in ns: NSString) -> Int? {
        var depth = 1
        var quote: unichar = 0
        var index = start
        while index < ns.length {
            let ch = ns.character(at: index)
            if quote != 0 {
                if ch == quote { quote = 0 }
                index += 1
                continue
            }
            if ch == 34 || ch == 39 { quote = ch }
            else if ch == 40 { depth += 1 }
            else if ch == 41 {
                depth -= 1
                if depth == 0 { return index - start + 1 }
            }
            index += 1
        }
        return nil
    }

    static func swiftPackageEntry(_ arguments: String) -> (name: String, version: String)? {
        let url = firstGroup("url\\s*:\\s*(['\"])([^'\"\\n]+)\\1", 2, in: arguments)
        let identifier = firstGroup("\\bid\\s*:\\s*(['\"])([^'\"\\n]+)\\1", 2, in: arguments)
        let declaredName = firstGroup("(?:^|[^A-Za-z])name\\s*:\\s*(['\"])([^'\"\\n]+)\\1", 2, in: arguments)
        if firstGroup("path\\s*:\\s*(['\"])([^'\"\\n]+)\\1", 2, in: arguments) != nil, url == nil, identifier == nil {
            return nil // 本地路径依赖
        }
        var version = firstGroup("\\bfrom\\s*:\\s*(['\"])([^'\"\\n]+)\\1", 2, in: arguments)
        version = version ?? firstGroup("\\bexact\\s*:\\s*(['\"])([^'\"\\n]+)\\1", 2, in: arguments)
        version = version ?? firstGroup("(['\"])([0-9][^'\"\\s]*)\\1\\s*\\.\\.\\.", 2, in: arguments)
        version = version ?? firstGroup("\\brevision\\s*:\\s*(['\"])([^'\"\\n]+)\\1", 2, in: arguments)
        version = version ?? firstGroup("\\bbranch\\s*:\\s*(['\"])([^'\"\\n]+)\\1", 2, in: arguments)

        let name: String
        if let declaredName, !declaredName.isEmpty {
            name = declaredName
        } else if let url, !url.isEmpty {
            name = swiftPackageBasename(url)
        } else if let identifier, !identifier.isEmpty {
            name = identifier
        } else {
            return nil
        }
        guard !name.isEmpty else { return nil }
        return (name, version ?? undeclaredVersion)
    }

    /// URL -> 包名：末段去掉 .git
    static func swiftPackageBasename(_ rawURL: String) -> String {
        var value = trim(rawURL)
        if let hash = value.firstIndex(of: "#") { value = String(value[..<hash]) }
        if let query = value.firstIndex(of: "?") { value = String(value[..<query]) }
        while value.hasSuffix("/") { value = String(value.dropLast()) }
        var last = value
        if let slash = last.lastIndex(of: "/") { last = String(last[last.index(after: slash)...]) }
        if last.lowercased().hasSuffix(".git") { last = String(last.dropLast(4)) }
        return last
    }
}

// MARK: - CocoaPods / Podfile

extension ManifestParsers {
    /// Podfile -> [DependencyRecord]。`target 'Tests'` 段内或带 `:testables` 的记为 .test。
    /// 逐行骨架走 `rubyStyleDependencies`（与 Gemfile 共用一份），这里只给 Podfile 的三个钩子。
    static func podfileDependencies(_ text: String, manifestPath: String) -> [DependencyRecord] {
        rubyStyleDependencies(text, manifestPath: manifestPath, walk: RubyStyleWalk(
            isEntry: { $0.hasPrefix("pod ") || $0.hasPrefix("pod(")
                || $0.hasPrefix("pod '") || $0.hasPrefix("pod \"") },
            entryScope: { line, inherited in
                (line.contains("testables") || inherited == .test) ? DependencyScope.test : inherited
            },
            isGroup: { _ in false },
            groupScope: { _ in .runtime },
            opensBlock: { opensBlock($0) },
            blockScope: { line, inherited in blockScope(line) ?? inherited },
            ecosystem: .cocoapods
        ))
    }

    static func blockScope(_ line: String) -> DependencyScope? {
        let haystack = (quotedStrings(line) + [line]).map { $0.lowercased() }
        guard haystack.contains(where: { $0.contains("test") || $0.contains("spec") }) else { return nil }
        return .test
    }

    static func opensBlock(_ line: String) -> Bool {
        line.hasSuffix(" do") || line.contains(" do ") || line.hasSuffix(" {")
    }

    static func quotedStrings(_ line: String) -> [String] {
        matches(of: "(['\"])([^'\"\\n]+)\\1", in: line).compactMap { ManifestParsers.value(at: 2, in: $0) }
    }

    /// 从若干候选串里挑出第一个看着像版本约束的（"~> 1.2"、">= 0.9"、"1.2.3"）。
    static func versionConstraint(from candidates: [String]) -> String? {
        for candidate in candidates {
            let value = trim(candidate)
            if value.isEmpty || value.hasPrefix(":") || value.contains("=>") { continue }
            guard let first = value.first else { continue }
            if first.isNumber || first == "~" || first == ">" || first == "<" || first == "=" {
                return value
            }
        }
        return nil
    }
}
