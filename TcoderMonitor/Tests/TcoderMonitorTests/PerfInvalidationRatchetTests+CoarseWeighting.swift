import XCTest
@testable import TcoderMonitor

/// 「粗读点收益分级」那一整段（原 §3.6）搬出来单独成文件。
///
/// 为什么不留在主文件里：主文件加完那段就是 **781 行**，离本仓 800 行上限只剩 19 行——
/// 再写一条测试就会把 main 弄红，而**拆文件才是修复，改阈值不是**（这条已被反复钉过）。
/// 为什么不干脆**复制一份口径**过去：那正是 #44 的形状（两套同名规则并存，错的那套在喂结论）。
/// 所以这段留在同一个类的 extension 里，共用主文件的 `coarsePattern` / `scanHits` / `codeLines`
/// ——它们从 `private` 放开成 `internal` 只为了这一件事，全仓**仍然只有这一把尺子**。
extension PerfInvalidationRatchetTests {
    // MARK: - 3.6 粗读点的**收益分级**：从 `publish()` 现读，不是一份手抄名单

    /// 派单时最容易撒错的地方：「16 处」看着像 16 份等价收益，其实**只有两处粗属性是无闸门写**。
    /// 所以这条不描述源码，它**读源码**：谁给 `latestSnapshot` 补了闸门、或新加了一处裸赋值，
    /// 这里会红，逼他回来改口径——而不是留下一份和代码不符的名单（本仓 #44 那类事故的形状）。
    static let ungatedCoarseSymbols: Set<String> = ["latestSnapshot", "history"]
    static let gatedCoarseSymbols: Set<String> = ["topProcesses", "processesByMemory", "trackedGroups",
                                                  "measuredProcessCount", "processMetricsTruncated"]
    /// 声明就带 `@ObservationIgnored`：压根不在观察图里，读它不产生失效面。
    static let unobservedCoarseSymbols: Set<String> = ["allProcesses"]
    /// 计算属性别名：自己不写，但 getter 读别的粗属性 → 付的是**它所别名那一处**的代价。
    static let aliasCoarseSymbols: Set<String> = ["lastSampleAt"]

    /// 符号名单只有一处真相：从 `coarsePattern` 的交替组里现取。
    static func coarseSymbols(fromPattern pattern: String) -> [String] {
        guard let open = pattern.firstIndex(of: "("),
              let close = pattern.firstIndex(of: ")"), open < close else { return [] }
        return pattern[pattern.index(after: open)..<close].split(separator: "|").map(String.init)
    }

    private static func matches(_ line: String, _ pattern: String) -> Bool {
        line.range(of: pattern, options: .regularExpression) != nil
    }

    /// 抽 `publish(_:)` 的函数体。**每 tick 的写法只由这一个函数决定**：
    /// `refreshGroups()` 里那句 `trackedGroups = next` 是"用户改了组"才跑的一次性裸写，
    /// 拿它去判"每 tick 成本"会把一处顺手写读成承重写（第一次跑这条就被它抓到了）。
    /// 边界用「下一行正好是四个空格 + `}`」——本仓 Swift 缩进风格；故意不用括号计数：
    /// 在字符串/注释里数括号越界过一次，教训见《开缺陷单前先对齐口径》。
    /// 锚点写 `func publish(` 而不是 `private func publish(`：改可见性、加 `@MainActor`
    /// 都是常见动作，锚点越具体越容易在没人注意时悄悄抽不到东西（这条是刚才两轮破坏性试验换来的）。
    static func publishBody(of text: String) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: { $0.contains("func publish(") }) else { return [] }
        var body: [String] = []
        for line in lines[(start + 1)...] {
            if line == "    }" { return body }
            body.append(line)
        }
        return body          // 找不到收尾 → 交给下面那道分母闸判红，不在这里猜
    }

    /// 分母闸（纯函数，好被双向钉住）：抽出来的行数够不够撑起"这就是整段写界面的地方"。
    /// 真值现在是 33 行；门槛取 12——远低于真值（正常改动不会误报），远高于"锚点没匹配上"的 0。
    static let minimumPublishBodyLines = 12

    static func tickBodyIsUsable(_ body: [String]) -> Bool {
        body.count >= minimumPublishBodyLines
    }

    /// 纯函数：返回「符号 → 归类」。判定只看三件事——
    /// 声明上有没有 `@ObservationIgnored`、是不是读别的粗属性的别名、**每 tick 那一写**是裸赋值还是过闸门。
    /// 顺序是有意的：`allProcesses` 既被裸写又不在观察图里，而"不在图里"才是结论
    /// （裸写一个不参与观察的属性不产生失效面）。
    /// 同一个属性在一 tick 之内既裸写又闸门写 = `"冲突"`：那是"闸门只加了一半"的形状，宁可问人也不要自己挑一个。
    static func classifyCoarseWrites(declarations: [String], tickBody: [String],
                                     symbols: [String]) -> [String: String] {
        let decls = declarations.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        let code = tickBody.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        var result: [String: String] = [:]
        for symbol in symbols {
            let isUnobserved = decls.contains { $0.contains("@ObservationIgnored") && $0.contains("var \(symbol)") }
            let otherSymbols = symbols.filter { $0 != symbol }
            let isAlias = decls.contains { line in
                guard Self.matches(line, #"var \#(symbol)\b[^={]*\{\s*\S"#) else { return false }
                return otherSymbols.contains { Self.matches(line, #"\b\#($0)\b"#) }
            }
            let isUngated = code.contains { Self.matches($0, #"^\s*(?:self\.)?\#(symbol)\s*=[^=]"#) }
            let isGated = code.contains { Self.matches($0, #"write\(\s*\\\.\#(symbol)\b"#) }
            switch (isUnobserved, isAlias, isUngated, isGated) {
            case (true, _, _, _): result[symbol] = "unobserved"
            case (_, true, _, _): result[symbol] = "alias"
            case (_, _, true, true): result[symbol] = "冲突"
            case (_, _, true, _): result[symbol] = "ungated"
            case (_, _, _, true): result[symbol] = "gated"
            default: result[symbol] = "未归类"
            }
        }
        return result
    }

    private func monitorSourceText() throws -> String {
        let url = Self.moduleRoot.appendingPathComponent(
            "Sources/TcoderMonitor/Services/Performance/MachSystemMonitor.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// 真文件 + 真口径：分类必须和源码一致。
    private func classifiedCoarseWrites() throws -> (classified: [String: String],
                                                     tickBodyLines: Int,
                                                     offTickBareWrites: [String]) {
        let text = try monitorSourceText()
        let body = Self.publishBody(of: text)
        // 分母闸：提取器坏了会让"没人裸写粗属性"变成假绿，所以先量它抽到了多少行。
        XCTAssertTrue(Self.tickBodyIsUsable(body),
                      "只从 `publish()` 抽到 \(body.count) 行（门槛 \(Self.minimumPublishBodyLines)），"
                    + "边界判定坏了 → 下面的分级不可信")
        let symbols = Self.coarseSymbols(fromPattern: Self.coarsePattern)
        let classified = Self.classifyCoarseWrites(declarations: Self.codeLines(of: text).map(\.text),
                                                  tickBody: body, symbols: symbols)
        // 「tick 之外还有谁裸写粗属性」是**披露**不是判红：一次性写不是每 tick 成本，
        // 但也不能当它不存在——迁移完成后整个兼容层要删，这些点得跟着一起消失。
        let inBody = Set(body)
        let offTick = Self.codeLines(of: text).filter { line in
            guard !inBody.contains(line.text) else { return false }
            return symbols.contains { Self.matches(line.text, #"^\s*(?:self\.)?\#($0)\s*=[^=]"#) }
        }.map { "MachSystemMonitor.swift:\($0.number) \($0.text.trimmingCharacters(in: .whitespaces))" }
        return (classified, body.count, offTick)
    }

    func testCoarseWriteCostClassMatchesPublishSource() throws {
        let symbols = Self.coarseSymbols(fromPattern: Self.coarsePattern)
        XCTAssertEqual(Set(symbols), Self.ungatedCoarseSymbols.union(Self.gatedCoarseSymbols)
                       .union(Self.unobservedCoarseSymbols).union(Self.aliasCoarseSymbols),
                       "`coarsePattern` 的禁则名单与收益分级的名单不是同一批符号了：\(symbols)")
        let probe = try classifiedCoarseWrites()
        let classified = probe.classified
        XCTAssertEqual(classified.values.filter { $0 == "冲突" || $0 == "未归类" }, [],
                       "有粗属性在同一个 tick 内既被裸写又被闸门写（或谁都没写），收益分级无法成立：\(classified)")
        func bucket(_ name: String) -> Set<String> {
            Set(classified.filter { $0.value == name }.map { $0.key })
        }
        XCTAssertEqual(bucket("ungated"), Self.ungatedCoarseSymbols, "无闸门写的粗属性变了")
        XCTAssertEqual(bucket("gated"), Self.gatedCoarseSymbols, "走等值闸门的粗属性变了")
        XCTAssertEqual(bucket("unobserved"), Self.unobservedCoarseSymbols)
        XCTAssertEqual(bucket("alias"), Self.aliasCoarseSymbols)
        let offTick = probe.offTickBareWrites.joined(separator: " | ")
        print("【收益分级的依据】`publish()` 抽到 \(probe.tickBodyLines) 行；"
            + "无闸门写 \(Self.ungatedCoarseSymbols.count) 处 / 已走闸门 \(Self.gatedCoarseSymbols.count) 处"
            + " / 不在观察图 \(Self.unobservedCoarseSymbols.count) 处 / 别名 \(Self.aliasCoarseSymbols.count) 处"
            + "；tick 之外另有 \(probe.offTickBareWrites.count) 处裸写（一次性路径，随兼容层一起删）"
            + (offTick.isEmpty ? "" : "：" + offTick))
    }

    /// 元测试（双向）：分级必须真能把「裸写」和「闸门写」区分开，否则上面那条等于没测。
    /// 反向用例特意放了 `x == y` 比较、注释行（都不是写点），以及一处"同一 tick 里闸门只加了一半"的写点。
    func testCoarseWriteClassifierSeparatesGatedFromUngated() {
        let fixture = [
            "@ObservationIgnored private(set) var allProcesses: [ProcessSnapshot] = []",
            "private(set) var latestSnapshot: SystemSnapshot?",
            "private(set) var topProcesses: [ProcessSnapshot] = []",
            "var lastSampleAt: Date? { latestSnapshot?.timestamp }",
            "// latestSnapshot = 注释里提到写点，不算",
            "latestSnapshot = batch.snapshot",
            "history = frames",
            "write(\\.topProcesses, leads.cpuRanking, &stats)",
            "halfGated = batch.leads.something",
            "write(\\.halfGated, batch.leads.something, &stats)",
            "if latestSnapshot == batch.snapshot { return }",
        ]
        let symbols = ["latestSnapshot", "history", "topProcesses", "allProcesses", "lastSampleAt", "halfGated"]
        let classified = Self.classifyCoarseWrites(declarations: fixture, tickBody: fixture, symbols: symbols)
        XCTAssertEqual(classified["latestSnapshot"], "ungated", "裸赋值没被判成无闸门写 → 承重的会被漏掉")
        XCTAssertEqual(classified["history"], "ungated")
        XCTAssertEqual(classified["topProcesses"], "gated", "闸门写没被判出来 → 顺手的会被错当成收益")
        XCTAssertEqual(classified["allProcesses"], "unobserved",
                       "裸写一个 `@ObservationIgnored` 属性不该算成本：它压根不在观察图里")
        XCTAssertEqual(classified["lastSampleAt"], "alias",
                       "别名没认出来 → 会误判成「没人写它」，而它其实每 tick 都在付 latestSnapshot 的账")
        XCTAssertEqual(classified["halfGated"], "冲突",
                       "「同一 tick 既裸写又闸门写」必须判冲突——那正是闸门只加了一半、读数看着对其实白加的形状")
    }

    /// `publishBody` 是这套分级的**唯一取数口**，它自己也得双向钉：
    /// 抽少了（没找到）要走分母闸判红，抽多了（越界到下一个函数）会把一次性写当成每 tick 成本。
    func testPublishBodyExtractorStopsAtTheFunctionBoundary() {
        let source = """
        final class MachSystemMonitor {
            private(set) var latestSnapshot: SystemSnapshot?

            private func publish(_ batch: SampleBatch) {
                latestSnapshot = batch.snapshot
                write(\\.topProcesses, leads.cpuRanking, &stats)
            }

            private func refreshGroups() {
                trackedGroups = next
            }
        }
        """
        let body = Self.publishBody(of: source)
        XCTAssertEqual(body.filter { $0.contains("latestSnapshot =") }.count, 1,
                       "publish 体内那一处裸写没抽到 → 承重的会被漏判：\(body)")
        XCTAssertFalse(body.contains { $0.contains("trackedGroups") },
                       "越界到下一个函数了 → tick 外的一次性裸写会被读成每 tick 成本：\(body)")

        // 锚点不能比代码更挑剔：改可见性 / 加属性之后必须照样抽得到（刚才两轮破坏性试验换来的）。
        for variant in ["    func publish(_ batch: SampleBatch) {",
                        "    @MainActor func publish(_ batch: SampleBatch) {",
                        "    internal func publish(_ batch: SampleBatch) {"] {
            let rewritten = source.replacingOccurrences(
                of: "    private func publish(_ batch: SampleBatch) {", with: variant)
            XCTAssertEqual(Self.publishBody(of: rewritten).count, body.count,
                           "声明形式一改成「\(variant.trimmingCharacters(in: .whitespaces))」就抽不到东西了")
        }

        // 分母闸双向：没有 publish 必须返回空、空的必须被判不可用。
        // 少了这两条，"抽不到 → 零处裸写 → 全走闸门 → 收益分级看起来很好" 就是一条假绿的路径。
        let empty = Self.publishBody(of: "final class Nope { }")
        XCTAssertTrue(empty.isEmpty, "没有 `publish` 时不该硬猜出一个函数体")
        XCTAssertFalse(Self.tickBodyIsUsable(empty), "空体必须判不可用，否则分母闸是摆设")
        XCTAssertFalse(Self.tickBodyIsUsable(["        latestSnapshot = batch.snapshot"]),
                       "只抽到一行也必须是红的：那说明边界判定烂了")
        XCTAssertTrue(Self.tickBodyIsUsable(Array(repeating: "        x += 1",
                                                 count: Self.minimumPublishBodyLines)),
                      "刚好到门槛就该放行——门槛不该高到让正常改动天天误报")
    }

    /// 把分级落到**调用点计数**上：这一条打印的就是派单该看的两个数。
    /// 只断言"两者相加等于总命中"（分类完备），不断言各占几处——那是随迁移变的量。
    func testCoarseReadoutSitesSplitIntoLoadBearingAndIncidental() throws {
        let docs = try scannedConsumerDocs()
        let hits = try Self.scanHits(pattern: Self.coarsePattern, in: docs)
        let classified = try classifiedCoarseWrites().classified
        func symbol(of hit: String) -> String? {
            let token = hit.split(separator: " ").last.map(String.init) ?? hit
            return Self.coarseSymbols(fromPattern: Self.coarsePattern)
                .first { token.hasSuffix(".\($0)") || token == $0 }
        }
        var loadBearing = 0, incidental = 0, outOfGraph = 0, unknown = 0
        for hit in hits {
            switch classified[symbol(of: hit) ?? ""] {
            case "ungated", "alias": loadBearing += 1
            case "gated": incidental += 1
            case "unobserved": outOfGraph += 1
            default: unknown += 1
            }
        }
        XCTAssertEqual(unknown, 0, "有调用点落在分级之外 = 名单与禁则又各说各话了")
        XCTAssertEqual(outOfGraph, 0,
                       "有页面在读 `@ObservationIgnored` 的粗属性：不产生失效面，但那条属性的契约是「零读点」，"
                     + "由 testServiceSideKeepsDerivedValuesCachedAndNarrow 一起管")
        let line = "loadBearing=\(loadBearing) incidental=\(incidental) total=\(hits.count)\n"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tcoder-perf-migration-weighting.txt")
        try line.write(to: url, atomically: true, encoding: .utf8)
        print("【粗读点收益分级】承重（无闸门写/别名，每 tick 必重算）\(loadBearing) 处"
            + " / 顺手（已走等值闸门，单独迁它测不出差异）\(incidental) 处"
            + " / 合计 \(hits.count)（台账 \(url.lastPathComponent)）")
    }
}
