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
}
