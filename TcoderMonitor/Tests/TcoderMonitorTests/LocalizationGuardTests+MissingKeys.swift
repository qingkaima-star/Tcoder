import Foundation
import XCTest

/// OWNER: 总工（双语线）—— 从 `LocalizationGuardTests` 拆出来的两条静态判据。
///
/// 两条判的是**同一条机制洞的两端 —— 运行时查不中的键等于没翻**：
///
/// 1. **查了但目录里没键**：`localizedCopy("…")` / `localizedCount("…", …)` /
///    `localizedFormat("…", …)` 的字面量实参，必须在 `en.lproj/Localizable.strings` 里有同名键。
/// 2. **先拼再上屏**（守卫 1d，P53 立的）：中文片段被 `+` 拼进更大的串之后，
///    渲染层查的是**拼完之后**那一串，目录里永远不会有这种键。
///
/// 为什么这两条必须存在：缺键与拼串都**不报错、不崩、测试全绿**，
/// 唯一的症状是英文界面上铺着中文原文（或同一行半英半中）—— 也就是只有切到英文的人才看得见。
/// 而"看得见"这件事在活界面侧要靠 18 趟 AX 扫描（`ax_body_audit.py`）才能数出来，
/// 静态一条正则就能盯住的东西不该留给动态。
///
/// P51 第一次跑就抓到 9 条：`%lld 次`（四处调用点共用一把 `localizedCount`，
/// 目录里却始终没这条键）、`%lld 行`、相对时间六档（`%lld 分钟前` 那一族只登记了不带「前」的形态）、
/// `另有 %lld 处`。
extension LocalizationGuardTests {

    /// 含插值的查表实参（`"尚未分析\(subject.rawValue)"` 那一族）**不在本条范围里** ——
    /// 它们要改成 `localizedFormat` + 位置参数，属双语迁移线的存量（台账另记句数），
    /// 混进来的话这条判据会把"改法不同"误报成"写错了"。
    static func lookedUpLiterals(in text: String) -> (plain: [String], interpolated: [String]) {
        let pattern = #"localized(?:Copy|Count|Format)\(\s*"((?:[^"\\]|\\.)+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            XCTFail("正则构造失败 ⇒ 这条判据根本没在跑")
            return ([], [])
        }
        var plain: [String] = []
        var interpolated: [String] = []
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard let span = Range(match.range(at: 1), in: text) else { continue }
            let key = String(text[span])
            if key.contains("\\(") {
                interpolated.append(key)
            } else {
                plain.append(key)
            }
        }
        return (plain, interpolated)
    }

    static func missingKeys(in files: [(path: String, content: String)], keys: Set<String>) -> [String] {
        files.flatMap { file in
            // **只扫代码行**（`SurfaceScanKit.codeLines` 会滤掉整行 `//` / `///`）。
            // P57 是被自己的文档注释教出来的：我在 `DimensionDisplay.name` 上方写了一句
            // 「形如 `localizedFormat("「%1$@」完成但该分量未产出。", …)` 那一族」当反面举例，
            // 判据把注释里引的那句当真调用点，当场要我为一条**文档**去登记键。
            // 注释里必须能写被禁的写法本身 —— 否则没人能在判据旁边解释它为什么存在。
            let code = SurfaceScanKit.codeLines(file.content).joined(separator: "\n")
            return lookedUpLiterals(in: code).plain.filter { !keys.contains($0) }
                .map { "\(file.path) → \($0)" }
        }
    }

    func test_everyLookedUpLiteralHasACatalogKey() throws {
        let files = try SurfaceScanKit.sourceFiles(under: "")
        XCTAssertFalse(files.isEmpty, "一个源码文件都没扫到 ⇒ 这条判据在空转")
        // **两本目录都要读**：`.strings` 是单数键，复数形态（`%lld 次` / `%lld 行` /
        // 相对时间那一族）住在 `.stringsdict`。只读前者会把已翻的复数键算成债，
        // 然后逼人往 `.strings` 里补一条同名单数键 —— 那是"乱翻译"，不是收口。
        // （P51 就是这么差点犯错的：判据自己写的注释里就有这条教训。）
        let keys = Set(try Self.catalog().map(\.key))
            .union(Self.registeredStringsDictKeys())
        XCTAssertFalse(keys.isEmpty, "两本目录一条键都没读到 ⇒ 判据会全体误报，先修读数")

        let missing = Self.missingKeys(in: files, keys: keys)
        XCTAssertTrue(missing.isEmpty,
                      "这些句子查了表，但目录里根本没键 ⇒ 英文态直接把中文原文铺上屏，"
                    + "而且一句都不会报错：\n  " + missing.sorted().joined(separator: "\n  "))

        // 与判据**同一把尺子**：打印的插值处数也走代码行，不另抄一份口径
        // （P46 那次是打印 44 格、判据查 72 格；同一类错的第二处就要写成同源）
        let interpolated = files.reduce(0) { sum, file in
            sum + Self.lookedUpLiterals(in: SurfaceScanKit.codeLines(file.content)
                .joined(separator: "\n")).interpolated.count
        }
        print("【查表必有键】扫 \(files.count) 个文件 → 缺键 0 条；"
            + "含插值的查表实参 \(interpolated) 处（另一档：要改成 localizedFormat，见双语台账）")
    }

    /// 双向元测试：缺键必须抓到、有键不许误报、含插值的走另一档不误伤。
    func test_missingKeyRulerCatchesGapsAndSparesInterpolated() {
        let keys: Set<String> = ["已有键"]
        let dirty = [(path: "Views/Fake.swift",
                      content: "Text(localizedCopy(\"缺的键\")) localizedCount(\"%lld 次\", n)")]
        XCTAssertEqual(Set(Self.missingKeys(in: dirty, keys: keys)),
                       ["Views/Fake.swift → 缺的键", "Views/Fake.swift → %lld 次"],
                       "缺键没被抓全 ⇒ 这条判据数不出东西")
        let clean = [(path: "Views/Fake.swift", content: "localizedCopy(\"已有键\")")]
        XCTAssertTrue(Self.missingKeys(in: clean, keys: keys).isEmpty, "有键还报 ⇒ 下次没人信它")
        let interpolated = [(path: "Views/Fake.swift",
                             content: "localizedCopy(\"尚未分析\\(subject.rawValue)\")")]
        XCTAssertTrue(Self.missingKeys(in: interpolated, keys: keys).isEmpty,
                      "含插值的查表实参要改的是写法（localizedFormat + 位置参数），不该被这条误伤")
        XCTAssertEqual(Self.lookedUpLiterals(in: interpolated[0].content).interpolated.count, 1,
                       "插值那一档必须被**数出来**，不能悄悄不算")
        // 文档注释里**必须**能写被禁的写法本身（P57：我自己的反面举例被判成调用点）。
        let documented = [(path: "Views/Fake.swift",
                           content: "/// 形如 localizedCopy(\"缺的键\") 的写法是旧账\n"
                                 + "Text(localizedCopy(\"缺的键\"))\n")]
        XCTAssertEqual(Self.missingKeys(in: documented, keys: ["已有键"]),
                       ["Views/Fake.swift → 缺的键"],
                       "注释里的那一条不该算，代码里那一条必须算——两个方向都要成立")
    }

    // MARK: - 守卫 1d（P53）：先拼再上屏的中文串永远查不中

    /// 「汉字字面量」与「别的东西」之间有一个 `+` —— 两个方向都算：字面量在 `+` 左边，
    /// 或在 `+` 右边（跨行续写时 `+` 起头，正好落在第二行）。
    ///
    /// 为什么上面那条"查了表必须有键"**看不见这一族**：这里的字面量根本没被 `localized*` 包住，
    /// 它是**先拼成串、拼完那一串才被渲染层查表**。而拼出来的整串里嵌着测得值 ——
    /// 英文目录里不可能有「含 279 次合并 · 非合并 606 次」这种键，于是翻了也白翻。
    /// 更糟的一种是 `windowSuffix` 被当 `%3$@` 插进**已经翻好**的整句模板：
    /// 同一行前半英文、后半中文，比纯中文更难读，而静态侧三条键守卫全是绿的。
    static func composedChineseLines(in content: String) -> [(line: Int, text: String)] {
        let before = try? NSRegularExpression(
            pattern: #""(?:[^"\\\n]|\\.)*\p{Han}(?:[^"\\\n]|\\.)*"\s*\+"#)
        let after = try? NSRegularExpression(pattern: #"\+\s*"(?:[^"\\\n]|\\.)*\p{Han}"#)
        guard let before, let after else {
            XCTFail("正则构造失败 ⇒ 这条判据根本没在跑")
            return []
        }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var hits: [(line: Int, text: String)] = []
        for (index, rawLine) in lines.enumerated() {
            guard SurfaceScanKit.isCode(rawLine) else { continue }
            let line = Self.strippingTrailingComment(rawLine)
            let range = NSRange(line.startIndex..., in: line)
            if before.firstMatch(in: line, range: range) != nil
                || after.firstMatch(in: line, range: range) != nil {
                hits.append((index + 1, line.trimmingCharacters(in: .whitespaces)))
            }
        }
        return hits
    }

    /// 砍掉**行尾**注释。`SurfaceScanKit.isCode` 只豁免整行注释，而这一族最响的一条误报
    /// 正是"代码里的正则字面量含 `+`、行尾注释里含汉字与引号"（`Services/Logs/LogLineParser.swift`
    /// 的崩溃帧匹配表）—— 尺子看不见这种形状，它报出来的数就没人敢信。
    ///
    /// 判"引号外的 `//`"用的是**同行引号奇偶**：不数跨行的原始字符串，所以一条以 `#"` 起、
    /// `"#` 止的多行原始串内部，注释会被误当成代码。这个已知粗糙面由元测试钉住"不误伤"的方向：
    /// 宁可多报由人逐条判，不可漏报。
    static func strippingTrailingComment(_ line: String) -> String {
        var quoting = false
        var escaped = false
        let characters = Array(line)
        for index in characters.indices {
            let character = characters[index]
            if character == "\"", !escaped { quoting.toggle() }
            if character == "\\", !escaped {
                escaped = true
                continue
            }
            if !quoting, character == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                return String(characters[..<index])
            }
            escaped = false
        }
        return line
    }

    /// **已收口名单**：名单里的文件必须一处拼接都没有；名单只许往长里加。
    ///
    /// 为什么不是"全仓 0 处"：P53 第一次量到 **221 处**（`Services` 184 / `Views` 37），
    /// 那是横跨评分、日志、性能探针三条文案线的存量，一批收不完。
    /// 把判据立成"全仓必须 0"只有两条出路：一次改 221 处（本批不做），
    /// 或者开一个"数量只许降"的计数闸 —— 那是一条长度代理，
    /// 改小一处、别处加一处它照样绿（见《守恒线要逐条留名的豁免口》）。
    /// 名单制两条都避开了：**已收口的文件里新增一处拼接立刻变红**，
    /// 而名单外的存量由打印明写"还有 N 处没认证"，不会伪装成通过。
    static let compositionFreeFiles: [String] = [
        "Views/CodeGit/GitHistoryScope.swift",
        "Views/Git/GitInsightsSections.swift",
    ]

    func test_compositionFreeFilesStayFreeOfJoinedChineseCopy() throws {
        let files = try SurfaceScanKit.sourceFiles(under: "")
        XCTAssertFalse(files.isEmpty, "一个源码文件都没扫到 ⇒ 这条判据在空转")
        // 名单里的文件必须**还在扫描面上**：被改名或整片挪走，判据就悄悄不再覆盖它。
        let scanned = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0.content) })
        let absent = Self.compositionFreeFiles.filter { scanned[$0] == nil }
        XCTAssertTrue(absent.isEmpty,
                      "已收口名单点名的文件不在扫描面上（改名？挪走？），判据已覆盖不到它：\(absent)")

        let offenders = Self.compositionFreeFiles.flatMap { path in
            Self.composedChineseLines(in: scanned[path] ?? "").map { "\(path):\($0.line) \($0.text)" }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "这些中文片段被 `+` 拼出去了 ⇒ 拼完的整串永远对不上目录里的任何键，"
                    + "英文态要么整句中文、要么半英半中：\n  "
                    + offenders.sorted().joined(separator: "\n  "))

        // 名单外的存量：与判据**同一把尺子**数出来的，不是另抄一份数字。
        let rest = files.filter { !Self.compositionFreeFiles.contains($0.path) }
            .reduce(0) { $0 + Self.composedChineseLines(in: $1.content).count }
        print("【拼了查不中】已收口 \(Self.compositionFreeFiles.count) 个文件 → 名单内 0 处；"
            + "名单外仍有 \(rest) 处（P53 首测 221 处：Services 184 / Views 37，见双语台账 §9）")
    }

    // MARK: - 守卫 1g（P58）：中文字面量**自己肚子里**做插值，两条老判据都看不见

    /// `"平均圈复杂度 \(decimal(averageCC))"` 这一族：既没被 `localized*` 包住（守卫 1 放过），
    /// 也没有 `+`（守卫 1d 放过）—— 片段与测得值在**同一个字面量里**拼完了。
    /// 拼出来的那一串照样要上屏，照样查不中，英文态整行中文。
    ///
    /// 为什么单独立一条而不是并进 1d：1d 判的是"跨片段拼接"，改成数组字面量
    /// （`joined(["甲\(x)", "乙\(y)"])`）就能绕过它，而 P58 面对的健康评分 detail **正是**这个形状。
    static func interpolatedChineseLiterals(in content: String) -> [(line: Int, text: String)] {
        let literal = try? NSRegularExpression(pattern: #""(?:[^"\\\n]|\\.)*""#)
        // 「算不算汉字」用与守卫 1d **同一个** `\p{Han}`，不在这里另抄一份码表
        // （本仓已经有三把手写的汉字区间判断，每多一把就多一处会单独腐烂的地方）。
        let han = try? NSRegularExpression(pattern: #"[\p{Han}]"#)
        guard let literal, let han else {
            XCTFail("正则构造失败 ⇒ 这条判据根本没在跑")
            return []
        }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var hits: [(line: Int, text: String)] = []
        for (index, rawLine) in lines.enumerated() {
            guard SurfaceScanKit.isCode(rawLine) else { continue }
            let line = Self.strippingTrailingComment(rawLine)
            let range = NSRange(line.startIndex..., in: line)
            for match in literal.matches(in: line, range: range) {
                guard let span = Range(match.range, in: line) else { continue }
                let text = String(line[span])
                let span2 = NSRange(text.startIndex..., in: text)
                if text.contains("\\("), han.firstMatch(in: text, range: span2) != nil {
                    hits.append((index + 1, text))
                }
            }
        }
        return hits
    }

    /// **已收口名单**：形状与 1d 同源（名单里的文件一条都不许有，名单只许往长里加）。
    ///
    /// P58 首测全仓 `Services/Health` 尚有 52 处（`HealthRuntimeDimensions` 19 /
    /// `HealthBreakdown` 16 / `HealthTeamDimensions` 11 / `HealthCodeDimensions` 3 /
    /// `WeightedHealthScorer` 2 / `ScoreCurves` 1），那一族的分母记在双语台账 §9，
    /// 不在本条里"只减不增"——那是一条长度代理（见《守恒线要逐条留名的豁免口》）。
    static let keyizedCopyFiles: [String] = [
        "Services/Health/ScoreCurvesCode.swift",
        "Services/Health/ScoreCurvesTeamRuntime.swift",
        "Services/Health/GitCadenceEvidence.swift",
        // P64：这条判据原来只盯 Services，而 `Views/**` 里也有"返回字符串给 `Text(变量)`"的生产者
        // ——`markerNote` 那句 FIXME 提示就因此长期挂在英文态残留的 A 类里（两个半句各自登记过，
        // 运行时拼起来永远查不中）。名单只往长里加，加一个文件就要把它清干净。
        "Views/Code/CodeMetricsSections.swift",
        // P67：依赖页那五句只有换成别的仓库才上屏（本仓依赖清单是空的），
        // 拿 Homebrew 复验才抓到「共 8 项，已全部展示。」既没登记、又把测得值插在自己肚子里。
        "Views/Dependencies/DependenciesView.swift",
        // P67：这两句是**嵌在已译长句里**的片段，英文态实拍成 "…, 快照截至 2026-09-19（4 days ago）; …"。
        // 只有多生态的仓库才会走到这条分支（本仓依赖清单为空），所以十八趟 dogfooding 读数从没抓到过。
        "Services/Dependencies/DependencySnapshot.swift",
        "Services/Dependencies/ManifestDependencyAnalyzerVersionEvidence.swift",
    ]

    func test_keyizedCopyFilesHoldNoInterpolatedChineseLiterals() throws {
        let files = try SurfaceScanKit.sourceFiles(under: "")
        let scanned = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0.content) })
        let absent = Self.keyizedCopyFiles.filter { scanned[$0] == nil }
        XCTAssertTrue(absent.isEmpty,
                      "已收口名单点名的文件不在扫描面上（改名？挪走？），判据已覆盖不到它：\(absent)")
        let offenders = Self.keyizedCopyFiles.flatMap { path in
            Self.interpolatedChineseLiterals(in: scanned[path] ?? "")
                .map { "\(path):\($0.line) \($0.text)" }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "这些中文字面量把测得值**插在自己肚子里** ⇒ 整串永远查不中，"
                    + "改成 localizedFormat + 位置参数：\n  " + offenders.sorted().joined(separator: "\n  "))
        let rest = files.filter { !Self.keyizedCopyFiles.contains($0.path) }
            .reduce(0) { $0 + Self.interpolatedChineseLiterals(in: $1.content).count }
        print("【插值中文段】已收口 \(Self.keyizedCopyFiles.count) 个文件 → 名单内 0 处；"
            + "名单外仍有 \(rest) 处（P58 首测全仓，见双语台账 §9）")
    }

    /// 元测试：P58 拆掉的三种形状必须每种都被抓住，整句键写法一条不许误报。
    func test_meta_interpolatedChineseRulerCatchesWhatP58Removed() {
        let removed = [
            #"let detail = joined(["平均圈复杂度 \(decimal(averageCC))", "最大 \(maxCC)"]),"#,
            #"return "距今 \(decimal(days)) 天无提交""#,
            #"detail: raw.detail + "（榜内只列 \(code.hugeFiles.count) 个，实际 \(hugeCount) 个)","#,
        ]
        let found = removed.map { Self.interpolatedChineseLiterals(in: $0).count }
        XCTAssertEqual(found, [2, 1, 1], "漏一种形状，那一族就继续假绿：\(found)")
        let fixed = [
            #"let detail = joined([localizedFormat("平均圈复杂度 %1$@", decimal(averageCC))])"#,
            #"return localizedFormat("距今 %1$@ 天无提交", decimal(days))"#,
            #"print("count = \(count)")"#,
        ]
        for line in fixed {
            XCTAssertTrue(Self.interpolatedChineseLiterals(in: line).isEmpty, "整句键写法被误报：\(line)")
        }
        XCTAssertTrue(Self.interpolatedChineseLiterals(
            in: #"// 旧写法 "重复率 \(percent(value))" 必须能写在注释里"#).isEmpty,
            "注释里**必须**能写被禁的写法本身")
    }

    /// 双向元测试：P53 拆掉的四种写法**必须每一种都被抓住**（已知答案的正对照），
    /// 改成熟形态之后一条不许误报。没有这半边，上面那条绿只说明"正则没匹配上任何东西"。
    func test_compositionRulerCatchesTheFourShapesP53Removed() {
        // 跨行续写那一族：起头行**看不见**（`+` 在下一行），第二行才被抓 ——
        // 报的行号是续写行。这一条写死在这里，免得下次有人以为它数的是起头行。
        // （夹具走普通字面量 + `\n`：raw 串 `#"…"#` 是**单行**串，跨行会编译不过。）
        let across = "return \"含 \\(x) 次合并 · 非合并 \"\n    + \"\\(y) 次\""
        XCTAssertEqual(Self.composedChineseLines(in: across).map(\.line), [2],
                       "跨行拼接只在续写行被抓 ⇒ 这一族的锚点形状，漏了它整族就假绿")
        let shapes = [
            #"subtitle: "数据源只有边际分布" + scope.windowSuffix,"#,
            #"return scope.headline + "。趋势、时段分布不代表全部历史。""#,
            #"return "近 \(a) 次提交窗口内 · " + "\(b) 人""#,
        ]
        let found = shapes.map { Self.composedChineseLines(in: $0).count }
        XCTAssertEqual(found, [1, 1, 1], "四种形状漏了哪一种，那一族就会继续假绿：\(found)")

        let fixed = [
            #"return localizedFormat("含 %1$@ 次合并 · 非合并 %2$@ 次", a, b)"#,
            #"subtitle: localizedFormat("数据源只有边际分布%1$@", scope.windowSuffix),"#,
            #"return localizedFormat("%1$@。趋势、时段分布不代表全部历史。", scope.headline)"#,
            #"Text(localizedCopy("数据源只有边际分布"))"#,
        ]
        for line in fixed {
            XCTAssertTrue(Self.composedChineseLines(in: line).isEmpty, "整句键写法被误报：\(line)")
        }
        XCTAssertTrue(Self.composedChineseLines(
            in: #"// 旧写法是 "中文" + n，整行注释必须豁免，否则守卫判自己违规"#).isEmpty,
            "注释里**必须**能写被禁的写法本身")
        // 行尾注释那一族误报的正对照：代码里的正则含 `+`，注释里含汉字与引号。
        XCTAssertTrue(Self.composedChineseLines(
            in: ##"RX(#"^\s*#\d+[ \t]+0x[0-9a-f]+"#),  // crash 帧 "#0""##).isEmpty,
            "行尾注释没砍干净 ⇒ 尺子会把代码里的 `+` 与注释里的汉字连成一条误报")
    }
}
