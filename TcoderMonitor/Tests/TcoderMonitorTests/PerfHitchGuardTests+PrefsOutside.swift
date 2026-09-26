/// OWNER: 总工（性能线）—— **跨度之外**那一半的 prefs 读数（#97 后半）。
///
/// 为什么要单独一份、而不是塞进 `PerfHitchScan.rules`：
/// 那套规则全部只在 `var body:` 与 `Chart {` 的**跨度内**数（口径三件事写在 `PerfHitchScan.swift` 头注里），
/// 而 `@AppStorage`／`@SceneStorage` 是**属性声明**——字面永远不在跨度内，读却发生在每次访问那个
/// wrapper 的时候（每次访问都是一趟 `UserDefaults` 打盘）。把这种名字塞进 `rules`，
/// 跨度扫描只会给出 0，于是**"0 处 prefs 读"看起来像"这一族已经还干净了"**——
/// 正是 `tokenReference` 那次记过的同一种假零。所以这里量的是**另一个作用面**：整文件声明层。
///
/// ⚠ 这条判据不许被读成"prefs 已全覆盖"：跨度内那一半归 `syncPrefs`（卷十一 §182 落的），
/// 两半各有各的名字、各的名单，谁也不替谁作证。
import Foundation
import XCTest

extension PerfHitchGuardTests {

    /// 属性包装器形状的 prefs 声明。带 `(` 是有意的：`@AppStorage` 必然带键名出现，
    /// 去掉 `(` 会把"这个 wrapper 怎么用"那种叙述也算进来。
    static let prefsDeclarationPattern = #"@(?:App|Scene)Storage\s*\("#

    /// 现量 2（2026-09-27 18:44 逐点核过）：`Views/ProjectDetailView.swift` 与
    /// `Views/Shell/ProjectSidebar.swift` 各一处，键名都是 `selectedDetailSection`——
    /// **它正是九页差量取证选页的入口**（启动参数写、这里读），所以不许"为了变绿"顺手改掉，
    /// 也不许当成已经还掉的债。棘轮只许往下走；真要往上加，得同批改这一格并说明理由。
    static let prefsDeclarationCeiling = 2

    /// 模式能不能打中一行（编不出正则也算不中 ⇒ 上面那条 `testRulePatternsActuallyCompile` 之外再兜一层）。
    static func prefsPatternHits(_ line: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: prefsDeclarationPattern) else { return false }
        return regex.firstMatch(in: line, range: NSRange(location: 0, length: line.utf16.count)) != nil
    }

    /// 一份源码里的 prefs 声明 → `相对 Sources/TcoderMonitor 的路径:行 原文`
    /// （`SurfaceScanKit.sourceFiles` 给的 `path` 已经带 `Views/` 这一层，别再自己加前缀——
    /// 第一版我加了，于是打印成 `Views/Views/ProjectDetailView.swift`，那是假坐标）。
    /// 注释行由 `SurfaceScanKit.codeLines` 逐行剥掉（它是无状态的按行判），
    /// 因为现场就有一条反例：`Views/Shell/ProjectSidebar.swift` 有一行**注释**在谈 `@AppStorage`，
    /// 按字面 grep 会数成 3 处（18:44 我自己就先数错过一次）。
    static func prefsDeclarations(in source: String, file: String) -> [String] {
        var sites: [String] = []
        for (index, line) in source.components(separatedBy: "\n").enumerated() {
            guard SurfaceScanKit.codeLines(line) == [line], prefsPatternHits(line) else { continue }
            sites.append("\(file):\(index + 1) "
                + line.trimmingCharacters(in: .whitespaces))
        }
        return sites
    }

    /// 两棵树都数：`Views/**` 与 `Design/**`（后者今天 0 处，但图表 surface 迟早也会有包裹属性）。
    static func prefsDeclarationSites() throws -> [String] {
        var sites: [String] = []
        for surface in ["Views", "Design"] {
            for file in try SurfaceScanKit.sourceFiles(under: surface) {
                sites += prefsDeclarations(in: file.content, file: file.path)
            }
        }
        return sites
    }

    /// 棘轮本体：现量只许 ≤ 上限，且**逐点必须可点名**（只有数字的台账等于没有台账）。
    func testPrefsDeclarationsOutsideSpansAreNamedAndRatcheted() throws {
        let sites = try Self.prefsDeclarationSites()
        print("【跨度外的 prefs 读】现量 \(sites.count)/上限 \(Self.prefsDeclarationCeiling)"
            + "（作用面＝整文件声明层，不是 body/Chart 跨度）")
        for site in sites.sorted() { print("  - \(site)") }
        XCTAssertLessThanOrEqual(sites.count, Self.prefsDeclarationCeiling,
                                 "主线程上的 prefs 包裹属性从 \(Self.prefsDeclarationCeiling) 处涨到 \(sites.count) 处："
                               + "每一次访问都是一趟同步 `UserDefaults`，而这正是要往 0 走的那一族。"
                               + "上面已逐点点名——改代码，或者（说明理由之后）改这一格的上限，二选一。")
        XCTAssertEqual(Set(sites).count, sites.count, "同一位置被数了两遍（走树在重复，读出来的数不可信）")
    }

    /// 牙：先证明这条判据**能**红（合成输入），再证明**注释里谈它不算数**。
    /// 缺前一半它就是一条新的永真绿；缺后一半会把 18:44 我数错那件事固化成判据。
    func testPrefsDeclarationRuleFiresOnDeclarationsButNotOnComments() {
        let source = """
        struct SomeView: View {
            @AppStorage("selectedDetailSection") private var sectionRaw: String = "overview"
            // 这里只是**谈**这个键：@AppStorage("selectedDetailSection") 的取值一律不动
            @SceneStorage("panel") var panel: String = ""
            var body: some View { Text(sectionRaw) }
        }
        """
        let sites = Self.prefsDeclarations(in: source, file: "Views/SomeView.swift")
        XCTAssertEqual(sites.count, 2, "两处真声明都要数到，注释里那一条不许算：\n\(sites)")
        XCTAssertTrue(sites.contains { $0.hasPrefix("Views/SomeView.swift:2 ") },
                      "漏了 @AppStorage 那处，或者坐标前缀又加了一遍：\(sites)")
        XCTAssertTrue(sites.contains { $0.contains(":4 ") }, "漏了 @SceneStorage 那处：\(sites)")
        XCTAssertTrue(sites.allSatisfy { !$0.contains("取值一律不动") },
                      "注释行被当成声明 ⇒ 又退回按字面 grep 的粗法：\(sites)")
        XCTAssertFalse(Self.prefsPatternHits("let plain = 1"), "模式空转：连不含 prefs 的行都说命中")
    }
}
