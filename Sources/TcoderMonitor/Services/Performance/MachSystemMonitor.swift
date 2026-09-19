import Foundation

/// OWNER: Workstream C (性能监控). Rewrite this file.
/// Type name `MachSystemMonitor` and protocol conformance are frozen. AppState observes it,
/// so all four stored properties must stay `private(set)` and mutate on the main actor.
final class MachSystemMonitor: SystemMonitoringProviding {
    private(set) var latestSnapshot: SystemSnapshot?
    private(set) var history: [SystemSnapshot] = []
    private(set) var topProcesses: [ProcessSnapshot] = []
    private(set) var trackedGroups: [ProcessGroupSnapshot] = []
    private(set) var isRunning = false

    func start(intervalMilliseconds: UInt64) { isRunning = true }
    func stop() { isRunning = false }
    @discardableResult func sampleNow() -> SystemSnapshot? { latestSnapshot }
}
