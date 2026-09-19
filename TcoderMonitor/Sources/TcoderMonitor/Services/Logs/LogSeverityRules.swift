//
// 级别规则：ERROR/WARN/… 与崩溃特征词的优先级
//
// 从 LogParsing.swift 拆出：只为控制单文件长度，语义与拆分前完全一致。
//
import Foundation

extension LogLineParser {
    // MARK: 级别

    /// 匹配前先剥时间戳前缀，并且只在行首 240 字符内按单词边界匹配：
    /// 既躲开 `errorCount=0` 这类误判，也让「行首显式级别前缀」优先于正文里出现的崩溃词。
    static func detectSeverity(_ raw: String) -> LogSeverity? {
        let cleaned = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        let stripped = droppingTimestampPrefix(from: cleaned)
        let window = String(stripped.prefix(240))
        guard window.isEmpty == false else { return nil }

        let prefixHit = anchoredLevelHit(in: window)
        if let crashLocation = crashMarker.first(in: window)?.range.location {
            if let hit = prefixHit, hit.location < crashLocation { return hit.severity }
            return .crash
        }
        if let hit = prefixHit { return hit.severity }
        if let hit = levelKeyValue.first(in: window),
           let token = rxGroup(hit, 1, in: window),
           let severity = severity(forLevelWord: token) {
            return severity
        }
        return bodyKeywordSeverity(in: window)
    }

    static func anchoredLevelHit(in text: String) -> (location: Int, severity: LogSeverity)? {
        if let result = anchoredLevel.first(in: text),
           let token = rxGroup(result, 1, in: text),
           let severity = severity(forLevelWord: token) {
            return (result.range.location, severity)
        }
        if let result = anchoredShortLevel.first(in: text),
           let token = rxGroup(result, 1, in: text),
           let severity = severity(forShortCode: token) {
            return (result.range.location, severity)
        }
        if let result = levelKeyValue.first(in: text),
           let token = rxGroup(result, 1, in: text),
           let severity = severity(forLevelWord: token) {
            return (result.range.location, severity)
        }
        return nil
    }

    static func bodyKeywordSeverity(in text: String) -> LogSeverity? {
        var best: (location: Int, severity: LogSeverity)?

        func consider(_ location: Int?, _ severity: LogSeverity) {
            guard let location else { return }
            guard let current = best else {
                best = (location, severity)
                return
            }
            if location < current.location || (location == current.location && rank(severity) > rank(current.severity)) {
                best = (location, severity)
            }
        }

        if let result = levelWordAnywhere.first(in: text),
           let token = rxGroup(result, 1, in: text),
           let severity = severity(forLevelWord: token) {
            consider(result.range.location, severity)
        }
        consider(tracebackMarker.first(in: text)?.range.location, .exception)
        // `Caused by:` 按原始大小写匹配，避免误吞正文里的 "caused by" 散文
        consider(causedByMarker.first(in: text)?.range.location, .exception)
        return best?.severity
    }

    static func severity(forLevelWord word: String) -> LogSeverity? {
        switch word.uppercased() {
        case "ERROR", "SEVERE", "CRITICAL": return .error
        case "FATAL": return .fatal
        case "EXCEPTION": return .exception
        case "WARNING", "WARN": return .warning
        case "NOTICE", "INFO": return .info
        case "DEBUG", "VERBOSE": return .debug
        case "TRACE": return .trace
        default: return nil
        }
    }

    static func severity(forShortCode code: String) -> LogSeverity? {
        switch code.uppercased() {
        case "E": return .error
        case "W": return .warning
        case "I": return .info
        case "D", "V": return .debug
        case "T": return .trace
        case "F", "C": return .fatal
        default: return nil
        }
    }

    static func rank(_ severity: LogSeverity) -> Int {
        switch severity {
        case .trace: return 0
        case .debug: return 1
        case .info: return 2
        case .warning: return 3
        case .error: return 4
        case .exception: return 5
        case .fatal: return 6
        case .crash: return 7
        }
    }

    static func isErrorFamily(_ severity: LogSeverity) -> Bool {
        rank(severity) >= rank(.error)
    }

    static func looksLikeCrash(_ raw: String) -> Bool {
        crashMarker.first(in: raw) != nil
    }

    static func plainCrashSeverity(in text: String) -> LogSeverity? {
        crashedThreadHeader.first(in: text) != nil ? .crash : nil
    }

    static func isCrashReportPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasSuffix(".ips") || lower.contains("diagnosticreports")
    }
}
