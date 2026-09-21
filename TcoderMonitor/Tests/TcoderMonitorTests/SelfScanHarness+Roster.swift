/// OWNER: WS-X3 TestSplit —— 自 SelfScanHarness.swift 拆出，超限文件归人与派工单渲染（口径常量一个不动）。用例本体未改，只是搬了家。
import XCTest
@testable import TcoderMonitor

extension SelfScanHarnessCase {

    /// 第二轮（`AGENTS.md` §7 + 总工派工）把目录重切了一遍，所以按**现归属**报：
    /// `Services/Health|Code|Logs`→WS-R、`Services/Dependencies`→WS-N、`Services/Performance`→WS-C、
    /// `Views/Root|ProjectDetail|Dashboard`→WS-K、`Views/Code|Git|Dependencies|CodeGit`→WS-L、
    /// `Views/Performance|Logs|Health|PerfLogs`→WS-M、`Design/**`+`App/Theme.swift`→WS-G。
    static func owner(ofPath path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        if splitByWSV.contains(name) {
            return "WS-V（本轮派拆；原文归 \(legacyOwner(ofPath: path))）"
        }
        return legacyOwner(ofPath: path)
    }

    static func legacyOwner(ofPath path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        // 测试文件按 `AGENTS.md` §3 写在纸面上的 glob 归口（第二轮只重切了
        // Services/ 与 Views/，Tests/ 仍按原表），别拿目录规则去猜。
        if name.hasSuffix("Tests.swift") { return owner(ofTestFileNamed: name) }
        return directoryRules.first { rule in rule.matches(path, name) }?.owner ?? "未归属（报总工认领）"
    }

    /// 按文件名指派测试归口（§7 扩充流表是**按文件名**派的，不走 glob，先查它）。
    static func owner(ofTestFileNamed name: String) -> String {
        if let named = namedTestOwners[name] { return named }
        if name.hasPrefix("Code") { return "WS-A（Tests/Code*）" }
        if name.hasPrefix("Git") || name.hasPrefix("Dependency") { return "WS-B（Tests/Git*|Dependency*）" }
        if name.hasPrefix("Log") || name.hasPrefix("Health") || name.hasPrefix("Performance") {
            return "WS-C（Tests/Log*|Health*|Performance*）"
        }
        return "Tests/ 未命中 glob·报总工认领"
    }

    /// 一张按顺序首中即止的归口表：判据与原来那串 `switch true` 逐条同序、同条件、同归属。
    /// 拆成表是为了把 `legacyOwner` 的圈复杂度从 19 压到 16 以下（每个 `case` 的每个条件
    /// 在引擎口径里都是一个分支），**没有任何一条判据被放宽或删掉**。
    private struct OwnerRule {
        var matches: (_ path: String, _ name: String) -> Bool
        var owner: String
    }

    private static let directoryRules: [OwnerRule] = [
        OwnerRule(matches: { path, name in
            path.contains("/Sources/TcoderMonitor/Models/") || frozenFileNames.contains(name)
        }, owner: "总工（冻结区）"),
        OwnerRule(matches: { path, name in
            name == "Theme.swift" || path.contains("/Sources/TcoderMonitor/Design/")
        }, owner: "WS-G"),
        OwnerRule(matches: { _, name in shellViewFileNames.contains(name) }, owner: "WS-K"),
        OwnerRule(matches: { path, _ in codeGitViewDirectories.contains(where: { path.contains($0) }) }, owner: "WS-L"),
        OwnerRule(matches: { path, _ in perfLogsViewDirectories.contains(where: { path.contains($0) }) }, owner: "WS-M"),
        OwnerRule(matches: { path, _ in staticServiceDirectories.contains(where: { path.contains($0) }) }, owner: "WS-R"),
        OwnerRule(matches: { path, _ in path.contains("/Services/Dependencies/") }, owner: "WS-N"),
        OwnerRule(matches: { path, _ in path.contains("/Services/Performance/") }, owner: "WS-C"),
        OwnerRule(matches: { path, _ in path.contains("/Services/Coverage/") },
                  owner: "WS-J（本流，唯一无主 Services 文件）"),
        OwnerRule(matches: { path, _ in path.contains("/scripts/") }, owner: "WS-E（脚本）"),
    ]

    private static let frozenFileNames: Set<String> = [
        "Package.swift", "AppState.swift", "TcoderMonitorApp.swift", "ServiceContracts.swift",
        "ProjectStore.swift", "SharedUtilities.swift",
    ]
    private static let shellViewFileNames: Set<String> = [
        "RootView.swift", "ProjectDetailView.swift", "DashboardView.swift",
    ]
    private static let codeGitViewDirectories: Set<String> = [
        "/Views/Code/", "/Views/Git/", "/Views/Dependencies/", "/Views/CodeGit/",
    ]
    private static let perfLogsViewDirectories: Set<String> = [
        "/Views/Performance/", "/Views/Logs/", "/Views/Health/", "/Views/PerfLogs/",
    ]
    private static let staticServiceDirectories: Set<String> = [
        "/Services/Health/", "/Services/Code/", "/Services/Logs/",
    ]

    /// 生产代码与测试代码分栏：只看一个合并数字，会分不清"产品又堆坨了"
    /// 还是"测试文件待拆"——这两件事的责任人和紧迫度完全不同。
    static func productionSummary(_ over: [GroundTruthFile]) -> String {
        let production = over.filter { $0.path.contains("/Sources/") }
        guard !production.isEmpty else { return "生产代码（Sources/）：0 个超限，已达标" }
        return "生产代码（Sources/）：\(production.count) 个超限 —— \(tally(production))"
    }

    static func summaryOfTestFiles(_ over: [GroundTruthFile]) -> String {
        let tests = over.filter { !$0.path.contains("/Sources/") }
        guard !tests.isEmpty else { return "测试代码（Tests/）：0 个超限" }
        return "测试代码（Tests/）：\(tests.count) 个超限 —— \(tally(tests))"
    }

    static func tally(_ files: [GroundTruthFile]) -> String {
        Dictionary(grouping: files, by: { owner(ofPath: $0.path) })
            .map { "\($0.key) \($0.value.count) 个" }
            .sorted()
            .joined(separator: " · ")
    }

    static func hugeFileRoster(_ over: [GroundTruthFile]) -> String {
        let root = Self.repoRoot.path
        return over.map { file in
            let relative = file.path.hasPrefix(root)
                ? String(file.path.dropFirst(root.count + 1)) : file.path
            return "  \(String(format: "%5d", file.lines)) 行 → \(owner(ofPath: file.path))\t\(relative)"
        }.joined(separator: "\n")
    }

}
