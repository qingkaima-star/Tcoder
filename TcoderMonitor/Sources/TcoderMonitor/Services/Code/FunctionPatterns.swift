import Foundation

// OWNER: Workstream A (静态代码分析) —— FunctionPatterns
//
// 从 ComplexityEngine.swift 拆出，只为守住本工作流的红线（800 行以上的文件不得增加）：
// 语义、阈值、判定顺序一字未改。原先的 `private` 跨文件后必须放宽到模块内可见（internal），
// 除可见性外没有任何变化；ComplexityEngine 本身仍是唯一的入口。
//
// 各语言函数签名正则表（16 语言 25 条）。逐条都带真实语料踩出来的细节注释。

extension ComplexityEngine {
    // MARK: Patterns

    /// 语言 → 签名正则表。**未收录的语言给空数组**，与原先 `switch` 的 `default: return []` 一致。
    ///
    /// 为什么从 switch 改成查表：`patterns(of:)` 原来是 16 个 `case` 的分支（自扫报告点名
    /// CC=17），而里面**一条逻辑都没有**，全是「这个名字配这批正则」的静态数据。
    /// 换成字典之后同一批数据一字未动（顺序、成员、语言名都按原表逐行搬过来），
    /// 只把分支从 17 降到 2。附带好处：原来每个文件都要重造 25 个 `SignaturePattern` 结构体，
    /// 现在进程内构造一次（正则本身早有 `LanguageProfiles` 的 `cache(_:)` 兜着，
    /// 所以**编译次数没有变化**，变的只是数组与结构体的重复构造）。
    static let patternsByLanguage: [String: [SignaturePattern]] = [
        "Swift": [swiftFunction, swiftInitSubscript],
        "Kotlin": [kotlinFunction, cStyleFunction],
        "Java": [cStyleFunction],
        "Scala": [scalaFunction, cStyleFunction],
        "TypeScript": [jsFunction, jsVariableArrow, jsMethod, jsObjectMethod],
        "JavaScript": [jsFunction, jsVariableArrow, jsMethod, jsObjectMethod],
        "Vue": [jsFunction, jsVariableArrow, jsMethod, jsObjectMethod],
        "C": [cStyleFunction],
        "C++": [cStyleFunction],
        "Objective-C": [objectiveCMethod, cStyleFunction],
        "Go": [goFunction],
        "Rust": [rustFunction],
        "Python": [pythonFunction],
        "Ruby": [rubyFunction],
        "PHP": [phpFunction],
        "Dart": [cStyleFunction],
        "Gradle": [jsFunction, cStyleFunction],
        "Shell": [shellBrace, shellNameParen],
    ]

    static func patterns(of language: String) -> [SignaturePattern] {
        patternsByLanguage[language] ?? []
    }

    // 以下全部正则一律用 Swift 原始字符串 #"…"#：
    // 原始串里 `\(` 就是字面的「反斜杠 + 左括号」（正则的转义括号），只有 `\#(x)` 才是插值。
    // 普通字符串里单反斜杠 `\(` 会被 Swift 当成插值起点，这正是本文件此前一批编译错误的根因。

    static let annotationPrefix = #"\s*@\w+(?:\.\w+)*(?:\([^()]*\))?"#

    static let modifierGroup =
        #"(?:(?:public|private(?:\(\))?|protected|internal|fileprivate|open|static|class|final|"#
        + #"abstract|override|sealed|data|value|inline|noinline|crossinline|tailrec|operator|infix|"#
        + #"external|constexpr|volatile|register|restrict|synchronized|throws|rethrows|async|await|suspend|"#
        + #"lazy|mutating|nonisolated|isolated|weak|strong|autoclosure|composable|virtual|readonly|"#
        + #"native|strictfp|default)[ \t]+)"#

    /// 「缩进 + 注解/修饰符（可重复，彼此之间允许空白）」前缀。
    /// 两处细节都是踩出来的：
    /// 1) 行首空白必须放在重复组之前，否则 `    suspend fun foo()` 这类带缩进的修饰符签名匹配不上；
    /// 2) 组内还要留一个 `[ \t]*`，否则 `@MainActor private func` 这种「注解 + 修饰符」会断在空格上。
    static var head: String { #"[ \t]*(?:(?:\#(annotationPrefix)|\#(modifierGroup))[ \t]*)*"# }

    /// 单层参数列表（不含嵌套花括号，遇分号/换行即止）。
    static let params = #"\((?:[^;{}\n]*)\)"#

    static var swiftFunction: SignaturePattern {
        let modifiers = #"(?:(?:public|private|internal|fileprivate|open|static|class|final|override|"#
            + #"mutating|nonmutating|nonisolated|isolated|async|throws|rethrows|lazy|@\w+(?:\([^()]*\))?)[ \t]+)*"#
        // 覆盖：func name(_ a: Int, b: String) throws -> Foo {
        //       func name() { … / 泛型 func name<T: P>(…) where T: Q { …
        //       多行签名（`(` 之后换行，`{` 落在后面几行）→ 只要求匹配到 `(` 即可，
        //       函数体边界由 curlyEnd 向后找第一个 `{`。
        return SignaturePattern(
            #"^\#(head)\#(modifiers)func[ \t]+([A-Za-z_]\w*)[ \t]*(?:<[^<>()]*>)?[ \t]*\((?:[^;{}\n]*\))?(?:[^{;\n]*)?(?:\{|$)"#
        )
    }

    static var swiftInitSubscript: SignaturePattern {
        SignaturePattern(
            #"^\#(head)(?:[A-Za-z_][\w.]*[ \t]+)*((?:init|subscript)(?:\p{Hiragana}\p{Katakana}\w*)?)"#
                + #"[ \t]*(?:<[^<>()]*>)?[ \t]*\("#,
            namePrefix: "@"
        )
    }

    static var kotlinFunction: SignaturePattern {
        SignaturePattern(#"^\#(head)(?:fun|operator)[ \t]+(?:<[^<>]*>[ \t]*)?([A-Za-z_]\w*)[ \t]*\("#)
    }

    static var scalaFunction: SignaturePattern {
        SignaturePattern(#"^\#(head)def[ \t]+([A-Za-z_]\w*)[ \t]*(?:\(|:)"#)
    }

    static var cStyleFunction: SignaturePattern {
        let type = #"(?:[A-Za-z_$][\w$]*(?:\.\w+|::\w+)*(?:<[^<>{}();]*>)?(?:[ \t]*\[[ \t]*\])*[ \t*&]+)+"#
        // 组 1 必须是「函数名」本身；C++ 的 Foo::bar / Foo::~Foo 要整体算名字。
        // 参数表之后到 `{` 之间允许任意限定串：throws / noexcept / const / override / -> Ret / where…
        // （只排除分号和换行，所以 `foo(bar);` 这种调用行依然不会被误判成定义。）
        return SignaturePattern(
            #"^\#(head)(?:\#(type))?((?:[A-Za-z_$][\w$]*::)*~?[A-Za-z_$][\w$]*)[ \t]*\#(params)[^{;\n]*(?:\{|$)"#,
            requiresModifierWhenNoType: true
        )
    }

    static var objectiveCMethod: SignaturePattern {
        SignaturePattern(#"^[ \t]*[-+][ \t]*\([^()]*\)[ \t]*([A-Za-z_]\w*)"#)
    }

    static var jsFunction: SignaturePattern {
        // 允许赋值型函数表达式：`module.exports = function main(cb) {`、`handlers.save = function () {`
        let target = #"(?:[A-Za-z_$][\w$]*(?:\.?\[[^\]\n]{1,60}\]|\.[A-Za-z_$][\w$]*)*)[ \t]*=[ \t]*"#
        return SignaturePattern(
            #"^\#(head)(?:\#(target))?(?:export[ \t]+)?(?:default[ \t]+)?function[ \t]*\*?[ \t]*([A-Za-z_$][\w$]*)?[ \t]*\("#
        )
    }

    static var jsVariableArrow: SignaturePattern {
        let name = #"([A-Za-z_$][\w$]*)"#
        let typeAnn = #"(?:[ \t]*:[ \t]*[^=;{}()]*?)?"#
        return SignaturePattern(
            #"^\#(head)(?:const|let|var)[ \t]+\#(name)[ \t]*=[ \t]*(?:async[ \t]+)?"#
                + #"(?:function[ \t]*\*?[ \t]*(?:[A-Za-z_$][\w$]*)?[ \t]*)?\#(typeAnn)\("#
        )
    }

    static var jsMethod: SignaturePattern {
        // 整个成员名必须是捕获组 1：namePrefix "." 与 groupText(_,1) 都靠它（漏掉捕获会当场崩）
        let member = #"([A-Za-z_$][\w$]*|\[[^\]\n]{1,60}\]|"[^"\n]{1,60}"|'[^'\n]{1,60}')"#
        return SignaturePattern(
            #"^\#(head)(?:get[ \t]+|set[ \t]+)?\#(member)[ \t]*\.?[ \t]*\#(params)"#
                + #"(?:[ \t]*:[ \t]*[^;{}\n=]+)?[ \t]*\{"#,
            namePrefix: "."
        )
    }

    static var jsObjectMethod: SignaturePattern {
        SignaturePattern(
            #"^\#(head)("[^"\n]{1,60}"|'[^'\n]{1,60}'|[A-Za-z_$][\w$]*)[ \t]*:[ \t]*(?:async[ \t]+)?"#
                + #"(?:function[ \t]*\*?[ \t]*(?:[A-Za-z_$][\w$]*)?[ \t]*)?(?:\#(params)|[A-Za-z_$][\w$]*)"#
                + #"(?:[ \t]*:[ \t]*[^;{}\n=]+)?[ \t]*(?:=>|\{)"#,
            namePrefix: "."
        )
    }

    static var goFunction: SignaturePattern {
        // Go 1.18+ 泛型：`func Map[K comparable, V any](...)` 的类型参数表夹在名字和 `(` 之间
        SignaturePattern(#"^func[ \t]*(?:\([^()]*\)[ \t]*)?([A-Za-z_]\w*)[ \t]*(?:\[(?:[^\]\[\n]|\[[^\]\n]*\])*\])?[ \t]*\("#)
    }

    static var rustFunction: SignaturePattern {
        SignaturePattern(
            #"^[ \t]*(?:pub(?:\([^()]*\))?[ \t]+)?(?:(?:default|async|unsafe|extern|const)[ \t]+)*"#
                + #"fn[ \t]+([A-Za-z_]\w*)[ \t]*(?:<[^<>()]*>)?[ \t]*\("#
        )
    }

    static var pythonFunction: SignaturePattern {
        SignaturePattern(#"^[ \t]*(?:async[ \t]+)?def[ \t]+([A-Za-z_]\w*)[ \t]*\("#)
    }

    static var rubyFunction: SignaturePattern {
        SignaturePattern(
            #"^[ \t]*def[ \t]+([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*[?!=]?|\[\]=[\]]?|[!~<>=+\-*/%|&^]+)[ \t]*(?:\(|$|;)"#,
            needsParen: false
        )
    }

    static var phpFunction: SignaturePattern {
        SignaturePattern(#"^\#(head)function[ \t]+&?([A-Za-z_][\w]*)[ \t]*\("#)
    }

    static var shellBrace: SignaturePattern {
        SignaturePattern(#"^[ \t]*([A-Za-z_]\w*)[ \t]*\([ \t]*\)[ \t]*(?:\{|$)"#)
    }

    static var shellNameParen: SignaturePattern {
        SignaturePattern(
            #"^[ \t]*(?:function[ \t]+|source[ \t]+)([A-Za-z_]\w*)[ \t]*(?:\([^()]*\))?[ \t]*(?:\{|$)"#,
            needsParen: false
        )
    }
}
