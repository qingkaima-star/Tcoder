// OWNER: WS-R41 EcoSysVerdict · RD-70 —— 从 `DependencyEcosystemCoverageTests.swift`
// 拆出来住：那个文件写完两族扫描守卫就 404 行，撞上 `X3TestSizeAuditTests`
// 与产品同口径的 400 行线。**判据、样例、数字一字未改，只换了住的地方** ——
// 与 `LocalizationGuardTests+KeyValidity.swift` 那一族同一个先例。
//
// 这里只放两件东西：⑤「第四号出口不许再读旧闸门」那把静态尺子，⑥ 它的元测试。
// 行为的正反用例（真红 / 反向 / 混合形状 / 三档不折叠）住在主文件。
import XCTest
@testable import TcoderMonitor

extension DependencyEcosystemCoverageTests {

    // MARK: - ⑤ 扫描型守卫：第四号出口不许再读那把旧闸门

    /// 旧闸门的字面特征：读 `hasVulnerabilityCoverage`，或再传那枚 `vulnerabilityUnchecked` 开关。
    static let legacyGateMarkers = ["hasVulnerabilityCoverage", "vulnerabilityUnchecked"]
    /// 唯一合法装配形状：卡头的档位由「子账 → `vulnerabilityCoverage`」出来。
    static let requiredWiring = ["subledger(forEcosystem:", "DependencyEvidence.vulnerabilityCoverage("]
    /// 入参声明位（**不许有默认值**：给了默认值就能被漏传）。
    static let parameterPrefix = "let vulnerabilityCoverage: DependencyVulnerabilityCoverage"
    /// 卡头 `body` 那三臂的表头（画法与槽位的绑定关系）。
    static let slotArms = ["case .riskBadge:", "case .partiallyChecked:", "case .unchecked:"]

    static func legacyGateHits(in files: [(path: String, content: String)]) -> [String] {
        var out: [String] = []
        for file in files {
            for line in SurfaceScanKit.codeLines(file.content) {
                for marker in legacyGateMarkers where line.contains(marker) {
                    out.append("\(file.path) → \(marker)")
                }
            }
        }
        return out.sorted()
    }

    static func wiringHits(in files: [(path: String, content: String)]) -> Set<String> {
        let code = files.flatMap { SurfaceScanKit.codeLines($0.content) }.joined(separator: "\n")
        return Set(requiredWiring.filter { code.contains($0) })
    }

    static func defaultedParameters(in files: [(path: String, content: String)]) -> [String] {
        var out: [String] = []
        for file in files {
            for line in SurfaceScanKit.codeLines(file.content) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix(parameterPrefix), trimmed.contains("=") {
                    out.append("\(file.path) → \(trimmed)")
                }
            }
        }
        return out
    }

    /// 卡头 `switch` 三臂的原文（按表头切片，遇下一臂或收尾 `}` 为止）。
    static func arms(ofBadge text: String) -> [String: String] {
        let lines = SurfaceScanKit.codeLines(text)
        var out: [String: String] = [:]
        for label in slotArms {
            guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == label })
            else { continue }
            var arm: [String] = []
            for line in lines[(start + 1)...] {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if slotArms.contains(trimmed) || trimmed == "}" { break }
                arm.append(trimmed)
            }
            out[label] = arm.joined(separator: "\n")
        }
        return out
    }

    /// 画法判据的纯函数版：槽位 ↔ 徽标绑错就报（元测试因此能在内存里造坏样例）。
    static func drawingFindings(arms: [String: String]) -> [String] {
        var out: [String] = []
        let expected: [(arm: String, must: String, mustNot: String)] = [
            ("case .riskBadge:", "RiskBadge(risk: eco.riskLevel)", "SemanticBadge("),
            ("case .partiallyChecked:", "SemanticBadge(\"部分核对\", role: Theme.Semantic.warning, icon: .unverified)", "RiskBadge("),
            ("case .unchecked:", "SemanticBadge(\"未核对\", role: Theme.Semantic.neutral, icon: .unverified)", "RiskBadge("),
        ]
        for rule in expected {
            guard let arm = arms[rule.arm] else {
                out.append("找不到 \(rule.arm) 那一臂（分派被改写或整格搬家了）")
                continue
            }
            if !arm.contains(rule.must) { out.append("\(rule.arm) 没画成「\(rule.must)」：\(arm)") }
            if arm.contains(rule.mustNot) { out.append("\(rule.arm) 里出现了 \(rule.mustNot)") }
        }
        // 话术那一半：两臂的 hover 只许取装配口那一句，不许在视图里现写带数的句子。
        for arm in ["case .partiallyChecked:", "case .unchecked:"] {
            guard let text = arms[arm] else { continue }
            if !text.contains(".help(coverage.statement)") {
                out.append("\(arm) 的 hover 不再取自唯一装配口：\(text)")
            }
        }
        return out
    }

    func testEcosystemCardIsWiredToThePerEcosystemTierOnly() throws {
        let files = try SurfaceScanKit.sourceFiles(under: "Views/Dependencies")
        XCTAssertGreaterThanOrEqual(files.count, 4,
                                    "只扫到 \(files.count) 个依赖页文件 ⇒ 扫描面坏了，下面全是永真绿")
        XCTAssertTrue(files.contains { $0.path.hasSuffix("DependenciesView.swift") },
                      "扫描面里没有 DependenciesView.swift ⇒ 这条守卫在空跑")
        XCTAssertEqual(Self.legacyGateHits(in: files), [],
                       "依赖页又去读那把「发过请求＝核对过」的旧闸门了（RD-11 在第四号出口复活）")
        XCTAssertEqual(Self.wiringHits(in: files), Set(Self.requiredWiring),
                       "卡头没接在唯一分档入口上（子账 / `vulnerabilityCoverage` 至少缺一条）")
        XCTAssertEqual(Self.defaultedParameters(in: files).count, 0,
                       "卡头的覆盖度入参被加了默认值 ⇒ 漏传就不会再有人知道")
        // 分母自证：入参声明位本身必须扫得到，否则上一条断言是空转。
        let declared = files.flatMap { SurfaceScanKit.codeLines($0.content) }
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix(Self.parameterPrefix) }
        XCTAssertEqual(declared.count, 1, "卡头入参声明位应当恰好一处，实得 \(declared)")

        // 画法那一层的绑定（尺子在内存里判，坏样例见下面的元测试）。
        let badge = try XCTUnwrap(files.first { $0.path.hasSuffix("DependencyAdvisoryRows.swift") }?.content,
                                  "扫不到卡头的宿主文件 ⇒ 这条在空跑")
        let arms = Self.arms(ofBadge: badge)
        XCTAssertEqual(arms.count, Self.slotArms.count, "三臂没扫全（分派被改写）：\(arms.keys.sorted())")
        XCTAssertEqual(Self.drawingFindings(arms: arms), [], "槽位与徽标的绑定被改写了")
    }

    // MARK: - ⑥ 元测试（扫描型守卫必须有牙）

    /// 起点那条「不该为 0 的桶归零」：改前这一格**零用例**
    /// （现量：`git grep -l DependencyEcosystemSection -- TcoderMonitor/Tests` 在改前是空集），
    /// 本条把"这一格有人管了"钉成机读事实，并给分母自证（扫不到测试文件当场红）。
    func testMeta_theZeroThatStartedThisCase() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".swift") }
        XCTAssertGreaterThanOrEqual(names.count, 100, "只数到 \(names.count) 个测试文件 ⇒ 分母不对")
        let readers = names.filter { name in
            let text = (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
            return text.contains("DependencyEcosystemBadge") || text.contains("DependencyEcosystemSection")
        }
        XCTAssertEqual(readers.sorted(), [
            "DependencyEcosystemCoverageTests+ScanGuards.swift",   // 本文件（静态尺子 + 元测试）
            "DependencyEcosystemCoverageTests.swift",              // 主文件（行为的正反用例）
        ], "卡头这一格的用例面变了（多一片要在此留名）：\(readers.sorted())")
        print("【RD-70 用例面】扫 Tests \(names.count) 个文件 → 读卡头那格的只有 \(readers.sorted())（改前 0 个）")
    }

    /// 注入第二处必红、只在注释里提一句不红、干净文件不红、画法绑错必红。
    func testMeta_cardRulersCatchInjectedCopiesAndSpareComments() throws {
        let dirty = [(path: "Views/Dependencies/Fake.swift",
                      content: "struct S { let x: Bool\n"
                         + "  init(_ d: DependencyReport) { x = d.hasVulnerabilityCoverage } }\n")]
        XCTAssertEqual(Set(Self.legacyGateHits(in: dirty)),
                       ["Views/Dependencies/Fake.swift → hasVulnerabilityCoverage"],
                       "旧闸门被抄回第二处却没抓到 ⇒ 这条守卫没有牙")
        let commented = [(path: "Views/Dependencies/Fake2.swift",
                          content: "// 旧判据是 deps.hasVulnerabilityCoverage == false —— 已废\n"
                              + "/// 别再传 vulnerabilityUnchecked 这一格\nstruct Clean { let y = 1 }\n")]
        XCTAssertTrue(Self.legacyGateHits(in: commented).isEmpty,
                      "注释里讲旧写法被判红 ⇒ 没人能在判据旁边解释它为什么存在")
        let clean = [(path: "Views/Dependencies/Fake3.swift", content: "enum Clean { let x = 1 }\n")]
        XCTAssertTrue(Self.legacyGateHits(in: clean).isEmpty, "干净文件被误报")
        XCTAssertTrue(Self.wiringHits(in: clean).isEmpty, "没接装配口的文件却被判「已接上」")

        // 默认值那把尺子双向：加了默认值要抓、没加不许抓。
        let defaulted = "  \(Self.parameterPrefix) = .none(total: 0)\n"
        XCTAssertEqual(Self.defaultedParameters(in: [(path: "Views/Dependencies/Fake4.swift",
                                                      content: defaulted)]).count, 1, "默认值没被抓到")
        XCTAssertTrue(Self.defaultedParameters(in: commented).isEmpty)

        // 画法那把尺子三向：把 `.unchecked` 那一臂改回 all-clear（本次缺陷的形状）必须红、
        // 把 hover 改成视图里现写的句子必须红、正确的三臂不许红。
        let wrongArm = ["case .riskBadge:": "RiskBadge(risk: eco.riskLevel)",
                        "case .partiallyChecked:": "SemanticBadge(\"部分核对\", role: Theme.Semantic.warning, icon: .unverified)\n.help(coverage.statement)",
                        "case .unchecked:": "RiskBadge(risk: .none)"]
        XCTAssertEqual(Self.drawingFindings(arms: wrongArm).count, 3,
                       "「未核对」那一臂被改回绿底对勾却没被抓全 ⇒ 画法这把尺子是空的")
        let handWrittenSentence = ["case .riskBadge:": "RiskBadge(risk: eco.riskLevel)",
                                   "case .partiallyChecked:": "SemanticBadge(\"部分核对\", role: Theme.Semantic.warning, icon: .unverified)\n.help(\"还有 1 个没查\")",
                                   "case .unchecked:": "SemanticBadge(\"未核对\", role: Theme.Semantic.neutral, icon: .unverified)\n.help(coverage.statement)"]
        let sentenceFindings = Self.drawingFindings(arms: handWrittenSentence)
        XCTAssertEqual(sentenceFindings.count, 1, "视图里现写覆盖度话术没被抓到（RD-68 的第二把嘴）")
        XCTAssertTrue(sentenceFindings.first?.contains("不再取自唯一装配口") == true,
                      "抓到的是别的东西，报错会指错方向：\(sentenceFindings)")
        let right = Self.arms(ofBadge: try XCTUnwrap(
            SurfaceScanKit.sourceFiles(under: "Views/Dependencies")
                .first { $0.path.hasSuffix("DependencyAdvisoryRows.swift") }?.content))
        XCTAssertTrue(Self.drawingFindings(arms: right).isEmpty, "正确的画法被误报：\(right)")
    }
}
