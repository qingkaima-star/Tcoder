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
        /// `<type>pom</type>` —— 与 `<scope>import</scope>` 同时出现就是**导入的 BOM**。
        var type = ""
        var fromPlugin = false
    }

    private var properties: [String: String] = [:]
    private var rootGroup = ""
    private var rootArtifact = ""
    private var rootVersion = ""
    private var parentGroup = ""
    private var parentVersion = ""
    /// RD-13b 的两条事实：**这份 pom 有没有父级**、**dependencyManagement 里导入了哪些 BOM**。
    /// 没有这两条，"这一栏没写版本"就只能被读成"项目没管理版本" —— 那是把好事报成坏事。
    private var hasParent = false
    private var importedBOMs = 0
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

    /// 叶子值按「父元素是谁」分派。三个分支的判定表达式逐字照抄拆分前的 `route`，
    /// 只是各自搬进了一个方法；调用顺序、`stack` 的读法、落空时的行为都没有变。
    private func route(name: String, parent: String, value: String) {
        if parent == "dependency" {
            routeDependency(name: name, value: value)
            return
        }
        if parent == "properties" {
            properties[name] = value
            return
        }
        if parent == "parent" {
            if name == "groupId" { parentGroup = value; hasParent = true }
            if name == "version" { parentVersion = value; hasParent = true }
            return
        }
        if stack.count == 2 {
            routeRootLevel(name: name, value: value)
        }
    }

    /// `<dependency>` 里的字段。`dependencyManagement` 内外是两个列表，
    /// 「列表为空就整条丢弃」这条 guard 与原实现一致（含 `popLast` 后再 `append` 回去的顺序）。
    private func routeDependency(name: String, value: String) {
        let inManagement = stack.contains("dependencyManagement")
        var list = inManagement ? managedEntries : entries
        guard !list.isEmpty, var entry = list.popLast() else { return }
        switch name {
        case "groupId": entry.group = value
        case "artifactId": entry.artifact = value
        case "version": entry.version = value
        case "scope": entry.scope = value
        case "type": entry.type = value
        default: return
        }
        list.append(entry)
        if inManagement { managedEntries = list } else { entries = list }
    }

    /// 根元素上直接挂的 `<groupId>` / `<artifactId>` / `<version>`（父 pom 自己的坐标）。
    private func routeRootLevel(name: String, value: String) {
        switch name {
        case "groupId": rootGroup = value
        case "artifactId": rootArtifact = value
        case "version": rootVersion = value
        default: break
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

    /// 一个写出来的版本栏到底"算不算读出了确切版本"。
    /// `${...}` 代不出来 ⇒ `.undeterminable`（**不许**当没写，也不许拿占位原文去比较）；
    /// 读得出 ⇒ `.explicit`。"整栏为空"这一支不在这里判 —— 那是调用方分三态的地方。
    private func declaredVersionState(for resolved: String, raw: String) -> DependencyDeclaredVersionState {
        if resolved.isEmpty && raw.isEmpty { return .notDeclared }
        return resolved.contains("${") ? .undeterminable : .explicit
    }

    /// 已看到的 BOM 导入数（测试与说明文案都读它，不再各数一遍 XML）。
    var importedBOMCount: Int { importedBOMs }
    var declaresParent: Bool { hasParent }

    func dependencyRecords(manifestPath: String) -> [DependencyRecord] {
        let managed = managedVersionTable()
        let built = entries.compactMap { record(for: $0, managed: managed, manifestPath: manifestPath) }
        return ManifestParsers.dedupe(built)
    }

    /// `dependencyManagement` 的版本表（顺带把导入型 BOM 数出来）。
    ///
    /// 从 `dependencyRecords` 里拆出来只为一件事：那条函数本来的职责是"把条目变成记录"，
    /// 而"先建一张管理表"是它的**前置事实**，两件事写在一起时 CC 已经数到 19，
    /// 本包那条 16 的线（`SelfScanHarnessCase.complexFunctionBar`）就兜不住了。
    /// 取义一字未改：仍然按 `managedEntries` 原序遍历、仍然在**代入之前**数 BOM。
    private func managedVersionTable() -> [String: String] {
        var managedVersions: [String: String] = [:]
        for item in managedEntries {
            let group = resolve(item.group.isEmpty ? rootGroup : item.group)
            let artifact = resolve(item.artifact)
            let version = resolve(item.version)
            // 导入型 BOM 要在**代入之前**数：它自己有条目，但它给的是"别的包的版本从哪来"，
            // 不是这条依赖自己的版本 —— 于是它下面的 guard 会不会 skip 都要先数到。
            if item.type.lowercased() == "pom", item.scope.lowercased() == "import" {
                importedBOMs += 1        // 版本在 BOM 里，不在这份 pom 里（RD-13b 的第二条来路）
            }
            guard !group.isEmpty, !artifact.isEmpty, !version.isEmpty else { continue }
            managedVersions["\(group):\(artifact)"] = version
        }
        return managedVersions
    }

    /// 一条 `<dependency>` → 一条记录；`<artifactId>` 解析后为空的条目**不产出记录**
    /// （与原实现里那句 `guard !artifact.isEmpty else { continue }` 同一件事，只是改成返回 nil）。
    private func record(for item: Entry, managed: [String: String],
                        manifestPath: String) -> DependencyRecord? {
        let group = resolve(item.group.isEmpty ? rootGroup : item.group)
        let artifact = resolve(item.artifact)
        guard !artifact.isEmpty else { return nil }
        // 顺序：清单自己写的 <version> → 本份 pom 的 dependencyManagement → 占位串。
        let rawVersion = item.version
        var version = resolve(item.version)
        var state = declaredVersionState(for: version, raw: rawVersion)
        if version.isEmpty, let managedVersion = managed["\(group):\(artifact)"] {
            version = resolve(managedVersion)
            state = declaredVersionState(for: version, raw: managedVersion)
        }
        if version.isEmpty {
            version = ManifestParsers.undeclaredVersion
            // 三态分岔（RD-13b）：没写版本 ≠ 没管理版本。
            state = hasParent || importedBOMs > 0 ? .managedByParent : .notDeclared
        }
        let name = group.isEmpty ? artifact : "\(group):\(artifact)"
        var record = ManifestParsers.record(name, version, .maven, scope(of: item), manifestPath)
        record.declaredVersionState = state
        return record
    }

    /// 依赖条目 → scope。拆出来是为了让上面那条函数只管"版本从哪来"这一件事。
    /// 判据顺序与原来一致：插件注入且没写 scope ⇒ 构建；其余按 `<scope>` 归一。
    private func scope(of item: Entry) -> DependencyScope {
        if item.fromPlugin && item.scope.isEmpty { return .build }
        switch item.scope.lowercased() {
        case "test": return .test
        case "provided": return .platform
        default: return .runtime
        }
    }
}

// MARK: - 下标安全访问（各文件各自 fileprivate，不外溢到模块）

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
