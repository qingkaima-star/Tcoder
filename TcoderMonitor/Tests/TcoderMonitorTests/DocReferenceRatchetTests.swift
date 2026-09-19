import XCTest

/// WS-V #29：文档代码引用的有效性棘轮。
///
/// 要补的洞：全仓此前**没有任何一条测试读过** `README.md` 或 `docs/使用说明.md`。
/// WS-G 一次删掉 988 行基座、WS-K/L/M 重样又删掉一批 Views 类型之后，文档里的
/// `SectionNav.DetailSection` 这类锚点已经指到不存在的符号上，而**没有一条测试会红**。
/// 那是侥幸，不是被守住。
///
/// 四条设计约束，各自对应一个真踩过的失败模式：
/// 1. **分母必须被断言**。同类守卫曾因 `File.exists(相对路径)` 对仓库根判假，
///    把 91 条里的 85 条静默 skip 掉，于是「零失效」永远绿。所以这里不仅断言总数 > 0，
///    还按类别断言（符号锚点 > 0 且文件行号锚点 > 0），并断言两份文档都真被读到且非空。
/// 2. **尺子自己也要被测**：喂合成死引用必须判红，喂合成活引用必须判绿——
///    单向元测试会把「逢报必红」也当成守卫生效。
/// 3. **不许用 XCTSkip 蒙**：文档读不到/为空一律 `XCTFail`，skip 数断言为 0。
/// 4. **只减不增**：见 `knownDeadAnchors`。
///
/// 判定口径与它的限度（不假装做到了没做到的事）：`Type.member` 的**每一段**都必须作为
/// 完整单词出现在 `Sources/**` 的标识符集合里。这能抓到「类型被删/改名」和「成员被删/改名」，
/// 抓不到「成员被挪到另一个类型上」（`X.body` 里 `body` 在别处出现就算命中）。
/// 收紧到「同一类型作用域内」需要真的解析 Swift 语法，那是另一个量级的活儿。
final class DocReferenceRatchetTests: XCTestCase {

    /// 仓库根：本文件 → TcoderMonitorTests → Tests → TcoderMonitor → 工作树根（README.md 与 docs/ 在此）。
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let docs: [String] = ["README.md", "docs/使用说明.md"]

    /// 我们自己的文件类型：这类锚点必须能在仓库里找到实体文件。
    private static let repoFileExtensions: Set<String> = ["swift", "md", "sh"]

    /// 文档里作为**用户项目示例**出现的清单/报告文件名（package.json、pom.xml…）。
    /// 它们指的是别人仓库里的文件，按扩展名排除；排除条数会被打印，
    /// 且断言「被排除的扩展名必须都在这张表里」，不许悄悄扩大豁免面。
    private static let exampleManifestExtensions: Set<String> = [
        "json", "xml", "toml", "yaml", "yml", "gradle", "kts", "mod", "lock",
        "py", "js", "ts", "resolved",
    ]

    private static let prunedDirectories: Set<String> = [
        ".git", ".build", ".swiftpm", ".worktrees", "node_modules", "DerivedData",
        "dist", "build", "out",
    ]

    /// 已知失效基线（2026-09-20 实测：WS-K/L/M 重样 + WS-G 删基座的后果）。
    /// 这是**只减不增**的棘轮：新死引用立刻变红；修好一条却忘了从基线删掉，也变红。
    /// 两个方向都钉，基线就不可能退化成藏污纳垢的白名单。
    private static let knownDeadAnchors: Set<String> = [
        "CodeGitTable.DataColumns.complexityFunctions",
        "CodeRiskRows.CodeRiskAnalysis.suggestions",
        "ContributorRows.ContributorAnalysis.busFactorRisk",
        "ContributorRows.ContributorAnalysis.displayName",
        "ContributorRows.ContributorAnalysis.sorted",
        "ContributorRows.ContributorRow.body",
        "DashboardHero.HealthHeroCard.body",
        "DashboardHero.HealthRing",
        "DependencyVerdictRows.DependencyRowStatus.text",
        "DependencyVerdictRows.DependencySafetyVerdict",
        "DependencyVerdictRows.DependencySafetyVerdict.summaryCaption",
        "DependencyVerdictRows.SafetyVerdictBadge.body",
        "GitInsightsSections.GitActivitySection.body",
        "GitInsightsSections.GitCommitScopeSection.body",
        "GitInsightsSections.GitCommitScopeSection.message",
        "GitInsightsSections.GitDataAbsence.emptyState",
        "GitInsightsSections.GitRepositoryInfoSection.body",
        "GitInsightsSections.GitRepositorySourceSection.discoveryDetail",
        "HealthAdviceCards.HealthTrendCard.body",
        "LiveReadings.memoryUsedBytes",
        "LiveReadings.trustedMemoryPoints",
        "LogsErrorClusters.LogErrorClusterRow.body",
        "LogsErrorClusters.LogsErrorClustersCard.body",
        "LogsFileTables.LogsAffectedFilesCard.body",
        "PerformanceProcessGroups.PerformanceGroupCard.badgeText",
        "PerformanceProcessGroups.PerformanceGroupCard.copy",
        "PerformanceProcessGroups.PerformanceGroupCard.header",
        "PerformanceProcessGroups.PerformanceProcessGroupsCard.body",
        "PerformanceProcessTable.PerformanceProcessTableCard.body",
        "PerformanceProcessTable.PerformanceProcessTableCard.coverageNote",
        "PerformanceProcessTable.ProcessSortKey",
        "PerformanceProcessTable.ProcessSortKey.title",
        "SectionNav.DetailSection",
    ]

    // MARK: - 解析规则（纯函数，元测试直接喂合成输入）

    private struct CodeIndex {
        var identifiers: Set<String> = []
        /// 文件名 -> 行数（`wc -l` 口径：数换行符，末尾不成行的一段算一行）。
        var files: [String: Int] = [:]
    }

    private enum Anchor {
        case symbol(segments: [String])
        case file(name: String, line: Int?)
        case example(ext: String)
    }

    private func classify(_ token: String) -> Anchor {
        let halves = token.components(separatedBy: ":")
        let stem = halves[0]
        let line = halves.count > 1 ? Int(halves[1]) : nil
        let parts = stem.components(separatedBy: ".").filter { !$0.isEmpty }
        let ext = (parts.last ?? "").lowercased()
        if Self.exampleManifestExtensions.contains(ext) { return .example(ext: ext) }
        if Self.repoFileExtensions.contains(ext) { return .file(name: stem, line: line) }
        return .symbol(segments: parts)
    }

    /// nil = 有效；非 nil = 失效原因。
    private func resolve(_ anchor: Anchor, in index: CodeIndex) -> String? {
        switch anchor {
        case .example:
            return nil
        case let .symbol(segments):
            let missing = segments.filter { !index.identifiers.contains($0) }
            return missing.isEmpty ? nil : "Sources/** 里找不到 \(missing.joined(separator: "."))"
        case let .file(name, line):
            guard let count = index.files[name] else { return "仓库里没有 \(name)" }
            if let line, line > count { return "\(name) 只有 \(count) 行，引用了第 \(line) 行" }
            return nil
        }
    }

    /// 反引号里的点号串（可带 `:NN`）。
    /// 必须用 `#"…"#` 单行 raw string：写成 `#"""…"""#` 会被当多行字面量，
    /// 内容混进换行后正则整组空转还常绿（WS-L 实测踩过）。
    private func tokens(in text: String) -> [String] {
        let pattern = try? NSRegularExpression(
            pattern: #"`([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+(?::[0-9]+)?)`"#)
        guard let pattern else {
            XCTFail("锚点正则构造失败，扫描器根本没在跑")
            return []
        }
        return pattern.matches(in: text, range: fullRange(of: text)).map { text.slice($0.range(at: 1)) }
    }

    // MARK: - 建索引与扫描

    /// NSRegularExpression 要 UTF-16 区间；这个 SDK 不给 `matches(in:)` 的 range 默认值。
    private func fullRange(of text: String) -> NSRange {
        NSRange(location: 0, length: text.utf16.count)
    }

    private func walk(under directory: URL, _ body: (URL) -> Void) {
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

    private func buildIndex() throws -> CodeIndex {
        var index = CodeIndex()
        let identifierPattern = try NSRegularExpression(pattern: #"[A-Za-z_][A-Za-z0-9_]*"#)
        walk(under: Self.repoRoot.appendingPathComponent("TcoderMonitor/Sources", isDirectory: true)) { url in
            guard url.pathExtension == "swift",
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            for match in identifierPattern.matches(in: text, range: fullRange(of: text)) {
                index.identifiers.insert(text.slice(match.range))
            }
        }
        XCTAssertFalse(index.identifiers.isEmpty, "Sources 一个标识符都没数到，索引坏了")
        walk(under: Self.repoRoot) { url in
            guard index.files[url.lastPathComponent] == nil,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            let newlines = text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
            index.files[url.lastPathComponent] = text.hasSuffix("\n") ? newlines : newlines + 1
        }
        return index
    }

    private struct Scan {
        var docsRead = 0
        var unreadable: [String] = []
        var symbolCount = 0
        var fileCount = 0
        var exampleCount = 0
        var excludedExtensions = Set<String>()
        var dead: [String: String] = [:]
    }

    private func scanDocs(with index: CodeIndex) -> Scan {
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
                switch anchor {
                case let .example(ext):
                    scan.exampleCount += 1
                    scan.excludedExtensions.insert(ext)
                case .symbol:
                    scan.symbolCount += 1
                case .file:
                    scan.fileCount += 1
                }
                if let reason = resolve(anchor, in: index) { scan.dead[token] = reason }
            }
        }
        return scan
    }

    // MARK: - 断言

    /// 分母守卫：先证明尺子在量东西。这条不成立时，任何「零失效」的结论都没有意义。
    func testScannerActuallyReadsDocsAndFindsAnchors() throws {
        let scan = scanDocs(with: try buildIndex())
        XCTAssertEqual(scan.unreadable, [], "有文档读不到却被当成「引用都有效」：\(scan.unreadable)")
        XCTAssertEqual(scan.docsRead, Self.docs.count, "不是每份文档都被扫了")
        XCTAssertGreaterThan(scan.symbolCount, 0, "一个符号锚点都没扫到 = 正则或文档路径失效，棘轮在空转")
        XCTAssertGreaterThan(scan.fileCount, 0, "一个文件行号锚点都没扫到 = 同上")
        XCTAssertEqual(scan.excludedExtensions.subtracting(Self.exampleManifestExtensions), [],
                       "排除集里出现了没登记的扩展名，豁免面被悄悄扩大了")

        let total = scan.symbolCount + scan.fileCount
        XCTAssertGreaterThan(total, 100, "在锚范围内的引用只有 \(total) 条，不像这份文档的真实规模")
        print("【#29 分母】在锚引用 \(total) 条（符号 \(scan.symbolCount) / 文件行号 \(scan.fileCount)）"
            + "，示例清单名排除 \(scan.exampleCount) 条，文档读到 \(scan.docsRead)/\(Self.docs.count) 份，skip 0")
    }

    /// 棘轮本体：新增死引用变红；修掉了却忘了同步基线，也变红。
    func testNoNewDeadReferencesAndBaselineOnlyShrinks() throws {
        let scan = scanDocs(with: try buildIndex())
        let found = Set(scan.dead.keys)

        let fresh = found.subtracting(Self.knownDeadAnchors).sorted()
        XCTAssertTrue(fresh.isEmpty, """
        文档里出现了基线之外的新死引用 \(fresh.count) 条：
        \(fresh.map { "  \($0) → \(scan.dead[$0] ?? "?")" }.joined(separator: "\n"))
        """)

        let healed = Self.knownDeadAnchors.subtracting(found).sorted()
        XCTAssertTrue(healed.isEmpty, """
        基线里这 \(healed.count) 条已经不再失效，请从 knownDeadAnchors 删掉：\(healed)
        留着不放等于给它发了一张永久免死牌——棘轮只许往紧里拧。
        """)

        XCTAssertEqual(found, Self.knownDeadAnchors, "死引用集合与基线不逐条相等")
        print("【#29 棘轮】新增失效 0 条；已知待修 \(found.count) 条，与基线 \(Self.knownDeadAnchors.count) 条逐条相等")
    }

    /// 把已知失效连同原因打印出来，交给各流认领（不参与判定）。
    func testKnownDeadAnchorsAreReportedWithReasons() throws {
        let scan = scanDocs(with: try buildIndex())
        for token in scan.dead.keys.sorted() {
            print("  【待修】\(token) —— \(scan.dead[token] ?? "")")
        }
        if Self.knownDeadAnchors.isEmpty {
            XCTAssertTrue(scan.dead.isEmpty, "基线已清空但仍有 \(scan.dead.count) 条死引用")
        } else {
            XCTAssertFalse(scan.dead.isEmpty, "基线非空却报零失效，说明扫描没跑到文档")
        }
    }

    /// 端到端金丝雀：拿**真实的 Sources 索引**和**真实的正则**过一段合成文本，
    /// 断言两条假锚点被判失效、一条真锚点（`LogsView.header`）被判有效。
    /// 与上面那条元测试的分工：那条测纯函数，这条测「索引 + 正则 + 规则」整条链路，
    /// 顺带证明索引不是空的（真锚点解得开）。改文档做注入式验证太脏，所以搬进合成文本。
    func testEndToEndCanaryAgainstTheRealIndex() throws {
        let index = try buildIndex()
        let canary = """
        合成行：死符号 `WsvCanaryDeadType.someMember`、没这个文件 `WsvCanaryFile.swift:999`、
        行号越界 `Package.swift:99999`、真实锚点 `LogsView.header`。
        """
        let hits = tokens(in: canary)
        XCTAssertEqual(Set(hits), ["WsvCanaryDeadType.someMember", "WsvCanaryFile.swift:999",
                                   "Package.swift:99999", "LogsView.header"],
                       "合成文本里的锚点没被全部扫到，正则或口径漂了")
        let dead = hits.compactMap { token -> String? in
            resolve(classify(token), in: index) != nil ? token : nil
        }.sorted()
        XCTAssertEqual(dead, ["Package.swift:99999", "WsvCanaryDeadType.someMember",
                              "WsvCanaryFile.swift:999"],
                       "金丝雀没有被全部判红，或把真实锚点误判成失效")
    }

    // MARK: - 元测试：尺子自己也要被测

    /// 造一个只含 `RealType`/`realMember` 与 `Real.swift`(10 行) 的小世界：
    /// 死引用必须全被抓出，活引用必须全被放过——两个方向都要，
    /// 否则「逢报必红」的钝尺子也会自称在守护。
    func testRulerDetectsDeadAndAcceptsLiveAnchors() throws {
        var index = CodeIndex()
        index.identifiers = ["RealType", "realMember", "Another", "Gone"]
        index.files = ["Real.swift": 10, "Guide.md": 3]

        let deadSamples = [
            "NonexistentTypeXYZ.someMember",
            "RealType.removedMember",
            "A.B.NotThere",
            "Real.swift:99",
            "Ghost.swift:1",
        ]
        for token in deadSamples {
            XCTAssertEqual(tokens(in: "`\(token)`"), [token], "样例 \(token) 没被识别成锚点，尺子读不到它")
            XCTAssertNotNil(resolve(classify(token), in: index), "死样例 \(token) 被判成有效，尺子钝了")
        }

        for token in ["RealType.realMember", "Real.swift:10", "Real.swift", "Guide.md:3"] {
            XCTAssertNil(resolve(classify(token), in: index), "活样例 \(token) 被判成失效，尺子在乱咬")
        }

        // 行号边界：等于末行算有效，多一行算失效（不许恒真也不许恒假）。
        XCTAssertNil(resolve(classify("Real.swift:10"), in: index))
        XCTAssertEqual(resolve(classify("Real.swift:11"), in: index),
                       "Real.swift 只有 10 行，引用了第 11 行")
        // 示例清单名走 example 分支：既不算在锚范围，也不该被判失效。
        if case .example = classify("package.json") {} else {
            XCTFail("package.json 应按示例清单名排除，而不是当成本仓文件引用")
        }
        if case .symbol = classify("LogsView.header") {} else {
            XCTFail("LogsView.header 应判为符号锚点")
        }
    }
}

private extension String {
    /// 按 NSRegularExpression 的 NSRange（UTF-16 口径）取子串。
    /// 文档里有中文，用「按 Character 偏移」的写法会切错位置，必须走 Range 转换。
    func slice(_ range: NSRange) -> String {
        guard let swiftRange = Range(range, in: self) else { return "" }
        return String(self[swiftRange])
    }
}
