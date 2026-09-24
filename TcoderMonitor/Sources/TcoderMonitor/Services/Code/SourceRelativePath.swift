import Foundation

// OWNER: Workstream A (静态代码分析) —— SourceRelativePath
//
// 从 SourceFileClassifier.swift 拆出，只为守住本工作流的红线（巨大文件不得增加）：
// **三条不变式、判定顺序、别名名单一字未改**，原先的 `private static` 跨文件后放宽到
// 模块内可见（本仓已有三处同样处理，见 FunctionRecognition.swift 顶部说明）。
//
// 这里回答的唯一问题是「一个 url 相对某个 root 的路径是什么」，
// 读写与统计留在 SourceFileClassifier / SourceScanTrail。

extension SourceFileClassifier {

    /// 以 root 为基准算相对路径。
    ///
    /// 不变式（三条同时成立）：
    /// 1. 返回值里**绝不含 `..` 路径段**，也不含前导 `/`；
    /// 2. 只要 url 落在 root 之下（原始路径前缀成立，或两者各自解析符号链接后的
    ///    canonical / 完全解析路径前缀成立），返回值就是那段相对路径；
    /// 3. 所有形态的前缀判定都不成立（url 真的在 root 之外）才退化为 `lastPathComponent`。
    ///
    /// 纯函数：不读写任何可变全局状态，同一对输入在同一进程内输出稳定（形态顺序固定）。
    static func relativePath(for url: URL, root: URL) -> String {
        // 第一步用原始路径：绝大多数调用（枚举器给出的路径与调用方 root 同前缀）在这里就命中，
        // 一次系统调用都不多做。
        if let relative = relativePath(urlPath: url.path, rootPath: root.path) { return relative }

        // 第二步按归一化形态交叉再试。Darwin 的 `FileManager` 目录枚举器返回的是**已解析符号链接**
        // 的路径（`/tmp/...` → `/private/tmp/...`、`/var/...` → `/private/var/...`），而调用方传进来的
        // root 往往是原始路径；不归一化就会让前缀匹配整体失败、相对路径退化成裸文件名，进而：
        // (a) 依赖相对路径的 `skipDirectories` 带斜杠项（默认名单里的 `Resources/raw`）永远命不中；
        // (b) UI 上不同目录的同名文件显示成同一条路径。
        let urlForms = pathForms(of: url)
        let rootForms = pathForms(of: root)
        for urlForm in urlForms {
            for rootForm in rootForms {
                if let relative = relativePath(urlPath: urlForm, rootPath: rootForm) { return relative }
            }
        }
        return url.lastPathComponent
    }

    /// 一个 URL 的路径形态（原始路径在前，去重后依序尝试，保证输出稳定）：
    /// - `URL.path` 原始形态；
    /// - `URLResourceKey.canonicalPathKey`：解析 `/var → /private/var`、`/tmp → /private/tmp` 这类
    ///   **前缀**软链接（注意本 SDK 只有 `canonicalPathKey`，没有 `canonicalItemPathKey`；
    ///   路径不存在时 Foundation 返回 nil，于是自然落回原始形态）；
    /// - `resolvingSymlinksInPath()`：`canonicalPathKey` 不解析**末段**组件，root 自身就是目录
    ///   软链接时只有它能对齐（实测 `/tmp/x/repoclink` → canonical 仍是 repoclink、resolved 才是真实仓库）。
    /// 只在原始前缀判定失败后才走到这里，实测每次查询约 1.6 µs。
    static func pathForms(of url: URL) -> [String] {
        var forms: [String] = []
        func add(_ candidate: String) { if forms.contains(candidate) == false { forms.append(candidate) } }
        add(url.path)
        if let canonical = canonicalPath(of: url) { add(canonical) }
        add(url.resolvingSymlinksInPath().path)
        // 文件系统派生的形态只对**存在**的路径有效，最后再补一遍不 stat 的字面别名，
        // 否则路径里有任何一层还没被创建，`/tmp/...` 与 `/private/tmp/...` 就判不到同一个根。
        for base in Array(forms) {
            for alias in lexicalAliasForms(ofPath: base) { add(alias) }
        }
        return forms
    }

    /// macOS 上 `/tmp`、`/var`、`/etc`、`/tftpboot` 都是 `/private/…` 的别名，这层关系由系统固定，
    /// 按字面展开两种形态即可，不需要（也不应该依赖）stat —— 单测里根路径常常并不存在。
    static let privateAliasDirectories: Set<String> = ["tmp", "var", "etc", "tftpboot"]

    static func lexicalAliasForms(ofPath path: String) -> [String] {
        guard path.hasPrefix("/") else { return [path] }
        if path.hasPrefix("/private/") {
            let rest = String(path.dropFirst("/private/".count))
            let head = rest.split(separator: "/", maxSplits: 1).first.map(String.init)
            if let head, privateAliasDirectories.contains(head) { return [path, "/" + rest] }
            return [path]
        }
        let head = path.dropFirst().split(separator: "/", maxSplits: 1).first.map(String.init)
        if let head, privateAliasDirectories.contains(head) { return [path, "/private" + path] }
        return [path]
    }

    /// 纯字符串前缀剥离；不成立（含 `..` 逃逸、剥完为空）返回 nil 交给调用方继续判定。
    static func relativePath(urlPath: String, rootPath: String) -> String? {
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard urlPath.hasPrefix(prefix) else { return nil }
        let trimmed = String(urlPath.dropFirst(prefix.count))
        guard trimmed.isEmpty == false else { return nil }
        // 只挡真正的 `..` 路径段，不误伤 `a..b.swift` 这类合法文件名。
        guard trimmed.hasPrefix("../") == false, trimmed.hasSuffix("/..") == false,
              trimmed.contains("/../") == false else { return nil }
        return trimmed
    }

    /// 本 SDK 只有 `URLResourceKey.canonicalPathKey`（没有 `canonicalItemPathKey`）。
    static func canonicalPath(of url: URL) -> String? {
        guard let path = try? url.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath,
              path.isEmpty == false else { return nil }
        return path
    }
}

// MARK: - 被扫根的唯一写法（同一个目录不许在两个面印成两个串）

/// 「一个目录进报告、上屏、进溯源块时只有**一个**写法」这一把尺子。
///
/// 为什么必须单独立一处：装配口原本有两套写法，而且方向是**反的**——
/// `CLIScan.validatedURL` 走 `standardizedFileURL`，`ShellGitAnalyzer.canonicalPath`
/// 走 `standardizedFileURL + resolvingSymlinksInPath`。这两个 API 在 macOS 上会把
/// `/private/tmp`、`/private/var` 这类系统别名的**真实路径倒剥成别名短写**。
/// 实测（2026-09-25，同一枚提交、同一条夹具、同一台机器）：
/// GUI 落 `/private/tmp/…/ShopApp`、CLI 落 `/tmp/…/ShopApp`，
/// 于是「同一个仓库，界面说 A、命令行说 B」，而且 `resolvedGitRoot`
/// 会把这种**写法之差**误报成「仓库根被重定位」（那一句是要上屏的，见 `HealthView`）。
///
/// 方向定在**物理路径**：那是 `git` / `lsof` / `ps` 打的形状，也是唯一稳定的形状，
/// 别名短写只是它的另一个名字。判据由 `ScannedPathTests` 钉死（含「输出必须是解析的不动点」，
/// 所以将来换 Foundation 的脾气会先红，而不是悄悄换个写法）。
enum ScannedPath {

    /// 路径的物理写法。路径**不存在**时也给出稳定答案（按字面别名规则补 `/private`，
    /// 不去 stat 出一个存在的路径冒充）：被扫根可能在扫描期间被删，那种时候改写它才是撒谎。
    static func canonical(_ raw: String) -> String {
        guard raw.isEmpty == false else { return raw }
        let resolved = URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
        return physicalForm(of: resolved)
    }

    /// 把 `resolvingSymlinksInPath` 剥掉的 `/private` 前缀补回来：
    /// 存在的路径问 `canonicalPathKey`（方向正确：`/tmp → /private/tmp`），
    /// 问不到的（不存在、无权限）按同一份别名名单做字面展开。
    private static func physicalForm(of resolvedPath: String) -> String {
        let url = URL(fileURLWithPath: resolvedPath)
        if let keyed = SourceFileClassifier.canonicalPath(of: url) { return keyed }
        return SourceFileClassifier.lexicalAliasForms(ofPath: resolvedPath)
            .first(where: { $0.hasPrefix("/private/") }) ?? resolvedPath
    }
}

// MARK: - 重复块坐标（RD-61 第二半：落盘形状只在这一处定）

extension ScannedSourceFile {

    /// 写进 `DuplicatedFragment.path` 的那一格坐标：**相对被扫根**，不是绝对路径。
    ///
    /// 为什么必须相对（三条后果，一条比一条坏）：
    /// 1. `DuplicatedBlock.id` 由 `occurrences` 的路径排序拼成 ⇒ 绝对路径把检出目录嵌进了
    ///    **块身份**里：同一段克隆在两台机器、两个 worktree 下有两个 id，RD-52 承诺的
    ///    「可点名、可 diff」不成立，两次扫描的结论集求交永远是空集。
    /// 2. 榜外坐标那 6 条样本会进 `scanLimitations` 与落盘字段，一句上限说明的长度
    ///    随仓库放在哪变（2026-09-23 实测同一条 ≤1,200 字符的门：主树 1,060、
    ///    `.worktrees/r21-backlog` 1,244 ⇒ 每条并行流的门禁必红）。
    /// 3. 屏上、JSON、句子三处读者本来就读的是同一个 `occurrences`，绝对形状等于让
    ///    每一处各自再猜一遍「该剥掉多长的前缀」。
    ///
    /// 守卫方向（不静默降级）：只有当 `relativePath` 确实是 `url.path` 的一次**真后缀剥离**
    /// 时才给相对形状；不是就退回绝对路径 —— 宁可这一条坐标随检出位置变，
    /// 也不要它拼回根之后指到别的文件上（`SourceFileClassifier.relativePath(for:root:)`
    /// 的第三条不变式说明 url 落在 root 之外时它会退化成裸文件名，那种形状有歧义）。
    /// 产品路径上 url 全部出自 `enumerator(at: scanRoot)`，所以这一支只由合成输入走到；
    /// 那条不变式由 `DuplicateCoordinatePortabilityTests` 在**真源码扫描**上逐文件复量。
    ///
    /// 还原成绝对路径**只有一个入口**：`CodeViewFormat.resolvedURL(_:root:)`
    /// （Finder 定位与「用默认应用打开」两处消费点都走它）；旧报告里那批绝对坐标
    /// 不必改写，它走的是同一函数 `hasPrefix("/")` 那一支。
    var duplicationCoordinate: String {
        let relative = relativePath
        guard relative.isEmpty == false, url.path.hasSuffix("/" + relative) else { return url.path }
        return relative
    }
}

// MARK: - 跳过目录计划

/// 跳过目录判定 + 已剔除目录的绝对路径集合（符号链接与 skipDirectories 的兜底防线）。
/// 放在这里而不是 SourceScanTrail.swift：它是「相对路径 + 前缀匹配」这套判定的直接消费者，
/// 而 SourceScanTrail.swift 已经贴着 400 行的文件上限。
struct SourceSkipPlan {
    let root: URL
    let names: Set<String>
    let relativePaths: [String]
    var excludedDirectories: Set<String> = []

    init(root: URL, options: ScanOptions) {
        self.root = root
        names = Set(options.skipDirectories.filter { $0.contains("/") == false })
        relativePaths = options.skipDirectories.filter { $0.contains("/") }
    }

    func isInsideExcluded(_ path: String) -> Bool {
        excludedDirectories.contains { path.hasPrefix($0 + "/") }
    }

    /// 该路径落在哪个被剔除目录之下，取**最顶层**那个作为根因（`vendor` 而不是 `vendor/portable-ruby/4.0.5_1`）。
    /// 台账要回答的就是「vendor/ 一共丢了多少行」，归到叶子目录上就没法看了。
    func excludedAnchor(for path: String) -> String? {
        let hits = excludedDirectories.filter { path.hasPrefix($0 + "/") }
        guard let top = hits.min(by: { $0.count < $1.count }) else { return nil }
        let name = (top as NSString).lastPathComponent
        return name.isEmpty ? top : name
    }

    /// 返回 true 表示该目录整体剔除；由调用方执行 skipDescendants，避免在此处写死枚举器类型
    mutating func consume(_ url: URL) -> Bool {
        let relative = SourceFileClassifier.relativePath(for: url, root: root)
        let excluded = isInsideExcluded(url.path)
            || names.contains(url.lastPathComponent)
            || relativePaths.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") })
        guard excluded else { return false }
        excludedDirectories.insert(url.path)
        return true
    }
}


