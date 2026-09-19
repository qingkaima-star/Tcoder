import Foundation
@testable import TcoderMonitor

// WS-F 夹具树正文段：Java 源码、五种覆盖率报告、日志与杂项。
// 逐行原样搬自 ManifestLabFixtureTests.swift 的 build(at:)，只加了同签名的函数外壳，
// 正文与多行字符串的缩进未动（WS-V 机械拆分）。
extension LabTree {
    static func writeJavaSources(put: (String, String) throws -> Void,
                                  putLines: (String, [String]) throws -> Void) throws {

        // MARK: Java

        try putLines("src/main/java/com/acme/orders/OrderOrchestrator.java", orderOrchestrator())
        try putLines("src/main/java/com/acme/orders/UserService.java", userService())
        try putLines("src/main/java/com/acme/orders/PricingRules.java", clonedRules(className: "PricingRules"))
        try putLines("src/main/java/com/acme/orders/BillingRules.java", clonedRules(className: "BillingRules"))
        try putLines("src/main/java/com/acme/orders/Order.java", orderModel())


    }

    static func writeCoverageReports(put: (String, String) throws -> Void,
                                  putLines: (String, [String]) throws -> Void) throws {

        // MARK: 覆盖率产物（五种格式，数字写死）

        try put("frontend/coverage/unit/lcov.info", #"""
        TN:acme-orders-console
        SF:/lab/frontend/src/checkout.ts
        FNF:20
        FNH:15
        BRDA:12,0,0,4
        BRF:40
        BRH:24
        DA:1,1
        DA:2,0
        LF:100
        LH:75
        end_of_record

        """#)

        try put("frontend/coverage/coverage-summary.json", #"""
        {
          "total": {
            "lines": {"total": 400, "covered": 300, "skipped": 0, "pct": 75.0},
            "branches": {"total": 120, "covered": 78, "skipped": 0, "pct": 65.0},
            "functions": {"total": 60, "covered": 45, "skipped": 0, "pct": 75.0},
            "statements": {"total": 420, "covered": 315, "skipped": 0, "pct": 75.0}
          },
          "src/checkout.ts": {
            "lines": {"total": 60, "covered": 42, "pct": 70.0}
          }
        }

        """#)

        try put("java/orders-service/target/site/jacoco/jacoco.xml", #"""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <report name="orders-service">
          <package name="com/acme/orders">
            <class name="com/acme/orders/UserService" sourcefilename="UserService.java">
              <counter type="LINE" missed="6" covered="24"/>
              <counter type="BRANCH" missed="4" covered="6"/>
              <counter type="METHOD" missed="3" covered="9"/>
            </class>
            <counter type="LINE" missed="10" covered="40"/>
            <counter type="BRANCH" missed="6" covered="14"/>
            <counter type="METHOD" missed="5" covered="16"/>
          </package>
          <package name="com/acme/orders/rules">
            <counter type="LINE" missed="20" covered="60"/>
            <counter type="BRANCH" missed="9" covered="11"/>
            <counter type="METHOD" missed="8" covered="14"/>
          </package>
          <counter type="INSTRUCTION" missed="380" covered="1620"/>
          <counter type="BRANCH" missed="20" covered="60"/>
          <counter type="LINE" missed="25" covered="175"/>
          <counter type="METHOD" missed="10" covered="40"/>
        </report>

        """#)

        try put("python-tool/coverage/coverage.xml", #"""
        <?xml version="1.0" encoding="UTF-8"?>
        <coverage line-rate="0.8" branch-rate="0.65" lines-covered="200" lines-valid="250"
                  branches-covered="52" branches-valid="80" version="7.4">
          <packages>
            <package name="src" line-rate="0.75" branch-rate="0.6" complexity="12">
              <classes>
                <class name="inventory.py" line-rate="0.75" branch-rate="0.6">
                  <lines>
                    <line number="1" hits="1"/>
                    <line number="2" hits="0"/>
                  </lines>
                </class>
              </classes>
            </package>
          </packages>
        </coverage>

        """#)

        try put("clover.xml", #"""
        <?xml version="1.0" encoding="UTF-8"?>
        <coverage generated="1700000000" clover="3.2.0">
          <project timestamp="1700000000" name="acme-orders-lab">
            <package name="AcmeOrders">
              <file name="LegacyWorker.php" path="src/LegacyWorker.php">
                <metrics statements="40" coveredstatements="28" conditionals="8" coveredconditionals="5" methods="10" coveredmethods="6"/>
              </file>
              <metrics statements="40" coveredstatements="28" conditionals="8" coveredconditionals="5" methods="10" coveredmethods="6"/>
            </package>
            <metrics statements="120" coveredstatements="90" conditionals="30" coveredconditionals="18" methods="34" coveredmethods="25"/>
          </project>
        </coverage>

        """#)


    }

    static func writeLogs(put: (String, String) throws -> Void,
                                  putLines: (String, [String]) throws -> Void) throws {

        // MARK: 日志

        try put("Logs/error.log", errorLog())
        try put("Logs/crash.log", crashLog())


    }

    static func writeMiscFiles(put: (String, String) throws -> Void,
                                  putLines: (String, [String]) throws -> Void) throws {

        // MARK: 杂项

        try put("README.md", #"""
        # ACME Orders Lab

        这是 WS-F 造的多清单夹具：同一棵树里放齐 npm、Maven 多模块、Gradle（Groovy 与
        Kotlin 两种 DSL）、SwiftPM、Go、Cargo、Python、Ruby、CocoaPods、NuGet 十种清单，
        外加五种测试覆盖率报告与两份日志。它的唯一用途是让六类分析器输出可核对的真数。

        ## 目录

        * `pom.xml` + `java/orders-api` + `java/orders-service`：Maven 聚合工程
        * `src/main/java/com/acme/orders`：超大文件、高复杂度方法、复制粘贴块
        * `Logs`：已知条数的 ERROR / WARN / 异常 / 崩溃
        * `frontend/coverage`、`python-tool/coverage`、`clover.xml`：覆盖率报告

        """#)

        try put(".gitignore", ".DS_Store\n")

    }
}
