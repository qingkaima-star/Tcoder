// 依赖清单解析 · Ruby Gemfile 与 .NET packages.config（WS-B）
import Foundation

// MARK: - Ruby / Gemfile

extension ManifestParsers {
    /// Gemfile -> [DependencyRecord]。`group :test / :development / :production` 段影响 scope。
    static func gemfileDependencies(_ text: String, manifestPath: String) -> [DependencyRecord] {
        var records: [DependencyRecord] = []
        var depth = 0
        var scopes: [DependencyScope] = []
        for rawLine in lines(text) {
            let line = trim(stripHashComment(rawLine))
            if line.isEmpty { continue }
            if line == "end" || line.hasPrefix("end ") {
                if depth > 0 { depth -= 1 }
                while scopes.count > depth { scopes.removeLast() }
                continue
            }
            let inherited = scopes.last ?? .runtime
            if line.hasPrefix("gem ") || line.hasPrefix("gem(") || line.hasPrefix("gem '") || line.hasPrefix("gem \"") {
                let strings = quotedStrings(line)
                guard let name = strings.first, !name.isEmpty else { continue }
                let scope = gemInlineScope(line) ?? inherited
                let version = versionConstraint(from: Array(strings.dropFirst())) ?? undeclaredVersion
                records.append(record(name, version, .ruby, scope, manifestPath))
                continue
            }
            if line.hasPrefix("group ") {
                depth += 1
                scopes.append(gemGroupScope(line))
                continue
            }
            if opensBlock(line) || line.hasPrefix("if ") {
                depth += 1
                scopes.append(inherited)
            }
        }
        return dedupe(records)
    }

    static func gemGroupScope(_ line: String) -> DependencyScope {
        let symbols = matches(of: ":([A-Za-z0-9_]+)", in: line)
            .compactMap { ManifestParsers.value(at: 1, in: $0) }
            .map { $0.lowercased() }
        return rubyScope(forGroups: symbols)
    }

    /// group 名到 scope 的容错映射（:test/:tests/:spec -> 测试，:dev/:style/:lint/:typecheck/:doc -> 开发）。
    static func rubyScope(forGroups symbols: [String]) -> DependencyScope {
        for symbol in symbols {
            if symbol.contains("test") || symbol.contains("spec") { return .test }
        }
        let devHints = ["dev", "lint", "style", "typecheck", "doc", "check", "audit", "quality", "format", "debug", "tool"]
        for symbol in symbols where devHints.contains(where: { symbol.contains($0) }) { return .dev }
        return .runtime
    }

    static func gemInlineScope(_ line: String) -> DependencyScope? {
        guard let body = firstGroup("groups?\\s*:\\s*\\[([^\\]]*)\\]", 1, in: line) else { return nil }
        let symbols = matches(of: ":([A-Za-z0-9_]+)", in: body)
            .compactMap { ManifestParsers.value(at: 1, in: $0) }
            .map { $0.lowercased() }
        guard !symbols.isEmpty else { return nil }
        return rubyScope(forGroups: symbols)
    }
}

// MARK: - NuGet / packages.config

extension ManifestParsers {
    /// packages.config -> [DependencyRecord]。developmentDependency="true" 记为 .dev。
    static func nugetPackagesConfigDependencies(_ text: String, manifestPath: String) -> [DependencyRecord] {
        var records: [DependencyRecord] = []
        for groups in matches(of: "<package\\b([^>]*?)/?>", in: text) {
            guard let attributes = groups[safe: 1] else { continue }
            guard let name = nugetAttribute("id", in: attributes), !name.isEmpty else { continue }
            let version = nugetAttribute("version", in: attributes) ?? undeclaredVersion
            let development = (nugetAttribute("developmentDependency", in: attributes) ?? "").lowercased() == "true"
            records.append(record(name, version, .nuget, development ? .dev : .runtime, manifestPath))
        }
        return dedupe(records)
    }

    static func nugetAttribute(_ key: String, in attributes: String) -> String? {
        firstGroup("(?<![A-Za-z0-9_])\(key)\\s*=\\s*(['\"])([^'\"\\n]*)\\1", 2, in: attributes)
    }
}

// MARK: - 下标安全访问（各文件各自 fileprivate，不外溢到模块）

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
