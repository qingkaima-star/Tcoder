/// OWNER: WS-P95 性能轮（原住 `PerfHitchScan.swift`，2026-09-25 整块搬来——**宿主当时 394/400，
/// 再加一条词表就会在门禁当天把闸门撑红**，按本仓「拆，不抬线」的规矩先拆再补）。
/// 声明本体一字未改地搬过来；唯一实义改动是 `syncFileIO` 词表补了两类形状（见该条上方那段）。
import Foundation

extension PerfHitchScan {

    /// 禁用形状。`syncFileIO` 的词表按 AGENTS.md 第四轮红线 6 覆盖
    /// `fileExists` / `attributesOfItem` / `contentsOfDirectory` / `Data(contentsOf:` /
    /// `String(contentsOf:` / `stat(` / `lstat(` / `FileManager`——
    /// **只匹配 `stat(` 会得到一条永真绿守卫**（本仓实际写法是 `attributesOfItem(atPath:)`）。
    ///
    /// 【2026-09-22 拆掉一条被混用的尺子】原来 `dynamicNSColor` 一条同时承担两件事，
    /// 而它们的终点方向相反：
    /// - **构造**（`Color(nsColor:` / `NSColor(name:`）＝ 每次渲染现造一份色 ⇒ 真债，终点 0；
    /// - **引用**（`.textColor` 等）＝ 读一个 init 里算好的 `let` ⇒ **不是债**，
    ///   只是"渲染路径有多依赖令牌"的读数。
    /// 混在一起的后果是实测出来的：`dynamicNSColor` 顶到 62/62 零余量后，
    /// 任何人在 body 里新写一处**正确**的令牌取色都会把闸门打红；
    /// 而真正的债形状 `Color(nsColor:`（已有 2 处）**一条规则都不抓**
    /// （`directFormatters` 的模式只列 `NSColor|DateFormatter|NumberFormatter`，
    /// `Color(` 不在其中）。⇒ 一条尺子量两种反向的东西，结果是**该红的漏了、该绿的挡路**。
    static let rules: [(name: String, pattern: String)] = [
        ("directFormatters", #"(?<![\w.])(?:NSColor|DateFormatter|NumberFormatter)\s*\("#),
        // 渲染路径里现造动态色：`Color(nsColor: …)` 与 `NSColor(name: …) { }`。
        // 只算构造点，不算引用点——引用的是 init 里缓存好的 `let color`，见上面那段。
        ("dynamicColorConstruction", #"(?<![\w.])(?:Color\(nsColor:|NSColor\(name:)"#),
        ("tokenReference", #"\.(?:textColor|graphicColor|badgeFill|onFillColor)\b"#),
        // 尾随闭包 `.sorted { … }` 与带参 `.sorted(by:)` 都是全量排序，两个形状都要抓：
        // 只写 `\.sorted\s*\(` 会漏掉尾随闭包那种写法，而 `badSamples` 里用的正是它——
        // 元测试 `testScannerFiresOnBadSamples` 就是靠这个把"规则过窄"照出来的。
        ("fullSort", #"\.sorted\s*(?:\(|\{)"#),
        // 2026-09-25（缺陷 #65）补两类**确实打盘**却不在词表里的形状：
        //   · `resolvingSymlinksInPath()` —— 路径解析，按目录组件逐个 lstat（`ScanProvenance` 就在用）；
        //   · `Process(` / `NSTask(` —— 起子进程，本仓 git 那一族的主形状，比一次 `stat` 贵几个数量级。
        // 补之前先量过会不会当场点红：`Views/**` 与 `Design/**` 两棵根里这两类**各 0 处**（09:51 现读），
        //   补完的现量仍是 `syncFileIO 2/2`。
        // ⚠ **这一条不许加 `(?<![\w.])` 前顾**：它是**方法**，真写法永远是 `url.resolvingSymlinksInPath()`，
        //    排除 `.` 等于把它写成一条永真绿的守卫——第一版我就这么写错了，是元测试
        //    `testScannerFiresOnBadSamples` 拿样例打回来的（"规则命中不了坏样例，它已经废了"）。
        //    对面 `Process`/`NSTask` 是**类型名**，才需要挡 `.` 前面那种 `Foo.Process(` 误伤。
        // ⚠ 词表再宽也管不到"跨度外"的主线程 I/O（跨度只认 `var body:` 与 `Chart {`，
        //    且跳展开只在**同一份文件内**）——那句话的真实射程写在 spec §D 的 T5 行里，不靠这段注释撑。
        ("syncFileIO", #"(?<![\w.])(?:l?stat)\s*\(|(?:Data|String)\(contentsOf:|contents\(ofDirectory|contents\(ofPath:|attributesOfItem\(|fileExists\(|FileManager|resolvingSymlinksInPath\s*\(|(?<![\w.])(?:Process|NSTask)\s*\("#),
    ]

    /// 正则必须能编译（`matches` 对编不过的模式只返回空并报警，那条规则就静默失效了，
    /// 所以单列一条守卫钉住它）。
    static func assertableRulePatternsCompile() -> [String] {
        rules.compactMap { rule in (try? NSRegularExpression(pattern: rule.pattern)) == nil ? rule.name : nil }
    }

    /// 每条规则的坏样例（元测试用）。I/O 那条特意用**仓库里真实存在的形状**
    /// `attributesOfItem(atPath:)`，而不是 `stat(`。
    ///
    /// `tokenReference` 是个例外：它的样例**不是违例**，只是"正则还能打中形状"的探针——
    /// 引用缓存令牌本来就是要鼓励的写法（见 `rules` 上面那段）。
    /// 之所以仍要求配样例：这条规则的名字刚从 `dynamicNSColor` 改过，
    /// 一旦模式退化，读数会静默变成 0，而"0 处引用"看起来像"页面不依赖令牌了"，
    /// 比红更难发现。
    static let badSamples: [(String, [String])] = [
        ("directFormatters", [#"let c = NSColor(name: nil) { _ in .black }"#,
                              "let formatter = DateFormatter()",
                              "let nf = NumberFormatter()"]),
        ("dynamicColorConstruction", ["let ink = Color(nsColor: .separatorColor)",
                                      "return Color(nsColor: NSColor(name: nil) { ap in .black })",
                                      "let fill = NSColor(name: nil) { _ in .red }"]),
        ("tokenReference", ["Text(\"x\").foregroundStyle(role.textColor)",
                            "LineMark(x: .value(\"t\", p.t)).foregroundStyle(series.graphicColor)",
                            "RoundedRectangle().fill(state.badgeFill)",
                            "Image(systemName: \"x\").foregroundStyle(colorSet.onFillColor)"]),
        ("fullSort", ["let rows = allRows.sorted { $0.name < $1.name }",
                      "let names = allNames.sorted(by: { $0.count > $1.count })"]),
        ("syncFileIO", ["guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }",
                        "if FileManager.default.fileExists(atPath: project.path) {",
                        "let kids = try FileManager.default.contentsOfDirectory(atPath: root)",
                        "let raw = try Data(contentsOf: url)",
                        "let text = try String(contentsOf: url, encoding: .utf8)",
                        "var st = stat(); stat(path, &st)",
                        "let physical = url.resolvingSymlinksInPath().path",
                        "let task = Process(); task.launchPath = \"/bin/sh\""]),
    ]
}
