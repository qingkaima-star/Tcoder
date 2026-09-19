import XCTest
@testable import TcoderMonitor

/// WS-V #33：落盘层 `ProjectStore` 与 `ServiceContracts` 的往返 / 兼容性测试。
///
/// 为什么要写这份：真 lcov（`swift test --enable-code-coverage`）量到
/// `Services/ProjectStore.swift` 138 行可执行 **0 行命中**、`Services/ServiceContracts.swift`
/// 12 行 0 命中——一个从不被跑过的持久层，恰好是最不能只靠约定保证的地方。
/// `ProjectStore` 全程用 `try?` 解码，所以一个不兼容的字段变更会
/// **静默丢掉用户已存的报告而不报任何错**。本文件第 ③ 组就是把
/// 「不许给落盘契约加非 Optional 字段」从口头约定变成会红的测试。
///
/// 覆盖边界（诚实交代，别把这份文件当成「load() 也端到端测过了」）：
/// `ProjectStore.init()` 把 `storageDirectory` 硬编码到
/// `~/Library/Application Support/TcoderMonitor` 并**立刻** `load()`；`load()` 是
/// `private`，`storageDirectory` 只能在 init 之后改——测试无法让 `load()` 去读临时夹具。
/// 所以本文件：① 驱动真实的**写**路径（`add`/`upsertReport`/`rename`/`remove`/
/// `setSelectedProject`/`recordScore`，全是 store 自己的方法）；② 把落到临时目录的
/// **字节**用与 store 同配置（`.iso8601`）的解码器读回来断言等价，那正是 `load()`
/// 依赖的 schema 契约；③ 兼容性两组直接对磁盘字节增删键，不依赖注入点。
/// 契约缺口（报总工）：`ProjectStore` 若加一个 `init(storageDirectory: URL? = nil)`，
/// 「坏 JSON → 静默回退空列表」就能端到端钉住，而不只钉在 schema 层。
///
/// 两条环境事实，用例必须对它们免疫：
/// 1. `init()` 会把**你机器上真实的** `Application Support/TcoderMonitor/projects.json`
///    读进 `projects`。所以 `makeIsolatedStore()` 在重定向之后立刻把预载条目从内存里
///    清掉（只写临时目录），否则任何「注册表里有几个项目」的断言都会随机器状态漂。
/// 2. iso8601 只到秒，所以夹具日期一律取整秒，别把亚秒精度损失误报成往返不等价。
///
/// 安全红线：任何会落盘的方法都在 `storageDirectory` 重定向之后才调用，
/// 绝不往用户真实目录写一个字节。路径比较一律两边 `resolvingSymlinksInPath()`
/// （`/var → /private/var` 是软链，`FileManager.default.temporaryDirectory` 给 `/var/…`）。
@MainActor
final class ProjectStoreRoundTripTests: XCTestCase {

    private static let fixedGeneratedAt = Date(timeIntervalSince1970: 1_790_000_000)
    private static let fixedAttemptedAt = Date(timeIntervalSince1970: 1_790_000_060)

    /// 与 `ProjectStore.decoder` 同配置——磁盘契约的另一半。
    private var isoDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// `ProjectStore.PersistedState` 是 private，这里按同 schema 建镜像类型复检。
    private struct Registry: Codable {
        var projects: [MonitoredProject]
        var selectedProjectID: UUID?
    }

    // MARK: - 夹具

    private func makeIsolatedStore() throws -> (ProjectStore, URL) {
        let store = ProjectStore()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tcoder-store-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let captured = dir
        addTeardownBlock {
            try? FileManager.default.removeItem(at: captured)
        }
        store.storageDirectory = dir
        // `ProjectStore` 只在 `load()` 里 `createDirectory(reportsDirectory)`，
        // 而 `load()` 是 private、只跑在 init 里 —— 重定向之后没人再建这个子目录，
        // 于是 `save(report:)` 的 `try? data.write(...)` 会**静默失败**（写侧的同类地雷，
        // 已作为契约缺口报总工）。这里照 `load()` 的样子补上，本文件才测得到「写得出去」。
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("reports", isDirectory: true),
            withIntermediateDirectories: true)
        // 此刻才允许清场：remove() 会写注册表并删报告文件，两者都必须落在临时目录里。
        for stale in store.projects { store.remove(stale) }
        XCTAssertTrue(store.projects.isEmpty, "清场失败，后面的计数断言会随机器状态漂")
        return (store, dir)
    }

    private func canon(_ url: URL) -> String { url.resolvingSymlinksInPath().path }

    private func registryURL(in dir: URL) -> URL { dir.appendingPathComponent("projects.json") }
    private func historyURL(in dir: URL) -> URL { dir.appendingPathComponent("score-history.json") }
    private func reportURL(in dir: URL, _ id: UUID) -> URL {
        dir.appendingPathComponent("reports", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).json")
    }

    private func readData(_ url: URL) throws -> Data {
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "store 没写出 \(url.lastPathComponent)，落盘路径口径变了：\(canon(url))")
        return try Data(contentsOf: url)
    }

    /// 把 store 写出来的 JSON 删掉若干顶层键，用来伪造「上一版 schema 的旧文件」。
    private func byRemoving(keys: [String], from data: Data) throws -> Data {
        var obj = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        keys.forEach { obj.removeValue(forKey: $0) }
        return try JSONSerialization.data(withJSONObject: obj)
    }

    private func byRemovingNested(keys: [String], under container: String, from data: Data) throws -> Data {
        var obj = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        var nested = obj[container] as? [String: Any] ?? [:]
        keys.forEach { nested.removeValue(forKey: $0) }
        obj[container] = nested
        return try JSONSerialization.data(withJSONObject: obj)
    }

    private func byAdding(key: String, value: Any, to data: Data) throws -> Data {
        var obj = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        obj[key] = value
        return try JSONSerialization.data(withJSONObject: obj)
    }

    private func makeReport(for project: MonitoredProject) -> ProjectReport {
        var report = ProjectReport(project: project)
        report.code = CodeMetrics(totalFiles: 7, codeLines: 4_210)
        report.git = GitInsights(totalCommits: 42)
        report.health = HealthScore(overall: 73)
        report.generatedAt = Self.fixedGeneratedAt
        report.attemptedAt = Self.fixedAttemptedAt
        report.failedSections = ["日志"]
        return report
    }

    // MARK: - ① 存 → 读等价

    func testWrittenRegistryReportAndHistoryReadBackEquivalent() throws {
        let (store, dir) = try makeIsolatedStore()
        XCTAssertFalse(store.isLoading, "load() 的 defer 必须把 isLoading 落回 false")

        let project = store.add(path: "/tmp/wsv-store-subject", name: "落盘往返", isDemo: false)
        store.upsertReport(makeReport(for: project))
        store.setSelectedProject(project.id)
        store.recordScore(73, for: project.id, projectName: "落盘往返")

        // —— 注册表 ——
        let registryData = try readData(registryURL(in: dir))
        let registry = try isoDecoder.decode(Registry.self, from: registryData)
        XCTAssertEqual(registry.projects.map(\.id), [project.id], "projects.json 里的项目集合不对")
        let storedProject = try XCTUnwrap(registry.projects.first)
        XCTAssertEqual(storedProject.name, "落盘往返")
        XCTAssertEqual(storedProject.path, "/tmp/wsv-store-subject")
        XCTAssertEqual(storedProject.isDemo, false)
        // 注册表是在 upsertReport 之后写的，所以它必须与报告里的 project 同步带上扫描时间。
        XCTAssertEqual(storedProject.lastScanAt, Self.fixedGeneratedAt,
                       "注册表与单份报告里的 lastScanAt 不一致，重启后总览页会退回「未扫描」")
        XCTAssertEqual(registry.selectedProjectID, project.id, "选中项没跟着 persist 走")

        // —— 单份报告：写进去的对象与磁盘读回来的必须等价 ——
        let reportData = try readData(reportURL(in: dir, project.id))
        let decoded = try isoDecoder.decode(ProjectReport.self, from: reportData)
        XCTAssertEqual(decoded.project.id, project.id)
        XCTAssertEqual(decoded.code?.totalFiles, 7)
        XCTAssertEqual(decoded.code?.codeLines, 4_210)
        XCTAssertEqual(decoded.git?.totalCommits, 42)
        XCTAssertEqual(decoded.health?.overall, 73)
        XCTAssertEqual(decoded.failedSections, ["日志"])
        XCTAssertEqual(decoded.generatedAt, Self.fixedGeneratedAt,
                       "iso8601 往返后整秒日期必须分毫不差")
        XCTAssertEqual(decoded.attemptedAt, Self.fixedAttemptedAt)
        XCTAssertTrue(decoded.hasBeenScanned)
        XCTAssertEqual(decoded.project.lastScanAt, Self.fixedGeneratedAt,
                       "upsertReport 要把 generatedAt 同步进 project.lastScanAt")

        // —— 分数历史：内存视图与磁盘视图同源 ——
        let historyData = try readData(historyURL(in: dir))
        let history = try isoDecoder.decode([UUID: [ScoreHistoryPoint]].self, from: historyData)
        XCTAssertEqual(history[project.id]?.map(\.score), [73])
        XCTAssertEqual(history[project.id]?.first?.projectName, "落盘往返")
        XCTAssertEqual(store.scoreHistory(for: project.id).count, 1)

        // —— 编码口径：prettyPrinted + sortedKeys 也是落盘契约的一部分 ——
        let registryText = String(decoding: registryData, as: UTF8.self)
        XCTAssertTrue(registryText.contains("\n  \"projects\""),
                      "缩进/换行变了——这份 JSON 是人肉排障的第一现场，prettyPrinted 不许掉")
        if let projectsAt = registryText.range(of: "\"projects\""),
           let selectedAt = registryText.range(of: "\"selectedProjectID\"") {
            XCTAssertTrue(projectsAt.lowerBound < selectedAt.lowerBound,
                          "sortedKeys 失效：键序不再稳定，落盘 diff 会变得没法看")
        } else {
            XCTFail("注册表里没同时找到 projects 与 selectedProjectID：\(registryText.prefix(200))")
        }

        print("【WS-V #33】注册表 \(registryData.count) B / 报告 \(reportData.count) B / 历史 "
            + "\(historyData.count) B 全部按 iso8601 读回等价")
    }

    func testAddRenameRemoveStayConsistentBetweenMemoryAndDisk() throws {
        let (store, dir) = try makeIsolatedStore()

        let added = store.add(path: "/tmp/wsv-store-lifecycle", name: "生命周期")
        XCTAssertEqual(store.projects.count, 1, "新路径必须入册")
        let justAdded = try isoDecoder.decode(Registry.self, from: readData(registryURL(in: dir)))
        XCTAssertNil(justAdded.projects.first?.lastScanAt,
                     "add() 只登记项目，不该凭空造出「扫过了」")
        XCTAssertFalse(FileManager.default.fileExists(atPath: reportURL(in: dir, added.id).path),
                       "add() 只 persist 注册表，那份占位报告仅存在于内存——所以 load() 才需要 else 分支"
                     + "在报告文件缺失时重新合成一份；这条断言钉住这个分工，别把它当成写盘缺陷")

        // 同 path + 同 isDemo 幂等；isDemo 不同算另一个条目。
        let again = store.add(path: "/tmp/wsv-store-lifecycle", name: "随便起的")
        XCTAssertEqual(again.id, added.id, "重复添加必须返回原条目，不能造出第二个同名项目")
        XCTAssertEqual(store.projects.count, 1)
        XCTAssertEqual(added.name, "生命周期", "幂等分支不许顺手改名")
        let demo = store.add(path: "/tmp/wsv-store-lifecycle", name: "演示", isDemo: true)
        XCTAssertNotEqual(demo.id, added.id, "isDemo 是身份的一部分")

        store.rename(added, to: "改名后")
        let renamed = try isoDecoder.decode(Registry.self, from: readData(registryURL(in: dir)))
        XCTAssertEqual(renamed.projects.first { $0.id == added.id }?.name, "改名后")
        XCTAssertEqual(store.report(for: added)?.project.name, "改名后",
                       "报告里的 project 必须与注册表同步，否则 UI 两处显示不同名字")

        store.upsertReport(makeReport(for: added))
        XCTAssertTrue(FileManager.default.fileExists(atPath: reportURL(in: dir, added.id).path))
        store.remove(added)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reportURL(in: dir, added.id).path),
                       "remove 只删注册表不删报告文件，会在存储目录里留孤儿报告")
        let afterRemove = try isoDecoder.decode(Registry.self, from: readData(registryURL(in: dir)))
        XCTAssertFalse(afterRemove.projects.contains { $0.id == added.id })
        XCTAssertNil(store.report(for: added))
        XCTAssertNil(store.report(for: nil), "空选择要安全返回 nil，而不是崩溃")
    }

    func testSortedProjectsPutsBestScoreFirstAndUnscannedLast() throws {
        let (store, _) = try makeIsolatedStore()
        func add(_ name: String, overall: Int?) {
            let project = store.add(path: "/tmp/wsv-sort-\(name)", name: name)
            guard let overall else { return }
            var report = ProjectReport(project: project)
            report.health = HealthScore(overall: overall)
            store.upsertReport(report)
        }
        add("中", overall: 60)
        add("优", overall: 90)
        add("无报告", overall: nil)
        add("差", overall: 30)

        // 只比自己那四个的相对次序：排序是全序，取相对顺序即可，不依赖机器上还有谁。
        let mine = store.sortedProjects.filter { $0.path.hasPrefix("/tmp/wsv-sort-") }
        XCTAssertEqual(mine.map(\.name), ["优", "中", "差", "无报告"],
                       "排序契约：健康分降序，无报告（按 -1 计）排最后")
    }

    // MARK: - ② 向前兼容：新增 Optional 字段不得让旧 JSON 读不回来

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

    // MARK: - ③ 反向护栏：加一个非 Optional 字段，旧 JSON 会整份读不回来

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

    // MARK: - 分数历史的去重与截断

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

    // MARK: - ④ ServiceContracts：AnalysisError 的中文文案是该文件唯一的可执行代码

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

extension JSONEncoder {
    /// 与 `ProjectStore.encoder` 同配置（sortedKeys 够用，不必 prettyPrinted）。
    static func withISO8601SortedKeys() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
