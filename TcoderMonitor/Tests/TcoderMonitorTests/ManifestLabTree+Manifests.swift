import Foundation
@testable import TcoderMonitor

// WS-F 夹具树正文段：清单类（npm / Maven / Gradle / SwiftPM）。
// 逐行原样搬自 ManifestLabFixtureTests.swift 的 build(at:)，只加了同签名的函数外壳，
// 正文与多行字符串的缩进未动（WS-V 机械拆分）。
extension LabTree {
    static func writeManifestsNpm(put: (String, String) throws -> Void,
                                  putLines: (String, [String]) throws -> Void) throws {

        // MARK: npm

        try put("package.json", #"""
        {
          "name": "acme-orders-lab",
          "version": "1.0.0",
          "private": true,
          "scripts": {
            "build": "tsc -p .",
            "test": "vitest run"
          },
          "dependencies": {
            "react": "^18.2.0",
            "react-dom": "^18.2.0",
            "lodash": "4.17.20",
            "axios": "0.21.1",
            "express": "^5.2.1"
          },
          "devDependencies": {
            "typescript": "^5.3.3",
            "vitest": "1.2.2",
            "antd": "5.13.2"
          },
          "peerDependencies": {
            "moment": "2.29.4"
          },
          "optionalDependencies": {
            "@acme/experimental": "1.0.0-rc.3"
          }
        }

        """#)

        try put("package-lock.json", #"""
        {
          "name": "acme-orders-lab",
          "lockfileVersion": 3,
          "packages": {}
        }

        """#)

        try put("frontend/package.json", #"""
        {
          "name": "acme-orders-console",
          "version": "0.4.0",
          "dependencies": {
            "vue": "3.4.0",
            "pinia": "2.1.7"
          },
          "devDependencies": {
            "vite": "5.0.0"
          }
        }

        """#)

        try putLines("frontend/src/checkout.ts", [
            "import lodash from 'lodash';",
            "",
            "export interface CheckoutDraft {",
            "  orderId: string;",
            "  lane: string;",
            "}",
            "",
            "export function summarize(drafts: CheckoutDraft[]): string {",
            "  const grouped = lodash.groupBy(drafts, (draft) => draft.lane);",
            "  return Object.keys(grouped)",
            "    .map((lane) => lane + ':' + grouped[lane].length)",
            "    .join(' ');",
            "}",
            "",
        ])


    }

    static func writeManifestsMaven(put: (String, String) throws -> Void,
                                  putLines: (String, [String]) throws -> Void) throws {

        // MARK: Maven（根聚合 + 两个模块，模块放在 java/ 下以便做深度实验）

        try put("pom.xml", #"""
        <?xml version="1.0" encoding="UTF-8"?>
        <project xmlns="http://maven.apache.org/POM/4.0.0"
                 xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
                 xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
          <modelVersion>4.0.0</modelVersion>
          <groupId>com.acme.orders</groupId>
          <artifactId>acme-orders-parent</artifactId>
          <version>2.7.0</version>
          <packaging>pom</packaging>

          <properties>
            <acme.shared.version>1.4.2</acme.shared.version>
            <spring.boot.version>3.2.0</spring.boot.version>
          </properties>

          <modules>
            <module>java/orders-api</module>
            <module>java/orders-service</module>
          </modules>

          <dependencyManagement>
            <dependencies>
              <dependency>
                <groupId>com.acme.orders</groupId>
                <artifactId>orders-api</artifactId>
                <version>${project.version}</version>
              </dependency>
            </dependencies>
          </dependencyManagement>

          <dependencies>
            <dependency>
              <groupId>com.acme</groupId>
              <artifactId>acme-shared</artifactId>
              <version>${acme.shared.version}</version>
            </dependency>
            <dependency>
              <groupId>org.springframework.boot</groupId>
              <artifactId>spring-boot-starter</artifactId>
              <version>${spring.boot.version}</version>
            </dependency>
            <dependency>
              <groupId>com.acme.orders</groupId>
              <artifactId>orders-api</artifactId>
            </dependency>
          </dependencies>
        </project>

        """#)

        try put("java/orders-api/pom.xml", #"""
        <?xml version="1.0" encoding="UTF-8"?>
        <project xmlns="http://maven.apache.org/POM/4.0.0">
          <parent>
            <groupId>com.acme.orders</groupId>
            <artifactId>acme-orders-parent</artifactId>
            <version>2.7.0</version>
          </parent>
          <modelVersion>4.0.0</modelVersion>
          <artifactId>orders-api</artifactId>

          <dependencyManagement>
            <dependencies>
              <dependency>
                <groupId>com.fasterxml.jackson.core</groupId>
                <artifactId>jackson-databind</artifactId>
                <version>2.13.2</version>
              </dependency>
            </dependencies>
          </dependencyManagement>

          <dependencies>
            <dependency>
              <groupId>com.fasterxml.jackson.core</groupId>
              <artifactId>jackson-databind</artifactId>
            </dependency>
            <dependency>
              <groupId>org.projectlombok</groupId>
              <artifactId>lombok</artifactId>
              <version>1.18.30</version>
              <scope>provided</scope>
            </dependency>
            <dependency>
              <groupId>io.jsonwebtoken</groupId>
              <artifactId>jjwt</artifactId>
              <version>0.9.1</version>
            </dependency>
          </dependencies>
        </project>

        """#)

        try put("java/orders-service/pom.xml", #"""
        <?xml version="1.0" encoding="UTF-8"?>
        <project xmlns="http://maven.apache.org/POM/4.0.0">
          <parent>
            <groupId>com.acme.orders</groupId>
            <artifactId>acme-orders-parent</artifactId>
            <version>2.7.0</version>
          </parent>
          <modelVersion>4.0.0</modelVersion>
          <artifactId>orders-service</artifactId>

          <dependencies>
            <dependency>
              <groupId>org.apache.logging.log4j</groupId>
              <artifactId>log4j-core</artifactId>
              <version>2.14.1</version>
            </dependency>
            <dependency>
              <groupId>commons-collections</groupId>
              <artifactId>commons-collections</artifactId>
              <version>3.2.1</version>
            </dependency>
            <dependency>
              <groupId>junit</groupId>
              <artifactId>junit</artifactId>
              <version>4.13.2</version>
              <scope>test</scope>
            </dependency>
            <dependency>
              <groupId>org.acme.legacy</groupId>
              <artifactId>legacy-range-client</artifactId>
              <version>[1.0,2.0)</version>
            </dependency>
          </dependencies>

          <build>
            <plugins>
              <plugin>
                <groupId>org.apache.maven.plugins</groupId>
                <artifactId>maven-compiler-plugin</artifactId>
                <version>3.11.0</version>
                <dependencies>
                  <dependency>
                    <groupId>org.ow2.asm</groupId>
                    <artifactId>asm</artifactId>
                    <version>9.6</version>
                  </dependency>
                </dependencies>
              </plugin>
            </plugins>
          </build>
        </project>

        """#)


    }

    static func writeManifestsGradle(put: (String, String) throws -> Void,
                                  putLines: (String, [String]) throws -> Void) throws {

        // MARK: Gradle

        try put("build.gradle", #"""
        // Every Gradle shape the analyzer claims to read appears exactly once here.
        plugins {
            id 'java-library'
            id 'org.springframework.boot' version '3.2.0'
        }

        // implementation 'com.example.never:should-not-parse:9.9.9'
        dependencies {
            implementation 'com.squareup.okhttp3:okhttp:4.9.0'
            implementation 'org.apache.commons:commons-lang3:[3.8,4.0)'
            api 'io.grpc:grpc-netty-shaded:1.60.0'
            compileOnly 'org.projectlombok:lombok:1.18.30'
            annotationProcessor 'org.projectlombok:lombok:1.18.30'
            testImplementation 'junit:junit:4.13.2'
            implementation group: 'com.google.code.gson', name: 'gson', version: '2.10.1'
        }

        """#)

        try put("build.gradle.kts", #"""
        plugins {
            kotlin("jvm") version "1.9.22"
            id("com.diffplug.spotless") version "6.23.3"
        }

        dependencies {
            implementation(platform("org.springframework.boot:spring-boot-dependencies:3.2.0"))
            implementation("com.google.guava:guava:33.0.0-jre")
            testImplementation("org.mockito:mockito-core:5.2.0")
            runtimeOnly("com.mysql:mysql-connector-j:8.2.0")
        }

        """#)

        try put("settings.gradle", #"""
        rootProject.name = 'acme-orders-lab'

        dependencyResolutionManagement {
            versionCatalogs {
                create("libs") {
                    library('acme-shared', 'com.acme:acme-shared:1.4.2')
                    library('jwt', 'io.jsonwebtoken:jjwt:0.9.1')
                }
            }
        }

        """#)


    }

    static func writeManifestsSwiftPM(put: (String, String) throws -> Void,
                                  putLines: (String, [String]) throws -> Void) throws {

        // MARK: SwiftPM

        try put("Package.swift", #"""
        // swift-tools-version:5.9
        import PackageDescription

        let labPackage = Package(
            name: "ACMEOrdersLab",
            platforms: [.macOS(.v14)],
            dependencies: [
                .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
                .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.23.0"),
                .package(url: "https://github.com/onevcat/Kingfisher.git", exact: "7.10.0"),
                .package(url: "https://github.com/acme/design-system", .branch("main")),
                .package(url: "https://github.com/acme/palette", branch: "stable"),
                .package(path: "../acme-local-kit"),
            ],
            targets: [
                .target(
                    name: "ACMEOrders",
                    dependencies: [.product(name: "Logging", package: "swift-log")]
                )
            ]
        )

        """#)

        try put("Package.resolved", #"""
        {
          "pins": [
            {
              "identity": "swift-log",
              "kind": "remoteSourceControl",
              "location": "https://github.com/apple/swift-log.git",
              "state": {"revision": "9dfddc163f5ca31d86066e6e673e694fde88d6c6", "version": "1.6.1"}
            }
          ],
          "version": 2
        }

        """#)

        try putLines("Sources/ACMEOrders/OrderBook.swift", [
            "import Logging",
            "",
            "/// Keeps the in-memory view of one lab order.",
            "public struct OrderBook {",
            "    public var lane: String",
            "    public var attempts: Int",
            "",
            "    public init(lane: String, attempts: Int = 0) {",
            "        self.lane = lane",
            "        self.attempts = attempts",
            "    }",
            "",
            "    public func describe(using logger: Logger) -> String {",
            "        logger.info(\"order book lane received\")",
            "        return lane + \":\" + String(attempts)",
            "    }",
            "}",
            "",
        ])

    }
}
