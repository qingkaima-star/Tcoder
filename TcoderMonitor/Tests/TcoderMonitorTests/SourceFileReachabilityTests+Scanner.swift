/// OWNER: WS-X3 TestSplit —— 自 SourceFileReachabilityTests.swift 拆出，取盘与脱敏机器：剥注释/字符串、词法解析、建索引、读文件（判据与基线表不在内）。用例本体未改，只是搬了家。
import XCTest

extension SourceFileReachabilityTests {

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

    static func blank(_ chars: inout [Character], _ from: Int, _ to: Int) {
        var k = max(0, from)
        while k < min(chars.count, to) { if chars[k] != "\n" { chars[k] = " " }; k += 1 }
    }

    /// 从 `open`（指向第一个引号）吃一个字面量，返回结束后的下标。支持 `#"…"#` 与三引号。
    static func eatString(_ chars: inout [Character], open: Int, hashes: Int) -> Int {
        let n = chars.count
        let quotes = leadingQuoteRun(chars, at: open, count: n)
        var i = open + quotes
        var literalStart = open
        while i < n {
            if let step = eatEscape(&chars, at: i, hashes: hashes, literalStart: literalStart, count: n) {
                if step.halts { return step.next }   // 插值括号没配平：剩下的全部涂白
                literalStart = step.literalStart
                i = step.next
                continue
            }
            if let len = stringTerminator(chars, at: i, hashes: hashes, triple: quotes == 3, count: n) {
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

    /// 原来内联在 `eatString` 里的三元：`"""` 起头算三引号，否则单引号。
    /// 嵌套函数在复杂度口径里算进宿主函数，所以这些判定各自成函数、判据逐字照搬。
    static func leadingQuoteRun(_ chars: [Character], at open: Int, count n: Int) -> Int {
        open + 2 < n && chars[open + 1] == "\"" && chars[open + 2] == "\"" ? 3 : 1
    }

    /// `\` + `hashes` 个 `#` 才算转义前缀。
    static func isRawEscape(_ chars: [Character], at j: Int, hashes: Int, count n: Int) -> Bool {
        guard chars[j] == "\\", j + 1 + hashes < n else { return false }
        var k = j + 1
        while k < j + 1 + hashes { if chars[k] != "#" { return false }; k += 1 }
        return true
    }

    /// 消费一段转义前缀；若紧随其后是 `(`，把插值表达式**当代码留下**并跨过它的括号。
    /// 返回 nil 表示这个位置根本不是转义。`halts` 为真时括号没配平（原样：涂白剩余并收在 n）。
    static func eatEscape(_ chars: inout [Character], at i: Int, hashes: Int,
                          literalStart: Int, count n: Int)
        -> (next: Int, literalStart: Int, halts: Bool)? {
        guard isRawEscape(chars, at: i, hashes: hashes, count: n) else { return nil }
        let p = i + 1 + hashes
        guard p < n, chars[p] == "(" else { return (p + 1, literalStart, false) }
        blank(&chars, literalStart, i)
        guard let close = matchingParen(&chars, atOpen: p) else {
            blank(&chars, literalStart, n)
            return (n, literalStart, true)
        }
        return (close + 1, close + 1, false)
    }

    /// 字符串定界符（`"` + `hashes` 个 `#`，三引号再要三个 `"`）；命中返回总长度。
    static func stringTerminator(_ chars: [Character], at j: Int, hashes: Int,
                                 triple: Bool, count n: Int) -> Int? {
        guard chars[j] == "\"" else { return nil }
        var k = j + 1
        var h = 0
        while h < hashes { guard k < n, chars[k] == "#" else { return nil }; k += 1; h += 1 }
        if triple {
            for _ in 0..<3 { guard k < n, chars[k] == "\"" else { return nil }; k += 1 }
        }
        return k - j
    }

    static func matchingParen(_ chars: inout [Character], atOpen: Int) -> Int? {
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

    static func matches(_ re: NSRegularExpression, in text: String) -> [NSTextCheckingResult] {
        re.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    /// 单文件：按花括号深度（逐字符推进，不按行——`struct A { let b = 1 }` 写成一行也要算对）
    /// 把声明分成类型（深度 ≤ 1）与类型作用域成员（深度恰为 1）。
    static func analyzeOne(_ code: String) -> RAnalysis {
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
    static func prefixIsStatic(_ ns: NSString, declarationAt loc: Int) -> Bool {
        var start = loc
        while start > 0 {
            let c = ns.character(at: start - 1)
            if c == 0x0A || c == 0x7B { break }
            start -= 1
        }
        return !matches(staticRE, in: ns.substring(with: NSRange(location: start, length: loc - start))).isEmpty
    }

    /// 倒排索引：搜索面只有实现文件。
    static func buildIndex(_ docs: [RDoc], code: [String: String]) -> TokenIndex {
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

    static func declaredOnlyIn<T: Hashable>(_ index: [T: Set<String>], _ key: T, _ path: String) -> Bool {
        guard let set = index[key] else { return false }
        return set.count == 1 && set.contains(path)
    }

    /// 多条证据时挑最能说明问题的一条：优先指向**声明该类型的那个文件**（真正的派发点）。
    static func bestHit(_ hits: [String], preferring owner: String,
                                analyses: [String: RAnalysis]) -> String? {
        guard let first = hits.min() else { return nil }
        return hits.filter { $0 != first }.first { analyses[$0]?.types.contains(owner) == true } ?? first
    }

    func swiftFiles(under dir: URL) throws -> [URL] {
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

    func realDocs() throws -> [RDoc] {
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

    func realOutcome() throws -> (docs: [RDoc], out: ScanOutcome) {
        let docs = try realDocs()
        return (docs, Self.buildOutcome(docs, whitelist: Self.frameworkWhitelist))
    }

    func synth(_ items: [(String, String, Bool)]) -> [RDoc] {
        items.map { RDoc(relativePath: $0.0, raw: $0.1, isProduction: $0.2) } }

    func firstEvidence(_ out: ScanOutcome, _ path: String) -> String {
        guard let e = (out.evidence[path] ?? []).first else { return "零证据" }
        return "\(e.rule.rawValue) \(e.symbol) ← \(e.witness)"
    }

    static func ruleTallyText(_ tally: [Rule: Int]) -> String {
        Rule.allCases.map { "\($0.rawValue) \(tally[$0] ?? 0)" }.joined(separator: " · ")
    }

}
