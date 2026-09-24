import XCTest
@testable import TcoderMonitor

/// OWNER: 总工程师（冻结区 `ProjectStore` 的隔离入口，为九页取证解锁）
///
/// 这里只测**纯函数**与"落盘真的落在沙箱里"两件事。
/// 为什么值得单列一条文件：`TCODER_SUPPORT_DIR` 一旦写错成"相对路径也认"，
/// App 就会跟着进程 CWD 把用户的项目列表写到意想不到的地方——那比没有这个开关更糟。
/// 所以"拒绝相对路径"必须是被钉住的行为，不是靠注释。
@MainActor
final class ProjectStoreIsolationTests: XCTestCase {

    private let fakeBase = URL(fileURLWithPath: "/FakeAppSupport", isDirectory: true)

    // MARK: - 解析规则

    func testDefaultDirectoryIsUnchangedWhenNoOverride() {
        let url = ProjectStore.resolveStorageDirectory(environment: [:], applicationSupport: fakeBase)
        XCTAssertEqual(url.path, "/FakeAppSupport/TcoderMonitor",
                       "没设环境变量时必须与历史行为完全一致，否则会静默改变老用户的存储位置")
    }

    func testEmptyOverrideIsIgnoredNotTreatedAsRoot() {
        let url = ProjectStore.resolveStorageDirectory(
            environment: ["TCODER_SUPPORT_DIR": ""], applicationSupport: fakeBase)
        XCTAssertEqual(url.path, "/FakeAppSupport/TcoderMonitor",
                       "空字符串必须回落到默认目录；否则会把整个 / 当成沙箱")
    }

    func testAbsoluteOverrideIsHonoured() {
        let url = ProjectStore.resolveStorageDirectory(
            environment: ["TCODER_SUPPORT_DIR": "/tmp/tcoder-sandbox-1"], applicationSupport: fakeBase)
        XCTAssertEqual(url.path, "/tmp/tcoder-sandbox-1")
    }

    /// 这是这条开关最要紧的一条：相对路径一律不认。
    func testRelativeOverrideIsRefused() {
        for relative in ["relative/dir", "./sandbox", "../sandbox", "TcoderMonitor"] {
            let url = ProjectStore.resolveStorageDirectory(
                environment: ["TCODER_SUPPORT_DIR": relative], applicationSupport: fakeBase)
            XCTAssertEqual(url.path, "/FakeAppSupport/TcoderMonitor",
                             "相对路径 \(relative) 必须被拒绝——它会随进程 CWD 漂移")
        }
    }

    // MARK: - 端到端：沙箱实例不写用户目录

    /// 走**真实装配路径**：`setenv` 之后构造 `ProjectStore`，让 `init()` 自己去解析 + 建目录。
    /// 上面那版我先重定向 `storageDirectory` 再写盘，结果沙箱目录根本不存在
    /// ——那测的不是取证真正依赖的链路（App 是被环境变量启动的）。
    func testEnvironmentOverrideDrivesRealInitialization() throws {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tcoder-isolation-\(UUID().uuidString)", isDirectory: true)
        // 故意不预先 mkdir：如果 init() 没建目录，这条就会红，正好证明开关没接上
        setenv("TCODER_SUPPORT_DIR", sandbox.path, 1)
        defer { unsetenv("TCODER_SUPPORT_DIR") }

        let store = ProjectStore()
        XCTAssertEqual(store.storageDirectory.path, sandbox.path,
                       "init() 必须按 TCODER_SUPPORT_DIR 定位；不匹配说明开关根本没生效")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sandbox.path),
                      "init() 应当把沙箱目录建出来（用户数据目录不能被复用）")

        _ = store.add(path: "/tmp/tcoder-isolation-subject", name: "沙箱项目")
        let written = try FileManager.default.contentsOfDirectory(atPath: sandbox.path)
        XCTAssertTrue(written.contains("projects.json"),
                      "注册表必须写进沙箱，实得目录内容：\(written)")
        // 清理：整个沙箱是本用例自己造的，归本用例删
        try? FileManager.default.removeItem(at: sandbox)
    }

    // MARK: - 端到端：老用户机器上那一行已退役的示例数据（#66）

    /// `ProjectStore.PersistedState` 是 private，这里按同 schema 建镜像类型把磁盘字节读回来复检。
    private struct RegistryMirror: Codable {
        var projects: [MonitoredProject]
        var selectedProjectID: UUID?
    }

    private func rowsOnDisk(in sandbox: URL) throws -> RegistryMirror {
        let data = try Data(contentsOf: sandbox.appendingPathComponent("projects.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RegistryMirror.self, from: data)
    }

    /// 复现的是**现场**而不是夹具：本机 `~/Library/Application Support/TcoderMonitor/projects.json`
    /// 在 2026-09-25 07:06 仍然原样躺着 `demo://tcoder-sample` 那一行——2026-09-21 退役内置示例数据
    /// 时只删了产出（`DemoData`、侧栏入口），没人回头清已经写进注册表的那一行。
    /// 所以这里模拟「那位老用户的下一次启动」：**第一个 store 按老路径把那一行写进盘**（它测的是
    /// 写路径，不是被验对象），**第二个 store 才是被验的那次启动**——`load()` 是 private，
    /// 只有走真 `init()` 才测得到它（`resolveStorageDirectory` 那三条纯函数测试替代不了这一条）。
    func testRetiredSampleRowIsPurgedOnTheNextLaunch() throws {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tcoder-retire-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        setenv("TCODER_SUPPORT_DIR", sandbox.path, 1)
        defer {
            unsetenv("TCODER_SUPPORT_DIR")
            try? FileManager.default.removeItem(at: sandbox)
        }

        let writer = ProjectStore()
        let realProject = writer.add(path: sandbox.appendingPathComponent("真项目").path, name: "真项目")
        let sampleProject = writer.add(path: "demo://tcoder-sample", name: "Tcoder 示例项目")
        writer.setSelectedProject(sampleProject.id)
        let seeded = try rowsOnDisk(in: sandbox)
        XCTAssertEqual(seeded.projects.count, 2, "夹具没写成功（应两行），后面所有断言都是空的")
        XCTAssertEqual(seeded.selectedProjectID, sampleProject.id)

        let relaunch = ProjectStore()
        XCTAssertEqual(relaunch.projects.count, 1, "示例那一行没被清掉，侧栏会继续渲染假数据")
        XCTAssertEqual(relaunch.projects.first?.id, realProject.id)
        XCTAssertNil(relaunch.selectedProjectIDValue(),
                     "选中项正好是被退役那一行时必须一起清掉，否则界面指向一行已经不存在的 id")
        let afterRelaunch = try rowsOnDisk(in: sandbox)
        XCTAssertEqual(afterRelaunch.projects.count, 1,
                       "只在内存里滤＝文件里那行还在，别处读到它照样当真数据渲染")
        XCTAssertFalse(afterRelaunch.projects.contains { $0.path.hasPrefix("demo://") },
                       "落盘字节里不许再有任何 demo:// 行")
        XCTAssertNil(afterRelaunch.selectedProjectID, "悬空选中项也要一起落盘，否则下次启动又把它读回来")
    }

    /// 反方向：注册表里没有示例行时，`load()` 一个字节都不许改写。
    /// 不配这一条的话，「每次启动都重写一遍注册表」这种坏行为在这份文件里是测不出来的
    /// ——上一用例的夹具本来就带着示例行，只数得到「清完还剩一行」。
    ///
    /// ⚠ 判据用 **inode**，不用"文件字节相同"：编码器是确定性的
    /// （`[.prettyPrinted, .sortedKeys]`），把同样内容重写一遍，字节仍然一模一样 ⇒
    /// 比内容只能证明"没写坏"，证明不了"没写"。原子写会换一个新 inode，
    /// 而老文件没被删过 ⇒ 那个号不可能被发第二次，所以 inode 相同＝真的没人动过。
    func testLoadDoesNotRewriteRegistryWhenNothingToPurge() throws {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tcoder-untouched-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        setenv("TCODER_SUPPORT_DIR", sandbox.path, 1)
        defer {
            unsetenv("TCODER_SUPPORT_DIR")
            try? FileManager.default.removeItem(at: sandbox)
        }

        let writer = ProjectStore()
        _ = writer.add(path: sandbox.appendingPathComponent("真项目").path, name: "真项目")
        let registry = sandbox.appendingPathComponent("projects.json")
        let inodeBefore = try fileIdentifier(of: registry)

        _ = ProjectStore()                       // 没有可清的行 ⇒ load() 不许碰文件
        XCTAssertEqual(try fileIdentifier(of: registry), inodeBefore,
                       "无事可做时把用户的注册表重写一遍，等于拿别人的数据给自己练手（还会掩盖真实改动）")
    }

    private func fileIdentifier(of url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [.fileIdentifierKey])
        return UInt64(try XCTUnwrap(values.fileIdentifier,
                                    "读不到 \(url.lastPathComponent) 的 inode ⇒ 这条判据无从成立"))
    }

    /// 判据的**宽度**：只清点名退役过的那一枚常量。
    /// 「路径不在盘上就删」这种泛化会把用户暂时没插上的移动盘项目一并抹掉——
    /// 那是拿别人的数据换自己的整洁，本仓为同类越权判据立过案。
    func testRetirementJudgeIsExactlyAsWideAsTheRetiredConstant() {
        let rows = [MonitoredProject(name: "示例", path: "demo://tcoder-sample"),
                    MonitoredProject(name: "暂时没插上的盘", path: "/Volumes/NosuchDisk/项目"),
                    MonitoredProject(name: "别的演示方案", path: "demo://someone-else")]
        XCTAssertEqual(ProjectStore.rowsAfterRetiringSamples(rows).map(\.name),
                       ["暂时没插上的盘", "别的演示方案"],
                       "清行的判据一旦比退役常量宽，就会开始删没被点名过的行")
    }

    /// 假数据守卫（`FunctionalHonestyGuardTests`）把 `demo://` 列为禁字，而清理表**必须**带着它才删得掉那一行。
    /// 豁免按 **(文件, needle) 成对**给 ⇒ 四条各钉一次，防止它退化成"这个文件免检"或"这个字免检"，
    /// 也防止它变成**死条目**（哪天常量搬走了，豁免留着就是给未来的假数据留门）。
    /// 这条用例放在本文件而不是守卫那份里，理由：它钉的正是这枚常量，**豁免与常量要一起被读到**。
    func testFabricationExemptionStaysPairwiseAndNotDead() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for entry in FunctionalHonestyGuardTests.fabricationExemptions {
            let url = packageRoot.appendingPathComponent("Sources/TcoderMonitor/\(entry.path)")
            let content = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(content.contains(entry.needle),
                          "豁免点名的 \(entry.needle) 已经不在 \(entry.path) 里 ⇒ 这条豁免要跟着删")
            XCTAssertGreaterThanOrEqual(entry.reason.count, 20,
                                        "豁免理由没写够，读的人无从判断它免的是什么：\(entry.path)")
        }
        XCTAssertTrue(FunctionalHonestyGuardTests.fabricationHits(
            in: [(path: "Services/ProjectStore.swift",
                  content: "static let retired = [\"demo://tcoder-sample\"]\n")]).isEmpty,
                      "豁免没生效 ⇒ 门禁会一直红在清理表自己身上")
        XCTAssertFalse(FunctionalHonestyGuardTests.fabricationHits(
            in: [(path: "Services/ProjectStore.swift",
                  content: "let p = MonitoredProject(name: \"n\", path: \"/x\", isDemo: true)\n")]).isEmpty,
                       "豁免给了文件级单边口子：同一文件里 `isDemo` 回来也不会红")
        XCTAssertFalse(FunctionalHonestyGuardTests.fabricationHits(
            in: [(path: "Services/SomewhereElse.swift",
                  content: "let u = URL(string: \"demo://tcoder-sample\")!\n")]).isEmpty,
                       "豁免被当成全局免检：别处把示例数据请回来也不会红")
    }
}
