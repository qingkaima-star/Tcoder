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
        let candidates = try discoverReportFiles(in: projectRoot, options: options)
        metrics.scannedFileCount = candidates.count

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

    private func discoverReportFiles(in root: URL, options: ScanOptions) throws -> [URL] {
        var found: [URL] = []
        var queue: [(URL, Int)] = [(root, 0)]

        while let (directory, depth) = queue.popLast() {
            if depth > 6 || found.count >= 40 { continue }
            let children = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for child in children {
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if values?.isDirectory == true {
                    if Self.thirdPartyDirectories.contains(child.lastPathComponent) { continue }
                    queue.append((child, depth + 1))
                } else if Self.wantedNames.contains(child.lastPathComponent) {
                    found.append(child)
                }
            }
        }
        return found
    }

    // MARK: Parsing

    private func parse(url: URL) -> CoverageReport? {
        let name = url.lastPathComponent
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size > 0, size <= Self.maxReportBytes,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        switch name {
        case "lcov.info", "lcov.dat":
            return parseLCov(text: text, url: url)
        case "coverage-summary.json":
            return parseIstanbulSummary(text: text, url: url)
        case "jacoco.xml", "jacocoTestReport.xml":
            return parseJaCoCo(text: text, url: url)
        case "coverage.xml":
            return parseCoveragePy(text: text, url: url)
        case "clover.xml":
            return parseClover(text: text, url: url)
        default:
            return nil
        }
    }

    private func parseLCov(text: String, url: URL) -> CoverageReport? {
        var linesFound = 0, linesHit = 0, branchesFound = 0, branchesHit = 0, functionsFound = 0, functionsHit = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            switch line.prefix(3) {
            case "LF:": linesFound += Self.int(after: line)
            case "LH:": linesHit += Self.int(after: line)
            case "BRF": branchesFound += Self.int(after: line)
            case "BRH": branchesHit += Self.int(after: line)
            case "FNF": functionsFound += Self.int(after: line)
            case "FNH": functionsHit += Self.int(after: line)
            default: break
            }
        }
        guard linesFound > 0 else { return nil }
        return CoverageReport(
            path: url.path,
            kind: Self.classify(url: url),
            toolName: "lcov",
            linesCovered: linesHit, linesTotal: linesFound,
            branchesCovered: branchesHit, branchesTotal: branchesFound > 0 ? branchesFound : nil,
            methodsCovered: functionsHit, methodsTotal: functionsFound
        )
    }

    private func parseIstanbulSummary(text: String, url: URL) -> CoverageReport? {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let total = root["total"] as? [String: Any] else { return nil }

        func metric(_ key: String) -> (pct: Double, covered: Int, total: Int)? {
            guard let entry = total[key] as? [String: Any] else { return nil }
            let covered = (entry["covered"] as? Int) ?? 0
            let count = (entry["total"] as? Int) ?? 0
            let pct = (entry["pct"] as? Double) ?? (count > 0 ? Double(covered) / Double(count) * 100 : 0)
            return (pct, covered, count)
        }

        let lines = metric("lines") ?? metric("statements")
        guard let resolved = lines, resolved.total > 0 else { return nil }
        let branches = metric("branches")
        let functions = metric("functions")
        return CoverageReport(
            path: url.path,
            kind: Self.classify(url: url),
            toolName: "istanbul / nyc",
            linesCovered: resolved.covered, linesTotal: resolved.total,
            branchesCovered: branches?.covered ?? 0,
            branchesTotal: (branches?.total ?? 0) > 0 ? branches?.total : nil,
            methodsCovered: functions?.covered ?? 0, methodsTotal: functions?.total ?? 0
        )
    }

    private func parseJaCoCo(text: String, url: URL) -> CoverageReport? {
        // Report-level counters are the last ones in the document; per-package and
        // per-class counters appear earlier and would double-count.
        func totals(for type: String) -> (missed: Int, covered: Int)? {
            let pattern = "<counter\\s+type=\"\(type)\"\\s+missed=\"(\\d+)\"\\s+covered=\"(\\d+)\"\\s*/>"
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
                  match.numberOfRanges == 3 else { return nil }
            func value(_ index: Int) -> Int {
                let range = match.range(at: index)
                guard range.location != NSNotFound,
                      let swiftRange = Range(range, in: text) else { return 0 }
                return Int(text[swiftRange]) ?? 0
            }
            return (value(1), value(2))
        }

        guard let line = totals(for: "LINE") else { return nil }
        let branch = totals(for: "BRANCH")
        let method = totals(for: "METHOD")
        let total = line.missed + line.covered
        guard total > 0 else { return nil }
        return CoverageReport(
            path: url.path,
            kind: Self.classify(url: url),
            toolName: "JaCoCo",
            linesCovered: line.covered, linesTotal: total,
            branchesCovered: branch?.covered ?? 0,
            branchesTotal: branch.map { $0.missed + $0.covered }.flatMap { $0 > 0 ? $0 : nil },
            methodsCovered: method?.covered ?? 0,
            methodsTotal: method.map { $0.missed + $0.covered } ?? 0
        )
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
            methodsCovered: 0, methodsTotal: 0
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
            methodsCovered: 0, methodsTotal: 0
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
