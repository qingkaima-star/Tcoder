import XCTest

/// OWNER: WS-U 可达性守卫（缺陷 #45）——**"实现文件必须被引用"的机器守卫**。
///
/// 要补的洞：往 `Sources/TcoderMonitor/**` 扔一个零调用的 `.swift`，`Package.swift` 里只有
/// 一个 `executableTarget(path: "Sources/TcoderMonitor")`，它照样参与编译，全仓 58 个测试文件
/// 一声不响全绿。现有守卫都不管：`DocReferenceRatchetTests` 判「文档锚点的符号存不存在」（新增
/// 死文件反而让它更绿）、`SelfScanDogfoodTests` 只数超 800 行的文件、覆盖率类只看得见有可执行行的文件。
///
/// **判据（怎么写才算被引用）**：先用等长脱敏器剥掉注释与字符串字面量（插值 `\(...)` 里的
/// 表达式按代码保留，因为 `Text("\(Theme.Layout.x)")` 是真引用），再按**花括号深度**把声明分成
/// 「类型声明（深度 ≤ 1）」与「类型作用域成员（深度恰为 1，即 `struct`/`extension` 一级花括号内的
/// `func`/`var`/`let`/`case`/`typealias`）」。函数体里的局部量一律不当候选证据——普查时
/// 「局部变量 `arguments`/`limit`/`modifiers` 在别的文件里也叫这个名」就是这样把死文件洗活的。
/// 四条判据任一命中即算在用：
/// 1. **唯一类型名**：本文件声明的类型名全仓只有本文件声明，且在另一个实现文件里整词出现；
/// 2. **限定引用**：`Owner.member` 逐字出现在另一个实现文件里；
/// 3. **同作用域派发**：`(Owner, member)` 全仓只由本文件声明，且另一文件自己也拥有 `Owner`
///    作用域（声明或扩展了它）并整词提到该成员名——`ManifestParsers.swift` 分派到各解析分片、
///    `DependencyNetworkLookup.swift` 调 `NpmClient.swift` 里的 `performNpmLookup` 都是这形状；
/// 4. **static 简写**：`static` 成员（同样要求 `(Owner, member)` 全仓唯一声明）以 `.member` 形式
///    被使用。缺这条会把 `Notification.Name.requestAddProject`（消费方写 `for: .requestAddProject`）
///    判成死码，也就是误杀 `@main` 那个文件。
///
/// **搜索面**只有 `Sources/TcoderMonitor/**` 的其他实现文件：只有单测在用的实现文件，正是
/// AGENTS.md 明令禁止的「无调用方的实现文件」。**唯一性**在 Sources + Tests 全集上算——别人在
/// 测试里声明了同名符号时，朴素 grep 会把它当调用证据，那正是坑 3 的对称面。
final class SourceFileReachabilityTests: XCTestCase {

    // MARK: - 仓库根与扫描面

    /// 仓库根走 `#filePath` 回溯（与 `SelfScanHarness.repoRoot`、`DocReferenceRatchetTests` 同一套
    /// 写法）：本文件 → TcoderMonitorTests → Tests → TcoderMonitor（包根）。测试进程的 CWD 不是
    /// 包根，按相对路径扫会「静默扫不到东西、然后判通过」。
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let sourceDirName = "Sources/TcoderMonitor"
    private static let testDirName = "Tests/TcoderMonitorTests"

    /// 普查基线：`Sources/TcoderMonitor/**` 的文件数。钉住它是为了堵死
    /// 「目录解析失效 → 分母掉到个位数 → 零死文件通过」这条永真绿路径。
    ///
    /// 108 → 109（WS-T #43 新增 Services/Health/GitCadenceEvidence.swift，
    /// 调用点 WeightedHealthScorer 的 .activity 分支）。棘轮的摩擦是有意的：
    /// 加文件必须有人先确认它凭什么被引用。
    /// 109 → 110（WS-Y #47 新增 Design/DataAbsence.swift，13 处页面调用点，未用清单未点名它）。
    private static let censusBaseline = 111

    private static let prunedDirectories: Set<String> = [".git", ".build", ".swiftpm", ".worktrees",
                                                        "node_modules", "DerivedData", "dist", "build", "out"]

    /// 框架隐式调度的入口白名单。**只有 `@main` 一处**，且下面的门要求每个条目正文里真写着
    /// `@main`、并且它本身也拿得出证据——白名单不许变遮羞布。
    private static let frameworkWhitelist: Set<String> = ["App/TcoderMonitorApp.swift"]

    /// 普查点名的三个扩展分片（坑 1）：自己不声明顶层类型，只写 `extension SomeType`。
    /// 分片全集由扫描动态得出，这里钉三个具体名字，防止「发现逻辑哪天退化成空集」。
    private static let namedShardFiles = ["Services/Dependencies/ManifestParsersApple.swift",
                                          "Services/Code/ComplexityCounting.swift",
                                          "Services/Logs/CrashTextParsing.swift"]

    // MARK: - 数据模型

    // MARK: - 可见性说明（2026-09-20 拆分所致，**不要改回 private**）
    //
    // `RDoc` / `Rule` / `Evidence` / `ScanOutcome` / `Gate` / `leadingDotRE` / `buildOutcome` /
    // `gate` / `synth` 原先是 `private`。本轮补元测试后本文件涨到 880 行、撞上 800 行闸门，
    // 按「闸门不降、把文件拆开才是修复」拆出了 `SourceFileReachabilityMetaTests.swift`；
    // `private` 在同类型的跨文件 extension 里不可见，所以这几个声明放成了 `internal`。
    // **改回 `private` 会让那个文件编不过。**

    struct RDoc { var relativePath: String; var raw: String; var isProduction: Bool }

    private struct OwnerMember: Hashable, Comparable {
        var owner: String; var member: String
        static func < (l: OwnerMember, r: OwnerMember) -> Bool { (l.owner, l.member) < (r.owner, r.member) }
    }

    private struct RAnalysis {
        var types = Set<String>()
        /// 深度 0 声明的类型：只写 `extension` 的分片文件这里必为空。
        var topLevelTypes = Set<String>()
        var extensions = Set<String>()
        /// 深度恰为 1 的成员声明（类型作用域成员，不含函数体里的局部量）。
        var members = Set<OwnerMember>()
        var staticMembers = Set<OwnerMember>()
        /// 本文件「拥有作用域」的类型名：自己声明的类型 + 扩展目标 + 成员所属类型。
        var owners = Set<String>()
    }

    enum Rule: String, CaseIterable {
        case uniqueType = "①唯一类型名", qualified = "②限定引用"
        case dispatcher = "③同作用域派发", staticShorthand = "④static 简写"
    }

    struct Evidence: Hashable { var rule: Rule; var symbol: String; var witness: String }

    struct ScanOutcome {
        var productionFiles: [String] = []
        var testFileCount = 0
        var inUse: [String] = []
        var unused: [String] = []
        var whitelisted: [String] = []
        var evidence: [String: [Evidence]] = [:]
        var ruleTally: [Rule: Int] = [:]
        var candidateCount = 0
        var strippedFileCount = 0
    }

    struct Gate { var reasons: [String]; var pass: Bool { reasons.isEmpty } }

    /// 整词 / 限定 / 前导点简写三张倒排索引（键 → 出现过的实现文件集合）。
    /// 用索引而不是逐条跑正则：候选符号上千个，逐条正则会跑到分钟级。
    private struct TokenIndex {
        var word: [String: Set<String>] = [:]
        var qualified: [String: Set<String>] = [:]
        var dot: [String: Set<String>] = [:]
    }

    // MARK: - 脱敏器（剥注释与字符串，等长替换）

    /// 把注释与字符串字面量整段等长替换成空格（换行保留、行号不漂），返回与入参**等长**的纯代码
    /// 文本。插值 `\(...)` 里的表达式按代码保留。
    static func strippingNoise(_ raw: String) -> String {
        var chars = Array(raw)
        let n = chars.count
        var i = 0
        while i < n {
            let c = chars[i]
            if c == "/", i + 1 < n {
                if chars[i + 1] == "/" {
                    var j = i
                    while j < n, chars[j] != "\n" { j += 1 }
                    blank(&chars, i, j)
                    i = j
                    continue
                }
                if chars[i + 1] == "*" {
                    var depth = 1
                    var j = i + 2
                    while j < n, depth > 0 {
                        if chars[j] == "*", j + 1 < n, chars[j + 1] == "/" { depth -= 1; j += 2 }
                        else if chars[j] == "/", j + 1 < n, chars[j + 1] == "*" { depth += 1; j += 2 }
                        else { j += 1 }
                    }
                    blank(&chars, i, j)
                    i = j
                    continue
                }
            }
            if c == "#" {
                var k = i
                while k < n, chars[k] == "#" { k += 1 }
                if k < n, chars[k] == "\"" { i = eatString(&chars, open: k, hashes: k - i); continue }
                i = k
                continue
            }
            if c == "\"" { i = eatString(&chars, open: i, hashes: 0); continue }
            i += 1
        }
        return String(chars)
    }

    private static func blank(_ chars: inout [Character], _ from: Int, _ to: Int) {
        var k = max(0, from)
        while k < min(chars.count, to) { if chars[k] != "\n" { chars[k] = " " }; k += 1 }
    }

    /// 从 `open`（指向第一个引号）吃一个字面量，返回结束后的下标。支持 `#"…"#` 与三引号。
    private static func eatString(_ chars: inout [Character], open: Int, hashes: Int) -> Int {
        let n = chars.count
        let quotes = (open + 2 < n && chars[open + 1] == "\"" && chars[open + 2] == "\"") ? 3 : 1
        var i = open + quotes
        var literalStart = open
        func isEscape(_ j: Int) -> Bool {
            guard chars[j] == "\\", j + 1 + hashes < n else { return false }
            var k = j + 1
            while k < j + 1 + hashes { if chars[k] != "#" { return false }; k += 1 }
            return true
        }
        func terminator(_ j: Int) -> Int? {
            guard chars[j] == "\"" else { return nil }
            var k = j + 1
            var h = 0
            while h < hashes { guard k < n, chars[k] == "#" else { return nil }; k += 1; h += 1 }
            if quotes == 3 { for _ in 0..<3 { guard k < n, chars[k] == "\"" else { return nil }; k += 1 } }
            return k - j
        }
        while i < n {
            if isEscape(i) {
                let p = i + 1 + hashes
                if p < n, chars[p] == "(" {
                    blank(&chars, literalStart, i)
                    guard let close = matchingParen(&chars, atOpen: p) else {
                        blank(&chars, literalStart, n)
                        return n
                    }
                    literalStart = close + 1
                    i = close + 1
                    continue
                }
                i = p + 1
                continue
            }
            if let len = terminator(i) {
                blank(&chars, literalStart, i + len)
                return i + len
            }
            if quotes == 1, chars[i] == "\n" { // 未闭合的单行字面量：就地止损
                blank(&chars, literalStart, i)
                return i
            }
            i += 1
        }
        blank(&chars, literalStart, n)
        return n
    }

    private static func matchingParen(_ chars: inout [Character], atOpen: Int) -> Int? {
        var depth = 0
        var i = atOpen
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                var k = i - 1
                while k >= 0, chars[k] == "#" { k -= 1 }
                i = eatString(&chars, open: i, hashes: i - 1 - k)
                continue
            }
            if c == "(" { depth += 1 }
            if c == ")" { depth -= 1; if depth == 0 { return i } }
            i += 1
        }
        return nil
    }

    // MARK: - 声明解析与倒排索引

    private static let declRE = try! NSRegularExpression(
        pattern: #"\b(struct|class|enum|protocol|actor|extension)\s+([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*)"#)
    private static let memberRE = try! NSRegularExpression(
        pattern: #"\b(func|var|let|case|typealias)\s+([A-Za-z_]\w*)"#)
    private static let staticRE = try! NSRegularExpression(pattern: #"\bstatic\b|\bclass[ \t]+func\b"#)
    private static let wordRE = try! NSRegularExpression(pattern: #"[A-Za-z_]\w*"#)
    private static let dottedRE = try! NSRegularExpression(pattern: #"\b([A-Za-z_]\w*)\.([A-Za-z_]\w*)\b"#)
    /// 前导点简写索引。`(?<![\w.])` 是**必须的**：少了它 `NSWorkspace.shared` 也会被收进来，
    /// 于是任何声明了 `static ... shared` 的类型都被别的类型白送证据（2026-09-20 真漏过一次）。
    static let leadingDotRE = try! NSRegularExpression(pattern: #"(?<![\w.])\.([A-Za-z_]\w*)"#)
    /// 元测试 5 的独立复核口径：行首 ≤ 4 空白 + 修饰词 + 类型关键字 + 名字。故意**不借用**引擎的
    /// 花括号深度逻辑——两把尺子不许共享同一个盲区。
    private static let independentTypeSiteRE = try! NSRegularExpression(
        pattern: #"^[ \t]{0,4}(?:[A-Za-z_]\w* +)*(?:struct|class|enum|protocol|actor) +([A-Za-z_]\w*)"#)

    private static func matches(_ re: NSRegularExpression, in text: String) -> [NSTextCheckingResult] {
        re.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    /// 单文件：按花括号深度（逐字符推进，不按行——`struct A { let b = 1 }` 写成一行也要算对）
    /// 把声明分成类型（深度 ≤ 1）与类型作用域成员（深度恰为 1）。
    private static func analyzeOne(_ code: String) -> RAnalysis {
        let ns = code as NSString
        let total = ns.length
        var a = RAnalysis()
        var scopes: [(depth: Int, name: String)] = []
        var depth = 0
        var cursor = 0
        func advance(to target: Int) {
            var k = cursor
            while k < min(target, total) {
                let c = ns.character(at: k)
                if c == 0x7B { depth += 1 } else if c == 0x7D { depth -= 1 }
                k += 1
            }
            cursor = max(cursor, min(target, total))
        }
        let events = matches(declRE, in: code).map { ($0, true) } + matches(memberRE, in: code).map { ($0, false) }
        for (m, isTypeEvent) in events.sorted(by: { $0.0.range.location < $1.0.range.location }) {
            advance(to: m.range.location)
            let d = depth
            while let last = scopes.last, last.depth >= d { scopes.removeLast() }
            if isTypeEvent {
                let keyword = ns.substring(with: m.range(at: 1))
                let dotted = ns.substring(with: m.range(at: 2))
                let base = String(dotted.split(separator: ".").last ?? Substring(dotted))
                if keyword == "extension" {
                    a.extensions.insert(base)
                } else if d <= 1 {
                    // 函数体（深度 ≥ 2）里声明的类型外部不可达，不当候选证据
                    a.types.insert(base)
                }
                guard d <= 1 else { continue }
                if d == 0, keyword != "extension" { a.topLevelTypes.insert(base) }
                scopes.append((d, base))
                a.owners.insert(base)
                continue
            }
            guard d == 1, let scope = scopes.first, scope.depth == 0 else { continue }
            let name = ns.substring(with: m.range(at: 2))
            guard name != scope.name else { continue }
            let key = OwnerMember(owner: scope.name, member: name)
            a.members.insert(key)
            a.owners.insert(scope.name)
            if prefixIsStatic(ns, declarationAt: m.range.location) { a.staticMembers.insert(key) }
        }
        return a
    }

    /// 声明关键字往前的那一段（到换行或左花括号为止）里有没有 `static` / `class func`——只有
    /// static 成员才可能被写成 `.member` 简写，判据 ④ 靠它把面收窄。
    private static func prefixIsStatic(_ ns: NSString, declarationAt loc: Int) -> Bool {
        var start = loc
        while start > 0 {
            let c = ns.character(at: start - 1)
            if c == 0x0A || c == 0x7B { break }
            start -= 1
        }
        return !matches(staticRE, in: ns.substring(with: NSRange(location: start, length: loc - start))).isEmpty
    }

    /// 倒排索引：搜索面只有实现文件。
    private static func buildIndex(_ docs: [RDoc], code: [String: String]) -> TokenIndex {
        var idx = TokenIndex()
        for doc in docs where doc.isProduction {
            guard let text = code[doc.relativePath] else { continue }
            let range = NSRange(location: 0, length: (text as NSString).length)
            for m in wordRE.matches(in: text, range: range) {
                idx.word[(text as NSString).substring(with: m.range), default: []].insert(doc.relativePath)
            }
            for m in dottedRE.matches(in: text, range: range) {
                let ns = text as NSString
                idx.qualified[ns.substring(with: m.range(at: 1)) + "." + ns.substring(with: m.range(at: 2)),
                              default: []].insert(doc.relativePath)
            }
            for m in leadingDotRE.matches(in: text, range: range) {
                idx.dot[(text as NSString).substring(with: m.range(at: 1)), default: []].insert(doc.relativePath)
            }
        }
        return idx
    }

    // MARK: - 可达性判定（纯函数：喂合成文档就能验，不碰磁盘）

    private static func declaredOnlyIn<T: Hashable>(_ index: [T: Set<String>], _ key: T, _ path: String) -> Bool {
        guard let set = index[key] else { return false }
        return set.count == 1 && set.contains(path)
    }

    /// 多条证据时挑最能说明问题的一条：优先指向**声明该类型的那个文件**（真正的派发点）。
    private static func bestHit(_ hits: [String], preferring owner: String,
                                analyses: [String: RAnalysis]) -> String? {
        guard let first = hits.min() else { return nil }
        return hits.filter { $0 != first }.first { analyses[$0]?.types.contains(owner) == true } ?? first
    }
    static func buildOutcome(_ docs: [RDoc], whitelist: Set<String>) -> ScanOutcome {
        var code: [String: String] = [:]
        var analyses: [String: RAnalysis] = [:]
        var out = ScanOutcome()
        for doc in docs {
            let stripped = strippingNoise(doc.raw)
            code[doc.relativePath] = stripped
            analyses[doc.relativePath] = analyzeOne(stripped)
            if doc.isProduction, stripped != doc.raw { out.strippedFileCount += 1 }
        }
        // 唯一性在 Sources + Tests 全集上算
        var typeDeclarers: [String: Set<String>] = [:]
        var memberDeclarers: [OwnerMember: Set<String>] = [:]
        for doc in docs {
            guard let a = analyses[doc.relativePath] else { continue }
            for t in a.types { typeDeclarers[t, default: []].insert(doc.relativePath) }
            for m in a.members { memberDeclarers[m, default: []].insert(doc.relativePath) }
        }
        let production = docs.filter { $0.isProduction }.sorted { $0.relativePath < $1.relativePath }
        out.productionFiles = production.map(\.relativePath)
        out.testFileCount = docs.count - production.count
        let index = buildIndex(docs, code: code)

        for doc in production {
            guard let a = analyses[doc.relativePath] else { continue }
            let path = doc.relativePath
            var list: [Evidence] = []
            for t in a.types.sorted() {
                guard declaredOnlyIn(typeDeclarers, t, path) else { continue }
                out.candidateCount += 1
                let hits = Array((index.word[t] ?? []).filter { $0 != path })
                if let w = bestHit(hits, preferring: t, analyses: analyses) {
                    list.append(Evidence(rule: .uniqueType, symbol: t, witness: w))
                }
            }
            for key in a.members.sorted() {
                guard declaredOnlyIn(memberDeclarers, key, path) else { continue }
                out.candidateCount += 1
                let sym = "\(key.owner).\(key.member)"
                let qualifiedHits = Array((index.qualified[sym] ?? []).filter { $0 != path })
                if let w = bestHit(qualifiedHits, preferring: key.owner, analyses: analyses) {
                    list.append(Evidence(rule: .qualified, symbol: sym, witness: w))
                }
                // 派发点：另一文件自己拥有 Owner 作用域，并整词提到该成员名
                let dispatchHits = Array((index.word[key.member] ?? []).filter { other in
                    other != path && analyses[other]?.owners.contains(key.owner) == true
                })
                if let w = bestHit(dispatchHits, preferring: key.owner, analyses: analyses) {
                    list.append(Evidence(rule: .dispatcher, symbol: sym, witness: w))
                }
                guard a.staticMembers.contains(key) else { continue }
                // 取词式必须带前导限制，否则 `NSWorkspace.shared` 会被当成前导点简写、
                // 白送证据（真漏过一次）。完整说明与两条元测试见
                // `SourceFileReachabilityMetaTests.swift`。
                // 元测试：`testStaticShorthandNeedsTheOwnerInScope` + `testLeadingDotRegexRequiresABareDot`。
                let dotHits = Array((index.dot[key.member] ?? []).filter { $0 != path })
                if let w = bestHit(dotHits, preferring: key.owner, analyses: analyses) {
                    list.append(Evidence(rule: .staticShorthand, symbol: sym, witness: w))
                }
            }
            out.evidence[path] = list
        }
        for path in out.productionFiles {
            let list = out.evidence[path] ?? []
            if whitelist.contains(path) { out.whitelisted.append(path) }
            else if list.isEmpty { out.unused.append(path) }
            else {
                out.inUse.append(path)
                for e in list { out.ruleTally[e.rule, default: 0] += 1 }
            }
        }
        return out
    }

    /// 判定门口：真跑那一轮与合成夹具走的是**同一份**代码。
    /// 分母为 0 一律判失败——「没扫到东西」绝不能等于「交付干净」。
    static func gate(_ out: ScanOutcome, whitelist: Set<String>) -> Gate {
        var reasons: [String] = []
        if out.productionFiles.isEmpty {
            reasons.append("分母为 0：一个实现文件都没扫到。这是扫描器坏了，不是代码干净。")
        } else if out.productionFiles.count < 100 {
            reasons.append("分母 \(out.productionFiles.count) 远低于普查基线 \(censusBaseline)：路径解析静默失效。")
        }
        if !out.unused.isEmpty {
            reasons.append("零调用实现文件 \(out.unused.count) 个：\n"
                + out.unused.map { "  \($0)" }.joined(separator: "\n"))
        }
        let stale = whitelist.subtracting(out.productionFiles)
        if !stale.isEmpty { reasons.append("白名单条目已不在扫描面上，必须删掉：\(stale.sorted())") }
        let identity = out.inUse.count + out.unused.count + out.whitelisted.count
        if identity != out.productionFiles.count {
            reasons.append("守恒破了：在用 \(out.inUse.count) + 未用 \(out.unused.count)"
                + " + 白名单 \(out.whitelisted.count) = \(identity) ≠ 分母 \(out.productionFiles.count)")
        }
        return Gate(reasons: reasons)
    }

    // MARK: - 取数：真实仓库 / 合成夹具

    private func swiftFiles(under dir: URL) throws -> [URL] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
        var collected: [URL] = []
        let children = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [])
        for url in children.sorted(by: { $0.path < $1.path }) {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isDirectory == true {
                if !Self.prunedDirectories.contains(url.lastPathComponent) { collected.append(contentsOf: try swiftFiles(under: url)) }
            } else if values.isRegularFile == true, url.pathExtension == "swift" {
                collected.append(url)
            }
        }
        return collected
    }

    private func realDocs() throws -> [RDoc] {
        let fm = FileManager.default
        var docs: [RDoc] = []
        let faces: [(URL, Bool)] = [(Self.repoRoot.appendingPathComponent(Self.sourceDirName), true),
                                    (Self.repoRoot.appendingPathComponent(Self.testDirName), false)]
        for (dir, isProduction) in faces {
            XCTAssertTrue(fm.fileExists(atPath: dir.path), "扫描面目录不存在：\(dir.path) —— 仓库根解析失效")
            for url in try swiftFiles(under: dir) {
                guard let data = fm.contents(atPath: url.path), let text = String(data: data, encoding: .utf8) else {
                    XCTFail("读不到文件：\(url.path)")
                    continue
                }
                let relative = url.path.hasPrefix(dir.path)
                    ? String(url.path.dropFirst(dir.path.count + 1)) : url.lastPathComponent
                docs.append(RDoc(relativePath: relative, raw: text, isProduction: isProduction))
            }
        }
        return docs
    }

    private func realOutcome() throws -> (docs: [RDoc], out: ScanOutcome) {
        let docs = try realDocs()
        return (docs, Self.buildOutcome(docs, whitelist: Self.frameworkWhitelist))
    }

    func synth(_ items: [(String, String, Bool)]) -> [RDoc] {
        items.map { RDoc(relativePath: $0.0, raw: $0.1, isProduction: $0.2) } }

    private func firstEvidence(_ out: ScanOutcome, _ path: String) -> String {
        guard let e = (out.evidence[path] ?? []).first else { return "零证据" }
        return "\(e.rule.rawValue) \(e.symbol) ← \(e.witness)"
    }

    private static func ruleTallyText(_ tally: [Rule: Int]) -> String {
        Rule.allCases.map { "\($0.rawValue) \(tally[$0] ?? 0)" }.joined(separator: " · ")
    }

    // MARK: - 主门：每个实现文件逐个要有外部调用证据（分母见 censusBaseline）

    func testEveryImplementationFileHasExternalCallEvidence() throws {
        let (docs, out) = try realOutcome()
        let g = Self.gate(out, whitelist: Self.frameworkWhitelist)
        XCTAssertTrue(g.pass, g.reasons.joined(separator: "\n"))
        XCTAssertEqual(out.productionFiles.count, docs.filter { $0.isProduction }.count, "分母与扫描面不一致")
        XCTAssertGreaterThan(out.productionFiles.count, 100, "分母必须 > 100（普查基线见 censusBaseline）")
        XCTAssertGreaterThan(out.testFileCount, 50, "测试面也没扫到 → 目录解析八成是坏的")
        XCTAssertEqual(out.inUse.count + out.unused.count + out.whitelisted.count, out.productionFiles.count,
                       "在用 + 未用 + 白名单 必须等于分母，不许有没归类的文件")
        XCTAssertGreaterThan(out.strippedFileCount, out.productionFiles.count * 3 / 4,
                             "多数文件脱敏后文本没变化 → 脱敏器可能空转")
        var report: [String] = []
        report.append("【WS-U 可达性守卫】实现文件 \(out.productionFiles.count) 个"
            + "（普查基线 \(Self.censusBaseline)）；测试文件 \(out.testFileCount) 个参与唯一性计算")
        report.append("  在用 \(out.inUse.count) · 未用 \(out.unused.count)"
            + " · 白名单 \(out.whitelisted.count)（\(Self.frameworkWhitelist.sorted().joined(separator: ", "))）")
        report.append("  全仓唯一声明的候选符号 \(out.candidateCount) 个；证据条数按判据："
            + Self.ruleTallyText(out.ruleTally))
        report.append("  剥掉注释与字符串后文本发生变化的实现文件："
            + "\(out.strippedFileCount)/\(out.productionFiles.count)")
        report.append("  白名单自身证据：" + out.whitelisted
            .map { "\($0) → \(self.firstEvidence(out, $0))" }.joined(separator: " ; "))
        report.append("  零调用清单：" + (out.unused.isEmpty ? "无" : out.unused.joined(separator: ", ")))
        print(report.joined(separator: "\n"))
    }

    // MARK: - 元测试 1：合成死文件必须被抓出来（守卫抓得住坏例）

    func testSyntheticOrphanFileIsJudgedUncalled() {
        // 名字全部全仓唯一，刻意避开 `Layout` / `crashExtensions` 这类碰撞名。
        let orphan = """
        import Foundation
        struct WSUProbeOrphanWidget {
            static let wsuProbeOrphanThreshold = 7
            func wsuProbeOrphanBody() -> Int { Self.wsuProbeOrphanThreshold }
        }
        """
        let consumer = """
        import Foundation
        enum WSUProbeConsumer {
            static func wsuProbeConsume() -> Int { wsuProbeAgain() + WSUProbeOtherKind.wsuProbeMadeValue }
        }
        struct WSUProbeOtherKind {
            static let wsuProbeMadeValue = 3
        }
        """
        // 分片式扩展：自己不声明类型，只靠「同作用域派发」活着（真仓里十几个分片全靠这条）
        let support = """
        import Foundation
        extension WSUProbeConsumer {
            static func wsuProbeAgain() -> Int { WSUProbeOtherKind.wsuProbeMadeValue }
        }
        """
        let out = Self.buildOutcome(synth([("WSUProbeOrphanWidget.swift", orphan, true),
                                           ("WSUProbeConsumer.swift", consumer, true),
                                           ("WSUProbeSupport.swift", support, true)]), whitelist: [])
        XCTAssertEqual(out.unused, ["WSUProbeOrphanWidget.swift"],
                       "零调用文件没被抓到，守卫就是空的（在用：\(out.inUse)）")
        XCTAssertEqual(out.inUse.sorted(), ["WSUProbeConsumer.swift", "WSUProbeSupport.swift"],
                       "把在用的合成文件一起判死，等于守卫放倒好例")
        XCTAssertTrue((out.evidence["WSUProbeOrphanWidget.swift"] ?? []).isEmpty, "死文件不许拿到任何证据")
        let g = Self.gate(out, whitelist: [])
        XCTAssertFalse(g.pass, "有未用文件时判定门必须失败")
        XCTAssertTrue(g.reasons.joined().contains("零调用实现文件 1 个"), "失败理由要点名：\(g.reasons)")
        XCTAssertTrue(g.reasons.joined().contains("WSUProbeOrphanWidget"), "失败理由要点到文件：\(g.reasons)")
    }

    // MARK: - 元测试 2：扩展分片不得被误杀（守卫不放倒好例）

    func testExtensionShardFilesAreAllJudgedInUse() throws {
        let (docs, out) = try realOutcome()
        let analyses = docs.filter { $0.isProduction }.reduce(into: [String: RAnalysis]()) { acc, doc in
            acc[doc.relativePath] = Self.analyzeOne(Self.strippingNoise(doc.raw))
        }
        let shards = out.productionFiles.filter { path -> Bool in
            guard let a = analyses[path] else { return false }
            return a.topLevelTypes.isEmpty && !a.extensions.isEmpty
        }
        XCTAssertGreaterThanOrEqual(shards.count, 13,
                                    "不声明顶层类型的分片只剩 \(shards.count) 个（普查 13 个）—— 发现逻辑退化了")
        for named in Self.namedShardFiles {
            XCTAssertTrue(shards.contains(named), "普查点名的分片 \(named) 没被发现（类型/扩展解析变了）")
        }
        let killed = shards.filter { out.unused.contains($0) }
        XCTAssertTrue(killed.isEmpty, "扩展分片被误判成死码：\(killed)")
        let report = shards.map { path -> String in
            let exts = (analyses[path]?.extensions ?? []).sorted().joined(separator: ",")
            return "  \(path) [extension \(exts)] → \(self.firstEvidence(out, path))"
                + "（共 \((out.evidence[path] ?? []).count) 条）"
        }
        print("【WS-U 分片专项】不声明顶层类型的分片文件 \(shards.count) 个，逐个判在用，误杀 \(killed.count) 个：\n"
            + report.joined(separator: "\n"))
    }

    // MARK: - 元测试 4：脱敏真的起作用

    func testCommentsAndStringsDoNotForgeReferenceEvidence() {
        let orphan = """
        import Foundation
        struct WSUCommentOrphanType {
            static let wsuCommentOrphanField = 1
        }
        """
        let commenter = """
        import Foundation
        // WSUCommentOrphanType 在这里被提到，不算引用
        /* 块注释里再写一次 WSUCommentOrphanType
           嵌套 /* 还有 WSUCommentOrphanType */ */
        enum WSUCommenter {
            static let wsuNote = "WSUCommentOrphanType 只是个字符串"
            static func wsuUseControl() -> Int { WSUCommentControl.wsuControlValue }
        }
        """
        // 对照组：真代码互引，必须判在用（否则分不清「脱敏生效」与「脱敏器把一切都判死」）
        let control = """
        import Foundation
        struct WSUCommentControl {
            static let wsuControlValue = 5
            static let wsuEcho = WSUCommenter.wsuNote
        }
        """
        let out = Self.buildOutcome(synth([("WSUCommentOrphan.swift", orphan, true),
                                           ("WSUCommenter.swift", commenter, true),
                                           ("WSUCommentControl.swift", control, true)]), whitelist: [])
        XCTAssertEqual(out.unused, ["WSUCommentOrphan.swift"],
                       "注释/字符串里的名字被当成了引用 → 死码被洗活（在用：\(out.inUse)）")
        XCTAssertEqual(out.inUse.sorted(), ["WSUCommentControl.swift", "WSUCommenter.swift"],
                       "真互引的对照组没判在用：\(out.inUse)")
    }

    func testInterpolationInsideStringStillCountsAsCode() {
        // 反面：插值表达式里的引用是真的，脱敏器不能连它一起吞掉。
        // `WSUInterpTarget` 在语料里只出现在另一文件的插值里，它判活才说明插值被保住了。
        let target = """
        import Foundation
        struct WSUInterpTarget {
            static let wsuInterpValue = 2
            static let wsuMirror = WSUInterpUser.wsuInterpSeed
        }
        """
        let user = """
        import Foundation
        enum WSUInterpUser {
            static let wsuInterpSeed = 1
            static func line() -> String { "\\(WSUInterpTarget.wsuInterpValue) 项" }
        }
        """
        let out = Self.buildOutcome(synth([("WSUInterpTarget.swift", target, true),
                                           ("WSUInterpUser.swift", user, true)]), whitelist: [])
        XCTAssertTrue(out.inUse.contains("WSUInterpTarget.swift"),
                      "插值里的引用被吞掉，会把好文件判死：未用清单 \(out.unused)")
        XCTAssertEqual(out.unused, [])
    }

    func testStrippingHandlesEachNoiseShapeAndChangesRealFiles() throws {
        let fixtures = [("let a = 1 // commentTokenHere", "commentTokenHere", "let a = 1"),
                        ("let a = /* blockTokenHere */ 1", "blockTokenHere", "let a ="),
                        ("let n = /* out /* inTokenHere */ out */ 2", "inTokenHere", "let n ="),
                        ("let s = \"quotedTokenHere\" + y", "quotedTokenHere", "+ y"),
                        ("let r = #\"raw\"TokenHere\"# + z", "TokenHere", "+ z"),
                        ("let e = \"escaped \\\" TokenHere\" + w", "TokenHere", "+ w"),
                        ("let m = \"\"\"\n  multiTokenHere\n  \"\"\"\n", "multiTokenHere", "let m =")]
        for fixture in fixtures { assertNoiseGone(fixture.0, noise: fixture.1, code: fixture.2) }
        XCTAssertTrue(Self.strippingNoise("let s = \"\\(RealName.field)\"").contains("RealName.field"),
                      "插值表达式必须保留为代码")
        let production = try realDocs().filter { $0.isProduction }
        let changed = production.filter { Self.strippingNoise($0.raw) != $0.raw }
        XCTAssertGreaterThan(changed.count, production.count * 3 / 4,
                             "\(production.count) 个实现文件里只有 \(changed.count) 个脱敏后变化 —— 脱敏器空转")
        print("【WS-U 脱敏自证】剥掉注释与字符串后文本发生变化：\(changed.count)/\(production.count) 个实现文件")
    }

    private func assertNoiseGone(_ raw: String, noise: String, code: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let stripped = Self.strippingNoise(raw)
        XCTAssertEqual(stripped.count, raw.count, "脱敏必须等长（行号不能漂）：\(raw)", file: file, line: line)
        XCTAssertFalse(stripped.contains(noise), "噪声没被剥掉：[\(stripped)]", file: file, line: line)
        XCTAssertTrue(stripped.contains(code), "代码被误剥：[\(stripped)]", file: file, line: line)
    }

    // MARK: - 元测试 5：名字碰撞不能把死文件洗活

    func testCollisionNamesAreNotAcceptedAsEvidence() throws {
        let (docs, out) = try realOutcome()
        // 独立口径（行式正则，不借引擎的深度分析）数一遍每个类型名的声明点
        var sitesByName: [String: Set<String>] = [:]
        for doc in docs {
            for line in Self.strippingNoise(doc.raw).components(separatedBy: "\n") {
                for m in Self.matches(Self.independentTypeSiteRE, in: line) {
                    sitesByName[(line as NSString).substring(with: m.range(at: 1)), default: []].insert(doc.relativePath)
                }
            }
        }
        let colliding = sitesByName.filter { $0.value.count >= 2 }
        XCTAssertGreaterThan(sitesByName.count, 300,
                             "独立口径只数到 \(sitesByName.count) 个类型声明名——行式正则八成空转了")
        let laundered = out.productionFiles.flatMap { path -> [String] in
            (out.evidence[path] ?? []).compactMap { e in
                guard e.rule == .uniqueType else { return nil }
                let sites = sitesByName[e.symbol] ?? []
                return sites.count > 1 ? "\(path) 用 \(e.symbol)（独立口径声明点 \(sites.sorted())）" : nil
            }
        }
        XCTAssertTrue(laundered.isEmpty, "碰撞名被当成「全仓唯一声明」证据：\n\(laundered.joined(separator: "\n"))")
        // 真正的碰撞面在**成员名**上：普查点名的 `crashExtensions` 由两个文件各声明一次。
        // 判据 ②③④ 要求 `(Owner, member)` 成对唯一，所以裸成员名相同的两个持有者都得另找证据。
        var memberSites: [String: Set<String>] = [:]
        for doc in docs where doc.isProduction {
            for m in Self.analyzeOne(Self.strippingNoise(doc.raw)).members {
                memberSites[m.member, default: []].insert(doc.relativePath)
            }
        }
        XCTAssertGreaterThanOrEqual(memberSites.filter { $0.value.count >= 2 }.count, 10,
                                    "成员名碰撞只剩 \(memberSites.filter { $0.value.count >= 2 }.count) 个，"
                                    + "与普查（crashExtensions 这类至少两处）不符")
        XCTAssertTrue((memberSites["crashExtensions"] ?? []).count >= 2,
                      "普查点名的 crashExtensions 不再碰撞：\(memberSites["crashExtensions"] ?? [])")
        // 普查点名的两个持有者都不许靠裸名洗白
        for owner in ["Services/Logs/CrashReportPatterns.swift", "Services/Logs/LogDiscovery.swift"] {
            XCTAssertTrue(out.productionFiles.contains(owner), "扫描面里没有 \(owner)，普查口径变了")
            let bare = (out.evidence[owner] ?? []).filter { $0.rule == .uniqueType && $0.symbol == "crashExtensions" }
            XCTAssertTrue(bare.isEmpty, "\(owner) 靠裸名 crashExtensions 洗白：\(bare)")
        }
        print("【WS-U 碰撞点名】独立口径类型名 \(sitesByName.count) 个，其中同名 \(colliding.count) 个；"
            + "成员名碰撞 \(memberSites.filter { $0.value.count >= 2 }.count) 个（crashExtensions 声明点 "
            + "\((memberSites["crashExtensions"] ?? []).sorted().joined(separator: ", "))）")
        // 合成坏例：两个实现文件都声明 `WSUDuplicateLayout`，第三个其实是死文件。
        // 朴素 `grep -w` 会因为第一个文件里的出现把它判活；唯一性索引必须判死。
        let collide = Self.buildOutcome(synth([
            ("WSUReal.swift", "struct WSUDuplicateLayout { let wsuRealField = WSUUser.go() }", true),
            ("WSUUser.swift", "enum WSUUser { static func go() -> Int { _ = WSUDuplicateLayout.wsuRealField; return 1 } }", true),
            ("WSUDead.swift", "struct WSUDuplicateLayout { static let wsuDeadField = 9 }", true)]), whitelist: [])
        XCTAssertEqual(collide.unused, ["WSUDead.swift"], "碰撞名把死文件洗活了，守卫就白写：\(collide.unused)")
        XCTAssertEqual(collide.inUse.sorted(), ["WSUReal.swift", "WSUUser.swift"],
                       "对照组（碰撞名的另一持有者）没判在用：\(collide.inUse)")
    }

    // MARK: - 元测试 6：白名单必须自己站得住（且不许环境门控）

    func testWhitelistIsSmallJustifiedAndNotHidingADeadFile() throws {
        let (docs, out) = try realOutcome()
        XCTAssertEqual(out.whitelisted, Self.frameworkWhitelist.sorted(), "白名单条目必须都还在扫描面上")
        XCTAssertLessThanOrEqual(Self.frameworkWhitelist.count, 3, "白名单一长就该重新审：\(Self.frameworkWhitelist)")
        let raws = docs.reduce(into: [String: String]()) { $0[$1.relativePath] = $1.raw }
        for entry in Self.frameworkWhitelist {
            XCTAssertTrue(raws[entry]?.contains("@main") == true,
                          "白名单条目 \(entry) 正文里没有 @main，「框架隐式调度」这条理由不成立")
            XCTAssertFalse((out.evidence[entry] ?? []).isEmpty,
                           "白名单文件 \(entry) 其实零证据：它现在是死码，白名单不许替它兜着")
        }
        // 本守卫每轮默认跑到：不许出现「没设环境变量就 skip」的绿灯。探测词用拼接写——
        // 写成一整串会被本文件自身命中，断言就自缚了。
        let own = try String(contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8)
        for needle in ["XCT" + "Skip", "Process" + "Info", "get" + "env", "environ" + "ment"] {
            XCTAssertFalse(own.contains(needle), "守卫正文里出现了 \(needle)：门控绿灯就是没在跑的绿灯")
        }
        print("【WS-U 白名单】" + out.whitelisted.map { "\($0) → \(self.firstEvidence(out, $0))" }
            .joined(separator: " ; ") + "；无环境门控，每轮默认跑到")
    }

    // MARK: - 元测试 7：靠弱判据活着的文件必须被点名（守卫不许悄悄变松）

    func testFilesAliveOnlyByWeakerEvidenceAreNamedExplicitly() throws {
        let (_, out) = try realOutcome()
        let weakFirst = out.inUse.filter { path in
            guard let first = (out.evidence[path] ?? []).first else { return false }
            return first.rule == .dispatcher || first.rule == .staticShorthand
        }
        let roster = weakFirst.map { "  \($0) → \(self.firstEvidence(out, $0))" }.joined(separator: "\n")
        XCTAssertLessThan(weakFirst.count, 25,
                          "首条证据来自弱判据（③派发/④static简写）的文件有 \(weakFirst.count) 个，超过普查观测面。"
                          + "守卫在悄悄变松，先复核判据再谈改这个数：\n\(roster)")
        print("【WS-U 弱证据点名】在用 \(out.inUse.count) 个，其中首条证据是 ③派发/④static简写 的 "
            + "\(weakFirst.count) 个：\n\(roster)")
        XCTAssertTrue(out.unused.isEmpty, "未用文件：\(out.unused)")
    }

    // MARK: - 元测试 8：分母与普查基线对齐（也防 filter 名字写错的永真绿）

    func testDenominatorMatchesCensusBaseline() throws {
        let (_, out) = try realOutcome()
        XCTAssertEqual(out.productionFiles.count, Self.censusBaseline,
                       "分母从 \(Self.censusBaseline) 变了：先分清是新增实现文件（那就该有引用）还是扫描面坏了")
        XCTAssertTrue(out.unused.isEmpty, "未用文件：\(out.unused)")
    }
}
