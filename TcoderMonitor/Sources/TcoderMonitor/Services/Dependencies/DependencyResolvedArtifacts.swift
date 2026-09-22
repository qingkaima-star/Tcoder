// OWNER: R3 依赖证据链 · 已解析产物（RD-13b：不要求被扫项目为消提示手工补版本）
//
// 台账 RD-13b 的第二半句是"**能读已有的 effective-POM / 依赖树 / SBOM 文件**"。
// 为什么必须有这一步：Maven 子模块不写 `<version>` 是集中管理版本的好形状，
// 但要知道它到底装的是哪个版本，只有四条路：
//   ① 联网跑 `mvn` —— 本轮不开（禁网、且不是所有环境都有 Maven）；
// ② 要项目手工补一个版本号来消提示 —— **整改意见明令禁止**这种修法（等于让被扫对象替工具撒谎）；
// ③ 读项目**自己已经产出的**已解析产物 —— 本文件；
// ④ 都读不到就老实说"由父级管理但未解析" —— 见 `DependencyDeclaredVersionState`。
//
// 支持四种已被生态工具写出来的东西（纯函数，给文本返回 `包名 -> 版本`，解不出返回 nil）：
//   · effective-POM：`mvn help:effective-pom` 与 flatten-maven-plugin 的产物（版本已全部代入）
//   · 依赖树：`mvn dependency:tree` 的输出（`g:a:jar:v:scope` 与 `[INFO]` 前缀两种形状）
//   · CycloneDX SBOM（JSON）：`components[].{name,version,purl}`
//   · SPDX SBOM（JSON）：`packages[].{name,versionInfo,packageFileName,externalRefs}`
//
// 一条规矩：**同名多版本不猜**（沿用 `DependencyLockParser.assign` 的 ambiguous 语义）。
import Foundation

// MARK: - 解析

extension DependencyLockParser {

    /// 已解析产物的文件名判定表（`applyLockResolutions` 与清单发现共用一份）。
    /// 只收"工具写出来的、里面带确切版本"的文件，不收手写清单。
    static let resolvedArtifactNames: Set<String> = [
        "effective-pom.xml", ".flattened-pom.xml", "flattened-pom.xml", "dependency-reduced-pom.xml",
        "dependency-tree.txt", "dependencies.txt", "mvn-dependency-tree.txt", "gradle-dependencies.txt",
        "bom.json", "bom.xml", "cdx.json", "sbom.json", "sbom.cdx.json", "cyclonedx.json",
        "spdx.json", "sbom.spdx.json", "buildinfo.json",
    ]

    /// 这份产物认不认（按文件内容再判一次，文件名只是候选）。
    static func isResolvedArtifact(fileName: String, text: String) -> Bool {
        if resolvedArtifactNames.contains(fileName) { return true }
        // 扩展形状：`*-bom.json` / `*.spdx.json` / `*.cdx.json` 这类带前后缀的命名。
        guard fileName.hasSuffix(".json") else { return false }
        return fileName.contains("spdx") || fileName.contains("cdx") || fileName.contains("bom")
            || text.contains("\"spdxVersion\"") || text.contains("\"bomFormat\"")
    }

    /// 分派：认不出来返回 nil（调用方按"没有解析值"处理，绝不编一个版本）。
    static func parseResolvedArtifact(fileName: String, text: String,
                                     relativePath: String) -> DependencyLockResolution? {
        if fileName.hasSuffix(".xml"), !text.contains("\"bomFormat\"") {
            return effectivePomXML(text, relativePath: relativePath)
        }
        if let resolution = cycloneDXJSON(text, relativePath: relativePath) { return resolution }
        if let resolution = spdxJSON(text, relativePath: relativePath) { return resolution }
        if let resolution = mavenDependencyTree(text, relativePath: relativePath) { return resolution }
        return nil
    }

    // MARK: effective-POM

    /// effective-POM / flattened pom：结构与 pom.xml 相同，差别是 `<version>` 已经全部代入。
    /// 因此**复用 `ManifestParsers.pomXMLDependencies`**（同一把解析器，不另写一套），
    /// 把它读出的 (坐标, 版本) 折成一张表 —— 这就是"项目实际会拿到哪个版本"的直接证据。
    static func effectivePomXML(_ text: String, relativePath: String) -> DependencyLockResolution? {
        let records = ManifestParsers.pomXMLDependencies(text, manifestPath: relativePath)
        var names: [String: String] = [:]
        var ambiguous = Set<String>()
        for record in records where record.version != ManifestParsers.undeclaredVersion {
            guard DependencySemver.parse(record.version) != nil else { continue }
            assign(name: record.name, version: record.version, into: &names, ambiguous: &ambiguous)
        }
        guard !names.isEmpty else { return nil }
        return DependencyLockResolution(kind: .resolvedArtifactReport, path: relativePath,
                                       versionsByName: names, ambiguousNames: ambiguous.sorted(),
                                       originIsResolvedArtifact: true)
    }

    // MARK: mvn dependency:tree

    /// 一行一条：`[INFO] +- com.acme:widget:jar:1.4.2:compile`、`|  \\- org.x:y:pom:2.0:test`
    /// 也认去掉 `[INFO]` 前缀的裸形状。只收**四段以上且第三段是打包类型**的行，
    /// 版本号一律取打包类型后面那一段 ⇒ 树里的缩进与重复行不会污染结果。
    static func mavenDependencyTree(_ text: String, relativePath: String) -> DependencyLockResolution? {
        var names: [String: String] = [:]
        var ambiguous = Set<String>()
        for rawLine in text.split(separator: "\n") {
            var line = String(rawLine)
            if let bracket = line.range(of: "[INFO]") { line.removeSubrange(bracket) }
            line = line.replacingOccurrences(of: "+-", with: " ")
                .replacingOccurrences(of: "\\-", with: " ")
                .replacingOccurrences(of: "|", with: " ")
                .replacingOccurrences(of: "\\", with: " ")
                .trimmingCharacters(in: .whitespaces)
            let pieces = line.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
            guard pieces.count >= 4 else { continue }
            let artifactIndex = pieces.firstIndex(where: { ["jar", "pom", "war", "zip", "aar", "module"].contains($0) })
            guard let packagingAt = artifactIndex, packagingAt + 1 < pieces.count else { continue }
            let group = pieces[0]
            let artifact = pieces[1]
            let version = pieces[packagingAt + 1]
            guard !group.isEmpty, !artifact.isEmpty, DependencySemver.parse(version) != nil else { continue }
            assign(name: "\(group):\(artifact)", version: version, into: &names, ambiguous: &ambiguous)
        }
        guard !names.isEmpty else { return nil }
        return DependencyLockResolution(kind: .resolvedArtifactReport, path: relativePath,
                                       versionsByName: names, ambiguousNames: ambiguous.sorted(),
                                       originIsResolvedArtifact: true)
    }

    // MARK: CycloneDX / SPDX（都是 JSON，共用一次解码）

    /// CycloneDX：`{"bomFormat":"CycloneDX","components":[{"name":"...","version":"...","purl":"pkg:maven/g:a@v"}]}`。
    /// Maven 组件的名字优先从 **purl** 还原成 `group:artifact`（与清单里 `pomXMLDependencies` 的取名一致），
    /// 否则对不上 —— 只用 `name` 会退化成 artifact，跨清单匹配就断了。
    static func cycloneDXJSON(_ text: String, relativePath: String) -> DependencyLockResolution? {
        guard let root = jsonRoot(text), root["bomFormat"] != nil || root["components"] != nil else { return nil }
        return collectionResolution(components: root["components"] as? [[String: Any]],
                                   relativePath: relativePath)
    }

    /// SPDX 2.x JSON：`{"spdxVersion":"SPDX-2.3","packages":[{"name","versionInfo","externalRefs":[…purl…]}]}`。
    static func spdxJSON(_ text: String, relativePath: String) -> DependencyLockResolution? {
        guard let root = jsonRoot(text), root["spdxVersion"] != nil || root["packages"] != nil else { return nil }
        return collectionResolution(components: root["packages"] as? [[String: Any]],
                                   relativePath: relativePath, versionKey: "versionInfo")
    }

    private static func jsonRoot(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else { return nil }
        return root
    }

    /// 两个 SBOM 家族的共部分：条目 -> (名字, 版本)，同名多版本进 ambiguous 不猜。
    static func collectionResolution(components: [[String: Any]?]?, relativePath: String,
                                    versionKey: String = "version") -> DependencyLockResolution? {
        guard let components else { return nil }
        var names: [String: String] = [:]
        var ambiguous = Set<String>()
        for entry in components.compactMap({ $0 }) {
            guard let rawName = entry["name"] as? String,
                  let version = (entry[versionKey] as? String) ?? (entry["version"] as? String),
                  DependencySemver.parse(version) != nil else { continue }
            let purl = (entry["purl"] as? String)
                ?? ((entry["externalRefs"] as? [[String: Any]])?
                    .compactMap { $0["referenceLocator"] as? String }
                    .first { $0.hasPrefix("pkg:") })
            let key = sbomComponentName(named: rawName, purl: purl)
            guard !key.isEmpty else { continue }
            assign(name: key, version: version, into: &names, ambiguous: &ambiguous)
        }
        guard !names.isEmpty else { return nil }
        return DependencyLockResolution(kind: .resolvedArtifactReport, path: relativePath,
                                       versionsByName: names, ambiguousNames: ambiguous.sorted(),
                                       originIsResolvedArtifact: true)
    }

    /// Maven 的 purl 是 `pkg:maven/group/artifact@version` ⇒ 还原成清单用的 `group:artifact`；
    /// npm / PyPI 等没有 group ⇒ 用 name 原值。认不出 purl 时也用 name（至少不比旧实现差）。
    static func sbomComponentName(named rawName: String, purl: String?) -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let purl, purl.hasPrefix("pkg:") else { return name }
        let pieces = purl.dropFirst(4).split(separator: "/")
        guard pieces.count >= 3 else { return name }      // pkg:<生态>/<组>/<名>@<版本>
        let artifact = pieces[pieces.count - 1].split(separator: "@").first.map(String.init) ?? name
        guard artifact == name || name.isEmpty else { return name }
        let group = pieces[pieces.count - 2]
        return group == "npm" || group == "pypi" || group == "generic" ? name : "\(group):\(artifact)"
    }
}
