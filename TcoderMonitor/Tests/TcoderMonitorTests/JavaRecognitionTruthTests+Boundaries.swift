import Foundation
import XCTest
@testable import TcoderMonitor

/// OWNER: R1 · Java 函数识别流 —— RD-03 / RD-04 的边界与分类真值。
///
/// 判据本体在 `JavaRecognitionTruthTests.swift`（名单精确相等 + 逐个边界对齐 + 点名不许出现）。
/// 这一份只管一件事：**方法边界必须止于该方法自己的配对 `}`**，
/// 并且泛型 / 构造器 / 多行签名 / 嵌套类型 / try-with-resources / lambda 各自都要有正例。
extension JavaRecognitionTruthTests {

    /// 构造器 / 泛型方法 / 多行签名 / 嵌套类型里的方法。
    /// 现状（改前）：`pick` 因泛型参数表夹在返回类型之前而**整条漏报**，
    /// `multiLineSignature` 因签名正则要求 `(` 与 `)` 同行而**整条漏报**。
    func testConstructorGenericsMultiLineSignatureAndNestedTypeAllBoundThemselves() {
        JavaTruth.assertTruth(
            JavaRecognitionTruthTests.genericsAndNestedType,
            expected: ["OrderService", "pick", "multiLineSignature", "inner"],
            forbidden: ["Helper", "Comparable", "Clock", "T", "tenant", "limit", "query",
                        "compareTo", "helper", "x"]
        )
    }

    /// 多行签名不仅要边界对，还得**数得出参数**——
    /// 签名行截在 `(` 上时，参数表必须一路并到 `{` 那一行再切。
    func testMultiLineSignatureCountsItsParametersAcrossLines() {
        let parsed = JavaTruth.parse(JavaRecognitionTruthTests.genericsAndNestedType)
        let found = JavaTruth.candidates(parsed)
        let multi = found.first { $0.name == "multiLineSignature" }
        XCTAssertNotNil(multi, "多行签名整条漏报：\(found.map(\.name))")
        XCTAssertEqual(multi?.parameterCount, 2, "跨行的 `(String tenant, int limit)` 必须算出 2 个参数")
        XCTAssertEqual(found.first { $0.name == "pick" }?.parameterCount, 2,
                       "泛型方法的参数表不能被类型参数表吃掉")
    }

    /// 普通调用行 / 字段声明 / try-with-resources 资源声明 / lambda：一条都不许独立上榜。
    /// 匿名类里**声明出来的具名方法** `onClick` 各出一条条目、各算自己的体 ⇒ 它在 expected 里，
    /// 不在 forbidden 里。
    ///
    /// ① **这条口径从哪来**：RD-08 + 台账 §13（2026-09-22 由总工在集成分支统一裁定）——
    ///    全仓一条口径：**具名嵌套函数（含匿名类里声明的方法）一律各出一条条目、各算自己的体**，
    ///    外层条目的复杂度按行挖掉直接子条目的跨度。落在 `FunctionScanning.Scan`
    ///    （`ownLines(of:)` + `nestedFunctionCount`）上，**不分语言**：Java 与 TS 走同一份实现。
    ///    本条原先写的是 R1 的「保留边界③」（匿名类体内的 `onClick` 归入外层方法体），
    ///    现在按 RD-08 改掉。
    ///
    /// ② **为什么"归入外层"不能留**：就在同一份文件下面那条
    ///    `testAnonymousClassOnAFieldIsNotAMethodButItsBodyMethodSurvives` 钉的是
    ///    「字段初始化式上挂的匿名类，其体内的 `onClick` **能**单独上榜」（伪函数不再吞整类之后）。
    ///    两处的构造是同一个 `new ClickHandler() { @Override public void onClick() {…} }`，
    ///    差别只是外层是方法体还是字段 —— 如果这里折进 `run` 而那里允许单列，
    ///    同一个形状在本文件里就有了两套答案，那正是 AGENTS §8 拦的"两套尺子"，
    ///    也是这次合并三条红里的一条（两条流各自门禁都绿，合起来必有一条被打红）。
    ///
    /// ③ **双计风险不由"不列子条目"来挡**：父条目 `run` 的复杂度只算 `ownLines(of:)` ——
    ///    整个跨度里按行挖掉直接子条目的跨度，`run` 少算的那几行恰好是 `onClick` 多算的那几行，
    ///    一个 `if` 不会被算两遍；对账口径「全文件条目的判定分支之和 == 源码真实分支数」
    ///    由 `TsNestedComplexityCaliberTests` 钉在同一份 `Scan` 上。
    ///    `lineCount` 仍是整段跨度（"这个函数写多长"的口径），所以边界真值照 `// R1!` / `// R1/` 标。
    func testCallsFieldsResourcesAndLambdaBodiesStayOffTheList() {
        JavaTruth.assertTruth(
            JavaRecognitionTruthTests.callsAndResources,
            expected: ["run", "onClick", "after"],
            forbidden: ["ClickHandler", "handler", "worker", "handle", "request",
                        "LIMIT", "compute", "transferTo", "newInputStream", "newOutputStream",
                        "info", "log", "reset", "ReportingJob", "Job", "Override", "Runnable"]
        )
    }

    /// 类字段上挂的匿名类：`new ClickHandler() {` 不许被读成名为 `ClickHandler` 的方法，
    /// 而它体内的 `onClick` 因为**没有被伪函数吞掉**才终于能单独上榜。
    func testAnonymousClassOnAFieldIsNotAMethodButItsBodyMethodSurvives() {
        JavaTruth.assertTruth(
            JavaRecognitionTruthTests.fieldInitializedAnonymousClass,
            expected: ["onClick", "count"],
            forbidden: ["ClickHandler", "fallback", "made", "WidgetFactory", "Override"]
        )
    }

    /// 语句关键字打头的行（`synchronized (lock) {`、`if (x) {`、`for (…)`、try-with-resources
    /// 的资源声明、普通调用行、字段声明）逐行喂给签名匹配，**一条都不许吐名字**。
    /// 这里直接测 `matchSignature` 而不是测整份文件：这些行在真文件里都被外层方法体盖住，
    /// 走文件级扫描根本到不了那一行——那是一条永真绿。
    func testStatementShelvesNeverYieldASignatureName() {
        let profile = ComplexityEngine.profile(for: "Java")
        for line in JavaRecognitionTruthTests.statementOnlyLines {
            XCTAssertNil(ComplexityEngine.matchSignature(line, profile), "语句行被判成签名：\(line)")
        }
    }

    /// 反过来，正例必须真的吐出名字（否则上一条可以靠"永远返回 nil"蒙过）。
    func testRealJavaSignaturesStillYieldTheirNames() {
        let profile = ComplexityEngine.profile(for: "Java")
        XCTAssertEqual(ComplexityEngine.matchSignature("public void save() {", profile), "save")
        XCTAssertEqual(ComplexityEngine.matchSignature("@Override public void save() {", profile), "save",
                       "注解紧贴签名是最常见的 Java 形状，必须认得")
        XCTAssertEqual(ComplexityEngine.matchSignature("public OrderService(Clock clock) {", profile),
                       "OrderService", "构造器要按构造器认，不许退化成裸调用")
    }
}

// MARK: - 夹具正文

extension JavaRecognitionTruthTests {

    static let genericsAndNestedType = """
    public class OrderService {

        private final Clock clock;

        public OrderService(Clock clock) { // R1!OrderService
            this.clock = clock;
        } // R1/OrderService

        public <T extends Comparable<T>> T pick(T a, T b) { // R1!pick
            if (a.compareTo(b) > 0) {
                return a;
            }
            return b;
        } // R1/pick

        public void multiLineSignature( // R1!multiLineSignature
                String tenant,
                int limit) {
            query(tenant, limit);
        } // R1/multiLineSignature

        static class Helper {
            void inner(int x) { // R1!inner
                if (x > 0) {
                    helper(x);
                }
            } // R1/inner
        }
    }
    """

    static let callsAndResources = """
    public class ReportingJob implements Job {

        private static final int LIMIT = compute(3);

        public void run() { // R1!run
            service.handle(request);
            ClickHandler handler = new ClickHandler() {
                @Override
                public void onClick() { // R1!onClick
                    pressed = true;
                } // R1/onClick
            };
            Runnable worker = () -> {
                if (ok) {
                    log.info("tick");
                }
            };
            try (InputStream in = Files.newInputStream(src);
                 OutputStream out = Files.newOutputStream(dst)) {
                in.transferTo(out);
            }
        } // R1/run

        public void after() { // R1!after
            reset();
        } // R1/after
    }
    """

    static let fieldInitializedAnonymousClass = """
    class WidgetFactory {

        private final ClickHandler fallback = new ClickHandler() {
            @Override
            public void onClick() { // R1!onClick
                pressed = true;
            } // R1/onClick
        };

        public int count() { // R1!count
            return made;
        } // R1/count
    }
    """

    /// 喂给 `matchSignature` 的语句行：形状取自上面夹具正文里真实出现过的那些行，
    /// 只是脱离了「被外层方法体盖住」的上下文，好让签名匹配自己被量一次。
    static let statementOnlyLines = [
        "        synchronized (lock) {",
        "            if (lane.isEmpty()) {",
        "                for (String lane : lanes) {",
        "            while (attempt > 0) {",
        "            switch (order.state()) {",
        "        service.handle(request);",
        "        ClickHandler handler = new ClickHandler() {",
        "        Runnable worker = () -> {",
        "        private static final int LIMIT = compute(3);",
        "             OutputStream out = Files.newOutputStream(dst)) {",
        "        DOMESTIC(40), CROSS(120);",
        "        List<User> findByTenant(String tenant);",
        "    }",
        "};",
    ]
}
