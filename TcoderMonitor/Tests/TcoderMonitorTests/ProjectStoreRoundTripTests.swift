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

    static let fixedGeneratedAt = Date(timeIntervalSince1970: 1_790_000_000)
    static let fixedAttemptedAt = Date(timeIntervalSince1970: 1_790_000_060)

    /// 与 `ProjectStore.decoder` 同配置——磁盘契约的另一半。
    var isoDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// `ProjectStore.PersistedState` 是 private，这里按同 schema 建镜像类型复检。
    struct Registry: Codable {
        var projects: [MonitoredProject]
        var selectedProjectID: UUID?
    }

    // MARK: - 夹具

    func makeIsolatedStore() throws -> (ProjectStore, URL) {
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

    func canon(_ url: URL) -> String { url.resolvingSymlinksInPath().path }

    func registryURL(in dir: URL) -> URL { dir.appendingPathComponent("projects.json") }
    func historyURL(in dir: URL) -> URL { dir.appendingPathComponent("score-history.json") }
    func reportURL(in dir: URL, _ id: UUID) -> URL {
        dir.appendingPathComponent("reports", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).json")
    }

    func readData(_ url: URL) throws -> Data {
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "store 没写出 \(url.lastPathComponent)，落盘路径口径变了：\(canon(url))")
        return try Data(contentsOf: url)
    }

    /// 把 store 写出来的 JSON 删掉若干顶层键，用来伪造「上一版 schema 的旧文件」。
    func byRemoving(keys: [String], from data: Data) throws -> Data {
        var obj = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        keys.forEach { obj.removeValue(forKey: $0) }
        return try JSONSerialization.data(withJSONObject: obj)
    }

    func byRemovingNested(keys: [String], under container: String, from data: Data) throws -> Data {
        var obj = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        var nested = obj[container] as? [String: Any] ?? [:]
        keys.forEach { nested.removeValue(forKey: $0) }
        obj[container] = nested
        return try JSONSerialization.data(withJSONObject: obj)
    }

    func byAdding(key: String, value: Any, to data: Data) throws -> Data {
        var obj = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        obj[key] = value
        return try JSONSerialization.data(withJSONObject: obj)
    }

    func makeReport(for project: MonitoredProject) -> ProjectReport {
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

        let project = store.add(path: "/tmp/wsv-store-subject", name: "落盘往返")
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

        // 同 path 幂等。（这里原本还断言"同 path + 不同 isDemo 算两个条目"，
        // 批次 P7-A 随示例数据退役 —— 身份里不再有"这份数据是编的"这一维。）
        let again = store.add(path: "/tmp/wsv-store-lifecycle", name: "随便起的")
        XCTAssertEqual(again.id, added.id, "重复添加必须返回原条目，不能造出第二个同名项目")
        XCTAssertEqual(store.projects.count, 1)
        XCTAssertEqual(added.name, "生命周期", "幂等分支不许顺手改名")

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

    // MARK: - ② 向前兼容：新增 Optional 字段不得让旧 JSON 读不回来

    // MARK: - ③ 反向护栏：加一个非 Optional 字段，旧 JSON 会整份读不回来

    // MARK: - 分数历史的去重与截断

    // MARK: - ④ ServiceContracts：AnalysisError 的中文文案是该文件唯一的可执行代码

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
