import XCTest
import Foundation

/// 双语守卫（方案见 `docs/中英双语方案.md`）。
///
/// 三条都是**扫描型**守卫，所以每条都配了"注入坏样例必须红"的元测试 ——
/// 本项目已经吃过四次假绿（假零 / 永真绿 / 门控绿灯 / 共享盲区），
/// 一个数不出东西的扫描器比没有扫描器更危险：它会让人以为有人在管。
///
/// 机制前提（决定下面为什么这么查）：
/// - **本地化键 = 中文原文**。所以缺译文时 macOS 退回显示键本身 = 正确的中文，
///   界面上永远不会出现 `contributor.busfactor.high` 这种机器键。
/// - 源语言 `zh-Hans` 因此**不需要**目录文件（键就是它自己）；只有 `en.lproj` 存在。
///   于是"两语言键集相等"这种查法是错的，真正要查的是：
///   ① 已迁移的文件里不许再有没登记的中文串；② 登记了却不翻；③ 翻了但代码里已无此串。
final class LocalizationGuardTests: XCTestCase {

    // MARK: - 读盘

    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/TcoderMonitorTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // TcoderMonitor
    }

    private static var englishCatalogPath: String {
        packageRoot.appendingPathComponent("Resources/en.lproj/Localizable.strings").path
    }

    /// 解析 `"键" = "值";`。
    ///
    /// 注释必须剥：目录文件里的说明文字大量带引号，不剥就会解析出假键。
    /// 曾经用"逐行状态机"剥块注释，结果**同行开合**的 `/* … */` 会把下一行
    /// 也当成注释吃掉 —— 于是 27 条键解析出 0 条，而"0 条"看起来像"目录是空的"。
    /// 现在直接按跨度删：先 `/* … */`（非贪婪、可跨行），再逐行删 `// …`。
    /// 已知局限：值里若真出现 `*/` 或 `//` 会被误剥 —— 本目录由我们自己写，
    /// 不放 URL；哪天要放，改的是这个解析器而不是放宽断言。
    static func parseCatalog(_ text: String) -> [(key: String, value: String)] {
        func dropping(_ pattern: String, from source: String, options: NSRegularExpression.Options) -> String {
            let re = try! NSRegularExpression(pattern: pattern, options: options)
            return re.stringByReplacingMatches(in: source, options: [],
                                               range: NSRange(source.startIndex..., in: source),
                                               withTemplate: "")
        }
        let stripped = dropping(#"/\*.*?\*/"#, from: text, options: [.dotMatchesLineSeparators])
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let comment = line.range(of: "//") else { return String(line) }
                return String(line[..<comment.lowerBound])
            }
            .joined(separator: "\n")

        let pattern = #"^\s*"((?:[^"\\]|\\.)+)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;"#
        let re = try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        let range = NSRange(stripped.startIndex..., in: stripped)
        var out: [(String, String)] = []
        for m in re.matches(in: stripped, options: [], range: range) {
            guard let kr = Range(m.range(at: 1), in: stripped),
                  let vr = Range(m.range(at: 2), in: stripped) else { continue }
            out.append((String(stripped[kr]), String(stripped[vr])))
        }
        return out
    }

    private static func catalog() throws -> [(key: String, value: String)] {
        let text = try String(contentsOfFile: englishCatalogPath, encoding: .utf8)
        let entries = parseCatalog(text)
        // 反向自证：目录读不出任何键 = 解析器坏了，而不是"这个包不需要翻译"。
        XCTAssertFalse(entries.isEmpty, "英文目录解析出 0 条 —— 解析器或路径坏了")
        return entries
    }

    /// 含 CJK 的界面串字面量（`Text("…")` / `Text(verbatim:"…")` 之外的都算），
    /// 返回「文件: 串」。**剥掉整行注释**。
    static func uiLiteralsNeedingKeys(in files: [(path: String, content: String)]) -> [String: Set<String>] {
        // ICU 正则**不认** Swift 的 `\u{4E00}` 写法，只认 `\u4E00`。
        // 写成前者时 `try?` 把编译失败吞成 nil，函数直接返回 [:] ——
        // 于是"没有任何未迁移的中文串"这个结论是假的。元测试抓的就是这个。
        let pattern = #"Text\(\s*(?:verbatim:\s*)?"((?:[^"\\]|\\.)*[\u4E00-\u9FFF](?:[^"\\]|\\.)*)""#
        let re = try! NSRegularExpression(pattern: pattern, options: [])
        var out: [String: Set<String>] = [:]
        for file in files {
            for line in file.content.split(separator: "\n", omittingEmptySubsequences: false) {
                let l = String(line)
                if l.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                let range = NSRange(l.startIndex..., in: l)
                for m in re.matches(in: l, options: [], range: range) {
                    guard let r = Range(m.range(at: 1), in: l) else { continue }
                    out[file.path, default: []].insert(String(l[r]))
                }
            }
        }
        return out
    }

    private static func sourceFiles() throws -> [(path: String, content: String)] {
        let root = packageRoot.appendingPathComponent("Sources/TcoderMonitor").path
        var out: [(String, String)] = []
        for sub in ["Views", "Design"] {
            for url in walkFiles(in: "\(root)/\(sub)") where url.hasSuffix(".swift") {
                out.append((String(url.dropFirst(root.count + 1)),
                            (try? String(contentsOfFile: url, encoding: .utf8)) ?? ""))
            }
        }
        XCTAssertGreaterThanOrEqual(out.count, 40, "扫到的界面文件只有 \(out.count) 个，分母不对")
        return out
    }

    private static func walkFiles(in dir: String) -> [String] {
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: dir) else { return [] }
        return en.compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") }
            .map { "\(dir)/\($0)" }
    }

    // MARK: - 守卫 1：已迁移的文件不许再有未登记的中文串

    /// **已完成迁移的文件清单。只许变长，不许变短。**
    ///
    /// 为什么用"完工清单"而不是"全局未迁移计数棘轮"：一个 26 的基线数字会随
    /// 任何人加一句中文而涨，涨了就"合法"，等于没有闸门；而"某个文件已经干净"
    /// 是一个可复核的事实，退回去就会立刻红。
    private static let migratedFiles: Set<String> = [
        // P1 尚未开始逐页迁移；P2 起每迁完一页把它的相对路径加进来。
    ]

    func test_migratedFilesHaveNoUnregisteredUILiterals() throws {
        guard !Self.migratedFiles.isEmpty else { return }   // 清单为空时不假装有结论
        let registered = Set(try Self.catalog().map(\.key))
        let literals = Self.uiLiteralsNeedingKeys(in: try Self.sourceFiles()
            .filter { Self.migratedFiles.contains($0.path) })
        let offenders = literals.flatMap { path, strings in
            strings.filter { !registered.contains($0) }.map { "\(path) → \"\($0)\"" }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "这些文件在已迁移清单里，却出现没登记的界面中文串：\n\(offenders.sorted().joined(separator: "\n"))")
    }

    // MARK: - 守卫 2：登记了就必须翻（值不等于键）

    /// 允许"值 = 键"的例外。**每条都要写理由**，否则白名单就是遮羞布。
    private static let identicalValueAllowlist: Set<String> = []

    func test_everyRegisteredKeyHasAnEnglishValue() throws {
        let entries = try Self.catalog()
        let untranslated = entries.filter { $0.value == $0.key }
            .map(\.key).filter { !Self.identicalValueAllowlist.contains($0) }
        XCTAssertTrue(untranslated.isEmpty,
                      "这些键登记了却没有译文（英文态会退回中文）：\(untranslated)")
        let empty = entries.filter { $0.value.isEmpty }.map(\.key)
        XCTAssertTrue(empty.isEmpty, "这些键的译文是空串：\(empty)")
    }

    // MARK: - 守卫 3：译文不许烂尾（键必须在代码里真实出现）

    func test_noStaleKeysInCatalog() throws {
        let entries = try Self.catalog()
        let allSource = try Self.walkFiles(in: Self.packageRoot.appendingPathComponent("Sources/TcoderMonitor").path)
            .reduce("") { $0 + ((try? String(contentsOfFile: $1, encoding: .utf8)) ?? "") }
        let stale = entries.map(\.key).filter { !allSource.contains($0) }
        XCTAssertTrue(stale.isEmpty,
                      "目录里有 \(stale.count) 条代码中已不存在的键（改了原文没同步目录）：\(stale)")
    }

    // MARK: - 元测试：三条守卫各自的扫描器必须真能抓到坏样例

    func test_scannersDetectInjectedViolations() {
        // 守卫 1 的扫描器：未登记的中文串要能被抓到，注释里的不能算。
        let dirty = [(path: "Views/Fake.swift",
                      content: "  Text(\"尚未翻译的句子\")\n// Text(\"注释里的\")\n")]
        XCTAssertEqual(Self.uiLiteralsNeedingKeys(in: dirty)["Views/Fake.swift"],
                       ["尚未翻译的句子"], "界面串扫描器失灵或没剥注释")

        // 守卫 2/3 的目录解析器：能读键值、能剥块注释与行注释。
        let parsed = Self.parseCatalog("""
        /* 说明里有 "假键" = "假值"; 一行 */
        "真键" = "Real";
        "另一键" = "Second";   // 行尾注释 "噪声" = "噪声值"
        """)
        XCTAssertEqual(parsed.count, 2,
                       "目录解析器数错了条数（\(parsed.map(\.key))）—— 注释没剥干净")
        XCTAssertEqual(parsed.map(\.key), ["真键", "另一键"])
        XCTAssertEqual(parsed.map(\.value), ["Real", "Second"])
        // 空值必须能被数出来（守卫 2 依赖它）
        XCTAssertEqual(Self.parseCatalog("\"k\" = \"\";").first?.value, "")
    }
}
