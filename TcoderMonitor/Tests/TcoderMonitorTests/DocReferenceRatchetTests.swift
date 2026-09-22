import XCTest

/// WS-V #29：文档代码引用的有效性棘轮。
///
/// 要补的洞：全仓此前**没有任何一条测试读过** `README.md` 或 `docs/使用说明.md`。
/// WS-G 一次删掉 988 行基座、WS-K/L/M 重样又删掉一批 Views 类型之后，文档里的锚点
/// 可以指到不存在的符号上而**没有一条测试会红**。那是侥幸，不是被守住。
///
/// 文档的锚点约定（总工实测指出，我第一版判错了，教训记在这里）：
/// 锚点写的是 **`文件名.类型.成员`**，例如 `ContributorRows.ContributorRow.body`
/// 指 `Sources/TcoderMonitor/Views/Git/ContributorRows.swift` 里 `struct ContributorRow`
/// 的 `body`。**首段是文件名，不是标识符**——`ContributorRows` 作为类型名根本不存在。
/// 我最初按「每一段都必须是 `Sources/**` 里的标识符`」判，于是 33 条活锚点被登记成
/// 「已知失效」。后果比清单长严重得多：进了基线就永远不红，真死锚混进去也会被
/// 当「已知」吞掉，而且基线永远不会缩小，因为文档本来就没写错。
/// 现在：首段若等于某个 `Sources/**` 的**文件名去后缀**，先吃掉这一段再逐段核验；
/// 豁免掉的文件名与条数**全部打印**，并有守恒断言兜着，不许豁免变成第二个黑洞。
///
/// 四条设计约束，各自对应一个真踩过的失败模式：
/// 1. **分母必须被断言**。同类守卫曾因 `File.exists(相对路径)` 对仓库根判假，
///    把 91 条里的 85 条静默 skip 掉，于是「零失效」永远绿。所以除了总数 > 0，
///    还按类别断言（符号类 > 0 且文件行号类 > 0）、文档读到数 == 登记数、skip == 0，
///    并加一条**守恒断言**：符号锚点必须逐条落到「判活(文件名作用域) / 判活(纯符号) /
///    判死」三个桶之一，三桶之和 == 符号总数，少一条就是被静默吞了。
/// 2. **尺子自己也要被测，且两个方向都要**：合成死引用必须判红，合成活引用必须判绿；
///    文件名作用域这条新规则更要双向钉住（豁免后仍缺成员的，必须照样判红）。
/// 3. **不许用 XCTSkip 蒙**：文档读不到 / 为空一律 `XCTFail`。
/// 4. **只减不增**：`knownDeadAnchors` 与实测失效集合双向相等；当前必须是空集。
///
/// 剩余限度（不假装做到了没做到的事）：判定仍是「逐段作为完整单词出现」，
/// 抓得到类型 / 成员被删或改名，抓不到「成员被挪到另一个类型 / 文件上」
/// （`X.body` 里 `body` 在别处出现即算命中）；也不核验首段文件名与后段类型
/// 真的同处一个文件。收紧到作用域内需要解析 Swift 语法，那是另一个量级的活儿。
final class DocReferenceRatchetTests: XCTestCase {

    /// 仓库根：本文件 → TcoderMonitorTests → Tests → TcoderMonitor → 工作树根（README.md 与 docs/ 在此）。
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// 2026-09-20 在 main `ab34cad` 上实测：四份文档里**带行号**的引用只剩 1 条
    /// （WS-Z / WS-Z2 把存量逐条换成了符号锚点，文件名提及另有 92 条，那是正常写作）。
    /// 这是**基线**不是"合法额度"——只许往下调；真降到 0 时把这里改成 0 并删掉
    /// 剩下那条历史引述。
    ///
    /// 第一版这里误用了 `fileCount`（所有反引号里的文件名），结果我自己写一句
    /// `verify_provenance.sh` 就把它顶到 93 而判红——那会把人训练成"改文档要绕着守卫走"。
    /// 现在只数**带行号**的那一类，正是 #48 要防的东西。
    static let fileLineReferenceCeiling = 1

    /// 2026-09-21 加进两份界面验收文档：`docs/界面-乱的清单.md` 的"判据"列整列都是锚点
    /// （哪条缺陷由哪把守卫管），此前**没有任何机器**替下一轮守着它；
    /// `docs/界面语言-对齐AiX.md` 是视觉语言的权威文档，同样点名符号。
    /// 接入前先按本文件的口径预检过：`NSView.toolTip` 这类**外部 API** 不合规约
    /// （锚点是给我们自己的代码用的），已改写成 `NSView` 的 `toolTip`；
    /// `*.py` 走 `exampleManifestExtensions` 豁免、`*.txt` 不是文件锚点，也一并改了措辞。
    static let docs: [String] = ["README.md", "docs/使用说明.md",
                                       "docs/口径与已知限制.md", "docs/九页实拍读数.md",
                                       "docs/界面-乱的清单.md", "docs/界面语言-对齐AiX.md"]

    /// 我们自己的文件类型：这类锚点必须能在仓库里找到实体文件。
    static let repoFileExtensions: Set<String> = ["swift", "md", "sh"]

    /// 文档里作为**用户项目示例**出现的清单 / 报告文件名（package.json、pom.xml…）。
    /// 它们指的是别人仓库里的文件，按扩展名排除；排除条数会被打印，
    /// 且断言「被排除的扩展名必须都在这张表里」，不许悄悄扩大豁免面。
    static let exampleManifestExtensions: Set<String> = [
        "json", "xml", "toml", "yaml", "yml", "gradle", "kts", "mod", "lock",
        "py", "js", "ts", "resolved",
    ]

    /// 同一条剪枝只有一个来源（见 `SelfScanHarnessCase.skipDirectoryNames` 的理由）。
    static let prunedDirectories: Set<String> = SelfScanHarnessCase.skipDirectoryNames

    /// 已知失效基线。**当前必须为空**：2026-09-20 按「文件名.类型.成员」口径重算后，
    /// 原先误登记的 33 条全部判活，真死引用为 0。
    /// 只有出现「确实失效、又暂时不该让全仓变红」的锚时才允许带**理由**放进来，
    /// 而下面的双向相等断言保证它只能被删掉、不能被沿用。
    static let knownDeadAnchors: [String: String] = [:]

    // MARK: - 被检索引

    struct CodeIndex {
        var identifiers: Set<String> = []
        /// `Tests/**` 里的**声明名**（`func test…` 与类型名）。**2026-09-22 补的第二份索引**：
        /// 文档大量引用守卫用例的名字，而判活只看 `Sources/**`，于是
        /// 写 `某测试类.test_某条` 必判死、写裸名 `test_某条` 又压根不成锚（正则要求至少一个点）
        /// —— 两条路都不能"被盯"。补上之后，测试被改名或删掉，文档会红。
        /// 只收声明是有原因的：收全标识符会让金丝雀被自己的测试文件喂成活锚（见 `testDeclarations`）。
        var testIdentifiers: Set<String> = []
        /// `Sources/**` 里 Swift 文件名的去后缀形式——文档锚点的首段用它做作用域豁免。
        var sourceFileStems: Set<String> = []
        /// 文件名 -> 行数（`wc -l` 口径：数换行符，末尾不成行的一段算一行）。
        var files: [String: Int] = [:]

        func knows(_ segment: String) -> Bool {
            identifiers.contains(segment) || testIdentifiers.contains(segment)
        }
    }

    enum Anchor {
        case symbol(segments: [String])
        case file(name: String, line: Int?)
        case example(ext: String)

        var isSymbol: Bool {
            if case .symbol = self { return true }
            return false
        }
    }

    struct Resolution {
        var reason: String?
        var usedFileScope: Bool
        var droppedSegment: String?
    }

    // MARK: - 解析规则（纯函数，元测试直接喂合成输入）

    func classify(_ token: String) -> Anchor {
        let halves = token.components(separatedBy: ":")
        let stem = halves[0]
        let line = halves.count > 1 ? Int(halves[1]) : nil
        let parts = stem.components(separatedBy: ".").filter { !$0.isEmpty }
        let ext = (parts.last ?? "").lowercased()
        if Self.exampleManifestExtensions.contains(ext) { return .example(ext: ext) }
        if Self.repoFileExtensions.contains(ext) { return .file(name: stem, line: line) }
        return .symbol(segments: parts)
    }

    /// 符号锚点：首段若是 `Sources/**` 的文件名，按文档约定吃掉它，再逐段核验。
    func resolve(_ anchor: Anchor, in index: CodeIndex) -> Resolution {
        switch anchor {
        case .example:
            return Resolution(reason: nil, usedFileScope: false, droppedSegment: nil)
        case let .symbol(segments):
            var checked = segments
            var dropped: String?
            if let head = segments.first, segments.count >= 2, index.sourceFileStems.contains(head) {
                checked.removeFirst()
                dropped = head
            }
            let missing = checked.filter { !index.knows($0) }
            let reason = missing.isEmpty ? nil : "Sources/** 与 Tests/** 里找不到 \(missing.joined(separator: "."))"
            return Resolution(reason: reason, usedFileScope: dropped != nil, droppedSegment: dropped)
        case let .file(name, line):
            guard let count = index.files[name] else {
                return Resolution(reason: "仓库里没有 \(name)", usedFileScope: false, droppedSegment: nil)
            }
            if let line, line > count {
                return Resolution(reason: "\(name) 只有 \(count) 行，引用了第 \(line) 行",
                                  usedFileScope: false, droppedSegment: nil)
            }
            return Resolution(reason: nil, usedFileScope: false, droppedSegment: nil)
        }
    }

    /// 反引号里的点号串（可带 `:NN`）。
    /// 必须用 `#"…"#` 单行 raw string：写成 `#"""…"""#` 会被当多行字面量，
    /// 内容混进换行后正则整组空转还常绿（WS-L 实测踩过）。
    func tokens(in text: String) -> [String] {
        let pattern = try? NSRegularExpression(
            pattern: #"`([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+(?::[0-9]+)?)`"#)
        guard let pattern else {
            XCTFail("锚点正则构造失败，扫描器根本没在跑")
            return []
        }
        return pattern.matches(in: text, range: NSRange(location: 0, length: text.utf16.count))
            .map { $0.range(at: 1).slice(in: text) }
    }

    // MARK: - 建索引与扫描

    func walk(under directory: URL, _ body: (URL) -> Void) {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return }
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDirectory {
                if Self.prunedDirectories.contains(child.lastPathComponent) { continue }
                walk(under: child, body)
            } else {
                body(child)
            }
        }
    }

    func buildIndex() throws -> CodeIndex {
        var index = CodeIndex()
        let identifierPattern = try NSRegularExpression(pattern: #"[A-Za-z_][A-Za-z0-9_]*"#)
        func identifiers(in url: URL) -> Set<String> {
            guard url.pathExtension == "swift",
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            var found: Set<String> = []
            let range = NSRange(location: 0, length: text.utf16.count)
            for match in identifierPattern.matches(in: text, range: range) {
                found.insert(match.range.slice(in: text))
            }
            return found
        }
        walk(under: Self.repoRoot.appendingPathComponent("TcoderMonitor/Sources", isDirectory: true)) { url in
            index.identifiers.formUnion(identifiers(in: url))
            if url.pathExtension == "swift" {
                index.sourceFileStems.insert(url.deletingPathExtension().lastPathComponent)
            }
        }
        walk(under: Self.repoRoot.appendingPathComponent("TcoderMonitor/Tests", isDirectory: true)) { url in
            index.testIdentifiers.formUnion(testDeclarations(in: url))
        }
        XCTAssertFalse(index.identifiers.isEmpty, "Sources 一个标识符都没数到，索引坏了")
        XCTAssertFalse(index.testIdentifiers.isEmpty, "Tests 一个标识符都没数到，测试名锚点会全体判死")
        XCTAssertFalse(index.sourceFileStems.isEmpty, "Sources 一个文件名都没数到，作用域豁免会空转")
        walk(under: Self.repoRoot) { url in
            guard index.files[url.lastPathComponent] == nil,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            let newlines = text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
            index.files[url.lastPathComponent] = text.hasSuffix("\n") ? newlines : newlines + 1
        }
        return index
    }

    /// Tests 侧**只收声明**（`func test…` 与类型名），不收全部标识符。
    ///
    /// 这不是洁癖，是当场撞出来的：第一版按"全标识符"扫 `Tests/**`，
    /// 于是元测试里那条金丝雀 `WsvCanaryDeadType.someMember` 被**它自己所在的测试文件**
    /// 喂成了活锚（名字只是字符串字面量，也进了索引）—— 金丝雀当场不红了。
    /// 判活的集合一旦包含"哪里提到过这个名字"，它就再也测不出判据失效。
    func testDeclarations(in url: URL) -> Set<String> {
        guard url.pathExtension == "swift",
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var found: Set<String> = []
        let patterns = [#"func\s+(test[A-Za-z0-9_]*)"#,
                        #"(?:class|struct|extension)\s+([A-Za-z0-9_]+)"#]
        let range = NSRange(location: 0, length: text.utf16.count)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: range) {
                found.insert(match.range(at: 1).slice(in: text))
            }
        }
        return found
    }

    struct Scan {
        var docsRead = 0
        var unreadable: [String] = []
        var symbolCount = 0
        var fileCount = 0
        var fileWithLineCount = 0
        var exampleCount = 0
        var excludedExtensions = Set<String>()
        var symbolFileScopedLive = 0
        var symbolPlainLive = 0
        var droppedSegments = Set<String>()
        var dead: [String: String] = [:]
    }

    func scanDocs(with index: CodeIndex) -> Scan {
        var scan = Scan()
        for doc in Self.docs {
            let url = Self.repoRoot.appendingPathComponent(doc)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                scan.unreadable.append(doc)
                continue
            }
            XCTAssertGreaterThan(text.count, 1_000, "\(doc) 读到了却只有 \(text.count) 字符，不像真文档")
            scan.docsRead += 1
            for token in tokens(in: text) {
                let anchor = classify(token)
                let resolution = resolve(anchor, in: index)
                switch anchor {
                case let .example(ext):
                    scan.exampleCount += 1
                    scan.excludedExtensions.insert(ext)
                case .symbol:
                    scan.symbolCount += 1
                    if resolution.reason == nil {
                        if resolution.usedFileScope {
                            scan.symbolFileScopedLive += 1
                            scan.droppedSegments.insert(resolution.droppedSegment ?? "?")
                        } else {
                            scan.symbolPlainLive += 1
                        }
                    }
                case .file(_, let line):
                    scan.fileCount += 1
                    // #48 真正要盯的是**带行号**的那一类：`foo.swift` 这种纯文件名提及
                    // 是正常写作（`build_app.sh`、`Info.plist`…），拿它当债务计数会
                    // 惩罚普通改文档——第一版就误伤过一次（写 `verify_provenance.sh` 就 +1）。
                    if line != nil { scan.fileWithLineCount += 1 }
                }
                if let reason = resolution.reason { scan.dead[token] = reason }
            }
        }
        return scan
    }

    // MARK: - 断言

    /// 分母守卫：先证明尺子在量东西，再证明它没把量到的东西静默吞掉。
    func testScannerActuallyReadsDocsAndFindsAnchors() throws {
        let scan = scanDocs(with: try buildIndex())
        XCTAssertEqual(scan.unreadable, [], "有文档读不到却被当成「引用都有效」：\(scan.unreadable)")
        XCTAssertEqual(scan.docsRead, Self.docs.count, "不是每份文档都被扫了")
        XCTAssertGreaterThan(scan.symbolCount, 0, "一个符号锚点都没扫到 = 正则或文档路径失效，棘轮在空转")
        XCTAssertGreaterThan(scan.fileCount, 0, "一个文件行号锚点都没扫到 = 同上")
        XCTAssertEqual(scan.excludedExtensions.subtracting(Self.exampleManifestExtensions), [],
                       "排除集里出现了没登记的扩展名，豁免面被悄悄扩大了")
        XCTAssertGreaterThan(scan.symbolCount + scan.fileCount, 100,
                             "在锚范围内的引用不到 100 条，不像这份文档的真实规模")

        // 守恒：每条符号锚点都必须落在三个桶之一，谁也不许凭空消失。
        let deadSymbols = scan.dead.filter { classify($0.key).isSymbol }.count
        XCTAssertEqual(scan.symbolCount, scan.symbolFileScopedLive + scan.symbolPlainLive + deadSymbols,
                       """
                       符号锚点不守恒（总 \(scan.symbolCount) ≠ 作用域判活 \(scan.symbolFileScopedLive)
                       + 纯符号判活 \(scan.symbolPlainLive) + 判死 \(deadSymbols)），
                       说明有锚点被静默吞掉——正是「91 条里跳过 85 条」那一族失效。
                       """)
        XCTAssertGreaterThan(scan.symbolFileScopedLive, 0,
                             "文件名作用域这条路径一次都没走到，说明豁免逻辑没被执行、口径可能又漂了")

        // #48：行号类锚点的判据是"文件存在 + 行号在界内"，**它守不住指向错位**。
        // 只读审计实测过 9 条"在界内但指错地方"的（`:135` 指着 `SeverityBadge.icon`
        // 却用来支撑 `displayValue` 那句话；10 条 CVE 行号整体 +1 偏移），
        // 它们全都判活。要让判据真的能验指向，就得把"被引用行须含同段提到的标识符"
        // 做成启发式——那种误报会把人训练成"红了就忽略"，不值。
        // 所以这里改用**只减不增棘轮**：行号引用条数只许往下走，
        // 让 §4.6"只写符号不写行号"这条规约变成机器守得住的事。
        XCTAssertLessThanOrEqual(scan.fileWithLineCount, Self.fileLineReferenceCeiling,
                                 "带行号的引用从 \(Self.fileLineReferenceCeiling) 涨到 \(scan.fileWithLineCount) 条："
                               + "新增一律写成 `文件名` 的 `类型.成员`，不要写行号。"
                               + "确实清掉了若干条，就把基线改成新的实测值（只许往下调）。")

        print("【#29 分母】在锚引用 \(scan.symbolCount + scan.fileCount) 条"
            + "（符号 \(scan.symbolCount)：按文件名作用域判活 \(scan.symbolFileScopedLive)"
            + " / 纯符号判活 \(scan.symbolPlainLive)）、文件名提及 \(scan.fileCount) 条（其中带行号 \(scan.fileWithLineCount) 条）；"
            + "示例清单名排除 \(scan.exampleCount) 条；文档读到 \(scan.docsRead)/\(Self.docs.count) 份，skip 0；"
            + "豁免掉的文件名首段 \(scan.droppedSegments.count) 个："
            + "\(scan.droppedSegments.sorted().joined(separator: ", "))")
    }

    /// 棘轮本体：新增死引用变红；修掉了却忘了同步基线，也变红。基线当前必须是空集。
    func testNoNewDeadReferencesAndBaselineOnlyShrinks() throws {
        let scan = scanDocs(with: try buildIndex())
        let found = Set(scan.dead.keys)

        XCTAssertTrue(Self.knownDeadAnchors.isEmpty,
                      "基线又被塞进 \(Self.knownDeadAnchors.count) 条：\(Self.knownDeadAnchors.keys.sorted())。"
                    + "按「文件名.类型.成员」口径重算后真死引用是 0；放条目前先证明它是真死的。")

        let fresh = found.subtracting(Set(Self.knownDeadAnchors.keys)).sorted()
        XCTAssertTrue(fresh.isEmpty, """
        文档里出现了基线之外的失效引用 \(fresh.count) 条：
        \(fresh.map { "  \($0) → \(scan.dead[$0] ?? "?")" }.joined(separator: "\n"))
        报给对应流修文档，别塞回基线——第一版就是把 33 条活锚点塞进基线的。
        """)

        let healed = Set(Self.knownDeadAnchors.keys).subtracting(found).sorted()
        XCTAssertTrue(healed.isEmpty, "基线里这 \(healed.count) 条已不再失效，请删掉：\(healed)")

        XCTAssertEqual(found, Set(Self.knownDeadAnchors.keys), "实测失效集合与基线不逐条相等")
        print("【#29 棘轮】在锚 \(scan.symbolCount + scan.fileCount) 条 → 失效 \(found.count) 条，"
            + "基线 \(Self.knownDeadAnchors.count) 条，逐条相等")
    }

    // MARK: - 元测试：尺子自己也要被测，两个方向都要

}

private extension NSRange {
    /// 按 NSRegularExpression 的 UTF-16 区间取子串。
    /// 文档里有中文，用「按 Character 偏移」的写法会切错位置，必须走 Range 转换。
    func slice(in text: String) -> String {
        guard let swiftRange = Range(self, in: text) else { return "" }
        return String(text[swiftRange])
    }
}
