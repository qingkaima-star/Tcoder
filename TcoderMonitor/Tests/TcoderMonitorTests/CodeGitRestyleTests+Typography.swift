/// OWNER: WS-X3 TestSplit —— 自 CodeGitRestyleTests.swift 拆出，正文数字与行节奏走同一套等宽助手、棘轮判据自证。用例本体未改，只是搬了家。
import XCTest
@testable import TcoderMonitor

extension CodeGitRestyleTests {

    /// 等宽与行节奏的覆盖面：承载数字的散文文本必须走 `CodeGitType.prose`（自带等宽数字），
    /// 而榜单行只能通过 `.dataTableRow()` 拿行高。两处都用源码扫描钉住，防止下一轮又各写各的。
    func testEveryProseNumberAndRowGoesThroughTheMonospacedHelpers() throws {
        let rowFiles: Set<String> = [
            "Code/CodeViewSupport.swift", "Code/CodeRiskRows.swift",
            "Git/ContributorRows.swift", "Git/GitInsightsCharts.swift",
            "Dependencies/DependencyVerdictRows.swift",
        ]
        let proseTiers = ["label", "microLabel", "narrative", "body", "cardTitle", "pageTitle"]
        var proseFonts: [String] = []
        var missingRhythm: [String] = []
        for file in try wsLSources() {
            for (index, line) in file.lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.starts(with: "//") else { continue }
                if proseTiers.contains(where: { trimmed.contains(".font(Theme.Typo.\($0).font)") }) {
                    proseFonts.append("\(file.name):\(index + 1): \(trimmed.prefix(60))")
                }
            }
            if rowFiles.contains(file.name), !file.body.contains(".dataTableRow()") {
                missingRhythm.append(file.name)
            }
        }
        XCTAssertTrue(proseFonts.isEmpty,
                      "散文文本要走 CodeGitType.prose，数字才保证等宽：\n\(proseFonts.joined(separator: "\n"))")
        XCTAssertTrue(missingRhythm.isEmpty,
                      "这些文件里有榜单行却没引用 .dataTableRow()：\(missingRhythm)")
    }

    func testRowRhythmComesFromOnePlace() {
        XCTAssertEqual(DataRowMetrics.verticalPadding, Theme.Spacing.xs)
        XCTAssertEqual(DataRowMetrics.rowGap, Theme.Spacing.xxs)
        XCTAssertEqual(DataRowMetrics.cellGap, Theme.Spacing.sm)
        XCTAssertEqual(DataRowMetrics.minRowHeight,
                       Theme.Layout.minHitTarget + Theme.Spacing.sm,
                       "行高下限必须可由令牌复算，不接受孤立数字")
        XCTAssertGreaterThanOrEqual(DataRowMetrics.minRowHeight, Theme.Layout.minHitTarget)
    }

    /// 元测试：证明上面那条棘轮不是空跑。
    /// 每条禁令都要能被一行合成违例命中，否则扫描会变成"永远绿的假安心"。
    func testRatchetPatternsActuallyDetectTheirOwnViolations() throws {
        let samples: [(String, String)] = [
            ("裸字号", #"        Text(x).font(.system(size: 9))"#),
            ("Theme 兼容桥旧色彩入口", "        tint: Theme.accent,"),
            ("Theme.color(for:)", "        .foregroundStyle(Theme.color(for: risk))"),
            ("裸颜色字面量", #"    Color(hex: "5C8DFF"), Color(red: 0.5, green: 0.5, blue: 0.5)"#),
            ("自造透明度", "        .background(status.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 3))"),
            ("旧分隔线", "                Divider().opacity(0.4)"),
            ("冻结在 Dashboard 的旧件", "            BannerRow(text: note, style: .warning)"),
            ("数字 padding", "            .padding(16)"),
            ("数字 spacing", "        VStack(spacing: 3) {"),
            ("数字尺寸", "                .frame(width: 4, height: 34)"),
            ("行内上下留白绕过 dataTableRow", "        .padding(.vertical, Theme.Spacing.xxs)"),
            ("未登记的裸符号串", #"            Image(systemName: "arrow.up.forward.app")"#),
            ("页面直取 Typo 档而没走等宽入口", "                    .font(Theme.Typo.microLabel.font)"),
            ("绕过 dataTableRow 的行内留白", "                VStack(spacing: Theme.Spacing.xs) {"),
        ]
        for (name, sample) in samples {
            XCTAssertTrue(try wsLForbiddenPattern(named: name).firstMatch(
                in: sample, range: NSRange(location: 0, length: sample.utf16.count)) != nil,
                "禁令「\(name)」匹配不到它本应抓住的写法：\(sample)")
        }
    }

    /// WS-I §6 提的"零新增"断言，落在本流自己的目录上：
    /// 视图层不得再出现裸字号/裸色/裸间距/旧兼容桥入口，注释里引用旧值做说明不算违例。
    func testRestyledPagesCarryNoRawVisualValues() throws {
        let forbidden = Self.forbiddenRawValues
        var violations: [String] = []
        for (name, pattern, pagesOnly) in forbidden {
            let regex = try NSRegularExpression(pattern: pattern)
            for file in try wsLSources() where !pagesOnly || !file.name.hasPrefix("CodeGit/") {
                for (index, line) in file.lines.enumerated() {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.starts(with: "//") { continue }
                    if regex.firstMatch(in: trimmed, range: NSRange(location: 0,
                                                                    length: trimmed.utf16.count)) != nil {
                        violations.append("\(name) → \(file.name):\(index + 1): \(trimmed.prefix(64))")
                    }
                }
            }
        }
        XCTAssertTrue(violations.isEmpty,
                      "WS-L 名下页面出现回潮值（\(violations.count) 处）：\n" + violations.joined(separator: "\n"))
    }

    /// 字号下限：本流页面只允许取 `Theme.Typo` 档位，而最低一档 `microLabel` 是 10pt。
    func testSmallestTypefaceOnMyPagesIsAtLeastTenPoints() throws {
        XCTAssertGreaterThanOrEqual(Theme.Typo.microLabel.size, 10,
                                    "低于 10pt 的中文在 macOS 上几乎糊成一团（WS-H §4.2）")
        let text = try wsLSources().map(\.body).joined(separator: "\n")
        XCTAssertFalse(text.contains(".caption2"), "语义 .caption2 会掉到 10pt 以下")
        XCTAssertFalse(text.contains("font(.caption"), "本流页面一律用 Theme.Typo 档位取字")
    }

}
