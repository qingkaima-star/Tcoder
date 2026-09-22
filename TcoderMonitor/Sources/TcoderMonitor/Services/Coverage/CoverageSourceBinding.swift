import Foundation

//  RD-26 · 第四类身份：**源码指纹**。
//
//  现场（我自己 grep 到的原文，`Services/Coverage/CoverageAnalyzer.swift`）：
//     旧实现 `fill(url:with:)` 只把报告文件**自身的 mtime** 写进 `generatedAt`，
//     界面上那句"报告生成于 …"是这条链上关于新鲜度的**全部**证据。
//  问题不是 mtime 假 —— 它是文件系统真记录 —— 而是它**什么都没绑定**：
//     一份 2020 年的 lcov 与一份刚跑出来的 lcov，在算总分时地位完全相同。
//     实测夹具 `s6_stale_against_source`：报告 mtime = 2020-01-01，仓库最新提交在昨天，
//     而健康分照样按"行覆盖 50.0%"计分（`测试覆盖 62 分`）、建议照样写
//     "将行覆盖率从 50.0% 提升到 75% 以上" —— 它建议用户去改一份**没被测量过**的源码。
//
//  本轮的判据（保守，不越权声称）：
//     · 提交身份只能从被扫仓库的 git 里读，读不到就是读不到（`nil`），**不拿 mtime 顶替**；
//     · mtime 只用来做**证伪**：报告时刻早于最新源码提交 ⇒ 已知陈旧，不进总分；
//     · 报告时刻不早于最新提交 ⇒ 只能说"未见更早证据"，**不能说"绑定在该提交上"**。
//       （覆盖率产物是本地文件、被 .gitignore 挡着，没有任何一处写着它测的是哪个提交。）

// MARK: - 被扫源码的一侧

/// 被扫仓库在**本次扫描时**的源码状态。全部来自真 `git` 子进程，读不到就留 `nil`。
struct CoverageSourceState: Codable, Equatable, Sendable {
    /// `git rev-parse HEAD`。不是 git 仓库 / git 不可用 / 超时 ⇒ `nil`。
    var headCommit: String?
    /// `git log -1 --format=%ct`（最新提交的提交时刻）。
    var headCommitDate: Date?
    /// 读 git 失败的原因（人话）。`nil` = 读成功。有值 ⇒ 下面两个字段的可信度作废。
    var readFailure: String?
    /// **`.git` 实际落在哪个目录**（提交身份的来源坐标）。
    /// `nil` = 没读到仓库。等于被扫根 = 项目自己就是仓库根；**不等于** ⇒ 提交号来自**父链上那个
    /// 更大的仓库**，它说的不是"这个项目自己的提交"（本仓 §25 点名的"外层仓库提交号冒充被扫总体"）。
    var repositoryRoot: URL?
    /// `repositoryRoot` 相对**被扫根**的坐标：`"."` = 被扫目录自己，`".."` / `"<b>` = 往外 B 层。
    /// 用相对形状而不是绝对路径：绝对路径换机器就换（本轮实测踩过 `/var` ↔ `/private/var`）。
    var repositoryCoordinate: String?

    static let unavailable = CoverageSourceState(headCommit: nil, headCommitDate: nil,
                                                 readFailure: "非 git 仓库或 git 读取失败")

    var isBoundToCommit: Bool { headCommit != nil && headCommitDate != nil }

    /// 只跑一次 `git`，失败一律降级成"未知"而不是"干净"。
    /// 分析器跑在 `Task.detached` 里，这里的阻塞式 `waitUntilExit` 不碰主线程。
    static func read(at root: URL, timeout: TimeInterval = 5) -> CoverageSourceState {
        guard let repository = repositoryDirectory(for: root) else {
            return CoverageSourceState(headCommit: nil, headCommitDate: nil,
                                       readFailure: "所选目录内没有 .git，谈不上提交绑定")
        }
        guard let commit = runGit(["rev-parse", "HEAD"], at: root, timeout: timeout),
              !commit.isEmpty else {
            return CoverageSourceState(headCommit: nil, headCommitDate: nil,
                                       readFailure: "git rev-parse HEAD 没拿到结果",
                                       repositoryRoot: repository,
                                       repositoryCoordinate: coordinate(of: repository, relativeTo: root))
        }
        let stamp = runGit(["log", "-1", "--format=%ct"], at: root, timeout: timeout)
            .flatMap { Int($0) }
            .map { Date(timeIntervalSince1970: Double($0)) }
        return CoverageSourceState(headCommit: CommitIdentity.abbreviated(commit),
                                   headCommitDate: stamp,
                                   readFailure: stamp == nil ? "拿到 HEAD，但读不到提交时刻" : nil,
                                   repositoryRoot: repository,
                                   repositoryCoordinate: coordinate(of: repository, relativeTo: root))
    }

    /// lcov 里的 `SF:` 常是绝对路径，报告也可能落在被扫目录的子目录里 ——
    /// 两种情况都要能在**被扫目录及其父链**上找到 `.git` 才算 git 仓库。
    /// ⚠ 但**找到在哪儿必须一起记下来**：用户扫的是某个大仓库的子目录时，父链上的 HEAD 是真的，
    /// 可它绑的是那个大仓库；把它当成"这个项目自己的提交"就是冒充（`repositoryCoordinate` 说清）。
    private static func repositoryDirectory(for root: URL) -> URL? {
        var directory = root.standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                return directory
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { return nil }
            directory = parent
        }
    }

    /// 仓库根相对被扫根的坐标：`"."` = 就是被扫目录；`".."` / `"../.."` = 往外几层；
    /// `"sub"` = 被扫根里另有一个更小的仓库（读的人据此判断提交号是谁的）。
    private static func coordinate(of repository: URL, relativeTo root: URL) -> String {
        var left = repository.standardizedFileURL.path.split(separator: "/", omittingEmptySubsequences: true)
        var right = root.standardizedFileURL.path.split(separator: "/", omittingEmptySubsequences: true)
        while let a = left.first, let b = right.first, a == b { left.removeFirst(); right.removeFirst() }
        let up = Array(repeating: "..", count: right.count).joined(separator: "/")
        if left.isEmpty { return right.isEmpty ? "." : up }
        return up.isEmpty ? left.joined(separator: "/") : up + "/" + left.joined(separator: "/")
    }

    private static func runGit(_ arguments: [String], at root: URL, timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()      // 只终止自己起的这个 git 进程，不广播信号
                process.waitUntilExit()
                return nil
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 单份报告的一侧

/// 一份报告与当前源码的**关系**。四个状态必须分开，合成一个布尔就把证据弄丢了。
enum CoverageBindingState: String, Codable, Sendable, CaseIterable {
    /// 报告没有可用的生成时间（mtime 读不到）⇒ 无法比较。
    case undated
    /// 被扫侧没有提交身份（不是 git 仓库 / git 读失败）⇒ 无法绑定。
    case unbound
    /// 报告时刻**早于**最新源码提交 ⇒ 已知陈旧：它测的不是当前源码。
    case olderThanHead
    /// 报告时刻不早于最新提交 ⇒ 「未见更早证据」。
    /// 注意措辞：这不是"绑定在该提交上"，mtime 证明不了它测的是哪个提交。
    case notContradictedByHead

    /// 只有这一态允许"已知陈旧"被排除出总分。其余三态都不构成否定证据。
    var provesStaleness: Bool { self == .olderThanHead }

    /// 一句人话（进披露，不进判定）。
    var note: String {
        switch self {
        case .undated: return "报告无生成时间，无法与源码提交比较（未绑定）"
        case .unbound: return "被扫目录没有可读的提交身份，报告未与提交绑定"
        case .olderThanHead: return "报告早于最新源码提交 ⇒ 测的不是当前源码，不计入总数"
        case .notContradictedByHead: return "报告不早于最新源码提交（mtime 不是提交绑定，仅"
            + "未见更早证据）"
        }
    }
}

/// 比较本身。**独立于 `Process`**，好让四种状态都能被测到（真 git 子进程只在取证用例里跑）。
enum CoverageBinding {
    static func state(generatedAt: Date?, source: CoverageSourceState) -> CoverageBindingState {
        guard let generatedAt else { return .undated }
        guard source.isBoundToCommit, let head = source.headCommitDate else { return .unbound }
        return generatedAt < head ? .olderThanHead : .notContradictedByHead
    }
}
