import XCTest
@testable import TcoderMonitor

/// 选中项目判定处的守卫：`AppState.preferredProjectID` 是"界面显示谁的数字"的唯一入口。
///
/// 起因是真实事故：一次快速重启后应用把内置示例项目当成了选中项，示例里的
/// `Java 35%`、`UserService.java 4,320 行` 于是顶着真实仓库的名字出现在取证图里。
/// 示例的数字是编的，它抢到展示位就等于把假读数交出去。
final class DemoSelectionGuardTests: XCTestCase {

    private func project(_ name: String, demo: Bool) -> MonitoredProject {
        MonitoredProject(name: name, path: demo ? "demo://x" : "/tmp/\(name)", isDemo: demo)
    }

    func testStoredSelectionWinsWhenTheProjectStillExists() {
        let real = project("本仓库", demo: false)
        let sample = project("示例", demo: true)
        XCTAssertEqual(AppState.preferredProjectID(in: [sample, real], stored: real.id), real.id)
    }

    /// 关键一条：示例排在列表第一位也不能被选中——真实项目在场时它必须让位。
    func testRealProjectBeatsDemoWhenStoredSelectionIsGone() {
        let sample = project("示例", demo: true)
        let real = project("本仓库", demo: false)
        for stored: UUID? in [nil, UUID()] {
            XCTAssertEqual(AppState.preferredProjectID(in: [sample, real], stored: stored), real.id,
                           "stored=\(String(describing: stored)) 时落到了示例，界面会显示假读数")
        }
    }

    func testDemoIsStillChosenWhenItIsTheOnlyProject() {
        let sample = project("示例", demo: true)
        XCTAssertEqual(AppState.preferredProjectID(in: [sample], stored: nil), sample.id,
                       "只有示例时返回 nil 会让首启界面空白")
    }

    func testEmptyListHasNoSelection() {
        XCTAssertNil(AppState.preferredProjectID(in: [], stored: UUID()))
    }
}
