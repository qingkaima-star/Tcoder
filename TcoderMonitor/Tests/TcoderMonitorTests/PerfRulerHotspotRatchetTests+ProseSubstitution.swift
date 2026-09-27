//
//  PerfRulerHotspotRatchetTests+ProseSubstitution.swift
//
//  从宿主 `PerfRulerHotspotRatchetTests.swift` 整族搬来（2026-09-27，#105）：
//  这四格量的不是"尺子的复杂度/行数"，而是**尺子的话术会不会被 bash 真的执行**
//  （双引号里的反引号＝命令替换，2026-09-23 21:44 抓到两处、两处都是我自己写的）。
//  宿主当时 397/400 已贴 `X3TestSizeAuditTests` 的线 ⇒ **搬整族出去才是修复，抬线不是**。
//  搬动是逐字节的：`proseSubstitutionOffenders` / `backtickInsideDoubleQuotes`
//  与那两个 `func test_…` 的判据、断言、文案一字未改（多重集对冲自证，见 §203）。
//
@testable import TcoderMonitor
import XCTest

extension PerfRulerHotspotRatchetTests {

    // MARK: - 话术串里的命令替换（2026-09-23 21:44 抓到两处，两处都是我自己写的）

    /// 一行里**双引号串内部**出现反引号 ⇒ bash 把它当命令替换**真的执行**。
    /// 只看引号内部：注释里的反引号不执行、合法写法（`$( … )`）本来就该用；
    /// 整条判据管的是「把反引号当中文引号用」这一种形状——它只有跑起来才露，
    /// 而露出来的症状是「那行少了一个词 + stderr 多一行 command not found」，不是报错。
    static func backtickInsideDoubleQuotes(_ line: String) -> Bool {
        var inQuotes = false
        var escaped = false
        for ch in line {
            if escaped { escaped = false; continue }
            if ch == "\\" { escaped = inQuotes; continue }
            if ch == "\"" { inQuotes.toggle(); continue }
            if ch == "`" && inQuotes { return true }
        }
        return false
    }

    /// 只判会被执行的**输出行**（`echo` / `printf`），注释行跳过。
    static func proseSubstitutionOffenders(in content: String) -> [Int] {
        content.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            .compactMap { entry in
                let trimmed = entry.element.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("#"),
                      trimmed.contains("echo ") || trimmed.contains("printf ") else { return nil }
                return backtickInsideDoubleQuotes(String(entry.element)) ? entry.offset + 1 : nil
            }
    }

    func test_rulerScriptsDoNotRunSubstitutionInsideProse() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.scriptsRoot.path)
            .filter { $0.hasSuffix(".sh") }.sorted()
        XCTAssertGreaterThan(names.count, 10,
                             "scripts/ 只数到 \(names.count) 个 .sh ⇒ 读盘坏了，这条绿没有含义")
        var offenders: [String] = []
        var scannedLines = 0
        for name in names {
            let text = try String(contentsOf: Self.scriptsRoot.appendingPathComponent(name), encoding: .utf8)
            scannedLines += text.split(separator: "\n", omittingEmptySubsequences: false).count
            offenders += Self.proseSubstitutionOffenders(in: text).map { "\(name):\($0)" }
        }
        XCTAssertGreaterThan(scannedLines, 3_000, "总共只读到 \(scannedLines) 行 ⇒ 判据在空转")
        XCTAssertTrue(offenders.isEmpty,
                      "这些话术行会被 bash 真的执行（双引号里的反引号是命令替换）：\(offenders)")
    }

    /// 元测试双向：坏样例必须被抓且行号要对；两处合法写法（`$( … )`、注释里的反引号）不许被抓。
    /// 只断言"抓得住"的守卫是半个空转——它可能其实在什么都抓。
    func test_proseSubstitutionJudgeHasTeethBothWays() {
        let bad = "  echo \"==> 采集跑完：能不能进表由 `report` 与一致性判\""
        XCTAssertEqual(Self.proseSubstitutionOffenders(in: "x\n" + bad + "\ny"), [2],
                       "行号没指到那一行（拿到 \(Self.proseSubstitutionOffenders(in: "x\n" + bad + "\ny"))）")
        let okSubstitution = "  echo \"名册现量：$(printf '%s' \"$known\" | tr '\\n' ' ')\""
        let okComment = "  # 这里写反引号不执行：`report`"
        XCTAssertTrue(Self.proseSubstitutionOffenders(in: [okSubstitution, okComment].joined(separator: "\n")).isEmpty,
                      "合法写法不许被抓：$() 是看得见的替换，注释不执行")
    }
}
