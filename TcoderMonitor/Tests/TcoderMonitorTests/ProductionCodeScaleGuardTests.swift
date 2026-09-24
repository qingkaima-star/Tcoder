import XCTest
@testable import TcoderMonitor

/// R40 · **RD-67 双分母并排** 的「一把尺子」守卫（台账卷四 §73）。
///
/// # 拦的是哪一件事
/// 新句子「生产码 N 行 / 全量 M 行」只有一个家：
/// `Services/Code/ProductionCodeScaleReadout.swift` 的 `ProductionCodeScaleReadout`。
/// 谁在别处再拼一遍（界面卡、CLI、评分解释文本里手写一份中文），同一件事就有了两把尺子，
/// 两把尺子迟早分叉 —— 那是 RD-38/48/51/62 反复立过的案。本守卫**按名字**扫 `Sources/**`
/// 的代码行（剥整行注释：注释里**讲**这句话不算第二把尺子），只许那一个文件命中。
///
/// # 为什么写成「按句子名字」而不是「按调用形状」
/// 按 `ProductionCodeScaleReadout.reading(` 这种调用形状扫，换一种写法（换个参数名、
/// 拆成两行、改成局部变量）就扫不到 —— 本仓那条教训原话是「换个调用形状就扫不到正是教训」。
/// 名字扫的是**产物**（句子里那两个词），绕不过去。
///
/// # 分母非零自证（这一型缺了就是永真绿）
/// 「全仓只有装配口命中」这句话，在**装配口自己也数不到那四枚键**时同样成立 ⇒ 空转。
/// 所以同一条守卫先要求装配口那四枚整句键各命中 ≥1 一次，缺一枚当场红；
/// 元测试再把「注入第二份副本判红 / 只在注释里提不算 / 空扫描面不作数」三格钉住。
final class ProductionCodeScaleGuardTests: XCTestCase {

    // MARK: - 尺子（纯函数：只吃 [(路径, 内容)]，坏样例在内存里造，不往仓库塞假文件）

    /// 唯一装配口的相对路径（相对 `Sources/TcoderMonitor/`）。
    static let home = "Services/Code/ProductionCodeScaleReadout.swift"

    /// 一行里同时出现这两个词，就算「在拼这一句」（不是按调用形状）。
    static let markers = ["生产码", "全量"]

    /// 装配口那四枚整句键的**头部**：三条缺席态 + 弱判定打折那一条。
    /// 它们必须在装配口自己的代码行里各命中一次 —— 这就是那条「分母非零自证」。
    static let keyHeads = [
        "生产码 %1$lld 行 / 全量 %2$lld 行",
        "生产码 -- / 全量 %lld 行",
        "生产码这一档这次量到的是零",
        "生产码里 %lld 个文件只有语言证据",
    ]

    /// 剥掉整行注释之后的代码行。
    static func codeLines(_ content: String) -> [String] {
        content.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
    }

    /// 这一句的**拼装行**：代码行里同时含全部标记词才算。
    static func assembledLines(_ content: String) -> [String] {
        codeLines(content).filter { line in markers.allSatisfy { line.contains($0) } }
    }

    static func assemblesSentence(_ content: String) -> Bool {
        !assembledLines(content).isEmpty
    }

    /// 装配口里各枚键命中几次（一枚都没命中 ⇒ 判据在空转）。
    static func keyTally(in content: String) -> [String: Int] {
        let lines = codeLines(content)
        var tally: [String: Int] = [:]
        for head in keyHeads {
            tally[head] = lines.filter { $0.contains(head) }.count
        }
        return tally
    }

    // MARK: - 判据一：全仓只有那一个家在拼这一句

    func testOnlyTheAssemblyPointWritesThisSentence() throws {
        let files = try SurfaceScanKit.sourceFiles(under: "")
        XCTAssertGreaterThanOrEqual(files.count, 60,
                                    "只扫到 \(files.count) 个 Sources 文件 ⇒ 扫描面坏了，下面的绿不作数")
        var offenders: [String] = []
        var homeHits = 0
        for file in files {
            let hits = Self.assembledLines(file.content).count
            guard hits > 0 else { continue }
            if file.path.hasSuffix(Self.home) { homeHits += hits } else { offenders.append(file.path) }
        }
        // 分母非零自证：装配口自己数不到这句 ⇒ 判据在空转，当场红。
        XCTAssertGreaterThan(homeHits, 0,
                             "装配口 \(Self.home) 一处都没命中 ⇒ 键名或路径改了，整条守卫在空转")
        XCTAssertTrue(offenders.isEmpty,
                      "全仓出现了第二处拼这一句的地方（第二把尺子）：\n" + offenders.sorted().joined(separator: "\n"))
        print("【R40 一把尺子】装配口 \(Self.home) 拼了这一句的代码行 \(homeHits) 行；"
            + "第二把尺子 \(offenders.count) 处；扫描面 \(files.count) 个 Sources 文件")
        Self.recordLedger(homeHits: homeHits, offenders: offenders.count, surface: files.count)
    }

    /// 四枚键逐一自证（一枚没落地就是尺子在空转，而不是「这一句已经不需要了」）。
    func testAssemblyPointActuallyCarriesEveryKey() throws {
        let content = try Self.source(Self.home)
        XCTAssertFalse(content.isEmpty, "读不到装配口本体 ⇒ 本文件全部判据不作数")
        let tally = Self.keyTally(in: content)
        let missing = tally.filter { $0.value == 0 }.keys.sorted()
        XCTAssertTrue(missing.isEmpty,
                      "装配口里数不到这些整句键（守卫的分母掉到 0，不是句子变少了）：\(missing)")
        XCTAssertEqual(tally.count, Self.keyHeads.count, "四枚键的名单与自证数不上")
    }

    // MARK: - 判据二：两个上屏出口必须接在那一个家上（只查「没有第二处」不够）

    func testBothProductOutletsReadTheAssemblyPoint() throws {
        for outlet in ["Views/Code/CodeMetricsView.swift", "Views/Health/HealthView.swift"] {
            let content = try Self.source(outlet)
            XCTAssertFalse(content.isEmpty, "上屏出口 \(outlet) 读不到")
            XCTAssertTrue(content.contains("ProductionCodeScaleReadout."),
                          "\(outlet) 没接唯一装配口 ⇒ 那一格又在沉默")
            // 界面里手写一份中文 = 第二把尺子原地复活（RD-62 那条同形判据）。
            XCTAssertTrue(Self.codeLines(content).filter { line in
                Self.markers.allSatisfy { line.contains($0) }
            }.isEmpty, "\(outlet) 里自己拼了这一句：\(outlet)")
        }
    }

    /// CLI 那一路这轮**没接**（`Services/CLI/**` 归 R39），但它也不许自己拼一句。
    func testCLIWritesNoSecondCopyOfThisSentence() throws {
        let files = try SurfaceScanKit.sourceFiles(under: "Services/CLI")
        XCTAssertGreaterThanOrEqual(files.count, 2, "CLI 目录只扫到 \(files.count) 个文件 ⇒ 分母不对")
        let offenders = files.filter { Self.assemblesSentence($0.content) }.map(\.path)
        XCTAssertTrue(offenders.isEmpty, "无头那一路另拼了一份 ⇒ \(offenders)")
    }

    // MARK: - 元测试：三格双向 + 空扫描面不作数

    func test_meta_singleRulerScannerCatchesASecondCopyAndSparesComments() {
        let copied = [(path: "Views/Code/Fake.swift",
                       content: "  Text(\"生产码 3 行 / 全量 9 行\")\n")]
        XCTAssertEqual(Self.assembledLines(copied[0].content).count, 1, "坏样例没落到代码行上")
        XCTAssertTrue(Self.assemblesSentence(copied[0].content), "第二把尺子没被抓到 ⇒ 这条守卫是摆设")

        let commented = [(path: "Views/Code/Fake2.swift",
                          content: "  /// 这里不写「生产码 N 行 / 全量 M 行」，句子只有一个家\n")]
        XCTAssertFalse(Self.assemblesSentence(commented[0].content), "注释里讲这句话被判成第二把尺子")

        let unrelated = [(path: "Services/Code/Fake3.swift",
                          content: "  let roles = code.fileRoles?.share(for: .production)\n")]
        XCTAssertFalse(Self.assemblesSentence(unrelated[0].content), "同族但不同句的被误判")
    }

    /// 反向自证：喂一张空扫描面 / 喂一份没有装配口的清单，判据必须**报出问题**而不是绿。
    func test_meta_emptySurfaceIsNotAConclusion() {
        // 剥注释器自己要成立：只剩注释的文件不算拼了一句。
        XCTAssertTrue(Self.assembledLines("// 生产码 N 行 / 全量 M 行\n").isEmpty,
                      "整行注释没被剥掉 ⇒ 每个在注释里讲这句话的文件都会被当成第二把尺子")
        XCTAssertEqual(Self.assembledLines("Text(\"生产码 1 行 / 全量 2 行\")\n").count, 1,
                       "代码行被剥掉了 ⇒ 上面那条 0 处结论不可信")
        // 少了装配口那份文件，`homeHits` 就是 0 —— 判据一第一条断言正是拿它当分母。
        let withoutHome = [(path: "Views/RootView.swift", content: "import SwiftUI\n")]
        XCTAssertEqual(withoutHome.filter { Self.assemblesSentence($0.content) }.count, 0,
                       "干净清单被数成命中 ⇒ 上面的 0 处结论不可信")
        let tally = Self.keyTally(in: "enum Empty {}\n")
        XCTAssertEqual(tally.values.reduce(0, +), 0, "空文件里键命中数不为 0 ⇒ 自证器坏了")
        XCTAssertEqual(tally.count, Self.keyHeads.count, "自证器没有逐枚键各数一遍")
    }

    // MARK: - 落账（RD-64 第二条出口：读数不许只有 print 一个出口）

    private static func recordLedger(homeHits: Int, offenders: Int, surface: Int) {
        let readings = ["一把尺子 装配口 \(home) 命中 \(homeHits) 行",
                        "第二把尺子 \(offenders) 处",
                        "四枚整句键名单 \(keyHeads.count) 枚",
                        "扫描面 Sources 文件 \(surface) 个"]
        GuardLedger.record(guard: "ProductionCodeScaleGuardTests", readings: readings)
    }

    // MARK: - 小工具

    static func source(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TcoderMonitorTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // TcoderMonitor
            .appendingPathComponent("Sources/TcoderMonitor/" + relative)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}
