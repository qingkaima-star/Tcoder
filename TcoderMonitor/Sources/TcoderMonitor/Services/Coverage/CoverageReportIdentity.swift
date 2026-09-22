import Foundation

//  RD-25 · 覆盖率报告的**四类身份**之一到之三：格式 / 运行 / 模块。
//  （第四类「源码指纹」见 `CoverageSourceBinding.swift` —— 它要靠被扫仓库的提交状态算，
//    不能只从报告路径推出来，所以单独一格。）
//
//  为什么必须有身份：`overallLinePercent` 把留下的报告**直接累加相除**，
//  于是"同一次 nyc 运行导出的 lcov 与 json 摘要"（两份一模一样的数）会被算成两倍分母，
//  "全仓报告 + 模块报告"会互相重叠地累加，"unit 与 integration"的交集会被当成并集。
//  这三件事都不是精度问题，是**同一份证据被数了两遍**。要先能认出"这是同一来源"，
//  才谈得上合并。推不出来的一律标 `nil`（未知），未知不参与合并 —— 宁可分开呈现。

// MARK: - 格式身份

/// 报告格式。**这张表是本链上"文件名 → 什么格式 → 哪件工具"的唯一来源**，
/// 发现（决定扫哪些文件名）、解析（决定怎么读）、身份（决定能不能和别份合并）三处共用，
/// 免得三份清单各写一遍、哪天少写一个名字就静默漏掉一种格式。
enum CoverageReportFormat: String, Codable, Sendable, CaseIterable {
    case lcov
    case istanbulSummary
    case jacocoXml
    case coveragePyXml
    case cloverXml
    /// 文件名在候选清单里、但走到解析时已经认不出来了。**不许和别的格式合并**。
    case unrecognized

    /// 落盘与界面上认的工具名。取值与既有报告**一字未动**（旧报告里就写着这几个词）。
    var toolName: String {
        switch self {
        case .lcov: return "lcov"
        case .istanbulSummary: return "istanbul / nyc"
        case .jacocoXml: return "JaCoCo"
        case .coveragePyXml: return "coverage.py"
        case .cloverXml: return "clover"
        case .unrecognized: return "未识别格式"
        }
    }

    /// 文件名 → 格式。同一目录里 `lcov.info` 与 `lcov.dat` 是同一个格式的两种落名。
    static func identify(fileName: String) -> CoverageReportFormat {
        switch fileName {
        case "lcov.info", "lcov.dat": return .lcov
        case "coverage-summary.json": return .istanbulSummary
        case "jacoco.xml", "jacocoTestReport.xml": return .jacocoXml
        case "coverage.xml": return .coveragePyXml
        case "clover.xml": return .cloverXml
        default: return .unrecognized
        }
    }

    static var allFileNames: Set<String> { ["lcov.info", "lcov.dat", "coverage-summary.json",
                                            "jacoco.xml", "jacocoTestReport.xml",
                                            "coverage.xml", "clover.xml"] }

    /// 这份格式**本身**带不带源文件粒度。istanbul 的 json 摘要只有 `total` 一个桶，
    /// JaCoCo 的 report 级 counter 也是汇总 —— 它们没有任何一处写着"哪些文件"。
    var carriesPerSourceFileRecords: Bool { self == .lcov }

    /// 「同一次测试运行会一起落在这一个目录里的两种格式」。
    ///
    /// 只有 `nyc`/`istanbul` 这一对是**同一进程、同一批数据、两种落法**
    /// （`--reporter=lcov --reporter=json-summary`）⇒ 两份数说的是同一件事，相加必然双计。
    /// 别的组合同目录共放（比如 pytest 的 `coverage.xml` 和别人的 `lcov.info`）
    /// **不是**同一来源，一律不许按此规则去重 —— 宁可留着重复，也不许凭猜合并。
    static func isCoPublishedPair(_ lhs: CoverageReportFormat, _ rhs: CoverageReportFormat) -> Bool {
        Set([lhs, rhs]) == Set([CoverageReportFormat.lcov, .istanbulSummary])
    }
}

// MARK: - 运行 / 模块身份

/// 一份报告的身份。**全部由路径与报告正文推出**，因此可以随报告一起落盘并原地重算 ——
/// 这是有意的：新增字段要动 `Models/**`（冻结区），而路径与正文里确实写着这些信息。
///
/// ⚠️ R5b 改判：`runKey` **不再由 `derive` 拼出**。原来那句
/// `runKey = "module=\(module)|kind=\(kind.rawValue)"` 里的 `kind` 是
/// `CoverageAnalyzer.classify(url:)` 对**绝对路径**做子串匹配猜出来的归类，
/// 拿它当运行身份就是"靠文件名猜同一次运行"，而且猜错会把两次运行去重成一次（丢证据）。
/// 现在 `runKey` 一律先留 `nil`，由 `CoverageRunIdentity.assignRunKeys(to:)` 按
/// **同目录共位 + 正文互证** 分配；分不出来就保持 `nil`（未知不参与任何去重）。
struct CoverageReportIdentity: Codable, Equatable, Sendable {
    var format: CoverageReportFormat
    /// 同一目录、同一来源的键。`nil` = **认不出这次运行** ⇒ 该报告不与任何报告合并。
    var runKey: String?
    /// `runKey` 凭的是哪一条证据。`nil`/`.none` = 没有证据。
    var runEvidence: CoverageRunEvidence?
    /// 模块键：报告所在目录去掉"产物目录尾巴"之后剩下的相对目录。`""` = 仓库根。
    /// `nil` = 未知（绝对路径切不出可信相对形状）。
    var moduleKey: String?
    /// 报告**自身所在目录**相对被扫根的形式（**不**剥产物段）：这是"同一次运行"的共位坐标。
    /// `nil` = 在被扫目录之外。
    var directoryKey: String?
    /// 正文里写着的运行时刻（coverage.py `timestamp=` / clover `generated=`）。
    /// `nil` = 这个格式的正文里压根没有这一格（lcov / JaCoCo / istanbul 摘要都没有）。
    var runStamp: String?
    /// 只有汇总数字、没有文件清单 ⇒ 与其它汇总报告**永远无法核对是否重叠**。
    var isAggregateOnly: Bool
    /// 模块键为仓库根：视作"全仓候选"。**这只是候选，不是结论** ——
    /// 真正的合并判定看逐行账本（`CoverageLineLedger`），这里只用于披露与优先级。
    var isRepositoryWide: Bool

    /// 报告输出目录里属于"产物形式"的段，算模块键时要去掉，
    /// 否则 `coverage/lcov.info` 与 `coverage/html/lcov.info` 会被当成两次运行。
    /// 构建产物目录（`build`/`target`/`out`/`dist`）也在内：它们不可能是模块名，
    /// 留在段里会把 `server/build/reports/jacoco` 误当成一个模块路径。
    static let outputDirectorySegments: Set<String> = [
        "coverage", "cover", "reports", "report", "site", "jacoco", "clover",
        "html", "htmlcov", "lcov-report", "lcov", "xml", "json", "text",
        "unit", "integration", "itest", "e2e", "surefire", "test-results", "tmp",
        "build", "target", "out", "dist",
    ]

    /// 由报告路径与正文推出身份。`root` 是被扫目录（用来把绝对路径切成相对路径）。
    static func derive(path: String, root: URL, format: CoverageReportFormat?,
                       runStamp: String? = nil) -> CoverageReportIdentity {
        let resolved = format ?? CoverageReportFormat.identify(fileName: (path as NSString).lastPathComponent)
        let relative = relativePath(of: path, root: root)
        let directory = relative.map { ($0 as NSString).deletingLastPathComponent } ?? ""
        let segments = directory.split(separator: "/").map(String.init)
        var moduleSegments = segments[...]
        while let last = moduleSegments.last, outputDirectorySegments.contains(last.lowercased()) {
            moduleSegments = moduleSegments.dropLast()
        }
        let module = moduleSegments.isEmpty ? "" : moduleSegments.joined(separator: "/")

        return CoverageReportIdentity(
            format: resolved,
            // 运行归属要**两份以上互相核对**才成立，derive 只看一份 ⇒ 一律先留未知，
            // 由 `CoverageRunIdentity.assignRunKeys` 补。相对路径切不出来的连共位坐标都没有。
            runKey: nil,
            runEvidence: nil,
            moduleKey: relative == nil ? nil : module,
            directoryKey: relative == nil ? nil : directory,
            runStamp: runStamp,
            isAggregateOnly: !resolved.carriesPerSourceFileRecords,
            isRepositoryWide: relative != nil && module.isEmpty)
    }

    /// 路径 → 相对被扫目录的形式。**切不出来时返回 nil，不返回原路径**：
    /// 拿绝对路径当相对路径用，会让两份不同机器的报告看起来"模块不同"。
    ///
    /// 为什么要把每种写法都试一遍：macOS 的 `/var` 是指向 `/private/var` 的软链接，
    /// `contentsOfDirectory` 返回的是**已解析**的 `/private/var/...`，
    /// 而调用方给的 root 常是未解析的 `/var/...` —— 直接比前缀会在临时目录里
    /// 一份都切不出来（实测：整套同运行去重静默失效，两份一模一样的报告照样相加）。
    static func relativePath(of path: String, root: URL) -> String? {
        for target in pathVariants(path) {
            for prefix in pathVariants(root.path) {
                guard target.hasPrefix(prefix) else { continue }
                var rest = String(target.dropFirst(prefix.count))
                if rest.hasPrefix("/") { rest.removeFirst() }
                if !rest.isEmpty { return rest }
            }
        }
        return nil
    }

    private static func pathVariants(_ path: String) -> [String] {
        let url = URL(fileURLWithPath: path)
        return [url.path, url.standardizedFileURL.path, url.resolvingSymlinksInPath().path]
    }
}

// MARK: - 源码范围口径（RD-26：测试文件识别要跨语言）

/// 多语言的"这算测试码吗"判定，**叠在** `CoverageScope`（`Models/**` 冻结区）之上。
///
/// 为什么只能叠：`CoverageScope.isProductionSource` 住在契约文件里，本轮不动它；
/// 而它只认 Swift 那一套（`/Tests/`、`PackageTests`、`.build`、`*Tests.swift`），
/// 于是 `src/app.test.ts`、`src/test/java/…/OrderTest.java`、`tests/test_order.py`
/// 全被当成生产码 —— 实测一份十记录 lcov（3 份生产 + 7 份测试）算出 850/1000 = 85%，
/// 而生产码真值是 150/300 = 50%：**分母里 70% 是测试码，且测试码几乎必然被自己覆盖**。
/// 契约缺口（要总工把下列规则上提进 `CoverageScope`）见 Obsidian `112` 的 ## 契约缺口。
enum CoverageTestPathRules {

    /// 命中即为测试/校验码（不参与生产码分母）。逐条都是**路径段或完整后缀**判定，
    /// 因为子串判定会误伤：`latest.ts` 含 `test.ts`、`progress.ts` 含 `spec.ts`。
    static func isTestSource(path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let segments = path.split(separator: "/").map(String.init)
        guard let file = segments.last else { return false }
        let directories = Array(segments.dropLast()).map { $0.lowercased() }

        // ① 目录段：整个段就叫这些名字才算，`latest/`、`contest/` 一类不算。
        let testDirectories: Set<String> = [
            "tests", "test", "__tests__", "spec", "specs", "__mocks__",
            "androidtest", "it",
        ]
        if directories.contains(where: { testDirectories.contains($0) }) { return true }
        // Java 的 `src/test/java/…`、Kotlin 的 `src/test/kotlin/…` 与 Maven 验收集成测试的
        // `src/it/java/…` 都由上面的**段判定**命中（段名叫 test / it 才算），
        // 所以 `src/latest/Model.java` 这种生产路径不会被牵连。

        // ② 文件名后缀：JS/TS 生态的 `.test.` / `.spec.`（点号是判据的一部分，
        //    所以 `latest.ts` 不算、`app.test.ts` 算）。
        if matchesDottedTestInfix(file) { return true }

        // ③ 各语言的命名约定，一律要求后缀前那个字符是大写字母、下划线或连字符。
        return matchesSuffixedTestName(file)
    }

    /// `x.test.ts` / `x.spec.tsx` / `x.test.mjs` ……
    private static func matchesDottedTestInfix(_ file: String) -> Bool {
        for marker in [".test.", ".spec."] where file.contains(marker) {
            let language = String(file.suffix(after: marker))
            if ["ts", "tsx", "js", "jsx", "mjs", "cjs", "vue"].contains(language.lowercased()) {
                return true
            }
        }
        return false
    }

    /// `OrderTest.java` / `foo_test.go` / `test_order.py` / `user_spec.rb` / `CacheTest.kt`。
    /// 要求分隔符（大写 / `_` / `-`）：`Latest.java`、`Contest.java`、`protest.py` 都不算。
    private static func matchesSuffixedTestName(_ file: String) -> Bool {
        let upperCasedSuffixes = ["Test.java", "Tests.java", "IT.java", "TestCase.java",
                                  "Test.kt", "Tests.kt", "IT.kt", "Test.swift", "Tests.swift",
                                  "Test.scala", "Spec.scala", "Test.cs", "Tests.cs"]
        // `hasSuffix` 本身**区分大小写**，这就是判据：
        // `WidgetTest.java`（驼峰里那个大写 T 就是分隔符）算，
        // `Latest.java` / `Contest.java` / `progressTest`? —— 结尾是小写 `test.java`，不算。
        for suffix in upperCasedSuffixes where file.hasSuffix(suffix) { return true }
        let underscoreSuffixes = ["_test.go", "_test.py", "_test.rb", "_spec.rb", "_test.rs",
                                  "_test.java", "_test.js", "_test.ts"]
        for suffix in underscoreSuffixes where file.hasSuffix(suffix) {
            return file.count > suffix.count   // 不许整个文件名就只有后缀
        }
        return file.hasPrefix("test_") && file.hasSuffix(".py")
    }
}

private extension String {
    /// 取 `marker` 之后的那一段（用于 `.test.ts` 里挑出语言后缀）。
    func suffix(after marker: String) -> Substring {
        guard let range = range(of: marker) else { return Substring() }
        return self[range.upperBound...]
    }
}
