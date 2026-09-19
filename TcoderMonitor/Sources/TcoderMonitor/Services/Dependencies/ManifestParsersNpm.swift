// 依赖清单解析 · npm / package.json（WS-B）
//
// 从 ManifestParsers.swift 按生态拆出；公共词法与分派在 ManifestParsers.swift，
// 所有解析器仍是纯函数：给文本、返回记录，解不出就返回空/nil，绝不抛异常。
import Foundation

// MARK: - npm / package.json

extension ManifestParsers {
    private static let npmSections: [(key: String, scope: DependencyScope)] = [
        ("dependencies", .runtime),
        ("devDependencies", .dev),
        ("peerDependencies", .platform),
        ("optionalDependencies", .unknown),
    ]

    /// package.json -> [DependencyRecord]。版本原样保留（^1.2.3、workspace:*、git+https://…）。
    static func packageJSONDependencies(_ text: String, manifestPath: String) -> [DependencyRecord] {
        guard let data = text.data(using: .utf8) else { return [] }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let root = object as? [String: Any] else { return [] }

        var records: [DependencyRecord] = []
        for section in npmSections {
            guard let table = root[section.key] as? [String: Any] else { continue }
            for name in table.keys.sorted() {
                let version = jsonVersionString(table[name]) ?? undeclaredVersion
                records.append(record(name, version, .npm, section.scope, manifestPath))
            }
        }
        return dedupe(records)
    }

    private static func jsonVersionString(_ value: Any?) -> String? {
        if let string = value as? String { return string.isEmpty ? nil : string }
        if let number = value as? NSNumber { return number.stringValue }
        if let table = value as? [String: Any] { return jsonVersionString(table["version"]) }
        return nil
    }
}
