//
// 行解析入口：正则表、单行拆解与前缀剥离，外加归一化、签名与堆栈帧识别
//
// 从 LogParsing.swift 拆出：只为控制单文件长度，语义与拆分前完全一致。
// WS-X5 再把 `LogClustering.swift` 里那段 `extension LogLineParser`（归一化 / 签名 / 堆栈帧）
// 逐行原样搬到本文件末尾——搬而不是新建文件，是为了守住「本包文件 ≤ 400 行」这条棘轮
// 的同时不动全仓实现文件分母（`SourceFileReachabilityTests.censusBaseline` 归总工管）。
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

extension LogLineParser {
    // MARK: 归一化与签名

    // 归一化用的正则全部 static：这些函数按行调用，逐行编译正则会把整个分析拖慢一个数量级。
    static let collapseWhitespace = RX(#"\s+"#)
    static let uuidPattern = RX(#"\b[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}\b"#)
    static let hexPattern = RX(#"\b0[xX][0-9a-fA-F]+\b"#)
    /// 十六进制先落成不含数字的占位，避免随后「数字 -> N」把 `0xN` 里的 0 再吃掉一次
    static let hexPlaceholder = "<hex>"
    static let windowsPathPattern = RX(#"[A-Za-z]:[\\/][^\s"'`]*"#)
    static let unixPathPattern = RX(#"(?:/[A-Za-z0-9._$@~+-]+){2,}/?"#)
    static let singleQuotedPattern = RX(#"'[^'\n]*'"#)
    static let doubleQuotedPattern = RX(#""[^"\n]*""#)
    static let backtickQuotedPattern = RX(#"`[^`\n]*`"#)
    static let dottedNumberPattern = RX(#"\b\d+(?:[._-]\d+)+\b"#)
    static let digitsPattern = RX(#"\d+"#)
    static let repeatedPathPattern = RX(#"<path>(?:[ /]+<path>)+"#)
    static let repeatedStringPattern = RX(#"(?:<str>[ ,]*<str>)+"#)

    /// 顺序：折叠空白 -> uuid -> 十六进制 -> 路径 -> 引号串 -> 数字 -> 合并重复占位 -> 截断 240。
    /// 数字放在十六进制 / UUID 之后，否则 `0x1F4A` 会被拆成碎片而不是稳定的 `0xN`。
    static func normalizeMessage(_ message: String) -> String {
        var text = collapseWhitespace.replaces(message, with: " ")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false else { return "" }

        text = uuidPattern.replaces(text, with: "<uuid>")
        text = hexPattern.replaces(text, with: hexPlaceholder)
        text = windowsPathPattern.replaces(text, with: "<path>")
        text = unixPathPattern.replaces(text, with: "<path>")
        text = singleQuotedPattern.replaces(text, with: "<str>")
        text = doubleQuotedPattern.replaces(text, with: "<str>")
        text = backtickQuotedPattern.replaces(text, with: "<str>")
        text = dottedNumberPattern.replaces(text, with: "N")
        text = digitsPattern.replaces(text, with: "N")
        text = repeatedPathPattern.replaces(text, with: "<path>")
        text = repeatedStringPattern.replaces(text, with: "<str>")
        text = text.replacingOccurrences(of: hexPlaceholder, with: "0xN")
        text = collapseWhitespace.replaces(text, with: " ")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if text.count > 240 { text = String(text.prefix(240)) }
        return text
    }

    static let exceptionClass = RX(#"[A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)+(?:Exception|Error|Throwable)\b"#)
    static let fatalErrorMessage = RX(#"\bFatal error\b"#)
    static let excBadAccess = RX(#"\bEXC_BAD_ACCESS\b"#)
    static let excCrashToken = RX(#"\bEXC_CRASH\b"#)
    static let tracebackLabel = RX(#"\bTraceback \(most recent call last\)"#)
    static let threadCrashed = RX(#"\bThread[ \t]+\d+[ \t]+Crashed\b"#)
    static let leadingSeparators = RX(#"^[\s:,;>\-|]+"#)

    /// 非 error 级返回 nil（不进聚类）。签名 = 「主 token + 归一化消息」。
    static func signature(for line: ParsedLogLine) -> String? {
        guard let severity = line.severity, isErrorFamily(severity) else { return nil }
        let haystack = line.message.isEmpty ? line.raw : line.message
        let token = mainToken(in: haystack) ?? mainToken(in: line.raw) ?? severity.rawValue

        // 把 token 本身从消息里挖掉再归一化，否则签名会把它重复两遍
        var remainder = haystack
        if let range = remainder.range(of: token) { remainder.removeSubrange(range) }
        remainder = leadingSeparators.replaces(remainder, with: "")
        let normalized = normalizeMessage(remainder)
        if normalized.isEmpty { return token }
        return "\(token): \(normalized)"
    }

    /// 主 token 依次取：Java 全限定异常类名 -> Traceback -> Thread N Crashed -> Fatal error -> EXC_*
    static func mainToken(in text: String) -> String? {
        if let result = exceptionClass.first(in: text), let token = rxGroup(result, 0, in: text) { return token }
        if let result = tracebackLabel.first(in: text), let token = rxGroup(result, 0, in: text) { return token }
        if let result = threadCrashed.first(in: text), let token = rxGroup(result, 0, in: text) {
            return collapseWhitespace.replaces(token, with: " ")
        }
        if fatalErrorMessage.first(in: text) != nil { return "Fatal error" }
        if excBadAccess.first(in: text) != nil { return "EXC_BAD_ACCESS" }
        if excCrashToken.first(in: text) != nil { return "EXC_CRASH" }
        return nil
    }

    // MARK: 堆栈

    static func stackFrame(in raw: String) -> String? {
        let text = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        var best: (location: Int, value: String)?
        for candidate in [javaFrame, nativeFrame, pythonFrame, genericAtFrame] {
            guard let result = candidate.first(in: text), let value = rxGroup(result, 0, in: text) else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { continue }
            if let current = best {
                if result.range.location < current.location { best = (result.range.location, trimmed) }
            } else {
                best = (result.range.location, trimmed)
            }
        }
        if let best { return best.value }

        // demangled 符号帧要求缩进：否则 `pkg.Class: message` 这类 Java 正文会被误认成帧
        if text.hasPrefix(" ") || text.hasPrefix("\t") || text.hasPrefix("\\t"),
           let result = swiftSymbolFrame.first(in: text), let value = rxGroup(result, 0, in: text) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty == false { return String(trimmed.prefix(200)) }
        }
        // macOS 符号化帧形如 `func() in binary (0x1..)`：只有同时含地址与 ` in ` 才认
        if hexFrame.first(in: text) != nil, text.contains(" in ") {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return String(trimmed.prefix(200))
        }
        return nil
    }

    /// 只取 basename：绝对路径会把用户目录结构泄漏进摘要与 UI。
    static func sourceFile(in raw: String) -> String? {
        let text = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        if let result = sourceFileFromFrame.first(in: text), let token = rxGroup(result, 1, in: text) {
            return lastPathComponent(of: token)
        }
        if let result = pythonFrame.first(in: text) {
            let ns = text as NSString
            let frame = ns.substring(with: result.range)
            if let quoted = quotedPath.first(in: frame), let path = rxGroup(quoted, 1, in: frame) {
                return lastPathComponent(of: path)
            }
        }
        if let result = fileLineFrame.first(in: text), let token = rxGroup(result, 0, in: text) {
            return lastPathComponent(of: token)
        }
        return nil
    }

    static func lastPathComponent(of token: String) -> String? {
        var value = token
        // 连续剥掉尾部的 `:123` `:42` 行列号，只留文件名
        while let range = value.range(of: ":", options: .backwards),
              value[range.upperBound...].isEmpty == false,
              value[range.upperBound...].allSatisfy({ $0.isNumber }) {
            value = String(value[..<range.lowerBound])
        }
        let name = value.split(separator: "/").last.map(String.init) ?? value
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.isEmpty == false, cleaned.contains(".") else { return nil }
        return cleaned
    }

    /// 多行堆栈归属：紧跟 error / exception / fatal / crash 事件之后的连续帧行。
    static func isStackLine(_ raw: String) -> Bool {
        let text = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return false }
        for pattern in stackLinePatterns where pattern.first(in: text) != nil { return true }
        return false
    }
}
