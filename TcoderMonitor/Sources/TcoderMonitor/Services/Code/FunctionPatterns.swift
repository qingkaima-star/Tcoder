import Foundation

// OWNER: Workstream A (静态代码分析) —— FunctionPatterns
//
// 从 ComplexityEngine.swift 拆出，只为守住本工作流的红线（800 行以上的文件不得增加）：
// 语义、阈值、判定顺序一字未改。原先的 `private` 跨文件后必须放宽到模块内可见（internal），
// 除可见性外没有任何变化；ComplexityEngine 本身仍是唯一的入口。
//
// 各语言函数签名正则表（16 语言 25 条）。逐条都带真实语料踩出来的细节注释。
//
// 2026-09-22 R1（检测正确性整改轮）改过两处、新增一处，**不再是"一字未改"**：
// `annotationPrefix` 加原子组（RD-01 注解被拆成"前缀＋函数名"），
// `cStyleFunction` 加泛型类型参数表 + 允许多行签名收尾（RD-04 漏报补齐），
// 末尾整块新增 `JavaSignatureDeclines`（RD-04「覆盖不了的要出声」；搬到这里而不是
// `FunctionRecognition.swift`，是因为那边离本仓 400 行闸门只剩 7 行余量）。
// 三条都在 `JavaRecognitionTruthTests*` 里有独立真值 + 合成违例元测试钉着。

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

    /// 注解段。**`(?>…)` 是原子组，这条是本文件唯一的"不许回溯"承诺**，也是 RD-01 的根因所在：
    ///
    /// 原先写成普通的 `@\w+(?:\.\w+)*(?:\([^()]*\))?`，于是 `@\w+` 可以**缩短**、
    /// 把注解名的尾巴让给后面的「函数名」段。`@ExtendWith(X.class)` 因此被读成
    /// 「注解 `@ExtendWit` + 函数名 `h` + 参数表 `(X.class)`」，`@MockitoSettings(strictness = …)`
    /// 被读成「`@MockitoSetting` + `s`」，`@Foo(bar(1))` 被读成「`@Fo` + `o`」。
    /// 伪函数之后还要接边界：`curlyEnd` 一路找到类体的 `}`，于是整个类被记成一个"高复杂度方法"。
    ///
    /// 原子组让这条回溯路径**在语法上不存在**：注解一旦按贪婪匹配吃定，就不许再吐字符回来。
    /// 为什么这比"屏蔽 `s`/`h` 这类名字"或"给 Mockito 特判"对：
    /// 前者是把已知的三个名字钉住，换个注解（`@SpringBootTest(…)`、`@Audited(…)`）立刻长回来；
    /// 后者是把一个**语法层**的形状问题挪到**词表层**去解。这里改的是"注解段能不能被拆"，
    /// 与注解叫什么、来自哪个框架无关 —— Kotlin/Scala/PHP/Gradle 共用 `head`，
    /// TypeScript/JavaScript/Vue 的装饰器（`@observable name() {`）同一条路径一起被堵住。
    ///
    /// 保住的正例：`@Override public void save() {` —— 原子组吃 `@Override`（后面是空白，
    /// `(?:\([^()]*\))?` 自然匹配空），修饰符与返回类型照旧跟在后面，`save` 照常上榜。
    static let annotationPrefix = #"\s*(?>@\w+(?:\.\w+)*(?:\([^()]*\))?)"#

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
        // RD-04 之一：**泛型方法**。Java 把类型参数表夹在修饰符与返回类型之间
        // （`public <T extends Comparable<T>> T pick(T a, T b)`），原先这一段无处安放，
        // 整条签名直接漏报。允许两层尖括号嵌套；再深就不认——
        // 认不出是漏报（`JavaRecognitionNotes` 会出声），硬认是误报，两者代价不对称。
        let typeParams = #"(?:<[^<>\n]*(?:<[^<>\n]*>[^<>\n]*)*>[ \t]+)?"#
        // RD-04 之二：**多行签名**（`public void multiLine(` 换行铺参数）。
        // 参数表允许"没有收尾括号就到行尾"，函数体由 `curlyEnd` 在 `maxSignatureLookahead`
        // 窗口内向后找 `{`；窗口里再出现一条新签名就整条放弃，所以无体的抽象声明
        // 不会把下一个方法的 `{` 当成自己的边界。
        // 关键约束照旧留着：`;` 与 `}` 不能进参数表，`foo(bar);` 这类调用行仍进不来。
        let signatureParams = #"\((?:[^;{}\n]*\)|[^;{}\n]*$)"#
        // 组 1 必须是「函数名」本身；C++ 的 Foo::bar / Foo::~Foo 要整体算名字。
        // `(?<![\w$.])` 把「名字必须是一个完整词元的起点」写成 pattern 自己的约束，
        // 而不是"head 恰好把它挡住了"的副作用：`x.y.z(` 之后、或任何标识符中部都不许起名。
        // 参数表之后到 `{` 之间允许任意限定串：throws / noexcept / const / override / -> Ret / where…
        return SignaturePattern(
            #"^\#(head)\#(typeParams)(?:\#(type))?(?<![\w$.])((?:[A-Za-z_$][\w$]*::)*~?[A-Za-z_$][\w$]*)[ \t]*\#(signatureParams)[^{;\n]*(?:\{|$)"#,
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
        // `export` 前缀这一档以前**没有**：`jsFunction` 收了 `export function`，
        // 而 ESM/TS 模块里最常见的是 `export const useFoo = () => { … }` —— 少认它就是把
        // 整个模块的函数分母算小（台账 RD-79：交付二进制实测同形两块体箭头，
        // 不带 `export` 计到 1、带 `export` 计到 0）。
        // ⚠ 反例由守卫钉住：`export const config = { … }`（对象字面量，没有 `(`）
        //   与 `export const n = 1` 都**不许**被认成函数。
        return SignaturePattern(
            #"^\#(head)(?:export[ \t]+)?(?:const|let|var)[ \t]+\#(name)[ \t]*=[ \t]*(?:async[ \t]+)?"#
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

    // MARK: 未覆盖形状的台账（RD-04「覆盖不了的要出声」）

    /// Java 侧「长得像签名、但本轮不判成函数」的三类形状，逐类计数。
    ///
    /// 为什么必须有它：轻量正则漏掉的东西，在界面上必须长成"这几类没覆盖"，
    /// 而不是长成"这个文件里没有复杂函数"（整改清单里的 X2 漏报 + X3 未知冒充结论）。
    /// `ComplexityEngine` 只吐"认出来的"，认不出的一向是静默的 —— 这一层就是让静默变成读数。
    ///
    /// 三条判据各自独立计数，且**只报本次真扫到的条数**：一条都没遇到就不出声。
    /// 常驻的"我们是近似识别"提示等于把噪声当诚实，本仓既有红线（`scanLimitations`
    /// 的判据是"上限真的生效过"，见 `CodeAnalyzerPrecisionTests`）。
    enum JavaSignatureDeclines {
        struct Tally {
            var headlessDeclaration = 0
            var ambiguousBareSignature = 0
            var nestedAnonymousBody = 0
            var isEmpty: Bool {
                headlessDeclaration == 0 && ambiguousBareSignature == 0 && nestedAnonymousBody == 0
            }
            mutating func add(_ other: Tally) {
                headlessDeclaration += other.headlessDeclaration
                ambiguousBareSignature += other.ambiguousBareSignature
                nestedAnonymousBody += other.nestedAnonymousBody
            }
        }

        /// 类体一层深、以 `;` 收尾的「类型 + 名字 + 参数表」：接口方法 / 抽象方法。
        /// 没有方法体就没有边界，也就没有圈复杂度可算 —— 不计入函数榜。
        static let headlessPattern =
            #"^[ \t]*(?:[A-Za-z_$][\w$.]*(?:<[^<>\n]*>)?[ \t]+)+[A-Za-z_$][\w$]*[ \t]*\([^;{}()]*\)[ \t]*;[ \t]*$"#
        /// 类体一层深、名字前既无修饰符也无返回类型的 `Name(…) {`。
        /// 这**既可能是包级构造器**（`Lane(int limit) {`）**也可能是一条裸调用**
        /// （`foo(bar) {`）；两者要分开需要符号表知道外层类型名，本轮不做，所以只能报数不能猜。
        static let ambiguousBarePattern = #"^[ \t]*[A-Za-z_$][\w$]*[ \t]*\([^;{}()]*\)[ \t]*\{[ \t]*$"#
        /// lambda 与匿名类：它们的花括号是**外层方法体的一部分**，不单独列出（口径，不是漏报）。
        static let nestedBodyPattern = #"->[ \t]*\{|new[ \t]+[A-Za-z_$][\w$.]*[ \t]*\([^()]*\)[ \t]*\{"#

        /// 走一遍与主扫描**同一份** `sanitize`，所以花括号深度与函数边界看到的是同一个世界。
        static func tally(in file: ScannedSourceFile) -> Tally {
            let cleaned = ComplexityEngine.sanitize(file.lines.map(\.text),
                                                    ComplexityEngine.profile(for: file.language))
            var out = Tally()
            for (index, line) in cleaned.cleaned.enumerated() where line.isEmpty == false {
                let text = line as NSString
                let range = NSRange(location: 0, length: text.length)
                let depth = cleaned.prefix[index]
                if depth == 1 {
                    if hits(headlessPattern, text, range) { out.headlessDeclaration += 1 }
                    if hits(ambiguousBarePattern, text, range) { out.ambiguousBareSignature += 1 }
                } else if depth >= 2, hits(nestedBodyPattern, text, range) {
                    out.nestedAnonymousBody += 1
                }
            }
            return out
        }

        static func hits(_ pattern: String, _ text: NSString, _ range: NSRange) -> Bool {
            // 编不出来时 `cache` 已经把这条降级记进 `RuleDegradeLedger`；这里返回 false，
            // 不拿"匹配不到"冒充"没有这种形状"。
            ComplexityEngine.cache(pattern)?.firstMatch(in: text as String, options: [], range: range) != nil
        }

        /// 全仓汇总成 `CodeMetrics.scanLimitations` 的条目。只量 `Java` 档案的文件。
        static func notes(for files: [ScannedSourceFile]) -> [String] {
            var total = Tally()
            for file in files where ComplexityEngine.canonicalLanguage(file.language) == "Java" {
                total.add(tally(in: file))
            }
            guard total.isEmpty == false else { return [] }
            let prefix = "Java 函数识别为轻量正则（未接语法树）："
            var out: [String] = []
            if total.headlessDeclaration > 0 {
                out.append("\(prefix)\(total.headlessDeclaration) 处接口/抽象方法声明没有方法体，"
                    + "未计入函数榜（榜上没有 ≠ 文件里没有方法）。")
            }
            if total.ambiguousBareSignature > 0 {
                out.append("\(prefix)\(total.ambiguousBareSignature) 处「名字+参数表+{」之前既无修饰符"
                    + "也无返回类型，包级构造器与裸调用无法区分，未计入函数榜。")
            }
            if total.nestedAnonymousBody > 0 {
                out.append("\(prefix)\(total.nestedAnonymousBody) 处 lambda/匿名类体计入其外层方法体，"
                    + "不单独列出（外层方法的行数与 CC 含这段）。")
            }
            return out
        }
    }
}
