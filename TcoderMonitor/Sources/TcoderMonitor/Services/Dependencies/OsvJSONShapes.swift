// OSV / npm registry 响应的 JSON 形状（WS-B · 依赖安全四层里的第 3 层）
//
// 从 OsvClient.swift 拆出，只为守住本轮的文件规模线（单文件 ≤ 400 行）。
// 字段名、CodingKeys、可选性一条未改 —— 它们与 api.osv.dev / registry.npmjs.org
// 的实测响应对齐，动一个键名就会让整条在线漏洞结果静默解不出来。
import Foundation

extension DependencyNetworkLookup {
    // MARK: - JSON shapes（字段路径与 api.osv.dev / registry.npmjs.org 实测响应对齐）
    struct OsvEcosystemPackage: Codable {
        let name: String
        let ecosystem: String
    }

    struct OsvQueryPayload: Encodable {
        let package: OsvEcosystemPackage
        let version: String
    }

    struct OsvBatchPayload: Encodable {
        let queries: [OsvQueryPayload]
    }

    struct OsvBatchResponse: Decodable {
        let results: [OsvBatchResult]?
    }

    struct OsvBatchResult: Decodable {
        let vulns: [OsvBriefVuln]?
    }

    struct OsvBriefVuln: Decodable {
        let id: String
        let aliases: [String]?
        let modified: String?
    }

    struct OsvQueryResponse: Decodable {
        let vulns: [OsvVuln]?
    }

    struct OsvVuln: Decodable {
        let id: String
        let aliases: [String]?
        let summary: String?
        let details: String?
        let published: String?
        let modified: String?
        let severity: [OsvSeverityEntry]?
        let databaseSpecific: OsvDatabaseSpecific?
        let affected: [OsvAffected]?

        enum CodingKeys: String, CodingKey {
            case id, aliases, summary, details, published, modified, severity, affected
            case databaseSpecific = "database_specific"
        }
    }

    /// 实测：`severity: [{"type":"CVSS_V3","score":"CVSS:3.1/AV:N/…"}]`，score 多为向量串而非数字。
    struct OsvSeverityEntry: Decodable {
        let type: String?
        let score: String?
    }

    /// 实测：`database_specific.severity` 为 "CRITICAL" / "HIGH" / "MODERATE" / "LOW"。
    struct OsvDatabaseSpecific: Decodable {
        let severity: String?
    }

    struct OsvAffected: Decodable {
        let package: OsvAffectedPackage?
        let ranges: [OsvRange]?
        let versions: [String]?
    }

    /// 解码时全部字段可选，避免个别记录字段缺失导致整条 OSV 记录解析失败。
    struct OsvAffectedPackage: Decodable {
        let name: String?
        let ecosystem: String?
    }

    struct OsvRange: Decodable {
        let type: String?
        let events: [OsvEvent]?
    }

    struct OsvEvent: Decodable {
        let introduced: String?
        let fixed: String?
        let lastAffected: String?

        enum CodingKeys: String, CodingKey {
            case introduced, fixed
            case lastAffected = "last_affected"
        }
    }
}
