// 依赖清单解析 · Python requirements*.txt 与 pyproject.toml（WS-B）
import Foundation

// MARK: - Python

extension ManifestParsers {
    /// requirements.txt -> [DependencyRecord]。名字按 PEP 503 小写归一；
    /// `pkg>=1.2` 取声明的下界 "1.2"；`-r`/`-e`/注释行跳过。
    static func requirementsTxtDependencies(_ text: String, manifestPath: String) -> [DependencyRecord] {
        var records: [DependencyRecord] = []
        for rawLine in lines(text) {
            let line = trim(stripHashComment(rawLine))
            if line.isEmpty { continue }
            if line.hasPrefix("-") { continue } // -r / -e / -c / --index-url …
            if let item = pythonRequirementRecord(line, scope: .runtime, manifestPath: manifestPath) {
                records.append(item)
            }
        }
        return dedupe(records)
    }

    /// pyproject.toml / Pipfile / setup.py -> [DependencyRecord]（尽力而为）。
    /// 拆出去的三块（`pyprojectListKind` / `appendPyprojectList` / `pyprojectTableRecord`）
    /// 各自照抄原先那一段判定，分支顺序与取值一字未改：
    /// 前五条「整段就是一个依赖数组」的形状按原顺序判，都不命中才落到
    /// `pythonTableScope` 的 poetry / Pipfile 形状，最后是 setup.py 的两条正则。
    static func pyprojectDependencies(_ text: String, manifestPath: String) -> [DependencyRecord] {
        var records: [DependencyRecord] = []

        for entry in tomlEntries(in: text) {
            let section = entry.section.lowercased()
            let key = entry.key.lowercased()
            if let kind = pyprojectListKind(section: section, key: key) {
                appendPyprojectList(kind, entry: entry, manifestPath: manifestPath, to: &records)
                continue
            }
            guard let scope = pythonTableScope(section) else { continue }
            if let item = pyprojectTableRecord(key: key, value: entry.value, name: entry.key,
                                               scope: scope, manifestPath: manifestPath) {
                records.append(item)
            }
        }

        // setup.py 的 install_requires = [...] / extras_require = {...}
        appendSetupPy(in: text, manifestPath: manifestPath, to: &records)
        return dedupe(records)
    }

    /// 「整段就是一个依赖数组」的五种形状。判定条件与原先的五个 `if` 逐字相同，
    /// 包括 `dependency-groups` 与 `*optional-dependencies` 两条**不看 key** 这一细节。
    enum PyprojectListKind {
        /// 段内每个字符串是一条 PEP 508 依赖。
        case specs(DependencyScope)
        /// `requires-python`：只有解得出数字前缀时产一条 `python` 平台记录。
        case pythonPlatform
    }

    static func pyprojectListKind(section: String, key: String) -> PyprojectListKind? {
        if section == "project", key == "dependencies" { return .specs(.runtime) }
        if section == "build-system", key == "requires" { return .specs(.build) }
        if section == "project", key == "requires-python" { return .pythonPlatform }
        if section == "dependency-groups" { return .specs(.dev) }
        if section.hasSuffix("optional-dependencies") { return .specs(.dev) }
        return nil
    }

    static func appendPyprojectList(_ kind: PyprojectListKind,
                                    entry: (section: String, key: String, value: String),
                                    manifestPath: String,
                                    to records: inout [DependencyRecord]) {
        switch kind {
        case .specs(let scope):
            for spec in tomlStringList(entry.value) {
                appendPython(spec, scope: scope, manifestPath: manifestPath, to: &records)
            }
        case .pythonPlatform:
            if let version = numericVersionPrefix(entry.value) {
                records.append(record("python", version, .python, .platform, manifestPath))
            }
        }
    }

    /// poetry / Pipfile 风格：`name = "^1.2"` 或 `name = { version = "^1.2", … }`。
    /// `name` 用的是**未小写化的原 key**（与拆分前一致），判定链顺序未动。
    static func pyprojectTableRecord(key: String,
                                     value: String,
                                     name rawNameKey: String,
                                     scope: DependencyScope,
                                     manifestPath: String) -> DependencyRecord? {
        let name = key == "python" ? "python" : normalizePythonName(rawNameKey)
        guard !name.isEmpty else { return nil }
        let declared: String?
        if let inline = firstGroup("version\\s*=\\s*(['\"])([^'\"\\n]+)\\1", 2, in: value) {
            declared = inline
        } else if trim(value).hasPrefix("{") {
            declared = nil // 只有 git / path，没写版本
        } else {
            declared = firstGroup("^\\s*(['\"])([^'\"\\n]+)\\1", 2, in: value)
        }
        let version: String
        if let declared, let extracted = numericVersionPrefix(declared) {
            version = extracted
        } else if let declared, declared != "*" {
            version = declared
        } else {
            version = undeclaredVersion
        }
        return record(name, version, .python, name == "python" ? .platform : scope, manifestPath)
    }

    static func appendSetupPy(in text: String, manifestPath: String, to records: inout [DependencyRecord]) {
        for groups in matches(of: "install_requires\\s*=\\s*\\[([^\\]]*)\\]", in: text) {
            guard let body = groups[safe: 1] else { continue }
            for spec in tomlStringList(body) {
                appendPython(spec, scope: .runtime, manifestPath: manifestPath, to: &records)
            }
        }
        for groups in matches(of: "extras_require\\s*=\\s*\\{(.*?)\\n[ \\t]*\\}", in: text,
                             options: [.dotMatchesLineSeparators]) {
            guard let body = groups[safe: 1] else { continue }
            for spec in tomlStringList(body) {
                appendPython(spec, scope: .dev, manifestPath: manifestPath, to: &records)
            }
        }
    }

    private static func appendPython(_ spec: String, scope: DependencyScope,
                                     manifestPath: String, to records: inout [DependencyRecord]) {
        if let item = pythonRequirementRecord(spec, scope: scope, manifestPath: manifestPath) {
            records.append(item)
        }
    }

    /// 一条 PEP 508 / PEP 440 依赖字符串 -> DependencyRecord
    static func pythonRequirementRecord(_ spec: String, scope: DependencyScope,
                                        manifestPath: String) -> DependencyRecord? {
        var value = trim(stripHashComment(spec))
        if value.isEmpty || value.hasPrefix("-") { return nil }
        if let semicolon = value.firstIndex(of: ";") { value = trim(String(value[..<semicolon])) }
        // 直接引用：name @ https://…
        if let direct = value.range(of: " @ ") {
            let name = normalizePythonName(String(value[..<direct.lowerBound]))
            guard !name.isEmpty else { return nil }
            return record(name, undeclaredVersion, .python, scope, manifestPath)
        }
        if value.contains("://") {
            guard let egg = firstGroup("[#&]egg=([A-Za-z0-9_.\\-]+)", 1, in: value) else { return nil }
            return record(normalizePythonName(egg), undeclaredVersion, .python, scope, manifestPath)
        }
        guard let groups = matches(of: "^([A-Za-z0-9][A-Za-z0-9._\\-]*)\\s*(\\[[^\\]]*\\])?\\s*(.*)$", in: value).first,
              let rawName = groups[safe: 1] else { return nil }
        let name = normalizePythonName(rawName)
        guard !name.isEmpty else { return nil }
        let version = numericVersionPrefix(groups[safe: 3] ?? "") ?? undeclaredVersion
        return record(name, version, .python, scope, manifestPath)
    }

    static func normalizePythonName(_ raw: String) -> String {
        let lower = trim(raw).lowercased()
        guard !lower.isEmpty else { return lower }
        return replaceMatches(lower, pattern: "[-_.]+", with: "-")
    }

    /// 从 "^1.2"、">=1.2,<2"、"~> 1.2"、"==1.2.3" 里取声明的下界；取不到返回 nil。
    static func numericVersionPrefix(_ raw: String) -> String? {
        let value = trim(raw)
        guard !value.isEmpty else { return nil }
        return firstGroup("([0-9]+(?:\\.[0-9A-Za-z\\-]+)*)", 1, in: value)
    }

    /// 哪些 TOML 段里的 `key = value` 算依赖。
    static func pythonTableScope(_ section: String) -> DependencyScope? {
        switch section {
        case "packages": return .runtime
        case "dev-packages": return .dev
        case "tool.poetry.dependencies": return .runtime
        case "tool.poetry.dev-dependencies": return .dev
        case "tool.poetry.group.dependencies": return .dev
        default: break
        }
        if section.hasPrefix("tool.poetry.group.") && section.hasSuffix(".dependencies") {
            let group = section
                .replacingOccurrences(of: "tool.poetry.group.", with: "")
                .replacingOccurrences(of: ".dependencies", with: "")
            let devGroups: Set<String> = ["dev", "test", "tests", "lint", "docs", "ci", "tools", "typing", "quality"]
            return devGroups.contains(group) ? .dev : .runtime
        }
        return nil
    }

    /// 极简 TOML 扫描：返回 (段名, 键, 原样值)，多行数组 / 内联表已合并成一条。
    static func tomlEntries(in text: String) -> [(section: String, key: String, value: String)] {
        let rows = lines(text)
        var section = ""
        var result: [(String, String, String)] = []
        var index = 0
        while index < rows.count {
            let line = trim(stripHashComment(rows[index]))
            index += 1
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                section = trim(line.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
                continue
            }
            guard let groups = matches(of: "^([A-Za-z0-9_\"'\\.\\-]+)\\s*=(.*)$", in: line).first,
                  let key = groups[safe: 1], let rest = groups[safe: 2] else { continue }
            var value = trim(rest)
            while bracketBalance(value) > 0, index < rows.count {
                value += "\n" + trim(stripHashComment(rows[index]))
                index += 1
            }
            let cleanKey = key.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            result.append((section, cleanKey, value))
        }
        return result
    }

    /// 引号外的 `[`/`{` 与 `]`/`}` 差值。
    static func bracketBalance(_ text: String) -> Int {
        var open = 0
        var quote: Character?
        for ch in text {
            if let current = quote {
                if ch == current { quote = nil }
                continue
            }
            if ch == "\"" || ch == "'" { quote = ch; continue }
            if ch == "[" || ch == "{" { open += 1 }
            else if ch == "]" || ch == "}" { open -= 1 }
        }
        return open
    }

    /// 取出文本里所有引号字符串（数组元素、内联字符串都适用）。
    static func tomlStringList(_ text: String) -> [String] {
        quotedStrings(text)
    }
}

// MARK: - 下标安全访问（各文件各自 fileprivate，不外溢到模块）

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
