import Foundation

/// 一条**可定位坐标**：文件 + 符号 + 判据名。
///
/// 为什么要有这个形状：榜上条目、建议、CVE 行原来各自是一句中文（「XX 文件太大」「某函数 CC 41」），
/// 读的人既没法**点名**它、也没法把两次扫描的同一批结论**求交或 diff**。
/// 对齐 `BoardLengthReadoutRatchetTests` 那套做法（逐条带稳定坐标）后，
/// 「这次比上次多了哪几条」是一个集合差，不是一段散文对比。
///
/// 刻意**不把行号放进 key**：行号一次编辑就漂，漂了的坐标没法跨两次扫描求交。
/// 行号只在展示行里出现，作为"这一条此刻在哪"的辅助。
struct EvidenceCoordinate: Equatable, Hashable, Comparable {
    var file: String
    var symbol: String
    var criterion: String

    /// 稳定坐标串：点名用它、求交用它、diff 也用它。
    var key: String { "\(file) ⇑ \(symbol) ⇑ \(criterion)" }

    static func < (lhs: EvidenceCoordinate, rhs: EvidenceCoordinate) -> Bool { lhs.key < rhs.key }

    /// 文件级结论（巨大文件、覆盖率报告）在契约里**没有**符号位 —— 明写这一点，
    /// 而不是留空串或塞一个"?"让人以为读到了符号。
    static let fileLevelSymbol = "（文件级·契约里没有符号位）"
}

/// 判据名只这一份：每条坐标都指回**产出它的那个符号**，改判据时这里跟着动。
enum CriterionName {
    static let hugeFile = "巨大文件行数线（FileSystemCodeAnalyzer.mediumFileLines）"
    static let hotspot = "复杂度判级线（FileSystemCodeAnalyzer 的 critical/highFunctionComplexity）"
    static let duplicateBlock = "重复块滑窗（DuplicationEngine.analyze）"
    static let osvAdvisory = "OSV 在线通告命中（OsvClient）"
    static let snapshotVulnerability = "内置快照规则命中（VulnerabilitySource.matches）"
    static let logCluster = "错误聚类签名（LogClustering）"
    static let coverageReport = "覆盖率分母口径（CoverageScope.isProductionSource）"
    static let scanLimitation = "扫描边界自声明（CodeScanCoverage.limitationSummary）"
    static let healthComponent = "健康分量判据（WeightedHealthScorer）"
}

/// 结论 → 证据坐标（R10b 第 3 件）。
enum EvidenceCoordinates {

    /// 逐条落坐标。**只读报告里已有的结构化条目**，不在这里再扫一遍源码。
    static func of(_ report: ProjectReport) -> [EvidenceCoordinate] {
        coordinatesForCode(report) + coordinatesForDependencies(report)
            + coordinatesForLogs(report) + coordinatesForCoverage(report)
    }

    /// 有中文结论、但契约里没留下任何可回指结构的那些条目 —— 逐条点名说"没坐标"。
    /// 这一段是**故意**打出来的：静默不提，读的人就以为屏上每条结论都查得到出处。
    static func unanchored(_ report: ProjectReport) -> [String] {
        guard let health = report.health else { return [] }
        return (health.recommendations + health.issues).map {
            "  未落坐标（契约侧 recommendations / issues 就是 [String]，没有回指字段）：\($0)"
        }
    }

    static func text(_ report: ProjectReport) -> [String] {
        let coordinates = of(report)
        var lines = ["结论坐标 \(coordinates.count) 条（文件 ⇑ 符号 ⇑ 判据名，可点名 · 可求交 · 可 diff）"]
        lines.append(contentsOf: coordinates.sorted().map { "  \($0.key)" })
        let loose = unanchored(report)
        lines.append("  未落坐标 \(loose.count) 条"
                     + (loose.isEmpty ? ""
                        : "（这些结论在契约侧就是中文句子，出处要总工在 Models/** 开回指字段才钉得住）："))
        // 逐条列，不折叠成"其余若干条同形"：`CLIPrecisionCaveatTests` 立的规矩是
        // 榜上有几条就得有几行，折叠一次就少一处可点名的东西。
        lines.append(contentsOf: loose)
        return lines
    }

    // MARK: - 各路

    /// 被扫根之后的相对路径：绝对路径会把"同一份代码换个目录"变成"两批不同结论"。
    static func relative(_ path: String, to report: ProjectReport) -> String {
        guard let root = report.provenance?.scannedRoot, path.hasPrefix(root) else { return path }
        return String(path.dropFirst(root.count).drop(while: { $0 == "/" }))
    }

    private static func coordinatesForCode(_ report: ProjectReport) -> [EvidenceCoordinate] {
        guard let code = report.code else { return [] }
        var result: [EvidenceCoordinate] = []
        for hotspot in code.hugeFiles {
            result.append(EvidenceCoordinate(file: relative(hotspot.path, to: report),
                                             symbol: EvidenceCoordinate.fileLevelSymbol,
                                             criterion: CriterionName.hugeFile))
        }
        for function in code.topComplexFunctions {
            result.append(EvidenceCoordinate(file: relative(function.filePath, to: report),
                                             symbol: function.name, criterion: CriterionName.hotspot))
        }
        for block in code.duplicatedBlocks {
            let pair = block.occurrences.map { relative($0.path, to: report) }.sorted().joined(separator: " ↔ ")
            result.append(EvidenceCoordinate(file: pair.isEmpty ? "（无出现位置）" : pair,
                                             symbol: "\(block.lineCount) 行 · 相似度 "
                                                 + String(format: "%.2f", block.similarity),
                                             criterion: CriterionName.duplicateBlock))
        }
        return result
    }

    /// 依赖那一路：CVE 行本身不带文件，**受影响包名 → 清单路径**这一跳要现查一次已落盘的记录。
    /// 只查 `report.dependencies` 里的记录，不去读盘上的清单。
    private static func coordinatesForDependencies(_ report: ProjectReport) -> [EvidenceCoordinate] {
        guard let deps = report.dependencies else { return [] }
        let manifestOf = manifestIndex(deps, report: report)
        var result: [EvidenceCoordinate] = []
        for advisory in deps.advisories {
            result.append(contentsOf: advisory.affectedPackages.map {
                EvidenceCoordinate(file: manifestOf[$0] ?? "（未匹配到清单条目）",
                                   symbol: "\($0) · \(advisory.id)", criterion: CriterionName.osvAdvisory)
            })
        }
        for vulnerability in deps.offlineVulnerabilities {
            result.append(contentsOf: vulnerability.affectedDependencies.map {
                EvidenceCoordinate(file: manifestOf[$0] ?? "（未匹配到清单条目）",
                                   symbol: "\($0) · \(vulnerability.id)",
                                   criterion: CriterionName.snapshotVulnerability)
            })
        }
        return result
    }

    private static func coordinatesForLogs(_ report: ProjectReport) -> [EvidenceCoordinate] {
        report.logs?.topErrors.map {
            EvidenceCoordinate(file: relative($0.sourceFile, to: report),
                               symbol: $0.signature, criterion: CriterionName.logCluster)
        } ?? []
    }

    private static func coordinatesForCoverage(_ report: ProjectReport) -> [EvidenceCoordinate] {
        report.coverage?.reports.map {
            EvidenceCoordinate(file: relative($0.path, to: report),
                               symbol: "\($0.toolName) · \($0.kind.rawValue)",
                               criterion: CriterionName.coverageReport)
        } ?? []
    }

    /// 包名 → 它所在清单的路径。同名多条时取路径字典序最小的一条，
    /// 这样"同一个包名"在两台机器上不会指向两个不同清单（顺序无关）。
    private static func manifestIndex(_ deps: DependencyReport, report: ProjectReport) -> [String: String] {
        var index: [String: String] = [:]
        for ecosystem in deps.ecosystems.sorted(by: { $0.manifestPath < $1.manifestPath }) {
            for record in ecosystem.dependencies.sorted(by: { $0.name < $1.name }) where index[record.name] == nil {
                index[record.name] = relative(record.manifestPath, to: report)
            }
        }
        return index
    }
}

/// 一条**候选风险提示**：形态像、没独立真值 ⇒ 只是提示。
struct CandidateRiskHint: Equatable {
    var kind: String
    var file: String
    var symbol: String
    var why: String
    var confidence: String

    var coordinate: EvidenceCoordinate {
        EvidenceCoordinate(file: file, symbol: symbol, criterion: kind)
    }

    var displayLine: String {
        "  [\(CandidateRiskHints.screenToken)] \(kind) · \(file) ⇑ \(symbol) · 为什么值得看一眼：\(why)"
            + " · 把握：\(confidence)"
    }
}

/// 用户 §十 末尾点名的四类高价值检查：**只能出提示，不能出判定**。
///
/// 边界（这条比实现重要）：这四类形态**没有一条有独立真值** —— 判"不可达代码"要调用图，
/// 判"async 缺身份校验"要认得出鉴权调用，判"循环里查库 / 事务里做网络 IO"要控制流加副作用。
/// `ProjectReport` 里**没有任何一个字段**承载这些（`FunctionHotspot` 只有名字、行数、CC、参数个数）。
/// 所以产品侧现在一条候选都发不出，屏上只有"缺哪几项输入"那四行；
/// 规则本体已经写好并被单测用合成输入跑通 —— 等总工在 `Models/**` 开出函数级输入，
/// 判据一字不改就能出条目。**没有真值之前它就不是缺陷**，把它当缺陷发出去就是本轮禁止的假报。
enum CandidateRiskHints {

    /// 上屏必带的标记串。**任何**一条候选行都得含它，否则提示会长成判定。
    static let screenToken = "候选·未判定"

    struct Rule: Equatable {
        var kind: String
        /// 这一条要成立必须有的输入，以及它在契约里的缺席状态。
        var requiredInput: String
        var why: String
    }

    static let rules: [Rule] = [
        Rule(kind: "候选·不可达代码", requiredInput: "函数级调用图（Models/** 里没有这一格）",
             why: "零调用的实现文件本轮已经靠单测扫到过，但那份普查住在测试里，报告结构里没有承接字段"),
        Rule(kind: "候选·async 入口缺身份校验", requiredInput: "函数体的 await 标记 + 鉴权调用识别（契约里没有）",
             why: "无头入口与网络那一路都吃外部输入，形态上值得看一眼；认不出校验调用就不能判"),
        Rule(kind: "候选·循环内查库", requiredInput: "函数体内控制流 + 副作用调用（契约里只有 CC 与行数）",
             why: "高 CC 只说明分支多，不说明在循环里发查询 —— 拿 CC 当它是假报"),
        Rule(kind: "候选·事务内做网络 IO", requiredInput: "事务边界标记（契约里根本没有事务这个概念）",
             why: "这条最需要跨调用的上下文，报告里连事务都没建模，任何断言都是猜"),
    ]

    /// 规则判据吃的最小输入。**当前没有生产者**：产品侧传 `[]`（见 `pendingReasons(in:)`），
    /// 单测用合成值走通正向路径。
    struct CandidateEvidence: Equatable {
        var kind: String
        var file: String
        var symbol: String
        var detail: String
    }

    /// 正向：给了输入就出条目，每条自带坐标与「把握」，**不改任何分数**。
    static func hints(from evidence: [CandidateEvidence]) -> [CandidateRiskHint] {
        let known = Set(rules.map(\.kind))
        return evidence.filter { known.contains($0.kind) }.map {
            CandidateRiskHint(kind: $0.kind, file: $0.file, symbol: $0.symbol,
                              why: $0.detail,
                              confidence: "低：形态相似，无独立真值 ⇒ 不构成缺陷判定")
        }.sorted { $0.coordinate < $1.coordinate }
    }

    /// 产品侧现在能说的只有一句：四类检查各自缺哪一项输入。
    static func pendingReasons() -> [String] {
        rules.map { "  \(CandidateRiskHints.screenToken) \($0.kind) · 本次未发条目的原因：缺输入「\($0.requiredInput)」" }
    }

    static func text(_ report: ProjectReport) -> [String] {
        let emitted = hints(from: evidence(in: report))
        var lines = ["风险提示 \(emitted.count) 条（全部带「\(screenToken)」标记，"
                     + "不参与评分、不产生扣分）"]
        lines.append(contentsOf: emitted.map(\.displayLine))
        lines.append(contentsOf: pendingReasons())
        return lines
    }

    /// 报告里目前**没有任何**函数级副作用/调用信息，所以这里恒空。
    /// 写成函数而不是内联空数组：接线点只留这一处，将来加字段时改这里就够。
    static func evidence(in report: ProjectReport) -> [CandidateEvidence] { [] }
}
