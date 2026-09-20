/// OWNER: WS-X3 TestSplit —— 自 PerfLogsBorderlessTests.swift 拆出，无分数走中性/占位、每页至多一枚主角、HealthRing 只出现一次。用例本体未改，只是搬了家。
import Foundation
import XCTest
@testable import TcoderMonitor

extension PerfLogsBorderlessTests {

    func test_noTertiaryOnMeasuredValuesInOwnedPages() throws {
        let hits = Self.tertiaryOnMeasuredValues(in: try ownedFiles())
        XCTAssertTrue(hits.isEmpty,
                      "读数值被涂成三级灰（风格契约 4「最重的墨给最重要的数」的反面）：\(hits)")
    }

    func test_ownedPagesStillUseTertiarySomewhere() throws {
        // 反向自证：三页仍然在路径 / 时间戳 / 分隔符上用着 `.tertiary`。
        // 没有这条，上面那个「0 命中」既可能是「都改对了」，也可能是「扫描器瞎了」——
        // 而这两种情况在测试输出上长得一模一样。
        let files = try ownedFiles()
        let total = files.reduce(0) { sum, file in
            sum + BorderlessSurfaceGuardTests.codeLines(file.content)
                .filter { $0.contains(".tertiary") }.count
        }
        XCTAssertGreaterThanOrEqual(total, 5,
                                    "全目录只剩 \(total) 处 `.tertiary`：判据①的 0 命中可能来自扫描器失灵")
    }

    func test_nilScoreIsNeutralAndNeverDanger() {
        let role = Theme.Semantic.role(forScore: nil)
        XCTAssertEqual(role.name, "neutral", "「从没扫过」不得画成「最危险」")
        XCTAssertNotEqual(role.name, "danger")
        XCTAssertNotEqual(role.name, "critical")
    }

    func test_nilScoreReadsAsPlaceholderNotZero() {
        XCTAssertEqual(HealthRing.scoreText(for: nil), DataAbsence.notAnalysed.display,
                       "环心里那份 nil 必须写成缺证据字面，写成 0 就是伪造结论")
    }

    func test_noInputCardStillPassesAnExplicitNilScore() throws {
        let files = try ownedFiles()
        let sites = files.filter { $0.content.contains("HealthRing(score: nil") }
        XCTAssertEqual(sites.count, 1,
                       "「无维度输入」那一态必须以显式 nil 进环；改成 0 会被读成「这个项目很差」")
    }

    func test_scoreNeverReadsThroughADefaultedZero() throws {
        let hits = Self.hits(in: try ownedFiles(), where: { line in
            (line.contains("forScore:") || line.contains("HealthRing(score:")) && line.contains("?? 0")
        })
        XCTAssertTrue(hits.isEmpty, "分数走了 `?? 0` 兜底，缺证据被冒充成 0 分：\(hits)")
    }

    func test_noHeroMetricInsideOwnedPages() throws {
        // 健康页那枚 56pt 由 `HealthRing`（`Views/Shell/`，归 WS-O）画，
        // 所以三页自己**一处都不许**再出现 heroMetric，否则同页两枚主角。
        let hits = Self.hits(in: try ownedFiles(), where: { $0.contains("heroMetric") })
        XCTAssertTrue(hits.isEmpty, "同页第二枚 heroMetric（56pt 归健康页的分数环）：\(hits)")
    }

    func test_noSecondProtagonistTierInOwnedPages() throws {
        let hits = Self.hits(in: try ownedFiles(), where: { $0.contains("Typo.metricNumber") })
        XCTAssertTrue(hits.isEmpty,
                      "页面自己抬 metricNumber(34) 会跟读数带与分数环抢位：\(hits)")
    }

    func test_healthRingAppearsAtMostOncePerStruct() throws {
        let files = try ownedFiles().filter { $0.path.hasPrefix("Views/Health/") }
        let counts = Self.symbolCountPerStruct(named: "HealthRing(", in: files)
        let doubled = counts.filter { $0.value > 1 }.sorted { $0.key < $1.key }
        XCTAssertTrue(doubled.isEmpty, "同一个视图里两枚分数环 = 两枚主角：\(doubled)")
        XCTAssertEqual(counts.values.reduce(0, +), 2,
                       "健康页应有两处 `HealthRing(`（有分 / 无维度输入），且分属两个互斥分支")
    }

}
