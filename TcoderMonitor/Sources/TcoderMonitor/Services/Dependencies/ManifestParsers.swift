// MARK: - 依赖清单解析（WS-B 依赖工作流）
//
// 依赖清单解析的公共层（WS-B）：结果类型、文件名->生态、按生态分派的唯一入口，
// 以及各生态解析器共用的词法工具、框架标记规则表与锁文件候选表。
// 各生态的具体解析按文件拆开放在这里：
//   ManifestParsersNpm / Java(maven+gradle) / Apple(SwiftPM+Podfile) / Python /
//   Native(go+cargo) / Scripting(Gemfile+packages.config)
// 全部仍是纯函数：不做网络查询、不猜最新版本、不查漏洞 ——
// latestKnownVersion / versionCheckSource / knownVulnerabilities 一律留空，
// 由 ManifestDependencyAnalyzer 结合内置快照统一回填。
//
// 所有解析器都是纯函数：给文本、返回结果，解析失败返回空数组或 nil，绝不抛异常。

import Foundation

// MARK: - 解析结果

/// 一份清单文件的解析结果。
struct ParsedManifest: Equatable, Sendable {
    var ecosystem: DependencyEcosystem
    /// 相对项目根，例如 "frontend/package.json"
    var manifestRelativePath: String
    /// 清单所在目录相对根，根目录用 ""
    var directoryRelativePath: String
    var dependencies: [DependencyRecord]
    /// 同目录发现到的锁文件名，没有则 nil
    var lockfileName: String?
    /// 用户看得懂的名字，如 "React"、"Spring Boot"
    var frameworkMarkers: [String]
}

// MARK: - 清单文件名 -> 生态

enum ManifestFileName {
    /// 文件名 -> 生态。覆盖 DependencyEcosystem.manifestNames 里的全部名字。
    private static let table: [String: DependencyEcosystem] = [
        "package.json": .npm,
        "pom.xml": .maven,
        "build.gradle": .gradle,
        "build.gradle.kts": .gradle,
        "settings.gradle": .gradle,
        "settings.gradle.kts": .gradle,
        "Package.swift": .swiftPM,
        "requirements.txt": .python,
        "pyproject.toml": .python,
        "setup.py": .python,
        "Pipfile": .python,
        "go.mod": .go,
        "Cargo.toml": .cargo,
        "Podfile": .cocoapods,
        "Gemfile": .ruby,
        "packages.config": .nuget,
    ]

    static func ecosystem(for fileName: String) -> DependencyEcosystem? {
        let name = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = table[name] { return exact }
        // requirements-*.txt / dev-requirements.txt 这类派生名也归入 python
        let lower = name.lowercased()
        if lower.hasPrefix("requirements") && lower.hasSuffix(".txt") { return .python }
        return nil
    }

    static var allManifestNames: Set<String> { Set(table.keys) }
}

// MARK: - 总入口

enum ManifestParsers {
    /// 未声明版本时统一用的占位串。
    static let undeclaredVersion = "未声明"

    /// 唯一的总入口：按 manifest 文件名分派到对应格式解析器。
    /// 无法识别的文件名、内容为空、或解不出任何依赖时返回 nil（不抛异常、不崩溃）。
    static func parse(text: String,
                      manifestPath: String,
                      directoryRelativePath: String,
                      directoryListing: Set<String>) -> ParsedManifest? {
        let fileName = fileName(of: manifestPath)
        guard let ecosystem = ManifestFileName.ecosystem(for: fileName) else { return nil }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let raw = dependencies(for: ecosystem,
                               fileName: fileName,
                               text: text,
                               manifestPath: manifestPath)

        let dependencies = dedupe(raw)
        guard !dependencies.isEmpty else { return nil }
        return ParsedManifest(
            ecosystem: ecosystem,
            manifestRelativePath: manifestPath,
            directoryRelativePath: directoryRelativePath,
            dependencies: dependencies,
            lockfileName: lockfileName(for: ecosystem, in: directoryListing),
            frameworkMarkers: frameworkMarkers(ecosystem: ecosystem, dependencyNames: dependencies.map(\.name))
        )
    }

    /// pom.xml 里 <modules><module>x</module></modules> 抽出的相对模块目录名（多模块工程递归用）。
    static func mavenModulePaths(in pomText: String) -> [String] {
        var found: [String] = []
        var seen = Set<String>()
        for groups in matches(of: "<module>\\s*([^<]*?)\\s*</module>", in: pomText) {
            guard let raw = groups.last else { continue }
            let value = trim(raw)
            if value.isEmpty || value == "." { continue }
            if seen.insert(value).inserted { found.append(value) }
        }
        return found
    }

    /// 生态 -> 该生态的清单解析器。`parse` 只做「认文件 + 收尾」，分派表单独一处，
    /// 这样 11 个 `case` 的判定成本全落在这个函数里，`parse` 自己回到个位数复杂度。
    /// 每个分支调用的解析函数与拆分前**逐字相同**，包含 `.unknown` 返回空数组这一条
    /// （原先是 `return nil` 直接结束 `parse`，现在由「去重后为空 -> nil」接住，
    /// 结果同样是 nil：`.unknown` 走不到 `ManifestFileName.ecosystem(for:)` 的成功分支）。
    static func dependencies(for ecosystem: DependencyEcosystem,
                             fileName: String,
                             text: String,
                             manifestPath: String) -> [DependencyRecord] {
        switch ecosystem {
        case .npm:
            return packageJSONDependencies(text, manifestPath: manifestPath)
        case .maven:
            return pomXMLDependencies(text, manifestPath: manifestPath)
        case .gradle:
            return gradleDependencies(text, manifestPath: manifestPath)
        case .swiftPM:
            return swiftPackageDependencies(text, manifestPath: manifestPath)
        case .python:
            return pythonDependencies(fileName: fileName, text: text, manifestPath: manifestPath)
        case .go:
            return goModDependencies(text, manifestPath: manifestPath)
        case .cargo:
            return cargoTomlDependencies(text, manifestPath: manifestPath)
        case .cocoapods:
            return podfileDependencies(text, manifestPath: manifestPath)
        case .ruby:
            return gemfileDependencies(text, manifestPath: manifestPath)
        case .nuget:
            return nugetPackagesConfigDependencies(text, manifestPath: manifestPath)
        case .unknown:
            return []
        }
    }

    /// Python 系清单按文件名分流：`requirements*.txt` 走行式解析，其余走 pyproject/setup/Pipfile。
    static func pythonDependencies(fileName: String, text: String, manifestPath: String) -> [DependencyRecord] {
        let lower = fileName.lowercased()
        if lower.hasPrefix("requirements") && lower.hasSuffix(".txt") {
            return requirementsTxtDependencies(text, manifestPath: manifestPath)
        }
        return pyprojectDependencies(text, manifestPath: manifestPath)
    }
}

// MARK: - 内部通用工具

extension ManifestParsers {
    static func fileName(of path: String) -> String {
        (path as NSString).lastPathComponent
    }

    static func trim(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 统一换行后按行切开（不含换行符）。
    static func lines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    static func record(_ name: String,
                       _ version: String,
                       _ ecosystem: DependencyEcosystem,
                       _ scope: DependencyScope,
                       _ manifestPath: String) -> DependencyRecord {
        let cleanedName = trim(name)
        let cleanedVersion = trim(version)
        return DependencyRecord(
            name: cleanedName,
            version: cleanedVersion.isEmpty ? undeclaredVersion : cleanedVersion,
            ecosystem: ecosystem,
            scope: scope,
            manifestPath: manifestPath,
            latestKnownVersion: nil,
            versionCheckSource: VersionCheckSource.none,
            knownVulnerabilities: []
        )
    }

    /// 清单内按 name 去重，后出现的覆盖前者的取值（顺序按首次出现）。
    static func dedupe(_ records: [DependencyRecord]) -> [DependencyRecord] {
        var result: [DependencyRecord] = []
        var indexByName: [String: Int] = [:]
        for item in records {
            if let existing = indexByName[item.name] {
                result[existing] = item
            } else {
                indexByName[item.name] = result.count
                result.append(item)
            }
        }
        return result
    }

    /// 正则枚举，返回每条匹配的分组数组（下标 0 为整条匹配，未命中的分组为空串）。
    static func matches(of pattern: String,
                        in text: String,
                        options: NSRegularExpression.Options = []) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let ns = text as NSString
        var out: [[String]] = []
        regex.enumerateMatches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) { result, _, _ in
            guard let result else { return }
            var groups: [String] = []
            for index in 0..<result.numberOfRanges {
                let range = result.range(at: index)
                groups.append(range.location == NSNotFound ? "" : ns.substring(with: range))
            }
            out.append(groups)
        }
        return out
    }

    static func value(at index: Int, in groups: [String]) -> String? {
        guard index < groups.count else { return nil }
        let value = groups[index]
        return value.isEmpty ? nil : value
    }

    static func firstGroup(_ pattern: String, _ group: Int, in text: String) -> String? {
        for groups in matches(of: pattern, in: text) {
            if let value = value(at: group, in: groups) { return value }
        }
        return nil
    }

    static func replaceMatches(_ text: String, pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        return regex.stringByReplacingMatches(in: text, options: [],
                                              range: NSRange(location: 0, length: ns.length),
                                              withTemplate: template)
    }

    /// 去掉 `//` 行注释：`//` 只在引号外才算注释（避免误伤 "https://..."）。
    static func stripSlashComment(_ line: String) -> String {
        var inSingle = false
        var inDouble = false
        var result = ""
        let chars = Array(line)
        var index = 0
        while index < chars.count {
            let ch = chars[index]
            if ch == "'" && !inDouble { inSingle.toggle() }
            else if ch == "\"" && !inSingle { inDouble.toggle() }
            else if ch == "/" && !inSingle && !inDouble && index + 1 < chars.count && chars[index + 1] == "/" {
                break
            }
            result.append(ch)
            index += 1
        }
        return result
    }

    /// 去掉 `#` 注释：行首 `#` 或 空白后的 `#` 之后全部丢弃（引号内的 `#` 保留）。
    static func stripHashComment(_ line: String) -> String {
        let chars = Array(line)
        var inSingle = false
        var inDouble = false
        var index = 0
        while index < chars.count {
            let ch = chars[index]
            if ch == "'" && !inDouble { inSingle.toggle() }
            else if ch == "\"" && !inSingle { inDouble.toggle() }
            else if ch == "#" && !inSingle && !inDouble {
                if index == 0 { return "" }
                let prev = chars[index - 1]
                if prev == " " || prev == "\t" { return String(chars[0..<index]) }
            }
            index += 1
        }
        return line
    }

    // MARK: - Ruby 语法系清单（Podfile / Gemfile）共用的逐行扫描器

    /// Podfile 与 Gemfile 是同一套 Ruby 块语法，此前各自手写了一遍逐行扫描
    /// （工具点名的 15 行 87% 相似块就是这个）。这里把公共骨架收成一份，
    /// 差异全部下沉成 `RubyStyleWalk` 的六个钩子，每个钩子的表达式**逐字照抄原分支**：
    /// - `isEntry`：原 `pod ` / `gem ` 的四种前缀写法；
    /// - `entryScope`：Podfile 的 `testables` 判定 / Gemfile 的行内 `groups:` 判定；
    /// - `isGroup` + `groupScope`：只有 Gemfile 有 `group :test do` 这条专属分支；
    /// - `opensBlock`：Podfile 只看 ` do` / `{`，Gemfile 额外认 `if `；
    /// - `blockScope`：Podfile 用 `blockScope(line) ?? inherited`，Gemfile 原样继承。
    /// 判定顺序与拆分前两处完全一致：空行 → `end` → 声明行 → 组块 → 普通块。
    /// 其中「声明行前缀命中但包名为空」这一条原代码是 `continue`（不再往下看开块），
    /// 这里同样直接跳过本行，没有把它降级成「继续匹配后面的分支」。
    struct RubyStyleWalk {
        let isEntry: (String) -> Bool
        let entryScope: (String, DependencyScope) -> DependencyScope
        let isGroup: (String) -> Bool
        let groupScope: (String) -> DependencyScope
        let opensBlock: (String) -> Bool
        let blockScope: (String, DependencyScope) -> DependencyScope
        let ecosystem: DependencyEcosystem
    }

    static func rubyStyleDependencies(_ text: String,
                                      manifestPath: String,
                                      walk: RubyStyleWalk) -> [DependencyRecord] {
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
            if walk.isEntry(line) {
                if let entry = rubyStyleEntry(line, inherited: inherited, manifestPath: manifestPath, walk: walk) {
                    records.append(entry)
                }
                continue
            }
            if walk.isGroup(line) {
                depth += 1
                scopes.append(walk.groupScope(line))
                continue
            }
            if walk.opensBlock(line) {
                depth += 1
                scopes.append(walk.blockScope(line, inherited))
            }
        }
        return dedupe(records)
    }

    /// 声明行 -> 记录。取第一个引号串当包名、其余当版本约束，与拆分前两处逐字相同；
    /// 包名为空返回 nil（调用方照样 `continue`，与原行为一致）。
    static func rubyStyleEntry(_ line: String,
                               inherited: DependencyScope,
                               manifestPath: String,
                               walk: RubyStyleWalk) -> DependencyRecord? {
        let strings = quotedStrings(line)
        guard let name = strings.first, !name.isEmpty else { return nil }
        let scope = walk.entryScope(line, inherited)
        let version = versionConstraint(from: Array(strings.dropFirst())) ?? undeclaredVersion
        return record(name, version, walk.ecosystem, scope, manifestPath)
    }

}

// MARK: - 下标安全访问

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
