//
// 日志归属用的项目身份（R4，RD-23）。
//
// 整改前这里只有一句话：`projectName: projectRoot.lastPathComponent`。
// 于是"这个崩溃报告属不属于本项目"取决于**你从哪个目录添加项目**：
// 扫 `/repo` 得到的自动输入与扫 `/repo/Sub` 得到的不是同一份（后者才认 `Sub-*.ips`），
// 而且整个过程是"拿目录名猜应用"。
//
// 现在：身份 = 项目锚点（git 根）+ 项目**自己声明的产品名**（清单文件里的名字），
// 与"从哪一层开始扫"无关；报告一侧仍然只认报告自报的主名，不用目录名补。
//

import Foundation

struct LogProjectIdentity: Sendable, Equatable {
    /// 项目锚点：最近的、带着 `.git` 的祖先目录；找不到就是所选目录本身。
    var anchorURL: URL
    /// 锚点目录名（保留它是为了兼容既有的 `~/Library/Logs/<目录名>` 约定）。
    var anchorName: String
    /// 项目自己声明的产品名：`Package.swift` / `package.json` / `*.podspec` /
    /// `*.xcodeproj` / `*.app` / `Info.plist` 里的名字。**不来自目录名。**
    var declaredProductNames: [String]

    /// 可以拿去做归属比对的令牌（整段相等才认，不做子串匹配）。
    var attributionTokens: Set<String> {
        var tokens = Set(declaredProductNames.map { $0.lowercased() })
        tokens.insert(anchorName.lowercased())
        tokens.remove("")
        return tokens
    }

    /// 锚点下最多下潜几层去找清单。两层足够覆盖 `Repo/Package/Package.swift`
    /// 与 `Repo/App/Info.plist` 这类常见形状，又不会把整棵树走一遍。
    static let manifestDepth = 2
    static let manifestDirectoryBudget = 400

    static func resolve(scanRoot: URL) -> LogProjectIdentity {
        let anchor = projectAnchor(of: scanRoot)
        return LogProjectIdentity(anchorURL: anchor,
                                  anchorName: anchor.lastPathComponent,
                                  declaredProductNames: declaredProducts(under: anchor))
    }

    /// 调用方**已经知道**身份时的显式构造（单测与将来的"手工绑定报告目录"走这条）。
    /// 它不读清单，因此也不会把"这台机器上恰好有个同名目录"混进判定里。
    static func declaring(_ names: [String]) -> LogProjectIdentity {
        let cleaned = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
        return LogProjectIdentity(anchorURL: cleaned.first.map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: "/"),
                                  anchorName: cleaned.first ?? "",
                                  declaredProductNames: Array(cleaned.dropFirst()))
    }

    /// 向上找 `.git`（含 worktree 的 `.git` 文件形式）。走到文件系统根或超过 8 层就停。
    static func projectAnchor(of scanRoot: URL, limit: Int = 8) -> URL {
        var cursor = scanRoot
        for _ in 0..<limit {
            let git = cursor.appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: git.path) { return cursor }
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path { return scanRoot }
            cursor = parent
        }
        return scanRoot
    }

    /// 锚点范围内（深度 ≤ `manifestDepth`）声明的产品名，排序去重 ⇒ 与目录遍历顺序无关。
    static func declaredProducts(under anchor: URL) -> [String] {
        var found: Set<String> = []
        var directoriesLeft = manifestDirectoryBudget
        var stack: [(url: URL, depth: Int)] = [(anchor, 0)]
        while let (directory, depth) = stack.popLast(), directoriesLeft > 0 {
            directoriesLeft -= 1
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for entry in entries {
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true { continue }
                if values?.isDirectory == true {
                    found.formUnion(directoryProductNames(of: entry))
                    if depth < manifestDepth { stack.append((entry, depth + 1)) }
                    continue
                }
                found.formUnion(productNames(inManifestAt: entry))
            }
        }
        return found.sorted()
    }

    /// `Foo.xcodeproj` / `Foo.xcworkspace` / `Foo.app` 这类目录自带产品名。
    static func directoryProductNames(of url: URL) -> [String] {
        let known: Set<String> = ["xcodeproj", "xcworkspace", "app", "framework"]
        guard known.contains(url.pathExtension.lowercased()) else { return [] }
        return [url.deletingPathExtension().lastPathComponent]
    }

    /// 清单文件里声明的名字。读不动 / 解析不出来就返回空 —— **不猜**。
    static func productNames(inManifestAt url: URL) -> [String] {
        let name = url.lastPathComponent.lowercased()
        switch name {
        case "package.swift", "package.json":
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            return manifestNameTokens(in: text)
        case "info.plist":
            return infoPresetNames(of: url)
        default:
            guard url.pathExtension.lowercased() == "podspec",
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            return manifestNameTokens(in: text)
        }
    }

    /// `name: "X"` / `"name": "X"` / `.name("X"` 三种写法里的产品名。
    /// 只认字母数字点横线下划线组成的值，避免把 URL 或描述文字当成应用名。
    static let manifestNamePattern: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"["']?name["']?\s*[:=(]\s*["']([A-Za-z0-9_.\-]{2,80})["']"#
    )

    static func manifestNameTokens(in text: String) -> [String] {
        guard let pattern = manifestNamePattern else { return [] }
        let ns = text as NSString
        var names: [String] = []
        pattern.enumerateMatches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) { result, _, _ in
            guard let result, result.numberOfRanges > 1 else { return }
            let value = ns.substring(with: result.range(at: 1))
            if value.contains("/") == false, value.hasSuffix(".json") == false { names.append(value) }
        }
        return names
    }

    /// `Info.plist` 的 `CFBundleName` / `CFBundleExecutable` / `CFBundleIdentifier`。
    /// bundle id 取最后一段（`com.example.Foo` → `Foo`），它才是报告里 `procName` 的对应物。
    static func infoPresetNames(of url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any] else { return [] }
        var names: [String] = []
        for key in ["CFBundleName", "CFBundleExecutable"] {
            if let value = plist[key] as? String, value.isEmpty == false { names.append(value) }
        }
        if let identifier = plist["CFBundleIdentifier"] as? String {
            let tail = identifier.split(separator: ".").last.map(String.init) ?? ""
            if tail.isEmpty == false { names.append(tail) }
        }
        return names
    }
}
