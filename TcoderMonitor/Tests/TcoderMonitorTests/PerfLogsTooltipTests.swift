import Foundation
import XCTest
@testable import TcoderMonitor

/// OWNER: WS-M S5 性能与日志两片（`Views/Performance/**`、`Views/Logs/**`、`Views/PerfLogs/**`）。
///
/// 这一页把碎文案收进 ⓘ 之后，需要有一把**属于本片的**尺子钉住两件事：
/// 1. 五条承担诚实性告知的承诺句在本片**仍然常驻**（全局尺子 `TooltipMigrationGuardTests`
///    的守卫 C 查的是整个 `Views/**`，别的产品页替它绿不代表本两片没被搬空）；
/// 2. 「留短藏长」搬走的整句**必须还有落点**——搬进 ⓘ 是搬家，删掉才是事故。
///
/// 尺子本身复用 `TooltipMigrationGuardTests` 的那一份（`sight` / `hiddenCommitments` /
/// `viewFiles`），**不重抄一遍正则**：两把不同的尺子量同一个约定，早晚量出两个结论。
/// 与全站规矩一致：扫描型断言各配"注入坏样例必须红"的元测试，且分母 > 0。
final class PerfLogsTooltipTests: XCTestCase {

    // MARK: - 本片的两片目录

    /// 只取性能与日志两片的文件（`PerfLogs/**` 是共用的数与组件，也算本片）。
    static func sliceFiles() throws -> [(path: String, content: String)] {
        try TooltipMigrationGuardTests.viewFiles().filter {
            $0.path.hasPrefix("Views/Performance/")
                || $0.path.hasPrefix("Views/Logs/")
                || $0.path.hasPrefix("Views/PerfLogs/")
        }
    }

    /// 本五句一旦只剩 hover，用户就会把「没量到」读成一个真实的 0。
    private static let mustRemainVisibleOnSlice: [String] = [
        "取不到的一律显示",        // PerformanceView.header
        "不会补成 0",              // 同上
        "不表示数量为 0",          // PerformanceProcessTableCard.honestyLegend
        "首个差分帧到达前",        // PerformanceSystemTiles 磁盘 / 网络两落点
        "轴不是 0 起点",           // PerformanceLiveCharts.axisNotes
    ]

    func test_sliceHonestyCommitmentsStayOnScreen() throws {
        let files = try Self.sliceFiles()
        XCTAssertGreaterThanOrEqual(files.count, 10,
                                    "本片只扫到 \(files.count) 个文件，读盘坏了")
        let offenders = TooltipMigrationGuardTests.hiddenCommitments(
            Self.mustRemainVisibleOnSlice, files: files)
        XCTAssertTrue(offenders.isEmpty,
                      "这些诚实性承诺在本两片不许只靠悬停看见：\n" + offenders.joined(separator: "\n"))
    }

    /// 「首个差分帧到达前」在两处 tile 的 caption 上，两处都得在（藏掉一处就少一次告知）。
    func test_firstDerivativeFrameNoticeKeepsBothLandings() throws {
        let files = try Self.sliceFiles()
        let sightings = TooltipMigrationGuardTests.sight("首个差分帧到达前", in: files)
            .filter { !$0.inTooltip }
        XCTAssertEqual(sightings.count, 2,
                       "磁盘与网络两枚 tile 的「不给速率」各要一处常驻，实扫 \(sightings.count) 处：\(sightings)")
        XCTAssertTrue(Set(sightings.map(\.path)).count == 1,
                      "两处应当都在 PerformanceSystemTiles 里（同一条口径不许各写一份）")
    }

    // MARK: - 搬走的整句必须仍有落点

    /// 「留短藏长」的成对表：屏上短句 → 必须仍然在源码里的完整长口径。
    /// 左列查的是**别把短句又写回长句**，右列查的是**别把长句顺手删掉**。
    private static let movedPairs: [(short: String, long: String)] = [
        ("这是「在用」", "口径 = 总量 −（空闲 + 推测 + 可清除）"),                       // 内存口径
        ("轴不是 0 起点", "带下限的轴是为看清走势而收窄的，不是 0 起点"),             // 轴口径
        ("个无证据读数", "引擎给出压力档 unknown 或字节数为 0"),                          // 剔除判据
        ("命中数为 0 只说明「这一帧没有匹配的进程」", "不说明服务出了问题。"),             // 零命中读法
        ("匹配模式 %@", "对进程名与命令行做包含匹配"),                                    // 分组规则
        ("规则本身不改变任何进程", "例如 java、nginx、mysqld"),                            // 编辑器
        ("该项目还没有日志分析结果", "选择项目目录后点「重新分析」"),                       // 日志横幅
        ("按代码规模归一：每千行", "分母来自同一次扫描的有效代码行"),                      // 归一口径
        ("柱状为错误 / 异常 / 崩溃按天堆叠", "台阶取轴"),                                  // 趋势轴口径
        ("按错误出现次数取前", "条形与百分比同为「占全部出现次数」的比重"),                // 受影响文件
    ]

    func test_movedCalibersStillHaveALandingPoint() throws {
        let files = try Self.sliceFiles()
        let joined = files.reduce("") { $0 + $1.content }
        XCTAssertFalse(joined.isEmpty, "本片一个字都没扫到，读盘坏了")
        for pair in Self.movedPairs {
            XCTAssertTrue(joined.contains(pair.short), "屏上短句被改掉了：\(pair.short)")
            XCTAssertTrue(joined.contains(pair.long),
                          "整句没了——搬进 ⓘ 是搬家，删掉才是事故：\(pair.long)")
        }
        print("【ⓘ·S5 落点】本片核对 \(Self.movedPairs.count) 对「短句→整句」，"
              + "另有 \(Self.mustRemainVisibleOnSlice.count) 条诚实性承诺断言常驻")
    }

    /// `PerformanceGroupCard` 三态各 85-95 字：屏上只许留 `title` + 下一步，
    /// 成因整句进 ⓘ。**三态的 message 不许被压成一句通用话**（那是改语义）。
    func test_groupCardThreeStatesStayDistinctAndMoveMessageIntoBadge() throws {
        let files = try Self.sliceFiles()
        let card = try XCTUnwrap(files.first { $0.path.hasSuffix("PerformanceProcessGroups.swift") })
        XCTAssertTrue(card.content.contains("CopyHelpBadge(copy.message)"),
                      "三态成因整句不再走 ⓘ，说明它被搬回屏上或被删了")
        XCTAssertFalse(card.content.contains("Text(copy.message)"),
                       "屏上还常驻 copy.message 就等于没做「留短藏长」")
        let messages: [String] = [GroupMatchState.waitingFirstSample, .pausedWithoutMatch, .noMatch]
            .map { PerformanceGroupCard.copy(for: $0, pattern: "java", totalProcesses: 512).message }
        XCTAssertEqual(Set(messages).count, 3, "三态被压成同一句话就是改了语义：" + messages.joined(separator: " | "))
        XCTAssertTrue(messages[1].contains("暂停") && messages[2].contains("java"),
                      "每态各自的判据词不许在搬字时掉出去")
    }

    // MARK: - 元测试：上面那把尺子必须抓得住坏样例

    func test_meta_sliceScannerCatchesHiddenCommitmentAndSparesKeptOne() {
        let hidden = [(path: "Views/Performance/Fake.swift", content: """
        NoteLine("内存")
            .help("取不到的一律显示 --，不会补成 0")
        """)]
        let flagged = TooltipMigrationGuardTests.hiddenCommitments(
            ["取不到的一律显示", "不会补成 0"], files: hidden)
        XCTAssertEqual(flagged.count, 2, "只剩 hover 的坏样例没被抓到 —— 这条断言是摆设")

        let kept = [(path: "Views/Performance/Fake.swift", content: """
        NoteLine("取不到的一律显示 --，不会补成 0", help: "数值随采样刷新")
        """)]
        XCTAssertTrue(TooltipMigrationGuardTests.hiddenCommitments(
            ["取不到的一律显示", "不会补成 0"], files: kept).isEmpty, "合法样例被误报")

        let deleted = [(path: "Views/Performance/Fake.swift", content: """
        NoteLine("系统级实时读数")
        """)]
        let missing = TooltipMigrationGuardTests.hiddenCommitments(
            ["取不到的一律显示"], files: deleted)
        XCTAssertEqual(missing.count, 1)
        XCTAssertTrue(missing[0].contains("整页找不到"),
                      "删干净必须单独点名，不能和「只剩 hover 可见」混成一条：" + missing.joined(separator: " "))
    }
}
