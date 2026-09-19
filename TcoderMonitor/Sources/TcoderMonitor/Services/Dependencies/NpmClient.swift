// npm registry 客户端（WS-B · 依赖安全四层里的第 3 层）
//
// `DependencyNetworkLookup` 的 npm 侧实现：并发抓 `<pkg>/latest` 的 version 字段。
import Foundation

extension DependencyNetworkLookup {
    // MARK: - npm internals

    static func performNpmLookup(_ packages: [String], deadline: Date) async -> NpmPayload {
        var versions = [String: String](minimumCapacity: packages.count)
        var failed = 0
        var note: String?
        var index = 0
        while index < packages.count {
            guard Date() < deadline else {
                failed += packages.count - index
                appendNote(&note, "达到时间预算，剩余 \(packages.count - index) 个包未查询")
                break
            }
            let range = index..<min(index + npmConcurrency, packages.count)
            let chunk = Array(packages[range])
            index = range.upperBound
            let rows = await withTaskGroup(
                of: (name: String, version: String?).self,
                returning: [(name: String, version: String?)].self
            ) { group in
                for name in chunk {
                    group.addTask { (name, await self.fetchNpmLatest(name, deadline: deadline)) }
                }
                var acc: [(name: String, version: String?)] = []
                for await row in group { acc.append(row) }
                return acc
            }
            for row in rows {
                if let version = row.version {
                    versions[row.name] = version
                } else {
                    failed += 1
                }
            }
            failed += max(0, chunk.count - rows.count)
        }
        if versions.isEmpty && !packages.isEmpty {
            appendNote(&note, "npm registry 全部 \(packages.count) 个请求失败（可能无网络或包名不存在）")
        }
        return NpmPayload(versions: versions, failedRequests: failed, note: note)
    }

    static func fetchNpmLatest(_ name: String, deadline: Date) async -> String? {
        guard let encoded = npmPathEncoded(name),
              let url = npmURL(encoded) else { return nil }
        guard let (data, response) = try? await session.data(for: makeRequest(url: url, deadline: deadline)),
              isOK(response) else { return nil }
        guard let decoded = try? jsonDecoder.decode(NpmLatestManifest.self, from: data),
              let version = decoded.version?.trimmingCharacters(in: .whitespacesAndNewlines),
              !version.isEmpty else { return nil }
        return version
    }

    /// 实测：registry 的 `<pkg>/latest` 直接返回该版本 manifest，`version` 在顶层。
    struct NpmLatestManifest: Decodable {
        let name: String?
        let version: String?
    }
}
