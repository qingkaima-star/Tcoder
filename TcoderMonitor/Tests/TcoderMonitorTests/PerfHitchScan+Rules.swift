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
        ("syncFileIO", #"(?<![\w.])(?:l?stat)\s*\(|(?:Data|String)\(contentsOf:|contents\(ofDirectory|contents\(ofPath:|attributesOfItem\(|fileExists\(|FileManager|resolvingSymlinksInPath\s*\(|(?<![\w.])(?:Process|NSTask)\s*\(|\.write\(to(?:URL)?:|(?<![\w.])FileHandle\b|createFile\(\s*atPath:|(?<!\w)(?:copy|move|remove)Item\("#),
        // 缺陷 #97：prefs 这一族此前**两重不可见**——词表不认（`syncFileIO` 只列文件 API），
        // 而且 §177 用 time-profile 按区间切片量出来"主线程栈里 40% 是 `CFPreferences`/`NSUserDefaults`"
        // 之后，守卫连"我们自己有没有这么写"都答不出来。补一条**独立规则**而不是往 `syncFileIO` 里塞词：
        // 两件事的终点虽然同向（都往 0），但命中形状、豁免表与台账那一格都是分开的，
        // 混进一条就会重演 2026-09-22 那次"一条尺子量两种反向东西"的事故。
        // 上限 = 现量 0（`UserDefaults` 与 `CFPreferences` 在 `Sources/**` 各 0 处，2026-09-27 18:38 现读）
        // ⇒ 零余量、终点 0，新增一处即红；`@AppStorage` 那一族**不在这条里**（它字面不在跨度内，
        // 见 `#97` 后半那条未闭格），别把这条当成"prefs 已全覆盖"。
        // ⚠ 这条**故意不在结尾留 `\b`**：真写法是 `CFPreferencesCopyAppValue(…)` 这一族 C API，
        //    结尾 `\b` 会把它们全部挡在门外（第一版我就这么写废了，是元测试
        //    `testScannerFiresOnBadSamples` 拿样例打回来的）。防误伤由前面的 `(?<![\w.])` 负责。
        ("syncPrefs", #"(?<![\w.])(?:UserDefaults|CFPreferences|PropertyListSerialization)"#),
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
                        // 2026-09-27（§184）：写盘这一族以前根本不在词表里（只有读的形状）。
                        // 两种真形状各配一行：`Data.write(to:options:)` 与 `String.write(to:atomically:encoding:)`。
                        "try data.write(to: fileURL, options: .atomic)",
                        "try text.write(to: url, atomically: true, encoding: .utf8)",
                        "let physical = url.resolvingSymlinksInPath().path",
                        "let task = Process(); task.launchPath = \"/bin/sh\"",
                        // 2026-09-27（§190）：「往盘上写／改」这一族剩下的形状。样例一律抄本仓真形状：
                        // 注入实例名那种（`ProjectStore` 里的 `private let fileManager = …`）而不是
                        // `FileManager.default.xxx(`——后者会被词表里的 `FileManager` 先命中，
                        // 于是那一格备选**删掉也没人红**，见 `soleResponsibilityProbes`。
                        "let handle = try FileHandle(forReadingFrom: url)",
                        "try fileManager.createFile(atPath: path, contents: nil)",
                        "try fileManager.copyItem(at: src, to: dst)",
                        "try fileManager.moveItem(at: tmp, to: url)",
                        "try? fileManager.removeItem(at: reportURL(for: project.id))"]),
        // prefs 这一族的样例用的是**本仓从没写过、但一写就是主线程打盘**的三种真形状
        // （§177 那批 time-profile 里，`CFPreferences` 一族占了首帧后主线程栈的 40%）。
        ("syncPrefs", ["let v = UserDefaults.standard.object(forKey: key)",
                       "let v = CFPreferencesCopyAppValue(key as CFString, app as CFString)",
                       "let o = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)"]),
    ]

    /// 「这个字**自己**有没有牙」的名单：每格 = (规则, 从模式里减掉的那一小段, 只有它能命中的样例)。
    /// `needle` 一律**带上段首的 `|`**：只减半个备选会留下 `||`，而 `||` 是一格空备选，
    /// 它命中一切 ⇒ 那条"删掉仍命中"的判定会以一种让人摸不着原因的方式红。
    static let soleResponsibilityProbes: [(rule: String, needle: String, sample: String)] = [
        ("syncFileIO", #"|(?<![\w.])FileHandle\b"#, "let handle = try FileHandle(forReadingFrom: url)"),
        ("syncFileIO", #"|createFile\(\s*atPath:"#, "try fileManager.createFile(atPath: path, contents: nil)"),
        // 三格样例共用一条 `needle`：`copy|move|remove` 是一组，减掉整组才算"这格有没有牙"。
        // 为什么三个动词写成一组而不是三格备选（§190 实测）：`removeItem(` 字面**包含** `moveItem(`，
        // 分成三格时 `moveItem\(` 会把 `removeItem` 的样例盖住 —— 那正是这条名单要抓的形状，
        // 它第一次跑就抓住的是**我自己刚写下的那一版**。
        ("syncFileIO", #"|(?<!\w)(?:copy|move|remove)Item\("#, "try fileManager.copyItem(at: src, to: dst)"),
        ("syncFileIO", #"|(?<!\w)(?:copy|move|remove)Item\("#, "try fileManager.moveItem(at: tmp, to: url)"),
        ("syncFileIO", #"|(?<!\w)(?:copy|move|remove)Item\("#,
         "try? fileManager.removeItem(at: reportURL(for: project.id))"),
        // §184 那一格（写盘的 `.write(to:)`）也一并纳进来：这条名单不该只服务新词。
        ("syncFileIO", #"|\.write\(to(?:URL)?:"#, "try data.write(to: fileURL, options: .atomic)"),
    ]

    /// 把某一格备选从模式里**减掉**，样例必须因此打不中。
    ///
    /// 为什么要单独立一条（2026-09-27 §190）：`testScannerFiresOnBadSamples` 拿的是**整条**正则，
    /// 于是只要样例里另有一格形状先命中，这一格备选就是**零覆盖的字**——加它的人以为建了防线，
    /// 实际把它删掉也没有任何测试会红。我第一版正好踩中这件事：
    /// `FileManager.default.createFile(atPath: …)` 同时命中 `FileManager`，
    /// 那两格新备选其实没有被验过。减法是唯一能分清"这格有用"和"这格被邻居盖住"的办法。
    static func soleResponsibilityProblems() -> [String] {
        var problems: [String] = []
        for probe in soleResponsibilityProbes {
            guard let full = rules.first(where: { $0.name == probe.rule })?.pattern else {
                problems.append("\(probe.rule)：词表里没有这条规则，名单过期"); continue
            }
            let reduced = full.replacingOccurrences(of: probe.needle, with: "")
            guard reduced != full else {
                problems.append("\(probe.rule)：模式里找不到 \(probe.needle) ⇒ 名单过期，这一格没验成"); continue
            }
            guard (try? NSRegularExpression(pattern: reduced)) != nil else {
                problems.append("\(probe.rule)：去掉 \(probe.needle) 之后模式编不过 ⇒ 这一格没验成，不许当通过")
                continue
            }
            if matches(pattern: full, in: probe.sample).isEmpty {
                problems.append("\(probe.rule)：整条模式打不中样例 \(probe.sample)")
            }
            if matches(pattern: reduced, in: probe.sample).isEmpty == false {
                problems.append("\(probe.rule)：删掉 \(probe.needle) 仍命中 ⇒ 这格备选被样例里的另一格盖住，"
                                + "等于没加：\(probe.sample)")
            }
        }
        return problems
    }
}
