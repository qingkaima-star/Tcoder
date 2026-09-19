// MARK: - 依赖清单解析（WS-B 依赖工作流）
//
// 依赖清单解析的公共层（WS-B）：结果类型、文件名->生态、按生态分派的唯一入口，
// 以及各生态解析器共用的词法工具、框架标记规则表与锁文件候选表。
// 各生态的具体解析按文件拆开放在这里：
//   ManifestParsersNpm / Java(maven+gradle) / Apple(SwiftPM+Podfile) / Python /
//   Native(go+cargo) / Scripting(Gemfile+packages.config)
// 全部仍是纯函数：不做网络查询、不猜最新版本、不查漏洞 ——
// latestKnownVersion / versionCheckSource / knownVulnerabilities 一律留空，
// 由 ManifestDependencyAnalyzer 结合内置快照统一回填。
//
// 所有解析器都是纯函数：给文本、返回结果，解析失败返回空数组或 nil，绝不抛异常。

import Foundation

// MARK: - 解析结果

/// 一份清单文件的解析结果。
struct ParsedManifest: Equatable, Sendable {
    var ecosystem: DependencyEcosystem
    /// 相对项目根，例如 "frontend/package.json"
    var manifestRelativePath: String
    /// 清单所在目录相对根，根目录用 ""
    var directoryRelativePath: String
    var dependencies: [DependencyRecord]
    /// 同目录发现到的锁文件名，没有则 nil
    var lockfileName: String?
    /// 用户看得懂的名字，如 "React"、"Spring Boot"
    var frameworkMarkers: [String]
}

// MARK: - 清单文件名 -> 生态

enum ManifestFileName {
    /// 文件名 -> 生态。覆盖 DependencyEcosystem.manifestNames 里的全部名字。
    private static let table: [String: DependencyEcosystem] = [
        "package.json": .npm,
        "pom.xml": .maven,
        "build.gradle": .gradle,
        "build.gradle.kts": .gradle,
        "settings.gradle": .gradle,
        "settings.gradle.kts": .gradle,
        "Package.swift": .swiftPM,
        "requirements.txt": .python,
        "pyproject.toml": .python,
        "setup.py": .python,
        "Pipfile": .python,
        "go.mod": .go,
        "Cargo.toml": .cargo,
        "Podfile": .cocoapods,
        "Gemfile": .ruby,
        "packages.config": .nuget,
    ]

    static func ecosystem(for fileName: String) -> DependencyEcosystem? {
        let name = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = table[name] { return exact }
        // requirements-*.txt / dev-requirements.txt 这类派生名也归入 python
        let lower = name.lowercased()
        if lower.hasPrefix("requirements") && lower.hasSuffix(".txt") { return .python }
        return nil
    }

    static var allManifestNames: Set<String> { Set(table.keys) }
}

// MARK: - 总入口

enum ManifestParsers {
    /// 未声明版本时统一用的占位串。
    static let undeclaredVersion = "未声明"

    /// 唯一的总入口：按 manifest 文件名分派到对应格式解析器。
    /// 无法识别的文件名、内容为空、或解不出任何依赖时返回 nil（不抛异常、不崩溃）。
    static func parse(text: String,
                      manifestPath: String,
                      directoryRelativePath: String,
                      directoryListing: Set<String>) -> ParsedManifest? {
        let fileName = fileName(of: manifestPath)
        guard let ecosystem = ManifestFileName.ecosystem(for: fileName) else { return nil }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let raw: [DependencyRecord]
        switch ecosystem {
        case .npm:
            raw = packageJSONDependencies(text, manifestPath: manifestPath)
        case .maven:
            raw = pomXMLDependencies(text, manifestPath: manifestPath)
        case .gradle:
            raw = gradleDependencies(text, manifestPath: manifestPath)
        case .swiftPM:
            raw = swiftPackageDependencies(text, manifestPath: manifestPath)
        case .python:
            let lower = fileName.lowercased()
            if lower.hasPrefix("requirements") && lower.hasSuffix(".txt") {
                raw = requirementsTxtDependencies(text, manifestPath: manifestPath)
            } else {
                raw = pyprojectDependencies(text, manifestPath: manifestPath)
            }
        case .go:
            raw = goModDependencies(text, manifestPath: manifestPath)
        case .cargo:
            raw = cargoTomlDependencies(text, manifestPath: manifestPath)
        case .cocoapods:
            raw = podfileDependencies(text, manifestPath: manifestPath)
        case .ruby:
            raw = gemfileDependencies(text, manifestPath: manifestPath)
        case .nuget:
            raw = nugetPackagesConfigDependencies(text, manifestPath: manifestPath)
        case .unknown:
            return nil
        }

        let dependencies = dedupe(raw)
        guard !dependencies.isEmpty else { return nil }
        return ParsedManifest(
            ecosystem: ecosystem,
            manifestRelativePath: manifestPath,
            directoryRelativePath: directoryRelativePath,
            dependencies: dependencies,
            lockfileName: lockfileName(for: ecosystem, in: directoryListing),
            frameworkMarkers: frameworkMarkers(ecosystem: ecosystem, dependencyNames: dependencies.map(\.name))
        )
    }

    /// pom.xml 里 <modules><module>x</module></modules> 抽出的相对模块目录名（多模块工程递归用）。
    static func mavenModulePaths(in pomText: String) -> [String] {
        var found: [String] = []
        var seen = Set<String>()
        for groups in matches(of: "<module>\\s*([^<]*?)\\s*</module>", in: pomText) {
            guard let raw = groups.last else { continue }
            let value = trim(raw)
            if value.isEmpty || value == "." { continue }
            if seen.insert(value).inserted { found.append(value) }
        }
        return found
    }

    /// 生态 + 依赖名集合 -> 人类可读框架标记（去重、按命中次数排序、最多 8 个）。
    static func frameworkMarkers(ecosystem: DependencyEcosystem, dependencyNames: [String]) -> [String] {
        var counts: [String: Int] = [:]
        for name in dependencyNames {
            let tokens = tokens(of: name)
            guard !tokens.isEmpty else { continue }
            // 连接形式用于兜住 camelCase 拆出的碎片："MyBatis" -> [my, batis] ~ "mybatis"
            let joined = tokens.joined()
            var hits: [String] = []
            for rule in markerRules where rule.matches(ecosystem) {
                let isHit = rule.keys.contains { phrase in
                    containsPhrase(tokens, phrase) || joined == phrase.joined()
                }
                guard isHit else { continue }
                if !hits.contains(rule.marker) { hits.append(rule.marker) }
            }
            for marker in hits { counts[marker, default: 0] += 1 }
        }
        let sorted = counts.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
        }
        return Array(sorted.prefix(8).map(\.key))
    }

    /// 按生态在目录清单里找锁文件名，返回找到的第一个（没有则 nil）。
    static func lockfileName(for ecosystem: DependencyEcosystem, in directoryListing: Set<String>) -> String? {
        for candidate in lockfileCandidates[ecosystem] ?? [] where directoryListing.contains(candidate) {
            return candidate
        }
        return nil
    }
}

// MARK: - 内部通用工具

extension ManifestParsers {
    static func fileName(of path: String) -> String {
        (path as NSString).lastPathComponent
    }

    static func trim(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 统一换行后按行切开（不含换行符）。
    static func lines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    static func record(_ name: String,
                       _ version: String,
                       _ ecosystem: DependencyEcosystem,
                       _ scope: DependencyScope,
                       _ manifestPath: String) -> DependencyRecord {
        let cleanedName = trim(name)
        let cleanedVersion = trim(version)
        return DependencyRecord(
            name: cleanedName,
            version: cleanedVersion.isEmpty ? undeclaredVersion : cleanedVersion,
            ecosystem: ecosystem,
            scope: scope,
            manifestPath: manifestPath,
            latestKnownVersion: nil,
            versionCheckSource: VersionCheckSource.none,
            knownVulnerabilities: []
        )
    }

    /// 清单内按 name 去重，后出现的覆盖前者的取值（顺序按首次出现）。
    static func dedupe(_ records: [DependencyRecord]) -> [DependencyRecord] {
        var result: [DependencyRecord] = []
        var indexByName: [String: Int] = [:]
        for item in records {
            if let existing = indexByName[item.name] {
                result[existing] = item
            } else {
                indexByName[item.name] = result.count
                result.append(item)
            }
        }
        return result
    }

    /// 正则枚举，返回每条匹配的分组数组（下标 0 为整条匹配，未命中的分组为空串）。
    static func matches(of pattern: String,
                        in text: String,
                        options: NSRegularExpression.Options = []) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let ns = text as NSString
        var out: [[String]] = []
        regex.enumerateMatches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) { result, _, _ in
            guard let result else { return }
            var groups: [String] = []
            for index in 0..<result.numberOfRanges {
                let range = result.range(at: index)
                groups.append(range.location == NSNotFound ? "" : ns.substring(with: range))
            }
            out.append(groups)
        }
        return out
    }

    static func value(at index: Int, in groups: [String]) -> String? {
        guard index < groups.count else { return nil }
        let value = groups[index]
        return value.isEmpty ? nil : value
    }

    static func firstGroup(_ pattern: String, _ group: Int, in text: String) -> String? {
        for groups in matches(of: pattern, in: text) {
            if let value = value(at: group, in: groups) { return value }
        }
        return nil
    }

    static func replaceMatches(_ text: String, pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        return regex.stringByReplacingMatches(in: text, options: [],
                                              range: NSRange(location: 0, length: ns.length),
                                              withTemplate: template)
    }

    /// 去掉 `//` 行注释：`//` 只在引号外才算注释（避免误伤 "https://..."）。
    static func stripSlashComment(_ line: String) -> String {
        var inSingle = false
        var inDouble = false
        var result = ""
        let chars = Array(line)
        var index = 0
        while index < chars.count {
            let ch = chars[index]
            if ch == "'" && !inDouble { inSingle.toggle() }
            else if ch == "\"" && !inSingle { inDouble.toggle() }
            else if ch == "/" && !inSingle && !inDouble && index + 1 < chars.count && chars[index + 1] == "/" {
                break
            }
            result.append(ch)
            index += 1
        }
        return result
    }

    /// 去掉 `#` 注释：行首 `#` 或 空白后的 `#` 之后全部丢弃（引号内的 `#` 保留）。
    static func stripHashComment(_ line: String) -> String {
        let chars = Array(line)
        var inSingle = false
        var inDouble = false
        var index = 0
        while index < chars.count {
            let ch = chars[index]
            if ch == "'" && !inDouble { inSingle.toggle() }
            else if ch == "\"" && !inSingle { inDouble.toggle() }
            else if ch == "#" && !inSingle && !inDouble {
                if index == 0 { return "" }
                let prev = chars[index - 1]
                if prev == " " || prev == "\t" { return String(chars[0..<index]) }
            }
            index += 1
        }
        return line
    }

    // MARK: - 分词 / 框架标记

    /// 把依赖名切成小写 token：按非字母数字切，并拆 camelCase（"SwiftUI" -> swift, ui）。
    static func tokens(of name: String) -> [String] {
        let chars = Array(name)
        var result: [String] = []
        var current = ""
        for index in 0..<chars.count {
            let ch = chars[index]
            if !(ch.isLetter || ch.isNumber) {
                if !current.isEmpty { result.append(current); current = "" }
                continue
            }
            if ch.isUppercase && !current.isEmpty && index > 0 {
                let prev = chars[index - 1]
                let prevIsLowerOrDigit = prev.isNumber || (prev.isLetter && prev.isLowercase)
                let nextIsLower = index + 1 < chars.count && chars[index + 1].isLetter && chars[index + 1].isLowercase
                if prevIsLowerOrDigit || (prev.isUppercase && nextIsLower) {
                    result.append(current)
                    current = ""
                }
            }
            current.append(Character(ch.lowercased()))
        }
        if !current.isEmpty { result.append(current) }
        return result.filter { !$0.isEmpty }
    }

    static func containsPhrase(_ tokens: [String], _ phrase: [String]) -> Bool {
        guard !phrase.isEmpty, tokens.count >= phrase.count else { return false }
        for start in 0...(tokens.count - phrase.count) {
            if Array(tokens[start..<(start + phrase.count)]) == phrase { return true }
        }
        return false
    }

    struct MarkerRule {
        let marker: String
        /// 空集表示不限生态。
        let ecosystems: Set<DependencyEcosystem>
        let keys: [[String]]
        func matches(_ ecosystem: DependencyEcosystem) -> Bool {
            ecosystems.isEmpty || ecosystems.contains(ecosystem)
        }
    }

    static let markerRules: [MarkerRule] = [
        // 前端 / npm
        MarkerRule(marker: "React", ecosystems: [], keys: [["react"]]),
        MarkerRule(marker: "React DOM", ecosystems: [.npm, .unknown], keys: [["react", "dom"]]),
        MarkerRule(marker: "React Native", ecosystems: [.npm, .maven, .gradle, .unknown], keys: [["react", "native"]]),
        MarkerRule(marker: "Redux", ecosystems: [.npm, .unknown], keys: [["redux"], ["rematch"]]),
        MarkerRule(marker: "MobX", ecosystems: [.npm, .unknown], keys: [["mobx"]]),
        MarkerRule(marker: "Vue", ecosystems: [.npm, .unknown], keys: [["vue"]]),
        MarkerRule(marker: "Vue Router", ecosystems: [.npm, .unknown], keys: [["vue", "router"]]),
        MarkerRule(marker: "Pinia", ecosystems: [.npm, .unknown], keys: [["pinia"]]),
        MarkerRule(marker: "Vite", ecosystems: [.npm, .unknown], keys: [["vite"], ["vitejs"], ["vitest"]]),
        MarkerRule(marker: "Next.js", ecosystems: [.npm, .unknown], keys: [["next"]]),
        MarkerRule(marker: "Nuxt", ecosystems: [.npm, .unknown], keys: [["nuxt"]]),
        MarkerRule(marker: "Angular", ecosystems: [.npm, .unknown], keys: [["angular"]]),
        MarkerRule(marker: "Svelte", ecosystems: [.npm, .unknown], keys: [["svelte"]]),
        MarkerRule(marker: "Express", ecosystems: [.npm, .unknown], keys: [["express"]]),
        MarkerRule(marker: "Koa", ecosystems: [.npm, .unknown], keys: [["koa"]]),
        MarkerRule(marker: "NestJS", ecosystems: [.npm, .unknown], keys: [["nestjs"], ["nest"]]),
        MarkerRule(marker: "TypeScript", ecosystems: [.npm, .unknown], keys: [["typescript"], ["ts", "node"]]),
        MarkerRule(marker: "Electron", ecosystems: [.npm, .unknown], keys: [["electron"]]),
        MarkerRule(marker: "Tailwind CSS", ecosystems: [.npm, .unknown], keys: [["tailwindcss"], ["tailwind", "css"], ["tailwind"]]),
        MarkerRule(marker: "Webpack", ecosystems: [.npm, .unknown], keys: [["webpack"]]),
        MarkerRule(marker: "Babel", ecosystems: [.npm, .unknown], keys: [["babel"]]),
        MarkerRule(marker: "ESLint", ecosystems: [.npm, .unknown], keys: [["eslint"]]),
        MarkerRule(marker: "Prettier", ecosystems: [.npm, .unknown], keys: [["prettier"]]),
        MarkerRule(marker: "Jest", ecosystems: [.npm, .unknown], keys: [["jest"]]),
        MarkerRule(marker: "Axios", ecosystems: [.npm, .unknown], keys: [["axios"]]),
        MarkerRule(marker: "Lodash", ecosystems: [.npm, .unknown], keys: [["lodash"]]),
        MarkerRule(marker: "Moment.js", ecosystems: [.npm, .unknown], keys: [["moment"]]),
        MarkerRule(marker: "Day.js", ecosystems: [.npm, .unknown], keys: [["dayjs"]]),
        MarkerRule(marker: "ECharts", ecosystems: [.npm, .unknown], keys: [["echarts"]]),
        MarkerRule(marker: "Ant Design", ecosystems: [.npm, .unknown], keys: [["antd"], ["ant", "design"]]),
        MarkerRule(marker: "Element Plus", ecosystems: [.npm, .unknown], keys: [["element", "plus"], ["element", "ui"]]),
        MarkerRule(marker: "Prisma", ecosystems: [.npm, .unknown], keys: [["prisma"]]),
        MarkerRule(marker: "jQuery", ecosystems: [.npm, .unknown], keys: [["jquery"]]),
        // JVM
        MarkerRule(marker: "Spring Boot", ecosystems: [.maven, .gradle, .unknown], keys: [["spring", "boot"]]),
        MarkerRule(marker: "Spring Cloud", ecosystems: [.maven, .gradle, .unknown], keys: [["spring", "cloud"]]),
        MarkerRule(marker: "Spring Security", ecosystems: [.maven, .gradle, .unknown], keys: [["spring", "security"]]),
        MarkerRule(marker: "MyBatis", ecosystems: [.maven, .gradle, .unknown], keys: [["mybatis"]]),
        MarkerRule(marker: "MyBatis-Plus", ecosystems: [.maven, .gradle, .unknown], keys: [["mybatis", "plus"]]),
        MarkerRule(marker: "Lombok", ecosystems: [.maven, .gradle, .unknown], keys: [["lombok"]]),
        MarkerRule(marker: "Netty", ecosystems: [.maven, .gradle, .unknown], keys: [["netty"]]),
        MarkerRule(marker: "Jackson", ecosystems: [.maven, .gradle, .unknown], keys: [["jackson"]]),
        MarkerRule(marker: "Gson", ecosystems: [.maven, .gradle, .unknown], keys: [["gson"]]),
        MarkerRule(marker: "Fastjson", ecosystems: [.maven, .gradle, .unknown], keys: [["fastjson"]]),
        MarkerRule(marker: "Kotlin", ecosystems: [.maven, .gradle, .unknown], keys: [["kotlin"]]),
        MarkerRule(marker: "Ktor", ecosystems: [.maven, .gradle, .unknown], keys: [["ktor"]]),
        MarkerRule(marker: "Apache Commons", ecosystems: [.maven, .gradle, .unknown], keys: [["commons"]]),
        MarkerRule(marker: "Guava", ecosystems: [.maven, .gradle, .unknown], keys: [["guava"]]),
        MarkerRule(marker: "JUnit", ecosystems: [.maven, .gradle, .unknown], keys: [["junit"]]),
        MarkerRule(marker: "Mockito", ecosystems: [.maven, .gradle, .unknown], keys: [["mockito"]]),
        MarkerRule(marker: "Log4j", ecosystems: [.maven, .gradle, .unknown], keys: [["log4j"]]),
        MarkerRule(marker: "SLF4J", ecosystems: [.maven, .gradle, .unknown], keys: [["slf4j"]]),
        MarkerRule(marker: "Logback", ecosystems: [.maven, .gradle, .unknown], keys: [["logback"]]),
        MarkerRule(marker: "Druid", ecosystems: [.maven, .gradle, .unknown], keys: [["druid"]]),
        MarkerRule(marker: "HikariCP", ecosystems: [.maven, .gradle, .unknown], keys: [["hikari"]]),
        MarkerRule(marker: "Flyway", ecosystems: [.maven, .gradle, .unknown], keys: [["flyway"]]),
        MarkerRule(marker: "Dubbo", ecosystems: [.maven, .gradle, .unknown], keys: [["dubbo"]]),
        MarkerRule(marker: "Nacos", ecosystems: [.maven, .gradle, .unknown], keys: [["nacos"]]),
        MarkerRule(marker: "Seata", ecosystems: [.maven, .gradle, .unknown], keys: [["seata"]]),
        MarkerRule(marker: "Sentinel", ecosystems: [.maven, .gradle, .unknown], keys: [["sentinel"]]),
        MarkerRule(marker: "ShardingSphere", ecosystems: [.maven, .gradle, .unknown], keys: [["shardingsphere"], ["sharding", "sphere"]]),
        MarkerRule(marker: "XXL-JOB", ecosystems: [.maven, .gradle, .unknown], keys: [["xxl"]]),
        MarkerRule(marker: "Hutool", ecosystems: [.maven, .gradle, .unknown], keys: [["hutool"]]),
        MarkerRule(marker: "OkHttp", ecosystems: [.maven, .gradle, .unknown, .cocoapods], keys: [["okhttp"]]),
        MarkerRule(marker: "Retrofit", ecosystems: [.maven, .gradle, .unknown], keys: [["retrofit"]]),
        MarkerRule(marker: "gRPC", ecosystems: [.maven, .gradle, .go, .python, .unknown], keys: [["grpc"]]),
        MarkerRule(marker: "Protobuf", ecosystems: [.maven, .gradle, .go, .python, .npm, .unknown], keys: [["protobuf"], ["proto", "buf"]]),
        MarkerRule(marker: "Elasticsearch", ecosystems: [.maven, .gradle, .npm, .python, .unknown], keys: [["elasticsearch"]]),
        MarkerRule(marker: "Kafka", ecosystems: [.maven, .gradle, .python, .go, .unknown], keys: [["kafka"]]),
        MarkerRule(marker: "Redis", ecosystems: [.maven, .gradle, .python, .go, .npm, .ruby, .cocoapods, .unknown], keys: [["redis"], ["lettuce"]]),
        MarkerRule(marker: "Android Gradle Plugin", ecosystems: [.gradle, .maven], keys: [["android", "tools"], ["gradle", "android"]]),
        MarkerRule(marker: "Android", ecosystems: [.gradle, .maven], keys: [["androidx"], ["android"]]),
        // Swift / ObjC
        MarkerRule(marker: "SwiftUI", ecosystems: [], keys: [["swift", "ui"], ["swiftui"]]),
        MarkerRule(marker: "GRDB", ecosystems: [.swiftPM, .cocoapods, .unknown], keys: [["grdb"]]),
        MarkerRule(marker: "Alamofire", ecosystems: [.swiftPM, .cocoapods, .unknown], keys: [["alamofire"]]),
        MarkerRule(marker: "SnapKit", ecosystems: [.swiftPM, .cocoapods, .unknown], keys: [["snapkit"], ["snap", "kit"]]),
        MarkerRule(marker: "Moya", ecosystems: [.swiftPM, .cocoapods, .unknown], keys: [["moya"]]),
        MarkerRule(marker: "Kingfisher", ecosystems: [.swiftPM, .cocoapods, .unknown], keys: [["kingfisher"]]),
        MarkerRule(marker: "RxSwift", ecosystems: [.swiftPM, .cocoapods, .unknown], keys: [["rx", "swift"], ["rxcocoa"]]),
        MarkerRule(marker: "Realm", ecosystems: [.swiftPM, .cocoapods, .unknown], keys: [["realm"]]),
        MarkerRule(marker: "SDWebImage", ecosystems: [.cocoapods, .swiftPM, .unknown], keys: [["sd", "web", "image"], ["web", "image"]]),
        MarkerRule(marker: "YYModel", ecosystems: [.cocoapods, .swiftPM, .unknown], keys: [["yy", "model"]]),
        MarkerRule(marker: "SwiftLint", ecosystems: [.swiftPM, .cocoapods, .unknown], keys: [["swiftlint"]]),
        MarkerRule(marker: "Firebase", ecosystems: [.cocoapods, .swiftPM, .gradle, .npm, .unknown], keys: [["firebase"]]),
        // Go
        MarkerRule(marker: "Gin", ecosystems: [.go, .unknown], keys: [["gin"]]),
        MarkerRule(marker: "Echo", ecosystems: [.go, .unknown], keys: [["echo"]]),
        MarkerRule(marker: "Fiber", ecosystems: [.go, .unknown], keys: [["fiber"]]),
        MarkerRule(marker: "GORM", ecosystems: [.go, .unknown], keys: [["gorm"]]),
        MarkerRule(marker: "Cobra", ecosystems: [.go, .unknown], keys: [["cobra"]]),
        MarkerRule(marker: "Viper", ecosystems: [.go, .unknown], keys: [["viper"]]),
        // Rust
        MarkerRule(marker: "Tokio", ecosystems: [.cargo, .unknown], keys: [["tokio"]]),
        MarkerRule(marker: "Serde", ecosystems: [.cargo, .unknown], keys: [["serde"]]),
        MarkerRule(marker: "Actix Web", ecosystems: [.cargo, .unknown], keys: [["actix"]]),
        MarkerRule(marker: "Reqwest", ecosystems: [.cargo, .unknown], keys: [["reqwest"]]),
        MarkerRule(marker: "Clap", ecosystems: [.cargo, .unknown], keys: [["clap"]]),
        MarkerRule(marker: "Rocket", ecosystems: [.cargo, .unknown], keys: [["rocket"]]),
        MarkerRule(marker: "Anyhow", ecosystems: [.cargo, .unknown], keys: [["anyhow"]]),
        // Python
        MarkerRule(marker: "Django", ecosystems: [.python, .unknown], keys: [["django"]]),
        MarkerRule(marker: "Django REST Framework", ecosystems: [.python, .unknown], keys: [["djangorestframework"], ["rest", "framework"]]),
        MarkerRule(marker: "Flask", ecosystems: [.python, .unknown], keys: [["flask"]]),
        MarkerRule(marker: "FastAPI", ecosystems: [.python, .unknown], keys: [["fastapi"]]),
        MarkerRule(marker: "Uvicorn", ecosystems: [.python, .unknown], keys: [["uvicorn"]]),
        MarkerRule(marker: "Gunicorn", ecosystems: [.python, .unknown], keys: [["gunicorn"]]),
        MarkerRule(marker: "Pydantic", ecosystems: [.python, .unknown], keys: [["pydantic"]]),
        MarkerRule(marker: "SQLAlchemy", ecosystems: [.python, .unknown], keys: [["sqlalchemy"], ["active", "record"]]),
        MarkerRule(marker: "Alembic", ecosystems: [.python, .unknown], keys: [["alembic"]]),
        MarkerRule(marker: "Celery", ecosystems: [.python, .unknown], keys: [["celery"]]),
        MarkerRule(marker: "NumPy", ecosystems: [.python, .unknown], keys: [["numpy"]]),
        MarkerRule(marker: "Pandas", ecosystems: [.python, .unknown], keys: [["pandas"]]),
        MarkerRule(marker: "SciPy", ecosystems: [.python, .unknown], keys: [["scipy"]]),
        MarkerRule(marker: "Matplotlib", ecosystems: [.python, .unknown], keys: [["matplotlib"]]),
        MarkerRule(marker: "Scikit-learn", ecosystems: [.python, .unknown], keys: [["scikit"]]),
        MarkerRule(marker: "PyTorch", ecosystems: [.python, .unknown], keys: [["pytorch"], ["torch"]]),
        MarkerRule(marker: "TensorFlow", ecosystems: [.python, .unknown], keys: [["tensorflow"]]),
        MarkerRule(marker: "Jupyter", ecosystems: [.python, .unknown], keys: [["jupyter"], ["ipykernel"], ["ipython"]]),
        MarkerRule(marker: "pytest", ecosystems: [.python, .unknown], keys: [["pytest"]]),
        MarkerRule(marker: "Requests", ecosystems: [.python, .unknown], keys: [["requests"], ["httpx"], ["aiohttp"]]),
        MarkerRule(marker: "Ruff", ecosystems: [.python, .unknown], keys: [["ruff"]]),
        MarkerRule(marker: "Mypy", ecosystems: [.python, .unknown], keys: [["mypy"]]),
        MarkerRule(marker: "Poetry", ecosystems: [.python, .unknown], keys: [["poetry"]]),
        // Ruby
        MarkerRule(marker: "Ruby on Rails", ecosystems: [.ruby, .unknown], keys: [
            ["rails"], ["railties"], ["activerecord"], ["activesupport"], ["actionpack"], ["actionview"],
        ]),
        MarkerRule(marker: "RSpec", ecosystems: [.ruby, .unknown], keys: [["rspec"]]),
        MarkerRule(marker: "Sidekiq", ecosystems: [.ruby, .unknown], keys: [["sidekiq"]]),
        MarkerRule(marker: "Puma", ecosystems: [.ruby, .unknown], keys: [["puma"]]),
        MarkerRule(marker: "Devise", ecosystems: [.ruby, .unknown], keys: [["devise"]]),
        MarkerRule(marker: "Nokogiri", ecosystems: [.ruby, .unknown], keys: [["nokogiri"]]),
        MarkerRule(marker: "Minitest", ecosystems: [.ruby, .unknown], keys: [["minitest"]]),
        MarkerRule(marker: "RuboCop", ecosystems: [.ruby, .unknown], keys: [["rubocop"]]),
        MarkerRule(marker: "SimpleCov", ecosystems: [.ruby, .unknown], keys: [["simplecov"], ["simple", "cov"]]),
        MarkerRule(marker: "Bundler", ecosystems: [.ruby, .unknown], keys: [["bundler"]]),
        // .NET
        MarkerRule(marker: "ASP.NET Core", ecosystems: [.nuget, .unknown], keys: [["aspnetcore"], ["asp", "net"], ["net", "core"]]),
        MarkerRule(marker: "Entity Framework Core", ecosystems: [.nuget, .unknown], keys: [["entity", "framework"]]),
        MarkerRule(marker: "Newtonsoft.Json", ecosystems: [.nuget, .unknown], keys: [["newtonsoft"]]),
        MarkerRule(marker: "Serilog", ecosystems: [.nuget, .unknown], keys: [["serilog"]]),
        MarkerRule(marker: "Dapper", ecosystems: [.nuget, .unknown], keys: [["dapper"]]),
        MarkerRule(marker: "xUnit", ecosystems: [.nuget, .unknown], keys: [["xunit"]]),
        MarkerRule(marker: "NUnit", ecosystems: [.nuget, .unknown], keys: [["nunit"]]),
        MarkerRule(marker: "Moq", ecosystems: [.nuget, .unknown], keys: [["moq"]]),
    ]

    // MARK: - 锁文件判定表

    static let lockfileCandidates: [DependencyEcosystem: [String]] = [
        .npm: [
            "package-lock.json", "npm-shrinkwrap.json", "pnpm-lock.yaml", "pnpm-lock.yml",
            "yarn.lock", "bun.lockb", "bun.lock", "deno.lock",
        ],
        .maven: [],
        .gradle: ["gradle.lockfile", "dependencies.lock"],
        .swiftPM: ["Package.resolved"],
        .python: [
            "poetry.lock", "Pipfile.lock", "uv.lock", "pdm.lock",
            "requirements.lock", "requirements.txt.lock", "conda-lock.json",
        ],
        .go: ["go.sum"],
        .cargo: ["Cargo.lock"],
        .cocoapods: ["Podfile.lock"],
        .ruby: ["Gemfile.lock"],
        .nuget: ["packages.lock.json"],
        .unknown: [],
    ]
}

// MARK: - 下标安全访问

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
