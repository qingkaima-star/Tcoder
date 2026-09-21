// 依赖清单解析 · Go go.mod 与 Rust Cargo.toml（WS-B）
import Foundation

// MARK: - Go / go.mod

extension ManifestParsers {
    /// go.mod -> [DependencyRecord]。`// indirect` 记为 .unknown，其余 .runtime。
    /// 版本去掉 go 特有的 "v" 前缀与 "+incompatible"，以对齐 DependencyVersion 的点分比较。
    /// 块头部的四类跳行判定抽在 `goBlockHeader` 里（判定表达式逐字照抄），
    /// 一行依赖的取值抽在 `goRequireRecord` 里，两处的取值链均未改动。
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
            if !inRequireBlock, let header = goBlockHeader(stripped) {
                if header == .startRequire { inRequireBlock = true }
                if header == .startIgnored { inIgnoredBlock = true }
                continue
            }
            if let item = goRequireRecord(stripped: stripped, rawLine: rawLine, manifestPath: manifestPath) {
                records.append(item)
            }
        }
        return dedupe(records)
    }

    /// `require (` / `replace|exclude|retract` / `module|go|toolchain` 三类块头部。
    /// 返回 nil 表示这一行不是块头部，按依赖行继续处理——与拆分前的落空路径一致。
    enum GoBlockHeader: Equatable {
        case startRequire
        case startIgnored
        case skipped
    }

    static func goBlockHeader(_ stripped: String) -> GoBlockHeader? {
        if stripped == "require (" || stripped.hasPrefix("require (") { return .startRequire }
        if stripped.hasPrefix("replace") || stripped.hasPrefix("exclude") || stripped.hasPrefix("retract") {
            return stripped.contains("(") ? .startIgnored : .skipped
        }
        if stripped.hasPrefix("module") || stripped.hasPrefix("go ") || stripped.hasPrefix("go\t")
            || stripped == "go" || stripped.hasPrefix("toolchain") { return .skipped }
        return nil
    }

    /// 一行依赖 -> 记录。`require ` 前缀、空白分列、`( // indirect` 判定与 `goVersion` 调用链一字未改。
    static func goRequireRecord(stripped: String,
                                rawLine: String,
                                manifestPath: String) -> DependencyRecord? {
        var body = stripped
        if body.hasPrefix("require ") { body = trim(String(body.dropFirst("require ".count))) }
        let columns = body.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let modulePath = columns.first, !modulePath.isEmpty, modulePath != "(" else { return nil }
        if modulePath.hasPrefix("//") || modulePath.hasPrefix("\"") { return nil }
        let rawVersion = columns.count >= 2 ? columns[1] : undeclaredVersion
        let isIndirect = rawLine.lowercased().contains("// indirect")
        return record(modulePath, goVersion(rawVersion), .go,
                      isIndirect ? .unknown : .runtime, manifestPath)
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
