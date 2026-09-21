/// OWNER: WS-X3 TestSplit —— 自 ProjectStoreRoundTripTests.swift 拆出，旧 JSON 兼容、缺键整体失败、评分历史去重与错误描述互斥。用例本体未改，只是搬了家。
import XCTest
@testable import TcoderMonitor

extension ProjectStoreRoundTripTests {

    func testOldJSONWithoutTheNewOptionalFieldsStillDecodes() throws {
        let (store, dir) = try makeIsolatedStore()
        let project = store.add(path: "/tmp/wsv-store-compat", name: "兼容")
        store.upsertReport(makeReport(for: project))
        let fresh = try readData(reportURL(in: dir, project.id))

        // 场景一：这份文件是「还没有 attemptedAt / code / health 这些字段时」的老版本写的。
        let legacy = try byRemoving(keys: ["attemptedAt", "code", "health", "git", "logs",
                                          "dependencies", "coverage"], from: fresh)
        let restored = try isoDecoder.decode(ProjectReport.self, from: legacy)
        XCTAssertEqual(restored.project.id, project.id, "旧数据的项目身份必须原样保住")
        XCTAssertNil(restored.attemptedAt, "Optional 字段在旧文件里缺席 = nil，而不是解码失败")
        XCTAssertNil(restored.code)
        XCTAssertNil(restored.health)
        XCTAssertFalse(restored.hasBeenScanned)
        // 只删 Optional 键，非 Optional 的 failedSections 必须原样留着。
        // （它要是被删掉就整份解码失败，那是下面 ③ 的内容，别和这条混起来。）
        XCTAssertEqual(restored.failedSections, ["日志"],
                       "Optional 键的缺席不该波及其它字段的内容")

        // 场景二：老数据里连 `project.lastScanAt` 这个 Optional 都不存在。
        let noNestedOptional = try byRemovingNested(keys: ["lastScanAt"], under: "project", from: fresh)
        let stillOK = try isoDecoder.decode(ProjectReport.self, from: noNestedOptional)
        XCTAssertNil(stillOK.project.lastScanAt)
        XCTAssertEqual(stillOK.project.name, "兼容")

        // 场景三：未来某版多写了一个 Optional 键，老 reader 必须无视它而不是崩。
        let future = try byAdding(key: "wsvFutureOptionalThing", value: "x", to: fresh)
        let ignoreUnknown = try isoDecoder.decode(ProjectReport.self, from: future)
        XCTAssertEqual(ignoreUnknown.project.id, project.id)

        // 注册表侧同理：selectedProjectID 是 Optional，旧文件没这个键也读得回来。
        let registry = try readData(registryURL(in: dir))
        let legacyRegistry = try byRemoving(keys: ["selectedProjectID"], from: registry)
        let restoredRegistry = try isoDecoder.decode(Registry.self, from: legacyRegistry)
        XCTAssertNil(restoredRegistry.selectedProjectID)
        XCTAssertEqual(restoredRegistry.projects.map(\.id), [project.id],
                       "Optional 键缺席只该丢那一个字，不该丢整份注册表")

        print("【WS-V #33】Optional 三向兼容通过：缺键→nil、未知键→忽略、整份数据不丢")
    }

    /// 这条测的不是「我希望它失败」，而是「它现在确实失败，而且失败成什么样」。
    /// `ProjectStore.load()` 用 `try?` 解码，所以下面这个 keyNotFound 到线上表现成：
    /// 用户的项目列表 / 某份报告**凭空消失**，日志里一个字都没有。
    func testMissingNonOptionalKeyFailsWholeDecodeAndTryQuestionMarkHidesIt() throws {
        let (store, dir) = try makeIsolatedStore()
        let project = store.add(path: "/tmp/wsv-store-break", name: "断裂")
        store.upsertReport(makeReport(for: project))
        let fresh = try readData(reportURL(in: dir, project.id))

        // 关键事实：`failedSections: [String] = []` 与 `generatedAt: Date = Date()`
        // 都**带默认值**，但类型非 Optional。Codable 合成的 init(from:) 对非 Optional
        // 一律调 decode（不看默认值），所以旧文件缺键就整份抛错——
        // 「我给了默认值所以向后兼容」这个直觉在落盘契约上是错的。
        for key in ["failedSections", "generatedAt", "project"] {
            let broken = try byRemoving(keys: [key], from: fresh)
            XCTAssertThrowsError(try isoDecoder.decode(ProjectReport.self, from: broken),
                                 "缺非 Optional 键 \(key) 必须让整份解码失败") { error in
                guard case let DecodingError.keyNotFound(missing, context) = error else {
                    XCTFail("缺 \(key) 应当报 keyNotFound，实得 \(error)")
                    return
                }
                XCTAssertEqual(missing.stringValue, key)
                XCTAssertTrue(context.codingPath.isEmpty,
                              "错误定位在顶层，说明是整份报告级别的失败而非单个字段")
            }

            // 这一条把「静默」两个字钉住：ProjectStore.load() 用的就是这个 try?。
            let silentlyNil = try? isoDecoder.decode(ProjectReport.self, from: broken)
            XCTAssertNil(silentlyNil,
                         "try? 会把 keyNotFound 吞成 nil——这正是「已存报告无声消失」的机制")
        }

        // 注册表侧：`projects` 非 Optional，缺它 = 整个项目列表回退成空。
        let registry = try readData(registryURL(in: dir))
        let brokenRegistry = try byRemoving(keys: ["projects"], from: registry)
        XCTAssertNil(try? isoDecoder.decode(Registry.self, from: brokenRegistry),
                     "注册表缺 projects 键必须整份失败（load() 里表现为列表清空）")
        // 对照组：同一份文件只缺 Optional 的 selectedProjectID 就完全没事。
        let optionalOnly = try byRemoving(keys: ["selectedProjectID"], from: registry)
        XCTAssertNotNil(try? isoDecoder.decode(Registry.self, from: optionalOnly),
                        "只缺 Optional 键不该失败——两组的差别就是这条规则存在的全部理由")

        // 模型侧最后一道：MonitoredProject 的 isDemo 也是非 Optional。
        let projectData = try JSONEncoder.withISO8601SortedKeys().encode(project)
        let withoutDemo = try byRemoving(keys: ["isDemo"], from: projectData)
        XCTAssertThrowsError(
            try isoDecoder.decode(MonitoredProject.self, from: withoutDemo),
            "MonitoredProject 加一个非 Optional 字段，会让所有旧注册表读不回来")

        print("【WS-V #33】非 Optional 护栏：缺 failedSections / generatedAt / project / projects / "
            + "isDemo 全部整份 keyNotFound，且 try? 一律吞成 nil —— "
            + "落盘契约新增字段必须 Optional（#26 的规矩，现在它会长牙了）")
    }

    func testScoreHistoryDedupesSameRecentScoreAndCapsAt240Points() throws {
        let (store, dir) = try makeIsolatedStore()
        let project = store.add(path: "/tmp/wsv-store-history", name: "历史")

        store.recordScore(70, for: project.id, projectName: "历史")
        store.recordScore(70, for: project.id, projectName: "历史")
        XCTAssertEqual(store.scoreHistory(for: project.id).count, 1,
                       "60 秒内同分重复记录必须合并，否则趋势图被噪声灌满")
        store.recordScore(71, for: project.id, projectName: "历史")
        XCTAssertEqual(store.scoreHistory(for: project.id).count, 2)

        for score in 100...399 {
            store.recordScore(score, for: project.id, projectName: "历史")
        }
        let capped = store.scoreHistory(for: project.id)
        XCTAssertEqual(capped.count, 240, "历史上限 240 点，超出必须丢最旧的而不是拒绝写入")
        // 70 与 71 被挤掉，留下 160...399 共 240 个。按分数比而不是按日期比：
        // 同一微秒内的两点在 sort 里次序不稳定，按日期断言会偶发抖动。
        XCTAssertEqual(capped.map(\.score).sorted(), Array(160...399), "留下的必须是最新的 240 个")
        XCTAssertEqual(capped.map(\.date), capped.map(\.date).sorted(), "对外读取必须按时间升序")

        let onDisk = try isoDecoder.decode([UUID: [ScoreHistoryPoint]].self,
                                           from: readData(historyURL(in: dir)))
        XCTAssertEqual(onDisk[project.id]?.count, 240,
                       "截断必须同时落到磁盘，否则重启后又会长回去")
    }

    /// `ServiceContracts.swift` 那 12 行全在 `AnalysisError.errorDescription`。
    /// 这些串直接给用户看，`Views` 里的失败态文案全靠它们，所以逐条钉死。
    func testAnalysisErrorDescriptionsCoverEveryCaseAndStayDistinct() throws {
        let cases: [(AnalysisError, String)] = [
            (.notDirectory("/tmp/nope"), "路径不是有效目录：/tmp/nope"),
            (.notGitRepository("/tmp/plain"), "该目录不是 Git 仓库：/tmp/plain"),
            (.gitBinaryMissing, "未找到 git 可执行文件，请确认已安装 Xcode 命令行工具"),
            (.unreadableFile("/tmp/locked.log"), "文件无法读取：/tmp/locked.log"),
            (.cancelled, "扫描已取消"),
            (.timedOut("日志扫描"), "日志扫描 超时"),
            (.empty("依赖清单"), "依赖清单 没有可用数据"),
            (.networkUnavailable("OSV 批量接口不可用，已改用逐包查询"),
             "网络请求不可用：OSV 批量接口不可用，已改用逐包查询"),
        ]
        var seen = Set<String>()
        for (error, expected) in cases {
            let described = try XCTUnwrap(error.errorDescription, "\(error) 竟然没有文案")
            XCTAssertEqual(described, expected,
                           "错误文案变了——用户看到的排障提示会与笔记/文档脱节：\(error)")
            XCTAssertTrue(seen.insert(expected).inserted, "两个 case 共用同一句话：\(expected)")
        }
        XCTAssertEqual(cases.count, 8,
                       "AnalysisError 现有 8 个 case，这里必须一个不漏（少一个是漏网分支）")

        // 关联值必须出现在文案里，否则用户只知道出错、不知道是哪个路径出错。
        XCTAssertTrue(try XCTUnwrap(AnalysisError.notDirectory("/a/b").errorDescription).contains("/a/b"))
        XCTAssertTrue(try XCTUnwrap(AnalysisError.unreadableFile("/c/d").errorDescription).contains("/c/d"))
        XCTAssertTrue(try XCTUnwrap(AnalysisError.gitBinaryMissing.errorDescription).contains("git"))

        // Equatable：AppState 侧靠它做失败态去重。
        XCTAssertEqual(AnalysisError.notDirectory("/x"), AnalysisError.notDirectory("/x"))
        XCTAssertNotEqual(AnalysisError.notDirectory("/x"), AnalysisError.notDirectory("/y"))
        XCTAssertNotEqual(AnalysisError.cancelled, AnalysisError.timedOut("x"))
    }

}
