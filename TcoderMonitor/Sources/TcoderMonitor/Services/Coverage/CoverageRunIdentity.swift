import Foundation

//  R5b · RD-25 剩下那半：**「同一次运行」的判据**（R5 落了格式/模块/源码三格身份，
//  运行那一格当时是**从路径子串猜出来的归类**拼出来的 —— 见 `CoverageReportIdentity.derive`
//  原来那句 `runKey: "module=…|kind=…"`，而 `kind` 来自 `CoverageAnalyzer.classify(url:)`
//  对**绝对路径**做子串匹配）。那是猜，不是证据，而且猜错了会把两次运行**去重成一次**
//  （直接丢证据，比双计更坏）。
//
//  本文件的判据（全部纯函数、可注入、不读盘）：
//  1. **认得出**才给 `runKey`：同目录共位 + 正文互证（对偶格式数字核对得上 / 逐行账本一致 /
//     正文里写着同一个运行时刻），或正文自带运行时刻。
//  2. 认不出 ⇒ `runKey = nil`，并由规划器上屏「这份报告认不出属于哪次运行：<文件名>」。
//     **未知不参与去重**（宁可留着重复，也不许凭猜合并掉证据）。
//  3. `nil` 与"只有一份"是两件事：一份报告也照样可能认不出运行归属。

// MARK: - 运行归属的证据档位

/// 判"同一来源"到底凭的是哪一条证据。`note` 要能上屏 —— 只有键没有凭据，
/// 读的人无法分辨"同一次运行的两种落法"与"恰好放进同一个目录"，后者不足以声称同源。
enum CoverageRunEvidence: String, Codable, Sendable, CaseIterable {
    /// 拿不出任何证据 ⇒ **不产出 runKey**（未知）。
    case none
    /// 正文里写着运行时刻（coverage.py 的 `timestamp=`、clover 的 `generated=`）⇒ 自带归属。
    case contentStamp
    /// 同一输出目录里的**对偶落法**（一次 `nyc --reporter=lcov --reporter=json-summary`），
    /// 且两份的行数**互相核对得上**。
    case coPublishedPair
    /// 同一目录、同一格式的两份，**逐行账本完全一致**（同一批证据的两个副本）。
    case identicalLineSet
    /// 同一目录、同一运行时刻（同一次运行往不同目录里各写一份）。
    case sameDirectoryStamp

    /// 这一档撑不撑得起"同一个运行键"。
    var attestsSameRun: Bool { self != .none }

    var note: String {
        switch self {
        case .none: return "认不出属于哪次运行"
        case .contentStamp: return "正文自带运行时刻"
        case .coPublishedPair: return "同一次运行的对偶落法（数字已互相核对）"
        case .identicalLineSet: return "同目录同格式且逐行账本一致"
        case .sameDirectoryStamp: return "同一目录、同一运行时刻"
        }
    }
}

// MARK: - 判据本体

/// 运行身份的判定。吃的是**事实**（`Fact`），不吃盘 ⇒ 四种结果都能直接测。
enum CoverageRunIdentity {

    /// 一份报告能拿出手的运行事实。全部来自解析阶段已经读到的东西，不额外读盘。
    struct Fact: Equatable, Sendable {
        /// 报告**自身所在目录**相对被扫根的形式（未剥产物段）。`nil` = 在被扫目录之外。
        var directoryKey: String?
        var format: CoverageReportFormat
        var linesCovered: Int
        var linesTotal: Int
        var allLinesCovered: Int?
        var allLinesTotal: Int?
        /// 正文里的运行时刻原样（`timestamp="…"` / `generated="…"`）。`nil` = 正文没写。
        var runStamp: String?
        /// 逐行账本的稳定摘要（与别份一致 ⇒ 同一批证据）。`nil` = 该格式没有文件粒度。
        var lineSetSignature: String?

        /// 行数读数：有全量口径时按全量比（两份格式统计的对象要一致），否则按计分行数。
        var comparableLines: (covered: Int, total: Int) {
            if let total = allLinesTotal, total > 0 {
                return (allLinesCovered ?? 0, total)
            }
            return (linesCovered, linesTotal)
        }
    }

    /// 两份报告**能不能**被判成同一次运行。**同目录是必要条件**（不是充分条件）。
    static func corroborate(_ lhs: Fact, _ rhs: Fact) -> CoverageRunEvidence {
        guard let directory = lhs.directoryKey, directory == rhs.directoryKey else { return .none }
        // ① 正文自带运行时刻且相同：工具在同一秒往同一目录里写两份。
        if let stamp = lhs.runStamp, let other = rhs.runStamp, stamp == other {
            return .sameDirectoryStamp
        }
        // ② 对偶格式（nyc 的 lcov + json 摘要）⇒ 必须**数字互相核对得上**才算同一来源。
        //    核不上就说明不是同一次导出的产物，留着重复也比去重丢掉证据安全。
        if CoverageReportFormat.isCoPublishedPair(lhs.format, rhs.format) {
            return linesAgree(lhs, rhs) ? .coPublishedPair : .none
        }
        // ③ 同格式的两份落名（`lcov.info` 与 `lcov.dat`）：要么账本一致，要么行数一致。
        if lhs.format == rhs.format {
            if let left = lhs.lineSetSignature, let right = rhs.lineSetSignature, left == right {
                return .identicalLineSet
            }
            if lhs.lineSetSignature == nil, rhs.lineSetSignature == nil, linesAgree(lhs, rhs) {
                return .identicalLineSet
            }
        }
        return .none
    }

    /// 两份的行数是否同一批证据：**计分口径与全量口径都各对一次**，
    /// 任一对得上即算对得上（istanbul 摘要只有全量口径，lcov 两份口径都有）。
    static func linesAgree(_ lhs: Fact, _ rhs: Fact) -> Bool {
        if lhs.linesCovered == rhs.linesCovered, lhs.linesTotal == rhs.linesTotal, lhs.linesTotal > 0 {
            return true
        }
        let left = lhs.comparableLines, right = rhs.comparableLines
        return left.total > 0 && left == right
    }

    /// 正文 → 运行时刻。**只有两种格式的正文真写着它**，其余一律 `nil`（不许拿 mtime 冒充正文证据：
    /// mtime 是文件系统时间，不是"哪次测试运行"的记录）。
    static func runStamp(in text: String, format: CoverageReportFormat) -> String? {
        let attribute: String
        switch format {
        case .coveragePyXml: attribute = "timestamp"      // `<coverage timestamp="1680…">`
        case .cloverXml: attribute = "generated"          // `<coverage generated="1609…">`
        default: return nil
        }
        // 只看头部那一段（属性都在根元素上），免得把正文里别处的同名属性读进来。
        let header = String(text.prefix(2_000))
        guard let regex = try? NSRegularExpression(pattern: "\(attribute)=\"([0-9]+)\""),
              let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
              match.numberOfRanges == 2,
              let range = Range(match.range(at: 1), in: header) else { return nil }
        let value = String(header[range])
        return value.isEmpty ? nil : value
    }

    /// 逐行账本 → 稳定摘要。**只由账本内容决定**，与路径、与字典遍历顺序无关。
    static func lineSetSignature(of ledger: CoverageLineLedger?) -> String? {
        guard let ledger, ledger.sawSourceFileRecords else { return nil }
        let part = ledger.files.keys.sorted().map { name -> String in
            guard let record = ledger.files[name] else { return "\(name)=?" }
            let found = record.foundLines?.sorted().map(String.init).joined(separator: ",") ?? ""
            let hit = record.hitLines?.sorted().map(String.init).joined(separator: ",") ?? ""
            return "\(name):\(record.found)/\(record.hit):\(found):\(hit)"
        }
        return part.joined(separator: "|")
    }

    // MARK: - 给一批候选分配 runKey

    /// 同目录的一组里，与**该组锚点**（路径最小那份）互证得起来的成员共享一个 runKey；
    /// 核不起来的成员一律 `nil`（未知 ⇒ 不参与去重）。
    /// 定序：先按路径排，保证**与输入顺序无关**（本仓对复现性的要求）。
    ///
    /// ⚠️ **实现形状的血泪账**（接手第一跑就红的那条用例钉着它）：早期版本按**输入下标**
    /// 遍历、锚点分支里无条件写 `runKey = nil`，于是"谁先被处理"决定了锚点保不保得住
    /// 成员回灌给它的键 —— 同一批候选换顺序喂进去会分出两个结果
    /// （`[lcov, summary]` ⇒ 两份都有键；`[summary, lcov]` ⇒ summary 先被回灌、
    /// 随后自己走到锚点分支又被抹成 nil）。**改成按目录分组整体结算**：
    /// 一个目录内先定出锚点（该目录里路径最小那份），成员逐个与锚点互证，
    /// 锚点自己的键与证据档由**第一个互证成功的成员**（按路径序）决定，
    /// 全程只读 `report.path` 与目录坐标 ⇒ 与输入顺序无关。
    ///
    /// 边界（保守方向写死）：**不跨目录合并运行归属**。同一次运行往两个目录各写一份
    /// （pytest 根目录 `coverage.xml` + 插件写的 `sub/lcov.info`）在本判据下认不出来，
    /// 后果是"分开呈现、不给总数"，不是"双计" —— 认错来源的代价比不认更大。
    static func assignRunKeys(to candidates: [CoverageCandidate]) -> [CoverageCandidate] {
        let facts = candidates.map { fact(of: $0) }
        // 按目录分组：组成员是**下标**，锚点 = 该目录里路径最小那份（与输入顺序无关）。
        var groups: [String: [Int]] = [:]
        for index in candidates.indices {
            guard let directory = candidates[index].identity.directoryKey else { continue }
            groups[directory, default: []].append(index)
        }

        var outcome = candidates
        for (directory, members) in groups {
            let key = "dir=\(directory)"
            let ordered = members.sorted { candidates[$0].report.path < candidates[$1].report.path }
            guard let anchor = ordered.first else { continue }
            // ① 锚点自己正文写着运行时刻 ⇒ 它单独也认得出自己（目录里只有它一份时同理）。
            var anchorEvidence: CoverageRunEvidence? =
                facts[anchor].runStamp == nil ? nil : .contentStamp
            // ② 其余成员逐个与锚点互证。证据档取**路径序里第一个互证成功的成员**，
            //    所以换输入顺序既不会换键、也不会换"凭的是哪条证据"。
            for member in ordered.dropFirst() {
                let evidence = corroborate(facts[anchor], facts[member])
                guard evidence.attestsSameRun else {
                    outcome[member].identity.runKey = nil
                    outcome[member].identity.runEvidence = .none
                    continue
                }
                outcome[member].identity.runKey = key
                outcome[member].identity.runEvidence = evidence
                if anchorEvidence == nil { anchorEvidence = evidence }
            }
            // ③ 锚点在**这里一次性结算**：没有成员互证、正文又没有时刻 ⇒ 未知。
            //    （旧实现把这句写在按输入序遍历的分支里，才会抹掉已经回灌好的键。）
            outcome[anchor].identity.runKey = anchorEvidence == nil ? nil : key
            outcome[anchor].identity.runEvidence = anchorEvidence ?? .none
        }
        // 在被扫目录之外（切不出目录坐标）⇒ 未知，不参与任何去重。
        for index in candidates.indices where candidates[index].identity.directoryKey == nil {
            outcome[index].identity.runKey = nil
            outcome[index].identity.runEvidence = .none
        }
        return outcome
    }

    /// 候选 → 运行事实。单列出来是为了让 `corroborate` 能脱离 `CoverageCandidate` 直接测。
    static func fact(of candidate: CoverageCandidate) -> Fact {
        Fact(directoryKey: candidate.identity.directoryKey,
             format: candidate.identity.format,
             linesCovered: candidate.report.linesCovered,
             linesTotal: candidate.report.linesTotal,
             allLinesCovered: candidate.report.allLinesCovered,
             allLinesTotal: candidate.report.allLinesTotal,
             runStamp: candidate.identity.runStamp,
             lineSetSignature: lineSetSignature(of: candidate.ledger))
    }
}
