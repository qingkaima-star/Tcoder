import Foundation
import XCTest

/// OWNER: 总工（界面线）—— 从 `EvidenceFreshnessTests` 拆出来的**依赖面完整性**判据。
///
/// 主文件管的是"那一格的实拍有没有过期"，本文件管的是**更前一步**的问题：
/// 一行列出的依赖面，**是不是那一页真正用到的东西**。
/// 漏列的后果不是报错，是**永远不报错**：改了没被列进来的生产者，
/// 屏上换了句话，而新鲜度判据看着"这页的文件没动"照样绿。
///
/// 拆文件是 400 行的 Tests 尺寸线逼的（主文件 291 行，加完这两条判据过线），
/// 一条断言都没删。
extension EvidenceFreshnessTests {

    // MARK: - 口径生产者（P53）

    /// **口径生产者**：自己不画任何卡，但别的页面**上屏的那句话**是它拼出来的。
    /// 这类文件是"我这页没动"这种假绿的唯一入口 —— P53 就是踩着它复发的：
    /// `GitHistoryScope` 供着 Git 洞察的口径条、贡献者两枚磁贴的副标题、总览 hero 的 ⓘ，
    /// 而表里那三行都没有列它（Git 洞察那一行当时是**靠同批别的文件也被改了**才判红的 ——
    /// 只改生产者时三页一起假绿）。
    ///
    /// 名单要小而准：只登记**跨页供句**的生产者。把普通共用组件也塞进来，
    /// 每一行都会因为一点基座改动而要求重拍九页，最后没人愿意维护这张表。
    static let caliberProducers: [(file: String, type: String)] = [
        ("TcoderMonitor/Sources/TcoderMonitor/Views/CodeGit/GitHistoryScope.swift",
         "GitHistoryScope"),
        // P57：健康页那本供的不只是健康页。维度名（`DimensionDisplay.name`）被插进多条整句，
        // 而**总览 hero 也在读这些整句** —— 词汇层动一行，健康页之外的格子也会变。
        // 名单加一条，就让判据自己去点名哪些行漏了它，而不是等下一次改文案时撞红。
        ("TcoderMonitor/Sources/TcoderMonitor/Services/Health/HealthBreakdown.swift",
         "DimensionDisplay"),
    ]

    /// 类型名的词界匹配：`GitHistoryScope` 不许被 `GitHistoryScopeTests` 那种邻居蒙住 ——
    /// 词界丢了就是"看见却没引用"的反面：把邻居的引用算到自己头上，到处误报。
    static func references(_ type: String, in code: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: "\\b" + type + "\\b") else {
            XCTFail("正则构造失败 ⇒ 这条判据根本没在跑")
            return false
        }
        let range = NSRange(code.startIndex..., in: code)
        return regex.firstMatch(in: code, range: range) != nil
    }

    /// 一行缺哪几列。`read` 注入进来，元测试才能不碰真文件测这个函数。
    ///
    /// **读不到也算一条**：路径写错的时候，"这一行没引用生产者"与"这一行点名的文件根本不存在"
    /// 必须可分辨 —— 否则表里打错一个字，那一行就静默脱离检查（假绿的第三条腿）。
    static func missingProducerColumns(
        for row: Row,
        producers: [(file: String, type: String)],
        read: (String) -> String?
    ) -> [String] {
        let page = row.pages.joined(separator: "/")
        var unreadable: [String] = []
        var code = ""
        for path in row.paths {
            guard let text = read(path) else {
                unreadable.append("\(page) → 表里点名的路径读不到：\(path)")
                continue
            }
            code += text + "\n"
        }
        guard unreadable.isEmpty else { return unreadable }
        let listed = Set(row.paths)
        return producers.compactMap { producer in
            guard !listed.contains(producer.file),
                  references(producer.type, in: code) else { return nil }
            return "\(page) 的页内文件引用了 \(producer.type)，那一行却没列 \(producer.file)"
        }
    }

    /// 表里既有"一个文件"的写法，也有"整片目录"的写法（`Views/Performance` 这种，
    /// `git log -- <目录>` 合法）。两种都要读成代码：目录按 `.swift` 递归收，
    /// **路径真的不存在才返回 nil** —— 把目录当"读不到"会误报六行，尺子立刻就没人信了。
    static func code(at path: String) -> String? {
        let url = repoRoot.appendingPathComponent(path)
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        if !isDirectory.boolValue {
            return try? String(contentsOf: url, encoding: .utf8)
        }
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
        else { return "" }
        return walker.compactMap { item -> String? in
            guard let file = item as? URL, file.pathExtension == "swift" else { return nil }
            return try? String(contentsOf: file, encoding: .utf8)
        }.joined(separator: "\n")
    }

    func test_everyRowListsTheCaliberProducersItsOwnFilesReference() throws {
        let url = Self.repoRoot.appendingPathComponent(Self.catalogPath)
        let found = Self.rows(in: try String(contentsOf: url, encoding: .utf8))
        XCTAssertFalse(found.isEmpty, "表里一行都没有 ⇒ 这条判据在空转")
        let offenders = found.flatMap {
            Self.missingProducerColumns(for: $0, producers: Self.caliberProducers,
                                        read: { Self.code(at: $0) })
        }
        XCTAssertTrue(offenders.isEmpty,
                      "这些行的依赖面漏了它真正用到的口径生产者（改了生产者，那一页不会判红）：\n"
                    + offenders.joined(separator: "\n"))

        // 名单自己也要被反着钉一次：名单里的生产者如果在整张表点名的文件里都不再出现，
        // 说明它已被拆掉或改名，而名单还在假装管事 —— 那是"清单不自动长大"的反面。
        let allCode = found.flatMap(\.paths).compactMap { Self.code(at: $0) }.joined(separator: "\n")
        let idle = Self.caliberProducers.map(\.type).filter { !Self.references($0, in: allCode) }
        XCTAssertTrue(idle.isEmpty,
                      "口径生产者名单里这些类型在表点名的文件里已经不出现了（该删还是改名了？）：\(idle)")
        print("【依赖面完整性】表里 \(found.count) 行 × 名单 \(Self.caliberProducers.count) 个生产者"
            + " → 缺列 \(offenders.count) 处")
    }

    /// 双向元测试：引用了没列必须抓到；列全了、没引用都不许乱咬；
    /// 路径写错（读不到）要报，**不许退化成"没引用"**。
    func test_producerColumnRulerCatchesMissingColumnsAndSparesCompleteRows() {
        let producer = (file: "Views/CodeGit/Producer.swift", type: "Producer")
        let files: [String: String] = [
            "Views/Git/Page.swift": "let line = Producer(scope).headline",
            "Views/CodeGit/Producer.swift": "struct Producer { var headline: String { \"\" } }",
            "Views/Git/Neighbour.swift": "let t = ProducerTests()",
        ]
        let read: (String) -> String? = { files[$0] }
        let row = Row(pages: ["Git 洞察"], batch: "b", head: "abc1234", paths: ["Views/Git/Page.swift"])
        let caught = Self.missingProducerColumns(for: row, producers: [producer], read: read)
        XCTAssertEqual(caught.count, 1, "引用了生产者却没列它 ⇒ 必须报：\(caught)")
        XCTAssertTrue(caught[0].contains("Producer.swift"), "报的要指得到缺的那个文件：\(caught)")

        let complete = Row(pages: ["Git 洞察"], batch: "b", head: "abc1234",
                           paths: ["Views/Git/Page.swift", "Views/CodeGit/Producer.swift"])
        XCTAssertTrue(Self.missingProducerColumns(for: complete, producers: [producer], read: read).isEmpty,
                      "列全了还报 ⇒ 下次没人信这张表")
        let unrelated = Row(pages: ["代码规模"], batch: "b", head: "abc1234",
                            paths: ["Views/Git/Neighbour.swift"])
        XCTAssertTrue(Self.missingProducerColumns(for: unrelated, producers: [producer], read: read).isEmpty,
                      "`ProducerTests` 不是 `Producer`：词界没守住就会到处误报")

        let typo = Row(pages: ["Git 洞察"], batch: "b", head: "abc1234", paths: ["Views/Git/Pge.swift"])
        let unreadable = Self.missingProducerColumns(for: typo, producers: [producer], read: read)
        XCTAssertEqual(unreadable.count, 1, "路径读不到必须报，不许当成\"没引用\"放过：\(unreadable)")
        XCTAssertTrue(unreadable[0].contains("读不到"), "报的得说清是读不到：\(unreadable)")
    }
}
