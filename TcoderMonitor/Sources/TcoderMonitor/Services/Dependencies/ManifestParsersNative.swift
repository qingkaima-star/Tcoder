// 依赖清单解析 · Go go.mod 与 Rust Cargo.toml（WS-B）
import Foundation

// MARK: - Go / go.mod

extension ManifestParsers {
    /// go.mod -> [DependencyRecord]。`// indirect` 记为 .unknown，其余 .runtime。
    /// 版本去掉 go 特有的 "v" 前缀与 "+incompatible"，以对齐 DependencyVersion 的点分比较。
    static func goModDependencies(_ text: String, manifestPath: String) -> [DependencyRecord] {
        var records: [DependencyRecord] = []
        var inRequireBlock = false
        var inIgnoredBlock = false
        for rawLine in lines(text) {
            let stripped = trim(stripSlashComment(rawLine))
            if stripped.isEmpty { continue }

            if inIgnoredBlock {
                if stripped == ")" { inIgnoredBlock = false }
                continue
            }
            if inRequireBlock && stripped == ")" {
                inRequireBlock = false
                continue
            }
            if !inRequireBlock {
                if stripped == "require (" || stripped.hasPrefix("require (") { inRequireBlock = true; continue }
                if stripped.hasPrefix("replace") || stripped.hasPrefix("exclude") || stripped.hasPrefix("retract") {
                    if stripped.contains("(") { inIgnoredBlock = true }
                    continue
                }
                if stripped.hasPrefix("module") || stripped.hasPrefix("go ") || stripped.hasPrefix("go\t")
                    || stripped == "go" || stripped.hasPrefix("toolchain") { continue }
            }

            var body = stripped
            if body.hasPrefix("require ") { body = trim(String(body.dropFirst("require ".count))) }
            let columns = body.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let modulePath = columns.first, !modulePath.isEmpty, modulePath != "(" else { continue }
            if modulePath.hasPrefix("//") || modulePath.hasPrefix("\"") { continue }
            let rawVersion = columns.count >= 2 ? columns[1] : undeclaredVersion
            let isIndirect = rawLine.lowercased().contains("// indirect")
            records.append(record(modulePath, goVersion(rawVersion), .go,
                                  isIndirect ? .unknown : .runtime, manifestPath))
        }
        return dedupe(records)
    }

    static func goVersion(_ raw: String) -> String {
        var value = trim(raw)
        if value.hasPrefix("v"), let first = value.dropFirst().first, first.isNumber {
            value = String(value.dropFirst())
        }
        if let plus = value.firstIndex(of: "+") { value = String(value[..<plus]) }
        return value.isEmpty ? undeclaredVersion : value
    }
}

// MARK: - Cargo / Cargo.toml

extension ManifestParsers {
    /// Cargo.toml -> [DependencyRecord]。
    static func cargoTomlDependencies(_ text: String, manifestPath: String) -> [DependencyRecord] {
        var records: [DependencyRecord] = []
        for entry in tomlEntries(in: text) {
            let section = entry.section.lowercased()
            guard section.hasSuffix("dependencies") || section.hasSuffix("dependency") else { continue }
            let scope: DependencyScope
            if section.contains("dev") { scope = .dev }
            else if section.contains("build") { scope = .build }
            else { scope = .runtime }
            let name = trim(entry.key)
            guard !name.isEmpty else { continue }
            let declared: String?
            if let inline = firstGroup("version\\s*=\\s*(['\"])([^'\"\\n]+)\\1", 2, in: entry.value) {
                declared = inline
            } else if trim(entry.value).hasPrefix("{") {
                declared = nil
            } else {
                declared = firstGroup("^\\s*(['\"])([^'\"\\n]+)\\1", 2, in: entry.value)
            }
            let version = trim(declared ?? undeclaredVersion)
            records.append(record(name, version.isEmpty || version == "*" ? undeclaredVersion : version,
                                  .cargo, scope, manifestPath))
        }
        return dedupe(records)
    }
}
