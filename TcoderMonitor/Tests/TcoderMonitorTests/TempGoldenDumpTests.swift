import XCTest
@testable import TcoderMonitor

/// 一次性取证：把 `VulnerabilitySource` 的全部对外输出逐字打出来，
/// 供重构前后 diff。用完即删，不进交付。
final class TempGoldenDumpTests: XCTestCase {

    private func rec(_ ecosystem: DependencyEcosystem, _ name: String, _ version: String) -> DependencyRecord {
        DependencyRecord(name: name, version: version, ecosystem: ecosystem, scope: .runtime,
                         manifestPath: "m", latestKnownVersion: nil,
                         versionCheckSource: .none, knownVulnerabilities: [])
    }

    func testDump() throws {
        var out = "GOLDEN-START\n"
        for rule in VulnerabilitySource.bundled {
            out += [
                rule.id, rule.ecosystem.rawValue, rule.package, rule.affectedBelow,
                rule.introducedIn ?? "<nil>", rule.fixedVersion ?? "<nil>",
                rule.severity.rawValue, rule.cveIdentifiers.joined(separator: "|"),
                rule.summary, rule.details, rule.source, rule.vulnerableRange,
            ].joined(separator: "\u{1}") + "\n"
        }
        out += "AFFECTS\n"
        let probes = ["", " ", "1.0.0", "4.17.20", "4.17.21", "4.17.22", "v1.2.82", "^2.16.0",
                      ">= 2.0.0", "未声明", "*", "latest", "2.31.0-SNAPSHOT", "0.9.1"]
        for rule in VulnerabilitySource.bundled {
            for probe in probes {
                out += "\(rule.id)|\(probe)|\(rule.affects(version: probe))\n"
            }
        }
        let deps: [DependencyRecord] = [
            rec(.npm, "lodash", "4.17.20"),
            rec(.npm, "lodash", "4.17.21"),
            rec(.maven, "org.apache.logging.log4j:log4j-core", "2.14.1"),
            rec(.python, "requests", "2.31.0"),
            rec(.python, "urllib3", "1.26.17"),
            rec(.maven, "com.alibaba:fastjson", "1.2.80"),
            rec(.maven, "unknown:thing", "1.0.0"),
            rec(.npm, "axios", "0.21.1"),
            rec(.maven, "commons-collections:commons-collections", "3.2.1"),
            rec(.maven, "io.jsonwebtoken:jjwt", "0.9.1"),
            rec(.maven, "com.fasterxml.jackson.core:jackson-databind", "2.13.3"),
            rec(.python, "django", "4.2.5"),
            rec(.python, "django", "4.2.6"),
            rec(.npm, "lodash", "未声明"),
        ]
        out += "OFFLINE\n"
        for v in VulnerabilitySource.offlineVulnerabilities(for: deps) {
            out += [v.id, v.package, v.ecosystem.rawValue, v.vulnerableRange,
                    v.fixedVersion ?? "<nil>", v.summary, v.severity.rawValue,
                    v.cveIdentifiers.joined(separator: "|"),
                    v.affectedDependencies.joined(separator: "|")].joined(separator: "\u{1}") + "\n"
        }
        out += "ADVISORIES\n"
        for a in VulnerabilitySource.bundledAdvisories(for: deps) {
            out += [a.id, a.aliases.joined(separator: "|"), a.summary, a.details,
                    a.severity.rawValue, a.affectedPackages.joined(separator: "|"),
                    a.ecosystem.rawValue, a.source, String(describing: a.cvssScore),
                    String(describing: a.publishedAt)].joined(separator: "\u{1}") + "\n"
        }
        out += "COVERED\n"
        for dep in deps {
            out += "\(dep.name)|\(dep.version)|\(VulnerabilitySource.coveredIdentifiers(ecosystem: dep.ecosystem, name: dep.name, version: dep.version).sorted().joined(separator: "|"))\n"
        }
        out += "GOLDEN-END"
        try out.write(toFile: "/tmp/x2-vuln-golden.txt", atomically: true, encoding: .utf8)
        print("【golden】\(out.count) 字符 → /tmp/x2-vuln-golden.txt")
    }

    /// 崩溃报告通道的逐字取证：把 .ips 解析与纯文本段解析产出的**每一个字段**打出来。
    /// 覆盖 parseDiagnosticReport 拆出去的取值/栈/证据/rawLine 拼装四段，以及
    /// parseTextSegment / crashSignature / title 的全部形状。
    func testDumpCrash() throws {
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        var out = "CRASH-GOLDEN-START\n"
        for text in TempGoldenDumpTests.crashFixtures {
            out += "=== FIXTURE ===\n"
            let events = CrashReportParser.parseDiagnosticReport(text: text, path: "/Logs/Foo.ips", modifiedAt: stamp)
            out += TempGoldenDumpTests.dump(events)
            out += "=== TEXTCHANNEL ===\n"
            out += TempGoldenDumpTests.dump(CrashReportParser.parseCrashText(
                text: text, path: "/Logs/crash.log", modifiedAt: stamp))
        }
        out += "CRASH-GOLDEN-END"
        try out.write(toFile: "/tmp/x2-crash-golden.txt", atomically: true, encoding: .utf8)
        print("【crash golden】\(out.count) 字符 → /tmp/x2-crash-golden.txt")
    }

    static func dump(_ events: [LogEvent]) -> String {
        var rows: [String] = []
        for event in events {
            var parts: [String] = []
            parts.append(event.date.map { String($0.timeIntervalSince1970) } ?? "<nil>")
            parts.append(event.severity.rawValue)
            parts.append(event.rawLine)
            parts.append(event.message)
            parts.append(event.sourceLogPath)
            parts.append(String(event.lineNumber))
            parts.append(event.stackFrames.joined(separator: "|"))
            parts.append(event.sourceFiles.joined(separator: "|"))
            parts.append(event.isCrash ? "T" : "F")
            parts.append(event.isContinuation ? "T" : "F")
            parts.append(event.exceptionToken ?? "<nil>")
            parts.append(CrashReportParser.crashSignature(from: event) ?? "<nil>")
            rows.append(parts.joined(separator: "\u{1}"))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    static let crashFixtures: [String] = [
        // 1) 完整 header+body：exception / termination / asi / threads(frames 直挂) / 身份字段
        """
        {"app_name":"TcoderMonitor","bug_type":"309","incident_id":"AAAA-1111","os_version":"macOS 26.5","product":"MacBookPro18,1","app_version":"1.0","app_session":"S1","timestamp":"2026-09-20 21:01:02.00 +0800"}
        {"procName":"TcoderMonitor","bug_type":"309","app_version":"1.0","app_session":"S1","incident_id":"AAAA-1111","os_version":"macOS 26.5","product":"MacBookPro18,1","exception":{"codes":"0x0000000000000001, 0x0000000000000000","subtype":"KERN_INVALID_ADDRESS at 0x0000000000000010","type":"EXC_BAD_ACCESS","signal":"SIGSEGV","codes_if_signaled":["a","b"]},"termination":{"reason":"Segmentation fault: 11","indicator":"SIGSEGV","flags":"0x0","notificationName":["x","y"]},"usedImages":[{"name":"TcoderMonitor"},{"path":"/usr/lib/libswiftCore.dylib"}],"threads":[{"triggered":true,"name":"com.apple.main-thread","queue":"userInteractive","frames":[{"imageIndex":0,"symbol":"main","sourceLineInfo":{"file":"/src/App.swift","line":42},"image_offset":255},{"image_index":1,"symbolLocation":"_platform_strlen in libsystem_platform.dylib"},{"imageIndex":99},{"imageIndex":-1,"image_offset":-5}]},{"triggered":false,"frames":[{"symbol":"other"}]}],"asi":{"Backtrace":[["k1",["v1","v2"]],["k2",[]]],"Diagnose":[{"a":"1","b":""}],"Other":[["k3","v3"]]}}
        """,
        // 2) 单行 JSON、无 exception，只有 lastExceptionBacktrace + backtrace.frames 嵌套形状
        """
        {"incident_identifier":"B-2","reporting_time":"2026-09-20T10:00:00Z"}
        {"proc_name":"Helper","exceptionStrings":"EXC_CRASH (SIGABRT)","backtrace":{"frames":[{"symbol":"abort","binary_name":"libc","sourceLineInfo":{"filePath":"/x/y.mm","lineNumber":7}}]},"lastExceptionBacktrace":[{" imageName ":"Foo"}],"termination":{"notificationName":"NSApplicationCrashOnExceptions"}}
        """,
        // 3) body 解不开、退化成 header；threads 用 crashedThread 下标；帧是裸字符串
        """
        {"timestamp":"2026-09-18-132231","app_name":"A","not json at all
        """,
        // 4) 纯文本崩溃日志（走 parseCrashText 的段切分与 cue/帧挂载）
        """
        Incident Identifier: C-3
        CrashReporter Key:   abc
        Hardware:            MacBookPro18,1
        Process:             TcoderMonitor [123]
        Path:                /Applications/TcoderMonitor.app/Contents/MacOS/TcoderMonitor
        Identifier:          com.tcoder.monitor
        Version:             1.0 (1)
        Code Type:           ARM-64
        Parent Process:      launchd [1]
        Date/Time:           2026-09-20 21:01:02.00 +0800
        OS Version:          macOS 26.5 (23F1)
        Exception Type:  EXC_BAD_ACCESS (SIGSEGV)
        Exception Codes: KERN_INVALID_ADDRESS at 0x0000000000000010
        Exception Subtype: SIGSEGV
        Termination Reason: Namespace SIGNAL, Code 11
        Triggered by Thread:  0
        Thread 0 Crashed:
        0   TcoderMonitor  0x0000000102345678 main + 42
        1   libswiftCore.dylib  0x0000000103456789 _platform_strlen + 1
        2   TcoderMonitor  0x000000010456789a SwiftUIView.body (Sources/App.swift:120)
        Thread 1:
        3   libsystem_pthread.dylib 0x00000001056789ab start_wqthread + 0
        Binary Images:
        0x102000000 - 0x102ffffff TcoderMonitor arm64 <deadbeef> /Applications/TcoderMonitor.app/Contents/MacOS/TcoderMonitor
        Fatal error: Unexpectedly found nil while unwrapping an Optional value
        precondition failure: flag is false
        Assertion failure: x > 0
        """,
        // 5) 累积型 crash.log（无 Incident Identifier，多个锚点词各自成事件）
        """
        Fatal error: bad things happened at Sources/A.swift:1
        some noise line
        terminate called after throwing an instance of 'std::exception'
        kernel panic: unwinding got a trap
        0   App  0x0000000100000000 doWork (App.swift:8)
        Segmentation fault: 11
        Abort trap: 6
        uncaught exception NSInvalidArgumentException
        pure virtual method called
        EXC_BAD_ACCESS somewhere
        """,
    ]
}
