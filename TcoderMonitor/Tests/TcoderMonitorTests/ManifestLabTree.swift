import Foundation
@testable import TcoderMonitor

// WS-F 多清单夹具实验室 · 夹具树构建器（骨架）。
// 拆自 ManifestLabFixtureTests.swift（WS-V 机械拆分，正文逐行原样搬运）：
// build(at:) 现在只做「建目录 + 依次调用各段写入函数」，十段正文分别在
// ManifestLabTree+Manifests.swift / +OtherManifests.swift / +CodeAndCoverage.swift，
// Java/Go/Swift/Rust/Python/TS 正文素材在 ManifestLabTree+SourceMaterial.swift。
// 每段写入函数的签名一致：接两个闭包参数 put / putLines，段内正文与拆分前逐字相同。
// MARK: - 夹具树构建器

/// 只负责「按设计真值写文件 + 做一次真实 git 历史」。
/// 所有期望值都不从这里出，避免自证。
enum LabTree {

    struct Built {
        var files: [String] = []
        var lineCounts: [String: Int] = [:]
    }

    enum LabError: Error { case git(String) }

    static func build(at root: URL) throws -> Built {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.path) { try fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        var built = Built()
        func put(_ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let stamped = LabDates.stamp(text)
            try stamped.write(to: url, atomically: true, encoding: .utf8)
            built.files.append(path)
            let body = stamped.hasSuffix("\n") ? String(stamped.dropLast()) : stamped
            built.lineCounts[path] = body.components(separatedBy: "\n").count
        }
        func putLines(_ path: String, _ lines: [String]) throws {
            try put(path, lines.joined(separator: "\n"))
        }


        try writeManifestsNpm(put: put, putLines: putLines)
        try writeManifestsMaven(put: put, putLines: putLines)
        try writeManifestsGradle(put: put, putLines: putLines)
        try writeManifestsSwiftPM(put: put, putLines: putLines)
        try writeManifestsGoAndRust(put: put, putLines: putLines)
        try writeManifestsPythonRubyAndDotNet(put: put, putLines: putLines)
        try writeJavaSources(put: put, putLines: putLines)
        try writeCoverageReports(put: put, putLines: putLines)
        try writeLogs(put: put, putLines: putLines)
        try writeMiscFiles(put: put, putLines: putLines)

        return built
    }

    // MARK: - git 历史

    static func makeGitRepository(at root: URL, files: [String]) throws {
        let authors = [
            ("Liang Wei", "liang.wei@acme.example"),
            ("Zhao Min", "zhao.min@acme.example"),
            ("Chen Yu", "chen.yu@acme.example"),
        ]
        // 9 次提交横跨约 60 小时：D-2 到 D-0 三个自然日，全部落在过去。
        let hourOffsets = [60, 54, 48, 42, 36, 30, 24, 12, 2]
        let authorForCommit = [0, 0, 1, 0, 1, 0, 1, 0, 2]
        let groups: [[String]] = [
            [".gitignore", "README.md", "pom.xml", "package.json"],
            ["src/main/java/com/acme/orders/OrderOrchestrator.java", "src/main/java/com/acme/orders/Order.java"],
            ["src/main/java/com/acme/orders/UserService.java"],
            ["src/main/java/com/acme/orders/PricingRules.java", "src/main/java/com/acme/orders/BillingRules.java"],
            ["frontend/package.json", "frontend/src/checkout.ts", "package-lock.json"],
            ["frontend/coverage/unit/lcov.info", "frontend/coverage/coverage-summary.json"],
            ["build.gradle", "build.gradle.kts", "settings.gradle",
             "java/orders-api/pom.xml", "java/orders-service/pom.xml"],
            ["Package.swift", "Package.resolved", "Sources/ACMEOrders/OrderBook.swift",
             "go.mod", "go.sum", "service/main.go", "pkg/decode/decoder.go",
             "Cargo.toml", "Cargo.lock", "rust-worker/src/main.rs",
             "pyproject.toml", "python-tool/requirements.txt", "python-tool/src/inventory.py",
             "Gemfile", "Gemfile.lock", "ios/Podfile", "ios/Podfile.lock", "dotnet/packages.config"],
            ["java/orders-service/target/site/jacoco/jacoco.xml",
             "python-tool/coverage/coverage.xml", "clover.xml",
             "Logs/error.log", "Logs/crash.log"],
        ]
        let messages = [
            "chore(lab): 初始化清单与聚合工程",
            "feat(orders): 加入订单编排器",
            "feat(users): 加入用户服务",
            "fix(rules): 拆出定价与计费规则",
            "feat(front): 收银台页面与前端清单",
            "test(front): 落前端覆盖率产物",
            "build(jvm): 补 Gradle 与 Maven 模块",
            "chore(multi): 各语言清单与源码样例",
            "docs(lab): 覆盖率与日志样本",
        ]

        try git(["init", "-b", "main"], at: root)
        try git(["remote", "add", "origin", "https://git.acme.example/orders/acme-orders-lab.git"], at: root)
        for (index, group) in groups.enumerated() {
            try git(["add", "--"] + group, at: root)
            let author = authors[authorForCommit[index]]
            let date = LabDates.gitTimestamp(hoursAgo: hourOffsets[index])
            try git(["commit", "--quiet", "-m", messages[index]], at: root,
                    extra: ["GIT_AUTHOR_NAME": author.0, "GIT_AUTHOR_EMAIL": author.1,
                            "GIT_COMMITTER_NAME": author.0, "GIT_COMMITTER_EMAIL": author.1,
                            "GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date])
        }
    }

    private static func git(_ arguments: [String], at root: URL, extra: [String: String] = [:]) throws {
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in extra { environment[key] = value }
        // `-c` 覆盖是刻意的：本机 git 配置属于别人的环境，不能改；但签名进程、
        // fsmonitor 守护、自动 gc 都可能让子进程占住管道，把一次 commit 拖到超时。
        let safeDefaults = ["-c", "commit.gpgsign=false", "-c", "core.fsmonitor=false", "-c", "gc.auto=0"]
        let started = Date()
        // 超时给到 40s：bash 里单条 commit 实测 30ms，但全量 302 例并发跑时
        // Shell.blockingRun 会把个别 commit 拖到十几秒（隔离跑同一批只要 0.4s），
        // 卡在 20s 上会让本用例变成随机红。
        let result = Shell.blockingRun("git", arguments: safeDefaults + arguments,
                                       workingDirectory: root, timeout: 40, environment: environment)
        let seconds = Date().timeIntervalSince(started)
        if seconds > 1 {
            print("【WS-F】git \(arguments.first ?? "") 耗时 \(String(format: "%.1f", seconds))s")
        }
        guard result.succeeded else {
            throw LabError.git("git \(arguments.joined(separator: " ")) -> \(result.stderr)")
        }
    }


}

/// 夹具里的相对日期：`@Dn@` -> n 天前的 `yyyy-MM-dd`。
enum LabDates {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func stamp(_ text: String, now: Date = Date()) -> String {
        var result = text
        for offset in 0...3 {
            let day = Calendar(identifier: .gregorian)
                .date(byAdding: .day, value: -offset, to: now) ?? now
            result = result.replacingOccurrences(of: "@D\(offset)@", with: formatter.string(from: day))
        }
        return result
    }

    /// 给 git 用的 ISO 时间戳（带本机时区偏移，和 `--date=iso-local` 对得上）。
    static func gitTimestamp(hoursAgo: Int, now: Date = Date()) -> String {
        let date = Calendar(identifier: .gregorian)
            .date(byAdding: .hour, value: -hoursAgo, to: now) ?? now
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        return formatter.string(from: date)
    }
}
