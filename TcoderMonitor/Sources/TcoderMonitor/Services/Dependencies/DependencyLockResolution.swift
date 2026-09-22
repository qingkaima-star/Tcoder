// OWNER: R3 依赖证据链 · 锁文件解析（RD-10 / RD-12 的"实际版本"来源）
//
// 为什么必须有这一步：清单里写的 `^1.2.3` 是**请求**，不是**安装**。
// 整改清单 RD-10 要求"分别保存声明范围 / 实际解析版本 / 最新版本"，
// 而本仓此前只把锁文件的**文件名**读出来（`EcosystemReport.lockfileName`），
// 内容一个字都没读 ⇒ 查询 OSV 时只能拿声明下界，回填又用另一种拼法（RD-12 的错绑）。
//
// 本文件的三条规矩：
//   1. **只在无歧义时回填**：同一个包在锁里有多个版本（不同父包各锁一份）时不猜，返回 nil，
//      让上层落"版本未解析"而不是挑一个看起来对的。
//   2. **按声明符匹配，不按包名匹配**：yarn.lock / pnpm 的键本身就带声明符
//      （`lodash@^4.17.15`），这是唯一能把"同包多版本"分开的证据。
//   3. 解析器是纯函数：给文本、返回 `包名|声明符 -> 确切版本`，坏数据返回空，绝不抛。
import Foundation

/// 一份锁文件的解析结果。
struct DependencyLockResolution: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case npmPackageLock
        case yarnLock
        case pnpmLock
        case cargoLock
        case gradleLockfile
        case swiftPackageResolved
        /// Maven / Gradle 的"已解析产物"：effective-POM、依赖树、SBOM（见
        /// `DependencyResolvedArtifactParsers.swift`）。
        case resolvedArtifactReport
    }

    let kind: Kind
    /// 相对项目根的锁文件路径（可追溯：状态里要点名"依据哪份文件"）。
    let path: String
    /// `包名 -> 确切版本`。**只有无歧义的那批才进这张表**。
    let versionsByName: [String: String]
    /// `包名|清单里的声明符原文 -> 确切版本`（yarn / pnpm / package-lock v1 有声明符时才有）。
    let versionsBySpecifier: [String: String]
    /// 同名多版本被丢弃的包名（"为什么不回填"也要留证据）。
    let ambiguousNames: [String]

    init(kind: Kind, path: String, versionsByName: [String: String],
         versionsBySpecifier: [String: String] = [:], ambiguousNames: [String] = []) {
        self.kind = kind
        self.path = path
        self.versionsByName = versionsByName
        self.versionsBySpecifier = versionsBySpecifier
        self.ambiguousNames = ambiguousNames
    }

    /// 这条依赖在锁里解析成了哪个版本。顺序：先按声明符精确匹配，再按包名（仅在无歧义时）。
    func resolvedVersion(name: String, declaredRange: String) -> String? {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanRange = declaredRange.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = versionsBySpecifier["\(cleanName)|\(cleanRange)"] { return exact }
        if ambiguousNames.contains(cleanName) { return nil }
        return versionsByName[cleanName]
    }
}

// MARK: - 解析入口

enum DependencyLockParser {

    /// 按文件名分派。不认的锁文件返回 nil（调用方按"没有解析值"处理）。
    static func parse(fileName: String, text: String, relativePath: String) -> DependencyLockResolution? {
        switch fileName {
        case "package-lock.json", "npm-shrinkwrap.json":
            return packageLockJSON(text, relativePath: relativePath)
        case "yarn.lock":
            return yarnLock(text, relativePath: relativePath)
        case "pnpm-lock.yaml", "pnpm-lock.yml":
            return pnpmLock(text, relativePath: relativePath)
        case "Cargo.lock":
            return cargoLock(text, relativePath: relativePath)
        case "Package.resolved":
            return packageResolved(text, relativePath: relativePath)
        case "gradle.lockfile":
            return gradleLockfile(text, relativePath: relativePath)
        default:
            return nil
        }
    }

    // MARK: npm · package-lock.json（v1 / v2 / v3）

    /// v2/v3 的 `packages["node_modules/<name>"].version`；v1 的 `dependencies.<name>.version`。
    /// 只取**顶层**：`node_modules/a/node_modules/b` 是 a 的传递依赖，
    /// 拿它去回填直接依赖 `b` 就是张冠李戴（同名不同版本时更是凭空挑一个）。
    static func packageLockJSON(_ text: String, relativePath: String) -> DependencyLockResolution? {
        guard let data = text.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var names: [String: String] = [:]
        var ambiguous = Set<String>()
        var declared: [String: String] = [:]
        collectPackageLockV2(root["packages"], names: &names, ambiguous: &ambiguous, declared: &declared)
        collectPackageLockV1(root["dependencies"], names: &names, ambiguous: &ambiguous)
        // 声明符 -> 解析版本：只在包名无歧义时成立（v1 没有声明符表，这张表就是空的）。
        var bySpecifier: [String: String] = [:]
        for (name, specifier) in declared {
            guard !ambiguous.contains(name), let version = names[name] else { continue }
            bySpecifier["\(name)|\(specifier)"] = version
        }
        guard !names.isEmpty || !bySpecifier.isEmpty else { return nil }
        return DependencyLockResolution(kind: .npmPackageLock, path: relativePath,
                                       versionsByName: names,
                                       versionsBySpecifier: bySpecifier,
                                       ambiguousNames: ambiguous.sorted())
    }

    /// v2/v3：`packages` 表。只收**顶层** `node_modules/<name>`，并单独收根包（键为 ""）
    /// 那份 `dependencies` 里的声明符 —— 后者是把"声明范围"对上"锁定版本"的唯一线索。
    static func collectPackageLockV2(_ raw: Any?, names: inout [String: String],
                                     ambiguous: inout Set<String>, declared: inout [String: String]) {
        guard let packages = raw as? [String: Any] else { return }
        for (key, value) in packages {
            guard let entry = value as? [String: Any] else { continue }
            if key.isEmpty {
                if let table = entry["dependencies"] as? [String: Any] {
                    for (name, spec) in table {
                        if let text = spec as? String { declared[name] = text }
                    }
                }
                continue
            }
            guard let version = entry["version"] as? String,
                  let name = npmTopLevelPackage(in: key) else { continue }
            assign(name: name, version: version, into: &names, ambiguous: &ambiguous)
        }
    }

    /// v1：顶层 `dependencies` 的键就是包名，值里的 version 是当时装上的那个。
    /// 嵌套在某个包下面的 `dependencies` 属于传递依赖，一概不读。
    static func collectPackageLockV1(_ raw: Any?, names: inout [String: String],
                                     ambiguous: inout Set<String>) {
        guard let dependencies = raw as? [String: Any] else { return }
        for (name, value) in dependencies {
            guard let entry = value as? [String: Any], let version = entry["version"] as? String else { continue }
            assign(name: name, version: version, into: &names, ambiguous: &ambiguous)
        }
    }

    /// `node_modules/lodash` -> `lodash`；`packages[""]`（根包）与任何带第二层
    /// `node_modules` 的路径都**不收**。scope 包 `node_modules/@a/b` 收，得到 `@a/b`。
    static func npmTopLevelPackage(in key: String) -> String? {
        let prefix = "node_modules/"
        guard key.hasPrefix(prefix) else { return nil }
        let tail = String(key.dropFirst(prefix.count))
        guard !tail.isEmpty, !tail.contains("node_modules/") else { return nil }
        if tail.hasPrefix("@") {
            let pieces = tail.split(separator: "/")
            guard pieces.count == 2 else { return nil }
            return "@\(pieces[0])/\(pieces[1])"
        }
        return tail
    }

    // MARK: npm · yarn.lock（v1）

    /// 形状：
    /// ```
    /// lodash@^4.17.15, lodash@^4.17.20:
    ///   version "4.17.21"
    /// ```
    /// 键里的声明符与包名一起出现，这是"同包多版本"唯一能分开的证据。
    static func yarnLock(_ text: String, relativePath: String) -> DependencyLockResolution? {
        var names: [String: String] = [:]
        var bySpecifier: [String: String] = [:]
        var ambiguous = Set<String>()
        var pending: [(name: String, specifier: String)] = []
        for rawLine in text.split(whereSeparator: { $0 == "\n" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("version") {
                guard let version = Self.quotedValue(in: line) else { continue }
                for entry in pending {
                    bySpecifier["\(entry.name)|\(entry.specifier)"] = version
                    assign(name: entry.name, version: version, into: &names, ambiguous: &ambiguous)
                }
                pending = []
                continue
            }
            guard line.hasSuffix(":") else { continue }
            pending = Self.yarnSelectors(String(line.dropLast()))
        }
        guard !names.isEmpty else { return nil }
        return DependencyLockResolution(kind: .yarnLock, path: relativePath,
                                       versionsByName: names, versionsBySpecifier: bySpecifier,
                                       ambiguousNames: ambiguous.sorted())
    }

    /// `lodash@^4.17.15, "foo@1.0.0"` -> [(lodash, ^4.17.15), (foo, 1.0.0)]。
    static func yarnSelectors(_ header: String) -> [(name: String, specifier: String)] {
        var result: [(String, String)] = []
        for piece in header.components(separatedBy: ",") {
            var item = piece.trimmingCharacters(in: .whitespaces)
            if item.hasPrefix("\""), item.hasSuffix("\""), item.count >= 2 {
                item = String(item.dropFirst().dropLast())
            }
            // 从右往左找最后一个 `@` 才是版本分隔符（scope 包名里也有 `@`）。
            guard let at = item.lastIndex(of: "@"), at != item.startIndex else { continue }
            let name = String(item[item.startIndex..<at])
            let specifier = String(item[item.index(after: at)...])
            guard !name.isEmpty, !specifier.isEmpty else { continue }
            result.append((name, specifier))
        }
        return result
    }

    // MARK: npm · pnpm-lock.yaml

    /// v6+：`/lodash@4.17.21:` 或 `  lodash@4.17.21:` 在 `packages:` 段里；v5：`/lodash/4.17.21:`。
    /// 同名多版本同样进 ambiguous，不猜。
    static func pnpmLock(_ text: String, relativePath: String) -> DependencyLockResolution? {
        var names: [String: String] = [:]
        var bySpecifier: [String: String] = [:]
        var ambiguous = Set<String>()
        for rawLine in text.split(whereSeparator: { $0 == "\n" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("/"), line.hasSuffix(":") else { continue }
            let body = String(line.dropFirst().dropLast())
            guard let at = body.lastIndex(of: "@"), at != body.startIndex else {
                // v5 形状 `/lodash/4.17.21:`
                let pieces = body.split(separator: "/")
                guard pieces.count >= 2 else { continue }
                assign(name: String(pieces[0]), version: String(pieces[1]), into: &names, ambiguous: &ambiguous)
                continue
            }
            let name = String(body[body.startIndex..<at])
            var version = String(body[body.index(after: at)...])
            if let paren = version.firstIndex(of: "(") { version = String(version[..<paren]) }
            guard !name.isEmpty, !version.isEmpty else { continue }
            assign(name: name, version: version, into: &names, ambiguous: &ambiguous)
            bySpecifier["\(name)|\(version)"] = version
        }
        guard !names.isEmpty else { return nil }
        return DependencyLockResolution(kind: .pnpmLock, path: relativePath,
                                       versionsByName: names, versionsBySpecifier: bySpecifier,
                                       ambiguousNames: ambiguous.sorted())
    }

    // MARK: Rust · Cargo.lock

    static func cargoLock(_ text: String, relativePath: String) -> DependencyLockResolution? {
        var names: [String: String] = [:]
        var ambiguous = Set<String>()
        var pendingName: String?
        for rawLine in text.split(whereSeparator: { $0 == "\n" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "[[package]]" { pendingName = nil; continue }
            if line.hasPrefix("name = ") {
                pendingName = Self.unquoted(line)
                continue
            }
            if line.hasPrefix("version = "), let name = pendingName, let version = Self.unquoted(line) {
                assign(name: name, version: version, into: &names, ambiguous: &ambiguous)
                pendingName = nil
            }
        }
        guard !names.isEmpty else { return nil }
        return DependencyLockResolution(kind: .cargoLock, path: relativePath,
                                       versionsByName: names, ambiguousNames: ambiguous.sorted())
    }

    // MARK: Gradle · gradle.lockfile

    /// 一行一条 `group:artifact:version=configuration1,configuration2`。
    static func gradleLockfile(_ text: String, relativePath: String) -> DependencyLockResolution? {
        var names: [String: String] = [:]
        var ambiguous = Set<String>()
        for rawLine in text.split(whereSeparator: { $0 == "\n" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let coordinate = String(line[line.startIndex..<equals])
            let pieces = coordinate.split(separator: ":")
            guard pieces.count >= 3 else { continue }
            let version = String(pieces[pieces.count - 1])
            let name = "\(pieces[0]):\(pieces[1])"
            guard !version.isEmpty else { continue }
            assign(name: name, version: version, into: &names, ambiguous: &ambiguous)
        }
        guard !names.isEmpty else { return nil }
        return DependencyLockResolution(kind: .gradleLockfile, path: relativePath,
                                       versionsByName: names, ambiguousNames: ambiguous.sorted())
    }

    // MARK: SwiftPM · Package.resolved

    /// Xcode / `swift build` 写出的 `{"pins":[{"identity":"swift-log","state":{"version":"1.6.1"}}]}`。
    /// `Package.swift` 里的 `from: "1.2.0"` 是范围，这份文件才是当时真正检出的那个数。
    static func packageResolved(_ text: String, relativePath: String) -> DependencyLockResolution? {
        guard let data = text.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pins = root["pins"] as? [[String: Any]] else { return nil }
        var names: [String: String] = [:]
        var ambiguous = Set<String>()
        for pin in pins {
            let identity = (pin["identity"] as? String) ?? (pin["package"] as? String)
            let version = ((pin["state"] as? [String: Any])?["version"] as? String) ?? (pin["version"] as? String)
            guard let name = identity, !name.isEmpty, let version, !version.isEmpty else { continue }
            assign(name: name, version: version, into: &names, ambiguous: &ambiguous)
        }
        guard !names.isEmpty else { return nil }
        return DependencyLockResolution(kind: .npmPackageLock, path: relativePath,
                                       versionsByName: names, ambiguousNames: ambiguous.sorted())
    }

    // MARK: - 共用小工具

    /// 同名冲突时**不覆盖**，改记入 ambiguous（后面按包名的回填会被它挡住）。
    static func assign(name: String, version: String, into table: inout [String: String],
                       ambiguous: inout Set<String>) {
        guard !name.isEmpty, !version.isEmpty else { return }
        if let existing = table[name], existing != version {
            ambiguous.insert(name)
            return
        }
        table[name] = version
    }

    /// `version "1.2.3"` / `name = "x"` -> 引号里的内容。
    static func unquoted(_ line: String) -> String? {
        Self.quotedValue(in: line)
    }

    /// 取行内**第一对**引号之间的内容。
    static func quotedValue(in line: String) -> String? {
        guard let first = line.firstIndex(of: "\"") else { return nil }
        let rest = line[line.index(after: first)...]
        guard let second = rest.firstIndex(of: "\"") else { return nil }
        let value = String(rest[..<second])
        return value.isEmpty ? nil : value
    }
}
