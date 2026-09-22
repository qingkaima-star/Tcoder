import Foundation
import XCTest
@testable import TcoderMonitor

/// OWNER: R1 · Java 函数识别流 —— RD-01 / RD-02 的**独立真值**闸门。
///
/// 本文件的每一条期望都是**手写**的：夹具正文里的 `// R1!名字`（签名起始行）与
/// `// R1/名字`（该方法**自己**的闭合 `}` 行）是作者对「这段 Java 里哪个方法从哪行到哪行」的判断，
/// **不是**从 `ComplexityEngine` 的输出反抄回来的（AGENTS §8 硬约束 6：不许拿实现自身输出当真值）。
/// 用标记而不是手写行号，是为了让我自己数错行号时当场可见，同时不改变判据的来源。
///
/// 三条判据必须一起成立才叫「注解 / 类声明 / 构造器 / 普通调用 / 资源声明 与方法分开判」：
/// 1. **榜上名单精确等于真值**（排序后集合相等）—— 多一个是误报（X1），少一个是漏报（X2）；
/// 2. **每个方法的起止行等于标记位置** —— 名字对上而边界吃掉整个类体不算通过（RD-04）；
/// 3. **点名清单逐个不许出现** —— `h`、`s` 这类由 `@ExtendWit` + `h(` 回溯拆出来的伪函数。
///    第 3 条与第 1 条故意重叠：集合相等挂掉时要能一眼看出是哪个名字错了。
///
/// 语言判定：夹具在内存里构造成 `ScannedSourceFile(language: "Java")`，
/// **不落 `.java` 文件进仓库**（会被本仓自扫当成真源码、污染分母）。
/// 走真磁盘 + 真分类器的端到端证据在 `+Honesty` 那份里，由真 CLI 子进程出。
final class JavaRecognitionTruthTests: XCTestCase {

    /// RD-01 主案发现场：Mockito / JUnit 5 的类级注解。
    /// `@ExtendWith(MockitoExtension.class)` 会被拆成「注解 `@ExtendWit` + 函数名 `h`」，
    /// `@MockitoSettings(strictness = …)` 拆成「`@MockitoSetting` + `s`」——
    /// 名字段允许单字符 + `@\w+` 可回溯，两条凑在一起就是伪函数。
    func testMockitoStyleClassAnnotationsYieldOnlyRealMethods() {
        JavaTruth.assertTruth(
            JavaRecognitionTruthTests.mockitoAnnotationClass,
            expected: ["setUp", "rejectsEmptyCart"],
            forbidden: ["h", "s", "e", "OrderServiceTest", "ExtendWith", "MockitoSettings",
                        "DisplayName", "CsvSource", "repository", "service", "OrderService",
                        "deleteAll", "isEmpty", "IllegalStateException", "BeforeEach", "Test"]
        )
    }

    /// 带多参数的注解、数组参数注解、注解紧贴签名：都不许长出伪函数，
    /// 而 `find` / `listAll` 两个真方法必须照常上榜。
    func testMultiArgumentAndBraceValuedAnnotationsAreNotSplit() {
        JavaTruth.assertTruth(
            JavaRecognitionTruthTests.auditedService,
            expected: ["find", "listAll"],
            forbidden: ["d", "e", "n", "s", "AuditService", "SuppressWarnings", "Audited",
                        "Cacheable", "Transactional", "RequestMapping", "repository", "findAll",
                        "User", "id"]
        )
    }

    /// 注解紧贴方法声明是**必须保住**的正例：`@Override public void save()` 要认成 `save`。
    /// 跨行注解（`@Query(` … `)` 摊成四行）不许把后面的真签名一起废掉。
    func testAnnotationHuggingSignatureAndCrossLineAnnotationBothStillYieldMethods() {
        JavaTruth.assertTruth(
            JavaRecognitionTruthTests.annotationAdjacentToSignature,
            expected: ["save", "paginated"],
            forbidden: ["l", "Query", "Transactional", "Override", "value", "countQuery",
                        "CartTest", "cart", "write", "String", "valueOf", "page"]
        )
    }

    /// 接口里的抽象声明**没有方法体**，本引擎的口径是「函数 = 有体的签名」，所以此处真值为空。
    /// 但「没识别出来」不等于「这个文件没有方法」—— 必须由限制通道出声（见 `+Honesty`）。
    func testInterfaceDeclarationsWithoutBodiesAreNotCountedAsFunctions() {
        JavaTruth.assertTruth(
            JavaRecognitionTruthTests.repositoryInterface,
            expected: [],
            forbidden: ["findByTenant", "purge", "Query", "Modifying", "Transactional",
                        "value", "countQuery", "UserRepository", "count"]
        )
    }

    /// 元测试（E②）：判据器本身要能被合成违例打到，也要放过干净结果。
    /// 少了这一条，「标记解析失效 → 期望表空 → 榜上也空 → 全绿」就是一条永真绿路径。
    func testTruthJudgeCatchesSyntheticViolations() {
        let parsed = JavaTruth.parse(JavaRecognitionTruthTests.mockitoAnnotationClass)
        XCTAssertEqual(parsed.truth["setUp"], 12...14, "标记解析必须还我手写行号")
        XCTAssertEqual(parsed.truth["rejectsEmptyCart"], 19...23, "标记解析必须还我手写行号")

        // 违例 1：RD-01 的原始形状 —— 注解拆出伪函数 `h`/`s`，**并且**真方法 `setUp` 的边界
        // 被类体的 `}` 撑到 12…24（原来吃掉整个类体的就是这个）。两种坏法必须同时被抓。
        let swallowing = [
            FunctionCandidate(name: "h", startLine: 1, lineCount: 24, parameterCount: 1, complexity: 9),
            FunctionCandidate(name: "s", startLine: 2, lineCount: 23, parameterCount: 1, complexity: 8),
            FunctionCandidate(name: "setUp", startLine: 12, lineCount: 13, parameterCount: 0, complexity: 1),
            FunctionCandidate(name: "rejectsEmptyCart", startLine: 19, lineCount: 5, parameterCount: 0, complexity: 2),
        ]
        let hits = JavaTruth.problems(parsed: parsed,
                                      expected: ["setUp", "rejectsEmptyCart"],
                                      forbidden: ["h", "s"], found: swallowing)
        XCTAssertTrue(hits.contains { $0.contains("识别名单不等于真值") }, "\(hits)")
        XCTAssertTrue(hits.contains { $0.contains("误报未消除：榜上仍挂着 h") }, "\(hits)")
        XCTAssertTrue(hits.contains { $0.contains("边界未绑到") }, "setUp 被撑到类体尾必须被抓：\(hits)")

        // 违例 2：漏报——只有真值里的一半上榜。
        let half = [FunctionCandidate(name: "setUp", startLine: 12, lineCount: 3, parameterCount: 0, complexity: 1)]
        XCTAssertTrue(JavaTruth.problems(parsed: parsed, expected: ["setUp", "rejectsEmptyCart"],
                                         forbidden: [], found: half)
            .contains { $0.contains("识别名单不等于真值") }, "漏报必须被抓到")

        // 正例：与真值完全一致的结果必须零问题（否则判据是永真红，也等于没判据）。
        XCTAssertTrue(JavaTruth.problems(parsed: parsed, expected: ["setUp", "rejectsEmptyCart"],
                                         forbidden: ["h"], found: JavaTruth.candidates(parsed)).isEmpty,
                      "干净结果被判出问题 → 判据器自己坏了")
    }
}

// MARK: - 夹具正文（手写 Java，逐行对照真值标记）

extension JavaRecognitionTruthTests {

    /// 24 行。期望：`setUp` 12…14、`rejectsEmptyCart` 19…23。
    static let mockitoAnnotationClass = """
    @ExtendWith(MockitoExtension.class)
    @MockitoSettings(strictness = Strictness.STRICT_STUBS)
    class OrderServiceTest {

        @Mock
        private OrderRepository repository;

        @InjectMocks
        private OrderService service = new OrderService();

        @BeforeEach
        void setUp() { // R1!setUp
            repository.deleteAll();
        } // R1/setUp

        @Test
        @DisplayName("rejects empty cart")
        @CsvSource(source = Class.class)
        void rejectsEmptyCart() { // R1!rejectsEmptyCart
            if (service.isEmpty()) {
                throw new IllegalStateException("empty");
            }
        } // R1/rejectsEmptyCart
    }
    """

    /// 期望：`find`、`listAll`。`@SuppressWarnings({"PMD", …})` 是数组参数形状。
    static let auditedService = """
    public class AuditService {

        @SuppressWarnings({"PMD", "Checkstyle"})
        @Audited(before = AuditOn.CREATE, after = AuditOn.DELETE)
        @Cacheable(value = "users", key = "#id")
        public User find(String id) { // R1!find
            return repository.find(id);
        } // R1/find

        @Transactional(readOnly = true)
        @RequestMapping(method = RequestMethod.POST, value = "/x")
        public List<User> listAll() { // R1!listAll
            return repository.findAll();
        } // R1/listAll
    }
    """

    /// 期望：`save`（注解紧贴签名）、`paginated`（跨行注解之后）。
    static let annotationAdjacentToSignature = """
    class CartTest {

        @Override
        public void save() { // R1!save
            store.write(cart);
        } // R1/save

        @Query(
            value = "SELECT c FROM Cart c",
            countQuery = "SELECT count(c) FROM Cart c"
        )
        @Transactional(readOnly = true)
        public String paginated(int page) { // R1!paginated
            if (page < 0) {
                return "";
            }
            return String.valueOf(page);
        } // R1/paginated
    }
    """

    /// 全部是无体声明：真值为空集。
    static let repositoryInterface = """
    public interface UserRepository extends JpaRepository<User, Long> {

        @Query(
            value = "SELECT u FROM User u WHERE u.tenant = :tenant",
            countQuery = "SELECT count(u) FROM User u"
        )
        List<User> findByTenant(String tenant);

        @Modifying
        @Transactional
        void purge(String tenant);
    }
    """
}
