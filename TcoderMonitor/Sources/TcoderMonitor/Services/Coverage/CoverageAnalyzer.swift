import Foundation

protocol CoverageProviding: AnyObject {
    func analyze(projectRoot: URL, options: ScanOptions) async throws -> CoverageMetrics
}

/// Reads coverage artefacts the repository already produces. Nothing here runs a
/// test suite — it only parses existing reports, so it stays read-only and fast.
final class CoverageAnalyzer: CoverageProviding {
    private static let maxReportBytes = 20_000_000

    private static let wantedNames: Set<String> = [
        "lcov.info", "lcov.dat", "coverage-summary.json", "jacoco.xml",
        "jacocoTestReport.xml", "coverage.xml", "clover.xml",
    ]

    /// Deliberately NOT `ScanOptions.skipDirectories`: that list skips `coverage`,
    /// `target` and `build`, which is exactly where these reports live.
    private static let thirdPartyDirectories: Set<String> = [
        "node_modules", "bower_components", "vendor", "Pods", "Carthage", "pub",
        ".git", ".build", ".swiftpm", "DerivedData", "venv", ".venv", "__pycache__",
        ".pytest_cache", ".mypy_cache", ".gradle", ".dart_tool", ".next", ".nuxt",
        ".turbo", ".parcel-cache", "xcuserdata", ".idea", ".vscode",
    ]

    func analyze(projectRoot: URL, options: ScanOptions) async throws -> CoverageMetrics {
        var metrics = CoverageMetrics()
        let discovery = try discoverReportFiles(in: projectRoot, options: options)
        let candidates = discovery.found
        metrics.scannedFileCount = candidates.count
        // 每次分析都写下这一格（0 也是一句真话："扫到的每个目录都读得动"）。
        // 旧报告里它是 nil = 那个版本根本没统计过，两者在界面上必须分开。
        metrics.unreadableDirectoryCount = discovery.unreadableDirectories

        var parsed: [CoverageReport] = []
        for url in candidates {
            guard let report = parse(url: url) else { continue }
            parsed.append(report)
        }

        // A monorepo legitimately publishes several per-package reports; keeping them
        // all makes overallLinePercent a weighted aggregate instead of picking one.
        metrics.reports = Self.rank(parsed)
        metrics.analyzedAt = Date()
        return metrics
    }

    // MARK: Discovery

    /// 找报告文件的产出：候选清单 + **读不动的目录数**。
    ///
    /// 后者是这条链上最后一个"把未知说成已知"的口子：原来目录枚举失败（权限、
    /// 悬空软链接、竞态中消失的目录）被 `try?` 吞成空数组，于是一个根本没被看过的
    /// 子树在界面上长成"这个项目没有覆盖率报告"。现在它必须自己报名字。
    struct Discovery: Sendable {
        var found: [URL] = []
        var unreadableDirectories: Int = 0
    }

    private func discoverReportFiles(in root: URL, options: ScanOptions) throws -> Discovery {
        var out = Discovery()
        var queue: [(URL, Int)] = [(root, 0)]

        while let (directory, depth) = queue.popLast() {
            if depth > 6 || out.found.count >= 40 { continue }
            let children: [URL]
            do {
                children = try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]
                )
            } catch {
                out.unreadableDirectories += 1
                continue
            }

            for child in children {
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if values?.isDirectory == true {
                    if Self.thirdPartyDirectories.contains(child.lastPathComponent) { continue }
                    queue.append((child, depth + 1))
                } else if Self.wantedNames.contains(child.lastPathComponent) {
                    out.found.append(child)
                }
            }
        }
        return out
    }

    // MARK: Parsing

    private func parse(url: URL) -> CoverageReport? {
        let name = url.lastPathComponent
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size > 0, size <= Self.maxReportBytes,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        switch name {
        case "lcov.info", "lcov.dat":
            return fill(url: url, with: parseLCov(text: text, url: url))
        case "coverage-summary.json":
            return fill(url: url, with: parseIstanbulSummary(text: text, url: url))
        case "jacoco.xml", "jacocoTestReport.xml":
            return fill(url: url, with: parseJaCoCo(text: text, url: url))
        case "coverage.xml":
            return fill(url: url, with: parseCoveragePy(text: text, url: url))
        case "clover.xml":
            return fill(url: url, with: parseClover(text: text, url: url))
        default:
            return nil
        }
    }

    /// 五种格式的解析器都不关心「这份文件是哪天的」，所以在这里统一补一次：
    /// 生成时间取报告文件**自身的 mtime**——这是唯一不用相信解析器的证据来源。
    /// 读不到就留 nil，由 `CoverageReport.generationText` 明说「未知生成时间」，
    /// 绝不允许拿本次分析时刻顶替（那等于把陈旧报告洗成新数据）。
    private func fill(url: URL, with report: CoverageReport?) -> CoverageReport? {
        guard var filled = report else { return nil }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        filled.generatedAt = values?.contentModificationDate
        return filled
    }

    /// lcov 是唯一带**源文件粒度**的格式（每条记录一个 `SF:`），所以只有它能真的
    /// 把测试代码从计分分母里剔出去。其余四种格式只有汇总数字，标成
    /// `.aggregateOnly` 让它们的生产码口径**明说等同全量**，而不是假装区分过。
    private func parseLCov(text: String, url: URL) -> CoverageReport? {
        var tally = LCovTally()
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            tally.consume(raw.trimmingCharacters(in: .whitespaces))
        }
        guard tally.allLinesFound > 0 else { return nil }
        return tally.report(url: url)
    }

    /// lcov 的逐行累加器。从 `parseLCov` 里分出来只为了一个理由：那段循环被本 App
    /// 自扫点名 CC 16（超过 `complexFunctionBar`）。语义一字未动——
    /// `SF:` 决定归属、`end_of_record` 关掉归属、没有归属的计数不许悄悄进生产码。
    struct LCovTally {
        var allLinesFound = 0, allLinesHit = 0
        var prodLinesFound = 0, prodLinesHit = 0
        var allBranchesFound = 0, allBranchesHit = 0
        var prodBranchesFound = 0, prodBranchesHit = 0
        var functionsFound = 0, functionsHit = 0
        var inProductionRecord = false
        var sawSourceFileRecord = false

        mutating func consume(_ line: String) {
            if line.hasPrefix("SF:") {
                let path = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                sawSourceFileRecord = true
                inProductionRecord = CoverageScope.isProductionSource(path: path)
                return
            }
            // 没有 SF: 归属的计数不允许悄悄算进生产码。
            if line == "end_of_record" { inProductionRecord = false }
            let value = CoverageAnalyzer.int(after: line)
            switch line.prefix(3) {
            case "LF:": add(value, toAll: \.allLinesFound, toProduction: \.prodLinesFound)
            case "LH:": add(value, toAll: \.allLinesHit, toProduction: \.prodLinesHit)
            case "BRF": add(value, toAll: \.allBranchesFound, toProduction: \.prodBranchesFound)
            case "BRH": add(value, toAll: \.allBranchesHit, toProduction: \.prodBranchesHit)
            case "FNF": functionsFound += value
            case "FNH": functionsHit += value
            default: break
            }
        }

        /// 走 keyPath 而不是 `inout`：两个 `inout` 同时指向 self 的属性会撞
        /// 独占访问检查（编译器直接判错），而"全量 + 生产码"成对累加正是这里的形状。
        private mutating func add(_ value: Int,
                                  toAll all: WritableKeyPath<LCovTally, Int>,
                                  toProduction production: WritableKeyPath<LCovTally, Int>) {
            self[keyPath: all] += value
            if inProductionRecord { self[keyPath: production] += value }
        }

        /// `separated` = 这份报告真带 `SF:` 记录，才有资格谈"生产码口径"；
        /// 没有 SF: 时全量与生产码同值，且 `scopeGranularity` 必须落到 `.aggregateOnly`。
        func report(url: URL) -> CoverageReport {
            let separated = sawSourceFileRecord
            let prodBranches = separated ? prodBranchesFound : allBranchesFound
            return CoverageReport(
                path: url.path,
                kind: CoverageAnalyzer.classify(url: url),
                toolName: "lcov",
                linesCovered: separated ? prodLinesHit : allLinesHit,
                linesTotal: separated ? prodLinesFound : allLinesFound,
                branchesCovered: separated ? prodBranchesHit : allBranchesHit,
                branchesTotal: prodBranches > 0 ? prodBranches : nil,
                methodsCovered: functionsHit, methodsTotal: functionsFound,
                allLinesCovered: allLinesHit, allLinesTotal: allLinesFound,
                allBranchesCovered: allBranchesHit,
                allBranchesTotal: allBranchesFound > 0 ? allBranchesFound : nil,
                scopeGranularity: separated ? .perSourceFile : .aggregateOnly
            )
        }
    }

    private func parseIstanbulSummary(text: String, url: URL) -> CoverageReport? {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let total = root["total"] as? [String: Any] else { return nil }

        // 两级判断不能合并成一次回退：lines 桶**存在但为 0** 时不认 statements，
        // 只有 lines 缺失才回退。合起来会把"零覆盖"悄悄报成 83% 覆盖。
        guard let lines = Self.istanbulCounter(total["lines"]) ?? Self.istanbulCounter(total["statements"]),
              lines.total > 0 else { return nil }
        let branches = Self.istanbulCounter(total["branches"])
        let functions = Self.istanbulCounter(total["functions"])
        return CoverageReport(
            path: url.path,
            kind: Self.classify(url: url),
            toolName: "istanbul / nyc",
            linesCovered: lines.covered, linesTotal: lines.total,
            branchesCovered: branches?.covered ?? 0,
            branchesTotal: Self.positiveTotal(of: branches),
            methodsCovered: functions?.covered ?? 0, methodsTotal: functions?.total ?? 0,
            allLinesCovered: lines.covered, allLinesTotal: lines.total,
            allBranchesCovered: branches?.covered ?? 0,
            allBranchesTotal: Self.positiveTotal(of: branches),
            scopeGranularity: .aggregateOnly
        )
    }

    /// istanbul 的一个计数桶。`pct` 故意不读：`CoverageReport` 从不消费它
    /// （百分比由 `linePercent` 现场派生），原来那次 `??` 加三元只是白加判定分。
    private static func istanbulCounter(_ entry: Any?) -> (covered: Int, total: Int)? {
        guard let bucket = entry as? [String: Any] else { return nil }
        return (covered: bucket["covered"] as? Int ?? 0, total: bucket["total"] as? Int ?? 0)
    }

    /// 分支总数为 0 视作"这份报告没统计分支"，返回 nil 而不是 0/0。
    private static func positiveTotal(of counter: (covered: Int, total: Int)?) -> Int? {
        guard let counter, counter.total > 0 else { return nil }
        return counter.total
    }

    private func parseJaCoCo(text: String, url: URL) -> CoverageReport? {
        // Report-level counters are the last ones in the document; per-package and
        // per-class counters appear earlier and would double-count.
        guard let line = Self.jacocoTotals(for: "LINE", in: text) else { return nil }
        let branch = Self.jacocoTotals(for: "BRANCH", in: text)
        let method = Self.jacocoTotals(for: "METHOD", in: text)
        let total = line.missed + line.covered
        guard total > 0 else { return nil }
        return CoverageReport(
            path: url.path,
            kind: Self.classify(url: url),
            toolName: "JaCoCo",
            linesCovered: line.covered, linesTotal: total,
            branchesCovered: branch?.covered ?? 0,
            branchesTotal: Self.jacocoSumIfPositive(branch),
            methodsCovered: method?.covered ?? 0,
            methodsTotal: Self.jacocoSum(method),
            allLinesCovered: line.covered, allLinesTotal: total,
            allBranchesCovered: branch?.covered ?? 0,
            allBranchesTotal: Self.jacocoSumIfPositive(branch),
            scopeGranularity: .aggregateOnly
        )
    }

    static func jacocoTotals(for type: String, in text: String) -> (missed: Int, covered: Int)? {
        let pattern = "<counter\\s+type=\"\(type)\"\\s+missed=\"(\\d+)\"\\s+covered=\"(\\d+)\"\\s*/>"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
              match.numberOfRanges == 3 else { return nil }
        return (jacocoValue(at: 1, of: match, in: text), jacocoValue(at: 2, of: match, in: text))
    }

    static func jacocoValue(at index: Int, of match: NSTextCheckingResult, in text: String) -> Int {
        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return 0 }
        return Int(text[swiftRange]) ?? 0
    }

    /// 分支总数为 0 时报 nil（"这份报告没有分支数据"），不是报 0（"分支覆盖 0%"）。
    static func jacocoSumIfPositive(_ counter: (missed: Int, covered: Int)?) -> Int? {
        guard let counter else { return nil }
        let sum = counter.missed + counter.covered
        return sum > 0 ? sum : nil
    }

    static func jacocoSum(_ counter: (missed: Int, covered: Int)?) -> Int {
        counter.map { $0.missed + $0.covered } ?? 0
    }

    private func parseCoveragePy(text: String, url: URL) -> CoverageReport? {
        guard let start = text.range(of: "<coverage") else { return nil }
        let headerEnd = text.range(of: ">", range: start.lowerBound..<text.endIndex)?.lowerBound
            ?? start.upperBound
        let header = String(text[start.lowerBound..<headerEnd])

        func attr(_ name: String) -> Double? {
            guard let regex = try? NSRegularExpression(pattern: "\(name)=\"([0-9.]+)\""),
                  let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
                  match.numberOfRanges == 2,
                  let range = Range(match.range(at: 1), in: header) else { return nil }
            return Double(header[range])
        }

        let valid = Int(attr("lines-valid") ?? 0)
        guard valid > 0 else { return nil }
        let covered = Int(attr("lines-covered") ?? 0)
        let branchValid = Int(attr("branches-valid") ?? 0)
        return CoverageReport(
            path: url.path,
            kind: Self.classify(url: url),
            toolName: "coverage.py",
            linesCovered: covered, linesTotal: valid,
            branchesCovered: Int(attr("branches-covered") ?? 0),
            branchesTotal: branchValid > 0 ? branchValid : nil,
            methodsCovered: 0, methodsTotal: 0,
            allLinesCovered: covered, allLinesTotal: valid,
            allBranchesCovered: Int(attr("branches-covered") ?? 0),
            allBranchesTotal: branchValid > 0 ? branchValid : nil,
            scopeGranularity: .aggregateOnly
        )
    }

    private func parseClover(text: String, url: URL) -> CoverageReport? {
        let pattern = "<metrics\\s+statements=\"(\\d+)\"\\s+coveredstatements=\"(\\d+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
              match.numberOfRanges == 3 else { return nil }
        func value(_ index: Int) -> Int {
            guard let range = Range(match.range(at: index), in: text) else { return 0 }
            return Int(text[range]) ?? 0
        }
        let total = value(1)
        guard total > 0 else { return nil }
        return CoverageReport(
            path: url.path,
            kind: Self.classify(url: url),
            toolName: "clover",
            linesCovered: value(2), linesTotal: total,
            branchesCovered: 0, branchesTotal: nil,
            methodsCovered: 0, methodsTotal: 0,
            allLinesCovered: value(2), allLinesTotal: total,
            allBranchesCovered: 0, allBranchesTotal: nil,
            scopeGranularity: .aggregateOnly
        )
    }

    // MARK: Helpers

    private static func int(after line: String) -> Int {
        guard let colon = line.firstIndex(of: ":") else { return 0 }
        return Int(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)) ?? 0
    }

    private static func classify(url: URL) -> CoverageReport.Kind {
        let path = url.path.lowercased()
        if path.contains("integration") || path.contains("/itest") || path.contains("e2e") { return .integration }
        if path.contains("unit") || path.contains("/test/") || path.contains("surefire") { return .unit }
        return .combined
    }

    /// Largest denominator first — that ordering puts the aggregate report in front
    /// when a repository publishes both per-module and whole-project files.
    private static func rank(_ reports: [CoverageReport]) -> [CoverageReport] {
        Array(reports.sorted { $0.linesTotal > $1.linesTotal }.prefix(6))
    }
}
