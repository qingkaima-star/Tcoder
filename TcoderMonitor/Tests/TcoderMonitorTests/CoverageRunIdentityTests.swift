import XCTest
@testable import TcoderMonitor

/// R5b · **运行身份**（`runKey`）与**合并可信度**（`mergeConfident`）的判据用例。
///
/// 这一整份全部打**纯函数**：吃字符串与 `/repo` 这种假根，不读盘、不起进程 ——
/// 因为"认不出哪次运行"这件事必须能在没有夹具的情况下被判出来。
/// 端到端那半在 `CoverageMergeTests` / `CoverageChainProofTests`。
final class CoverageRunIdentityTests: XCTestCase {

    private static let root = URL(fileURLWithPath: "/repo")

    /// 造一份候选（不读盘）。`ledger` 由 lcov 正文解析出来 —— 那也是纯函数。
    private func candidate(path: String,
                           format: CoverageReportFormat = .lcov,
                           covered: Int = 100,
                           total: Int = 200,
                           lcovBody: String? = nil,
                           stamp: String? = nil,
                           fingerprint: String? = "abc1234") -> CoverageCandidate {
        let report = CoverageReport(path: path, kind: .combined,
                                    toolName: format.toolName,
                                    linesCovered: covered, linesTotal: total,
                                    branchesCovered: 0, branchesTotal: nil,
                                    methodsCovered: 0, methodsTotal: 0,
                                    allLinesCovered: covered, allLinesTotal: total,
                                    allBranchesCovered: 0, allBranchesTotal: nil,
                                    scopeGranularity: lcovBody == nil ? .aggregateOnly : .perSourceFile)
        var ledger: CoverageLineLedger?
        if let body = lcovBody {
            ledger = CoverageAnalyzer.parseLCovWithLedger(text: body, url: URL(fileURLWithPath: path),
                                                          root: Self.root)?.ledger
        }
        return CoverageCandidate(
            report: report,
            identity: CoverageReportIdentity.derive(path: path, root: Self.root, format: format,
                                                    runStamp: stamp ?? ledgerRunStamp(body: lcovBody,
                                                                                       format: format)),
            binding: .unbound, ledger: ledger, sourceFingerprint: fingerprint)
    }

    private func ledgerRunStamp(body: String?, format: CoverageReportFormat) -> String? {
        guard let body else { return nil }
        return CoverageRunIdentity.runStamp(in: body, format: format)
    }

    private func fact(directory: String?, format: CoverageReportFormat = .lcov,
                      covered: Int = 120, total: Int = 200,
                      allCovered: Int? = nil, allTotal: Int? = nil,
                      stamp: String? = nil, signature: String? = nil)
        -> CoverageRunIdentity.Fact {
        CoverageRunIdentity.Fact(directoryKey: directory, format: format,
                                 linesCovered: covered, linesTotal: total,
                                 allLinesCovered: allCovered, allLinesTotal: allTotal,
                                 runStamp: stamp, lineSetSignature: signature)
    }

    // MARK: - 同一次运行的判据：正例

    /// 对偶格式 + 同目录 + 数字互相核对得上 ⇒ 同一次运行。
    func testCoPublishedPairWithAgreeingNumbersIsOneRun() {
        let lcov = fact(directory: "web/coverage")
        let summary = fact(directory: "web/coverage", format: .istanbulSummary)
        XCTAssertEqual(CoverageRunIdentity.corroborate(lcov, summary), .coPublishedPair)
    }

    /// 同目录、同格式、逐行账本一致 ⇒ 同一批证据的两个副本。
    func testIdenticalLineSetsAreOneRun() {
        let a = fact(directory: "coverage", signature: "src/a.ts:10/5:1,2,3")
        let b = fact(directory: "coverage", signature: "src/a.ts:10/5:1,2,3")
        XCTAssertEqual(CoverageRunIdentity.corroborate(a, b), .identicalLineSet)
    }

    // MARK: - 同一次运行的判据：反例（**宁可不合并，也不许凭猜合并**）

    /// 反例①：同目录、对偶格式，但**数字核不上** ⇒ 不是同一次运行。
    /// 这一条挡住的是"见目录就去重"：真见过一次 lcov 是全仓、摘要只算了入口目录的项目。
    func testCoPublishedPairWithDisagreeingNumbersIsNotOneRun() {
        let lcov = fact(directory: "web/coverage", covered: 120, total: 200)
        let summary = fact(directory: "web/coverage", format: .istanbulSummary, covered: 340, total: 400)
        XCTAssertEqual(CoverageRunIdentity.corroborate(lcov, summary), .none)
    }

    /// 反例②：**不同目录**的数字一样也不许并 —— 两个模块各写一份一模一样的数太常见了，
    /// 而去重是**丢证据**，双计只是数重复。方向必须往"分开呈现"倒。
    func testSameNumbersInDifferentDirectoriesAreNotOneRun() {
        let a = fact(directory: "pkg-a/coverage")
        let b = fact(directory: "pkg-b/coverage")
        XCTAssertEqual(CoverageRunIdentity.corroborate(a, b), .none)
    }

    /// 反例③：同目录、账本不一致 ⇒ 两次运行各自往同一个目录里写过东西。
    func testDifferentLineSetsInOneDirectoryAreNotOneRun() {
        let a = fact(directory: "coverage", signature: "src/a.ts:10/5:1,2,3")
        let b = fact(directory: "coverage", signature: "src/a.ts:10/9:1,2,3,4")
        XCTAssertEqual(CoverageRunIdentity.corroborate(a, b), .none)
    }

    /// 反例④：拿不出目录坐标（报告在被扫目录之外）⇒ 任何两份都不能算同一次运行。
    func testMissingDirectoryKeyNeverCorroborates() {
        let a = fact(directory: nil), b = fact(directory: nil)
        XCTAssertEqual(CoverageRunIdentity.corroborate(a, b), .none, "两份都没有目录坐标也能共享键 ⇒ 全并成一次")
    }

    // MARK: - 运行时刻只认正文

    func testRunStampComesFromReportBodyOnly() {
        XCTAssertEqual(CoverageRunIdentity.runStamp(in: #"<coverage timestamp="1680000000" version="7.4">"#,
                                                    format: .coveragePyXml), "1680000000")
        XCTAssertEqual(CoverageRunIdentity.runStamp(in: #"<coverage generated="1609459200" clover="3.2.0">"#,
                                                   format: .cloverXml), "1609459200")
        // 反例：lcov 正文里出现 `timestamp="…"` 也不算 —— 那个格式的正文没这一格。
        XCTAssertNil(CoverageRunIdentity.runStamp(in: #"# timestamp="1680000000""#, format: .lcov))
        XCTAssertNil(CoverageRunIdentity.runStamp(in: "{}", format: .istanbulSummary))
    }

    func testSameDirectorySameStampIsOneRun() {
        let a = fact(directory: "py/coverage", format: .coveragePyXml, stamp: "1680000000")
        let b = fact(directory: "py/coverage", format: .cloverXml, stamp: "1680000000")
        XCTAssertEqual(CoverageRunIdentity.corroborate(a, b), .sameDirectoryStamp)
        let older = fact(directory: "py/coverage", format: .cloverXml, stamp: "1680000999")
        XCTAssertEqual(CoverageRunIdentity.corroborate(a, older), .none, "时刻不同 ⇒ 两次运行")
    }

    // MARK: - runKey 分配（两份以上才发得出键）

    func testRunKeysAssignedOnlyWhereCorroborated() {
        let lcov = candidate(path: "/repo/web/coverage/lcov.info", covered: 120, total: 200,
                             lcovBody: "SF:src/a.ts\nLF:200\nLH:120\nend_of_record\n")
        let summary = candidate(path: "/repo/web/coverage/coverage-summary.json",
                                format: .istanbulSummary, covered: 120, total: 200)
        let keyed = CoverageRunIdentity.assignRunKeys(to: [summary, lcov])
        XCTAssertEqual(Set(keyed.compactMap { $0.identity.runKey }).count, 1, "两份应共享同一个键")
        XCTAssertNotNil(keyed.first?.identity.runKey)
        XCTAssertEqual(keyed.first?.identity.runEvidence, .coPublishedPair)

        // 同一批输入**核不上数字** ⇒ 两份都拿不到键（未知，不参与去重）。
        let mismatched = [candidate(path: "/repo/web/coverage/lcov.info", covered: 120, total: 200,
                                    lcovBody: "SF:src/a.ts\nLF:200\nLH:120\nend_of_record\n"),
                          candidate(path: "/repo/web/coverage/coverage-summary.json",
                                    format: .istanbulSummary, covered: 340, total: 400)]
        XCTAssertTrue(CoverageRunIdentity.assignRunKeys(to: mismatched)
                      .allSatisfy { $0.identity.runKey == nil },
                      "核不上还发键 ⇒ 就是凭目录猜同一次运行")
    }

    /// 与输入顺序无关（复现性）：同一批候选换顺序喂进去，键的分配结果必须一致。
    func testRunKeyAssignmentIsOrderIndependent() {
        let a = candidate(path: "/repo/web/coverage/lcov.info", covered: 120, total: 200,
                          lcovBody: "SF:src/a.ts\nLF:200\nLH:120\nend_of_record\n")
        let b = candidate(path: "/repo/web/coverage/coverage-summary.json",
                          format: .istanbulSummary, covered: 120, total: 200)
        let c = candidate(path: "/repo/pkg-b/coverage/lcov.info", covered: 50, total: 100,
                          lcovBody: "SF:src/b.ts\nLF:100\nLH:50\nend_of_record\n")
        func keys(_ list: [CoverageCandidate]) -> [String: String?] {
            Dictionary(uniqueKeysWithValues: list.map { ($0.report.path, $0.identity.runKey) })
        }
        let forward = keys(CoverageRunIdentity.assignRunKeys(to: [a, b, c]))
        let backward = keys(CoverageRunIdentity.assignRunKeys(to: [c, b, a]))
        XCTAssertEqual(forward, backward, "同一批候选换个输入顺序就分出两个键 ⇒ 读数不可复现")
    }

    /// 上一那条只试了**两个**顺序，而抹键的形状是"锚点何时被结算"，三个元素才有三种落点
    /// ⇒ 这里把 3! = 6 个排列全试一遍，并且**逐个断言键与证据档**（不只比相等）。
    /// 钉住的病：`assignRunKeys` 早期按输入下标遍历、锚点分支无条件写 `nil`，
    /// 于是同一批夹具换个临时目录名/换个读盘顺序就能从"合并成 1 份"变成"两份都算"（双计）。
    func testRunKeyAssignmentStaysIdenticalAcrossAllSixPermutations() {
        let lcov = candidate(path: "/repo/web/coverage/lcov.info", covered: 120, total: 200,
                             lcovBody: "SF:src/a.ts\nLF:200\nLH:120\nend_of_record\n")
        let summary = candidate(path: "/repo/web/coverage/coverage-summary.json",
                                format: .istanbulSummary, covered: 120, total: 200)
        let other = candidate(path: "/repo/pkg-b/coverage/lcov.info", covered: 50, total: 100,
                              lcovBody: "SF:src/b.ts\nLF:100\nLH:50\nend_of_record\n")
        let expected: [String: String?] = [
            "/repo/web/coverage/lcov.info": "dir=web/coverage",
            "/repo/web/coverage/coverage-summary.json": "dir=web/coverage",
            "/repo/pkg-b/coverage/lcov.info": nil,
        ]
        for permutation in permutations([lcov, summary, other]) {
            let keyed = CoverageRunIdentity.assignRunKeys(to: permutation)
            XCTAssertEqual(Dictionary(uniqueKeysWithValues: keyed.map { ($0.report.path, $0.identity.runKey) }),
                           expected, "排列 \(keyed.map { ($0.report.path as NSString).lastPathComponent }) 走出了别的键")
            // 证据档也要稳定：同一份报告在任何输入顺序里都必须"凭同一条证据"被认出来。
            XCTAssertEqual(Set(keyed.compactMap { entry -> String? in
                entry.identity.runKey.map { "\($0)|\(entry.identity.runEvidence?.rawValue ?? "-")" } }),
                           Set(["dir=web/coverage|coPublishedPair"]),
                           "互证成功的两份应共享同一个键与同一条证据档")
        }
    }

    /// 三个元素的全部排列（不引第三方库：手写递归，只在这条用例里用一次）。
    private func permutations<T>(_ items: [T]) -> [[T]] {
        guard !items.isEmpty else { return [[]] }
        var out: [[T]] = []
        for index in items.indices {
            var rest = items
            let head = rest.remove(at: index)
            out.append(contentsOf: permutations(rest).map { [head] + $0 })
        }
        return out
    }

    /// unit 与 integration 在两个目录里 ⇒ **绝不共用运行键**（R5 用"猜来的归类"挡住这件事，
    /// R5b 换成"目录坐标"挡住：同一批夹具换个临时目录名也不该变）。
    func testUnitAndIntegrationRunsAreNeverCollapsed() {
        let unit = candidate(path: "/repo/coverage/unit/lcov.info", covered: 78, total: 100,
                             lcovBody: "SF:a.ts\nLF:100\nLH:78\nend_of_record\n")
        let integration = candidate(path: "/repo/coverage/integration/lcov.info", covered: 54, total: 100,
                                    lcovBody: "SF:a.ts\nLF:100\nLH:54\nend_of_record\n")
        let keyed = CoverageRunIdentity.assignRunKeys(to: [unit, integration])
        XCTAssertTrue(keyed.allSatisfy { $0.identity.runKey == nil },
                      "两份既不同目录、又核不上账本 ⇒ 谁也不许替它们认一次运行")
        XCTAssertNotEqual(unit.identity.directoryKey, integration.identity.directoryKey)
    }

    // MARK: - mergeConfident：**身份互证**，不是份数

    func testConfidenceRequiresEveryIdentitySlot() {
        let complete = candidate(path: "/repo/web/coverage/lcov.info", covered: 120, total: 200,
                                 lcovBody: "SF:src/a.ts\nLF:200\nLH:120\nend_of_record\n")
        var keyed = complete
        keyed.identity.runKey = "dir=web/coverage"
        let verdict = CoverageMergeConfidence.verdict(included: [keyed], fingerprint: "abc1234",
                                                      gaveTotal: true, evidenceLeftOut: false,
                                                      conflictingFileCount: 0)
        XCTAssertEqual(verdict.confident, true, "四格身份齐 + 有逐行粒度 ⇒ 才谈得上 confident")
        XCTAssertTrue(verdict.gaps.isEmpty)

        // 缺源码指纹 ⇒ 不许 confident（这一档最容易被"只有一份报告"顺手放过）。
        let noFingerprint = CoverageMergeConfidence.verdict(included: [keyed], fingerprint: nil,
                                                            gaveTotal: true, evidenceLeftOut: false,
                                                            conflictingFileCount: 0)
        XCTAssertEqual(noFingerprint.confident, false)
        XCTAssertEqual(noFingerprint.gaps, [.unboundSource])

        // 缺运行归属 ⇒ 同上，并且点名是哪份。
        let noRun = CoverageMergeConfidence.verdict(included: [complete], fingerprint: "abc1234",
                                                   gaveTotal: true, evidenceLeftOut: false,
                                                   conflictingFileCount: 0)
        XCTAssertEqual(noRun.confident, false)
        XCTAssertEqual(noRun.gaps, [.unknownRun])
        XCTAssertEqual(noRun.missingByPath.first?.path, "/repo/web/coverage/lcov.info")
    }

    /// **`mergeConfident` 不许由"有几份报告"推出**：
    /// 一份身份齐全 ⇒ true；两份身份不齐 ⇒ false。份数在这里没有发言权。
    func testConfidenceIsNotAFunctionOfReportCount() {
        let oneComplete = candidate(path: "/repo/web/coverage/lcov.info", covered: 120, total: 200,
                                    lcovBody: "SF:src/a.ts\nLF:200\nLH:120\nend_of_record\n")
        var keyed = oneComplete
        keyed.identity.runKey = "dir=web/coverage"
        let single = CoverageMergeConfidence.verdict(included: [keyed], fingerprint: "abc1234",
                                                    gaveTotal: true, evidenceLeftOut: false,
                                                    conflictingFileCount: 0)
        XCTAssertEqual(single.confident, true)

        var secondIncomplete = keyed
        secondIncomplete.identity.moduleKey = nil          // 模块身份掉了
        secondIncomplete.identity.runKey = nil             // 运行身份也没了
        let pair = CoverageMergeConfidence.verdict(included: [keyed, secondIncomplete],
                                                   fingerprint: "abc1234", gaveTotal: true,
                                                   evidenceLeftOut: false, conflictingFileCount: 0)
        XCTAssertEqual(pair.confident, false, "两份里有一份身份不齐 ⇒ 整句就不许说'可信'")
        XCTAssertTrue(pair.gaps.contains(.unknownRun))
        XCTAssertTrue(pair.gaps.contains(.unknownModule))
    }

    /// `nil` 与 `false` 分家：**压根没给总数** ≠ 给了总数但身份不成立。
    func testNoTotalMeansNilConfidence() {
        let verdict = CoverageMergeConfidence.verdict(included: [], fingerprint: "abc1234",
                                                      gaveTotal: false, evidenceLeftOut: true,
                                                      conflictingFileCount: 2)
        XCTAssertNil(verdict.confident)
        XCTAssertTrue(verdict.gaps.isEmpty, "没给总数时不去数身份缺什么，那是另一件事")
    }

    /// 有证据没并进总数 ⇒ 既要点名"未互证"，也要单独点出"有东西没并进来"。
    func testLeftOutEvidenceIsItsOwnGap() {
        let verdict = CoverageMergeConfidence.verdict(included: [], fingerprint: "abc1234",
                                                      gaveTotal: true, evidenceLeftOut: true,
                                                      conflictingFileCount: 0)
        XCTAssertEqual(verdict.confident, false)
        XCTAssertEqual(verdict.gaps, [.evidenceLeftOut])
    }

    // MARK: - 逐行账本摘要（跨报告核对的坐标本身）

    func testLineSetSignatureIgnoresDictionaryOrderAndIsNilWithoutFileGranularity() throws {
        let one = CoverageAnalyzer.parseLCovWithLedger(
            text: "SF:a.ts\nDA:1,1\nDA:2,0\nLF:2\nLH:1\nend_of_record\n"
                + "SF:b.ts\nDA:1,1\nLF:1\nLH:1\nend_of_record\n",
            url: URL(fileURLWithPath: "/repo/coverage/lcov.info"), root: Self.root)
        let other = CoverageAnalyzer.parseLCovWithLedger(
            text: "SF:b.ts\nDA:1,1\nLF:1\nLH:1\nend_of_record\n"
                + "SF:a.ts\nDA:1,1\nDA:2,0\nLF:2\nLH:1\nend_of_record\n",
            url: URL(fileURLWithPath: "/repo/coverage/lcov.info"), root: Self.root)
        let first = CoverageRunIdentity.lineSetSignature(of: try XCTUnwrap(one?.ledger))
        let second = CoverageRunIdentity.lineSetSignature(of: try XCTUnwrap(other?.ledger))
        XCTAssertEqual(first, second, "同一批行、`SF:` 顺序不同 ⇒ 摘要必须一致（否则并集核对形同虚设）")
        XCTAssertNil(CoverageRunIdentity.lineSetSignature(of: nil))
        XCTAssertNil(CoverageRunIdentity.lineSetSignature(of: CoverageLineLedger()),
                     "没见过任何 `SF:` ⇒ 没有文件粒度，拿不出可比对的摘要")
    }
}
