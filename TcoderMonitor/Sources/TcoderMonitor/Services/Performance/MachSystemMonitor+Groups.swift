import Foundation
import Observation

/// `MachSystemMonitor` 的**受监控组入口**分片（WS-X6 规模债切片，2026-09-21）。
///
/// 为什么是这四个函数：本文件被自扫点名「巨大文件」（>400 行），而该搬走的得是
/// **与采样节拍无关**的一组——心跳的九格、差分链、`ingest`/`publish` 全部原地不动。
/// 函数体逐字搬迁，一行未改。
///
/// 可见性说明（**不要改回 private**）：`managedGroups` 与 `refreshGroups()` 原先是
/// `private`，而 `private` 只到文件作用域、跨文件的同类型扩展看不见它们。
/// 本仓的态度在 `SourceFileReachabilityTests` 里已经写明：宁可行文说明为什么放成
/// `internal`，也不抄第二份状态或第二份口径（两份并存时，错的那套常在喂数据）。
/// `managedGroups` 仍带 `@ObservationIgnored`，放进观察图与否不因搬家而改变。
extension MachSystemMonitor {

    func groups() -> [TrackedProcessGroup] { managedGroups }

    @discardableResult
    func addGroup(title: String, matchPattern: String) -> TrackedProcessGroup? {
        let pattern = matchPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return nil }
        if let existing = managedGroups.first(where: {
            $0.matchPattern.caseInsensitiveCompare(pattern) == .orderedSame
        }) {
            return existing
        }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = TrackedProcessGroup(
            title: name.isEmpty ? pattern : name,
            matchPattern: pattern
        )
        managedGroups.append(group)
        refreshGroups()
        return group
    }

    func removeGroup(id: UUID) {
        managedGroups.removeAll { $0.id == id }
        refreshGroups()
    }

    /// Register extra matchers for a project (e.g. a service named after the repo).
    func ensureGroup(title: String, matchPattern: String) {
        guard managedGroups.contains(where: { $0.title == title }) == false else { return }
        addGroup(title: title, matchPattern: matchPattern)
    }
}
