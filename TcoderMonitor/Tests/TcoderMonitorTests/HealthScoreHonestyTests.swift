import XCTest
@testable import TcoderMonitor

/// WS-C 健康评分单测：诚实性契约——缺证据不得给满分，未启用/降级/零命中必须显式区分。
/// 拆自 HealthScoreTests.swift，断言与用例一字未改（WS-V）。
final class HealthScoreHonestyTests: HealthScoreTestCase {
    /// 服务层字段到证据状态的判定必须是纯函数且覆盖三态（走契约派生态，不猜 note 文案）。
    func testVulnerabilityEvidenceClassificationCoversAllServiceShapes() {
        func report(_ mutate: (inout DependencyReport) -> Void) -> DependencyReport {
            var deps = DependencyReport(ecosystems: [mavenEcosystem(total: 140, outdated: 0)])
            mutate(&deps)
            return deps
        }
        // 默认离线：没联网、内置规则也没命中。
        XCTAssertEqual(VulnerabilityEvidence.classify(report { _ in () }), .unchecked,
                       "allowNetwork=false 的默认形态必须判成未核对")
        // note 的任意写法都不许改变结论（判据只看 hasVulnerabilityCoverage）。
        for note in ["", "无", "未启用联网核对", "本项目没有可在线查询的生态（SwiftPM / CocoaPods 不在 OSV 覆盖范围内）"] {
            XCTAssertEqual(VulnerabilityEvidence.classify(report { $0.networkLookupNote = note }), .unchecked,
                           "未联网时无论 note 怎么写都必须是未核对，note=\(note)")
        }
        // 开了网、查完了 —— "查完"这件事自 R3 起由**逐条状态**说，不再由 note 的字面说
        // （旧判据是 note 里有没有"失败"两个字，那等于让中文文案给业务状态授权，RD-13 点名）。
        XCTAssertEqual(VulnerabilityEvidence.classify(report {
            markAllChecked(&$0)
            $0.networkLookupPerformed = true
            $0.networkLookupNote = "在线查询已完成（OSV + npm registry）"
        }), .verified)
        // 开了网但部分失败：这里没有逐条账（旧报告的形状）⇒ 只能落到"试了没查完"，
        // 而不是"查过且干净"。note 里那句中文只是给人看的，**不参与判定**。
        XCTAssertEqual(VulnerabilityEvidence.classify(report {
            $0.networkLookupPerformed = true
            $0.networkLookupNote = "OSV：52 个包中 3 个查询失败"
        }), .degraded)
        // 内置规则已有命中：结论本身就是证据，即使没联网也必须计分（绝不能让带 CVE 的仓库分数变高）。
        var withVulnerabilities = report { _ in () }
        withVulnerabilities.advisories = advisories(count: 3)
        XCTAssertEqual(withVulnerabilities.vulnerableCount, 3, "夹具必须真造出 3 个受影响依赖")
        XCTAssertTrue(withVulnerabilities.hasVulnerabilityCoverage, "有 advisories 即视为有覆盖")
        XCTAssertEqual(VulnerabilityEvidence.classify(withVulnerabilities), .verified)
    }

    /// 端到端：默认离线 + 零命中 与 已联网 + 零命中 必须得到**不同**的结果与文案。
    /// 前者整个依赖维度缺席（不参与评分），后者才允许接近满分。
    func testOfflineDependenciesAreNotScoredWhileCheckedOnesAre() {
        let scorer = WeightedHealthScorer()
        let dependenciesName = HealthDimension.dependencies.rawValue

        let offline = scorer.score(HealthInputs(dependencies: offlineDependencies()))
        XCTAssertFalse(offline.components.contains { $0.name == dependenciesName },
                       "没核对过就不许给依赖分数，实际 \(offline.components.map(\.name))")
        XCTAssertEqual(offline.overall, 0, "唯一维度被摘掉后不得凭空给出综合分，实得 \(offline.overall)")
        XCTAssertFalse(offline.strengths.contains(where: { $0.contains("漏洞") }),
                       "没查过就不该把漏洞结论当优点报出来，实得 \(offline.strengths)")
        XCTAssertTrue(offline.recommendations.contains { $0.contains("不计分") },
                      "必须如实说明本维度暂不计分，实得 \(offline.recommendations)")

        let checked = scorer.score(HealthInputs(dependencies: cleanDependencies()))
        guard let component = checked.components.first(where: { $0.name == dependenciesName }) else {
            return XCTFail("已核对且零命中时依赖健康必须在场")
        }
        XCTAssertGreaterThanOrEqual(component.score, 95, "已核对零命中应接近满分，实得 \(component.score)")
        XCTAssertFalse(component.detail.contains("未做") && component.detail.contains("不计分"),
                       "已核对时不得出现未核对措辞，实得 \(component.detail)")
        XCTAssertTrue(checked.strengths.contains { $0.contains("已完成漏洞核对") },
                      "查过且干净才配进优点，实得 \(checked.strengths)")
        XCTAssertNotEqual(offline.overall, checked.overall, "两种形态必须得到不同结果")

        // 未联网但内置规则有命中：必须照常重扣，不能被「不计分」放过。
        var foundOffline = offlineDependencies()
        foundOffline.advisories = advisories(count: 12)
        let found = scorer.score(HealthInputs(dependencies: foundOffline))
        guard let foundComponent = found.components.first(where: { $0.name == dependenciesName }) else {
            return XCTFail("已有 12 个已知漏洞时依赖维度绝不能缺席，实际 \(found.components.map(\.name))")
        }
        XCTAssertLessThan(foundComponent.score, 40, "12 个漏洞必须重扣，实得 \(foundComponent.score)")
        XCTAssertTrue(found.issues.contains { $0.contains("12") }, "实得 \(found.issues)")

        // 查了但部分失败：零命中时不敢说干净。
        var degraded = offlineDependencies()
        degraded.networkLookupPerformed = true
        degraded.networkLookupNote = "OSV：52 个包中 3 个查询失败"
        let degradedResult = scorer.score(HealthInputs(dependencies: degraded))
        XCTAssertFalse(degradedResult.components.contains { $0.name == dependenciesName },
                       "核对未完成时不得给依赖分数，实际 \(degradedResult.components.map(\.name))")
        XCTAssertTrue(degradedResult.recommendations.contains { $0.contains("未完成") },
                      "实得 \(degradedResult.recommendations)")
    }

    /// 缺证据时权重必须归一到剩下的维度 —— 摘掉一个维度不能把综合分算漏。
    func testWeightsStayNormalisedWhenDependencyDimensionIsDropped() {
        let offline = WeightedHealthScorer().score(HealthInputs(code: healthyCode(),
                                                                dependencies: offlineDependencies()))
        let checked = WeightedHealthScorer().score(HealthInputs(code: healthyCode(),
                                                                dependencies: cleanDependencies()))
        XCTAssertEqual(offline.components.reduce(0) { $0 + $1.weight }, 1.0, accuracy: 1e-6,
                       "依赖维度缺席后其余权重仍须归一到 1.0")
        XCTAssertEqual(checked.components.reduce(0) { $0 + $1.weight }, 1.0, accuracy: 1e-6)
        XCTAssertEqual(offline.components.count + 1, checked.components.count)
        for result in [offline, checked] {
            let weighted = result.components.reduce(0.0) { $0 + Double($1.score) * $1.weight }
            XCTAssertEqual(Double(result.overall), weighted.rounded(), accuracy: 1,
                           "overall 必须等于 Σ(score·weight)（±1）")
        }
    }

    /// 一行日志都没扫到时，优点卡不得写「无崩溃」——与 detail 的「按默认值计」同一口径。
    func testStabilityPraiseRequiresActuallyScannedLogs() {
        var emptyLogs = healthyLogs()
        emptyLogs.totalLinesScanned = 0
        emptyLogs.errorCount = 0
        emptyLogs.exceptionCount = 0
        emptyLogs.crashCount = 0
        let blind = WeightedHealthScorer().score(HealthInputs(code: healthyCode(), logs: emptyLogs))
        XCTAssertFalse(blind.strengths.contains(where: { $0.contains("未见崩溃") || $0.contains("无崩溃") }),
                       "没扫到日志就断言无崩溃是虚报，实得 \(blind.strengths)")
        XCTAssertTrue(blind.recommendations.contains { $0.contains("没有可扫描的日志") },
                      "必须提示日志缺失，实得 \(blind.recommendations)")

        let scanned = WeightedHealthScorer().score(HealthInputs(code: healthyCode(), logs: healthyLogs()))
        XCTAssertTrue(scanned.strengths.contains { $0.contains("未见崩溃") && $0.contains("120") },
                      "真扫到 12 万行时才可以写这句优点，实得 \(scanned.strengths)")
    }

}
