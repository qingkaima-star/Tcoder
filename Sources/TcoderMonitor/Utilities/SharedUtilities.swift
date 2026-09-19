import Foundation

// MARK: - Shared shell execution

/// Runs external binaries (git, defaults, vm_stat) with a hard timeout.
/// Owned by the chief engineer — analyzers must use this rather than hand-rolled
/// Process code, so timeout + stderr handling stays uniform.
struct ShellResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { exitCode == 0 }
    var trimmedOutput: String { stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum Shell {
    static func run(
        _ launchPath: String,
        arguments: [String],
        workingDirectory: URL? = nil,
        timeout: TimeInterval = 30,
        environment: [String: String]? = nil
    ) async -> ShellResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<ShellResult, Never>) in
            let queue = DispatchQueue(label: "com.tcoder.monitor.shell", attributes: .concurrent)
            queue.async {
                continuation.resume(returning: blockingRun(
                    launchPath,
                    arguments: arguments,
                    workingDirectory: workingDirectory,
                    timeout: timeout,
                    environment: environment
                ))
            }
        }
    }

    static func blockingRun(
        _ launchPath: String,
        arguments: [String],
        workingDirectory: URL? = nil,
        timeout: TimeInterval = 30,
        environment: [String: String]? = nil
    ) -> ShellResult {
        let process = Process()
        if launchPath.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: launchPath)
        } else {
            process.executableURL = resolveExecutable(named: launchPath)
        }
        process.arguments = arguments

        var env = environment ?? ProcessInfo.processInfo.environment
        env["LC_ALL"] = "C"
        env["LANG"] = "en_US.UTF-8"
        env["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = env

        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return ShellResult(exitCode: -1, stdout: "", stderr: "启动失败: \(error.localizedDescription)")
        }

        // Drain concurrently: a full 64KB pipe buffer would otherwise deadlock `git log`
        // on huge repositories before it can finish.
        let group = DispatchGroup()
        var outData = Data()
        var errData = Data()
        let ioQueue = DispatchQueue(label: "com.tcoder.monitor.shell.io", attributes: .concurrent)
        group.enter()
        ioQueue.async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        ioQueue.async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        let finished = DispatchSemaphore(value: 0)
        process.waitUntilExitAsync { finished.signal() }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
        }
        group.wait()

        return ShellResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    static func resolveExecutable(named name: String) -> URL {
        let candidates = [
            "/usr/bin/\(name)",
            "/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        if let pathValue = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathValue.split(separator: ":") {
                let candidate = "\(dir)/\(name)"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return URL(fileURLWithPath: candidate)
                }
            }
        }
        return URL(fileURLWithPath: "/usr/bin/\(name)")
    }

    static func isAvailable(_ name: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: resolveExecutable(named: name).path)
    }
}

private extension Process {
    func waitUntilExitAsync(_ completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .utility).async {
            self.waitUntilExit()
            completion()
        }
    }
}

// MARK: - Formatting helpers shared by every view

enum ByteFormat {
    static func string(_ bytes: UInt64, precision: Int = 1) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        guard bytes > 0 else { return "0 B" }
        var value = Double(bytes)
        var index = 0
        while value >= 1024 && index < units.count - 1 {
            value /= 1024
            index += 1
        }
        if index == 0 { return "\(Int(value)) B" }
        return String(format: "%.\(precision)f %@", value, units[index])
    }

    /// Throughput style: 120MB/s
    static func rate(_ bytesPerSecond: UInt64) -> String {
        string(bytesPerSecond, precision: 0) + "/s"
    }

    /// Bit rate for network: 20Mbps
    static func bitRate(_ bytesPerSecond: UInt64) -> String {
        let bits = Double(bytesPerSecond) * 8
        let units = ["bps", "Kbps", "Mbps", "Gbps"]
        var value = bits
        var index = 0
        while value >= 1000 && index < units.count - 1 {
            value /= 1000
            index += 1
        }
        return String(format: index == 0 ? "%.0f %s" : "%.1f %s", value, units[index])
    }
}

enum NumberFormat {
    static let grouping: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter
    }()

    static func grouped(_ value: Int) -> String {
        grouping.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// 182,430 -> 182k ; 1_204_000 -> 1.2M
    static func compact(_ value: Int) -> String {
        switch value {
        case ..<1_000: return "\(value)"
        case ..<1_000_000: return String(format: "%.0fk", Double(value) / 1_000)
        default: return String(format: "%.1fM", Double(value) / 1_000_000)
        }
    }

    static func percent(_ fraction: Double, precision: Int = 1) -> String {
        String(format: "%.\(precision)f%%", max(0, fraction) * 100)
    }

    static func signed(_ value: Int) -> String {
        value > 0 ? "+\(grouped(value))" : grouped(value)
    }
}

enum DateFormat {
    static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter
    }()

    static let dayMonth: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    static let full: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    static func sinceDescription(_ date: Date?) -> String {
        guard let date else { return "从未" }
        return LogRecency.describe(date)
    }
}
