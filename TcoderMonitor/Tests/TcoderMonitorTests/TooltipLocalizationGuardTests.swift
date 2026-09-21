import XCTest

/// 规则：**视图层 `.help(...)` 的实参不许是"没查表的中文"**。
///
/// 要补的洞（批次 P14，英文态实测抓出来的）：`.help(_:)` 收的是**成品 String**，
/// 它自己**不查本地化目录**（双语方案 §7.1）。所以只要写 `.help("中文一句")`，
/// 英文界面上那格 hover 就永远是中文 —— 而这类句子此前**没有任何机器在看**：
/// tooltip 那三把尺子数的是"槽位数"与"可见长句数"，没有一把问"这句话查没查表"。
/// 更阴的是：其中 **9 条句子早就登记在 `Localizable.strings` 里**了，
/// 只是没人去查 —— 又一次「键存在 ≠ 查得中」。
///
/// 判据（静态，零容忍）：扫 `Sources/**`，凡 `.help(` 之后的同一行里出现汉字，
/// 而那一行又没有 `localizedCopy` / `localizedFormat` 兜底，就点名判败。
/// 注释行与文档示例跳过（扫描型守卫的老坑：把说明文字当代码数）。
///
/// 限度要写清楚，别把这把尺子当成万能：
/// - 它看不见 `.help(section.title)` 这类**参数里没有汉字、值却是中文**的落点
///   （侧栏页名那 9 条就是这一类，靠人工接进 `localizedCopy`，
///   由下面的元测试钉住"包一层"这个形状不许退回去）；
/// - 它也不管 **Service 层拼出来的整句**（`limitationSummary`、`SourceSkipLedger.clearing`
///   等），那是 F13 单独一案，量级由 `scripts/ax_tooltip_report.sh` + `AX_LANG=en`
///   在活界面上量（见 `docs/界面语言-对齐AiX.md` §6.15）。
final class TooltipLocalizationGuardTests: XCTestCase {

    static func violations(in files: [(path: String, content: String)]) -> [String] {
        var hits: [String] = []
        for file in files {
            for (index, raw) in file.content.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.startswithComment { continue }
                guard let match = line.range(of: ".help(") else { continue }
                let argument = String(line[match.upperBound...])
                let hasHan = argument.contains { $0 >= "\u{4E00}" && $0 <= "\u{9FFF}" }
                guard hasHan, !argument.contains("localized") else { continue }
                hits.append("\(file.path):\(index + 1)")
            }
        }
        return hits
    }

    func test_noHelpArgumentSkipsTheCatalog() throws {
        let views = try SurfaceScanKit.sourceFiles(under: "Views")
        let design = try SurfaceScanKit.sourceFiles(under: "Design")
        let files = views + design
        let found = Self.violations(in: files)
        XCTAssertTrue(found.isEmpty,
                      "这些 `.help(...)` 的实参是**没查表的中文**，英文态会原样上屏：\(found)")
    }

    // MARK: - 元测试：三个方向都要钉住

    /// 坏样例必须抓得到（否则主门是永真绿）。
    func test_meta_catchesARawChineseHelpLiteral() {
        let files = [("X.swift", "Text(\"a\")\n    .help(\"这句没查表\")\n")]
        XCTAssertEqual(Self.violations(in: files), ["X.swift:2"])
    }

    /// 好样例必须放过：查表包一层、或实参里根本没有汉字。
    func test_meta_passesLocalizedAndNonLiteralForms() {
        let files = [("Y.swift", """
        .help(localizedCopy("这句查了表"))
        .help(localizedFormat("%1$@ · 次改动", n))
        .help(section.title)
        .help("Live CPU / memory in use")
        """)]
        XCTAssertTrue(Self.violations(in: files).isEmpty, "\(Self.violations(in: files))")
    }

    /// 注释里的例子不算代码 —— 扫描型守卫最容易在此处虚报（本仓已经吃过几次）。
    func test_meta_ignoresCommentLines() {
        let files = [("Z.swift", """
        // .help("注释里的举例不算")
        /// .help("文档注释里的也不算")
        """)]
        XCTAssertTrue(Self.violations(in: files).isEmpty)
    }
}

private extension String {
    var startswithComment: Bool { hasPrefix("//") || hasPrefix("///") || hasPrefix("*") }
}
