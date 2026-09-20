/// OWNER: WS-X3 TestSplit —— 自 SourceFileReachabilityTests.swift 拆出，证据规则侧三条（碰撞名/白名单/弱证据点名）。用例本体未改，只是搬了家。
import XCTest

extension SourceFileReachabilityTests {

    func testCollisionNamesAreNotAcceptedAsEvidence() throws {
        let (docs, out) = try realOutcome()
        // 独立口径（行式正则，不借引擎的深度分析）数一遍每个类型名的声明点
        var sitesByName: [String: Set<String>] = [:]
        for doc in docs {
            for line in Self.strippingNoise(doc.raw).components(separatedBy: "\n") {
                for m in Self.matches(Self.independentTypeSiteRE, in: line) {
                    sitesByName[(line as NSString).substring(with: m.range(at: 1)), default: []].insert(doc.relativePath)
                }
            }
        }
        let colliding = sitesByName.filter { $0.value.count >= 2 }
        XCTAssertGreaterThan(sitesByName.count, 300,
                             "独立口径只数到 \(sitesByName.count) 个类型声明名——行式正则八成空转了")
        let laundered = out.productionFiles.flatMap { path -> [String] in
            (out.evidence[path] ?? []).compactMap { e in
                guard e.rule == .uniqueType else { return nil }
                let sites = sitesByName[e.symbol] ?? []
                return sites.count > 1 ? "\(path) 用 \(e.symbol)（独立口径声明点 \(sites.sorted())）" : nil
            }
        }
        XCTAssertTrue(laundered.isEmpty, "碰撞名被当成「全仓唯一声明」证据：\n\(laundered.joined(separator: "\n"))")
        // 真正的碰撞面在**成员名**上：普查点名的 `crashExtensions` 由两个文件各声明一次。
        // 判据 ②③④ 要求 `(Owner, member)` 成对唯一，所以裸成员名相同的两个持有者都得另找证据。
        var memberSites: [String: Set<String>] = [:]
        for doc in docs where doc.isProduction {
            for m in Self.analyzeOne(Self.strippingNoise(doc.raw)).members {
                memberSites[m.member, default: []].insert(doc.relativePath)
            }
        }
        XCTAssertGreaterThanOrEqual(memberSites.filter { $0.value.count >= 2 }.count, 10,
                                    "成员名碰撞只剩 \(memberSites.filter { $0.value.count >= 2 }.count) 个，"
                                    + "与普查（crashExtensions 这类至少两处）不符")
        XCTAssertTrue((memberSites["crashExtensions"] ?? []).count >= 2,
                      "普查点名的 crashExtensions 不再碰撞：\(memberSites["crashExtensions"] ?? [])")
        // 普查点名的两个持有者都不许靠裸名洗白
        for owner in ["Services/Logs/CrashReportPatterns.swift", "Services/Logs/LogDiscovery.swift"] {
            XCTAssertTrue(out.productionFiles.contains(owner), "扫描面里没有 \(owner)，普查口径变了")
            let bare = (out.evidence[owner] ?? []).filter { $0.rule == .uniqueType && $0.symbol == "crashExtensions" }
            XCTAssertTrue(bare.isEmpty, "\(owner) 靠裸名 crashExtensions 洗白：\(bare)")
        }
        print("【WS-U 碰撞点名】独立口径类型名 \(sitesByName.count) 个，其中同名 \(colliding.count) 个；"
            + "成员名碰撞 \(memberSites.filter { $0.value.count >= 2 }.count) 个（crashExtensions 声明点 "
            + "\((memberSites["crashExtensions"] ?? []).sorted().joined(separator: ", "))）")
        // 合成坏例：两个实现文件都声明 `WSUDuplicateLayout`，第三个其实是死文件。
        // 朴素 `grep -w` 会因为第一个文件里的出现把它判活；唯一性索引必须判死。
        let collide = Self.buildOutcome(synth([
            ("WSUReal.swift", "struct WSUDuplicateLayout { let wsuRealField = WSUUser.go() }", true),
            ("WSUUser.swift", "enum WSUUser { static func go() -> Int { _ = WSUDuplicateLayout.wsuRealField; return 1 } }", true),
            ("WSUDead.swift", "struct WSUDuplicateLayout { static let wsuDeadField = 9 }", true)]), whitelist: [])
        XCTAssertEqual(collide.unused, ["WSUDead.swift"], "碰撞名把死文件洗活了，守卫就白写：\(collide.unused)")
        XCTAssertEqual(collide.inUse.sorted(), ["WSUReal.swift", "WSUUser.swift"],
                       "对照组（碰撞名的另一持有者）没判在用：\(collide.inUse)")
    }

    func testWhitelistIsSmallJustifiedAndNotHidingADeadFile() throws {
        let (docs, out) = try realOutcome()
        XCTAssertEqual(out.whitelisted, Self.frameworkWhitelist.sorted(), "白名单条目必须都还在扫描面上")
        XCTAssertLessThanOrEqual(Self.frameworkWhitelist.count, 3, "白名单一长就该重新审：\(Self.frameworkWhitelist)")
        let raws = docs.reduce(into: [String: String]()) { $0[$1.relativePath] = $1.raw }
        for entry in Self.frameworkWhitelist {
            XCTAssertTrue(raws[entry]?.contains("@main") == true,
                          "白名单条目 \(entry) 正文里没有 @main，「框架隐式调度」这条理由不成立")
            XCTAssertFalse((out.evidence[entry] ?? []).isEmpty,
                           "白名单文件 \(entry) 其实零证据：它现在是死码，白名单不许替它兜着")
        }
        // 本守卫每轮默认跑到：不许出现「没设环境变量就 skip」的绿灯。探测词用拼接写——
        // 写成一整串会被本文件自身命中，断言就自缚了。
        let own = try String(contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8)
        for needle in ["XCT" + "Skip", "Process" + "Info", "get" + "env", "environ" + "ment"] {
            XCTAssertFalse(own.contains(needle), "守卫正文里出现了 \(needle)：门控绿灯就是没在跑的绿灯")
        }
        print("【WS-U 白名单】" + out.whitelisted.map { "\($0) → \(self.firstEvidence(out, $0))" }
            .joined(separator: " ; ") + "；无环境门控，每轮默认跑到")
    }

    func testFilesAliveOnlyByWeakerEvidenceAreNamedExplicitly() throws {
        let (_, out) = try realOutcome()
        let weakFirst = out.inUse.filter { path in
            guard let first = (out.evidence[path] ?? []).first else { return false }
            return first.rule == .dispatcher || first.rule == .staticShorthand
        }
        let roster = weakFirst.map { "  \($0) → \(self.firstEvidence(out, $0))" }.joined(separator: "\n")
        XCTAssertLessThan(weakFirst.count, 25,
                          "首条证据来自弱判据（③派发/④static简写）的文件有 \(weakFirst.count) 个，超过普查观测面。"
                          + "守卫在悄悄变松，先复核判据再谈改这个数：\n\(roster)")
        print("【WS-U 弱证据点名】在用 \(out.inUse.count) 个，其中首条证据是 ③派发/④static简写 的 "
            + "\(weakFirst.count) 个：\n\(roster)")
        XCTAssertTrue(out.unused.isEmpty, "未用文件：\(out.unused)")
    }

}
