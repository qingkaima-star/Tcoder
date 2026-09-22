// OWNER: R3 依赖证据链 · 版本模型（RD-10）
//
// 本文件解决的是「一条依赖到底装的是哪个版本」这件事。历史上本仓把三件事混成一个字符串：
//   · 清单里**声明**的范围（`^1.2.3`、`[1.0,2.0)`、`workspace:*`、`*`）；
//   · 锁文件 / 依赖树 / SBOM 里**实际解析**出来的版本（`1.2.3`）；
//   · 快照或 registry 给的**最新已知**版本（`1.9.0`）。
// 混用的后果由冻结契约 `DependencyVersion.normalize` 兜底成 0：`^1.2.3` 在第一个字符处被截断成
// 空前缀 → `[0]` → 任何 caret 声明都"落后于"任何最新版本（虚报过旧），
// 而 `KnownVulnerability.comparableCore` 却能吃掉 `^`（两处口径不一致，整改清单 RD-10 点名）。
//
// 本文件的三条不变式（每条都有用例钉着，见 DependencyVersionIdentityTests）：
//   1. **未知不折算成 0**：`*` / `latest` / `workspace:*` / 空 / "未声明" 一律判「不可判定」，
//      并带一个具体的阻塞原因，绝不产出「过旧」也绝不产出「已是最新」。
//   2. **范围下界不等于安装版本**：只有**精确**声明或**已解析**的版本才参与新旧比较；
//      范围只作为「查询用的最好证据」保留，并显式标出它只是下界。
//   3. **比较身份与查询身份同源**：`queryVersion` 同时是 OSV / registry 的查询版本、
//      回填时的 key、以及和最新版比较的那个数 —— 一个数只有一份规范化。
import Foundation

// MARK: - 声明形态

/// 清单里那一栏版本原文的**形态**。这是"我们读到了什么"，不是"我们猜它装了什么"。
enum DependencyDeclaredForm: Equatable, Sendable {
    /// `1.2.3` —— 声明即安装版本（没有锁文件时它是唯一可用的精确证据）。
    case exact(String)
    /// 带范围算符或区间的写法：`^1.2.3`、`~1.2.3`、`>=1.0.0`、`1.2.x`、`[1.0,2.0)`、`1.x || 2.x`。
    case range(DependencyVersionRange)
    /// `*`、`x`、`latest`、`any`、空串 —— 没有任何版本约束。
    case wildcard
    /// `workspace:*`、`workspace:^1.2` —— 版本由本仓内的另一个工作区决定，清单里这个数不是版本。
    case workspace
    /// `git+https://…`、`file:…`、`link:…`、`npm:other@1.2`、`catalog:…`、分支名 / 修订号。
    case externalSource
    /// "未声明"（解析器给的占位串）或纯空白。
    case unspecified
    /// 脏数据：既不是版本号、也不认得任何范围语法（`abc`、`TBD`）。
    /// 单独一态，是为了让"这条依赖的版本栏写坏了"和"这条写的是范围"在界面上不混成一句。
    case malformed
}

/// 一条版本范围：保留原文，另单独给出**下界**（只用于查询，不用于"当前版本"）。
struct DependencyVersionRange: Equatable, Sendable {
    /// 清单原文，如 `[1.0,2.0)`。展示与追溯都读它，绝不拿代入后的数冒充。
    let raw: String
    /// 范围下界（`^1.2.3` → `1.2.3`，`[1.0,2.0)` → `1.0`）。取不出来时为 nil。
    let lowerBound: String?
    /// 下界是否**含**（`^` / `~` / `>=` / `[` 为含；`>1.0` 不含）。
    let lowerBoundInclusive: Bool

    /// 区间写法里有没有"任意 / x"这类通配成分（`1.2.x`、`1.x || 2.x`）：
    /// 有它就没有可信下界，只能判不可判定。
    let hasWildcardComponent: Bool
}

// MARK: - 阻塞原因

/// 「为什么这条依赖的版本新旧无法判定」——必须点名，不能沉默。
enum DependencyVersionBlocker: String, Equatable, Sendable {
    /// 声明的是范围，且没有任何锁文件 / 依赖树把它解析成确切版本。
    case rangeNotResolved
    /// `*` / `latest` / 空 —— 清单根本没给版本。
    case versionUnspecified
    /// `workspace:*` —— 真正的版本在同一仓库的另一份清单里，本轮不去做工作区联查。
    case workspaceProtocol
    /// git / file / 分支 / 修订号 —— 不是注册表版本，没有"最新"可比。
    case nonRegistrySource
    /// 版本可比，但**没有最新已知版本**这一侧的证据（生态无快照、在线没查到）。
    case missingLatestVersion
    /// 两侧任一端解析不出数字段（脏数据）。
    case malformedVersion
}

/// 一条依赖的版本新旧结论。**只有前三个是测出来的事实**。
enum DependencyOutdatedness: Equatable, Sendable {
    case older
    case atLatest
    /// 当前版本比"最新已知"还高 —— 通常是快照过期，不是问题，但绝不能报成「过旧」。
    case aheadOfLatest
    case undetermined(DependencyVersionBlocker)
}

/// 拿去查 OSV / registry 的那个版本是从哪儿来的。这条归因会显示给用户：
/// 「按下界查询」和「按锁定版本查询」的核对强度不一样。
enum DependencyQueryBasis: String, Equatable, Sendable {
    /// 锁文件 / 依赖树 / SBOM 解析出的确切版本 —— 最强。
    case lockedVersion
    /// 清单直接声明的精确版本（无范围算符）。
    case declaredExact
    /// 只有范围，取它的下界 —— 最弱，实际安装版本可能更高。
    case rangeLowerBound
}

// MARK: - 版本身份

/// 一条依赖的三份版本 + 由它们派生出的比较结论与查询身份。
struct DependencyVersionIdentity: Equatable, Sendable {
    let ecosystem: DependencyEcosystem
    let name: String
    /// 清单原文（声明范围）。
    let declaredRange: String
    /// 实际解析版本（锁文件 / 依赖树 / SBOM），没解析到为 nil。
    let resolvedVersion: String?
    /// 最新已知版本（内置快照或在线 registry），没查到为 nil。
    let latestKnownVersion: String?

    var declaredForm: DependencyDeclaredForm {
        Self.form(of: declaredRange)
    }

    /// 解析版本能不能当版本号用（`1.2.3` 可以，`workspace:*` 不行）。
    var parsedResolved: DependencySemver? { resolvedVersion.flatMap(DependencySemver.parse) }

    /// 参与比较的那个"当前版本"：**解析版本优先，其次精确声明**；
    /// 范围下界永远不参与比较（那是"去掉 ^ 把下界当安装版本"，RD-10 明令禁止）。
    var comparisonVersion: String? {
        if let resolved = resolvedVersion, parsedResolved != nil { return resolved }
        if case .exact(let value) = declaredForm { return value }
        return nil
    }

    var comparisonSemver: DependencySemver? { comparisonVersion.flatMap(DependencySemver.parse) }

    /// 用于查询与回填的版本，以及它的来路。nil = 这条依赖根本没资格进查询批次。
    var query: (version: String, basis: DependencyQueryBasis)? {
        if let resolved = resolvedVersion, parsedResolved != nil {
            return (resolved, .lockedVersion)
        }
        if case .exact(let value) = declaredForm, DependencySemver.parse(value) != nil {
            return (value, .declaredExact)
        }
        if case .range(let range) = declaredForm,
           !range.hasWildcardComponent, let lower = range.lowerBound,
           DependencySemver.parse(lower) != nil {
            return (lower, .rangeLowerBound)
        }
        return nil
    }

    /// 版本新旧结论（不可判定时带原因）。
    var outdatedness: DependencyOutdatedness {
        guard let current = comparisonSemver else {
            switch declaredForm {
            case .wildcard: return .undetermined(.versionUnspecified)
            case .unspecified: return .undetermined(.versionUnspecified)
            case .workspace: return .undetermined(.workspaceProtocol)
            case .externalSource: return .undetermined(.nonRegistrySource)
            case .malformed: return .undetermined(.malformedVersion)
            case .range:
                // 有下界也只够拿去查询，**安装版本未知** ⇒ 不许把下界当安装版本判过旧。
                return .undetermined(.rangeNotResolved)
            case .exact: return .undetermined(.malformedVersion)
            }
        }
        guard let latest = latestKnownVersion.flatMap(DependencySemver.parse) else {
            return .undetermined(.missingLatestVersion)
        }
        switch DependencySemver.compare(current, latest) {
        case .orderedAscending: return .older
        case .orderedSame: return .atLatest
        default: return .aheadOfLatest
        }
    }

    /// 这条记录能不能进入在线核对批次（版本层面）。
    var isQueryable: Bool { query != nil }

    /// **查询与回填共用的同一个 key**（RD-12）：生态 + 包名 + 规范化后的查询版本。
    /// 两侧都必须走这一个函数，禁止任何一侧再自己拼一次 `name@version`。
    static func coordinate(ecosystem: DependencyEcosystem, name: String, queryVersion: String) -> String {
        "\(ecosystem.rawValue)|\(name)|\(queryVersion)"
    }

    /// 本条记录在自己那份清单里的稳定标识（回填按它走，不按文案走）。
    func coordinate(for version: String) -> String {
        Self.coordinate(ecosystem: ecosystem, name: name, queryVersion: version)
    }

    var queryCoordinate: String? {
        guard let query else { return nil }
        return Self.coordinate(ecosystem: ecosystem, name: name, queryVersion: query.version)
    }

    /// 逐条依赖的**稳定记录 ID**：`EcosystemReport.id` + 包名 + 声明原文。
    /// 同包多清单、同包多版本都靠它区分，回填与状态查询都不许用"包名"当 key。
    static func recordID(ecosystem: DependencyEcosystem, manifestPath: String,
                         name: String, declaredRange: String) -> String {
        "\(ecosystem.rawValue):\(manifestPath):\(name):\(declaredRange)"
    }

    /// 从冻结契约的一条记录 + 可选的额外解析值构造身份。
    /// `record.version` 按解析器的约定就是**清单原文**（`^1.2.3` 不会被剥成 `1.2.3`）；
    /// `record.resolvedVersion` 是锁文件 / 依赖树 / SBOM 那条路写进来的实际版本。
    static func of(_ record: DependencyRecord, resolvedVersion: String? = nil) -> DependencyVersionIdentity {
        DependencyVersionIdentity(ecosystem: record.ecosystem,
                                  name: record.name,
                                  declaredRange: record.version,
                                  resolvedVersion: resolvedVersion ?? record.resolvedVersion,
                                  latestKnownVersion: record.latestKnownVersion)
    }

    /// 清单原文 -> 声明形态。顺序：占位串 → workspace → 外部来源 → 通配 → 范围 → 精确。
    static func form(of raw: String) -> DependencyDeclaredForm {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text == ManifestParsers.undeclaredVersion { return .unspecified }
        let lowered = text.lowercased()
        // `workspace:*` / `workspace:^1.2`：真正的版本在同一仓库的另一个工作区里，
        // 清单上这个字符串不是版本 —— 单独一态，不去猜。
        if lowered.hasPrefix("workspace:") || lowered.hasPrefix("catalog:") { return .workspace }
        if lowered == "*" || lowered == "x" || lowered == "latest" || lowered == "any" || lowered == "next" {
            return .wildcard
        }
        if Self.looksExternal(text) { return .externalSource }
        if let range = Self.range(of: text) { return .range(range) }
        if DependencySemver.parse(text) != nil { return .exact(text) }
        // 带数字却认不出的写法（`>= 1.0, < 2` 之外的自定义范围方言）保守归为范围：
        // 判不了就是判不了，不许假装判过。一个数字都没有的（`abc`、`TBD`）是脏数据，单独一态。
        if text.contains(where: { $0.isNumber }) {
            return .range(DependencyVersionRange(raw: text, lowerBound: nil,
                                                  lowerBoundInclusive: false, hasWildcardComponent: true))
        }
        return .malformed
    }

    /// 分支名 / 修订号 / URL 型版本（`master`、`abc1234`、`v1#revision=…`）不是注册表版本。
    static func looksExternal(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let schemes = ["git+", "git://", "github:", "gitlab:", "bitbucket:", "http://", "https://",
                       "ssh://", "file:", "link:", "portal:", "npm:", "path:"]
        if schemes.contains(where: { lowered.hasPrefix($0) }) { return true }
        if lowered.hasPrefix("branch:") || lowered.hasPrefix("rev:") || lowered.hasPrefix("tag:") { return true }
        // `user/repo#semver:^1.0` 这类带 `#` 的仓库坐标
        return text.contains("#") && !text.contains(" ")
    }

    /// 识别范围算符 / 区间，并给出下界（只作查询用）。
    static func range(of text: String) -> DependencyVersionRange? {
        let hasOperator = text.contains(where: { "^~<>=".contains($0) })
        let hasBracket = text.contains("[") || text.contains("(")
        let hasOr = text.contains("||")
        let hasComma = text.contains(",")
        let hasWildcardComponent = text.contains("*") || text.lowercased().contains(".x") || text.hasSuffix("x")
        guard hasOperator || hasBracket || hasOr || hasComma || hasWildcardComponent else { return nil }
        let lower = Self.lowerBound(of: text)
        let inclusive: Bool
        if text.hasPrefix(">=") || text.hasPrefix("[") { inclusive = true }
        else if text.hasPrefix(">") { inclusive = false }
        else { inclusive = true }   // `^` / `~` / `1.2.x` / `[a,b)` 的下界都含
        return DependencyVersionRange(raw: text, lowerBound: lower,
                                      lowerBoundInclusive: inclusive,
                                      hasWildcardComponent: hasWildcardComponent)
    }

    /// 从范围文本里取出**最小**的那个数字段作下界；多约束（`>1.0 <2.0`、`1.x || 2.x`）取首个。
    static func lowerBound(of text: String) -> String? {
        let tokens = Self.versionLikeTokens(in: text)
        guard let first = tokens.first else { return nil }
        if text.hasPrefix("^") || text.hasPrefix("~") || text.hasPrefix(">=") || text.hasPrefix(">") {
            return first
        }
        return tokens.min(by: { lhs, rhs in
            let left = DependencySemver.parse(lhs) ?? .zero
            let right = DependencySemver.parse(rhs) ?? .zero
            return DependencySemver.compare(left, right) == .orderedAscending
        })
    }

    /// 把文本里像版本号（以数字开头、可含 `.` 与字母限定）的片段按出现顺序取出来。
    static func versionLikeTokens(in text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for character in text {
            if character.isLetter || character.isNumber || character == "." || character == "-" {
                current.append(character)
                continue
            }
            if !current.isEmpty { tokens.append(current); current = "" }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens.filter { $0.first?.isNumber == true }
    }
}

// MARK: - 规范坐标（查询 / 回填 / 公告关联共用同一把 key）

extension DependencyRecord {
    /// 这条记录用于**关联公告**的规范坐标（RD-12）。
    ///
    /// 唯一生成口是 `DependencyVersionIdentity.coordinate(ecosystem:name:queryVersion:)`：
    /// 公告侧（OSV 与内置规则）与回填侧都调它，任何一处再手写一次
    /// `"\(name)@\(version)"` 都会让"总览有公告、依赖行不标记"复现 ——
    /// 该形状由 `DependencyEvidenceTests.testNoHandBuiltCoordinateStringsRemain` 扫着。
    var dependencyCoordinate: String? { DependencyVersionIdentity.of(self).queryCoordinate }
}

/// 规范坐标 -> 给人看的那一句。存储层必须是规范坐标（可回填、可比对），
/// 展示层在这里统一还原成 `lodash@4.17.15`，避免界面上出现 `npm|lodash|4.17.15`。
enum DependencyCoordinateDisplay {
    static func text(_ coordinate: String) -> String {
        let pieces = coordinate.split(separator: "|")
        guard pieces.count == 3 else { return coordinate }
        return "\(pieces[1])@\(pieces[2])"
    }

    static func texts(_ coordinates: [String]) -> [String] { coordinates.map(text) }
}
