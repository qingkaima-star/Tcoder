import XCTest
@testable import TcoderMonitor

/// 「工程质量（代码口径）」副读数的契约。
///
/// 这个数是给用户的第二把尺子，也是最容易被写歪的一件：**换一批成员重新归一化**这件事，
/// 一旦允许它用第二套公式、或者允许它悄悄把难看的维度剔掉却不说明，
/// 它就退化成了"挑对自己有利的口径"。所以这里钉的四条都是反着钉的：
/// ① 成员名单与排除项必须跟着落盘；② 分值必须由**同一批分量的同一套权重**复现；
/// ③ 没有代码维度时宁可没有这个数，也不给 0；④ 老报告 JSON 缺字段必须还能解码。
final class HealthCodeScopeTests: HealthScoreTestCase {

    // MARK: - ① 只有代码维度时：与综合分同值，且承认"没有排除项"

    func testCodeScopeEqualsOverallWhenOnlyCodeDimensionsArePresent() {
        let result = WeightedHealthScorer().score(HealthInputs(code: healthyCode()))
        guard let scope = result.codeScope else { return XCTFail("代码维度在场，代码口径必须存在") }
        XCTAssertEqual(scope.overall, result.overall, "只有代码维度时两个数必须相等，否则就是两套公式")
        XCTAssertTrue(scope.excludedDimensions.isEmpty, "没有可排除的维度却写了排除项：\(scope.excludedDimensions)")
        XCTAssertEqual(Set(scope.includedDimensions),
                       Set([HealthDimension.codeQuality, .complexity, .duplication, .documentation].map(\.rawValue)))
        XCTAssertFalse(scope.note.isEmpty, "口径说明不得留空，否则读者只能猜这个数是什么")
    }

    // MARK: - ② 分值必须由同一批分量复现（不许有第二套算法）

    func testCodeScopeIsRecomputedFromThePublishedComponents() {
        let result = WeightedHealthScorer().score(fullInputs())
        guard let scope = result.codeScope else { return XCTFail("fullInputs 含代码四维，必须产出代码口径") }
        let members = result.components.filter { scope.includedDimensions.contains($0.name) }
        XCTAssertFalse(members.isEmpty)
        let weightSum = members.reduce(0.0) { $0 + $1.weight }
        let hand = members.reduce(0.0) { $0 + Double($1.score) * ($1.weight / weightSum) }
        XCTAssertEqual(Double(scope.overall), hand, accuracy: 1.0,
                       "代码口径必须能由界面上那张分量表手算复现（±1 是取整余量）")
    }

    // MARK: - ③ 排除项必须点名，而且必须恰好是「在场但不属于代码口径」的那些

    func testCodeScopeNamesEveryExcludedDimensionInItsOwnNote() {
        let result = WeightedHealthScorer().score(fullInputs())
        guard let scope = result.codeScope else { return XCTFail("缺代码口径副读数") }
        let present = Set(result.components.map(\.name))
        let members = Set(HealthDimension.allCases.filter(\.belongsToCodeScope).map(\.rawValue))
        XCTAssertEqual(Set(scope.includedDimensions), members.intersection(present),
                       "计入名单必须恰好是「在场的代码口径成员」")
        XCTAssertEqual(Set(scope.excludedDimensions), present.subtracting(members),
                       "排除名单必须恰好是「在场但不属于代码口径」的维度，多一项少一项都算虚报")
        for name in scope.excludedDimensions {
            XCTAssertTrue(scope.note.contains(name), "note 里必须逐个点名排除项，实际：\(scope.note)")
        }
        XCTAssertFalse(scope.includedDimensions.contains(where: { scope.excludedDimensions.contains($0) }),
                       "同一维度不得既计入又排除")
    }

    // MARK: - ④ 没有代码维度时不给数（0 分会被读成"代码很差"）

    func testCodeScopeIsAbsentWhenNoCodeDimensionScored() {
        let runtimeOnly = WeightedHealthScorer().score(
            HealthInputs(logs: healthyLogs(), dependencies: cleanDependencies()))
        XCTAssertNil(runtimeOnly.codeScope, "只有运行/依赖证据时不得凭空造一个代码分")
        XCTAssertFalse(runtimeOnly.components.isEmpty, "前置条件：这份输入确实产出了分量，只是没有代码维")

        let empty = WeightedHealthScorer().score(HealthInputs())
        XCTAssertNil(empty.codeScope, "无输入时两个数都不该存在")
        XCTAssertEqual(empty.overall, 0, "无输入的综合分仍是 0（走「无可用输入」那张卡，不是代码口径）")
    }

    // MARK: - ⑤ 落盘兼容：老报告没有这个字段，必须还能解码

    func testLegacyReportJSONWithoutCodeScopeStillDecodes() throws {
        // `Date` 走默认 `JSONDecoder`，落盘形状是**数字时间戳**不是字符串（这条是被本测试
        // 第一次跑红之后才发现的事实，写下来免得下次又拿 ISO8601 当假夹具）。
        let payload = """
        {"computedAt":800000000,"overall":61,"components":[],"strengths":[],\
        "issues":[],"recommendations":[],"narrative":"历史报告","generatedByAI":false}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(HealthScore.self, from: payload)
        XCTAssertEqual(decoded.overall, 61)
        XCTAssertNil(decoded.codeScope, "新增字段必须是 Optional，否则旧 JSON 整份解码失败（本仓踩过）")
    }

    // MARK: - ⑥ 元测试：证明上面第②条那条恒等式真的会红（防永真绿）

    /// 拿一份手工分量喂给 `codeScope(from:)`，把被排除维度的分数拉到极端：
    /// 如果实现把排除名单当摆设（拿全部分量加权），这个测试必须炸。
    func testCodeScopeIgnoresExcludedDimensionsEvenWhenTheyAreExtreme() {
        let components = [
            ScoreComponent(name: HealthDimension.complexity.rawValue, score: 90, weight: 0.5, detail: "d", risk: .low),
            ScoreComponent(name: HealthDimension.duplication.rawValue, score: 100, weight: 0.5, detail: "d", risk: .none),
            ScoreComponent(name: HealthDimension.busFactor.rawValue, score: 0, weight: 9.0, detail: "d", risk: .critical),
        ]
        let scope = WeightedHealthScorer.codeScope(from: components)
        XCTAssertEqual(scope?.overall, 95, "协作分布哪怕权重压倒一切，也不许渗进代码口径")
        XCTAssertEqual(scope?.excludedDimensions, [HealthDimension.busFactor.rawValue])
    }

    /// 反向：全部成员都是代码维度时，排除名单必须为空而不是漏报。
    func testCodeScopeReportsNoExclusionsWhenEveryComponentIsCodeScoped() {
        let components = [
            ScoreComponent(name: HealthDimension.documentation.rawValue, score: 80, weight: 1.0, detail: "d", risk: .low),
        ]
        let scope = WeightedHealthScorer.codeScope(from: components)
        XCTAssertEqual(scope?.overall, 80)
        XCTAssertTrue(scope?.excludedDimensions.isEmpty ?? false)
    }

    // MARK: - ⑦ 成员资格本身是判据，不许两处各写一份

    func testCodeScopeMembershipCoversAllNineDimensionsExactlyOnce() {
        let members = HealthDimension.allCases.filter(\.belongsToCodeScope)
        let rest = HealthDimension.allCases.filter { !$0.belongsToCodeScope }
        XCTAssertEqual(members.count + rest.count, HealthDimension.allCases.count, "判据必须对九维全覆盖")
        XCTAssertEqual(Set(members.map(\.rawValue)),
                       Set([HealthDimension.codeQuality, .complexity, .duplication, .documentation, .testing].map(\.rawValue)),
                       "成员名单变了要同步改界面文案与本报告说明")
    }
}
