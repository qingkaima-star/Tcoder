//
// 崩溃报告的正则包装与判定表：`Pattern` / `Cue` / `FatalPhrase` 与全部 static let 表。
// 全部是不可变 static let，线程安全；从 CrashReportParser.swift 拆出只为控制单文件长度，
// 语义与拆分前完全一致。
//
import Foundation

// MARK: - 内部：正则包装与判定表（全部是不可变 static let，线程安全）

extension CrashReportParser {
    /// NSRegularExpression 的安全包装：编译失败就是 nil，所有查询按「不匹配」处理。
    struct Pattern {
        private let regex: NSRegularExpression?

        init(_ expression: String) {
            regex = try? NSRegularExpression(pattern: expression, options: [])
        }

        func matches(_ text: String) -> Bool {
            guard let regex, !text.isEmpty else { return false }
            let ns = text as NSString
            return regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)) != nil
        }

        /// group 0 是整条匹配，未命中的分组为 nil；整体不匹配返回 nil。
        func groups(in text: String) -> [String?]? {
            guard let regex, !text.isEmpty else { return nil }
            let ns = text as NSString
            guard let result = regex.firstMatch(
                in: text,
                options: [],
                range: NSRange(location: 0, length: ns.length)
            ) else { return nil }
            var values: [String?] = []
            for index in 0..<result.numberOfRanges {
                let range = result.range(at: index)
                values.append(range.location == NSNotFound ? nil : ns.substring(with: range))
            }
            return values
        }

        func firstMatch(in text: String) -> String? {
            guard let groups = groups(in: text), groups.count > 0, let whole = groups[0] else { return nil }
            let cleaned = CrashReportParser.trimmed(whole)
            return cleaned.isEmpty ? nil : cleaned
        }

        func firstGroup(in text: String, _ index: Int) -> String? {
            guard let groups = groups(in: text), index < groups.count, let value = groups[index] else { return nil }
            let cleaned = CrashReportParser.trimmed(value)
            return cleaned.isEmpty ? nil : cleaned
        }

        /// 一行里可能有多个文件名（例如 `at Foo.swift:12 (Bar.swift:9)`）。
        func allMatches(in text: String, group: Int = 0) -> [String] {
            guard let regex, !text.isEmpty, group >= 0 else { return [] }
            let ns = text as NSString
            var found: [String] = []
            regex.enumerateMatches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) { result, _, _ in
                guard let result, group < result.numberOfRanges else { return }
                let range = result.range(at: group)
                guard range.location != NSNotFound, range.length > 0, range.length < 200 else { return }
                found.append(ns.substring(with: range))
            }
            return found
        }
    }

    /// 崩溃报告扩展名（Apple DiagnosticReports 的常见后缀）。
    static let crashExtensions: Set<String> = [
        "ips", "crash", "panic", "diag", "spin", "csncrashed", "diagnostics",
    ]

    static let ipsMaxFrames = 8
    static let textMaxFrames = 12
    static let maxReadBytes = 4_000_000
    static let maxTextLines = 20_000
    static let maxTextEvents = 2_000

    static let exceptionTypePattern = Pattern("\\bEXC_[A-Z][A-Z0-9_]{2,}\\b")
    static let machineCodePattern = Pattern("\\b(?:KERN_[A-Z][A-Z_]{2,}|BUS_[A-Z][A-Z_]{2,}|ILL_[A-Z][A-Z_]{2,}|SEGV_[A-Z][A-Z_]{2,}|FPE_[A-Z][A-Z_]{2,})\\b")
    static let signalPattern = Pattern("\\bSIG(?:SEGV|ABRT|BUS|ILL|TRAP|KILL|SYS|EMT|XCPU|XFSZ|PIPE|TERM|INT|QUIT|STOP|USR1|USR2)\\b")
    static let exceptionTypeValuePattern = Pattern("\\bException Type\\s*:\\s*([^\\n·]+)")
    static let terminationValuePattern = Pattern("\\bTermination Reason\\s*:\\s*([^\\n·]+)")
    static let crashedThreadPattern = Pattern("^\\s*Thread\\s+\\d+\\s+(?:Crashed|crashed)\\b")
    static let anyThreadPattern = Pattern("^\\s*Thread\\s+\\d+\\b")
    static let sectionStopPattern = Pattern("^\\s*(?:Binary Images|Extra Information|Application Specific Information|Last Exception Backtrace|VM Regions|Used Images|Thread State)\\b")
    static let dateLabelPattern = Pattern("^\\s*(?:Date/Time|Timestamp|Incident Date)\\s*:\\s*(.+)$")
    static let fileNameDatePattern = Pattern("(\\d{4})-(\\d{2})-(\\d{2})[-_](\\d{2})(\\d{2})?(\\d{2})?")
    static let sourceFilePattern = Pattern("(?:[A-Za-z0-9_$.\\-]+[/\\\\])+([A-Za-z0-9_$.\\-]+)\\.(?:swift|mm|c|cc|cpp|cxx|m|py|js|jsx|ts|tsx|kt|java|go|rs)\\b|[A-Za-z0-9_$.\\-]+\\.(?:swift|mm|c|cc|cpp|cxx|m|py|js|jsx|ts|tsx|kt|java|go|rs)\\b")

    // MARK: 纯文本报告里的归属字段（RD-23：应用与构建身份要显式绑定，不靠目录名猜）

    static let incidentIDPattern = Pattern("\\bIncident Identifier\\s*:\\s*([0-9A-Fa-f]{6,}(?:-[0-9A-Fa-f]+){0,4})")
    static let processNamePattern = Pattern("^\\s*Process\\s*:\\s*(\\S+)")
    static let reportVersionPattern = Pattern("^\\s*Version\\s*:\\s*(.+)$")
    static let reportOSVersionPattern = Pattern("^\\s*OS Version\\s*:\\s*(.+)$")
    static let reportIdentifierPattern = Pattern("^\\s*Identifier\\s*:\\s*(\\S+)")

    /// 「这份内容**看起来是一份报告**」的形状判据：有报告独有的机器字段名。
    /// 命中却取不出事件证据 ⇒ 判 `.parseFailed`（内容坏了）；
    /// 一个都没命中 ⇒ 判 `.suspected`（它根本不是报告，只是名字/目录像）。
    static let reportShapeMarkers: [String] = [
        "incident identifier", "exception type", "termination reason", "bug_type",
        "incident_id", "\"threads\"", "thread ", "crashed thread", "os version", "code type",
        "\"exception\"", "\"app_version\"", "\"procname\"",
    ]

    /// 堆栈帧行的几种写法（Apple 文本 / lldb / 带源码行）。
    static let framePatterns: [Pattern] = [
        Pattern("^[ \\t]*\\d{1,3}[ \\t]+\\S+[ \\t]+0x[0-9a-fA-F]{6,}[ \\t]+\\S[^\\n]*[+-][ \\t]*\\d+[ \\t]*$"),
        Pattern("^[ \\t]*(?:frame[ \\t]+)?#[ \\t]*\\d+[ \\t]*:?[ \\t]+0x[0-9a-fA-F]{6,}[ \\t]+\\S[^\\n]*$"),
        Pattern("^[ \\t]*(?:frame[ \\t]+)?#[ \\t]*\\d+[ \\t]*:?[ \\t]+in[ \\t]+\\S[^\\n]*\\.(?:swift|mm|cc|cpp|c|py|js|ts|kt|java|go)\\b[^\\n]*$"),
        Pattern("^[ \\t]*\\d{1,3}[ \\t]+\\S+[ \\t]+[^\\t\\n ]+[^\\n]*\\([^\\n)]*\\.(?:swift|mm|cc|cpp|c|py|js|ts):\\d+\\)[ \\t]*$"),
    ]

    /// 特征词表。`startsReport` = 它足以单独算「一次崩溃」；
    /// false = 同一份报告里的补充信息，只并进主事件（避免一次崩溃被数成 5 次）。
    struct Cue {
        let label: String
        let startsReport: Bool
        let pattern: Pattern
    }

    static let cues: [Cue] = [
        Cue(label: "Fatal error", startsReport: true, pattern: Pattern("\\bFatal error\\b")),
        Cue(label: "Fatal Python error", startsReport: true, pattern: Pattern("\\bFatal Python error\\b")),
        Cue(label: "precondition failure", startsReport: true, pattern: Pattern("\\bprecondition failure\\b")),
        Cue(label: "assertion failure", startsReport: true, pattern: Pattern("\\bassertion failure\\b")),
        Cue(label: "pure virtual method called", startsReport: true, pattern: Pattern("\\bpure virtual method called\\b")),
        Cue(label: "terminate called after throwing", startsReport: true, pattern: Pattern("\\bterminate called after throwing\\b")),
        Cue(label: "kernel panic", startsReport: true, pattern: Pattern("\\bkernel panic\\b")),
        Cue(label: "uncaught exception", startsReport: true, pattern: Pattern("\\buncaught exception\\b")),
        Cue(label: "Incident Identifier", startsReport: true, pattern: Pattern("\\bIncident Identifier\\s*:")),
        Cue(label: "Exception Type", startsReport: true, pattern: Pattern("\\bException Type\\s*:")),
        Cue(label: "EXC_BAD_ACCESS", startsReport: false, pattern: Pattern("\\bEXC_BAD_ACCESS\\b")),
        Cue(label: "EXC_BAD_INSTRUCTION", startsReport: false, pattern: Pattern("\\bEXC_BAD_INSTRUCTION\\b")),
        Cue(label: "EXC_CRASH", startsReport: false, pattern: Pattern("\\bEXC_CRASH\\b")),
        Cue(label: "EXC_BREAKPOINT", startsReport: false, pattern: Pattern("\\bEXC_BREAKPOINT\\b")),
        Cue(label: "EXC_GUARD", startsReport: false, pattern: Pattern("\\bEXC_GUARD\\b")),
        Cue(label: "EXC_RESOURCE", startsReport: false, pattern: Pattern("\\bEXC_RESOURCE\\b")),
        Cue(label: "EXC", startsReport: false, pattern: Pattern("\\bEXC_[A-Z][A-Z0-9_]{2,}\\b")),
        Cue(label: "signal", startsReport: false, pattern: Pattern("\\bSIG(?:SEGV|ABRT|BUS|ILL|TRAP|KILL|SYS|EMT|XCPU|XFSZ|PIPE|TERM|INT|QUIT|STOP|USR1|USR2)\\b")),
        Cue(label: "Thread Crashed", startsReport: false, pattern: Pattern("\\bThread\\s+\\d+\\s+(?:Crashed|crashed)\\b")),
        Cue(label: "Termination Reason", startsReport: false, pattern: Pattern("\\bTermination Reason\\s*:")),
        Cue(label: "Exception Codes", startsReport: false, pattern: Pattern("\\bException (?:Codes|Subtype|Signal)\\s*:")),
        Cue(label: "Triggered by Thread", startsReport: false, pattern: Pattern("\\bTriggered by Thread\\s*:")),
        Cue(label: "Segmentation fault", startsReport: false, pattern: Pattern("\\bSegmentation fault\\b")),
        Cue(label: "Abort trap", startsReport: false, pattern: Pattern("\\bAbort trap\\b")),
    ]

    /// fatal 短语 -> 稳定签名标签（按声明顺序优先；"Segmentation fault" 归一成 SIGSEGV）。
    struct FatalPhrase {
        let label: String
        let pattern: Pattern
    }

    static let fatalPhrases: [FatalPhrase] = [
        FatalPhrase(label: "Fatal error", pattern: Pattern("\\bFatal error\\b")),
        FatalPhrase(label: "Fatal Python error", pattern: Pattern("\\bFatal Python error\\b")),
        FatalPhrase(label: "precondition failure", pattern: Pattern("\\bprecondition failure\\b")),
        FatalPhrase(label: "assertion failure", pattern: Pattern("\\bassertion failure\\b")),
        FatalPhrase(label: "terminate called after throwing", pattern: Pattern("\\bterminate called after throwing\\b")),
        FatalPhrase(label: "pure virtual method called", pattern: Pattern("\\bpure virtual method called\\b")),
        FatalPhrase(label: "kernel panic", pattern: Pattern("\\bkernel panic\\b")),
        FatalPhrase(label: "uncaught exception", pattern: Pattern("\\buncaught exception\\b")),
        FatalPhrase(label: "SIGSEGV", pattern: Pattern("\\bSegmentation fault\\b")),
        FatalPhrase(label: "SIGABRT", pattern: Pattern("\\bAbort trap\\b")),
    ]
}
