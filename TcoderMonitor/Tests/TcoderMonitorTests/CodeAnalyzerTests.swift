import XCTest
@testable import TcoderMonitor

/// WS-A（静态代码分析）单元测试：`Services/Code` 的行分类、扫描纪律、圈复杂度、
/// 重复代码与端到端聚合。
///
/// 约定：
/// - 夹具一律写在 `FileManager.default.temporaryDirectory` 下、随测试即建即删，
///   绝不读写本仓库之外的资产；真实仓库自检只扫本仓库自身目录树。
/// - 断言以「不变式」优先，只有自己构造的夹具与纯函数才写死具体数字。
final class CodeAnalyzerTests: XCTestCase {

    // MARK: - 夹具基础设施

    var fm: FileManager { FileManager.default }

    /// 本测试独占的临时夹具根（已取真实路径）。
    ///
    /// `FileManager` 的目录枚举器返回的是**已解析软链接**的路径，而 macOS 的 temporaryDirectory 位于
    /// `/var -> /private/var` 之下（`resolvingSymlinksInPath()` 不解析这种前缀软链接，实测只有
    /// `canonicalPathKey` 能对齐）。夹具根不归一化就会让 relativePath 退化成主文件名、
    /// 带 `/` 的 skipDirectories 命不中、「是否越出夹具根」的断言也全线失真。
    func makeFixtureRoot() throws -> URL {
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: false)
        let canonical = try? base.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath
        guard let path = canonical, path.isEmpty == false else { return base }
        return URL(fileURLWithPath: path)
    }

    @discardableResult
    func write(_ text: String, to relativePath: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    func classify(_ url: URL, root: URL, options: ScanOptions = .default) -> ScannedSourceFile? {
        SourceFileClassifier(options: options).classify(url: url, root: root)
    }

    func scan(_ root: URL, options: ScanOptions = .default) async -> SourceScanResult {
        await SourceTreeScanner(options: options).scan(root: root)
    }

    /// 行种类串：C=代码、M=注释、_=空行，便于一次比对整份夹具的分类结果。
    func kindPattern(of file: ScannedSourceFile) -> String {
        file.lines.map { line in
            switch line.kind {
            case .code: return "C"
            case .comment: return "M"
            case .blank: return "_"
            }
        }.joined()
    }

    /// 逐行重新计数，不直接信结构体自带的汇总字段。
    func recount(_ file: ScannedSourceFile) -> (blank: Int, comment: Int, code: Int) {
        var blank = 0
        var comment = 0
        var code = 0
        for line in file.lines {
            switch line.kind {
            case .blank: blank += 1
            case .comment: comment += 1
            case .code: code += 1
            }
        }
        return (blank, comment, code)
    }

    func lineCountsHold(_ file: ScannedSourceFile) -> Bool {
        file.totalLineCount == file.blankLineCount + file.commentLineCount + file.codeLineCount
    }

    func codeLineTotal(of files: [ScannedSourceFile]) -> Int {
        files.reduce(0) { $0 + $1.codeLineCount }
    }

    func lineTotal(of files: [ScannedSourceFile]) -> Int {
        files.reduce(0) { $0 + $1.totalLineCount }
    }

    /// 显式构造 ScanOptions，避免受默认名单变更影响。
    func options(maxFiles: Int = 5_000,
                        maxFileBytes: Int = 2_000_000,
                        skipDirectories: Set<String> = [],
                        binaryExtensions: Set<String> = [],
                        includeHidden: Bool = false) -> ScanOptions {
        ScanOptions(maxFiles: maxFiles, maxFileBytes: maxFileBytes, skipDirectories: skipDirectories,
                    binaryExtensions: binaryExtensions, includeHidden: includeHidden)
    }

    // MARK: - A. 行分类不变式

    // MARK: - B. 注释判定按语言

    // MARK: - C. TODO / FIXME

    // MARK: - D. 语言映射

    // MARK: - I. 重复代码

    // MARK: - J. 端到端

    // MARK: - K. 性能护栏

    // MARK: - L. 已知缺陷（上游修复前预期失败）

}
