// OWNER: R3 依赖证据链 · 版本比较的唯一一把尺子（RD-10）
//
// 本类型原先住在 `Models/DependencyReport.swift`，2026-09-22 由 R3 按 AGENTS §8.1 的窄口径
// 豁免整块搬进本文件（那次豁免清单里点名的就是 `DependencyVersion` 一族：normalize / compare /
// isOlder）。搬动是**逐字节**的：成员、取义、文案一个字都没改，Models 里减掉的行与这里加上的行
// 按行多重集对得上（丢失 0 / 多出 0，脚本输出记在 R3 的 Obsidian `108`）。
//
// 为什么落在 `Services/Dependencies/`：这个类型已经不做解析，只把比较**下沉**给同目录的
// `DependencySemver`（全仓唯一一把 semver 尺子）—— 两者分开住会诱导下一个人回来加第二套解析，
// 而那正是 RD-10 的根因。类型名与调用形状一字未动 ⇒ 两个消费方零改动。
import Foundation

/// Minimal dotted-version compare that tolerates suffixes like `-SNAPSHOT`, `+build`, `^1.2.3`.
///
/// ## RD-10 的根因修正（2026-09-22，R3 依 AGENTS §8.1 豁免动本类型）
///
/// 旧实现在自己内部有**两套**口径，且其中一套是错的：
///   · 这里用 `prefix(while:)` 取"数字芯"，而截断符集合里就写着 `^~<>` ——
///     `^1.2.3` 在**第一个字符**处断成空串 → `parts.isEmpty` → 返回 `[0]`，
///     于是任何 caret 声明都"落后于"任何最新版本（虚报过旧），
///     `*` / `latest` / `未声明` / `abc` 同样被折成 0.0.0 参与比较；
///   · 同一仓的 `KnownVulnerability.comparableCore` 却会先吃掉 `^`（两处不一致，台账点名）。
///
/// 现在的形状：
///   1. **全仓只有一把版本尺子** —— 比较一律下沉到 `DependencySemver`
///      （`Services/Dependencies/DependencyVersionIdentity.swift`），本类型不再自带第二套解析；
///      预发布（`-beta` / `-SNAPSHOT`）低于正式版，构建元数据（`+build`）不参与先后。
///   2. **认不出就是认不出**：`normalize` 返回空数组（旧返回 `[0]`），`outcome` 返回 `.unknown`，
///      `compare` 返回 **nil**（旧返回 `.orderedSame`，那是在谎称"这两个版本相等"），
///      `isOlder` 对不可比较的一侧返回 false —— 但**上层必须出声**，
///      逐条依赖的"为什么判不了"由 `DependencyVersionBlocker` 承载，不靠沉默。
///
/// ⚠ 本类型只回答"这两个串谁在前谁在后"。**"这条依赖装的是哪个版本"是另一件事**：
/// 声明范围 / 实际解析版本 / 最新已知版本三份身份住在 `DependencyVersionIdentity`，
/// `isProbablyOutdated` 已改走它 —— 那里明确禁止把 `^1.2.3` 的下界当安装版本。
enum DependencyVersion {
    /// 数字芯（不含预发布语义）。解析不出返回**空数组**（旧实现给 `[0]`，那正是 RD-10 的病根）。
    static func normalize(_ raw: String) -> [Int] {
        Self.core(raw)?.segments ?? []
    }

    /// 这个串能不能收敛成一个版本号。
    static func isComparable(_ raw: String) -> Bool { Self.core(raw) != nil }

    /// 两个串的先后。**返回 Optional：认不出就是"不可比较"，不许折成 `.orderedSame`。**
    ///
    /// 2026-09-22 由 R3 收口（这颗地雷当时不是活 bug —— 全仓零调用方，但它随时会被捡起来用）：
    /// 旧签名是 `(String, String) -> ComparisonResult`，而 body 第一行就写着
    /// `guard let left = Self.core(lhs), let right = Self.core(rhs) else { return .orderedSame }`
    /// —— 把"不知道"表达成了"相等"。三态本来就在 `outcome()` 里，这一支是它的失真副本。
    /// 失真的形状特别适合做排序/去重/分组的输入：`*` / `latest` / `未声明` / `[1.0,2.0)`
    /// 会互相"相等"，于是 `.sorted(by:)` 给出假稳定序、`Set`/`Dictionary(grouping:)` 把
    /// 不同的包并成一格（RD-10 的"未知折成 0"换个地方复发）。
    ///
    /// 为什么选"改返回类型"而不是"保留签名 + 加一条扫描守卫"（工单二选一，理由写在这里）：
    ///   1. **便宜**：全仓 `DependencyVersion.compare` 的调用点是 **0 处**（Sources + Tests 逐条
    ///      grep 过，只有本文件与 `Models/DependencyReport.swift` 的注释提到它），改签名零改动面；
    ///   2. **挡得住**：假"相等"这个**值**从表达里消失了 —— 无论调用方是直接拿函数引用
    ///      （`.sorted(by: DependencyVersion.compare)` 当场编译不过，`ComparisonResult?` 不是 `Bool`）
    ///      还是自己写包一层闭包，都不可能再把"认不出"读成"这两个版本一样"。
    ///      扫描守卫只能管 textual 形状，包一层就漏，且必须配白名单；这里不需要。
    ///   3. 语义要回来只有一个合法出口：**`outcome(current:than:)`，它有 `.unknown` 这一态**。
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        guard let left = Self.core(lhs), let right = Self.core(rhs) else { return nil }
        return DependencySemver.compare(left, right)
    }

    static func isOlder(current: String, than latest: String) -> Bool {
        outcome(current: current, than: latest) == .older
    }

    /// 三态结局：不可比较时**明确返回 `.unknown`**，调用方必须出声，不许按"更旧"或"不旧"处理。
    static func outcome(current: String, than latest: String) -> Outcome {
        guard let left = Self.core(current), let right = Self.core(latest) else { return .unknown }
        switch DependencySemver.compare(left, right) {
        case .orderedAscending: return .older
        case .orderedDescending: return .newer
        default: return .same
        }
    }

    enum Outcome: Equatable, Sendable {
        case older, same, newer, unknown
    }

    private static func core(_ raw: String) -> DependencySemver? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 前缀范围算符与 `v`：`^` `~` `>=` `>` `<=` `<` `=`，允许跟空格（`>= 1.2.3`）。
        while let first = text.first, "^~<>=".contains(first) {
            text = String(text.dropFirst())
            text = text.trimmingCharacters(in: .whitespaces)
        }
        // 带区间 / 多选 / 通配结构的串不是"一个版本号"，宁可不解，也不去取它某个端点冒充版本。
        if text.contains(where: { "[],()|*".contains($0) }) { return nil }
        if text.split(separator: ".").contains(where: { $0.lowercased() == "x" }) { return nil }
        return DependencySemver.parse(text)
    }
}
