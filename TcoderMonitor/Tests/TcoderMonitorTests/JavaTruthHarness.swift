import Foundation
import XCTest
@testable import TcoderMonitor

/// OWNER: R1 · Java 函数识别流 —— 真值夹具的**判据器**（`JavaRecognitionTruthTests*` 专用）。
///
/// 为什么要单独一层：判据本体（「名单精确相等 + 逐个边界对齐 + 点名不许出现」）必须是**纯函数**，
/// 才能既吃真实扫描结果、又吃合成结果。合成结果那一路就是元测试——
/// 拿一份「伪函数 `h` 上榜、`setUp` 边界吃掉整个类体」的假输出喂进去，
/// 判据必须报出问题，否则这条闸门是永真绿（AGENTS §8 硬约束 6「新守卫要 sabotage 一次证明有牙」）。
///
/// 夹具里的真值标记：`// R1!名字` 标签名起始行，`// R1/名字` 标该名字**自己的**闭合 `}` 行。
/// 两个标记都是 Java 行注释，`ComplexitySanitizer` 会把它们剥掉，不影响被匹配的正文。
enum JavaTruth {
    struct Parsed {
        var lines: [String]
        /// 方法名 → 1-based 起止行（闭区间），由夹具里的标记读出。
        var truth: [String: ClosedRange<Int>]
    }

    static let beginToken = "// R1!"
    static let endToken = "// R1/"

    // MARK: 夹具解析

    static func parse(_ source: String) -> Parsed {
        var lines = source.components(separatedBy: "\n")
        if lines.last?.isEmpty == true { lines.removeLast() }
        var open: [String: Int] = [:]
        var truth: [String: ClosedRange<Int>] = [:]
        for (index, line) in lines.enumerated() {
            if let name = marker(in: line, token: beginToken) {
                open[name] = index + 1
            } else if let name = marker(in: line, token: endToken), let start = open[name] {
                truth[name] = start...(index + 1)
                open.removeValue(forKey: name)
            }
        }
        for (name, start) in open { truth[name] = start...start }  // 缺收尾标记 → 退化成一行的假真值，判据必红
        return Parsed(lines: lines, truth: truth)
    }

    static func marker(in line: String, token: String) -> String? {
        guard let range = line.range(of: token) else { return nil }
        let name = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// 内存构造被扫文件：不落 `.java` 进仓库，避免污染本仓自扫分母。
    static func scannedFile(_ lines: [String], language: String = "Java") -> ScannedSourceFile {
        ScannedSourceFile(
            url: URL(fileURLWithPath: "/r1-fixture/\(language)Fixture.src"),
            relativePath: "Fixture.\(language.lowercased())",
            language: language,
            lines: lines.enumerated().map {
                SourceLine(number: $0.offset + 1, text: $0.element, kind: .code)
            },
            blankLineCount: 0, commentLineCount: 0, codeLineCount: lines.count,
            todoCount: 0, fixmeCount: 0
        )
    }

    static func candidates(_ parsed: Parsed, language: String = "Java") -> [FunctionCandidate] {
        ComplexityEngine.functions(in: scannedFile(parsed.lines, language: language))
    }

    // MARK: 真磁盘夹具（端到端那一条用）

    /// 临时目录即建即删，**绝不写进仓库树内**（会被本仓自扫当真源码）。
    /// 与 `CodeAnalyzerTests.makeFixtureRoot` 同一套归一化：macOS 的 temporaryDirectory 在
    /// `/var -> /private/var` 之下，不取 canonicalPath 会让 relativePath 与「是否越出夹具根」失真。
    static func writeTemp(_ sources: [(path: String, text: String)]) throws -> URL {
        let fm = FileManager.default
        let made = fm.temporaryDirectory
            .appendingPathComponent("r1-java-truth-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: made, withIntermediateDirectories: true)
        let canonical = try? made.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath
        let root = (canonical?.isEmpty == false) ? URL(fileURLWithPath: canonical!) : made
        for source in sources {
            let url = root.appendingPathComponent(source.path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(source.text.utf8).write(to: url)
        }
        return root
    }

    static func remove(_ root: URL) throws {
        try FileManager.default.removeItem(at: root)
    }

    // MARK: 判据（纯函数）

    static func problems(parsed: Parsed, expected: [String], forbidden: [String],
                         found: [FunctionCandidate]) -> [String] {
        var out: [String] = []
        if Set(parsed.truth.keys) != Set(expected) {
            out.append("夹具自查失败：标记出的名字 \(parsed.truth.keys.sorted()) ≠ 期望表 \(expected.sorted())")
        }
        let names = found.map(\.name)
        if names.sorted() != expected.sorted() {
            out.append("识别名单不等于真值：实得 \(names.sorted())，期望 \(expected.sorted())")
        }
        for banned in forbidden where names.contains(banned) {
            out.append("误报未消除：榜上仍挂着 \(banned)")
        }
        for candidate in found {
            guard let span = parsed.truth[candidate.name] else { continue }
            let end = candidate.startLine + candidate.lineCount - 1
            if candidate.startLine != span.lowerBound || end != span.upperBound {
                out.append("边界未绑到该方法自己的 }: \(candidate.name) 实得 \(candidate.startLine)…\(end)，"
                    + "真值 \(span.lowerBound)…\(span.upperBound)")
            }
        }
        return out
    }

    /// 判据入口：跑一次真实扫描、把 `problems` 全量摊在失败信息里（可追溯：每条都带实得数字）。
    static func assertTruth(_ source: String, expected: [String], forbidden: [String],
                            language: String = "Java",
                            file: StaticString = #filePath, line: UInt = #line) {
        let parsed = parse(source)
        let found = candidates(parsed, language: language)
        let issues = problems(parsed: parsed, expected: expected, forbidden: forbidden, found: found)
        XCTAssertTrue(issues.isEmpty, issues.joined(separator: "\n"))
    }
}
