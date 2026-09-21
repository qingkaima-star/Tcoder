import Foundation
import SwiftUI
import AppKit
import XCTest
@testable import TcoderMonitor

/// 英文定宽列复量（双语方案 §4 第 4 条 / §12.6 第 1 条，工单 #17）。
///
/// **为什么要有这条**：英文态实拍里 `Engineering Quality (code b…` 被省略号截断 ——
/// 中文 17 字放得下的列，英文 33 字符放不下。译文是逐条写进目录的，
/// 每加一条英文就可能撞上一次，而且**只在英文态发生**，中文门禁永远看不见。
///
/// **为什么按"标签形态"筛**：定宽列装的是标签，不是散文。
/// 判据 = 键（中文原文）≤ 12 个汉字的条目 ⇒ 它是标签/列名/单位，
/// 会落在 `Theme.Layout.fieldLabelWidth`(160) 这类定宽槽里；
/// 长句走散文区，会换行，不受这条管。
///
/// 尺子是 `NSAttributedString.size()` + `NSFont.systemFont`，
/// 与 SwiftUI 的真实渲染不完全等价（字距、prose 的 tracking 有差），
/// 所以这里**只用来列清单与拦明显越界**，最终验收仍是英文态实拍。
/// `test_rulerMeasuresWhatItClaims` 就是钉这把尺子不是永真绿。
final class EnglishWidthAuditTests: XCTestCase {

    /// 定宽标签槽的预算（pt）。取自 `Theme.Layout.fieldLabelWidth`，
    /// 留 6pt 给 `.frame` 之前的行内边距 —— 宁可先紧后松。
    /// 英文档那一列的预算（守卫按**英文态**量，不是当前系统语言）。
    private static let labelBudget: CGFloat = Theme.Layout.fieldLabelWidthEnglish - 6

    static func width(of text: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight)
        ]
        return ceil(NSAttributedString(string: text, attributes: attributes).size().width)
    }

    /// 定宽标签槽的**真实内容集合**：从调用点取，不按"看着像标签"猜。
    ///
    /// 第一版按"键 ≤ 12 汉字"筛标签，当场误判 35 条 —— 里面大半是
    /// `开发依赖不随产物发布`、`已完成扫描，没有函数上榜` 这类**会换行的散文**，
    /// 它们根本不住在定宽列里。误判的守卫会逼人为了过闸去改一个本来没错的写法，
    /// 所以改成扫 `DataFieldRow(label:` / `Theme.Readout.Field(` 的实参。
    static func fixedColumnLabels(in files: [(path: String, content: String)]) -> Set<String> {
        var out: Set<String> = []
        let patterns = [
            #"DataFieldRow\(label:\s*"([^"]*)""#,
            #"label:\s*"([^"]*)"[^\n]*?value:"# as String,
            #"Theme\.Readout\.Field\(\s*"([^"]*)""#,
            #"Theme\.Readout\.Field\(\s*([A-Za-z_][A-Za-z0-9_.]*)\s*,"#,
        ]
        let regexes = patterns.map { try! NSRegularExpression(pattern: $0, options: []) }
        for file in files {
            for line in file.content.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                let range = NSRange(line.startIndex..., in: line)
                for re in regexes {
                    for m in re.matches(in: line, options: [], range: range) {
                        guard let r = Range(m.range(at: 1), in: line) else { continue }
                        let text = String(line[r])
                        if text.contains(where: { "\u{4E00}" <= $0 && $0 <= "\u{9FFF}" }) {
                            out.insert(text)
                        }
                    }
                }
            }
        }
        return out
    }

    func test_englishLabelsFitTheFixedLabelColumn() throws {
        let catalogPath = LocalizationGuardTests.packageRoot
            .appendingPathComponent("Resources/en.lproj/Localizable.strings").path
        // 不用 `uniqueKeysWithValues`：目录里出现重复键时它会**直接崩掉整个套件**，
        // 而"有重复键"本身是要被守卫点名的问题（见 LocalizationGuardTests 的键唯一性断言）。
        let entries = Dictionary(
            LocalizationGuardTests.parseCatalog(
                try String(contentsOfFile: catalogPath, encoding: .utf8)).map { ($0.key, $0.value) },
            uniquingKeysWith: { first, _ in first })
        let files = try SurfaceScanKit.sourceFiles(under: "Views")
            + SurfaceScanKit.sourceFiles(under: "Design")
        var labels = Self.fixedColumnLabels(in: files)
        // **调用点扫不到"变量喂进来的槽"**：`Theme.Readout.Field(scope.label, …)`
        // 里 `scope.label` 是运行时值，静态只看得到标识符。英文实拍里被截断的
        // `Engineering Quality (code b…` 正是这一类 —— 只扫字面量会得到一个假绿 0。
        // 所以把这些槽的真实值来源（枚举 rawValue）直接并进内容集合。
        labels.formUnion(HealthDimension.allCases.map(\.rawValue))
        labels.formUnion(DetailSection.allCases.map(\.rawValue))
        XCTAssertGreaterThanOrEqual(labels.count, 40,
                                    "只扫到 \(labels.count) 个定宽标签 —— 扫描器坏了，不是没有债")

        let tier = Theme.Typo.label
        var offenders: [(String, String, CGFloat)] = []
        var untranslated: [String] = []
        for label in labels.sorted() {
            guard let english = entries[label] else { untranslated.append(label); continue }
            let measured = Self.width(of: english, size: tier.size, weight: Self.nsWeight(tier.weight))
            if measured > Self.labelBudget { offenders.append((label, english, measured)) }
        }
        offenders.sort { $0.2 > $1.2 }
        print("英文定宽复量：定宽标签 \(labels.count) 个（未登记译文 \(untranslated) 个）"
              + " / 预算 \(Int(Self.labelBudget))pt @ \(tier.size)pt · 越界 \(offenders.count) 个"
              + "（最宽 \(offenders.first.map { String(format: "%.0f", $0.2) } ?? "—")pt）")
        print("  未登记译文的定宽标签 \(untranslated.count) 个：\(untranslated.prefix(12))")
        XCTAssertTrue(offenders.isEmpty,
                      "这些英文标签在 \(Int(Self.labelBudget))pt 定宽列里放不下（英文态会被省略号截断）：\n"
                      + offenders.map { "  \($0.0) → \"\($0.1)\" = \(String(format: "%.0f", $0.2))pt" }
                        .joined(separator: "\n"))
    }

    static func nsWeight(_ weight: Font.Weight) -> NSFont.Weight {
        switch weight {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        default: return .regular
        }
    }

    /// 尺子的元测试：这条断言不成立时，上面那条"越界为 0"就是永真绿。
    func test_rulerMeasuresWhatItClaims() {
        let short = Self.width(of: "口径", size: 12, weight: .regular)
        let long = Self.width(of: "Engineering Quality (code basis)", size: 12, weight: .regular)
        XCTAssertGreaterThan(short, 10, "量不出宽度 —— 尺子是死的")
        XCTAssertGreaterThan(long, short * 5, "长英文串没量出明显更宽的占位，尺子失灵")
        // 样例必须**真的**能越界，否则"越界 0 条"可能只是筛子眼太大。
        // 预算从 154 抬到 194（英文档）后这条一度失效 —— 尺子的自证要跟着预算一起改，
        // 不能只把断言删掉了事。
        let overBudget = Self.width(of: "Engineering Quality (code basis, offline snapshot)",
                                    size: 12, weight: .regular)
        XCTAssertGreaterThan(overBudget, Self.labelBudget,
                             "造不出越界样例 —— 这条守卫永远不会红，等于没有")
        // 调用点筛选的正反双向：真槽位要抓到、散文实参不得误抓
        let sites = [(path: "Views/Fake.swift", content:
            "DataFieldRow(label: \"口径说明\", value: x, style: .text)\n"
          + "Theme.Readout.Field(\"维度名\", \"90 · A 级\")\n"
          + "DataNotice(text: \"这是一段会换行的长说明文字，不住在定宽列里\")\n")]
        XCTAssertEqual(Self.fixedColumnLabels(in: sites), ["口径说明", "维度名"],
                       "定宽标签扫描器失灵或把散文也抓进来了")
    }
}
