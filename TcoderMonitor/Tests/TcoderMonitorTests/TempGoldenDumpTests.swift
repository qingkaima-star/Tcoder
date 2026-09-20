import XCTest
@testable import TcoderMonitor

/// 一次性取证：把 `VulnerabilitySource` 的全部对外输出逐字打出来，
/// 供重构前后 diff。用完即删，不进交付。
final class TempGoldenDumpTests: XCTestCase {

    private func rec(_ ecosystem: DependencyEcosystem, _ name: String, _ version: String) -> DependencyRecord {
        DependencyRecord(name: name, version: version, ecosystem: ecosystem, scope: .runtime,
                         manifestPath: "m", latestKnownVersion: nil,
                         versionCheckSource: .none, knownVulnerabilities: [])
    }

    func testDump() throws {
        var out = "GOLDEN-START\n"
        for rule in VulnerabilitySource.bundled {
            out += [
                rule.id, rule.ecosystem.rawValue, rule.package, rule.affectedBelow,
                rule.introducedIn ?? "<nil>", rule.fixedVersion ?? "<nil>",
                rule.severity.rawValue, rule.cveIdentifiers.joined(separator: "|"),
                rule.summary, rule.details, rule.source, rule.vulnerableRange,
            ].joined(separator: "\u{1}") + "\n"
        }
        out += "AFFECTS\n"
        let probes = ["", " ", "1.0.0", "4.17.20", "4.17.21", "4.17.22", "v1.2.82", "^2.16.0",
                      ">= 2.0.0", "未声明", "*", "latest", "2.31.0-SNAPSHOT", "0.9.1"]
        for rule in VulnerabilitySource.bundled {
            for probe in probes {
                out += "\(rule.id)|\(probe)|\(rule.affects(version: probe))\n"
            }
        }
        let deps: [DependencyRecord] = [
            rec(.npm, "lodash", "4.17.20"),
            rec(.npm, "lodash", "4.17.21"),
            rec(.maven, "org.apache.logging.log4j:log4j-core", "2.14.1"),
            rec(.python, "requests", "2.31.0"),
            rec(.python, "urllib3", "1.26.17"),
            rec(.maven, "com.alibaba:fastjson", "1.2.80"),
            rec(.maven, "unknown:thing", "1.0.0"),
            rec(.npm, "axios", "0.21.1"),
            rec(.maven, "commons-collections:commons-collections", "3.2.1"),
            rec(.maven, "io.jsonwebtoken:jjwt", "0.9.1"),
            rec(.maven, "com.fasterxml.jackson.core:jackson-databind", "2.13.3"),
            rec(.python, "django", "4.2.5"),
            rec(.python, "django", "4.2.6"),
            rec(.npm, "lodash", "未声明"),
        ]
        out += "OFFLINE\n"
        for v in VulnerabilitySource.offlineVulnerabilities(for: deps) {
            out += [v.id, v.package, v.ecosystem.rawValue, v.vulnerableRange,
                    v.fixedVersion ?? "<nil>", v.summary, v.severity.rawValue,
                    v.cveIdentifiers.joined(separator: "|"),
                    v.affectedDependencies.joined(separator: "|")].joined(separator: "\u{1}") + "\n"
        }
        out += "ADVISORIES\n"
        for a in VulnerabilitySource.bundledAdvisories(for: deps) {
            out += [a.id, a.aliases.joined(separator: "|"), a.summary, a.details,
                    a.severity.rawValue, a.affectedPackages.joined(separator: "|"),
                    a.ecosystem.rawValue, a.source, String(describing: a.cvssScore),
                    String(describing: a.publishedAt)].joined(separator: "\u{1}") + "\n"
        }
        out += "COVERED\n"
        for dep in deps {
            out += "\(dep.name)|\(dep.version)|\(VulnerabilitySource.coveredIdentifiers(ecosystem: dep.ecosystem, name: dep.name, version: dep.version).sorted().joined(separator: "|"))\n"
        }
        out += "GOLDEN-END"
        try out.write(toFile: "/tmp/x2-vuln-golden.txt", atomically: true, encoding: .utf8)
        print("【golden】\(out.count) 字符 → /tmp/x2-vuln-golden.txt")
    }
}
