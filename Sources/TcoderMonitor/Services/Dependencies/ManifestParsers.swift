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
    /// 文件名 -> 生态。覆盖 DependencyEcosystem.manifestNames 的全部名字。
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
        let names = dependencies.map(\.name)
        return ParsedManifest(
            ecosystem: ecosystem,
            manifestRelativePath: manifestPath,
            directoryRelativePath: directoryRelativePath,
            dependencies: dependencies,
            lockfileName: lockfileName(for: ecosystem, in: directoryListing),
            frameworkMarkers: frameworkMarkers(ecosystem: ecosystem, dependencyNames: names)
        )
    }

    /// pom.xml 里 <modules><module>x</module></modules> 抽出的相对模块目录名（多模块工程递归用）。
    static func mavenModulePaths(in pomText: String) -> [String] {
        var found: [String] = []
        var seen = Set<String>()
        for groups in matches(of: "<module>\\s*([^<]*?)\\s*</module>", in: pomText) {
            guard let raw = groups.last, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
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
            for rule in markerRules where rule.matches(ecosystem) {
                guard rule.keys.contains(where: { containsPhrase(tokens, $0) }) else { continue }
                counts[rule.marker, default: 0] += 1
                break
            }
        }
        // 次级键：多规则命中同一 marker 的情况已在上面按 dep 计数，这里只排 marker
        var merged: [String: Int] = [:]
        for (marker, count) in counts {
            let display = marker
            merged[display, default: 0] += count
        }
        let sorted = merged.sorted { lhs, rhs in
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

    // MARK: - 内部工具

    private static func fileName(of path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private static func trim(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 统一换行，返回按行切开的数组（不含换行符）。
    private static func lines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    /// 未声明版本时的占位，保持与契约里 "未声明" 一致。
    static let undeclaredVersion = "未声明"

    private static func record(_ name: String,
                               _ version: String,
                               _ ecosystem: DependencyEcosystem,
                               _ scope: DependencyScope,
                               _ manifestPath: String) -> DependencyRecord {
        let cleanedName = trim(name)
        let cleanedVersion = trim(version).isEmpty ? undeclaredVersion : trim(version)
        return DependencyRecord(
            name: cleanedName,
            version: cleanedVersion,
            ecosystem: ecosystem,
            scope: scope,
            manifestPath: manifestPath,
            latestKnownVersion: nil,
            versionCheckSource: VersionCheckSource.none,
            knownVulnerabilities: []
        )
    }

    /// 清单内按 name 去重，后出现的覆盖前者的取值（顺序按首次出现）。
    private static func dedupe(_ records: [DependencyRecord]) -> [DependencyRecord] {
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

    /// 正则枚举，返回每条匹配的分组数组（group 0 为整条匹配，未命中为 nil）。
    private static func matches(of pattern: String, in text: String) -> [[String?]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var out: [[String?]] = []
        out.reserveCapacity(16)
        regex.enumerateMatches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) { result, _, _ in
            guard let result else { return }
            var groups: [String?] = []
            for index in 0..<result.numberOfRanges {
                let range = result.range(at: index)
                groups.append(range.location == NSNotFound ? nil : ns.substring(with: range))
            }
            out.append(groups)
        }
        return out
    }

    private static func firstGroup(_ pattern: String, _ group: Int, in text: String) -> String? {
        for groups in matches(of: pattern, in: text) {
            if group < groups.count, let value = groups[group], !value.isEmpty { return value }
        }
        return nil
    }

    /// 去掉行内注释：`//` 只在引号外才算注释（避免误伤 "https://..."）。
    private static func stripSlashComment(_ line: String) -> String {
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

    /// Python 风格注释：行首 `#` 或 空白后的 `#` 之后全部丢弃。
    private static func stripHashComment(_ line: String) -> String {
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

    /// 把依赖名切成小写 token：按非字母数字切，并拆 camelCase（"SwiftUI" -> swift,ui）。
    private static func tokens(of name: String) -> [String] {
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
        return result
    }

    private static func containsPhrase(_ tokens: [String], _ phrase: [String]) -> Bool {
        guard !phrase.isEmpty, tokens.count >= phrase.count else { return false }
        for start in 0...(tokens.count - phrase.count) {
            if Array(tokens[start..<(start + phrase.count)]) == phrase { return true }
        }
        return false
    }

    private struct MarkerRule {
        let marker: String
        let ecosystems: Set<DependencyEcosystem>
        let keys: [[String]]
        /// ecosystems 为空集表示不限生态。
        func matches(_ ecosystem: DependencyEcosystem) -> Bool {
            ecosystems.isEmpty || ecosystems.contains(ecosystem)
        }
    }

    private static let markerRules: [MarkerRule] = [
        // 前端
        MarkerRule(marker: "React", ecosystems: [], keys: [["react"]]),
        MarkerRule(marker: "React Native", ecosystems: [.npm, .maven, .gradle, .unknown], keys: [["react", "native"]]),
        MarkerRule(marker: "React DOM", ecosystems: [.npm, .unknown], keys: [["react", "dom"]]),
        MarkerRule(marker: "Redux", ecosystems: [.npm, .unknown], keys: [["redux"], ["rematch"]]),
        MarkerRule(marker: "MobX", ecosystems: [.npm, .unknown], keys: [["mobx"]]),
        MarkerRule(marker: "Vue", ecosystems: [.npm, .unknown], keys: [["vue"]]),
        MarkerRule(marker: "Vue Router", ecosystems: [.npm, .unknown], keys: [["vue", "router"]]),
        MarkerRule(marker: "Pinia", ecosystems: [.npm, .unknown], keys: [["pinia"]]),
        MarkerRule(marker: "Vite", ecosystems: [.npm, .unknown], keys: [["vite"], ["vitejs"], ["vitest"]]),
        MarkerRule(marker: "Next.js", ecosystems: [.npm, .unknown], keys: [["next"]]),
        MarkerRule(marker: "Nuxt", ecosystems: [.npm, .unknown], keys: [["nuxt"]]),
        MarkerRule(marker: "Angular", ecosystems: [.npm, .unknown], keys: [["angular"], ["ng", "bootstrap"]]),
        MarkerRule(marker: "Svelte", ecosystems: [.npm, .unknown], keys: [["svelte"]]),
        MarkerRule(marker: "Express", ecosystems: [.npm, .unknown], keys: [["express"]]),
        MarkerRule(marker: "Koa", ecosystems: [.npm, .unknown], keys: [["koa"]]),
        MarkerRule(marker: "NestJS", ecosystems: [.npm, .unknown], keys: [["nest"], ["nestjs"]]),
        MarkerRule(marker: "TypeScript", ecosystems: [.npm, .unknown], keys: [["typescript"], ["ts", "node"]]),
        MarkerRule(marker: "Electron", ecosystems: [.npm, .unknown], keys: [["electron"]]),
        MarkerRule(marker: "Tailwind CSS", ecosystems: [.npm, .unknown], keys: [["tailwindcss"], ["tailwind", "css"], ["tailwind"]]),
        MarkerRule(marker: "Webpack", ecosystems: [.npm, .unknown], keys: [["webpack"]]),
        MarkerRule(marker: "Babel", ecosystems: [.npm, .unknown], keys: [["babel"]]),
        MarkerRule(marker: "ESLint", ecosystems: [.npm, .unknown], keys: [["eslint"]]),
        MarkerRule(marker: "Prettier", ecosystems: [.npm, .unknown], keys: [["prettier"]]),
        MarkerRule(marker: "Jest", ecosystems: [.npm, .unknown], keys: [["jest"]]),
        MarkerRule(marker: "Axios", ecosystems: [.npm, .unknown], keys: [["axios"], ["is", "stream"]]),
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
        MarkerRule(marker: "Sentinel", ecosystems: [.maven, .gradle, .unknown], keys: [["sentinel"]]),
        MarkerRule(marker: "Seata", ecosystems: [.maven, .gradle, .unknown], keys: [["seata"]]),
        MarkerRule(marker: "Nacos", ecosystems: [.maven, .gradle, .unknown], keys: [["nacos"]]),
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
        MarkerRule(marker: "SwiftUI", ecosystems: [], keys: [["swift", "ui"]]),
        MarkerRule(marker: "GRDB", ecosystems: [.swiftPM, .cocoapods, .unknown], keys: [["grdb"]]),
        MarkerRule(marker: "Alamofire", ecosystems: [.swiftPM, .cocoapods, .unknown], keys: [["alamofire"]]),
        MarkerRule(marker: "SnapKit", ecosystems: [.swiftPM, .cocoapods, .unknown], keys: [["snapkit"], ["snap", "kit"]]),
        MarkerRule(marker: "Moya", ecosystems: [.swiftPM, .cocoapods, .unknown], keys: [["moya"]]),
        MarkerRule(marker: "Kingfisher", ecosystems: [.swiftPM, .cocoapods, .unknown], keys: [["kingfisher"]]),
        MarkerRule(marker: "RxSwift", ecosystems: [.swiftPM, .cocoapods, .unknown], keys: [["rx", "swift"], ["rxcocoa"]]),
        MarkerRule(marker: "Realm", ecosystems: [.swiftPM, .cocoapods, .unknown], keys: [["realm", "swift"], ["realm"]]),
        MarkerRule(marker: "YYModel", ecosystems: [.cocoapods, .swiftPM, .unknown], keys: [["yy", "model"]]),
        MarkerRule(marker: "SDWebImage", ecosystems: [.cocoapods, .swiftPM, .unknown], keys: [["sd", "web", "image"], ["web", "image"]]),
        MarkerRule(marker: "Chart", ecosystems: [.cocoapods, .swiftPM, .unknown], keys: [["charts"], ["dc", "charts"]]),
        MarkerRule(marker: "SwiftLint", ecosystems: [.swiftPM, .cocoapods, .unknown], keys: [["swiftlint"]]),
        MarkerRule(marker: "Firebase", ecosystems: [.cocoapods, .swiftPM, .gradle, .npm, .unknown], keys: [["firebase"]]),
        // Go
        MarkerRule(marker: "Gin", ecosystems: [.go, .unknown], keys: [["gin"]]),
        MarkerRule(marker: "Echo", ecosystems: [.go, .unknown], keys: [["echo"]]),
        MarkerRule(marker: "Fiber", ecosystems: [.go, .unknown], keys: [["fiber"]]),
        MarkerRule(marker: "GORM", ecosystems: [.go, .unknown], keys: [["gorm"]]),
        MarkerRule(marker: "Cobra", ecosystems: [.go, .unknown], keys: [["cobra"]]),
        MarkerRule(marker: "Zap", ecosystems: [.go, .unknown], keys: [["zap"]]),
        MarkerRule(marker: "Viper", ecosystems: [.go, .unknown], keys: [["viper"]]),
        // Rust
        MarkerRule(marker: "Tokio", ecosystems: [.cargo, .unknown], keys: [["tokio"]]),
        MarkerRule(marker: "Serde", ecosystems: [.cargo, .unknown], keys: [["serde"]]),
        MarkerRule(marker: "Actix Web", ecosystems: [.cargo, .unknown], keys: [["actix"]]),
        MarkerRule(marker: "Reqwest", ecosystems: [.cargo, .unknown], keys: [["reqwest"]]),
        MarkerRule(marker: "Clap", ecosystems: [.cargo, .unknown], keys: [["clap"]]),
        MarkerRule(marker: "Rocket", ecosystems: [.cargo, .unknown], keys: [["rocket"]]),
        MarkerRule(marker: "Anyhow", ecosystems: [.cargo, .unknown], keys: [["anyhow"]]),
        MarkerRule(marker: "Tracing", ecosystems: [.cargo, .unknown], keys: [["tracing"]]),
        // Python
        MarkerRule(marker: "Django", ecosystems: [.python, .unknown], keys: [["django"]]),
        MarkerRule(marker: "Django REST Framework", ecosystems: [.python, .unknown], keys: [["rest", "framework"], ["djangorestframework"]]),
        MarkerRule(marker: "Flask", ecosystems: [.python, .unknown], keys: [["flask"]]),
        MarkerRule(marker: "FastAPI", ecosystems: [.python, .unknown], keys: [["fastapi"]]),
        MarkerRule(marker: "Uvicorn", ecosystems: [.python, .unknown], keys: [["uvicorn"]]),
        MarkerRule(marker: "Gunicorn", ecosystems: [.python, .unknown], keys: [["gunicorn"]]),
        MarkerRule(marker: "Pydantic", ecosystems: [.python, .unknown], keys: [["pydantic"]]),
        MarkerRule(marker: "SQLAlchemy", ecosystems: [.python, .unknown], keys: [["sqlalchemy"]]),
        MarkerRule(marker: "Alembic", ecosystems: [.python, .unknown], keys: [["alembic"]]),
        MarkerRule(marker: "Celery", ecosystems: [.python, .unknown], keys: [["celery"]]),
        MarkerRule(marker: "NumPy", ecosystems: [.python, .unknown], keys: [["numpy"]]),
        MarkerRule(marker: "Pandas", ecosystems: [.python, .unknown], keys: [["pandas"]]),
        MarkerRule(marker: "SciPy", ecosystems: [.python, .unknown], keys: [["scipy"]]),
        MarkerRule(marker: "Matplotlib", ecosystems: [.python, .unknown], keys: [["matplotlib"]]),
        MarkerRule(marker: "Scikit-learn", ecosystems: [.python, .unknown], keys: [["scikit"]]),
        MarkerRule(marker: "PyTorch", ecosystems: [.python, .unknown], keys: [["torch"], ["pytorch"]]),
        MarkerRule(marker: "TensorFlow", ecosystems: [.python, .unknown], keys: [["tensorflow"]]),
        MarkerRule(marker: "Jupyter", ecosystems: [.python, .unknown], keys: [["jupyter"], ["ipykernel"], ["ipython"]]),
        MarkerRule(marker: "pytest", ecosystems: [.python, .unknown], keys: [["pytest"]]),
        MarkerRule(marker: "Requests", ecosystems: [.python, .unknown], keys: [["requests"], ["httpx"], ["aiohttp"]]),
        MarkerRule(marker: "Ruff", ecosystems: [.python, .unknown], keys: [["ruff"]]),
        MarkerRule(marker: "Mypy", ecosystems: [.python, .unknown], keys: [["mypy"]]),
        MarkerRule(marker: "Black", ecosystems: [.python, .unknown], keys: [["black"]]),
        MarkerRule(marker: "Poetry", ecosystems: [.python, .unknown], keys: [["poetry"]]),
        // Ruby
        MarkerRule(marker: "Ruby on Rails", ecosystems: [.ruby, .unknown], keys: [
            ["rails"], ["railties"], ["activerecord"], ["activesupport"], ["actionpack"], ["actionview"], ["ActiveRecord"]
                .flatMap { tokens(of: $0) },
        ]),
        MarkerRule(marker: "RSpec", ecosystems: [.ruby, .unknown], keys: [["rspec"]]),
        MarkerRule(marker: "Sidekiq", ecosystems: [.ruby, .unknown], keys: [["sidekiq"]]),
        MarkerRule(marker: "Puma", ecosystems: [.ruby, .unknown], keys: [["puma"]]),
        MarkerRule(marker: "Devise", ecosystems: [.ruby, .unknown], keys: [["devise"]]),
        MarkerRule(marker: "Nokogiri", ecosystems: [.ruby, .unknown], keys: [["nokogiri"]]),
        // .NET
        MarkerRule(marker: "ASP.NET Core", ecosystems: [.nuget, .unknown], keys: [["asp", "net"], ["net", "core"]]),
        MarkerRule(marker: "Entity Framework Core", ecosystems: [.nuget, .unknown], keys: [["entity", "framework"]]),
        MarkerRule(marker: "Newtonsoft.Json", ecosystems: [.nuget, .unknown], keys: [["newtonsoft"]]),
        MarkerRule(marker: "Serilog", ecosystems: [.nuget, .unknown], keys: [["serilog"]]),
        MarkerRule(marker: "Dapper", ecosystems: [.nuget, .unknown], keys: [["dapper"]]),
        MarkerRule(marker: "xUnit", ecosystems: [.nuget, .unknown], keys: [["xunit"]]),
        MarkerRule(marker: "NUnit", ecosystems: [.nuget, .unknown], keys: [["nunit"]]),
        MarkerRule(marker: "Moq", ecosystems: [.nuget, .unknown], keys: [["moq"]]),
    ]

    // MARK: - 锁文件判定表

    private static let lockfileCandidates: [DependencyEcosystem: [String]] = [
        .npm: [
            "package-lock.json", "npm-shrinkwrap.json", "pnpm-lock.yaml", "pnpm-lock.yml",
            "yarn.lock", "bun.lockb", "bun.lock", "deno.lock",
        ],
        .maven: [],
        .gradle: ["gradle.lockfile", "dependencies.lock"],
        .swiftPM: ["Package.resolved"],
        .python: [
            "poetry.lock", "Pipfile.lock", "uv.lock", "pdm.lock", "hatch.lock",
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
        return records
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
    /// pom.xml -> [DependencyRecord]。name 为 "groupId:artifactId"，
    /// dependencyManagement 的版本与 <properties> 会代入实际 dependencies 条目。
    static func pomXMLDependencies(_ text: String, manifestPath: String) -> [DependencyRecord] {
        let model = PomDocumentModel(text: text)
        return model.dependencyRecords(manifestPath: manifestPath)
    }
}

/// pom.xml 的中间模型：properties 表 + dependencyManagement 版本表 + 真实依赖条目。
private final class PomDocumentModel: NSObject, XMLParserDelegate {
    private struct Entry {
        var group: String = ""
        var artifact: String = ""
        var version: String = ""
        var scope: String = ""
        var fromPlugin: Bool = false
    }

    private var properties: [String: String] = [:]
    private var managedVersions: [String: String] = [:]
    private var rootGroup: String = ""
    private var rootVersion: String = ""
    private var rootArtifact: String = ""
    private var parentGroup: String = ""
    private var parentVersion: String = ""
    private var entries: [Entry] = []
    private var managed: [Entry] = []

    private var stack: [String] = []
    private var text = ""

    init(text: String) {
        super.init()
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard let data = normalized.data(using: .utf8) else { return }
        let parser = XMLParser(data: data)
        parser.delegate = self
        // 解析失败时就返回已收集到的部分，绝不抛异常。
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = Self.local(elementName)
        stack.append(name)
        text = ""
        if name == "dependency" {
            entries.append(Entry())
            if stack.contains("dependencyManagement") { managed.append(entries.removeLast()) }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let name = Self.local(elementName)
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = stack.count >= 2 ? stack[stack.count - 2] : ""
        let isLeaf = !value.isEmpty

        if isLeaf {
            if parent == "dependency" {
                let index = stack.contains("dependencyManagement") ? managed.count - 1 : entries.count - 1
                guard index >= 0 else { break }
                var entry = stack.contains("dependencyManagement") ? managed[index] : entries[index]
                entry.fromPlugin = stack.contains("plugin") || stack.contains("plugins")
                switch name {
                case "groupId": entry.group = value
                case "artifactId": entry.artifact = value
                case "version": entry.version = value
                case "scope": entry.scope = value
                default: break
                }
                if stack.contains("dependencyManagement") { managed[index] = entry } else { entries[index] = entry }
            } else if parent == "properties" {
                properties[name] = value
            } else if parent == "module" {
                break // 模块名由 mavenModulePaths(in:) 单独提供
            } else if stack.count == 2 {
                switch name {
                case "groupId": rootGroup = value
                case "artifactId": rootArtifact = value
                case "version": rootVersion = value
                default: break
                }
            } else if parent == "parent" {
                switch name {
                case "groupId": parentGroup = value
                case "version": parentVersion = value
                default: break
                }
            }
        }
        if !stack.isEmpty { stack.removeLast() }
        if name == "dependency" { text = ""; return }
        text = ""
    }

    private static func local(_ elementName: String) -> String {
        elementName.split(separator: ":").last.map(String.init) ?? elementName
    }

    /// 属性 / 内置变量代入；代不了保留原文。
    private func resolve(_ raw: String) -> String {
        guard raw.contains("${") else { return raw }
        var result = raw
        let pattern = "\\$\\{([^}]*)\\}"
        // 迭代两轮，支持属性里再引用属性。
        for _ in 0..<2 {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { break }
            let ns = result as NSString
            var replacements: [(NSRange, String)] = []
            regex.enumerateMatches(in: result, options: [], range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                guard let match, match.numberOfRanges > 1 else { return }
                let keyRange = match.range(at: 1)
                let key = ns.substring(with: keyRange)
                let fullRange = match.range(at: 0)
                switch key {
                case "project.version", "version":
                    replacements.append((fullRange, result(forVersion: true)))
                case "project.groupId", "groupId":
                    replacements.append((fullRange, firstNonEmpty(rootGroup, parentGroup)))
                case "project.artifactId", "artifactId":
                    replacements.append((fullRange, rootArtifact))
                case "project.parent.version":
                    replacements.append((fullRange, parentVersion))
                case "project.parent.groupId":
                    replacements.append((fullRange, parentGroup))
                default:
                    if let hit = properties[key] { replacements.append((fullRange, hit)) }
                }
            }
            guard !replacements.isEmpty else { break }
            var mutable = result
            for (range, value) in replacements.reversed() {
                guard let swiftRange = Range(range, in: mutable) else { continue }
                mutable.replaceSubrange(swiftRange, with: value)
            }
            result = mutable
        }
        return result
    }

    private func firstNonEmpty(_ values: String...) -> String {
        values.first { !$0.isEmpty } ?? ""
    }

    private func result(forVersion isVersion: Bool) -> String {
        guard isVersion else { return "" }
        return firstNonEmpty(rootVersion, properties["revision"], parentVersion)
    }

    func dependencyRecords(manifestPath: String) -> [DependencyRecord] {
        // 先建 dependencyManagement 版本表
        for item in managed {
            let group = resolve(item.group.isEmpty ? rootGroup : item.group)
            let artifact = resolve(item.artifact)
            let version = resolve(item.version)
            guard !group.isEmpty, !artifact.isEmpty, !version.isEmpty else { continue }
            managedVersions["\(group):\(artifact)"] = version
        }

        var records: [DependencyRecord] = []
        for item in entries {
            let groupValue = resolve(item.group.isEmpty ? rootGroup : item.group)
            let artifactValue = resolve(item.artifact)
            guard !artifactValue.isEmpty else { continue }
            let key = "\(groupValue):\(artifactValue)"
            var versionValue = resolve(item.version)
            if versionValue.isEmpty { versionValue = managedVersions[key] ?? "" }
            // 管理表里也可能带 ${}，再代一次
            versionValue = resolve(versionValue)
            if versionValue.isEmpty { versionValue = PomDocumentModel.placeholder }

            let scope: DependencyScope
            if item.fromPlugin && item.scope.isEmpty {
                scope = .build
            } else {
                switch item.scope.lowercased() {
                case "test": scope = .test
                case "provided": scope = .platform
                case "runtime", "compile", "system", "", "import": scope = .runtime
                default: scope = .runtime
                }
            }
            let name = groupValue.isEmpty ? artifactValue : "\(groupValue):\(artifactValue)"
            records.append(DependencyRecord(
                name: name,
                version: versionValue,
                ecosystem: .maven,
                scope: scope,
                manifestPath: manifestPath,
                latestKnownVersion: nil,
                versionCheckSource: VersionCheckSource.none,
                knownVulnerabilities: []
            ))
        }
        return records
    }

    static let placeholder = "未声明"
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
        "kaptest": .test,
        "kaptandroidtest": .test,
        "compileonly": .build,
        "kapt": .build,
        "annotationprocessor": .build,
        "corelibrarydesugaring": .build,
        "detekt": .build,
        "spotless": .build,
    ]

    private static func gradleScope(for configuration: String) -> DependencyScope? {
        let key = configuration.lowercased()
        if let known = gradleConfigScopes[key] { return known }
        let isTest = key.contains("test") || key.contains("spec")
        if key.hasSuffix("implementation") || key.hasSuffix("api") { return isTest ? .test : .runtime }
        if key.hasSuffix("classpath") { return .runtime }
        if key.hasSuffix("only") { return key.contains("runtime") ? .runtime : (isTest ? .test : .build) }
        if key.hasPrefix("kapt") || key.contains("processor") { return isTest ? .test : .build }
        return nil
    }

    /// build.gradle / build.gradle.kts -> [DependencyRecord]。
    /// 支持 `implementation 'g:a:v'`、`api("g:a:v")`、map 写法、`library("别名","g:a:v")`、`id(...) version "..."`。
    static func gradleDependencies(_ text: String, manifestPath: String) -> [DependencyRecord] {
        let body = lines(text).map { stripSlashComment($0) }.joined(separator: "\n")
        var records: [DependencyRecord] = []

        // 1) 配置名 + 字符串坐标
        let coordPattern = "\\b([A-Za-z][A-Za-z0-9_]*)\\s*\\(?\\s*(?:platform\\s*\\(\\s*)?(['\"])([^'\"\\n]+)\\2"
        for groups in matches(of: coordPattern, in: body) {
            guard let config = groups[1], let coordinate = groups[3],
                  let scope = gradleScope(for: config) else { continue }
            guard let (name, version) = gradleCoordinate(coordinate) else { continue }
            records.append(record(name, version, .gradle, scope, manifestPath))
        }

        // 2) map 写法：implementation group: 'g', name: 'a', version: 'v'
        let mapPattern = "\\b([A-Za-z][A-Za-z0-9_]*)\\s*\\(?\\s*group\\s*:\\s*(['\"])([^'\"\\n]+)\\2\\s*,\\s*name\\s*:\\s*(['\"])([^'\"\\n]+)\\4\\s*(?:,\\s*version\\s*:\\s*(['\"])([^'\"\\n]+)\\6)?"
        for groups in matches(of: mapPattern, in: body) {
            guard let config = groups[1], let group = groups[3], let artifact = groups[5],
                  let scope = gradleScope(for: config) else { continue }
            let version = groups.count > 7 ? (groups[7] ?? undeclaredVersion) : undeclaredVersion
            records.append(record("\(group):\(artifact)", version, .gradle, scope, manifestPath))
        }

        // 3) 版本目录（settings.gradle 里的 version catalogs）：library("别名", "g:a:v")
        for groups in matches(of: "\\blibrary\\s*\\(\\s*(['\"])([^'\"\\n]+)\\1\\s*,\\s*(['\"])([^'\"\\n]+)\\3", in: body) {
            guard let coordinate = groups[4], let (name, version) = gradleCoordinate(coordinate) else { continue }
            records.append(record(name, version, .gradle, .runtime, manifestPath))
        }

        // 4) 插件声明：id("org.springframework.boot") version "3.2.0" / kotlin("jvm") version "1.9.22"
        let pluginPattern = "\\b(?:id|kotlin)\\s*\\(?\\s*(['\"])([A-Za-z0-9_.\\-]+)\\1\\s*\\)?\\s+version\\s+(['\"])([^'\"\\n]+)\\3"
        for groups in matches(of: pluginPattern, in: body) {
            guard let rawID = groups[2], let version = groups[4] else { continue }
            let name: String
            if rawID.contains(".") { name = rawID }
            else { name = "org.jetbrains.kotlin.\(rawID)" }
            if gradleCoordinate(name) != nil { continue } // 像坐标的（g:a）交给上面的规则
            records.append(record(name, version, .gradle, .build, manifestPath))
        }

        return records
    }

    /// "g:a:v" / "g:a" / "g:a:v@jar" / "g:a:v:classifier" -> (name, version)；不像坐标返回 nil。
    private static func gradleCoordinate(_ raw: String) -> (name: String, version: String)? {
        let coordinate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if coordinate.isEmpty || coordinate.contains("://") || coordinate.contains(" ") { return nil }
        if coordinate.hasPrefix("/") || coordinate.hasPrefix("\\") { return nil }
        var parts = coordinate.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return nil }
        parts = parts.map { part in
            guard let at = part.firstIndex(of: "@") else { return part }
            return String(part[..<at])
        }
        let group = parts[0].trimmingCharacters(in: .whitespaces)
        let artifact = parts[1].trimmingCharacters(in: .whitespaces)
        guard !group.isEmpty, !artifact.isEmpty else { return nil }
        // 至少看着像包名/模块名（含字母）
        guard group.contains(where: { $0.isLetter }), artifact.contains(where: { $0.isLetter }) else { return nil }
        let version: String
        if parts.count >= 3, !parts[2].isEmpty {
            version = parts[2]
        } else {
            version = undeclaredVersion
        }
        return ("\(group):\(artifact)", version)
    }
}

// MARK: - Swift Package Manager / Package.swift

extension ManifestParsers {
    /// Package.swift -> [DependencyRecord]。`.package(path:)` 是本地模块，不计入。
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
            guard let argumentsRange = argumentsRange(after: argumentsStart, in: ns) else {
                searchStart = argumentsStart
                continue
            }
            let arguments = ns.substring(with: NSRange(location: argumentsStart, length: argumentsRange))
            searchStart = argumentsStart + argumentsRange
            if let entry = swiftPackageEntry(arguments) {
                records.append(record(entry.name, entry.version, .swiftPM, .runtime, manifestPath))
            }
        }
        return records
    }

    /// 从 `.package(` 之后扫描配对括号，返回参数文本长度；返回 nil 表示括号不配对。
    private static func argumentsRange(after start: Int, in ns: NSString) -> Int? {
        var depth = 1
        var index = start
        var quote: unichar = 0
        let quoteDouble: unichar = 34
        let quoteSingle: unichar = 39
        while index < ns.length {
            let ch = ns.character(at: index)
            if quote != 0 {
                if ch == quote { quote = 0 }
                index += 1
                continue
            }
            if ch == quoteDouble || ch == quoteSingle { quote = ch; index += 1; continue }
            if ch == 40 { depth += 1 }
            else if ch == 41 {
                depth -= 1
                if depth == 0 { return index - start + 1 }
            }
            index += 1
        }
        return nil
    }

    private static func swiftPackageEntry(_ arguments: String) -> (name: String, version: String)? {
        let url = firstGroup("url\\s*:\\s*([\"'])([^\"'\\n]+)\\1", 2, in: arguments)
        let identifier = firstGroup("\\bid\\s*:\\s*([\"'])([^\"'\\n]+)\\1", 2, in: arguments)
        let declaredName = firstGroup("(?:^|[^A-Za-z])name\\s*:\\s*([\"'])([^\"'\\n]+)\\1", 2, in: arguments)
        // 本地路径依赖属于工程自身模块，跳过
        if firstGroup("path\\s*:\\s*([\"'])([^\"'\\n]+)\\1", 2, in: arguments) != nil, url == nil, identifier == nil {
            return nil
        }
        var version = firstGroup("\\bfrom\\s*:\\s*([\"'])([^\"'\\n]+)\\1", 2, in: arguments)
        version = version ?? firstGroup("\\bexact\\s*:\\s*([\"'])([^\"'\\n]+)\\1", 2, in: arguments)
        version = version ?? firstGroup("([\"'])([0-9][^\"'\\s]*)\\1\\s*\\.\\.\\.", 2, in: arguments)
        version = version ?? firstGroup("\\brevision\\s*:\\s*([\"'])([^\"'\\n]+)\\1", 2, in: arguments)
        version = version ?? firstGroup("\\bbranch\\s*:\\s*([\"'])([^\"'\\n]+)\\1", 2, in: arguments)

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
    private static func swiftPackageBasename(_ rawURL: String) -> String {
        var value = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hash = value.firstIndex(of: "#") { value = String(value[..<hash]) }
        if let query = value.firstIndex(of: "?") { value = String(value[..<query]) }
        while value.hasSuffix("/") { value = String(value.dropLast()) }
        var last = value
        if let slash = last.lastIndex(of: "/") { last = String(last[last.index(after: slash)...]) }
        if let colon = last.lastIndex(of: ":") { last = String(last[last.index(after: colon)...]) }
        if last.lowercased().hasSuffix(".git") { last = String(last.dropLast(4)) }
        return last
    }
}

// MARK: - Python / requirements.txt + pyproject.toml + Pipfile + setup.py

extension ManifestParsers {
    /// requirements.txt -> [DependencyRecord]。名字按 PEP 503 小写归一。
    static func requirementsTxtDependencies(_ text: String, manifestPath: String) -> [DependencyRecord] {
        var records: [DependencyRecord] = []
        for rawLine in lines(text) {
            let line = trim(stripHashComment(rawLine))
            if line.isEmpty { continue }
            if line.hasPrefix("-") { continue } // -r / -e / -c / --index-url …
            if let record = pythonRequirementRecord(line, scope: .runtime, manifestPath: manifestPath) {
                records.append(record)
            }
        }
        return records
    }

    /// pyproject.toml / Pipfile / setup.py -> [DependencyRecord]（尽力而为）。
    static func pyprojectDependencies(_ text: String, manifestPath: String) -> [DependencyRecord] {
        var records: [DependencyRecord] = []
        let entries = tomlEntries(in: text)

        for entry in entries {
            let section = entry.section.lowercased()
            let key = entry.key.lowercased()

            // setup.py / pyproject 里的数组式声明
            if section == "project" && key == "dependencies" {
                for spec in tomlStringList(entry.value) {
                    if let item = pythonRequirementRecord(spec, scope: .runtime, manifestPath: manifestPath) {
                        records.append(item)
                    }
                }
                continue
            }
            if section == "build-system" && key == "requires" {
                for spec in tomlStringList(entry.value) {
                    if let item = pythonRequirementRecord(spec, scope: .build, manifestPath: manifestPath) {
                        records.append(item)
                    }
                }
                continue
            }
            if section == "project" && key == "requires-python" {
                if let version = numericVersionPrefix(entry.value) {
                    records.append(record("python", version, .python, .platform, manifestPath))
                }
                continue
            }
            if section == "dependency-groups" {
                for spec in tomlStringList(entry.value) {
                    if let item = pythonRequirementRecord(spec, scope: .dev, manifestPath: manifestPath) {
                        records.append(item)
                    }
                }
                continue
            }

            guard let scope = pythonTableScope(section: section, key: key) else { continue }
            if section.hasSuffix("optional-dependencies") {
                // [project.optional-dependencies] 的每个键是一个可选组
                for spec in tomlStringList(entry.value) {
                    if let item = pythonRequirementRecord(spec, scope: .dev, manifestPath: manifestPath) {
                        records.append(item)
                    }
                }
                continue
            }
            // poetry / Pipfile 风格：name = "^1.2" 或 name = { version = "^1.2" }
            let name = key == "python" ? "python" : normalizePythonName(entry.key)
            guard !name.isEmpty, name != "source" else { continue }
            let rawVersion: String?
            if let inline = firstGroup("version\\s*=\\s*([\"'])([^\"'\\n]+)\\1", 2, in: entry.value) {
                rawVersion = inline
            } else if entry.value.trimmingCharacters(in: .whitespaces).hasPrefix("{") {
                rawVersion = nil // 只有 git/path 之类，没有版本
            } else {
                rawVersion = firstGroup("^\\s*([\"'])([^\"'\\n]+)\\1", 2, in: entry.value)
            }
            if name.isEmpty { continue }
            let version: String
            if let rawVersion, let extracted = numericVersionPrefix(rawVersion) {
                version = extracted
            } else if let rawVersion {
                version = rawVersion
            } else {
                version = undeclaredVersion
            }
            let entryScope: DependencyScope = name == "python" ? .platform : scope
            records.append(record(name, version, .python, entryScope, manifestPath))
        }

        // setup.py 的 install_requires = [ ... ]
        for groups in matches(of: "install_requires\\s*=\\s*\\[([^\\]]*)\\]", in: text) {
            guard let body = groups[1] else { continue }
            for spec in tomlStringList(body) {
                if let item = pythonRequirementRecord(spec, scope: .runtime, manifestPath: manifestPath) {
                    records.append(item)
                }
            }
        }
        for groups in matches(of: "extras_require\\s*=\\s*\\{(.*?)\\n\\s*\\}", in: text, multiline: true) {
            guard let body = groups[1] else { continue }
            for spec in tomlStringList(body) {
                if let item = pythonRequirementRecord(spec, scope: .dev, manifestPath: manifestPath) {
                    records.append(item)
                }
            }
        }
        return records
    }

    /// 一条 PEP 508/PEP 440 依赖字符串 -> DependencyRecord
    private static func pythonRequirementRecord(_ spec: String, scope: DependencyScope, manifestPath: String) -> DependencyRecord? {
        var value = trim(stripHashComment(spec))
        if value.isEmpty { return nil }
        if value.hasPrefix("-") { return nil }
        if let semicolon = value.firstIndex(of: ";") { value = trim(String(value[..<semicolon])) }
        // 直接引用：name @ https://…
        if let at = value.range(of: " @ ") {
            let name = normalizePythonName(String(value[..<at.lowerBound]))
            guard !name.isEmpty else { return nil }
            return record(name, undeclaredVersion, .python, scope, manifestPath)
        }
        if value.contains("://") {
            guard let egg = firstGroup("[#&]egg=([A-Za-z0-9_.\\-]+)", 1, in: value) else { return nil }
            return record(normalizePythonName(egg), undeclaredVersion, .python, scope, manifestPath)
        }
        guard let groups = matches(of: "^([A-Za-z0-9][A-Za-z0-9._\\-]*)\\s*(\\[[^\\]]*\\])?\\s*(.*)$", in: value).first,
              let rawName = groups[1] else { return nil }
        let name = normalizePythonName(rawName)
        guard !name.isEmpty else { return nil }
        let version = numericVersionPrefix(groups[3] ?? "") ?? undeclaredVersion
        return record(name, version, .python, scope, manifestPath)
    }

    private static func normalizePythonName(_ raw: String) -> String {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return lower }
        let collapsed = matchesReplaced(lower, pattern: "[-_.]+", with: "-")
        return collapsed
    }

    /// 从 "^1.2"、">=1.2,<2"、"~> 1.2"、"==1.2.3" 里取声明的下界；取不到返回 nil。
    private static func numericVersionPrefix(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return firstGroup("([0-9]+(?:\\.[0-9A-Za-z\\-]+)*)", 1, in: value)
    }

    /// 哪些 TOML 段里的 `key = value` 算依赖，以及对应 scope。
    private static func pythonTableScope(section: String, key: String) -> DependencyScope? {
        if section.hasSuffix("optional-dependencies") { return .dev }
        if section == "packages" { return .runtime }
        if section == "dev-packages" { return .dev }
        if section == "tool.poetry.dependencies" { return .runtime }
        if section == "tool.poetry.dev-dependencies" { return .dev }
        if section == "tool.poetry.group" || section.hasPrefix("tool.poetry.group.") {
            guard section.hasSuffix(".dependencies") else { return nil }
            let groupName = section.replacingOccurrences(of: "tool.poetry.group.", with: "")
                .replacingOccurrences(of: ".dependencies", with: "")
            return ["dev", "test", "tests", "lint", "docs", "ci", "tools", "typing"].contains(groupName) ? .dev : .runtime
        }
        if section.hasSuffix("dependencies") && (section.hasPrefix("tool.pipenv") || section == "dependencies") {
            return .runtime
        }
        _ = key
        return nil
    }

    /// 极简 TOML 扫描：返回 (段名, 键, 原样值)，多行数组/内联表已合并。
    private static func tomlEntries(in text: String) -> [(section: String, key: String, value: String)] {
        let rows = lines(text)
        var section = ""
        var result: [(String, String, String)] = []
        var index = 0
        while index < rows.count {
            let raw = rows[index]
            let line = trim(stripHashComment(raw))
            index += 1
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                let inner = line.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                section = trim(inner)
                continue
            }
            guard let groups = matches(of: "^([A-Za-z0-9_\"'\\.\\-]+)\\s*=(.*)$", in: line).first,
                  let key = groups[1], let rest = groups[2] else { continue }
            var value = trim(rest)
            var balance = bracketBalance(value)
            while balance > 0 && index < rows.count {
                let next = rows[index]
                index += 1
                value += "\n" + trim(stripHashComment(next))
                balance = bracketBalance(value)
            }
            let cleanKey = key.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            result.append((section, cleanKey, value))
        }
        return result
    }

    /// 引号外的 `[`/`{` 与 `]`/`}` 差值。
    private static func bracketBalance(_ text: String) -> Int {
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

    /// 取出文本里所有引号字符串（数组元素 / 内联字符串都能用）。
    private static func tomlStringList(_ text: String) -> [String] {
        matches(of: "([\"'])([^\"'\\n]+)\\1", in: text).compactMap { $0[2] }
    }

    private static func matchesReplaced(_ text: String, pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, options: [],
                                              range: NSRange(location: 0, length: (text as NSString).length),
                                              withTemplate: template)
    }
}

// MARK: - Go / go.mod

extension ManifestParsers {
    /// go.mod -> [DependencyRecord]。`// indirect` 记为 .unknown。
    /// 版本去掉 go 特有的 "v" 前缀与 "+incompatible"，以便与 DependencyVersion 的点分比较对齐。
    static func goModDependencies(_ text: String, manifestPath: String) -> [DependencyRecord] {
        var records: [DependencyRecord] = []
        var inRequireBlock = false
        var inIgnoredBlock = false
        for rawLine in lines(text) {
            let stripped = trim(stripSlashComment(rawLine))
            let isCommentOnly = rawLine.trimmingCharacters(in: .whitespaces).hasPrefix("//")
            if stripped.isEmpty { continue }

            if !inRequireBlock && !inIgnoredBlock {
                if stripped.hasPrefix("require (") || stripped == "require (" {
                    inRequireBlock = true
                    continue
                }
                if stripped.hasPrefix("replace (") || stripped.hasPrefix("exclude (")
                    || stripped.hasPrefix("retract") {
                    inIgnoredBlock = true
                    continue
                }
                if stripped.hasPrefix("module") || stripped.hasPrefix("go ")
                    || stripped.hasPrefix("toolchain") || stripped.hasPrefix("require //") {
                    continue
                }
            }
            if inIgnoredBlock {
                if stripped == ")" { inIgnoredBlock = false }
                continue
            }
            if inRequireBlock && stripped == ")" {
                inRequireBlock = false
                continue
            }

            var body = stripped
            if body.hasPrefix("require ") { body = trim(String(body.dropFirst("require ".count))) }
            let columns = body.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard columns.count >= 1 else { continue }
            let modulePath = columns[0]
            guard !modulePath.isEmpty, modulePath != "(", !modulePath.hasPrefix("//") else { continue }
            var version = columns.count >= 2 ? columns[1] : undeclaredVersion
            if version == "(" { version = undeclaredVersion }
            version = goVersion(version)
            let isIndirect = rawLine.contains("// indirect") || (isCommentOnly && rawLine.contains("indirect"))
            records.append(record(modulePath, version, .go, isIndirect ? .unknown : .runtime, manifestPath))
        }
        return records
    }

    private static func goVersion(_ raw: String) -> String {
        var value = trim(raw)
        if value.hasPrefix("v"), value.dropFirst().first.map({ $0.isNumber }) == true {
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
            let value = entry.value
            let version: String
            if let inline = firstGroup("version\\s*=\\s*([\"'])([^\"'\\n]+)\\1", 2, in: value) {
                version = inline
            } else {
                version = firstGroup("^\\s*([\"'])([^\"'\\n]+)\\1", 2, in: value) ?? undeclaredVersion
            }
            let normalized = trim(version)
            records.append(record(name, normalized.isEmpty || normalized == "*" ? undeclaredVersion : normalized,
                                  .cargo, scope, manifestPath))
        }
        return records
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
            let line = trim(stripSlashComment(rawLine))
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line == "end" || line.hasPrefix("end ") || line.hasPrefix("end}") {
                if depth > 0 { depth -= 1 }
                if !scopes.isEmpty, let last = scopes.popLast(), scopes.count > depth {
                    scopes.append(last)
                }
                while scopes.count > depth { scopes.removeLast() }
                continue
            }

            let inherited = scopes.last ?? .runtime
            if line.hasPrefix("pod ") || line.hasPrefix("pod(") || line.hasPrefix("pod'") || line.hasPrefix("pod\"") {
                let strings = matches(of: "([\"'])([^\"'\\n]+)\\1", in: line).compactMap { $0[2] }
                guard let name = strings.first, !name.isEmpty else { continue }
                var scope = inherited
                if line.contains("testables") { scope = .test }
                else if let explicit = podVersion(strings.dropFirst()) {
                    scope = inherited
                    _ = explicit
                }
                let version = podVersion(strings.dropFirst()) ?? undeclaredVersion
                records.append(record(name, version, .cocoapods, scope, manifestPath))
                continue
            }
            // 块开启：target 'X' do / def install! / if …
            let opensBlock = line.hasSuffix(" do") || line.contains(" do ") || line.hasSuffix(" {")
            if opensBlock {
                depth += 1
                let scope = blockScope(line) ?? inherited
                scopes.append(scope)
            }
        }
        return records
    }

    private static func blockScope(_ line: String) -> DependencyScope? {
        let strings = matches(of: "([\"'])([^\"'\\n]+)\\1", in: line).compactMap { $0[2] }
        let lowered = (strings + [line]).map { $0.lowercased() }
        guard lowered.contains(where: { $0.contains("test") || $0.contains("spec") }) else { return nil }
        return .test
    }

    private static func podVersion(_ candidates: ArraySlice<String>) -> String? {
        for candidate in candidates {
            let value = trim(candidate)
            if value.hasPrefix(":") { continue }
            if value.contains("=>") { continue }
            if value.first.map({ $0.isNumber || $0 == "~" || $0 == ">" || $0 == "<" || $0 == "=" }) == true {
                return value
            }
        }
        return nil
    }
}

// MARK: - Ruby / Gemfile

extension ManifestParsers {
    /// Gemfile -> [DependencyRecord]。`group :test/:development/:production` 影响 scope。
    static func gemfileDependencies(_ text: String, manifestPath: String) -> [DependencyRecord] {
        var records: [DependencyRecord] = []
        var depth = 0
        var scopes: [DependencyScope] = []
        var inherited: DependencyScope = .runtime
        for rawLine in lines(text) {
            let line = trim(stripHashComment(rawLine))
            if line.isEmpty { continue }
            if line == "end" || line.hasPrefix("end ") {
                if depth > 0 { depth -= 1 }
                while scopes.count > depth { scopes.removeLast() }
                inherited = scopes.last ?? .runtime
                continue
            }
            if let scope = gemGroupScope(line) {
                inherited = scope
                depth += 1
                scopes.append(scope)
                continue
            }
            if gemOpensBlock(line) {
                depth += 1
                scopes.append(inherited)
                continue
            }
            if line.hasPrefix("gem ") || line.hasPrefix("gem(") || line.hasPrefix("gem'") || line.hasPrefix("gem\"") {
                let strings = matches(of: "([\"'])([^\"'\\n]+)\\1", in: line).compactMap { $0[2] }
                guard let name = strings.first, !name.isEmpty else { continue }
                let scope = gemInlineScope(line) ?? inherited
                let version = gemVersion(strings.dropFirst()) ?? undeclaredVersion
                records.append(record(name, version, .ruby, scope, manifestPath))
            }
        }
        return records
    }

    private static func gemGroupScope(_ line: String) -> DependencyScope? {
        guard line.hasPrefix("group ") else { return nil }
        let symbols = matches(of: ":([A-Za-z0-9_]+)", in: line).compactMap { $0[1] }
        let names = symbols.map { $0.lowercased() }
        if names.contains("test") || names.contains("spec") { return .test }
        if names.contains("development") || names.contains("dev") { return .dev }
        if names.contains("production") || names.contains("prod") { return .runtime }
        return .runtime
    }

    private static func gemInlineScope(_ line: String) -> DependencyScope? {
        guard let body = firstGroup("groups?\\s*:\\s*\\[([^\\]]*)\\]", 1, in: line) else { return nil }
        let symbols = matches(of: ":([A-Za-z0-9_]+)", in: body).compactMap { $0[1] }.map { $0.lowercased() }
        if symbols.contains("test") || symbols.contains("spec") { return .test }
        if symbols.contains("development") || symbols.contains("dev") { return .dev }
        if symbols.contains("production") || symbols.contains("prod") { return .runtime }
        return nil
    }

    private static func gemOpensBlock(_ line: String) -> Bool {
        line.hasSuffix(" do") || line.contains(" do ") || line.hasSuffix(" {") || line.hasPrefix("if ")
    }

    private static func gemVersion(_ candidates: ArraySlice<String>) -> String? {
        for candidate in candidates {
            let value = trim(candidate)
            if value.contains("=>") { continue }
            if value.first.map({ $0.isNumber || $0 == "~" || $0 == ">" || $0 == "<" || $0 == "=" }) == true {
                return value
            }
        }
        return nil
    }
}

// MARK: - NuGet / packages.config

extension ManifestParsers {
    /// packages.config -> [DependencyRecord]。developmentDependency="true" 记为 .dev。
    static func nugetPackagesConfigDependencies(_ text: String, manifestPath: String) -> [DependencyRecord] {
        var records: [DependencyRecord] = []
        for groups in matches(of: "<package\\b([^>]*?)/?>", in: text) {
            guard let attributes = groups[1] else { continue }
            let name = nugetAttribute("id", in: attributes)
            let version = nugetAttribute("version", in: attributes)
            guard let name, !name.isEmpty else { continue }
            let development = (nugetAttribute("developmentDependency", in: attributes) ?? "").lowercased() == "true"
            records.append(record(name, version ?? undeclaredVersion, .nuget, development ? .dev : .runtime, manifestPath))
        }
        return records
    }

    private static func nugetAttribute(_ key: String, in attributes: String) -> String? {
        firstGroup("\(key)\\s*=\\s*([\"'])([^\"'\\n]*)\\1", 2, in: attributes)
    }
}

// MARK: - 各生态公开入口（契约要求，逐个转发到上面的实现）

extension ManifestParsers {
    // pomXMLDependencies / gradleDependencies / packageJSONDependencies / swiftPackageDependencies /
    // requirementsTxtDependencies / pyprojectDependencies / goModDependencies / cargoTomlDependencies /
    // podfileDependencies / gemfileDependencies / nugetPackagesConfigDependencies
    // 已分别在上面的对应 extension 中定义，签名与契约一致。
    static var supportedEcosystems: [DependencyEcosystem] {
        DependencyEcosystem.allCases.filter { $0 != .unknown }
    }
}
