/// OWNER: WS-X3 TestSplit —— 自 DocReferenceRatchetTests.swift 拆出，尺子自身的双向元测试：文件作用域锚点、真索引金丝雀、死锚点要带原因。用例本体未改，只是搬了家。
import XCTest

extension DocReferenceRatchetTests {

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

}
