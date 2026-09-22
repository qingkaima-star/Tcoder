// 依赖清单解析 · 各生态共用的「框架标记」判定表与锁文件候选表（WS-B）
//
// 从 ManifestParsers.swift 拆出，只为守住本轮的文件规模线（单文件 ≤ 400 行）。
// 规则表的**内容、顺序、取值、判定分支**一字未改：`markerRules` 是按声明顺序命中的，
// 拆出来时保持原顺序，所以 frameworkMarkers 的输出与拆分前逐字一致。
// `tokens(of:)` 与 `startsNewCamelToken` 是同一次拆分带出来的：前者把驼峰边界判定
// 抽成独立谓词以降圈复杂度，抽前后逐字等价（&& 的操作无副作用，顺序不影响结果）。
import Foundation

// MARK: - 框架标记 / 锁文件判定表

extension ManifestParsers {
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

    // MARK: - 分词

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
            if startsNewCamelToken(chars, index) && !current.isEmpty {
                result.append(current)
                current = ""
            }
            current.append(Character(ch.lowercased()))
        }
        if !current.isEmpty { result.append(current) }
        return result.filter { !$0.isEmpty }
    }

    /// `chars[index]` 处是否落在一个**新**驼峰词的开头。两条原判定一字未动：
    /// 前一个字符是小写/数字（`swiftUI` 的 U 之前），或前一个也是大写而下一个是小写
    /// （`SwiftUI` 的 i 之前，即缩写串与词干的接缝）。首字符永不切（index > 0）。
    static func startsNewCamelToken(_ chars: [Character], _ index: Int) -> Bool {
        guard chars[index].isUppercase, index > 0 else { return false }
        let prev = chars[index - 1]
        let prevIsLowerOrDigit = prev.isNumber || (prev.isLetter && prev.isLowercase)
        let nextIsLower = index + 1 < chars.count
            && chars[index + 1].isLetter && chars[index + 1].isLowercase
        return prevIsLowerOrDigit || (prev.isUppercase && nextIsLower)
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

    /// **已解析产物**候选（RD-13b）：这些不是锁文件，是工具已经替我们把版本算出来的东西
    /// —— Maven 根本没有 lock 文件这一族，逼项目"补一个"正是整改意见禁止的那种修法。
    /// 因此单列一表：`lockfileName`（界面与"这是不是一份锁文件"的口径）仍只读上面那张表。
    static let resolvedArtifactCandidates: [DependencyEcosystem: [String]] = [
        .maven: ["effective-pom.xml", ".flattened-pom.xml", "flattened-pom.xml",
                 "dependency-reduced-pom.xml", "dependency-tree.txt", "dependencies.txt",
                 "mvn-dependency-tree.txt", "bom.json", "sbom.json", "spdx.json", "sbom.cdx.json"],
        .gradle: ["dependencies.txt", "gradle-dependencies.txt", "bom.json", "sbom.json", "spdx.json"],
    ]

    /// 这个文件名是不是"已解析产物"候选。
    static func isResolvedArtifactCandidate(_ name: String, ecosystem: DependencyEcosystem) -> Bool {
        (resolvedArtifactCandidates[ecosystem] ?? []).contains(name)
    }
}
