// 依赖清单解析 · Maven pom.xml + Gradle build.gradle(.kts)（WS-B）
//
// 含 pom 的 XMLParser 中间模型（properties / dependencyManagement 版本代入）。
// 本文件用到 groups[safe:]，故自带一份 fileprivate 的 Array 安全下标，不外溢到模块。
import Foundation

// MARK: - Maven / pom.xml

extension ManifestParsers {
    /// pom.xml -> [DependencyRecord]。name 为 "groupId:artifactId"；
    /// `<properties>` 与 dependencyManagement 的版本会代入实际 dependencies 条目，
    /// 代不了就保留原文，完全解不出来版本时填 "未声明"。
    static func pomXMLDependencies(_ text: String, manifestPath: String) -> [DependencyRecord] {
        let model = PomDocumentModel(text: text)
        return dedupe(model.dependencyRecords(manifestPath: manifestPath))
    }
}

// MARK: - Gradle / build.gradle(.kts)

extension ManifestParsers {
    private static let gradleConfigScopes: [String: DependencyScope] = [
        "implementation": .runtime,
        "api": .runtime,
        "compile": .runtime,
        "runtime": .runtime,
        "runtimeonly": .runtime,
        "classpath": .runtime,
        "debugimplementation": .runtime,
        "releaseimplementation": .runtime,
        "testimplementation": .test,
        "testruntimeonly": .test,
        "testcompileonly": .test,
        "testannotationprocessor": .test,
        "androidtestimplementation": .test,
        "androidtestruntimeonly": .test,
        "androidtestannotationprocessor": .test,
        "kapttest": .test,
        "kaptandroidtest": .test,
        "compileonly": .build,
        "kapt": .build,
        "annotationprocessor": .build,
        "corelibrarydesugaring": .build,
        "detekt": .build,
        "spotless": .build,
    ]

    static func gradleScope(for configuration: String) -> DependencyScope? {
        let key = configuration.lowercased()
        if let known = gradleConfigScopes[key] { return known }
        let isTest = key.contains("test") || key.contains("spec")
        if key.hasSuffix("implementation") || key.hasSuffix("api") { return isTest ? .test : .runtime }
        if key.hasSuffix("classpath") { return .runtime }
        if key.hasSuffix("only") { return key.contains("runtime") ? .runtime : (isTest ? .test : .build) }
        if key.hasPrefix("kapt") || key.contains("processor") { return isTest ? .test : .build }
        return nil
    }

    /// build.gradle / build.gradle.kts / settings.gradle(.kts) -> [DependencyRecord]。
    static func gradleDependencies(_ text: String, manifestPath: String) -> [DependencyRecord] {
        let body = lines(text).map { stripSlashComment($0) }.joined(separator: "\n")
        var records: [DependencyRecord] = []

        // 1) 配置名 + 字符串坐标：implementation 'g:a:v' / api("g:a:v") / implementation platform("g:a:v")
        let coordinatePattern = "\\b([A-Za-z][A-Za-z0-9_]*)\\s*\\(?\\s*(?:platform\\s*\\(\\s*)?(['\"])([^'\"\\n]+)\\2"
        for groups in matches(of: coordinatePattern, in: body) {
            guard let configuration = groups[safe: 1], let coordinate = groups[safe: 3],
                  let scope = gradleScope(for: configuration) else { continue }
            guard let (name, version) = gradleCoordinate(coordinate) else { continue }
            records.append(record(name, version, .gradle, scope, manifestPath))
        }

        // 2) map 写法：implementation group: 'g', name: 'a', version: 'v'
        let mapPattern = "\\b([A-Za-z][A-Za-z0-9_]*)\\s*\\(?\\s*group\\s*:\\s*(['\"])([^'\"\\n]+)\\2"
            + "\\s*,\\s*name\\s*:\\s*(['\"])([^'\"\\n]+)\\4\\s*(?:,\\s*version\\s*:\\s*(['\"])([^'\"\\n]+)\\6)?"
        for groups in matches(of: mapPattern, in: body) {
            guard let configuration = groups[safe: 1], let group = groups[safe: 3], let artifact = groups[safe: 5],
                  let scope = gradleScope(for: configuration) else { continue }
            let version = groups[safe: 7] ?? undeclaredVersion
            records.append(record("\(group):\(artifact)", version, .gradle, scope, manifestPath))
        }

        // 3) 版本目录：library("别名", "g:a:v")（现代 Gradle 真正的版本只写在这里）
        let catalogPattern = "\\blibrary\\s*\\(\\s*(['\"])([^'\"\\n]+)\\1\\s*,\\s*(['\"])([^'\"\\n]+)\\3"
        for groups in matches(of: catalogPattern, in: body) {
            guard let coordinate = groups[safe: 4], let (name, version) = gradleCoordinate(coordinate) else { continue }
            records.append(record(name, version, .gradle, .runtime, manifestPath))
        }

        // 4) 插件声明：id("org.springframework.boot") version "3.2.0" / kotlin("jvm") version "1.9.22"
        let pluginPattern = "\\b(?:id|kotlin)\\s*\\(?\\s*(['\"])([A-Za-z0-9_.\\-]+)\\1\\s*\\)?\\s+version\\s+(['\"])([^'\"\\n]+)\\3"
        for groups in matches(of: pluginPattern, in: body) {
            guard let rawID = groups[safe: 2], let version = groups[safe: 4] else { continue }
            let name = rawID.contains(".") ? rawID : "org.jetbrains.kotlin.\(rawID)"
            records.append(record(name, version, .gradle, .build, manifestPath))
        }
        return dedupe(records)
    }

    /// "g:a:v" / "g:a" / "g:a:v@jar" / "g:a:v:classifier" -> (name, version)；不像坐标返回 nil。
    static func gradleCoordinate(_ raw: String) -> (name: String, version: String)? {
        let coordinate = trim(raw)
        if coordinate.isEmpty || coordinate.contains("://") || coordinate.contains(" ") { return nil }
        if coordinate.hasPrefix("/") || coordinate.hasPrefix("\\") { return nil }
        let parts = coordinate.split(separator: ":", omittingEmptySubsequences: false)
            .map { component -> String in
                guard let at = component.firstIndex(of: "@") else { return String(component) }
                return String(component[..<at])
            }
        guard parts.count >= 2 else { return nil }
        let group = parts[0]
        let artifact = parts[1]
        guard group.contains(where: { $0.isLetter }), artifact.contains(where: { $0.isLetter }) else { return nil }
        let version = parts.count >= 3 && !parts[2].isEmpty ? parts[2] : undeclaredVersion
        return ("\(group):\(artifact)", version)
    }
}

// MARK: - pom.xml 中间模型

/// pom.xml 的中间模型：`<properties>` 表 + dependencyManagement 版本表 + 真实依赖条目。
/// 用 XMLParser 走一遍，命名空间前缀会被剥掉；解析中断就返回已收集到的部分，不抛异常。
private final class PomDocumentModel: NSObject, XMLParserDelegate {
    struct Entry {
        var group = ""
        var artifact = ""
        var version = ""
        var scope = ""
        var fromPlugin = false
    }

    private var properties: [String: String] = [:]
    private var rootGroup = ""
    private var rootArtifact = ""
    private var rootVersion = ""
    private var parentGroup = ""
    private var parentVersion = ""
    private var entries: [Entry] = []
    private var managedEntries: [Entry] = []
    private var stack: [String] = []
    private var characters = ""

    init(text: String) {
        super.init()
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard let data = normalized.data(using: .utf8) else { return }
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        let name = Self.localName(elementName)
        stack.append(name)
        characters = ""
        if name == "dependency" {
            var entry = Entry()
            entry.fromPlugin = stack.contains("plugin") || stack.contains("plugins")
            if stack.contains("dependencyManagement") {
                managedEntries.append(entry)
            } else {
                entries.append(entry)
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        characters += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let name = Self.localName(elementName)
        let value = characters.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = stack.count >= 2 ? stack[stack.count - 2] : ""
        if !value.isEmpty { route(name: name, parent: parent, value: value) }
        if !stack.isEmpty { stack.removeLast() }
        characters = ""
    }

    private func route(name: String, parent: String, value: String) {
        if parent == "dependency" {
            let inManagement = stack.contains("dependencyManagement")
            var list = inManagement ? managedEntries : entries
            guard !list.isEmpty, var entry = list.popLast() else { return }
            switch name {
            case "groupId": entry.group = value
            case "artifactId": entry.artifact = value
            case "version": entry.version = value
            case "scope": entry.scope = value
            default: return
            }
            list.append(entry)
            if inManagement { managedEntries = list } else { entries = list }
            return
        }
        if parent == "properties" {
            properties[name] = value
            return
        }
        if parent == "parent" {
            if name == "groupId" { parentGroup = value }
            if name == "version" { parentVersion = value }
            return
        }
        if stack.count == 2 {
            switch name {
            case "groupId": rootGroup = value
            case "artifactId": rootArtifact = value
            case "version": rootVersion = value
            default: break
            }
        }
    }

    private static func localName(_ elementName: String) -> String {
        elementName.split(separator: ":").last.map(String.init) ?? elementName
    }

    // MARK: 属性代入

    /// `${xxx.version}` / `${project.version}` 代入；代不了的那一段保留原文。
    private func resolve(_ raw: String, depth: Int = 0) -> String {
        guard depth < 3, raw.contains("${") else { return raw }
        let chars = Array(raw)
        var result = ""
        var index = 0
        while index < chars.count {
            if chars[index] == "$", index + 1 < chars.count, chars[index + 1] == "{" {
                var end = index + 2
                while end < chars.count, chars[end] != "}" { end += 1 }
                if end < chars.count {
                    let key = String(chars[(index + 2)..<end])
                    if let value = substitution(for: key) {
                        result += resolve(value, depth: depth + 1)
                    } else {
                        result += String(chars[index...end])
                    }
                    index = end + 1
                    continue
                }
            }
            result.append(chars[index])
            index += 1
        }
        return result
    }

    private func substitution(for key: String) -> String? {
        if let hit = properties[key], !hit.isEmpty { return hit }
        switch key {
        case "project.version", "version":
            let candidate = rootVersion.isEmpty ? parentVersion : rootVersion
            return candidate.isEmpty ? nil : candidate
        case "project.groupId", "groupId":
            let candidate = rootGroup.isEmpty ? parentGroup : rootGroup
            return candidate.isEmpty ? nil : candidate
        case "project.artifactId", "artifactId":
            return rootArtifact.isEmpty ? nil : rootArtifact
        case "project.parent.version":
            return parentVersion.isEmpty ? nil : parentVersion
        case "project.parent.groupId":
            return parentGroup.isEmpty ? nil : parentGroup
        default:
            return nil
        }
    }

    // MARK: 出结果

    func dependencyRecords(manifestPath: String) -> [DependencyRecord] {
        var managedVersions: [String: String] = [:]
        for item in managedEntries {
            let group = resolve(item.group.isEmpty ? rootGroup : item.group)
            let artifact = resolve(item.artifact)
            let version = resolve(item.version)
            guard !group.isEmpty, !artifact.isEmpty, !version.isEmpty else { continue }
            managedVersions["\(group):\(artifact)"] = version
        }

        var records: [DependencyRecord] = []
        for item in entries {
            let group = resolve(item.group.isEmpty ? rootGroup : item.group)
            let artifact = resolve(item.artifact)
            guard !artifact.isEmpty else { continue }
            var version = resolve(item.version)
            if version.isEmpty { version = resolve(managedVersions["\(group):\(artifact)"] ?? "") }
            if version.isEmpty { version = ManifestParsers.undeclaredVersion }
            let scope: DependencyScope
            if item.fromPlugin && item.scope.isEmpty {
                scope = .build
            } else {
                switch item.scope.lowercased() {
                case "test": scope = .test
                case "provided": scope = .platform
                default: scope = .runtime
                }
            }
            let name = group.isEmpty ? artifact : "\(group):\(artifact)"
            records.append(ManifestParsers.record(name, version, .maven, scope, manifestPath))
        }
        return ManifestParsers.dedupe(records)
    }
}

// MARK: - 下标安全访问（各文件各自 fileprivate，不外溢到模块）

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
