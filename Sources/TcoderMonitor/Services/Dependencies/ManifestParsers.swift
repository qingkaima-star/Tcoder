// MARK: - 依赖清单解析（WS-B 依赖工作流）
//
// 这个文件只做一件事：把「清单文件的文本内容」解析成 DependencyRecord 列表。
// 不做任何网络查询、不猜最新版本、不查漏洞：
// latestKnownVersion / versionCheckSource / knownVulnerabilities 一律留空，
// 由主会话的 ManifestDependencyAnalyzer 结合内置快照统一回填。
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

// MARK: - npm / package.json

extension ManifestParsers {
    private static let npmSections: [(key: String, scope: DependencyScope)] = [
        ("dependencies", .runtime),
        ("devDependencies", .dev),
        ("peerDependencies", .platform),
        ("optionalDependencies", .unknown),
    ]

    /// package.json -> [DependencyRecord]。版本原样保留（^1.2.3、workspace:*、git+https://…）。
    static func packageJSONDependencies(_ text: String, manifestPath: String) -> [DependencyRecord] {
        guard let data = text.data(using: .utf8) else { return [] }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let root = object as? [String: Any] else { return [] }

        var records: [DependencyRecord] = []
        for section in npmSections {
            guard let table = root[section.key] as? [String: Any] else { continue }
            for name in table.keys.sorted() {
                let version = jsonVersionString(table[name]) ?? undeclaredVersion
                records.append(record(name, version, .npm, section.scope, manifestPath))
            }
        }
        return dedupe(records)
    }

    private static func jsonVersionString(_ value: Any?) -> String? {
        if let string = value as? String { return string.isEmpty ? nil : string }
        if let number = value as? NSNumber { return number.stringValue }
        if let table = value as? [String: Any] { return jsonVersionString(table["version"]) }
        return nil
    }
}

// MARK: - Maven / pom.xml

extension ManifestParsers {
    /// pom.xml -> [DependencyRecord]。name 为 "groupId:artifactId"；
    /// `<properties>` 与 dependencyManagement 的版本会代入实际 dependencies 条目，
    /// 代不了就保留原文，完全解不出来版本时填 "未声明"。
    static func pomXMLDependencies(_ text: String, manifestPath: String) -> [DependencyRecord] {
        let model = PomDocumentModel(text: text)
        return dedupe(model.dependencyRecords(manifestPath: manifestPath))
    }
}

// MARK: - Gradle / build.gradle(.kts)

extension ManifestParsers {
    private static let gradleConfigScopes: [String: DependencyScope] = [
        "implementation": .runtime,
        "api": .runtime,
        "compile": .runtime,
        "runtime": .runtime,
        "runtimeonly": .runtime,
        "classpath": .runtime,
        "debugimplementation": .runtime,
        "releaseimplementation": .runtime,
        "testimplementation": .test,
        "testruntimeonly": .test,
        "testcompileonly": .test,
        "testannotationprocessor": .test,
        "androidtestimplementation": .test,
        "androidtestruntimeonly": .test,
        "androidtestannotationprocessor": .test,
        "kapttest": .test,
        "kaptandroidtest": .test,
        "compileonly": .build,
        "kapt": .build,
        "annotationprocessor": .build,
        "corelibrarydesugaring": .build,
        "detekt": .build,
        "spotless": .build,
    ]

    static func gradleScope(for configuration: String) -> DependencyScope? {
        let key = configuration.lowercased()
        if let known = gradleConfigScopes[key] { return known }
        let isTest = key.contains("test") || key.contains("spec")
        if key.hasSuffix("implementation") || key.hasSuffix("api") { return isTest ? .test : .runtime }
        if key.hasSuffix("classpath") { return .runtime }
        if key.hasSuffix("only") { return key.contains("runtime") ? .runtime : (isTest ? .test : .build) }
        if key.hasPrefix("kapt") || key.contains("processor") { return isTest ? .test : .build }
        return nil
    }

    /// build.gradle / build.gradle.kts / settings.gradle(.kts) -> [DependencyRecord]。
    static func gradleDependencies(_ text: String, manifestPath: String) -> [DependencyRecord] {
        let body = lines(text).map { stripSlashComment($0) }.joined(separator: "\n")
        var records: [DependencyRecord] = []

        // 1) 配置名 + 字符串坐标：implementation 'g:a:v' / api("g:a:v") / implementation platform("g:a:v")
        let coordinatePattern = "\\b([A-Za-z][A-Za-z0-9_]*)\\s*\\(?\\s*(?:platform\\s*\\(\\s*)?(['\"])([^'\"\\n]+)\\2"
        for groups in matches(of: coordinatePattern, in: body) {
            guard let configuration = groups[safe: 1], let coordinate = groups[safe: 3],
                  let scope = gradleScope(for: configuration) else { continue }
            guard let (name, version) = gradleCoordinate(coordinate) else { continue }
            records.append(record(name, version, .gradle, scope, manifestPath))
        }

        // 2) map 写法：implementation group: 'g', name: 'a', version: 'v'
        let mapPattern = "\\b([A-Za-z][A-Za-z0-9_]*)\\s*\\(?\\s*group\\s*:\\s*(['\"])([^'\"\\n]+)\\2"
            + "\\s*,\\s*name\\s*:\\s*(['\"])([^'\"\\n]+)\\4\\s*(?:,\\s*version\\s*:\\s*(['\"])([^'\"\\n]+)\\6)?"
        for groups in matches(of: mapPattern, in: body) {
            guard let configuration = groups[safe: 1], let group = groups[safe: 3], let artifact = groups[safe: 5],
                  let scope = gradleScope(for: configuration) else { continue }
            let version = groups[safe: 7] ?? undeclaredVersion
            records.append(record("\(group):\(artifact)", version, .gradle, scope, manifestPath))
        }

        // 3) 版本目录：library("别名", "g:a:v")（现代 Gradle 真正的版本只写在这里）
        let catalogPattern = "\\blibrary\\s*\\(\\s*(['\"])([^'\"\\n]+)\\1\\s*,\\s*(['\"])([^'\"\\n]+)\\3"
        for groups in matches(of: catalogPattern, in: body) {
            guard let coordinate = groups[safe: 4], let (name, version) = gradleCoordinate(coordinate) else { continue }
            records.append(record(name, version, .gradle, .runtime, manifestPath))
        }

        // 4) 插件声明：id("org.springframework.boot") version "3.2.0" / kotlin("jvm") version "1.9.22"
        let pluginPattern = "\\b(?:id|kotlin)\\s*\\(?\\s*(['\"])([A-Za-z0-9_.\\-]+)\\1\\s*\\)?\\s+version\\s+(['\"])([^'\"\\n]+)\\3"
        for groups in matches(of: pluginPattern, in: body) {
            guard let rawID = groups[safe: 2], let version = groups[safe: 4] else { continue }
            let name = rawID.contains(".") ? rawID : "org.jetbrains.kotlin.\(rawID)"
            records.append(record(name, version, .gradle, .build, manifestPath))
        }
        return dedupe(records)
    }

    /// "g:a:v" / "g:a" / "g:a:v@jar" / "g:a:v:classifier" -> (name, version)；不像坐标返回 nil。
    static func gradleCoordinate(_ raw: String) -> (name: String, version: String)? {
        let coordinate = trim(raw)
        if coordinate.isEmpty || coordinate.contains("://") || coordinate.contains(" ") { return nil }
        if coordinate.hasPrefix("/") || coordinate.hasPrefix("\\") { return nil }
        let parts = coordinate.split(separator: ":", omittingEmptySubsequences: false)
            .map { component -> String in
                guard let at = component.firstIndex(of: "@") else { return String(component) }
                return String(component[..<at])
            }
        guard parts.count >= 2 else { return nil }
        let group = parts[0]
        let artifact = parts[1]
        guard group.contains(where: { $0.isLetter }), artifact.contains(where: { $0.isLetter }) else { return nil }
        let version = parts.count >= 3 && !parts[2].isEmpty ? parts[2] : undeclaredVersion
        return ("\(group):\(artifact)", version)
    }
}

// MARK: - Swift Package Manager / Package.swift

extension ManifestParsers {
    /// Package.swift -> [DependencyRecord]，scope 全为 .runtime。`.package(path:)` 是本地模块，不计入。
    static func swiftPackageDependencies(_ text: String, manifestPath: String) -> [DependencyRecord] {
        let ns = text as NSString
        let needle = ".package("
        var records: [DependencyRecord] = []
        var searchStart = 0
        while searchStart < ns.length {
            let window = NSRange(location: searchStart, length: ns.length - searchStart)
            let found = ns.range(of: needle, options: [], range: window)
            if found.location == NSNotFound { break }
            let argumentsStart = found.location + found.length
            guard let argumentsLength = closingArgumentsLength(after: argumentsStart, in: ns) else {
                searchStart = argumentsStart
                continue
            }
            let arguments = ns.substring(with: NSRange(location: argumentsStart, length: argumentsLength))
            searchStart = argumentsStart + argumentsLength
            let body = stripSlashComment(arguments)
            if let entry = swiftPackageEntry(body) {
                records.append(record(entry.name, entry.version, .swiftPM, .runtime, manifestPath))
            }
        }
        return dedupe(records)
    }

    /// 从 `.package(` 之后扫描配对括号，返回参数文本长度；括号不配对返回 nil。
    static func closingArgumentsLength(after start: Int, in ns: NSString) -> Int? {
        var depth = 1
        var quote: unichar = 0
        var index = start
        while index < ns.length {
            let ch = ns.character(at: index)
            if quote != 0 {
                if ch == quote { quote = 0 }
                index += 1
                continue
            }
            if ch == 34 || ch == 39 { quote = ch }
            else if ch == 40 { depth += 1 }
            else if ch == 41 {
                depth -= 1
                if depth == 0 { return index - start + 1 }
            }
            index += 1
        }
        return nil
    }

    static func swiftPackageEntry(_ arguments: String) -> (name: String, version: String)? {
        let url = firstGroup("url\\s*:\\s*(['\"])([^'\"\\n]+)\\1", 2, in: arguments)
        let identifier = firstGroup("\\bid\\s*:\\s*(['\"])([^'\"\\n]+)\\1", 2, in: arguments)
        let declaredName = firstGroup("(?:^|[^A-Za-z])name\\s*:\\s*(['\"])([^'\"\\n]+)\\1", 2, in: arguments)
        if firstGroup("path\\s*:\\s*(['\"])([^'\"\\n]+)\\1", 2, in: arguments) != nil, url == nil, identifier == nil {
            return nil // 本地路径依赖
        }
        var version = firstGroup("\\bfrom\\s*:\\s*(['\"])([^'\"\\n]+)\\1", 2, in: arguments)
        version = version ?? firstGroup("\\bexact\\s*:\\s*(['\"])([^'\"\\n]+)\\1", 2, in: arguments)
        version = version ?? firstGroup("(['\"])([0-9][^'\"\\s]*)\\1\\s*\\.\\.\\.", 2, in: arguments)
        version = version ?? firstGroup("\\brevision\\s*:\\s*(['\"])([^'\"\\n]+)\\1", 2, in: arguments)
        version = version ?? firstGroup("\\bbranch\\s*:\\s*(['\"])([^'\"\\n]+)\\1", 2, in: arguments)

        let name: String
        if let declaredName, !declaredName.isEmpty {
            name = declaredName
        } else if let url, !url.isEmpty {
            name = swiftPackageBasename(url)
        } else if let identifier, !identifier.isEmpty {
            name = identifier
        } else {
            return nil
        }
        guard !name.isEmpty else { return nil }
        return (name, version ?? undeclaredVersion)
    }

    /// URL -> 包名：末段去掉 .git
    static func swiftPackageBasename(_ rawURL: String) -> String {
        var value = trim(rawURL)
        if let hash = value.firstIndex(of: "#") { value = String(value[..<hash]) }
        if let query = value.firstIndex(of: "?") { value = String(value[..<query]) }
        while value.hasSuffix("/") { value = String(value.dropLast()) }
        var last = value
        if let slash = last.lastIndex(of: "/") { last = String(last[last.index(after: slash)...]) }
        if last.lowercased().hasSuffix(".git") { last = String(last.dropLast(4)) }
        return last
    }
}

// MARK: - Python

extension ManifestParsers {
    /// requirements.txt -> [DependencyRecord]。名字按 PEP 503 小写归一；
    /// `pkg>=1.2` 取声明的下界 "1.2"；`-r`/`-e`/注释行跳过。
    static func requirementsTxtDependencies(_ text: String, manifestPath: String) -> [DependencyRecord] {
        var records: [DependencyRecord] = []
        for rawLine in lines(text) {
            let line = trim(stripHashComment(rawLine))
            if line.isEmpty { continue }
            if line.hasPrefix("-") { continue } // -r / -e / -c / --index-url …
            if let item = pythonRequirementRecord(line, scope: .runtime, manifestPath: manifestPath) {
                records.append(item)
            }
        }
        return dedupe(records)
    }

    /// pyproject.toml / Pipfile / setup.py -> [DependencyRecord]（尽力而为）。
    static func pyprojectDependencies(_ text: String, manifestPath: String) -> [DependencyRecord] {
        var records: [DependencyRecord] = []

        for entry in tomlEntries(in: text) {
            let section = entry.section.lowercased()
            let key = entry.key.lowercased()
            let value = entry.value

            if section == "project", key == "dependencies" {
                for spec in tomlStringList(value) {
                    appendPython(spec, scope: .runtime, manifestPath: manifestPath, to: &records)
                }
                continue
            }
            if section == "build-system", key == "requires" {
                for spec in tomlStringList(value) {
                    appendPython(spec, scope: .build, manifestPath: manifestPath, to: &records)
                }
                continue
            }
            if section == "project", key == "requires-python" {
                if let version = numericVersionPrefix(value) {
                    records.append(record("python", version, .python, .platform, manifestPath))
                }
                continue
            }
            if section == "dependency-groups" {
                for spec in tomlStringList(value) {
                    appendPython(spec, scope: .dev, manifestPath: manifestPath, to: &records)
                }
                continue
            }
            if section.hasSuffix("optional-dependencies") {
                for spec in tomlStringList(value) {
                    appendPython(spec, scope: .dev, manifestPath: manifestPath, to: &records)
                }
                continue
            }

            guard let scope = pythonTableScope(section) else { continue }
            // poetry / Pipfile 风格：name = "^1.2" 或 name = { version = "^1.2", … }
            let name = key == "python" ? "python" : normalizePythonName(entry.key)
            guard !name.isEmpty else { continue }
            let declared: String?
            if let inline = firstGroup("version\\s*=\\s*(['\"])([^'\"\\n]+)\\1", 2, in: value) {
                declared = inline
            } else if trim(value).hasPrefix("{") {
                declared = nil // 只有 git / path，没写版本
            } else {
                declared = firstGroup("^\\s*(['\"])([^'\"\\n]+)\\1", 2, in: value)
            }
            let version: String
            if let declared, let extracted = numericVersionPrefix(declared) {
                version = extracted
            } else if let declared, declared != "*" {
                version = declared
            } else {
                version = undeclaredVersion
            }
            records.append(record(name, version, .python, name == "python" ? .platform : scope, manifestPath))
        }

        // setup.py 的 install_requires = [...] / extras_require = {...}
        for groups in matches(of: "install_requires\\s*=\\s*\\[([^\\]]*)\\]", in: text) {
            guard let body = groups[safe: 1] else { continue }
            for spec in tomlStringList(body) {
                appendPython(spec, scope: .runtime, manifestPath: manifestPath, to: &records)
            }
        }
        for groups in matches(of: "extras_require\\s*=\\s*\\{(.*?)\\n[ \\t]*\\}", in: text,
                             options: [.dotMatchesLineSeparators]) {
            guard let body = groups[safe: 1] else { continue }
            for spec in tomlStringList(body) {
                appendPython(spec, scope: .dev, manifestPath: manifestPath, to: &records)
            }
        }
        return dedupe(records)
    }

    private static func appendPython(_ spec: String, scope: DependencyScope,
                                     manifestPath: String, to records: inout [DependencyRecord]) {
        if let item = pythonRequirementRecord(spec, scope: scope, manifestPath: manifestPath) {
            records.append(item)
        }
    }

    /// 一条 PEP 508 / PEP 440 依赖字符串 -> DependencyRecord
    static func pythonRequirementRecord(_ spec: String, scope: DependencyScope,
                                        manifestPath: String) -> DependencyRecord? {
        var value = trim(stripHashComment(spec))
        if value.isEmpty || value.hasPrefix("-") { return nil }
        if let semicolon = value.firstIndex(of: ";") { value = trim(String(value[..<semicolon])) }
        // 直接引用：name @ https://…
        if let direct = value.range(of: " @ ") {
            let name = normalizePythonName(String(value[..<direct.lowerBound]))
            guard !name.isEmpty else { return nil }
            return record(name, undeclaredVersion, .python, scope, manifestPath)
        }
        if value.contains("://") {
            guard let egg = firstGroup("[#&]egg=([A-Za-z0-9_.\\-]+)", 1, in: value) else { return nil }
            return record(normalizePythonName(egg), undeclaredVersion, .python, scope, manifestPath)
        }
        guard let groups = matches(of: "^([A-Za-z0-9][A-Za-z0-9._\\-]*)\\s*(\\[[^\\]]*\\])?\\s*(.*)$", in: value).first,
              let rawName = groups[safe: 1] else { return nil }
        let name = normalizePythonName(rawName)
        guard !name.isEmpty else { return nil }
        let version = numericVersionPrefix(groups[safe: 3] ?? "") ?? undeclaredVersion
        return record(name, version, .python, scope, manifestPath)
    }

    static func normalizePythonName(_ raw: String) -> String {
        let lower = trim(raw).lowercased()
        guard !lower.isEmpty else { return lower }
        return replaceMatches(lower, pattern: "[-_.]+", with: "-")
    }

    /// 从 "^1.2"、">=1.2,<2"、"~> 1.2"、"==1.2.3" 里取声明的下界；取不到返回 nil。
    static func numericVersionPrefix(_ raw: String) -> String? {
        let value = trim(raw)
        guard !value.isEmpty else { return nil }
        return firstGroup("([0-9]+(?:\\.[0-9A-Za-z\\-]+)*)", 1, in: value)
    }

    /// 哪些 TOML 段里的 `key = value` 算依赖。
    static func pythonTableScope(_ section: String) -> DependencyScope? {
        switch section {
        case "packages": return .runtime
        case "dev-packages": return .dev
        case "tool.poetry.dependencies": return .runtime
        case "tool.poetry.dev-dependencies": return .dev
        case "tool.poetry.group.dependencies": return .dev
        default: break
        }
        if section.hasPrefix("tool.poetry.group.") && section.hasSuffix(".dependencies") {
            let group = section
                .replacingOccurrences(of: "tool.poetry.group.", with: "")
                .replacingOccurrences(of: ".dependencies", with: "")
            let devGroups: Set<String> = ["dev", "test", "tests", "lint", "docs", "ci", "tools", "typing", "quality"]
            return devGroups.contains(group) ? .dev : .runtime
        }
        return nil
    }

    /// 极简 TOML 扫描：返回 (段名, 键, 原样值)，多行数组 / 内联表已合并成一条。
    static func tomlEntries(in text: String) -> [(section: String, key: String, value: String)] {
        let rows = lines(text)
        var section = ""
        var result: [(String, String, String)] = []
        var index = 0
        while index < rows.count {
            let line = trim(stripHashComment(rows[index]))
            index += 1
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                section = trim(line.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
                continue
            }
            guard let groups = matches(of: "^([A-Za-z0-9_\"'\\.\\-]+)\\s*=(.*)$", in: line).first,
                  let key = groups[safe: 1], let rest = groups[safe: 2] else { continue }
            var value = trim(rest)
            while bracketBalance(value) > 0, index < rows.count {
                value += "\n" + trim(stripHashComment(rows[index]))
                index += 1
            }
            let cleanKey = key.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            result.append((section, cleanKey, value))
        }
        return result
    }

    /// 引号外的 `[`/`{` 与 `]`/`}` 差值。
    static func bracketBalance(_ text: String) -> Int {
        var open = 0
        var quote: Character?
        for ch in text {
            if let current = quote {
                if ch == current { quote = nil }
                continue
            }
            if ch == "\"" || ch == "'" { quote = ch; continue }
            if ch == "[" || ch == "{" { open += 1 }
            else if ch == "]" || ch == "}" { open -= 1 }
        }
        return open
    }

    /// 取出文本里所有引号字符串（数组元素、内联字符串都适用）。
    static func tomlStringList(_ text: String) -> [String] {
        quotedStrings(text)
    }
}

// MARK: - Go / go.mod

extension ManifestParsers {
    /// go.mod -> [DependencyRecord]。`// indirect` 记为 .unknown，其余 .runtime。
    /// 版本去掉 go 特有的 "v" 前缀与 "+incompatible"，以对齐 DependencyVersion 的点分比较。
    static func goModDependencies(_ text: String, manifestPath: String) -> [DependencyRecord] {
        var records: [DependencyRecord] = []
        var inRequireBlock = false
        var inIgnoredBlock = false
        for rawLine in lines(text) {
            let stripped = trim(stripSlashComment(rawLine))
            if stripped.isEmpty { continue }

            if inIgnoredBlock {
                if stripped == ")" { inIgnoredBlock = false }
                continue
            }
            if inRequireBlock && stripped == ")" {
                inRequireBlock = false
                continue
            }
            if !inRequireBlock {
                if stripped == "require (" || stripped.hasPrefix("require (") { inRequireBlock = true; continue }
                if stripped.hasPrefix("replace") || stripped.hasPrefix("exclude") || stripped.hasPrefix("retract") {
                    if stripped.contains("(") { inIgnoredBlock = true }
                    continue
                }
                if stripped.hasPrefix("module") || stripped.hasPrefix("go ") || stripped.hasPrefix("go\t")
                    || stripped == "go" || stripped.hasPrefix("toolchain") { continue }
            }

            var body = stripped
            if body.hasPrefix("require ") { body = trim(String(body.dropFirst("require ".count))) }
            let columns = body.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let modulePath = columns.first, !modulePath.isEmpty, modulePath != "(" else { continue }
            if modulePath.hasPrefix("//") || modulePath.hasPrefix("\"") { continue }
            let rawVersion = columns.count >= 2 ? columns[1] : undeclaredVersion
            let isIndirect = rawLine.lowercased().contains("// indirect")
            records.append(record(modulePath, goVersion(rawVersion), .go,
                                  isIndirect ? .unknown : .runtime, manifestPath))
        }
        return dedupe(records)
    }

    static func goVersion(_ raw: String) -> String {
        var value = trim(raw)
        if value.hasPrefix("v"), let first = value.dropFirst().first, first.isNumber {
            value = String(value.dropFirst())
        }
        if let plus = value.firstIndex(of: "+") { value = String(value[..<plus]) }
        return value.isEmpty ? undeclaredVersion : value
    }
}

// MARK: - Cargo / Cargo.toml

extension ManifestParsers {
    /// Cargo.toml -> [DependencyRecord]。
    static func cargoTomlDependencies(_ text: String, manifestPath: String) -> [DependencyRecord] {
        var records: [DependencyRecord] = []
        for entry in tomlEntries(in: text) {
            let section = entry.section.lowercased()
            guard section.hasSuffix("dependencies") || section.hasSuffix("dependency") else { continue }
            let scope: DependencyScope
            if section.contains("dev") { scope = .dev }
            else if section.contains("build") { scope = .build }
            else { scope = .runtime }
            let name = trim(entry.key)
            guard !name.isEmpty else { continue }
            let declared: String?
            if let inline = firstGroup("version\\s*=\\s*(['\"])([^'\"\\n]+)\\1", 2, in: entry.value) {
                declared = inline
            } else if trim(entry.value).hasPrefix("{") {
                declared = nil
            } else {
                declared = firstGroup("^\\s*(['\"])([^'\"\\n]+)\\1", 2, in: entry.value)
            }
            let version = trim(declared ?? undeclaredVersion)
            records.append(record(name, version.isEmpty || version == "*" ? undeclaredVersion : version,
                                  .cargo, scope, manifestPath))
        }
        return dedupe(records)
    }
}

// MARK: - CocoaPods / Podfile

extension ManifestParsers {
    /// Podfile -> [DependencyRecord]。`target 'Tests'` 段内或带 `:testables` 的记为 .test。
    static func podfileDependencies(_ text: String, manifestPath: String) -> [DependencyRecord] {
        var records: [DependencyRecord] = []
        var depth = 0
        var scopes: [DependencyScope] = []
        for rawLine in lines(text) {
            let line = trim(stripHashComment(rawLine))
            if line.isEmpty { continue }
            if line == "end" || line.hasPrefix("end ") {
                if depth > 0 { depth -= 1 }
                while scopes.count > depth { scopes.removeLast() }
                continue
            }
            let inherited = scopes.last ?? .runtime
            if line.hasPrefix("pod ") || line.hasPrefix("pod(") || line.hasPrefix("pod '") || line.hasPrefix("pod \"") {
                let strings = quotedStrings(line)
                guard let name = strings.first, !name.isEmpty else { continue }
                let scope = (line.contains("testables") || inherited == .test) ? DependencyScope.test : inherited
                let version = versionConstraint(from: Array(strings.dropFirst())) ?? undeclaredVersion
                records.append(record(name, version, .cocoapods, scope, manifestPath))
                continue
            }
            if opensBlock(line) {
                depth += 1
                scopes.append(blockScope(line) ?? inherited)
            }
        }
        return dedupe(records)
    }

    static func blockScope(_ line: String) -> DependencyScope? {
        let haystack = (quotedStrings(line) + [line]).map { $0.lowercased() }
        guard haystack.contains(where: { $0.contains("test") || $0.contains("spec") }) else { return nil }
        return .test
    }

    static func opensBlock(_ line: String) -> Bool {
        line.hasSuffix(" do") || line.contains(" do ") || line.hasSuffix(" {")
    }

    static func quotedStrings(_ line: String) -> [String] {
        matches(of: "(['\"])([^'\"\\n]+)\\1", in: line).compactMap { ManifestParsers.value(at: 2, in: $0) }
    }

    /// 从若干候选串里挑出第一个看着像版本约束的（"~> 1.2"、">= 0.9"、"1.2.3"）。
    static func versionConstraint(from candidates: [String]) -> String? {
        for candidate in candidates {
            let value = trim(candidate)
            if value.isEmpty || value.hasPrefix(":") || value.contains("=>") { continue }
            guard let first = value.first else { continue }
            if first.isNumber || first == "~" || first == ">" || first == "<" || first == "=" {
                return value
            }
        }
        return nil
    }
}

// MARK: - Ruby / Gemfile

extension ManifestParsers {
    /// Gemfile -> [DependencyRecord]。`group :test / :development / :production` 段影响 scope。
    static func gemfileDependencies(_ text: String, manifestPath: String) -> [DependencyRecord] {
        var records: [DependencyRecord] = []
        var depth = 0
        var scopes: [DependencyScope] = []
        for rawLine in lines(text) {
            let line = trim(stripHashComment(rawLine))
            if line.isEmpty { continue }
            if line == "end" || line.hasPrefix("end ") {
                if depth > 0 { depth -= 1 }
                while scopes.count > depth { scopes.removeLast() }
                continue
            }
            let inherited = scopes.last ?? .runtime
            if line.hasPrefix("gem ") || line.hasPrefix("gem(") || line.hasPrefix("gem '") || line.hasPrefix("gem \"") {
                let strings = quotedStrings(line)
                guard let name = strings.first, !name.isEmpty else { continue }
                let scope = gemInlineScope(line) ?? inherited
                let version = versionConstraint(from: Array(strings.dropFirst())) ?? undeclaredVersion
                records.append(record(name, version, .ruby, scope, manifestPath))
                continue
            }
            if line.hasPrefix("group ") {
                depth += 1
                scopes.append(gemGroupScope(line))
                continue
            }
            if opensBlock(line) || line.hasPrefix("if ") {
                depth += 1
                scopes.append(inherited)
            }
        }
        return dedupe(records)
    }

    static func gemGroupScope(_ line: String) -> DependencyScope {
        let symbols = matches(of: ":([A-Za-z0-9_]+)", in: line)
            .compactMap { ManifestParsers.value(at: 1, in: $0) }
            .map { $0.lowercased() }
        return rubyScope(forGroups: symbols)
    }

    /// group 名到 scope 的容错映射（:test/:tests/:spec -> 测试，:dev/:style/:lint/:typecheck/:doc -> 开发）。
    static func rubyScope(forGroups symbols: [String]) -> DependencyScope {
        for symbol in symbols {
            if symbol.contains("test") || symbol.contains("spec") { return .test }
        }
        let devHints = ["dev", "lint", "style", "typecheck", "doc", "check", "audit", "quality", "format", "debug", "tool"]
        for symbol in symbols where devHints.contains(where: { symbol.contains($0) }) { return .dev }
        return .runtime
    }

    static func gemInlineScope(_ line: String) -> DependencyScope? {
        guard let body = firstGroup("groups?\\s*:\\s*\\[([^\\]]*)\\]", 1, in: line) else { return nil }
        let symbols = matches(of: ":([A-Za-z0-9_]+)", in: body)
            .compactMap { ManifestParsers.value(at: 1, in: $0) }
            .map { $0.lowercased() }
        guard !symbols.isEmpty else { return nil }
        return rubyScope(forGroups: symbols)
    }
}

// MARK: - NuGet / packages.config

extension ManifestParsers {
    /// packages.config -> [DependencyRecord]。developmentDependency="true" 记为 .dev。
    static func nugetPackagesConfigDependencies(_ text: String, manifestPath: String) -> [DependencyRecord] {
        var records: [DependencyRecord] = []
        for groups in matches(of: "<package\\b([^>]*?)/?>", in: text) {
            guard let attributes = groups[safe: 1] else { continue }
            guard let name = nugetAttribute("id", in: attributes), !name.isEmpty else { continue }
            let version = nugetAttribute("version", in: attributes) ?? undeclaredVersion
            let development = (nugetAttribute("developmentDependency", in: attributes) ?? "").lowercased() == "true"
            records.append(record(name, version, .nuget, development ? .dev : .runtime, manifestPath))
        }
        return dedupe(records)
    }

    static func nugetAttribute(_ key: String, in attributes: String) -> String? {
        firstGroup("(?<![A-Za-z0-9_])\(key)\\s*=\\s*(['\"])([^'\"\\n]*)\\1", 2, in: attributes)
    }
}

// MARK: - 下标安全访问

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - pom.xml 中间模型

/// pom.xml 的中间模型：`<properties>` 表 + dependencyManagement 版本表 + 真实依赖条目。
/// 用 XMLParser 走一遍，命名空间前缀会被剥掉；解析中断就返回已收集到的部分，不抛异常。
private final class PomDocumentModel: NSObject, XMLParserDelegate {
    struct Entry {
        var group = ""
        var artifact = ""
        var version = ""
        var scope = ""
        var fromPlugin = false
    }

    private var properties: [String: String] = [:]
    private var rootGroup = ""
    private var rootArtifact = ""
    private var rootVersion = ""
    private var parentGroup = ""
    private var parentVersion = ""
    private var entries: [Entry] = []
    private var managedEntries: [Entry] = []
    private var stack: [String] = []
    private var characters = ""

    init(text: String) {
        super.init()
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard let data = normalized.data(using: .utf8) else { return }
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        let name = Self.localName(elementName)
        stack.append(name)
        characters = ""
        if name == "dependency" {
            var entry = Entry()
            entry.fromPlugin = stack.contains("plugin") || stack.contains("plugins")
            if stack.contains("dependencyManagement") {
                managedEntries.append(entry)
            } else {
                entries.append(entry)
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        characters += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let name = Self.localName(elementName)
        let value = characters.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = stack.count >= 2 ? stack[stack.count - 2] : ""
        if !value.isEmpty { route(name: name, parent: parent, value: value) }
        if !stack.isEmpty { stack.removeLast() }
        characters = ""
    }

    private func route(name: String, parent: String, value: String) {
        if parent == "dependency" {
            let inManagement = stack.contains("dependencyManagement")
            var list = inManagement ? managedEntries : entries
            guard !list.isEmpty, var entry = list.popLast() else { return }
            switch name {
            case "groupId": entry.group = value
            case "artifactId": entry.artifact = value
            case "version": entry.version = value
            case "scope": entry.scope = value
            default: return
            }
            list.append(entry)
            if inManagement { managedEntries = list } else { entries = list }
            return
        }
        if parent == "properties" {
            properties[name] = value
            return
        }
        if parent == "parent" {
            if name == "groupId" { parentGroup = value }
            if name == "version" { parentVersion = value }
            return
        }
        if stack.count == 2 {
            switch name {
            case "groupId": rootGroup = value
            case "artifactId": rootArtifact = value
            case "version": rootVersion = value
            default: break
            }
        }
    }

    private static func localName(_ elementName: String) -> String {
        elementName.split(separator: ":").last.map(String.init) ?? elementName
    }

    // MARK: 属性代入

    /// `${xxx.version}` / `${project.version}` 代入；代不了的那一段保留原文。
    private func resolve(_ raw: String, depth: Int = 0) -> String {
        guard depth < 3, raw.contains("${") else { return raw }
        let chars = Array(raw)
        var result = ""
        var index = 0
        while index < chars.count {
            if chars[index] == "$", index + 1 < chars.count, chars[index + 1] == "{" {
                var end = index + 2
                while end < chars.count, chars[end] != "}" { end += 1 }
                if end < chars.count {
                    let key = String(chars[(index + 2)..<end])
                    if let value = substitution(for: key) {
                        result += resolve(value, depth: depth + 1)
                    } else {
                        result += String(chars[index...end])
                    }
                    index = end + 1
                    continue
                }
            }
            result.append(chars[index])
            index += 1
        }
        return result
    }

    private func substitution(for key: String) -> String? {
        if let hit = properties[key], !hit.isEmpty { return hit }
        switch key {
        case "project.version", "version":
            let candidate = rootVersion.isEmpty ? parentVersion : rootVersion
            return candidate.isEmpty ? nil : candidate
        case "project.groupId", "groupId":
            let candidate = rootGroup.isEmpty ? parentGroup : rootGroup
            return candidate.isEmpty ? nil : candidate
        case "project.artifactId", "artifactId":
            return rootArtifact.isEmpty ? nil : rootArtifact
        case "project.parent.version":
            return parentVersion.isEmpty ? nil : parentVersion
        case "project.parent.groupId":
            return parentGroup.isEmpty ? nil : parentGroup
        default:
            return nil
        }
    }

    // MARK: 出结果

    func dependencyRecords(manifestPath: String) -> [DependencyRecord] {
        var managedVersions: [String: String] = [:]
        for item in managedEntries {
            let group = resolve(item.group.isEmpty ? rootGroup : item.group)
            let artifact = resolve(item.artifact)
            let version = resolve(item.version)
            guard !group.isEmpty, !artifact.isEmpty, !version.isEmpty else { continue }
            managedVersions["\(group):\(artifact)"] = version
        }

        var records: [DependencyRecord] = []
        for item in entries {
            let group = resolve(item.group.isEmpty ? rootGroup : item.group)
            let artifact = resolve(item.artifact)
            guard !artifact.isEmpty else { continue }
            var version = resolve(item.version)
            if version.isEmpty { version = resolve(managedVersions["\(group):\(artifact)"] ?? "") }
            if version.isEmpty { version = ManifestParsers.undeclaredVersion }
            let scope: DependencyScope
            if item.fromPlugin && item.scope.isEmpty {
                scope = .build
            } else {
                switch item.scope.lowercased() {
                case "test": scope = .test
                case "provided": scope = .platform
                default: scope = .runtime
                }
            }
            let name = group.isEmpty ? artifact : "\(group):\(artifact)"
            records.append(ManifestParsers.record(name, version, .maven, scope, manifestPath))
        }
        return ManifestParsers.dedupe(records)
    }
}
