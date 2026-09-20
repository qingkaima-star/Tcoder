import XCTest
@testable import TcoderMonitor

/// WS-L 代码与 Git 类页面重样的判据测试。
///
/// 只测**纯函数**（口径派生、三态判定、读数聚合、分类色稳定性、文案措辞）：
/// 不启动 App、不碰渲染，UI 取证由总工统一安排。
final class CodeGitRestyleTests: XCTestCase {

    // MARK: - Helpers

    func author(_ name: String, _ email: String, commits: Int,
                        last: Date? = nil) -> AuthorStats {
        AuthorStats(name: name, email: email, commits: commits, additions: 0, deletions: 0,
                    filesTouched: 0, firstCommitAt: nil, lastCommitAt: last,
                    activityByHour: [], topDirectories: [:])
    }

    func bucket(_ date: Date, commits: Int, granularity: BucketGranularity = .week) -> CommitBucket {
        CommitBucket(date: date, commits: commits, additions: 0, deletions: 0, granularity: granularity)
    }

    // MARK: - Git 提交口径（「62 vs 48」那条账）

    // MARK: - 趋势读数与时段矩阵

    // MARK: - 贡献者分析

    // MARK: - 代码页三态

    // MARK: - 风险判据

    // MARK: - 依赖页诚实线

    // MARK: - 表格列定义

    // MARK: - 第二轮：口径互斥的三态空态

    // MARK: - 第二轮：色板与行节奏

    // MARK: - 防回潮棘轮（只扫 WS-L 名下四个目录）

    func wsLForbiddenPattern(named name: String) throws -> NSRegularExpression {
        let pattern = try XCTUnwrap(Self.forbiddenRawValues.first { $0.name == name }?.pattern,
                                    "棘轮里没有这条禁令：\(name)")
        return try NSRegularExpression(pattern: pattern)
    }

    /// 视图层禁止出现的写法（WS-I §6 的"零新增"断言，作用域只限 WS-L 名下四个目录）。
    /// 注释行不算违例：注释里要引用旧值才能说明为什么换掉它。
    /// `pagesOnly` 的三条只约束页面层——基座 `CodeGit/` 是组件实现点：
    /// `.padding(.vertical` 与 `.font(Theme.Typo.…)` 正是它对外提供 `dataTableRow()`
    /// 与 `CodeGitType.prose()` 的地方，在基座里禁掉等于把定义本身删掉。
    /// 每条禁令都由 `testRatchetPatternsActuallyDetectTheirOwnViolations` 反向验一次，
    /// 防止界符写错导致扫描空转（本项目上一轮就真的空转过）。
    static let forbiddenRawValues: [(name: String, pattern: String, pagesOnly: Bool)] = [
        ("裸字号", #"\.system\(size:"#, false),
        ("Theme 兼容桥旧色彩入口", #"Theme\.(accent|healthy|caution|danger|critical|neutral|gridLine|cardBackground|subtleBackground|monoSmall|monoBody|metricNumber|heroNumber)\b"#, false),
        ("Theme.color(for:)", #"Theme\.color\(for"#, false),
        ("裸颜色字面量", #"Color\((hex|red):"#, false),
        ("自造透明度", #"\.opacity\(0\.[0-9]"#, false),
        ("旧分隔线", #"Divider\(\)"#, false),
        ("冻结在 Dashboard 的旧件", #"(BannerRow|StatLine|LanguageBar)\("#, false),
        ("数字 padding", #"\.padding\((\.[a-z]+, )?[0-9]"#, false),
        ("数字 spacing", #"spacing: [0-9]"#, false),
        ("数字尺寸", #"\b(width|minHeight|maxHeight|height): [0-9]"#, false),
        ("行内上下留白绕过 dataTableRow", #"\.padding\(\.vertical"#, true),
        ("未登记的裸符号串", ##"Image\(systemName: ""##, false),
        ("页面直取 Typo 档而没走等宽入口", #"\.font\(Theme\.Typo\.(label|microLabel|narrative|body|cardTitle|pageTitle)\.font"#, true),
        ("绕过 dataTableRow 的行内留白", #"VStack\(spacing: Theme\.Spacing"#, true),
    ]

    struct SourceFile { let name: String; let body: String
        var lines: [String] { body.components(separatedBy: "\n") } }

    func wsLSources() throws -> [SourceFile] {
        let views = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/TcoderMonitorTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // TcoderMonitor
            .appendingPathComponent("Sources/TcoderMonitor/Views")
        let fm = FileManager.default
        var out: [SourceFile] = []
        for dir in ["Code", "Git", "Dependencies", "CodeGit"] {
            let url = views.appendingPathComponent(dir)
            let names = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
            for name in names.sorted() where name.hasSuffix(".swift") {
                let file = url.appendingPathComponent(name)
                guard let body = try? String(contentsOf: file, encoding: .utf8) else { continue }
                out.append(SourceFile(name: "\(dir)/\(name)", body: body))
            }
        }
        // 14 → 13：`CodeGit/CodeGitTable.swift` 于 M0 上提为 `Design/DataTable.swift`
        // 13 → 14（收官轮 WS-X0）：本 App 自扫点名 `CodeRiskAnalysis.suggestions` 138 行 / CC 17，
        // 按类拆出的三个构建器落在同目录新文件 `Code/CodeRiskAdvice.swift`（原文件留在 400 行线内）。
        // 归属没动：多的是 Code 目录里的一处实现分片，仍归本流。
        // （本轮 spec §2.4）。它被 6 个目录的 10 个文件共用，留在一个页面目录下
        // 等于让该页独占全仓的列系统。这条断言本来就是「归属被动过就要响」，
        // 它响了，改的是**记录**而不是把断言删掉。
        XCTAssertEqual(out.count, 14, "WS-L/WS-P 名下应有 14 个视图文件（Code 5 / Git 5 / Dependencies 2 / CodeGit 2），数量变了说明归属被动过；列系统已上提进 Design/，见 Design/DataTable.swift")
        return out
    }
}

extension GitDataAbsence {
    /// 标题是否出现重复——一旦有人把两种"没有数据"合回一句「……或……」，这里就会红。
    static func hasDuplicateTitles() -> Bool {
        let titles: [String] = [
            GitDataAbsence.notARepository.copy!.title,
            GitDataAbsence.repositoryWithoutCommits.copy!.title,
            GitDataAbsence.commitsUnparsed(total: 7).copy!.title,
            GitDataAbsence.commitsWithoutAuthors(total: 7).copy!.title,
        ]
        return Set(titles).count != titles.count
    }
}

