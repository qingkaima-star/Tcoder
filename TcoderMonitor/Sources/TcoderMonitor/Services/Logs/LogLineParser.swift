//
// 行解析入口：正则表、单行拆解与前缀剥离
//
// 从 LogParsing.swift 拆出：只为控制单文件长度，语义与拆分前完全一致。
//
import Foundation

// MARK: - 行解析

enum LogLineParser {

    // 时间戳族：ISO / 空格分隔 / log4j 逗号毫秒 / syslog / epoch。捕获组编号见下方常量注释。
    // groups: 1年 2月 3日 4时 5分 6秒 7小数秒 8时区
    static let stamp = RX(#"(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:[.,](\d{1,9}))?(Z|[+-]\d{1,2}(?::?\d{2})?)?"#)
    // groups: 1月名 2日 3时 4分 5秒 6小数秒
    static let syslogStamp = RX(#"([A-Z][a-z]{2})\s{1,2}(\d{1,2})\s+(\d{1,2}):(\d{2}):(\d{2})(?:[.,](\d{1,3}))?"#)
    static let epochStamp = RX(#"(?<![\d.])(\d{10,13})(?![\d.])"#)
    static let dateOnlyStamp = RX(#"\b\d{4}-\d{2}-\d{2}\b"#)
    static let bracketPrefix = RX(#"^[\s\[(<]{0,2}[\[(<](?!(?:ERROR|WARN|WARNING|INFO|DEBUG|TRACE|FATAL|SEVERE|CRITICAL|EXCEPTION|NOTICE)\b)[^\]\)>]{1,40}[\]\)>][ \t]*[:\-|>?]{0,2}[ \t]*"#, options: .caseInsensitive)

    // 级别
    static let crashMarker = RX(#"\b(?:SIGSEGV|SIGABRT|SIGBUS|SIGILL|SIGTRAP|EXC_BAD_ACCESS|EXC_CRASH)\b|\bFatal error:|\bprecondition failure\b|\bFatal Python error\b|\bThread[ \t]+\d+[ \t]+Crashed\b"#)
    static let anchoredLevel = RX(#"^[\s\[<(]{0,4}(ERROR|FATAL|SEVERE|CRITICAL|EXCEPTION|WARNING|WARN|NOTICE|INFO|DEBUG|TRACE)\b"#, options: .caseInsensitive)
    static let anchoredShortLevel = RX(#"^[\s\[<(]{0,3}([EWIDTFVS])/[\w.\-\[]"#, options: .caseInsensitive)
    static let levelKeyValue = RX(#"\blevel[ \t]*[=:][ \t]*"?(trace|debug|info|notice|warn|warning|error|fatal|critical|exception)"?(?![\w-])"#, options: .caseInsensitive)
    static let levelWordAnywhere = RX(#"\b(FATAL|CRITICAL|EXCEPTION|SEVERE|ERROR|WARNING|WARN|NOTICE|INFO|DEBUG|TRACE)\b(?![\w-])"#, options: .caseInsensitive)
    static let tracebackMarker = RX(#"\bTraceback\b"#)
    static let causedByMarker = RX(#"\bCaused by:"#)
    static let crashedThreadHeader = RX(#"^\s*Crashed[ \t]+Thread:[ \t]*\d+\s*$"#, options: .caseInsensitive)

    // 堆栈帧
    static let javaFrame = RX(#"\bat\s+[A-Za-z_$][\w$<>$.]*\.[\w$<>$.]+\([\w$.]*\.(?:java|kt|kts|scala|groovy)(?![\w-])(?::\d+)?\)"#)
    static let genericAtFrame = RX(#"(?:^|[\t ])at\s+[\w$<>.$,()\[\]]+\([\w$.]*\.[A-Za-z]{2,5}(?::\d+)?\)"#)
    static let nativeFrame = RX(#"#\d+[ \t]+0x[0-9a-fA-F_]+[ \t]+in[ \t]+\S+"#)
    static let pythonFrame = RX(#"File[ \t]*"[^"]+",[ \t]*line[ \t]+\d+(?:,[ \t]*in[ \t]+\S+)?"#)
    static let hexFrame = RX(#"\b0x[0-9a-fA-F]{6,}\b"#)
    static let swiftSymbolFrame = RX("([A-Za-z_$][\\w$]*\\.){2,}[\\w$]+\\s*:\\s*[\\w$()\\[\\],.&' \u{2039}\u{203a}]+")
    static let fileLineFrame = RX(#"[\w$./\-]+\.(?:java|kt|kts|swift|py|go|ts|tsx|js|jsx|vue|scala|rb|rs)(?![\w-])(?::\d+)?"#)
    static let sourceFileFromFrame = RX(#"\(([\w$.\-/]+\.(?:java|kt|kts|swift|py|go|ts|tsx|js|jsx|vue|scala|rb|rs))(?![\w-])(?::(\d+))?\)"#)
    static let quotedPath = RX(#""([^"\n]+)""#)

    /// 归属判定用：这些形态的行挂在上一条 error 级事件上
    static let stackLinePatterns: [RX] = [
        RX(#"^(?:[\t ]|\\t)+at[ \t]+[\w$<>.$]"#),                        // "\tat com.foo.Bar.baz(...)"
        RX(#"^(?:[\t ]|\\t)*at[ \t]+[A-Za-z_$][\w$<>$.]*\("#),           // "at com.foo.Bar.baz(...)"
        RX(#"^(?:[\t ]|\\t)*\.\.\.[ \t]+\d+[ \t]+more"#, options: .caseInsensitive),  // "... 12 more"
        RX(#"^\s*Caused by:[ \t]+"#),                                     // Java 异常链
        RX(#"^\s*Suppressed:[ \t]+"#),
        RX(#"^\s*#\d+[ \t]+0x[0-9a-fA-F_]+"#),                             // lldb / crash 帧 "#0 0x..."
        RX(#"^\s*(?:\(\?\?\)\s*)?0x[0-9a-fA-F]{6,}\b"#),                  // 裸地址帧
        RX(#"^\s*File[ \t]*"[^"]+",[ \t]*line[ \t]+\d+"#),                // Python 帧
        RX(#"^\s*[\w$./\-]+\.(?:java|kt|kts|swift|py|go|ts|tsx|js|jsx|vue|scala|rb|rs|m|mm|c|cpp)(?![\w-]):\d+"#),
        RX(#"^\s*[\w$./\-(\)\[\]<>,]+\s*\+\s*0x[0-9a-fA-F]{2,}"#),         // Go / C 符号偏移帧 "pkg.fn(0x1) + 0x20"
        RX(#"^\s+[A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*){2,}\s*:"#),        // 缩进 + Swift demangled 符号
    ]

    static let monthNumbers: [String: Int] = [
        "Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4, "May": 5, "Jun": 6,
        "Jul": 7, "Aug": 8, "Sep": 9, "Oct": 10, "Nov": 11, "Dec": 12,
    ]

    // MARK: 单行

    static func parseLine(_ raw: String, number: Int, sourcePath: String, referenceDate: Date) -> ParsedLogLine {
        let cleaned = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        let stripped = droppingTimestampPrefix(from: cleaned)
        let detected = detectSeverity(cleaned)
        // .ips 里 "Crashed Thread: 5" 这类无级别行只有结合文件角色才认得出来
        let severity = detected ?? (isCrashReportPath(sourcePath) ? plainCrashSeverity(in: cleaned) : nil)

        return ParsedLogLine(number: number,
                             raw: cleaned,
                             date: parseTimestamp(cleaned, referenceDate: referenceDate),
                             severity: severity,
                             message: composeMessage(from: stripped),
                             stackFrame: stackFrame(in: cleaned),
                             sourceFile: sourceFile(in: cleaned))
    }
    // MARK: 前缀剥离

    /// 剥掉行首的时间戳以及紧随其后的 `[main]` / `<Info>` 之类的线程/模块标签。
    static func droppingTimestampPrefix(from text: String) -> String {
        guard let result = leadingStampMatch(in: text) else { return text }
        let ns = text as NSString
        var cut = NSMaxRange(result.range)
        guard cut <= ns.length else { return text }
        cut = skipSeparators(ns, from: cut, limit: 6)
        var rest = ns.substring(from: cut)
        for _ in 0..<2 {
            guard let tag = bracketPrefix.first(in: rest) else { break }
            let restNs = rest as NSString
            let end = skipSeparators(restNs, from: NSMaxRange(tag.range), limit: 4)
            guard end <= restNs.length else { break }
            rest = restNs.substring(from: end)
        }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func skipSeparators(_ ns: NSString, from location: Int, limit: Int) -> Int {
        var cursor = location
        var skipped = 0
        while cursor < ns.length, skipped < limit {
            let character = ns.substring(with: NSRange(location: cursor, length: 1))
            if "])>-:|, \t".contains(character) {
                cursor += 1
                skipped += 1
            } else {
                break
            }
        }
        return cursor
    }

    /// 只认真正位于行首的时间戳（起始位置 <= 4），否则会把正文吃掉。
    static func leadingStampMatch(in text: String) -> NSTextCheckingResult? {
        var best: NSTextCheckingResult?
        for pattern in [stamp, syslogStamp, epochStamp, dateOnlyStamp] {
            guard let result = pattern.first(in: text), result.range.location <= 4 else { continue }
            if let current = best {
                if result.range.location < current.range.location { best = result }
            } else {
                best = result
            }
        }
        return best
    }

    static func composeMessage(from stripped: String) -> String {
        var text = stripped
        if let result = anchoredLevel.first(in: text) {
            let ns = text as NSString
            let cut = skipSeparators(ns, from: NSMaxRange(result.range), limit: 4)
            if cut <= ns.length { text = ns.substring(from: cut) }
        } else if let result = anchoredShortLevel.first(in: text) {
            let ns = text as NSString
            let cut = min(NSMaxRange(result.range), ns.length)
            text = ns.substring(from: cut)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty == false { return trimmed }
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
