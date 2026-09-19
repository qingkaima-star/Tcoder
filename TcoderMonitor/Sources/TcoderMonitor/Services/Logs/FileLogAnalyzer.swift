import Foundation

/// Entry point that composes WS-C's engines: LogDiscovery -> LogReader ->
/// (CrashReportParser for .ips) -> LogAggregator. Runs inside the detached
/// analysis task AppState already provides, so the file IO stays off the main actor.
final class FileLogAnalyzer: LogAnalysisProviding {
    private static let maxBytesPerFile = 20_000_000
    private static let maxLinesPerFile = 50_000
    private static let maxDiscoveredFiles = 60
    private static let topErrorLimit = 20

    func analyze(projectRoot: URL, extraLogURLs: [URL], withinDays: Int) async throws -> LogSummary {
        let projectName = projectRoot.lastPathComponent
        let windowDays = max(1, withinDays)

        var discovered = LogDiscovery.discover(
            projectRoot: projectRoot,
            projectName: projectName,
            withinDays: windowDays,
            maxFiles: Self.maxDiscoveredFiles
        )
        discovered.append(contentsOf: attached(urls: extraLogURLs, projectRoot: projectRoot))

        // De-duplicate by absolute path: a user-attached file often also lives
        // inside the project's own Logs/ directory.
        var seen = Set<String>()
        let targets = discovered.filter { seen.insert($0.url.path).inserted }

        var readings: [LogFileReading] = []
        var crashEvents: [LogEvent] = []
        for log in targets {
            let reading = LogReader.read(log, maxBytes: Self.maxBytesPerFile,
                                         maxLines: Self.maxLinesPerFile)
            readings.append(reading)
            if CrashReportParser.isCrashReport(log.url, role: log.role) {
                crashEvents.append(contentsOf: CrashReportParser.events(for: reading))
            }
        }

        let aggregate = LogAggregator.aggregate(
            readings: readings,
            extraEvents: crashEvents,
            topLimit: Self.topErrorLimit
        )

        var summary = LogSummary()
        summary.analyzedAt = Date()
        summary.windowStart = aggregate.windowStart
        summary.windowEnd = aggregate.windowEnd
        summary.errorCount = aggregate.errorCount
        summary.exceptionCount = aggregate.exceptionCount
        summary.warningCount = aggregate.warningCount
        summary.crashCount = aggregate.crashCount
        summary.fatalCount = aggregate.fatalCount
        summary.infoLineCount = aggregate.infoLineCount
        summary.totalLinesScanned = aggregate.totalLinesScanned
        summary.topErrors = aggregate.topErrors
        summary.trend = aggregate.trend
        summary.affectedFiles = aggregate.affectedFiles
        summary.scannedFiles = readings.map {
            ScannedLogFile(
                path: $0.url.path,
                sizeBytes: $0.sizeBytes,
                lineCount: $0.totalLines,
                modifiedAt: $0.modifiedAt,
                role: $0.role
            )
        }
        return summary
    }

    private func attached(urls: [URL], projectRoot: URL) -> [DiscoveredLog] {
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
            ), values.isRegularFile == true else { return nil }

            let size = Int64(values.fileSize ?? 0)
            guard size > 0 else { return nil }
            let modified = values.contentModificationDate ?? Date.distantPast
            return DiscoveredLog(
                url: url,
                role: LogDiscovery.role(for: url, in: projectRoot),
                sizeBytes: size,
                modifiedAt: modified
            )
        }
    }
}
