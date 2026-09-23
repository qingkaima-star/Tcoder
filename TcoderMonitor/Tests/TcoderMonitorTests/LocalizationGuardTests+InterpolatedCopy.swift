import Foundation
import XCTest
@testable import TcoderMonitor

// MARK: - 批次 P26：插值拼出来的中文串 = 查表永远查不到的那一类（只减不增棘轮）
//
// **形状**：`subtitle: "只有 \(n) 个历史点"`。整句里嵌了插值 ⇒ 源码里从来没有
// "只有 N 个历史点"这个**键**，`localizedCopy` 无从查起 ⇒ 英文态下这一行必然还是中文。
// 正确写法是整句键 + 位置参数：`localizedFormat("只有 %1$@ 个历史点", …)` ——
// 它字面量里没有 `\(`，所以这条尺子对**用对形状的**写法天然免疫（不是靠白名单豁免）。
//
// 立它的直接理由：英文态全量取证（交付头 `64c5418`，36 张）第一次逐张用眼睛看英文态，
// 照出「评分趋势」卡上**卡名是英文、紧挨着的副标题是中文**——
// 而那两行一个走查表、一个是插值拼串。这类缺陷中文态永远看不见。
//
// 为什么只钉本轮 UI 面（Health / Performance / Logs / PerfLogs / Shell）：
// 全站实测 114 处 / 26 个文件，榜首是 `Views/Dependencies/`（12 处），
// 那条目录此刻归整改轮 R3 在写。给别人的活跃面套自己的棘轮是误伤
// （守恒线要留逐条留名的豁免口，同理适用于"别把闸门下到别人车道上"）；
// 全站那 114 处属双语线存量（要逐处重构成整句键），登记在
// `docs/界面语言-对齐AiX.md` §6.26，由那条线按文件收。

extension LocalizationGuardTests {

    /// 本轮 UI 面。加目录要在这里加，并且基线要跟着实扫重量。
    static let interpolatedScanDirs = ["Health", "Performance", "Logs", "PerfLogs", "Shell"]

    /// 纯函数：数一段源码里"同时含 `\\(` 与汉字"的字符串字面量。
    /// 逐原始行 + 只剥整行注释（与全站其它扫描器同一道边界）。
    static func interpolatedHanLiterals(in content: String) -> [String] {
        let literal = try! NSRegularExpression(pattern: "\"((?:[^\"\\\\]|\\\\.)*?)\"")
        var hits: [String] = []
        for line in SurfaceScanKit.codeLines(content) {
            let range = NSRange(line.startIndex..., in: line)
            for match in literal.matches(in: line, options: [], range: range) {
                guard let inner = Range(match.range(at: 1), in: line) else { continue }
                let text = String(line[inner])
                let isHan = text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
                if text.contains("\\(") && isHan { hits.append(text) }
            }
        }
        return hits
    }

    /// 2026-09-22 在 `64c5418` 之后实扫播种：**40 处 / 12 个文件**
    /// （最多的一档是 `Logs/LogsMetricGrid.swift` 8 处）。只许往下调。
    private static let interpolatedCopyCeiling = 40

    func test_interpolatedChineseCopyInUiFaceDoesNotGrow() throws {
        var perFile: [String: Int] = [:]
        for dir in Self.interpolatedScanDirs {
            for file in try SurfaceScanKit.sourceFiles(under: "Views/\(dir)") {
                let n = Self.interpolatedHanLiterals(in: file.content).count
                if n > 0 { perFile[file.path] = n }
            }
        }
        let total = perFile.values.reduce(0, +)
        // 分母必须 > 0：扫不到文件时"0 处违规"是假零（这条守卫第一次写就要防这个）。
        XCTAssertFalse(perFile.isEmpty, "本轮 UI 面一个插值中文串都没扫到 ⇒ 先怀疑扫描面坏了")
        let ranked = perFile.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
        print("插值中文串现量 \(total) / 上限 \(Self.interpolatedCopyCeiling)，"
            + "分布：" + ranked.prefix(5).map { "\($0.key) \($0.value)" }.joined(separator: "、"))
        XCTAssertLessThanOrEqual(total, Self.interpolatedCopyCeiling,
                                 "插值拼出来的中文串涨了 \(total - Self.interpolatedCopyCeiling) 处："
                                 + "这种形状没有整句键，英文态永远查不到 ⇒ 改成 localizedFormat(\"整句 %1$@\", …)")
    }

    /// 元测试：用对形状的免疫、用错形状的必须抓到。
    func test_interpolatedCopyScannerSeparatesBothShapes() {
        // 原始字符串里 `\(` 就是字面量两个字符（插值需要写成 `\#(`），
        // 所以这里造的是"源码文本"，不是真的去插值一个不存在的 `n`。
        let wrong = #"subtitle: "只有 \(NumberFormat.grouped(n)) 个历史点""#
        XCTAssertEqual(Self.interpolatedHanLiterals(in: wrong).count, 1,
                       "插值中文串没被抓到 ⇒ 这条棘轮数不出东西")
        let right = #"subtitle: localizedFormat("只有 %1$@ 个历史点", NumberFormat.grouped(n))"#
        XCTAssertTrue(Self.interpolatedHanLiterals(in: right).isEmpty, "整句键 + 位置参数的被误伤")
        let pureInterpolation = #"Text("\(NumberFormat.grouped(n))")"#
        XCTAssertTrue(Self.interpolatedHanLiterals(in: pureInterpolation).isEmpty,
                      "没有汉字的纯数字插值被误伤")
    }


    // MARK: - 守卫 1h（P59）：**是文案就必须查表**（与上面 P26 那条同族：那条管插值，这条管裸串）

    /// P26 与 1g 只抓"含插值的中文段"，抓不到这一族：
    /// `return ["优先拆分最高复杂度函数"]` —— 没有插值、没有 `+`、也没被 `localized*` 包住，
    /// 三条键守卫全是绿的，而 `Text(变量)` 天生不查表 ⇒ **登记了也白登记**。
    /// 本条判的是：`Services/Health` 里**含汉字的字面量**必须是某个查表调用的第一个实参。
    ///
    /// 只判"字面量里有没有汉字"，所以标点字符（`"。"`、`"、"`）与英文串天然豁免；
    /// 查表调用**与字面量分了行**也不算违例（先把 `localized*( "…" )` 整段等长涂白，
    /// 再在原文坐标系上找剩下的汉字字面量 —— 行号仍是原文行号）。
    static func bareChineseLiterals(in content: String) -> [(line: Int, text: String)] {
        let literal = try? NSRegularExpression(pattern: #""(?:[^"\\\n]|\\.)*""#)
        let lookedUp = try? NSRegularExpression(
            pattern: #"localized(?:Copy|Count|Format)\(\s*"(?:[^"\\\n]|\\.)*""#)
        let han = try? NSRegularExpression(pattern: #"[\p{Han}]"#)
        guard let literal, let lookedUp, let han else {
            XCTFail("正则构造失败 ⇒ 这条判据根本没在跑")
            return []
        }
        let kept = content.split(separator: "\n", omittingEmptySubsequences: false)
            .map { raw -> String in
                let line = String(raw)
                return SurfaceScanKit.isCode(line) ? Self.strippingTrailingComment(line) : ""
            }
            .joined(separator: "\n")
        let whole = NSRange(kept.startIndex..., in: kept)
        var blanked = kept
        for match in lookedUp.matches(in: kept, range: whole).reversed() {
            guard let source = Range(match.range, in: kept),
                  let target = Range(match.range, in: blanked) else { continue }
            // **等长涂白，但换行必须原样留着**：把换行也换成空格会让后面每一行的行号
            // 集体前移（元测试钉的就是这一条：报错指不到地方，等于把人往错的地方支）。
            let preserved = String(kept[source].map { $0.isNewline ? $0 : " " })
            blanked.replaceSubrange(target, with: preserved)
        }
        let blankedRange = NSRange(blanked.startIndex..., in: blanked)
        return literal.matches(in: blanked, range: blankedRange).compactMap { match in
            guard let span = Range(match.range, in: blanked) else { return nil }
            let text = String(blanked[span])
            let textRange = NSRange(text.startIndex..., in: text)
            guard han.firstMatch(in: text, range: textRange) != nil else { return nil }
            let line = blanked[blanked.startIndex..<span.lowerBound].unicodeScalars
                .reduce(into: 0) { total, scalar in if scalar == "\n" { total += 1 } } + 1
            return (line, text)
        }
    }

    /// **已收口名单**（形状与 1d/1g 同源：名单里的文件一个都不许有，只许往长里加）。
    /// P59a 首批六个；`HealthBreakdown` / `HealthRuntimeDimensions` / `HealthTeamDimensions`
    /// 三个文件还有 98 处裸字面量，收完再点进来（现量由打印出声，不伪装成通过）。
    static let copyLookedUpFiles: [String] = [
        "Services/Health/ScoreCurves.swift",
        "Services/Health/ScoreCurvesCode.swift",
        "Services/Health/ScoreCurvesTeamRuntime.swift",
        "Services/Health/GitCadenceEvidence.swift",
        "Services/Health/HealthCodeDimensions.swift",
        "Services/Health/WeightedHealthScorer.swift",
    ]

    func test_copyInLookedUpFilesAlwaysGoesThroughTheCatalog() throws {
        let files = try SurfaceScanKit.sourceFiles(under: "")
        let scanned = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0.content) })
        let absent = Self.copyLookedUpFiles.filter { scanned[$0] == nil }
        XCTAssertTrue(absent.isEmpty,
                      "已收口名单点名的文件不在扫描面上（改名？挪走？）：\(absent)")
        let offenders = Self.copyLookedUpFiles.flatMap { path in
            Self.bareChineseLiterals(in: scanned[path] ?? "")
                .map { "\(path):\($0.line) \($0.text)" }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "这些中文文案字面量没走查表 ⇒ 英文态直接把中文铺上屏，而三条键守卫全绿"
                    + "（`Text(变量)` 不查表，登记了也白登记）：\n  "
                    + offenders.sorted().joined(separator: "\n  "))
        // 名单外的现量**只数 `Services/**`**：`Views/**` 里 `Text("中文")` 走的是
        // `LocalizedStringKey` 自己的查表，那是合法写法，按本条判据数进去会得到一个
        // 谁都不该去还的假债（1,673 处里绝大多数就是这一族）。
        let rest = files.filter { !Self.copyLookedUpFiles.contains($0.path)
                                 && $0.path.hasPrefix("Services/") }
            .reduce(0) { $0 + Self.bareChineseLiterals(in: $1.content).count }
        print("【文案必查表】已收口 \(Self.copyLookedUpFiles.count) 个文件 → 名单内 0 处；"
            + "`Services/**` 其余文件仍有 \(rest) 处（Views 不算：`Text(字面量)` 自己查表）")
    }

    /// 元测试：四种"没查表"的形状都要被抓到，三种合法写法一条不许误伤。
    func test_meta_bareCopyRulerCatchesUnlookedLiteralsAndSparesLegalShapes() {
        let dirty = [
            #"return ["优先拆分最高复杂度函数"]"#,
            #"outcome.strengths.append(String(format: "注释密度适中（%.1f%%）", x))"#,
            #"label: "工程质量（代码口径）","#,
            #"let pads = ["其余维度处于可接受区间。", "建议保持观察。"]"#,
        ]
        let found = dirty.map { Self.bareChineseLiterals(in: $0).count }
        XCTAssertEqual(found, [1, 1, 1, 2], "漏一种形状，那一族就继续假绿：\(found)")
        let legal = [
            #"return [localizedCopy("优先拆分最高复杂度函数")]"#,
            "texts.recommendations.append(localizedCopy(\n    \"当前无明显短板：综合分只由这些分量按权重算出。\"))",
            #"if character == "。" || character == "、" { }"#,
            #"let key = "AppleLanguages""#,
        ]
        for line in legal {
            XCTAssertTrue(Self.bareChineseLiterals(in: line).isEmpty, "合法写法被误报：\(line)")
        }
        // 行号必须指到**原文**那一行（涂白不许让偏移漂），跨行调用也要算对。
        let across = "let a = 1\nlet b = [localizedCopy(\n  \"整句键\")]\nlet c = [\"裸中文\"]"
        XCTAssertEqual(Self.bareChineseLiterals(in: across).map(\.line), [4],
                       "行号漂了 ⇒ 报错指不到地方，而跨行的查表调用还被误判：\(Self.bareChineseLiterals(in: across))")
    }
}
