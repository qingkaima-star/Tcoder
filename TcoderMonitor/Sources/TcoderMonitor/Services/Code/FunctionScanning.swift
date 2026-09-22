import Foundation

// OWNER: R2 (Vue / TS 识别与模板字符串) —— 函数识别这一条链路的扫描端。
//
// 从 `ComplexityEngine.swift` 整块搬来（本流本轮写的代码，逐字节搬动，判定一字未改），
// 只为守住 `SourcesSizeAuditTests` 的 400 行闸门。搬动之后：
//   * `ComplexityEngine.swift` 留「模型 + 阈值 + 圈复杂度 + 参数计数」；
//   * 本文件留「入口 API（`functions(in:)` / `functionsWithIntegrity(in:)`）+ 逐行扫描 `Scan`」。
// 新代码不再往 `ComplexityEngine.swift` 里塞：那文件已经有两拨人在改。

extension ComplexityEngine {

    // MARK: API

    /// 从单个文件识别函数并算复杂度；无法识别的语言返回 []。
    static func functions(in file: ScannedSourceFile) -> [FunctionCandidate] {
        functionsWithIntegrity(in: file).candidates
    }

    /// 与 `functions(in:)` 同一次扫描，额外带回完整性读数。**这是 R2 之后的唯一真入口**，
    /// `functions(in:)` 只是它的投影（既有条目与既有单测都还在按老形状调它）。
    static func functionsWithIntegrity(in file: ScannedSourceFile) -> FunctionScanOutcome {
        let profile = profile(for: file.language)
        guard profile.family != .none, !profile.patterns.isEmpty else { return FunctionScanOutcome() }
        let raw = file.lines.map { $0.text }
        guard !raw.isEmpty else { return FunctionScanOutcome() }

        // RD-07：`.vue` 一份文件住着三种语言。逐行给档案 —— 脚本区按它自己声明的 lang 清洗，
        // 模板 / 样式区整行不进代码统计（内联箭头因此进不了榜，也不再能污染词法状态机）。
        var profiles = Array<LangProfile?>(repeating: profile, count: raw.count)
        var scanProfile = profile
        var mask: [Bool]?
        var outcome = FunctionScanOutcome(codeRegionLineCount: raw.count)
        if profile.scriptRegionOnly, let map = detectVueRegions(raw) {
            let scriptProfile = ComplexityEngine.profile(for: map.scriptLanguage)
            for index in raw.indices {
                let isScript = map.regions[index] == .script
                profiles[index] = isScript ? scriptProfile : nil
            }
            scanProfile = scriptProfile
            mask = map.scriptMask
            outcome.codeRegionLineCount = map.scriptLineCount()
        } else if profile.scriptRegionOnly {
            // 分区认不出来：退回 HEAD 的 `<script` 粗判，**并且把这一格如实说出来**，
            // 而不是悄悄按「没有模板区」处理。
            outcome.vueRegionFallback = true
            mask = computeScriptMask(raw)
        }

        let src = sanitize(raw, profiles: profiles)
        var integrity = src.integrity
        if outcome.vueRegionFallback { integrity.regionFallback = true }
        var scan = Scan(src: src, profile: scanProfile, scriptMask: mask)
        outcome.candidates = scan.run()
        outcome.unboundedSignatureCount = scan.unboundedCount
        outcome.nestedDepthTruncatedCount = scan.depthTruncatedCount
        outcome.integrity = integrity
        return outcome
    }

    /// 逐行「找签名 → 定边界 → 产出候选」的扫描，并对**嵌套具名函数**递归下一层。
    ///
    /// **口径（RD-08，本条目的落点）**：一条条目 = 一个具名函数；
    /// `complexity` 只算**它自己那部分体**（直接嵌套的子函数体已经按行挖掉），
    /// `lineCount` 是它在文件里的跨度（含嵌套体，那是"这个函数写多长"的口径），
    /// `nestedFunctionCount` 告诉你它里面还包了几个单列的子函数。
    ///
    /// HEAD 的形状是：命中签名之后 `line = endLine + 1` **跳过整个函数体**，
    /// 内层具名函数因此**从没产生过条目**，而外层的 `complexity(ofCleanedLines: line...endLine)`
    /// 把内层的 `if` 一起算了进去 —— 榜上一个数字撑两层人，名字却是外层那个。
    /// （工单里写的「内层条目被 `covered` 集合剔掉」在本仓 HEAD 查无此物：
    /// `grep -rn covered Sources/TcoderMonitor/Services/Code/` 是 0 命中。修的是同一个病，
    /// 机制按原文写清楚。）
    ///
    /// 递归深度上限见 `maxNestedFunctionScanDepth`：更深的嵌套不再展开，其判定并入直接外层，
    /// 这一格通过 `FunctionScanOutcome.nestedDepthTruncatedCount` 如实出声，不许静默。
    struct Scan {
        let src: SanitizedSource
        let profile: LangProfile
        let scriptMask: [Bool]?
        var result: [FunctionCandidate] = []
        var line = 0
        /// 命中签名但边界推不出来的次数（出声用；见 `FunctionScanOutcome.unboundedSignatureCount`）
        var unboundedCount = 0
        /// 因超过递归深度而没有继续下钻的函数体数（出声用）
        var depthTruncatedCount = 0
        var collectedNodeCount = 0

        /// 一段函数体与它的直接子函数。子节点先collect，父节点才知道要挖掉哪些行。
        struct Node {
            var name: String
            var start: Int
            var signatureEnd: Int
            var end: Int
            var children: [Node] = []
        }

        mutating func run() -> [FunctionCandidate] {
            let roots = collect(from: 0, to: src.cleaned.count - 1, depth: 0)
            for root in roots { flatten(root) }
            return result
        }

        /// 在 `[from, to]` 这段行区间里找函数签名，命中之后对体内递归。
        mutating func collect(from: Int, to: Int, depth: Int) -> [Node] {
            var found: [Node] = []
            var cursor = from
            while cursor <= to {
                if collectedNodeCount >= ComplexityEngine.maxCandidatesPerFile { break }
                line = cursor
                guard let match = signatureStartingHere() else { cursor += 1; continue }
                var node = Node(name: match.name, start: cursor, signatureEnd: match.signatureEnd,
                                end: match.endLine)
                if match.endLine > cursor {
                    if depth >= ComplexityEngine.maxNestedFunctionScanDepth {
                        depthTruncatedCount += 1
                    } else {
                        node.children = collect(from: cursor + 1, to: match.endLine - 1, depth: depth + 1)
                    }
                }
                let span = match.endLine - cursor + 1
                collectedNodeCount += 1
                if span >= ComplexityEngine.minFunctionLines, span <= ComplexityEngine.maxFunctionLines {
                    found.append(node)
                } else {
                    // 外层不合格（太短 / 太长）时**子函数不许跟着一起消失**
                    found.append(contentsOf: node.children)
                }
                cursor = match.endLine + 1
            }
            return found
        }

        /// 本行是不是一个函数签名的开头；是的话给出签名行、签名结束行与闭合行。
        mutating func signatureStartingHere() -> (name: String, signatureEnd: Int, endLine: Int)? {
            guard let name = signatureNameHere() else { return nil }
            let boundary = bodyBoundary()
            guard let endLine = boundary.closing else {
                // **放弃了要留名**：以前这里只是 return nil，扫描线前进一行继续，
                // 于是一个边界推不出来的函数在报告里与「这行不是函数」完全一样。
                unboundedCount += 1
                return nil
            }
            // 防御：签名行绝不能越过闭合行，否则下面的 line...signatureEnd 区间会当场 trap
            var signatureEnd = boundary.signatureEnd
            if signatureEnd > endLine { signatureEnd = endLine }
            return (name, signatureEnd, endLine)
        }

        /// 先父后子地展开成候选清单（顺序：外层在前，其内层紧跟其后）。
        mutating func flatten(_ node: Node) {
            let signature = src.cleaned[node.start...node.signatureEnd].joined(separator: " ")
            result.append(FunctionCandidate(
                name: node.name,
                startLine: node.start + 1,
                lineCount: node.end - node.start + 1,
                parameterCount: ComplexityEngine.parameterCount(from: signature),
                complexity: ComplexityEngine.complexity(ofCleanedLines: ownLines(of: node), profile: profile),
                nestedFunctionCount: node.children.count
            ))
            for child in node.children { flatten(child) }
        }

        /// 本函数**自己那部分体**：整个跨度里按行挖掉直接子函数的跨度。
        func ownLines(of node: Node) -> [String] {
            var lines: [String] = []
            var cursor = node.start
            for child in node.children where child.end >= cursor {
                if child.start > cursor { lines.append(contentsOf: src.cleaned[cursor..<child.start]) }
                cursor = child.end + 1
            }
            if cursor <= node.end { lines.append(contentsOf: src.cleaned[cursor...node.end]) }
            return lines
        }

        /// 四道廉价闸门 + 签名正则，先便宜后贵，顺序与原实现一致。
        func signatureNameHere() -> String? {
            if line > 0, !src.balancedBefore[line - 1] { return nil }
            if let mask = scriptMask, !mask[line] { return nil }
            let cleanedLine = src.cleaned[line]
            // utf8.count 对原生 Swift String 是 O(1)，utf16.count 会触发转码；这里只是长度门槛
            guard !cleanedLine.isEmpty, cleanedLine.utf8.count <= ComplexityEngine.maxLineLengthForMatch else {
                return nil
            }
            // 廉价预筛：绝大多数语言的签名都必须带 `(`，先挡掉就不必为每行进 NSString/正则循环
            if profile.parenOnEveryPattern, cleanedLine.contains("(") == false { return nil }
            guard let name = ComplexityEngine.matchSignature(cleanedLine, profile) else { return nil }
            // RD-38：这里原先有**第二处**名字过滤（`isReservedAfterPrefix`，
            // 由 R2 在"根因文件归 R1 名下、本流不得改"的处境下就地补的等价副本）。
            // 两份各自的绿会让人以为两种口径都对，而第三个改识别的人只会看到其中一个入口。
            // 现在唯一入口是 `FunctionRecognition.signatureName` → `isReservedSignatureName`，
            // 副本连同这句 guard 一起删除，语义（含"只剥一个前导点"）一字未改地搬了过去。
            return name
        }

        /// 签名命中之后定函数边界：花括号族 / 缩进族 / Ruby `end` 族各走各的。
        func bodyBoundary() -> (closing: Int?, signatureEnd: Int) {
            switch profile.family {
            case .curly, .shell:
                guard let span = ComplexityEngine.curlyEnd(start: line, src, profile) else { return (nil, line) }
                return (span.closing, span.brace)
            case .indentation:
                let signatureEnd = ComplexityEngine.multiLineSignatureEnd(start: line, src.cleaned,
                                                                         closingChars: [":"])
                return (ComplexityEngine.indentedEnd(start: line, signatureEnd: signatureEnd,
                                                     cleaned: src.cleaned), signatureEnd)
            case .rubyEnd:
                // Ruby 的边界靠同级 `end` 判定，不受跨行签名影响；这里只把签名行对齐，
                // 好让 `def foo(\n a,\n b\n)` 这种跨行参数表也数得出参数。
                let signatureEnd = ComplexityEngine.multiLineSignatureEnd(start: line, src.cleaned,
                                                                          closingChars: [")"])
                return (ComplexityEngine.rubyEnd(start: line, src.cleaned), signatureEnd)
            case .none:
                return (nil, line)
            }
        }
    }
}
