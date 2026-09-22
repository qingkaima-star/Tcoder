import XCTest
@testable import TcoderMonitor

/// OWNER: R2（Vue / TS 识别与模板字符串）—— 控制流关键字的**语法位置**判据（RD-09）。
///
/// 两头都要有样例，这是本仓反复踩过的两条：
/// * 正向：``box.if`` / `guardElse(if:)` 这类**名字或标签里带关键字**的写法不得算成分支
///   （正则 `\b…\b` 管不住点号与冒号，`.if` 以前白送一次复杂度）；
/// * 反向钉子：`ifLet(` / `.ifLet(` / `switchMap(` 这类**名字里含关键字前缀**的合法写法
///   不得被误扣分，而且**同一行上真的 `if` 必须照样加分** ——
///   否则"整行都不数"这种偷懒实现能让反向用例全绿（永真绿守卫）。
///
/// 期望值全部手算，写在每个夹具上面的算式里。
final class TsReservedKeywordBranchTests: XCTestCase {

    private func cc(_ lines: [String], _ language: String = "TypeScript") -> Int {
        ComplexityEngine.complexity(forLines: lines, language: language)
    }

    // MARK: - 正向：成员访问位与标签位不算控制流

    /// 手算：基线 1 + 第 3 行那个**真的** `if` = 2。
    /// 第 2 行 `box.if` 与第 6 行 `guardElse(if:` 各是属性名 / 参数标签，一条都不许加。
    func testMemberAndLabelPositionKeywordsAreNotBranches() {
        let fixture = [
            "function memberNamedIf(box: Box): number {",
            "  const picked = box.if",
            "  if (picked > 0) {",
            "    return picked",
            "  }",
            "  return guardElse(if: picked)",
            "}",
        ]
        XCTAssertEqual(cc(fixture), 2, "box.if 与 guardElse(if: 都是名字/标签，不是分支")
        // 分母钉子：同一个夹具里真 if 确实被数到了，规则不是"整行不数"
        XCTAssertEqual(cc(["  if (picked > 0) {"]), 2, "单独一行真 if 必须算 1 次分支（分母 > 0）")
    }

    /// 同一行上既有 `.if` 又有真 `if`：只许加一次。
    func testDottedKeywordOnSameLineAsRealIfCountsOnce() {
        let fixture = [
            "function bothOnOneLine(box: Box): number {",
            "  if (box.if > 0) { return box.if }",
            "  return 0",
            "}",
        ]
        XCTAssertEqual(cc(fixture), 2, "两个 `box.if` 都不加分，行首那个真 if 加 1 → 基线 1 + 1")
    }

    /// 对象字面量里键名叫 `if` / `case`：键名不是分支。
    func testObjectKeysNamedAfterKeywordsAreNotBranches() {
        let table = [
            "const TABLE = {",
            "  if: 1,",
            "  case: 2,",
            "  while: 3,",
            "}",
        ]
        XCTAssertEqual(cc(table), 1, "对象键名 `if` / `case` / `while` 一条都不算分支")
        XCTAssertEqual(cc(table + ["  if (x) { y() }"]), 2, "真 if 仍要 +1（反向：不许整行不数）")
    }

    // MARK: - Swift 侧同一条判据（本仓自己就是 Swift，`.if` 会直接影响自扫读数）

    /// 手算：基线 1 + 第 3 行真 `if` = 2。
    /// Swift 的关键字集合里有 `guard`：`guardElse(if:` 既不能靠 `guard` 命中（词边界挡掉），
    /// 也不能靠 `if:` 命中（标签位挡掉）。
    func testSwiftSideKeepsDottedAndLabelShapesOutOfCount() {
        let fixture = [
            "func choose(_ box: Holder) -> Int {",
            "    let picked = box.if",
            "    if picked > 0 { return picked }",
            "    return guardElse(if: picked)",
            "}",
        ]
        XCTAssertEqual(cc(fixture, "Swift"), 2, "Swift：box.if / guardElse(if: 都不加分，真 if 加 1")
    }

    // MARK: - 反向钉子：名字里含关键字前缀的合法写法不得被误扣分

    /// 手算：这一整个函数一条判定都没有 ⇒ CC 必须是 1。
    func testKeywordPrefixedIdentifiersAreNotPenalized() {
        let fixture = [
            "function nameShapes(value: Option): number {",
            "  const a = ifLet(value)",
            "  const b = mapper.switchMap(value)",
            "  const c = obj.ifLet(value)",
            "  const d = switchMapOf(value)",
            "  const e = forKey(which)",
            "  return a + b + c + d + e",
            "}",
        ]
        XCTAssertEqual(cc(fixture), 1,
                       "ifLet / switchMap / forKey 这些名字里带关键字前缀的写法不得被扣分")
    }

    /// 反向钉子的**配对**正例：同一行上真 `if` 必须照旧 +1。
    /// 没有这一条，上面那条可以用"把带括号的行整行跳过"这种偷懒实现骗过去（永真绿守卫）。
    func testRealBranchOnSameLineAsPrefixedNameStillCounts() {
        XCTAssertEqual(cc(["  if (isSet(value)) { return mapper.switchMap(value) }"]), 2,
                       "行里有 switchMap 时，真 if 仍必须 +1")
        XCTAssertEqual(cc(["  while (queue.ifNext()) { drain() }"]), 2, "真 while +1，`.ifNext` 不加分")
        XCTAssertEqual(cc(["  for (const k of keys) { use(k) }"], "TypeScript"), 2, "真 for +1")
    }

    /// 判据 2 的边界：`case 1:` 这类**真的** switch 分支不能被冒号判据误伤
    /// （`case` 与冒号之间隔着条件 `1`，命中的是条件表达式不是标签位）。
    /// 手算：一个 `case` + 一个 `if` = 基线 1 + 2 = 3；`default` 本来就不在关键字表里。
    func testCaseColonShapesAreStillBranches() {
        let fixture = [
            "function grade(mark: number): string {",
            "  switch (mark) {",
            "    case 1:",
            "      return \"a\"",
            "    default:",
            "      return \"b\"",
            "  }",
            "  if (mark > 0) { return \"c\" }",
            "}",
        ]
        XCTAssertEqual(cc(fixture), 3, "一个 case（+1）与一个 if（+1）都要算进基线 1；default 不算")
    }

    // MARK: - 元测试：证明这两条判据真的有牙（F②）

    /// 合成违例必须命中、合法写法不得误伤，而且**判据本身可被反证**：
    /// 把 `.if` 换成真 `if (` 之后分数必须变，说明加分的是语法位置不是词面。
    func testJudgementIsSensitiveToPositionNotWord() {
        let dotted = cc(["  const a = box.if", "  const b = box.if"])
        let real = cc(["  if (a) { return 1 }", "  if (b) { return 2 }"])
        XCTAssertEqual(dotted, 1, "两个 .if 都不加分")
        XCTAssertEqual(real, 3, "两个真 if 各加一分")
        XCTAssertGreaterThan(real, dotted, "判据必须是看语法位置的：位置不同分数就要不同")
        // 合法写法不得误伤：`x : T` 类型注解不是标签位关键字
        XCTAssertEqual(cc(["  const value: number = ifNumber(x)"]), 1, "类型注解的冒号不得触发标签判据")
    }

    /// 反证矩阵里 C / K 两处是靠**别的用例**转红的，两条判据本身没人对着测过
    /// （换个形状就可能空转）。这里直接按调用点钉一次：真判定 `[true]`、
    /// 点号位与标签位 `[false]`，带前缀的保留字挡、关键字前缀的正常标识符不挡。
    func testTheTwoJudgementsThemselvesAreNailed() {
        func positions(_ line: String, _ word: String) -> [Bool] {
            let text = line as NSString
            var out: [Bool] = []
            var search = NSRange(location: 0, length: text.length)
            while search.location < text.length {
                let at = text.range(of: word, options: [], range: search)
                if at.location == NSNotFound { break }
                out.append(ComplexityEngine.isControlFlowPosition(text, at))
                search = NSRange(location: at.location + at.length,
                                 length: text.length - at.location - at.length)
            }
            return out
        }
        XCTAssertEqual(positions("  if (a) { b() }", "if"), [true], "行首真 if 必须算判定")
        XCTAssertEqual(positions("  box.if == other.if", "if"), [false, false], "点号后的 if 一个都不许算")
        XCTAssertEqual(positions("  guardElse(if: x)", "if"), [false], "标签位的 if 不许算")
        XCTAssertEqual(positions("  case .a:", "case"), [true], "case 后跟模式不是冒号标签")
        // RD-38：这道过滤原来有两处（这里曾叫 `Scan.isReservedAfterPrefix`），
        // 现在唯一入口是 `FunctionRecognition.swift` 里的 `ComplexityEngine.isReservedSignatureName`，
        // 四条断言原样搬过来 —— 语义一字未改：含"只剥一个前导点"与"关键字前缀不许被挡"两条反例。
        XCTAssertTrue(ComplexityEngine.isReservedSignatureName(".if"), ".if 必须被认成保留字")
        XCTAssertTrue(ComplexityEngine.isReservedSignatureName("if"))
        XCTAssertFalse(ComplexityEngine.isReservedSignatureName(".render"), "正常方法名不许被挡")
        XCTAssertFalse(ComplexityEngine.isReservedSignatureName("ifLet"), "关键字前缀的标识符不许被挡")
        // 反例补一条：内部点不许剥（`obj.if` 是成员链的一部分，不是 `.if`）
        XCTAssertFalse(ComplexityEngine.isReservedSignatureName("obj.if"),
                       "只剥**前导**一个点；把内部点也剥掉就会误杀真实成员名")
    }

    /// RD-38 的结构钉：**"签名名字能不能收下"这件事只许有一个入口文件**。
    ///
    /// 为什么钉"文件"而不是钉"次数"：`isReservedName(` 在唯一入口内部本来就要被调两次
    /// （原样一次、剥点一次），数次数会得到 3 而让人以为没收干净。
    /// 真正的病是**第二个文件里再长出一个包装**（R2 那次就是因为不能改 R1 的文件才就地补的），
    /// 所以断言是：`Sources/**` 里凡出现 `isReservedName(` 的行，**必须全部**在
    /// `FunctionRecognition.swift` 里。少一条 = 判据空转，多一个文件 = 当场点名是谁。
    func testReservedNameFilterLivesInExactlyOneFile() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = packageRoot.appendingPathComponent("Sources")
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        let swiftFiles = (enumerator?.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? [])
        XCTAssertFalse(swiftFiles.isEmpty, "扫描面为空 —— 这条断言不作数")

        var hitsByFile: [String: Int] = [:]
        for url in swiftFiles {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            // 只数**代码行**：讲这段历史的注释里出现了四次那个旧名字，剥注释才有牙。
            let codeLines = text.components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            let count = codeLines.filter { $0.contains("isReservedName(") }.count
            if count > 0 { hitsByFile[url.lastPathComponent] = count }
        }
        // 钉的是"**只有一个文件**"，不是次数：定义那一行自己也含 `isReservedName(`，
        // 所以次数天然要 +1（第一版按 2 写就被真实值 3 判红了一次 —— 那是我算错，不是有人长出来）。
        XCTAssertEqual(Set(hitsByFile.keys), ["FunctionRecognition.swift"],
                       "保留字过滤又长出第二个入口文件了：\(hitsByFile) —— 只许 `isReservedSignatureName` 调它")
        XCTAssertGreaterThanOrEqual(hitsByFile.values.reduce(0, +), 2,
                                    "一处都没扫到 ⇒ 扫描面坏了，这条不算通过")
    }
}
