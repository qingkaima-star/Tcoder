import XCTest
@testable import TcoderMonitor

/// OWNER: WS-X0 总工 —— **实现文件（`Sources/**` 与 `scripts/**`）的规模闸门**。
///
/// 为什么要有这条门：产品自己对外承诺的「巨大文件」口径是
/// `FileSystemCodeAnalyzer.mediumFileLines` = 400 行，它出现在自扫报告的待办单里，
/// 也参与健康评分的「代码质量」。但在本文件之前，**这条线在实现文件侧没有任何断言**：
///   * `X3TestSizeAuditTests` 用同一个 400 行口径，但它的扫描面明写只到 `Tests/**`
///     （注释原话："Sources 的规模债是 WS-X1 的账，不在这条门里"）；
///   * `SelfScanDogfoodTests` 只管 >800 行那一条（`highFileLines`，`ceiling = 0`）。
/// 结果就是收官轮把 Sources+Tests 的 >400 行文件从 39 个打到 0 之后，main 又叠了 83 笔提交，
/// `Design/SharedComponents.swift` 长回 426、`Design/ReadoutKit.swift` 长回 424，
/// 两把脚本尺子 `trace_report.py` 463 / `perf_selfcheck.sh` 458 也越线，
/// 而全量测试一声不响 —— **守卫只管一半总体，等于那一半没有守卫**。
///
/// 口径全部引用产品侧既有常量，本文件一个新数字都不造；行数走
/// `SelfScanHarnessCase.wcStyleLineCount`（`wc -l` 口径，与只减不增棘轮同一把尺子），
/// 走树用产品侧 `SourceTreeScanner`。
///
/// 两条写法上的教训就地写在这里：
///   1. **扫目录全集，不钉文件名**。钉文件名会在符号被拆走之后读成 0 并冒充通过
///      （main 批次 H5 的一条守卫就是这么静默失效的）。
///   2. **实现文件的判据是"不是测试"，不是"在 Sources 下"**。后者留了一个洞：
///      把超限文件挪去一个新目录就能绕过本门。
final class SourcesSizeAuditTests: SelfScanHarnessCase {

    private static let fileLineBar = FileSystemCodeAnalyzer.mediumFileLines

    /// **剩余超限文件的点名清单（只减不增）**。
    ///
    /// 两条脚本尺子是性能轮名下的产物（AGENTS §3：`scripts/perf_*` 归性能总工），
    /// 它们另有一整套 `perf_selfcheck.sh` 的 11 项反例要过，拆法不能只按行数切；
    /// 所以这里先**点名挂账**而不是悄悄排除。谁把它们拆回 400 以下就把条目划掉，
    /// 新增一个超限文件则当场变红。与 `SelfScanDogfoodTests` 的 `ceiling = 0` 同一种写法。
    ///
    /// 2026-09-21 划掉一条：`perf_selfcheck.sh` 从 835 行按主题拆成「宿主 68 + 三块反例
    /// 347/242/218」，四份都在 400 以下。它撞的是 `SelfScanDogfoodTests` 的 ≤800 那条，
    /// 当场把门禁判红过一次——挂账名单不是免检通道，账还上就把条目划掉。
    private static let hugeFileWorkList: Set<String> = [
        "TcoderMonitor/scripts/trace_report.py",
    ]

    /// 实现文件 = 仓库里的 `.swift`（`Tests/**` 除外，那条面由 `X3TestSizeAuditTests` 守）
    /// 加 `.py` / `.sh` 两把尺子语言。文档（.md）**不在本门里**——那是产品缺陷 #5
    /// （"散文长度不该算代码可维护性"）的裁定范围，塞进来等于用一条测试替没拍板的口径背书。
    static func isImplementationFile(_ url: URL) -> Bool {
        switch url.pathExtension {
        case "swift": return !url.path.contains("/Tests/")
        case "py", "sh": return true
        default: return false
        }
    }

    /// 相对仓库根的路径（清单与报错都用它，便于和 `git ls-files` 直接对上）。
    /// 两边都先解符号链接：`FileManager.temporaryDirectory` 给的是 `/var/...`，
    /// 而扫描器回来的路径是 `/private/var/...`，不解链接就匹配不上前缀、
    /// 只能退回 `lastPathComponent`（元测试就是这么抓到目录段凭空消失的）。
    static func relativePath(of url: URL, root: URL) -> String {
        let path = url.resolvingSymlinksInPath().path
        let base = root.resolvingSymlinksInPath().path
        guard path.hasPrefix(base) else { return url.lastPathComponent }
        return String(path.dropFirst(base.count).drop(while: { $0 == "/" }))
    }

    /// 超过 400 行的实现文件，按行数从大到小。
    /// 分三步写：`filter + compactMap + 三元 sorted` 串成一条链会让类型检查超时。
    static func oversized(_ files: [ScannedSourceFile], root: URL) -> [(path: String, lines: Int)] {
        var over: [(path: String, lines: Int)] = []
        for file in files where isImplementationFile(file.url) {
            guard let text = try? String(contentsOf: file.url, encoding: .utf8) else { continue }
            let lines = wcStyleLineCount(text)
            if lines > fileLineBar {
                over.append((relativePath(of: file.url, root: root), lines))
            }
        }
        over.sort { first, second in
            if first.lines != second.lines { return first.lines > second.lines }
            return first.path < second.path
        }
        return over
    }

    func testImplementationFilesStayUnderTheHugeFileBar() async throws {
        let root = Self.repoRoot
        let scanned = await SourceTreeScanner(options: .default).scan(root: root).files
        let implementation = scanned.filter { Self.isImplementationFile($0.url) }

        // 分母守卫：扫不到东西就等于这条门在空跑。现量约 165 个实现文件，
        // 这里只要求 >120 —— 路径解析静默失效时会掉到个位数，那才是这条要挡的事。
        XCTAssertGreaterThan(implementation.count, 120,
                             "只扫到 \(implementation.count) 个实现文件，扫描面退化了，下面的判据是永真绿")

        let over = Self.oversized(scanned, root: root)
        let found = Set(over.map(\.path))

        let unexpected = found.subtracting(Self.hugeFileWorkList)
        XCTAssertTrue(unexpected.isEmpty, """
        实现文件里出现 \(Self.fileLineBar) 行口径之外、且不在挂账清单里的新超限文件：
        \(over.filter { unexpected.contains($0.path) }.map { "  \($0.path) \($0.lines) 行" }.joined(separator: "\n"))
        这条线就是产品自扫报告里「巨大文件」用的同一条（`FileSystemCodeAnalyzer.mediumFileLines`），
        **拆文件才是修复**：改 `fileLineBar`、往清单里塞条目、或把文件挪出扫描面都不算。
        真要挂账，就在清单里写清归属与拆法，并向总工说明理由。
        """)

        let stale = Self.hugeFileWorkList.subtracting(found)
        XCTAssertTrue(stale.isEmpty, """
        挂账清单里 \(stale.count) 个文件已经达标了，把它们从 `hugeFileWorkList` 划掉：
        \(stale.sorted().joined(separator: "\n"))
        """)

        print("【实现文件规模闸门】实现文件 \(implementation.count) 个 / 超 \(Self.fileLineBar) 行的 \(over.count) 个"
            + "（挂账 \(Self.hugeFileWorkList.count)）：\n"
            + over.map { "  \($0.path) \($0.lines) 行" }.joined(separator: "\n"))
    }

    // MARK: - 元测试：尺子必须吃得到数据（注入超限样例要抓到、达标样例不报、判据不认漏）

    /// 只减不增的棘轮最容易死在"尺子读不到东西"上：那样 `over` 恒空、两条断言永远绿。
    /// 这里用**同一把尺子**量三份合成夹具，一次钉住三件事：
    /// 超 1 行要抓到、差 1 行不报、测试目录与文档不该被算进实现文件。
    func testRulerCatchesInjectedOversizedFileAndIgnoresTheRest() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sources-size-audit-probe", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bar = Self.fileLineBar

        func make(_ relative: String, lines: Int) throws -> URL {
            let url = dir.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            var bodyLines = ["import Foundation", "", "enum Probe {"]
            bodyLines += Array(repeating: "    // line", count: lines - 4)
            bodyLines.append("}")
            XCTAssertEqual(bodyLines.count, lines, "夹具本身没凑准 \(lines) 行，元测试的尺子就不准")
            // 每行都以 \n 结尾：`wcStyleLineCount` 数的是换行符，缺了末尾换行会少算一行。
            try (bodyLines.joined(separator: "\n") + "\n")
                .write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        let overByOne = try make("Sources/TcoderMonitor/ProbeOver.swift", lines: bar + 1)
        let underByOne = try make("Sources/TcoderMonitor/ProbeUnder.swift", lines: bar - 1)
        let inTests = try make("Tests/TcoderMonitorTests/ProbeTest.swift", lines: bar + 40)
        let prose = try make("docs/ProbeDoc.md", lines: bar + 40)

        let scanned = await SourceTreeScanner(options: .default).scan(root: dir).files
        XCTAssertEqual(scanned.count, 4, "产品侧扫描器没把四份夹具都收进来，元测试自身失效")

        let hit = Set(Self.oversized(scanned, root: dir).map(\.path))
        XCTAssertEqual(hit, [
            "Sources/TcoderMonitor/ProbeOver.swift",
        ], """
        尺子抓错对象：超 1 行的必须抓到；差 1 行的不许报；Tests/ 与 .md 不许算进实现文件。
        实测抓到 \(hit.sorted())
        """)
        XCTAssertTrue(Self.isImplementationFile(overByOne), "超限那份该被判成实现文件")
        XCTAssertTrue(Self.isImplementationFile(underByOne), "差 1 行的也是实现文件，只是不该被报")
        XCTAssertFalse(Self.isImplementationFile(inTests), "Tests/ 下的文件归 X3 那条门")
        XCTAssertFalse(Self.isImplementationFile(prose), "文档归产品缺陷 #5 的裁定，不归本门")
        print("【实现文件规模闸门·元测试】注入 \(bar + 1) 行抓到、\(bar - 1) 行不报、"
            + "Tests/\(bar + 40) 行与 .md 均不计入实现文件")
    }
}
