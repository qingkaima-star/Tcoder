import XCTest

/// 总工（尺子线）—— **提交里不许留着没解完的合并标记**。
///
/// # 为什么必须有它（今天两次真踩，一次是我自己）
/// 解冲突时按**字符偏移**切文本，`>>>>>>>` 那一行不会被删干净，而是**粘在下一行代码的尾巴上**：
/// `…readFailureDistribution(self))` 后面直接跟着七个 `>` 与一个分支名。它在 `Sources/` 里会被编译器抓到（今天就是这么发现的），
/// 但同一把手术落在 **`.strings` / `.stringsdict` / JSON 夹具**里就**完全静默**——
/// 目录解析失败时守卫只会说"格式不正确"，而 `try?` 会把它读成"没有数据"。
/// 更糟的是既有的检查都看不见它：`git status` 只看**索引态**（`UU`/`AA`/`DU`），
/// 已经 commit 掉的标记在它眼里是干净的；而按行首锚定（`^<<<<<<<`）的 grep
/// 对**行尾残留**天生是瞎的。⇒ 这条判据补的就是这一格。
///
/// # 扫描面为什么只有这三层
/// 只扫会被编译或被解析的东西：`Sources/**`、`Tests/**`、`Resources/**`。
/// `docs/**` 与 `scripts/**` **故意不扫**：台账与脚本里会正当引用这三个标记
/// （"剥掉粘在行尾的标记"这种句子本身就带着它），把它们算成违例就是把判据喂成噪音，
/// 而噪音判据的下场是被下一轮放宽——本仓记过好几回。
final class ConflictMarkerGuardTests: XCTestCase {

    /// 标记字面量**拼出来**，本文件里不出现真的标记（否则这条守卫会被自己判红，
    /// 而"守卫自己的金丝雀把判据喂活"是第 8 类静默失效）。
    static let leftMarker = String(repeating: "<", count: 7) + " "
    static let rightMarker = String(repeating: ">", count: 7) + " "

    static let scannedRoots = ["Sources", "Tests", "Resources"]

    static let scannedExtensions: Set<String> = [
        "swift", "m", "h", "strings", "stringsdict", "json", "xcprivacy", "entitlements",
    ]

    /// 一处违例 = 文件 + 行号 + 该行前 72 个字符。
    static func markerHits(in text: String, file: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { index, raw in
            let line = String(raw)
            // 只看**包含**，不做行首锚定：今天这处正好在行尾。
            guard line.contains(leftMarker) || line.contains(rightMarker) else { return nil }
            let excerpt = String(line.prefix(72)).replacingOccurrences(of: "\r", with: "")
            return "\(file):\(index + 1) 　\(excerpt)"
        }
    }

    /// 目录内递归收后缀命中的文件。读不到的目录**要报错**，不许静默跳过成"扫到 0 个"。
    static func files(under root: URL) throws -> [URL] {
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        guard let walker else {
            throw NSError(domain: "ConflictMarkerGuard", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "枚举不了 \(root.path) ⇒ 这条判据会退化成空扫"])
        }
        return walker.compactMap { item in
            guard let url = item as? URL, scannedExtensions.contains(url.pathExtension) else { return nil }
            return url
        }.sorted { $0.path < $1.path }
    }

    static var packageRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // TcoderMonitorTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // TcoderMonitor

    func test_noConflictMarkersLeftInCompiledOrParsedFiles() throws {
        var scanned = 0
        var hits: [String] = []
        for dir in Self.scannedRoots {
            let root = Self.packageRoot.appendingPathComponent(dir)
            let found = try Self.files(under: root)
            XCTAssertFalse(found.isEmpty, "\(dir) 一个可扫文件都没有 ⇒ 这条判据在空跑（永真绿）")
            scanned += found.count
            for file in found {
                let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                let relative = String(file.path.dropFirst(Self.packageRoot.path.count))
                hits += Self.markerHits(in: text, file: relative)
            }
        }
        // 分母出声：扫到多少文件必须打出来，"0 违例"才读得出是"查过了"还是"没查到"。
        let roots = Self.scannedRoots.joined(separator: "、")
        print("【合并标记】扫 \(scanned) 个会被编译/解析的文件（\(roots)） → 残留 \(hits.count) 处")
        XCTAssertTrue(hits.isEmpty,
                      "这些文件里留着没解完的合并标记 ⇒ 在 `.strings`/JSON 里它是静默的："
                    + "目录解析失败会被读成「没有数据」，而 `git status` 只看索引态、看不见已提交的标记：\n"
                    + hits.joined(separator: "\n"))
    }

    /// 双向元测试：行首与**行尾**两种位置都要抓到，干净文本不许乱咬。
    /// 只钉行首的那一版是这条判据的反例（今天那次漏网就是因为它在行尾）。
    func test_meta_markerRulerSeesBothEndsOfTheLine() {
        let head = Self.leftMarker + "HEAD"
        let tail = "        value = thing(arg))" + Self.rightMarker + "main"
        let caught = Self.markerHits(in: "一行正常\n" + head + "\n代码 x()\n" + tail, file: "A.swift")
        XCTAssertEqual(caught.count, 2, "行首与行尾各一处，必须都数到：\(caught)")
        XCTAssertTrue(caught[0].contains("A.swift:2"), "要报得出文件与行号：\(caught[0])")
        XCTAssertTrue(caught[1].contains(":4"), "行尾那处不能因为不在行首就漏：\(caught[1])")
        XCTAssertTrue(Self.markerHits(in: "正常一行\n" + Self.leftMarker + "别人复制的示例",
                                      file: "B.swift").isEmpty == false,
                      "反例：含标记就该被抓到（这条同时证明我没把判据写成永假）")
        XCTAssertTrue(Self.markerHits(in: "func f() { return 1 }\nlet a = b < c", file: "C.swift").isEmpty,
                      "小于号连着普通比较表达式不许被当成标记")
    }
}
