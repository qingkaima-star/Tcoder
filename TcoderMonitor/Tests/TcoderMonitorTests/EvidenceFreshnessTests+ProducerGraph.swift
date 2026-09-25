import Foundation
import XCTest

/// OWNER: 总工（界面线）—— 逐页实拍依赖面的**第三把尺**：服务生产者图。
///
/// 前两只眼睛在 `EvidenceFreshnessTests+Dependencies.swift`：口径生产者名单（P53）、
/// 「每个 Views 文件都得被某一行罩住」（P67）。那两把都还在吃**手抄名单**——
/// 名单不会自己长大，所以本文件改成从代码图算（#59）。
///
/// 拆成独立文件是被 400 行的 Tests 尺寸线逼的（宿主 226 行 + 本判据 180 行会过线），
/// 一条断言都没删、口径没改。
extension EvidenceFreshnessTests {

    // MARK: - 一跳服务生产者：依赖面从代码图算，不靠手抄（#59）

    /// 呈现侧（`Views`/`Design`/`App`）**直接点名**的 `Services/**` 文件就是那一页数字与
    /// 句子的生产者，表里那一行必须把它列进依赖面。口径与三次复发的账在
    /// `docs/界面-乱的清单.md`（"上屏的那句话由谁产出，那一行就必须列谁"）；这里把它变成机器断言。
    ///
    /// 【射程：只有 `Services/**`，而且只有**一跳**】不追第二跳：现扫噪声是**每行 12 ~ 89 处**，
    /// 那种形状上闸会把所有人的门禁打死（会误报的粗尺不许上闸）。也不列英文目录
    /// （`Resources/en.lproj/**`）：文档明写"故意不列"，那批实拍是中文态像素。
    /// ⚠ 边界备案：Swift 的多行字符串只被部分抹掉 ⇒ 只会**多报**不会漏报。
    static let servicesRoot = sourcePrefix + "Services"

    /// 类型声明，**不含 `extension`**：extension 不算所有者，否则一个类型名映射到多个文件，
    /// "到底是谁生产的"这句话就答不出来。
    static let declarationPattern =
        #"^\s*(?:public |internal |private |fileprivate )?(?:final\s+)?"#
        + #"(?:struct|class|enum|protocol|actor)\s+([A-Z]\w*)"#

    /// "用起来了"＝ `Name.` 或 `Name(`。裸提及不行：名字出现在别人的名字里、
    /// 出现在散文里，都不构成"这页的数字由它生产"。
    static let usagePattern = #"\b([A-Z]\w*)\s*[.(]"#

    static func captured(_ pattern: String, in text: String,
                         _ options: NSRegularExpression.Options = []) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            XCTFail("正则构造失败 ⇒ 这条判据根本没在跑：\(pattern)")
            return []
        }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
    }

    static func blanked(_ text: String, _ pattern: String,
                        _ options: NSRegularExpression.Options = []) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            XCTFail("正则构造失败 ⇒ 这条判据根本没在跑：\(pattern)")
            return text
        }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                              withTemplate: "\"\"")
    }

    /// 抹掉块注释、字符串字面量、行注释（含行尾），剩下的才算"这段代码用到了什么"。
    /// 这一条是噪声的**最大来源**（现扫 12 → 32）：本仓每个函数头上都有一段中文说明。
    /// 顺序要紧：先抹字符串，`//` 切割才不会在 `"https://x"` 那种地方咬错。
    static func codeOnly(_ text: String) -> String {
        let stripped = blanked(blanked(text, blockCommentPattern, [.dotMatchesLineSeparators]),
                               stringLiteralPattern)
        return stripped.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in String(line).components(separatedBy: "//").first ?? "" }
            .joined(separator: "\n")
    }

    static let blockCommentPattern = #"/\*.*?\*/"#
    static let stringLiteralPattern = #""(?:[^\"\n]|\\.)*""#

    static func swiftFiles(under path: String) -> [URL] {
        let url = repoRoot.appendingPathComponent(path)
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
        else { return [] }
        return walker.compactMap { item in (item as? URL)?.pathExtension == "swift" ? item as? URL : nil }
    }

    /// 表里那一格展开成一个个文件（目录递归收 `.swift`）。**路径真的不存在才返回 nil**：
    /// 表里打错一个字就让那一行静默脱离检查，是假绿的第三条腿 ⇒ 读不到必须出声。空目录不算读不到。
    static func sourceFiles(at path: String) -> [String]? {
        let url = repoRoot.appendingPathComponent(path)
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        if !isDirectory.boolValue { return [path] }
        return swiftFiles(under: path)
            .map { String($0.path.dropFirst(repoRoot.path.count + 1)) }.sorted()
    }

    /// 类型名 → 声明它的 `Services/**` 文件（仓库相对路径）。两道门：① 全仓只有一处声明
    /// （歧义名不进图，否则"谁生产的"答不出来）；② 那一处就在 `Services` 下。
    static func serviceProducers() -> [String: String] {
        var holders: [String: Set<String>] = [:]
        for url in swiftFiles(under: sourcePrefix) {
            let relative = String(url.path.dropFirst(repoRoot.path.count + 1))
            let body = codeOnly((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            for name in captured(declarationPattern, in: body, [.anchorsMatchLines]) {
                holders[name, default: []].insert(relative)
            }
        }
        return holders.reduce(into: [:]) { index, entry in
            guard entry.value.count == 1, let only = entry.value.first,
                  only == servicesRoot || only.hasPrefix(servicesRoot + "/") else { return }
            index[entry.key] = only
        }
    }

    /// 一行缺列哪几个服务生产者。`index`／`expand`／`read` 全部注入，元测试才不碰真文件。
    static func missingServiceProducers(
        for row: Row, index: [String: String],
        expand: (String) -> [String]?, read: (String) -> String?
    ) -> [String] {
        let page = row.pages.joined(separator: "/")
        let listed = Set(row.paths)
        var offenders: [String] = []
        var reported: Set<String> = []
        // 只有呈现侧那一格算"用到"（`Services→Services` 是第二跳，见上面"射程"）。
        for cell in row.paths where cell != servicesRoot && !cell.hasPrefix(servicesRoot + "/") {
            guard let files = expand(cell) else {
                offenders.append("\(page) → 表里点名的路径读不到：\(cell)")
                continue
            }
            for file in files {
                guard let text = read(file) else { continue }
                for type in captured(usagePattern, in: codeOnly(text)).sorted() {
                    guard let producer = index[type], reported.insert(producer).inserted,
                          !listed.contains(where: { covers($0, producer) }) else { continue }
                    offenders.append("\(page) 的 \(file) 用到了 \(type)，那一行却没列 \(producer)")
                }
            }
        }
        return offenders
    }

    func test_everyRowListsTheServicesItsOwnFilesCallInto() throws {
        let url = Self.repoRoot.appendingPathComponent(Self.catalogPath)
        let found = Self.rows(in: try String(contentsOf: url, encoding: .utf8))
        XCTAssertFalse(found.isEmpty, "表里一行都没有 ⇒ 这条判据在空转")
        let index = Self.serviceProducers()
        XCTAssertFalse(index.isEmpty,
                       "服务生产者图为空 ⇒ 下面所有『缺列 0 处』都不成立，先修尺子再看读数")
        let offenders = found.flatMap {
            Self.missingServiceProducers(for: $0, index: index,
                                         expand: { Self.sourceFiles(at: $0) },
                                         read: { Self.code(at: $0) })
        }
        XCTAssertTrue(offenders.isEmpty,
                      "这些行漏列了自己用到的服务生产者（改了那个文件，那一页不会判红）：\n"
                        + offenders.joined(separator: "\n"))
        print("【依赖面完整性·一跳】表里 \(found.count) 行 × 图里 \(index.count) 个服务类型"
            + " → 缺列 \(offenders.count) 处")
    }

    /// 双向元测试（合成输入，不碰真仓库）：漏列要抓到；列全（含目录级写法）、
    /// 第二跳、只在注释里提到都不许咬。
    func test_meta_serviceProducerRulerIsTwoSided() {
        let root = Self.servicesRoot
        let scale = root + "/Code/Scale.swift"
        let helper = root + "/Util/Helper.swift"
        let page = "Views/Page.swift"
        let index = ["Scale": scale, "Helper": helper]
        let files: [String: String] = [page: "Text(Scale.reading(x))  // 顺便提到 Helper"]
        let read: (String) -> String? = { files[$0] }
        let expand: (String) -> [String]? = { [$0] }
        let row = Row(pages: ["健康评分"], batch: "b", head: "abc1234", paths: [page])
        XCTAssertEqual(Self.missingServiceProducers(for: row, index: index, expand: expand, read: read),
                       ["健康评分 的 \(page) 用到了 Scale，那一行却没列 \(scale)"],
                       "只该报真用到的那一个；注释里提的 Helper 不算")

        // 同一句使用换个性别就两种结局：在 `Services` 里 ⇒ 第二跳，不算；
        // 在呈现侧 ⇒ 必须算。目录级「已覆盖」由 `covers` 那条元测试钉，这里不重复口径。
        let helperBody = "struct Helper { let n = Scale.x }"
        let hopFiles: [String: String] = ["Views/Clean.swift": "let n = 0", helper: helperBody,
                                          "Views/HelperCopy.swift": helperBody]
        let hopRead: (String) -> String? = { hopFiles[$0] }
        let hopExpand: (String) -> [String]? = { $0 == root + "/Util" ? [helper] : [$0] }
        let inServices = Row(pages: ["总览"], batch: "b", head: "1",
                             paths: ["Views/Clean.swift", root + "/Util"])
        XCTAssertTrue(Self.missingServiceProducers(for: inServices, index: index, expand: hopExpand,
                                                   read: hopRead).isEmpty,
                      "把 `Services→Services` 算进依赖面 ⇒ 每行都红，那把尺子上不了闸")
        let onPage = Row(pages: ["总览"], batch: "b", head: "1",
                         paths: ["Views/Clean.swift", "Views/HelperCopy.swift"])
        XCTAssertEqual(Self.missingServiceProducers(for: onPage, index: index, expand: hopExpand,
                                                    read: hopRead),
                       ["总览 的 Views/HelperCopy.swift 用到了 Scale，那一行却没列 \(scale)"],
                       "同一句使用搬到呈现侧却不报 ⇒ 这条「只算一跳」会把会漏报的尺子当成好尺子")

        XCTAssertEqual(Self.codeOnly("let u = \"https://x/y\"\n/// Helper.y\nlet z = Scale.x"),
                       "let u = \"\"\n\nlet z = Scale.x",
                       "字符串与行注释都要抹掉，真代码要留着")
        XCTAssertNotNil(Self.sourceFiles(at: root + "/Code"), "真实目录必须读得出来")
        XCTAssertNil(Self.sourceFiles(at: root + "/不存在的那一片"), "读不到要出声，不许当成空目录通过")
    }
}
