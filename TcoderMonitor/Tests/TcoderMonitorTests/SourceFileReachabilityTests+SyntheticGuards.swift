/// OWNER: WS-X3 TestSplit —— 自 SourceFileReachabilityTests.swift 拆出，合成夹具侧的五条元守卫（孤儿文件/分片/注释与字符串/插值/取噪形状）。用例本体未改，只是搬了家。
import XCTest

extension SourceFileReachabilityTests {

    func testSyntheticOrphanFileIsJudgedUncalled() {
        // 名字全部全仓唯一，刻意避开 `Layout` / `crashExtensions` 这类碰撞名。
        let orphan = """
        import Foundation
        struct WSUProbeOrphanWidget {
            static let wsuProbeOrphanThreshold = 7
            func wsuProbeOrphanBody() -> Int { Self.wsuProbeOrphanThreshold }
        }
        """
        let consumer = """
        import Foundation
        enum WSUProbeConsumer {
            static func wsuProbeConsume() -> Int { wsuProbeAgain() + WSUProbeOtherKind.wsuProbeMadeValue }
        }
        struct WSUProbeOtherKind {
            static let wsuProbeMadeValue = 3
        }
        """
        // 分片式扩展：自己不声明类型，只靠「同作用域派发」活着（真仓里十几个分片全靠这条）
        let support = """
        import Foundation
        extension WSUProbeConsumer {
            static func wsuProbeAgain() -> Int { WSUProbeOtherKind.wsuProbeMadeValue }
        }
        """
        let out = Self.buildOutcome(synth([("WSUProbeOrphanWidget.swift", orphan, true),
                                           ("WSUProbeConsumer.swift", consumer, true),
                                           ("WSUProbeSupport.swift", support, true)]), whitelist: [])
        XCTAssertEqual(out.unused, ["WSUProbeOrphanWidget.swift"],
                       "零调用文件没被抓到，守卫就是空的（在用：\(out.inUse)）")
        XCTAssertEqual(out.inUse.sorted(), ["WSUProbeConsumer.swift", "WSUProbeSupport.swift"],
                       "把在用的合成文件一起判死，等于守卫放倒好例")
        XCTAssertTrue((out.evidence["WSUProbeOrphanWidget.swift"] ?? []).isEmpty, "死文件不许拿到任何证据")
        let g = Self.gate(out, whitelist: [])
        XCTAssertFalse(g.pass, "有未用文件时判定门必须失败")
        XCTAssertTrue(g.reasons.joined().contains("零调用实现文件 1 个"), "失败理由要点名：\(g.reasons)")
        XCTAssertTrue(g.reasons.joined().contains("WSUProbeOrphanWidget"), "失败理由要点到文件：\(g.reasons)")
    }

    func testExtensionShardFilesAreAllJudgedInUse() throws {
        let (docs, out) = try realOutcome()
        let analyses = docs.filter { $0.isProduction }.reduce(into: [String: RAnalysis]()) { acc, doc in
            acc[doc.relativePath] = Self.analyzeOne(Self.strippingNoise(doc.raw))
        }
        let shards = out.productionFiles.filter { path -> Bool in
            guard let a = analyses[path] else { return false }
            return a.topLevelTypes.isEmpty && !a.extensions.isEmpty
        }
        XCTAssertGreaterThanOrEqual(shards.count, 13,
                                    "不声明顶层类型的分片只剩 \(shards.count) 个（普查 13 个）—— 发现逻辑退化了")
        for named in Self.namedShardFiles {
            XCTAssertTrue(shards.contains(named), "普查点名的分片 \(named) 没被发现（类型/扩展解析变了）")
        }
        let killed = shards.filter { out.unused.contains($0) }
        XCTAssertTrue(killed.isEmpty, "扩展分片被误判成死码：\(killed)")
        let report = shards.map { path -> String in
            let exts = (analyses[path]?.extensions ?? []).sorted().joined(separator: ",")
            return "  \(path) [extension \(exts)] → \(self.firstEvidence(out, path))"
                + "（共 \((out.evidence[path] ?? []).count) 条）"
        }
        print("【WS-U 分片专项】不声明顶层类型的分片文件 \(shards.count) 个，逐个判在用，误杀 \(killed.count) 个：\n"
            + report.joined(separator: "\n"))
    }

    func testCommentsAndStringsDoNotForgeReferenceEvidence() {
        let orphan = """
        import Foundation
        struct WSUCommentOrphanType {
            static let wsuCommentOrphanField = 1
        }
        """
        let commenter = """
        import Foundation
        // WSUCommentOrphanType 在这里被提到，不算引用
        /* 块注释里再写一次 WSUCommentOrphanType
           嵌套 /* 还有 WSUCommentOrphanType */ */
        enum WSUCommenter {
            static let wsuNote = "WSUCommentOrphanType 只是个字符串"
            static func wsuUseControl() -> Int { WSUCommentControl.wsuControlValue }
        }
        """
        // 对照组：真代码互引，必须判在用（否则分不清「脱敏生效」与「脱敏器把一切都判死」）
        let control = """
        import Foundation
        struct WSUCommentControl {
            static let wsuControlValue = 5
            static let wsuEcho = WSUCommenter.wsuNote
        }
        """
        let out = Self.buildOutcome(synth([("WSUCommentOrphan.swift", orphan, true),
                                           ("WSUCommenter.swift", commenter, true),
                                           ("WSUCommentControl.swift", control, true)]), whitelist: [])
        XCTAssertEqual(out.unused, ["WSUCommentOrphan.swift"],
                       "注释/字符串里的名字被当成了引用 → 死码被洗活（在用：\(out.inUse)）")
        XCTAssertEqual(out.inUse.sorted(), ["WSUCommentControl.swift", "WSUCommenter.swift"],
                       "真互引的对照组没判在用：\(out.inUse)")
    }

    func testInterpolationInsideStringStillCountsAsCode() {
        // 反面：插值表达式里的引用是真的，脱敏器不能连它一起吞掉。
        // `WSUInterpTarget` 在语料里只出现在另一文件的插值里，它判活才说明插值被保住了。
        let target = """
        import Foundation
        struct WSUInterpTarget {
            static let wsuInterpValue = 2
            static let wsuMirror = WSUInterpUser.wsuInterpSeed
        }
        """
        let user = """
        import Foundation
        enum WSUInterpUser {
            static let wsuInterpSeed = 1
            static func line() -> String { "\\(WSUInterpTarget.wsuInterpValue) 项" }
        }
        """
        let out = Self.buildOutcome(synth([("WSUInterpTarget.swift", target, true),
                                           ("WSUInterpUser.swift", user, true)]), whitelist: [])
        XCTAssertTrue(out.inUse.contains("WSUInterpTarget.swift"),
                      "插值里的引用被吞掉，会把好文件判死：未用清单 \(out.unused)")
        XCTAssertEqual(out.unused, [])
    }

    func testStrippingHandlesEachNoiseShapeAndChangesRealFiles() throws {
        let fixtures = [("let a = 1 // commentTokenHere", "commentTokenHere", "let a = 1"),
                        ("let a = /* blockTokenHere */ 1", "blockTokenHere", "let a ="),
                        ("let n = /* out /* inTokenHere */ out */ 2", "inTokenHere", "let n ="),
                        ("let s = \"quotedTokenHere\" + y", "quotedTokenHere", "+ y"),
                        ("let r = #\"raw\"TokenHere\"# + z", "TokenHere", "+ z"),
                        ("let e = \"escaped \\\" TokenHere\" + w", "TokenHere", "+ w"),
                        ("let m = \"\"\"\n  multiTokenHere\n  \"\"\"\n", "multiTokenHere", "let m =")]
        for fixture in fixtures { assertNoiseGone(fixture.0, noise: fixture.1, code: fixture.2) }
        XCTAssertTrue(Self.strippingNoise("let s = \"\\(RealName.field)\"").contains("RealName.field"),
                      "插值表达式必须保留为代码")
        let production = try realDocs().filter { $0.isProduction }
        let changed = production.filter { Self.strippingNoise($0.raw) != $0.raw }
        XCTAssertGreaterThan(changed.count, production.count * 3 / 4,
                             "\(production.count) 个实现文件里只有 \(changed.count) 个脱敏后变化 —— 脱敏器空转")
        print("【WS-U 脱敏自证】剥掉注释与字符串后文本发生变化：\(changed.count)/\(production.count) 个实现文件")
    }

    private func assertNoiseGone(_ raw: String, noise: String, code: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let stripped = Self.strippingNoise(raw)
        XCTAssertEqual(stripped.count, raw.count, "脱敏必须等长（行号不能漂）：\(raw)", file: file, line: line)
        XCTAssertFalse(stripped.contains(noise), "噪声没被剥掉：[\(stripped)]", file: file, line: line)
        XCTAssertTrue(stripped.contains(code), "代码被误剥：[\(stripped)]", file: file, line: line)
    }

}
