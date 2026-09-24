import Foundation

// OWNER: WS-R40 双分母并排（台账卷四 §73 · RD-67 需求方 2026-09-24 18:16 裁定
// 「维持现状 + 两个数并排给」）—— 「生产码 N 行 / 全量 M 行」这一句的**唯一装配口**。
//
// 为什么单独一个文件（AGENTS §3 第 7.1 条要求新增 Sources 文件写清「谁加的、凭什么被引用」）：
//   · 谁加的：本流 WS-R40，2026-09-24 派单点名「新增装配口优先放 Services/Code」；
//   · 凭什么被引用：两个上屏出口点名读它 ——
//     `CodeMetricsView`（代码规模页那一格读数旁，常驻）与 `HealthView`（综合评分卡 ⓘ）。
//     形状与同目录的 `CodeScanSurfaceReadout.accountingLines(_:)`、
//     `SourceScanScopeReadout.swift` 的 `MixedLanguageRegionCaliber.note(_:)` 同族同形：
//     句子只在这里生产，消费方一律只读，谁再拼一遍就是第二把尺子
//     （`ProductionCodeScaleGuardTests` 按名字扫 `Sources/**` 拦那一件事）。
//   · ⚠️ 本单**不接**无头 CLI 那一路（工单点名 `Services/CLI/**` 这轮归 R39，且 CLI 已有
//     `CLIScoreText.fileRoleStatement` 那一行在读同一枚字段）。等 CLI 要接这句的时候仍读这里。
//   · ⚠️ 新增 `Sources/**` 文件 ⇒ `SourceFileReachabilityTests.censusBaseline` 会当场红，
//     那把常量只由总工拧，本流没有动它。
//
// 这一档只回答一个问题：**这一份 codeLines 里有多少是生产码**。
// · 分母维持原样是需求方的裁定本身（文档 / 配置 / 备份 / 测试与生产码同分母）：
//   本文件不接评分、不改权重、不动阈值、不数行 —— 数值全部来自
//   `CodeMetrics.fileRoles`（`FileSystemCodeAnalyzer` 里 `SourceRoleTally` 算一次同喂
//   字段与台账）与 `CodeMetrics.codeLines`，这里一个字都不重算、不相减、不折算；
// · 判档判据仍只有 `SourceFileRoleRules.swift` 的 `SourceFileRoleRule.decide` 一处，
//   视图侧不许现算分档；
// · ⚠️ 三条容易走错的路，本文件一条都不走：
//   ① 把 `fileRoles` 里量到的 **0** 当缺数（那会凭空多出一种假「没量到」）；
//   ② 把生产码那一档当**分母**去改评分（那是需求方明确没批的语义变更）；
//   ③ 把「没做分档」渲染成「生产码 0 行」（那是把没跑过说成没有）。

/// 「生产码 N 行 / 全量 M 行」的唯一生产者。**只拼话，不判档、不数行、不改分母。**
enum ProductionCodeScaleReadout {

    /// 上屏那一句：主句 +（这一档真的量为零时）那句说明 +（有弱判定时）打折提示。
    ///
    /// 缺席态在这里分开走（本单的硬要求，逐条由 `ProductionScaleReadoutTests` 钉住）：
    /// · **本次没做角色分档**（`fileRoles == nil`，含整条代码路没跑）⇒ 返回 `nil`，
    ///   **整句不出声**：不许显示 `0`、不许显示「/ 全量」、也不许补一句「没做分档」去占位；
    /// · **做了分档而没有生产码那一档** ⇒ 主句打 `--`（见 `pairedLines(_:)`）；
    /// · **生产码那一档量到 0** ⇒ 主句照原样打数字 0，并补一句「这次量到的是零」。
    ///
    /// 组装形状沿用 `Services/Logs/CrashEvidenceReadout.swift` 的 `footnote(_:)`：
    /// **若干整句键**用语言无关的 ` · ` 串起来，不是拿中文字面量去 `+` 拼半句
    /// （后一种写法拼完的整串永远对不上目录里的键，是【拼了查不中】那一族）。
    static func reading(_ code: CodeMetrics?) -> String? {
        guard let code, let head = pairedLines(code) else { return nil }
        var parts = [head]
        if let zero = measuredZeroNotice(code) { parts.append(zero) }
        if let weak = weakEvidenceHint(code) { parts.append(weak) }
        return parts.joined(separator: " · ")
    }

    /// 主句（不含附加句）。三条互不冒充的分工处就在这里：
    ///
    /// 1. `code.fileRoles == nil` ⇒ `nil`：本次没有角色分档这件事，一个数都不成立；
    /// 2. 有分档而**生产码那一档不在八档里** ⇒ 打 `--`、**不折成 0**：
    ///    「没有生产码」与「这一档没数出来」是两件事，缺档由契约自己表达
    ///    （`Models/CodeMetrics.swift` 的 `CodeFileRoles` 注释写着「缺档 = 那一档没量到」）；
    /// 3. 有分档、有生产码那一档 ⇒ 直传 `production.codeLines` 与 `code.codeLines`，
    ///    量到的 0 照 0 打（再走 `measuredZeroNotice` 补那句说明）。
    ///
    /// 「全量」取的是 `CodeMetrics.codeLines` —— **就是评分与规模一直在用的那个分母**；
    /// 这一句只把它和生产码那一档并排放，不参与任何计算。
    static func pairedLines(_ code: CodeMetrics) -> String? {
        guard let roles = code.fileRoles else { return nil }
        guard let production = roles.share(for: .production) else {
            return localizedCount("生产码 -- / 全量 %lld 行 · 这一档没数出来，不是这一档没有生产码",
                                  code.codeLines)
        }
        // 两个复数槽各选各的支（英文 `1 line` / `5 lines`），形状照既有键
        // `共 %lld 天 · 单日峰值 %lld 条`（同一枚出口 `localizedCount(_:slots:)`）。
        return localizedCount("生产码 %1$lld 行 / 全量 %2$lld 行",
                              slots: [production.codeLines, code.codeLines])
    }

    /// 「这一档真的量到 0」那句说明。**只在生产码档在场且 `codeLines == 0` 时出声。**
    ///
    /// 它存在的全部理由是：`0` 与 `--` 在同一格里长得不一样**还不够**，读者还得知道
    /// 这个 0 是结论（八档都数过、生产码这一档一个文件都没有）而不是没数。
    /// ⚠️ 这一句只说这一档的分档结果，**不许**长成「这个项目没有源码」那类结论 ——
    /// 一个 `src/` 都没有的仓库完全可能有几万行测试与文档，那件事由别的格在说。
    static func measuredZeroNotice(_ code: CodeMetrics) -> String? {
        guard code.fileRoles?.share(for: .production)?.codeLines == 0 else { return nil }
        // 句子里**不留数字字面**：`groupedInto` 按「第 i 个槽 ⇔ 第 i 段连续数字」配对，
        // 模板里多出来的一枚 `0` 会把千分位补到别人的数字上（英文态更明显）。
        return localizedCopy("生产码这一档这次量到的是零，不是没数出来")
    }

    /// 弱判定打折提示：生产码档里 `weakEvidenceFiles > 0` 时才出声。
    ///
    /// 数来自契约那一格（`CodeFileRoleShare.weakEvidenceFiles` 只挂生产档）。
    /// `nil` = 本次没记这一格 ⇒ **不出声**（不许补 0 说成「一个弱判定都没有」）；
    /// `0` = 记过了而真的是 0 ⇒ 同样不出声（零命中不出声，与 `SourceRoleTally.notes` 一条纪律）。
    /// 这一次是**接上**而不是继续不接：`SourceRoleTally.weakEvidenceNote` 那句
    /// 「读生产码规模时按它打折」说的就是这件事，现在它在屏上有人说了；
    /// `scanLimitations` 那本账仍然不收它，理由写在 `SourceRoleTally.notes` 那段注释里
    /// （同一个数已经在上屏的句子里出声，再挂一条边界等于把已经量到的东西重复计成「没量准」）。
    static func weakEvidenceHint(_ code: CodeMetrics) -> String? {
        guard let weak = code.fileRoles?.share(for: .production)?.weakEvidenceFiles, weak > 0
        else { return nil }
        return localizedCount("生产码里 %lld 个文件只有语言证据、路径没有线索，读这一档要按它打折", weak)
    }
}
