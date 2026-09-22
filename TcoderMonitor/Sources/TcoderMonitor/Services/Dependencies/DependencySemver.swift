// OWNER: R3 依赖证据链 · 版本比较原语（RD-10 的唯一一把尺子）
//
// 自 `DependencyVersionIdentity.swift` 拆出（`SourcesSizeAuditTests` 的 400 行口径），
// 逐字搬动、未改任何取义。冻结契约 `DependencyVersion` 的比较也已下沉到这里 ——
// **全仓只留这一处版本比较实现**，不再有两套解析各自解释同一个 `^1.2.3`。
import Foundation

// MARK: - 版本比较（不用冻结的 DependencyVersion：它在 `^` 处折成 [0]）

/// 一个版本号：数字段 + 可选预发布标签。构建元数据（`+build7`）按 semver 规则不参与先后比较。
struct DependencySemver: Equatable, Sendable {
    var segments: [Int]
    /// 预发布标签（`beta.1`、`SNAPSHOT`）；空数组表示正式发布版。
    var prerelease: [String]
    /// 原样保留的字母限定（`-jre`、`-android`）：非预发布，只在同数字段时用于区分"不是同一个包"。
    var qualifier: String?

    static let zero = DependencySemver(segments: [0], prerelease: [], qualifier: nil)

    var isPrerelease: Bool { !prerelease.isEmpty }

    /// 解析 `1.2.3`、`1.2.3-beta.1`、`1.2.3+build`、`33.3.1-jre`、`2.0`。
    /// 认不出（`*`、`latest`、`workspace:*`、`未声明`、纯字母、区间串）返回 nil —— **绝不返回 0**。
    static func parse(_ raw: String) -> DependencySemver? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var body = text
        if body.hasPrefix("v") || body.hasPrefix("V") { body = String(body.dropFirst()) }
        guard let first = body.first, first.isNumber else { return nil }
        guard !body.contains(where: { "^~<>=,()[]|".contains($0) }) else { return nil }

        // 构建元数据先摘掉（`1.2.3+build7`）：semver 规定它不参与先后比较。
        if let plus = body.firstIndex(of: "+") { body = String(body[..<plus]) }

        var prerelease: [String] = []
        var qualifier: String?
        if let dash = body.firstIndex(of: "-") {
            let tail = String(body[body.index(after: dash)...])
            body = String(body[..<dash])
            // `-` 段可能既有预发布标签又有字母限定（`1.0.0-jre-SNAPSHOT`）。
            let pieces = tail.split(separator: "-", omittingEmptySubsequences: true).map(String.init)
            prerelease = pieces.filter { Self.isPrereleaseToken($0) }
            let others = pieces.filter { !Self.isPrereleaseToken($0) }
            qualifier = others.isEmpty ? nil : others.joined(separator: "-")
        }
        guard let segments = Self.segments(of: body) else { return nil }
        return DependencySemver(segments: segments, prerelease: prerelease, qualifier: qualifier)
    }

    /// 数字段解析：任何一段不是纯数字就判"解析不出"（返回 nil，交调用方走未定态）。
    static func segments(of core: String) -> [Int]? {
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var result: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isNumber }), let value = Int(part) else { return nil }
            result.append(value)
        }
        return result
    }

    /// 语义上的"预发布"标记：只有业界公认的几个词根才算，其余字母限定（`jre`、`android`）不算。
    static func isPrereleaseToken(_ token: String) -> Bool {
        let lowered = token.lowercased()
        let roots = ["alpha", "beta", "rc", "pre", "preview", "snapshot", "dev", "nightly", "milestone", "m"]
        return roots.contains(where: { lowered == $0 || lowered.hasPrefix($0) })
            || lowered.allSatisfy({ $0.isNumber })
    }

    /// 两个已解析版本的比较。**入口必须是解析过的值** —— 解析不出来的串由 `parse` 返回 nil
    /// 来表达"不知道"，在这一层根本拿不到值，也就绝无"按 0 比"的可能。
    static func compare(_ lhs: DependencySemver, _ rhs: DependencySemver) -> ComparisonResult {
        let numeric = Self.compareSegments(lhs.segments, rhs.segments)
        if numeric != .orderedSame { return numeric }
        // 数字段相同：预发布 < 正式版（semver 规则）。
        switch (lhs.isPrerelease, rhs.isPrerelease) {
        case (true, false): return .orderedAscending
        case (false, true): return .orderedDescending
        case (false, false): return .orderedSame
        case (true, true): return Self.comparePrerelease(lhs.prerelease, rhs.prerelease)
        }
    }

    /// 数字段逐位比较，缺段按 0 补（`1.0` 与 `1.0.0` 同档）。
    static func compareSegments(_ lhs: [Int], _ rhs: [Int]) -> ComparisonResult {
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left < right ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// 预发布标识串的比较：数字段先于字母段、逐段字典序（semver §11）。
    static func comparePrerelease(_ lhs: [String], _ rhs: [String]) -> ComparisonResult {
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : ""
            let right = index < rhs.count ? rhs[index] : ""
            if left == right { continue }
            // 少一端的预发布（`1.2.3-beta` vs `1.2.3-beta.1`）排在前面。
            if left.isEmpty { return .orderedAscending }
            if right.isEmpty { return .orderedDescending }
            let comparison = Self.comparePrereleaseToken(left, right)
            if comparison != .orderedSame { return comparison }
        }
        return .orderedSame
    }

    static func comparePrereleaseToken(_ lhs: String, _ rhs: String) -> ComparisonResult {
        guard let left = Int(lhs) else {
            if Int(rhs) != nil { return .orderedDescending }   // 数字段先于字母段
            return lhs < rhs ? .orderedAscending : .orderedDescending
        }
        guard let right = Int(rhs) else { return .orderedAscending }
        if left == right { return .orderedSame }
        return left < right ? .orderedAscending : .orderedDescending
    }
}
