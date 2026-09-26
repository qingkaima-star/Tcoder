/// OWNER: WS-X3 TestSplit —— 自 DocReferenceRatchetTests.swift 拆出，尺子自身的双向元测试：文件作用域锚点、真索引金丝雀、死锚点要带原因。用例本体未改，只是搬了家。
/// 2026-09-23 追加：Tests 侧**声明采集器**（`declaredNames`）也搬进来了 ——
/// 主文件撞上 Tests 的 400 行门，而采集器与钉它的元测试本来就该一起改。
import Foundation
import XCTest

extension DocReferenceRatchetTests {

    /// Tests 侧索引的采集器：从一份源码文本里收**声明名**（类型名 + 方法名）。
    ///
    /// 关键字表必须覆盖 Swift 全部顶层类型声明族：头一版只写了 `class|struct|extension`，
    /// 于是 `enum` 型的**共享测试基座**在索引里压根不存在 —— 第一次撞上是 `SurfaceScanKit`
    /// （扫描型守卫的尺子本体），文档正常引用它的成员被判死。
    /// 方法名同理从"只认 `test` 前缀"放宽：基座成员（`codeLines` 那一类）没有 test 前缀。
    ///
    /// 采集前先剥整行注释：`// struct CommentOnly {}` 不是声明。判活集合一旦包含
    /// "哪里提到过这个名字"，它就测不出判据失效 —— 金丝雀当年正是这样不红的。
    /// 注意只剥**整行**注释：行尾注释里的名字仍会进来（台账 §6.40 末尾备着这条，没吹成已封）。
    static func declaredNames(in text: String) -> Set<String> {
        var found: Set<String> = []
        let code = SurfaceScanKit.codeLines(text).joined(separator: "\n")
        let patterns = [#"func\s+([A-Za-z_][A-Za-z0-9_]*)"#,
                        #"(?:class|struct|enum|actor|protocol|extension)\s+([A-Za-z0-9_]+)"#]
        let range = NSRange(location: 0, length: code.utf16.count)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: code, range: range) {
                // 不走主文件那个 `slice(in:)`：它是**每个尺子文件各一份**的私有帮手
                // （`DocBareLineReferenceTests` 里还有一份同名的），放宽成 internal 会直接重声明冲突。
                if let span = Range(match.range(at: 1), in: code) {
                    found.insert(String(code[span]))
                }
            }
        }
        return found
    }

    /// 把每条失效连同原因打印出来，交各流认领；不参与判定。
    func testDeadAnchorsAreReportedWithReasons() throws {
        let scan = scanDocs(with: try buildIndex())
        for token in scan.dead.keys.sorted() {
            print("  【失效】\(token) —— \(scan.dead[token] ?? "")")
        }
        XCTAssertEqual(scan.dead.count, Self.knownDeadAnchors.count, "打印出的失效条数与基线条数不等")
    }

    /// 合成小世界：`ContributorRows.swift` 存在、里面有 `ContributorRow` 和 `body`，
    /// 但 `ContributorRows` 作为**类型名**不存在——文档正是这么写的。
    /// 三个方向一起钉：豁免首段后判活、豁免后仍缺成员判死、谁都不认识的判死。
    func testRulerHandlesFileScopedAnchorsBothWays() throws {
        var index = CodeIndex()
        index.identifiers = ["ContributorRow", "body", "RealType", "realMember"]
        index.sourceFileStems = ["ContributorRows", "Real"]
        index.files = ["Real.swift": 10, "ContributorRows.swift": 120, "Guide.md": 3]

        // ① 文件名作用域：首段不是类型名，豁免后必须判活（第一版就栽在这里，误登记 33 条）。
        let fileScoped = "ContributorRows.ContributorRow.body"
        XCTAssertNil(resolve(classify(fileScoped), in: index).reason,
                     "活锚点 \(fileScoped) 被判死——第一版的口径错就在这里")
        XCTAssertTrue(resolve(classify(fileScoped), in: index).usedFileScope,
                      "首段 ContributorRows 应当被当作文件名吃掉，并记录这次豁免")

        // ② 豁免不是免死金牌：文件在、里面的成员没了，照样判死。
        XCTAssertNotNil(resolve(classify("ContributorRows.NotARealType.member"), in: index).reason,
                        "豁免首段之后必须继续核验剩下的段；这里判活等于把豁免改成第二个黑洞")

        // ③ 首段既不是文件名也不是标识符 -> 判死。
        for dead in ["GhostFile.NotARealType.member", "NonexistentTypeXYZ.someMember",
                     "RealType.removedMember", "Real.swift:99", "Ghost.swift:1", "A.B.NotThere"] {
            XCTAssertNotNil(resolve(classify(dead), in: index).reason, "死样例 \(dead) 被判成有效，尺子钝了")
        }

        // ④ 活样例必须放过，否则「逢报必红」的钝尺子也会自称在守护。
        for live in ["RealType.realMember", "Real.swift:10", "Real.swift", "Guide.md:3",
                     "ContributorRows.ContributorRow.body"] {
            XCTAssertNil(resolve(classify(live), in: index).reason, "活样例 \(live) 被判成失效，尺子在乱咬")
        }

        // ⑤ 行号边界：末行有效、多一行失效（不许恒真，也不许恒假）。
        XCTAssertNil(resolve(classify("Real.swift:10"), in: index).reason)
        XCTAssertEqual(resolve(classify("Real.swift:11"), in: index).reason,
                       "Real.swift 只有 10 行，引用了第 11 行")

        // ⑥ 分类本身也要对：示例清单名走 example，普通点号串走 symbol。
        if case .example = classify("package.json") {} else {
            XCTFail("package.json 应按示例清单名排除，而不是当成本仓文件引用")
        }
        if case .symbol = classify("LogsView.header") {} else {
            XCTFail("LogsView.header 应判为符号锚点")
        }
        XCTAssertEqual(tokens(in: "`\(fileScoped)`"), [fileScoped],
                       "样例没被正则扫出来的话，上面所有判定都是空谈")
    }

    /// 端到端金丝雀：真实索引 + 真实正则，过一段合成文本，双向都要对。
    func testEndToEndCanaryAgainstTheRealIndex() throws {
        let index = try buildIndex()
        let canary = """
        合成行：真实文件名作用域 `ContributorRows.ContributorRow.body`、真实纯符号 `LogsView.header`、
        假符号 `WsvCanaryDeadType.someMember`、假文件 `WsvCanaryFile.swift:999`、
        行号越界 `Package.swift:99999`。
        """
        let hits = tokens(in: canary)
        XCTAssertEqual(Set(hits), [
            "ContributorRows.ContributorRow.body", "LogsView.header", "WsvCanaryDeadType.someMember",
            "WsvCanaryFile.swift:999", "Package.swift:99999",
        ], "合成文本里的锚点没被全部扫到，正则或口径漂了")

        let dead = hits.filter { resolve(classify($0), in: index).reason != nil }.sorted()
        XCTAssertEqual(dead, ["Package.swift:99999", "WsvCanaryDeadType.someMember", "WsvCanaryFile.swift:999"],
                       "金丝雀没有被全部判红，或把真实锚点误判成了失效")
    }

    /// 第②份索引（`Tests/**`）的元测试。**两条都要有**：
    /// 只证"Tests 里的名字判活"等于把判据关掉——任何人都可以让它永远活。
    func testTestsSideAnchorsResolveWhileNonsenseStillDies() {
        var index = CodeIndex()
        index.identifiers = ["Widget", "spin"]
        index.sourceFileStems = ["Widget"]
        index.testIdentifiers = ["WidgetTests", "test_spinWorks"]

        XCTAssertNil(resolve(.symbol(segments: ["WidgetTests", "test_spinWorks"]), in: index).reason,
                     "只住在 Tests 里的守卫名必须判活；否则文档引用它只能写裸名，而裸名不成锚 = 永远不被校验")
        let dead = resolve(.symbol(segments: ["WidgetTests", "test_goneAway"]), in: index)
        XCTAssertNotNil(dead.reason, "两侧都没有的名字必须仍然判死")
        XCTAssertTrue(dead.reason?.contains("Tests") == true,
                      "失效原因要说清查了哪两侧：\(dead.reason ?? "nil")")
    }

    /// 收声明的那把正则**自己**的元测试：上一批补 Tests 侧索引时只测了"喂进 testIdentifiers
    /// 之后判活"，合成输入是手写集合，绕过了采集器 —— 于是 `enum` 不在关键字表里这件事
    /// 无人可测，`SurfaceScanKit.codeLines` 在真实索引里被判死才由文档门当场撞出来。
    /// 两个方向：声明族一个都不许漏（漏 = 正常引用判死），非声明里的名字一个都不许多
    /// （多 = 金丝雀被自己喂活，判据失效测不出来）。
    func testDeclarationCollectorCoversEveryNamedKindOnlyAtDeclarationSites() {
        let text = """
        enum ScanKit { static func codeLines(_ s: String) -> [String] { [] } }
        actor Ledger { private func trim() {} }
        protocol Ruler {}
        struct Shape {}
        final class SurfaceGuardTests: XCTestCase { func test_borderless() {} }
        extension SurfaceGuardTests { func helper() {} }
        let canary = "WsvCanaryDeadType.someMember 只是字符串，不是声明"
        // struct CommentOnly {} —— 整行注释不是声明，剥注释由 SurfaceScanKit.codeLines 负责
        """
        let found = Self.declaredNames(in: text)
        for name in ["ScanKit", "codeLines", "Ledger", "trim", "Ruler", "Shape",
                     "SurfaceGuardTests", "test_borderless", "helper"] {
            XCTAssertTrue(found.contains(name), "声明名 \(name) 没被收到 —— 文档引用它会判死")
        }
        for notADeclaration in ["WsvCanaryDeadType", "someMember", "CommentOnly"] {
            XCTAssertFalse(found.contains(notADeclaration),
                           "\(notADeclaration) 不是声明却被收了：判活集合一旦包含「哪里提到过」，"
                         + "它就再也测不出判据失效（金丝雀当年就是这样不红的）")
        }
    }

    /// 守恒等式自己的元测试：三个桶必须同为**出现次数**口径。
    /// 反例形状不是我编的，是 2026-09-27 那次真实塌陷 —— 探针把 11 卷整改台账接进扫描面之后，
    /// 等式左边的 915 是出现次数、右边的判死栏取自 `[名: 原因]` 那张表（唯一名），
    /// 11 名死锚在文档里被提了 16 次 ⇒ 凭空差 5 枚，尺子把"同一条死锚提了两次"
    /// 喊成了"有锚点被静默吞掉"。两个方向一起钉：重复出现要各算一次（否则口径又漂回唯一名），
    /// 而四桶不闭合才是真的吞掉。
    func testSymbolTallyBucketsClosePerOccurrence() {
        var scan = Scan()
        let deadResolution = Resolution(reason: "找不到 Member", usedFileScope: false, droppedSegment: nil)
        let plainLive = Resolution(reason: nil, usedFileScope: false, droppedSegment: nil)
        let scopedLive = Resolution(reason: nil, usedFileScope: true, droppedSegment: "CodeMetrics")
        Self.tally(.symbol(segments: ["CodeMetrics", "totalLines"]), scopedLive, into: &scan)
        Self.tally(.symbol(segments: ["AppState", "lastScan"]), plainLive, into: &scan)
        Self.tally(.symbol(segments: ["NotAReal", "Member"]), deadResolution, into: &scan)
        Self.tally(.symbol(segments: ["NotAReal", "Member"]), deadResolution, into: &scan)
        XCTAssertEqual(scan.deadSymbolHits, 2,
                       "同一条死锚提两次只算一次 = 又回到唯一名口径，等式会凭空欠账")
        XCTAssertEqual(scan.symbolCount,
                       scan.symbolFileScopedLive + scan.symbolPlainLive + scan.deadSymbolHits,
                       "四桶不闭合：有锚点既没算活也没算死，这一格才是「静默吞掉」")
    }

    /// 示例清单名这张豁免表**改成存在性判据**（#104）：只有"本仓没有这个文件"才免检。
    /// 两个方向一起钉着，缺一边等于没修：
    /// ① 本仓真有的 python 长尺必须进文件锚点分母（写越界行号要判死、界内要判活）；
    /// ② 用户项目的 `package.json` 必须仍旧豁免（否则扫别人仓库的清单名会全体判红）；
    /// ③ 问不到索引时（合成小世界、纯分类自证）退回旧的按扩展名豁免，不然那些夹具会凭空地变红。
    func testExampleManifestExemptionIsAnExistenceTestNotAnExtensionTax() {
        var index = CodeIndex()
        index.files["trace_report.py"] = 500
        guard case .file = classify("trace_report.py:9999", in: index) else {
            return XCTFail("本仓真有的 .py 仍被按扩展名免检 ⇒ 自家尺子的引用永远不进分母")
        }
        XCTAssertNotNil(resolve(classify("trace_report.py:9999", in: index), in: index).reason,
                        "越界行号没判死：`.py` 被收进分母只是形式，判据没接上")
        XCTAssertNil(resolve(classify("scripts/trace_report.py:120", in: index), in: index).reason,
                     "界内行号判死了（带路径的写法要按文件名去查行数，否则是新的假红）")
        guard case .example(ext: "json") = classify("package.json", in: index) else {
            return XCTFail("package.json 本仓没有，必须仍按示例清单名豁免")
        }
        guard case .example(ext: "py") = classify("report.py:12", in: nil) else {
            return XCTFail("拿不到索引时要退回旧行为，否则合成夹具会凭空地变红")
        }
    }

}
