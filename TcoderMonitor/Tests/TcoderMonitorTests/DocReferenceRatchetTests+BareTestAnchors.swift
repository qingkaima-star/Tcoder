// OWNER: WS-R35 DocAnchor（RD-66）—— 反引号里的**裸用例名**这一类锚点的判活尺子。
//
// # 这条流要堵的洞（不是理论问题，是 09-24 上午真踩到的）
// 主尺子 `DocReferenceRatchetTests.swift` 的 token 正则要求**至少一个点**才算锚。
// ⇒ 文档里写裸名 `` `testDigestIgnoresEnumerationOrder` `` 压根不成锚、永不判活。
// 现场：`cd4f3a3`（09-24 11:49）在 `docs/口径与已知限制.md:640` 引了这个名字，
// 而它当时只在**未合并的** `ws/rd31-scandrift`（`a50c9e7`，10:56）里，
// main 到 `f367c73`（12:41）才有它 —— 中间约 52 分钟 main 上挂着一句指向不存在的东西的引用，
// 而 12:13 那趟全量兜底（`40f9446`，`Executed 1745 tests, ... 0 failures`）全绿。
// 那趟兜底看不见它，是因为这个名字**既不是符号锚、也没被任何判据认领**：
// 判活索引里其实早有 `Tests/**` 的声明名（`testIdentifiers` 那份第二索引），
// 缺的只是让裸名**成锚**的那条提取规则。
//
// # 与既有尺子的关系：并列，不并桶
// 主尺子那条守恒 `symbolCount == 作用域判活 + 纯符号判活 + 判死` 与
// 基线 `knownDeadAnchors` 必须是空集这两件事**一个字未动**（工单第 2 条允许的第二种走法：
// 新判的这类**单独成一类 + 另加一条守恒**）。所以：
//   * 不修改主正则 ⇒ 主尺子的分母、三桶、行号棘轮全部原样；
//   * 裸用例名的死引用**不许**塞进 `knownDeadAnchors`（那条断言会红，那是有意的），
//     本类自己的死名上限是 `bareTestDeadCeiling` = 0。
// 两族天然不交：点号锚含 `.`，裸名按构造不含（元测试 `test_bareFamilyNeverOverlapsTheDottedAnchorFamily` 钉住）。
//
// # 判据（三件，缺一不可）
//   1. token 整段在反引号里；
//   2. 形如 `test` 紧跟**大写字母或下划线** ⇒ 天然放过 `test` / `tests` / `testing`
//      （`s` / `i` 是小写），也天然放过没进反引号的散文用法；
//   3. 整名长度 ≥ `bareTestNameMinLength`，**且这个门槛由本仓真实声明名自证**
//      （见 `test_bareGateIsBoundedByTheShortestRealTestName`）——
//      门槛高过仓库里最短的真实用例名就当场红，它不可能是免检通道。
// 判活对象是**声明位名字**：`Tests/**` + `Sources/**` 里 `func` / 类型声明 / `var` / `let` 的位置。
// 只认声明位这件事由 `test_bareCollectorTakesDeclarationSitesOnlyNotMentions` 钉住 ——
// 判活集合一旦包含「哪里提到过」，它就再也测不出判据失效（主尺子的金丝雀当年正是这样不红的）。
//
// ⚠️ 两处**没收紧**的限度（不吹成已封，同 §主尺子的写法）：
//   * `var` / `let` 只按行内形状认，分不清存储属性与函数体内的局部绑定 ⇒
//     一个只在某函数体里 `let testFoo = 1` 出现过的名字会被读成「有声明」。
//     为什么仍要收属性：文档里 `testIdentifiers` 这类裸名指的**就是** `CodeIndex` 的那个字段
//     （`docs/界面语言-批次台账-续.md:329`），只收 func/类型名会把一句真话判红。
//   * 只剥**整行**注释（沿用 `SurfaceScanKit.codeLines`）：行尾注释里的名字仍会进索引。
//     同族的另一半也成立：**字符串字面量不剥** ⇒ 测试夹具里原样写一行 func 声明，
//     那个名字就会进真实索引、把「假名判红」的元测试喂成永真。这一条有守卫：
//     `test_bareCanaryNamesAreAbsentFromTheRealIndex` 每次跑都点名核对金丝雀还在不在场，
//     本文件的夹具因此把 func 关键字做成运行时拼接（见那条元测试的注释）。
import Foundation
import XCTest

/// 裸用例名这一类锚点的读数桶。**独立于**主尺子的 `Scan`（见文件头「并列，不并桶」）。
struct BareAnchorScan {
    var pathsRead: [String] = []
    var occurrences = 0
    var distinct: Set<String> = []
    var live: Set<String> = []
    var dead: [String: String] = [:]
    var liveOccurrences = 0
    var deadOccurrences = 0
}

extension DocReferenceRatchetTests {

    /// 裸用例名的**长度门槛**（整名）。取 9 的理由：本仓 `Tests/**` + `Sources/**` 声明位上
    /// 最短的 `test` 形状名字实测是 `testFiles`（9 字符）⇒ 门槛 = 那个实测最小值时，
    /// 「比本仓任何真实用例名都短」是**唯一**能被放过的形状，真名字一枚都逃不掉判活。
    /// 再短的都是散文缩写/占位（`testID`、`testA`），要求它们判活只会训练人绕着守卫写文档。
    /// 这条常数不许自己涨：`test_bareGateIsBoundedByTheShortestRealTestName` 拿真实索引自证。
    static let bareTestNameMinLength = 9

    /// 死名上限。**只许往下调、不许往上抬**（现在已经是 0，抬无可抬）。
    static let bareTestDeadCeiling = 0

    /// 形状本体：`test` 紧跟**大写字母或下划线**（⇒ 天然放过 `test` / `tests` / `testing`，
    /// 那三个词的第五个字符是小写字母）。判 token 与判真实声明名**两处**都从这一份拼出来，
    /// 不写两遍字符类。
    static let bareTestShapeHead = "test[A-Z_]"
    static let bareTestShapeTail = "[A-Za-z0-9_]"

    /// 形状固定部分**实际吃掉多少个字符**：`test` 的 4 个 + 形状位的 1 个。
    /// 必须单独写这一枚：把正则源码的长度（`test[A-Z_]` 是 10 个字符）当成匹配长度代进
    /// 量词下界，门槛会静默漂成 15 个字符 —— 写这一版时就差点踩进去。
    static let bareTestFixedMatchLength = 5

    /// 正则从门槛**推导**，不另写一份长度 ⇒ 门槛与尺子只有一个来源。
    static func bareTestTokens(in text: String) -> [String] {
        let lower = Self.bareTestNameMinLength - bareTestFixedMatchLength
        let pattern = "`(\(bareTestShapeHead)\(bareTestShapeTail){\(lower),})`"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            XCTFail("裸用例名正则构造失败（门槛 \(Self.bareTestNameMinLength) 不合法）⇒ 这条尺子在空转")
            return []
        }
        let range = NSRange(location: 0, length: text.utf16.count)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let span = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[span])
        }
    }

    /// 造一枚「正好 `length` 个字符、形状合法」的名字，给门槛的算术自证用。
    /// `testA` 已经是合法形状的最短形态（5 个字符），后面按长度补齐。
    static func bareGateProbe(length: Int) -> String {
        "testA" + String(repeating: "b", count: max(0, length - bareTestFixedMatchLength))
    }

    /// 这一类锚点的**声明位**名字采集器 = 既有 `declaredNames`（func / 类型名，一字不改地复用）
    /// ∪ 属性名（`var` / `let`）。剥整行注释由 `SurfaceScanKit.codeLines` 负责，与主尺子同源。
    static func bareAnchorDeclarations(in text: String) -> Set<String> {
        var found = declaredNames(in: text)
        let code = SurfaceScanKit.codeLines(text).joined(separator: "\n")
        guard let regex = try? NSRegularExpression(pattern: #"(?:var|let)\s+([A-Za-z_][A-Za-z0-9_]*)"#)
        else { return found }
        let range = NSRange(location: 0, length: code.utf16.count)
        for match in regex.matches(in: code, range: range) {
            guard let span = Range(match.range(at: 1), in: code) else { continue }
            found.insert(String(code[span]))
        }
        return found
    }

    /// 建索引：`Tests/**` + `Sources/**` 两棵树的声明位名字。分母自证 ⇒ 空索引不当「全都判活了」用。
    func buildBareAnchorIndex() -> (names: Set<String>, filesWalked: Int) {
        var names: Set<String> = []
        var walked = 0
        for subpath in ["TcoderMonitor/Tests", "TcoderMonitor/Sources"] {
            let dir = Self.repoRoot.appendingPathComponent(subpath, isDirectory: true)
            walk(under: dir) { url in
                guard url.pathExtension == "swift",
                      let text = try? String(contentsOf: url, encoding: .utf8) else { return }
                walked += 1
                names.formUnion(Self.bareAnchorDeclarations(in: text))
            }
        }
        XCTAssertFalse(names.isEmpty, "声明索引是空集 ⇒ 裸名会全体判死，那是索引坏了不是文档死了")
        XCTAssertGreaterThan(walked, 100, "只走了 \(walked) 个 .swift，不像本仓规模 ⇒ 先怀疑路径口径")
        return (names, walked)
    }

    static func scanBareTestAnchors(in docs: [(path: String, content: String)],
                                    index: Set<String>) -> BareAnchorScan {
        var scan = BareAnchorScan()
        for doc in docs {
            scan.pathsRead.append(doc.path)
            for token in bareTestTokens(in: doc.content) {
                scan.occurrences += 1
                scan.distinct.insert(token)
                if index.contains(token) {
                    scan.live.insert(token)
                    scan.liveOccurrences += 1
                } else {
                    scan.dead[token] = "Tests/** 与 Sources/** 的声明位里没有这个名字"
                    scan.deadOccurrences += 1
                }
            }
        }
        return scan
    }

    /// 空转自曝：把「这条尺子这次到底量没量到东西」算成一句**可以被元测试双向检查**的话。
    /// 返回 nil 才是「在量东西且条条有归属」。
    static func bareIdleDiagnosis(for scan: BareAnchorScan, expectedPaths: [String]) -> String? {
        if scan.pathsRead.sorted() != expectedPaths.sorted() {
            return "扫描面与 `docs` 登记清单不等：读了 \(scan.pathsRead.sorted())，"
                 + "应有 \(expectedPaths.sorted())（复用别人的读文档入口 ⇒ 它一改这里就要响）"
        }
        if scan.occurrences == 0 {
            return "一枚裸用例名锚点都没扫到 ⇒ 先怀疑正则或文档面失效，零死锚此时是空转不是结论"
        }
        if scan.distinct.isEmpty {
            return "扫到 \(scan.occurrences) 处却一个唯一名都没有，聚合漂了"
        }
        if scan.occurrences != scan.liveOccurrences + scan.deadOccurrences {
            return "不守恒：\(scan.occurrences) 处 ≠ 判活 \(scan.liveOccurrences) + 判死 \(scan.deadOccurrences)"
        }
        if scan.distinct.count != scan.live.count + scan.dead.count {
            return "不守恒：唯一名 \(scan.distinct.count) ≠ 活 \(scan.live.count) + 死 \(scan.dead.count)"
        }
        return nil
    }

    // MARK: - 真语料：分母 + 守恒 + 台账（AGENTS §8 第 6.1 条：读数不许只有 print 一个出口）

    func test_bareTestAnchorsAreCountedAndConservedOnRealDocs() throws {
        let docs = try Self.readDocsForSectionPointerScan()
        let index = buildBareAnchorIndex()
        let scan = Self.scanBareTestAnchors(in: docs, index: index.names)
        if let problem = Self.bareIdleDiagnosis(for: scan, expectedPaths: Self.docs) {
            XCTFail("【RD-66 裸用例名】尺子自曝：\(problem)")
        }
        let readout = "裸用例名锚点 现量 \(scan.occurrences) 处 / 唯一名 \(scan.distinct.count) 枚"
            + "（判活 \(scan.liveOccurrences) 处 · 判死 \(scan.deadOccurrences) 处），"
            + "死名上限 \(Self.bareTestDeadCeiling) 条，扫描面 \(scan.pathsRead.count) 份文档，"
            + "声明索引 \(index.names.count) 个名字 / 走 \(index.filesWalked) 个 .swift"
        let gate = "门槛 现量 \(Self.bareTestNameMinLength) 字符 / 上限 仓库最短真实用例名"
            + " \(Self.shortestRealBareTestName(in: index.names)) 字符（门槛只许 ≤ 它）"
        print("【RD-66 裸用例名】" + readout)
        print("【RD-66 门槛】" + gate)
        GuardLedger.record(guard: "DocReferenceRatchetTests", readings: [readout, gate])
    }

    /// 门槛的自证：高过仓库里最短的真实用例名 ⇒ 有一批真名字落在判活之外，那条门槛就是自欺。
    func test_bareGateIsBoundedByTheShortestRealTestName() {
        let index = buildBareAnchorIndex()
        let shortest = Self.shortestRealBareTestName(in: index.names)
        XCTAssertGreaterThanOrEqual(shortest, Self.bareTestNameMinLength,
                                    "门槛 \(Self.bareTestNameMinLength) 高过本仓最短真实用例名 \(shortest) 字符"
                                  + " ⇒ 短于门槛的真名字永远不被校验，这条门槛变成免检通道")
        XCTAssertGreaterThanOrEqual(Self.bareTestNameMinLength, Self.bareTestFixedMatchLength,
                                    "门槛低于形状固定部分（\(Self.bareTestFixedMatchLength) 个字符）"
                                  + " ⇒ 推导出的量词下界是负数，尺子会整组空转")
    }

    static func shortestRealBareTestName(in names: Set<String>) -> Int {
        names.filter { Self.hasBareTestShape($0) }.map(\.count).min() ?? 0
    }

    /// 「形状像用例名」但**不带**长度门槛 —— 专给上面那条自证用。
    /// 必须另写这一把：拿带门槛的尺子去找最短真实名字会得到一条永真断言
    /// （短于门槛的名字压根进不了它的匹配，于是门槛多高都「自证通过」）。
    static func hasBareTestShape(_ name: String) -> Bool {
        let shape = "^\(bareTestShapeHead)\(bareTestShapeTail)*$"
        return name.range(of: shape, options: .regularExpression) != nil
    }

    /// 门槛的**算术**自证：正好门槛长度的名字要收，短一格的不收。
    /// 这条为什么要单独立：量词下界是从门槛**减**出来的，减错数（比如拿正则源码
    /// 长度当匹配长度）只会把门槛静默抬高，其余每条断言都照样绿。
    func test_bareGateArithmeticIsExact() {
        let n = Self.bareTestNameMinLength
        let atGate = Self.bareGateProbe(length: n)
        let belowGate = Self.bareGateProbe(length: n - 1)
        XCTAssertEqual(atGate.count, n, "探针本身没造到 \(n) 个字符 ⇒ 这条自证是空的")
        XCTAssertEqual(Self.bareTestTokens(in: "`\(atGate)`"), [atGate],
                       "正好门槛长度的名字不收 ⇒ 门槛算多了")
        XCTAssertEqual(Self.bareTestTokens(in: "`\(belowGate)`"), [],
                       "比门槛短一格却仍被收 ⇒ 门槛算少了，或者压根没用上")
    }

    /// 棘轮：这一类锚点当前**零豁免额度**。死名的处置只有两条路 ——
    /// 改文档（本仓 09-24 走的就是这条），或另开一张带归属与日期的豁免表；
    /// **不许**塞进 `knownDeadAnchors`（那条断言会红，那是有意的）。
    func test_bareTestAnchorsHaveNoDeadName() throws {
        let docs = try Self.readDocsForSectionPointerScan()
        let scan = Self.scanBareTestAnchors(in: docs, index: buildBareAnchorIndex().names)
        XCTAssertTrue(Self.knownDeadAnchors.isEmpty,
                      "裸用例名的死引用不许靠往主尺子基线里塞条目来消音（基线必须为空）")
        XCTAssertLessThanOrEqual(scan.dead.count, Self.bareTestDeadCeiling,
                                 "死名从 \(Self.bareTestDeadCeiling) 涨到 \(scan.dead.count) 枚："
                               + "\(scan.dead.keys.sorted())")
        XCTAssertEqual(scan.dead, [:], "裸用例名判死明细见上一条：\(scan.dead)")
    }

    // MARK: - 双向元测试：合成输入喂进去，四个方向一起钉（工单第 4 条）

    /// ①假名判红 + ②真名判活：同一个合成世界里两向都要成立。
    func test_bareDeadNameJudgedRedWhileRealNameJudgedGreen() {
        let index: Set<String> = ["test_R35SyntheticRealCase", "testIdentifiers", "Widget"]
        let docs = [("README.md", """
            真名 `test_R35SyntheticRealCase` 判活；假名 `test_R35NoSuchGuardAnywhereR35` 判红；
            字段名 `testIdentifiers` 也是声明位名字，判活；
            点号锚 `Widget.spin` 与散文里的 test / tests 都不归这一类管。
            """)]
        let scan = Self.scanBareTestAnchors(in: docs, index: index)
        XCTAssertEqual(Array(scan.distinct).sorted(),
                       ["testIdentifiers", "test_R35NoSuchGuardAnywhereR35", "test_R35SyntheticRealCase"],
                       "三枚该扫的裸名没全扫到 ⇒ 后面的判定都是空谈")
        XCTAssertEqual(scan.live, ["test_R35SyntheticRealCase", "testIdentifiers"])
        XCTAssertEqual(Array(scan.dead.keys), ["test_R35NoSuchGuardAnywhereR35"],
                       "假名字没被判红 ⇒ 这条尺子钝了")
        XCTAssertNil(Self.bareIdleDiagnosis(for: scan, expectedPaths: ["README.md"]))
    }

    /// ③散文不误伤：`test` / `tests` / `testing`、没进反引号的名字、短于门槛的缩写，一律不成锚。
    func test_bareProseWordsAndUnquotedNamesAreNotAnchors() {
        let text = """
        跑 test、tests、testing 这些词本来就在散文里。
        反引号包住的 `test`、`tests`、`testing`、`Testing` 也不算这一类锚。
        没进反引号的 testSomeGuardName 不算锚；进了反引号但短于门槛的 `testID`、`testA` 也不算。
        点号锚 `SomeTests.test_helper` 由主尺子管，这里不重复判。
        """
        XCTAssertEqual(Self.bareTestTokens(in: text), [],
                       "散文词或未加反引号的名字被当成锚 ⇒ 文档里正常写中文都会被判红")
    }

    /// ④空自曝：扫到 0 条必须出声，不许把「零死锚」读成结论。
    func test_bareScannerSelfReportsWhenItScansNothing() {
        let plain = [("README.md", "整段散文，一枚反引号锚点都没有。")]
        let empty = Self.scanBareTestAnchors(in: plain, index: ["test_R35SyntheticRealCase"])
        XCTAssertNotNil(Self.bareIdleDiagnosis(for: empty, expectedPaths: ["README.md"]),
                        "扫到 0 条却不报错 ⇒ 91 条里 skip 85 条那一族失效会重演")
        // 文档面少一份也要出声（这里复用了别人的读文档入口，漂移必须响）。
        XCTAssertNotNil(Self.bareIdleDiagnosis(for: empty, expectedPaths: ["README.md", "docs/x.md"]))
        // 不守恒也要出声：手搓一张漏归属的读数桶。
        var broken = empty
        broken.occurrences = 3
        broken.distinct = ["a", "b"]
        broken.live = ["a"]
        broken.liveOccurrences = 1
        broken.deadOccurrences = 1
        XCTAssertNotNil(Self.bareIdleDiagnosis(for: broken, expectedPaths: ["README.md"]),
                        "守恒破了却没自曝 ⇒ 守恒这条断言是装饰")
    }

    /// 采集器自己的元测试：只认声明位（合成输入直接喂采集器，不绕过它）。
    /// ⚠️ 夹具里的 func 关键字是**运行时拼出来的**（`\(fn)`），不写死：采集器只剥整行注释、
    /// 不剥字符串字面量，所以把 `func test_X() {}` 原样写进本文件的字符串里，`test_X` 就会被
    /// **本文件自己**喂进真实索引 ⇒ 「假名字判红」那两条元测试变成被夹具喂活的空断言。
    /// 第一版就是这么错的，被 `test_bareCanaryNamesAreAbsentFromTheRealIndex` 当场照出来。
    func test_bareCollectorTakesDeclarationSitesOnlyNotMentions() {
        let fn = "func"
        let text = """
        final class R35SyntheticTests: XCTestCase {
            var testIdentifiers: Set<String> = []
            \(fn) test_R35RealCase() {}
        }
        // \(fn) test_R35CommentedOut() {} —— 整行注释不是声明
        let canary = "test_R35StringLiteralOnly 只是字符串"
        \(fn) caller() { use(test_R35MentionedOnly) }
        """
        let found = Self.bareAnchorDeclarations(in: text)
        for declared in ["R35SyntheticTests", "testIdentifiers", "test_R35RealCase", "caller", "canary"] {
            XCTAssertTrue(found.contains(declared), "声明名 \(declared) 没收到 ⇒ 文档正常引用它会判红")
        }
        for mentioned in ["test_R35CommentedOut", "test_R35StringLiteralOnly", "test_R35MentionedOnly"] {
            XCTAssertFalse(found.contains(mentioned),
                           "\(mentioned) 不是声明却被收了：判活集合一旦包含「哪里提到过」，"
                         + "它就再也测不出判据失效（主尺子的金丝雀当年就是这样不红的）")
        }
    }

    /// 两族不交：裸名不进点号锚的正则，点号锚不进裸名的正则 ⇒ 同一枚 token 不会被两把尺子各判一次。
    func test_bareFamilyNeverOverlapsTheDottedAnchorFamily() {
        let text = "`test_R35RealCase` 与 `Widget.spin` 与 `Real.swift:12` 与 `package.json`"
        let bare = Self.bareTestTokens(in: text)
        let dotted = tokens(in: text)
        XCTAssertEqual(bare, ["test_R35RealCase"])
        XCTAssertEqual(Set(bare).intersection(Set(dotted)), [],
                       "同一枚 token 被两把尺子各判一次 ⇒ 两处的结论迟早分叉，谁也不知道读哪个")
        XCTAssertTrue(dotted.contains("Widget.spin"))
    }

    /// 金丝雀必须**真的**不在索引里：否则上面那条「假名判红」是被自己的测试文件喂活的空断言。
    func test_bareCanaryNamesAreAbsentFromTheRealIndex() {
        let index = buildBareAnchorIndex().names
        for canary in ["test_R35NoSuchGuardAnywhereR35", "test_R35SyntheticRealCase",
                       "testNoSuchGuardExistsAnywhere", "test_R35RealCase"] {
            XCTAssertFalse(index.contains(canary),
                           "金丝雀 \(canary) 竟然在真实索引里 ⇒ 判红那条元测试已经是空转")
        }
    }
}
