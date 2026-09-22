import Foundation
import XCTest
@testable import TcoderMonitor

/// OWNER: R1 · Java 函数识别流 —— D 组「覆盖不了的要出声」。
///
/// 判据形状：走**真分析器 + 真磁盘夹具**（临时目录，即建即删，不落进仓库），
/// 一次同时量三件事——
/// 1. 伪函数不在榜上、真方法在榜上且**行数对**（榜单口径与 `+Boundaries` 那份对齐）；
/// 2. 轻量正则没能覆盖的 Java 形状必须以 `CodeMetrics.scanLimitations` 落盘，
///    界面上读得出「Java 识别 = 轻量正则，以下形状未覆盖」；
/// 3. **反向**：一类形状一个都没遇到时不许挂提示条——
///    「没测到」写成常驻声明，等于把噪声当诚实（本仓既有红线）。
extension JavaRecognitionTruthTests {

    /// 未覆盖形状的落盘：接口无体声明 / 无修饰符裸签名 / lambda 与匿名类体。
    func testDeclinedJavaShapesAreSpokenThroughScanLimitations() async throws {
        let root = try JavaTruth.writeTemp([
            ("src/OrderServiceTest.java", JavaRecognitionTruthTests.mockitoAnnotationClass),
            ("src/UserRepository.java", JavaRecognitionTruthTests.repositoryInterface),
            ("src/Lane.java", JavaRecognitionTruthTests.enumWithBareConstructor),
            ("src/ReportingJob.java", JavaRecognitionTruthTests.callsAndResources),
        ])
        defer { try? JavaTruth.remove(root) }

        let outcome = try await FileSystemCodeAnalyzer().analyzeWithCoverage(root: root, options: .default)
        let limits = outcome.metrics.scanLimitations ?? []
        let text = limits.joined(separator: "\n")
        // 三个数字是我逐份夹具数出来的，不是从实现输出反抄的：
        //   接口无体 = UserRepository 的 `List<User> findByTenant(String tenant);` + `void purge(String tenant);`
        //   裸签名   = Lane 的 `Lane(int limit) {`（`DOMESTIC(40), CROSS(120);` 不是声明，不许被数进来）
        //   lambda/匿名 = ReportingJob 的 `new ClickHandler() {` + `() -> {`
        XCTAssertTrue(limits.contains { $0.contains("Java") && $0.contains("2 处接口") },
                      "接口无体声明计数不对：\(text)")
        XCTAssertTrue(limits.contains { $0.contains("Java") && $0.contains("1 处「名字+参数表+{」") },
                      "裸签名计数不对：\(text)")
        XCTAssertTrue(limits.contains { $0.contains("Java") && $0.contains("2 处 lambda") },
                      "lambda / 匿名类体计数不对：\(text)")
        XCTAssertFalse(text.contains("没有复杂函数"), "限制通道不许写成「没有问题」：\(text)")
        // 分母守卫：这四份 Java 必须真的进了扫描面，否则上面三条是空转出来的永真绿。
        XCTAssertEqual(outcome.metrics.totalFiles, 4, "夹具四份文件必须都扫到：\(outcome.metrics.totalFiles)")
    }

    /// 反向判据：一个未覆盖形状都没有时，Java 限制条必须缺席（不是写成空串占位）。
    func testFullyCoveredJavaFileAddsNoLimitationNote() async throws {
        let root = try JavaTruth.writeTemp([
            ("src/Plain.java", JavaRecognitionTruthTests.plainMethodsOnly),
        ])
        defer { try? JavaTruth.remove(root) }
        let outcome = try await FileSystemCodeAnalyzer().analyzeWithCoverage(root: root, options: .default)
        let javaNotes = (outcome.metrics.scanLimitations ?? []).filter { $0.contains("Java") }
        XCTAssertTrue(javaNotes.isEmpty, "没遇到未覆盖形状却挂出 Java 提示条：\(javaNotes)")
    }

    /// 端到端读数：伪函数不在榜、真方法在榜且行数对（同一份夹具，两侧一起量）。
    func testReportedHotspotsCarryRealMethodsNotAnnotationArtifacts() async throws {
        let root = try JavaTruth.writeTemp([
            ("src/OrderServiceTest.java", JavaRecognitionTruthTests.mockitoAnnotationClass),
        ])
        defer { try? JavaTruth.remove(root) }
        let outcome = try await FileSystemCodeAnalyzer().analyzeWithCoverage(root: root, options: .default)
        let hotspots = outcome.metrics.topComplexFunctions
        XCTAssertEqual(Set(hotspots.map(\.name)), ["setUp", "rejectsEmptyCart"],
                       "榜单成员不对：\(hotspots.map { "\($0.name):\($0.startLine)" })")
        let rejects = hotspots.first { $0.name == "rejectsEmptyCart" }
        XCTAssertNotNil(rejects, "真方法没进榜：\(hotspots.map(\.name))")
        XCTAssertEqual(rejects?.startLine, 19, "起始行必须绑到签名自己那一行")
        XCTAssertEqual(rejects?.lineCount, 5, "边界必须止于该方法自己的 }，19…23")
        XCTAssertEqual(rejects?.cyclomaticComplexity, 2, "一个 if → CC=2")
    }
}

// MARK: - 这一组额外用的夹具

extension JavaRecognitionTruthTests {

    /// 只含「有返回类型 + 有方法体」的普通方法：三类未覆盖形状一个都没有。
    static let plainMethodsOnly = """
    public class Plain {

        public int add(int a, int b) { // R1!add
            return a + b;
        } // R1/add

        private void clear() { // R1!clear
            size = 0;
        } // R1/clear
    }
    """

    /// 枚举里的包级构造器：`Lane(int limit)` 名字前既无修饰符也无返回类型，
    /// 与一条裸调用行 `foo(bar) {` 在轻量正则下**形状相同**，本轮不补（必须出声）。
    static let enumWithBareConstructor = """
    public enum Lane {

        DOMESTIC(40), CROSS(120);

        private final int limit;

        Lane(int limit) { // R1!Lane
            this.limit = limit;
        } // R1/Lane

        public int limit() { // R1!limit
            return limit;
        } // R1/limit
    }
    """
}
