//
// 崩溃报告的取值工具层：.ips 的 JSON 安全取值、帧与时间解析、字符串裁剪与归一化。
// 这一层的纪律是「任何一步取不到就返回 nil / 空」，绝不让解析器因为字段缺失而崩。
// 从 CrashReportParser.swift 拆出，语义不变。
//
import Foundation

// MARK: - 内部：安全取值工具

extension CrashReportParser {
    static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), !data.isEmpty else { return nil }
        let bytes = data.count > maxReadBytes ? Data(data.prefix(maxReadBytes)) : data
        if let text = String(data: bytes, encoding: .utf8) { return text }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }

    static func emptyToNil(_ text: String) -> String? {
        text.isEmpty ? nil : text
    }

    /// 把栈帧压成看得懂的符号名：`_platform_strlen in libsystem_platform.dylib` → `_platform_strlen`，
    /// `foo() + 128 (Bar.swift:210)` → `foo() (Bar.swift:210)`。
    static func humanize(_ frame: String) -> String {
        if let range = frame.range(of: " in ") {
            let symbol = String(frame[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !symbol.isEmpty { return symbol }
        }
        var text = frame
        if let plus = text.range(of: " + 0x", options: .backwards) ?? text.range(of: " + ", options: .backwards) {
            text.replaceSubrange(plus.lowerBound..<plus.upperBound, with: "")
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// 与文本日志同一条归一化通道（去 uuid / 地址 / 绝对路径 / 数字噪声）。
    static func normalize(_ text: String) -> String {
        let cleaned = LogLineParser.normalizeMessage(text)
        return clip(trimmed(cleaned.replacingOccurrences(of: "\u{0000}", with: " ")), 900)
    }

    static func firstNonEmpty(_ values: [String?]) -> String? {
        for value in values.compactMap({ $0 }) where !trimmed(value).isEmpty { return value }
        return nil
    }

    static func indexed(_ values: [[String: Any]], _ index: Int?) -> [String: Any]? {
        guard let index, index >= 0, index < values.count else { return nil }
        return dictionary(values[index])
    }

    static func startsWithBrace(_ text: String) -> Bool {
        for character in text where !character.isNewline && character != " " && character != "\t" && character != "\u{FEFF}" {
            return character == "{"
        }
        return false
    }

    static func jsonDictionary(_ text: String) -> [String: Any]? {
        let body = trimmed(text)
        guard body.hasPrefix("{"), body.count > 2 else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: Data(body.utf8), options: []),
           let dictionary = object as? [String: Any] {
            return dictionary
        }
        // 尾部可能有杂散内容：退到最后一个 `}` 再试一次。
        if let opening = body.firstIndex(of: "{"), let closing = body.lastIndex(of: "}"), opening < closing {
            let slice = String(body[opening...closing])
            if let object = try? JSONSerialization.jsonObject(with: Data(slice.utf8), options: []),
               let dictionary = object as? [String: Any] {
                return dictionary
            }
        }
        return nil
    }

    static func dictionary(_ value: Any?) -> [String: Any]? { value as? [String: Any] }
    static func array(_ value: Any?) -> [Any]? { value as? [Any] }

    static func arrayOfDictionaries(_ value: Any?) -> [[String: Any]] {
        guard let list = value as? [Any] else { return [] }
        return list.compactMap { dictionary($0) }
    }

    /// 字符串 / NSNumber 都能读成字符串，读不到返回 nil。
    static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text.isEmpty ? nil : text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(trimmed(text)) }
        return nil
    }

    static func boolValue(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String {
            let lower = trimmed(text).lowercased()
            return lower == "true" || lower == "yes" || lower == "1"
        }
        return false
    }

    /// codes 可能是字符串、数字数组，也可能是小字典。
    static func stringOrJoined(_ value: Any?) -> String? {
        if let text = value as? String { return text.isEmpty ? nil : text }
        if let number = value as? NSNumber { return number.stringValue }
        if let list = value as? [Any] {
            let parts = list.compactMap { element -> String? in
                if let text = element as? String { return text.isEmpty ? nil : text }
                if let number = element as? NSNumber { return number.stringValue }
                if let nested = element as? [Any] {
                    let flat = nested.compactMap { string($0) }
                    return flat.isEmpty ? nil : flat.joined(separator: ", ")
                }
                if let table = element as? [String: Any] { return stringOrJoined(table) }
                return nil
            }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }
        if let table = value as? [String: Any] {
            let parts = table.keys.sorted().prefix(8).compactMap { key -> String? in
                guard let value = stringOrJoined(table[key]), !value.isEmpty else { return nil }
                return "\(key)=\(value)"
            }
            return parts.isEmpty ? nil : Array(parts).joined(separator: ", ")
        }
        return nil
    }

    /// `asi` 的每个 section 形如 `[[key, [values]], …]`，平摊成 `key = v1, v2`。
    static func flattenASI(_ asi: [String: Any]?) -> [String] {
        guard let asi, !asi.isEmpty else { return [] }
        let preferred = ["Backtrace", "Diagnose"]
        let ordered = preferred.filter { asi[$0] != nil } + asi.keys.filter { !preferred.contains($0) }.sorted()
        var result: [String] = []
        for section in ordered {
            guard let entries = array(asi[section]) else { continue }
            for entry in entries {
                if result.count >= 6 { break }
                if let pair = array(entry), let key = string(pair.first), pair.count >= 2 {
                    let values = array(pair[1])?.compactMap { string($0) } ?? []
                    let joined = values.isEmpty ? (stringOrJoined(pair[1]) ?? "") : values.joined(separator: ", ")
                    guard !joined.isEmpty else { continue }
                    result.append(normalize("\(key) = \(joined)"))
                } else if let table = dictionary(entry) {
                    for key in table.keys.sorted() {
                        guard result.count < 6, let value = stringOrJoined(table[key]), !value.isEmpty else { continue }
                        result.append(normalize("\(key) = \(value)"))
                    }
                }
            }
            if result.count >= 6 { break }
        }
        return Array(result.prefix(6))
    }

    /// usedImages 顺序表：frame 只带 imageIndex 时用它补镜像名。
    static func usedImageNames(_ value: Any?) -> [String] {
        arrayOfDictionaries(value).map { image in
            firstNonEmpty([
                string(image["name"]),
                string(image["path"]).map { ($0 as NSString).lastPathComponent },
            ]) ?? ""
        }
    }

    /// 一帧 .ips frame -> `symbol (File.swift:123)`；无 symbol 时 `frame <idx> in <imageName>`。
    static func ipsFrame(_ raw: Any?, index: Int, imageNames: [String]) -> (frame: String, file: String?)? {
        if let text = string(raw) {
            let plain = clip(trimmed(text), 300)
            return plain.isEmpty ? nil : (plain, nil)
        }
        guard let frame = dictionary(raw) else { return nil }
        let symbol = firstNonEmpty([string(frame["symbol"]), string(frame["symbolLocation"])])
        let source = dictionary(frame["sourceLineInfo"])
        let filePath = firstNonEmpty([string(source?["file"]), string(source?["filePath"])])
        let lineNumber = int(source?["line"]) ?? int(source?["lineNumber"])
        let imageIndex = int(frame["imageIndex"]) ?? int(frame["image_index"])
        let imageName = firstNonEmpty([
            string(frame["binary_name"]),
            string(frame["imageName"]),
            imageIndex.flatMap { position in position >= 0 && position < imageNames.count ? imageNames[position] : nil },
        ])
        let offset = int(frame["image_offset"]) ?? int(frame["imageOffset"])

        let file = filePath.map { trimmed(($0 as NSString).lastPathComponent) }
        let fileName = (file?.isEmpty == false) ? file : nil

        var text: String
        if let symbol {
            text = clip(symbol, 160)
            if let fileName {
                text += lineNumber.map { " (\(fileName):\($0))" } ?? " (\(fileName))"
            } else if let imageName {
                text += " in \(imageName)"
            }
        } else {
            text = "frame \(index)"
            if let imageName { text += " in \(imageName)" }
            if let offset { text += " + 0x" + String(max(0, offset), radix: 16) }
        }
        let built = clip(trimmed(text), 300)
        guard !built.isEmpty else { return nil }
        return (built, fileName)
    }

    /// date 优先 body 的 timestamp，回落到 header 的 timestamp/reporting_time，再回落 modifiedAt。
    static func ipsDate(body: [String: Any], header: [String: Any], path: String, modifiedAt: Date) -> Date {
        let candidates = [
            string(body["timestamp"]),
            string(body["incident_timestamp"]),
            string(header["timestamp"]),
            string(header["reporting_time"]),
            string(header["utc_time"]),
            string(header["incident_identifier"]),
        ]
        for candidate in candidates.compactMap({ $0 }) {
            if let parsed = date(from: candidate, referenceDate: modifiedAt) { return parsed }
        }
        if let fromName = dateFromFileName(path) { return fromName }
        return modifiedAt
    }

    static func date(from text: String, referenceDate: Date) -> Date? {
        let value = trimmed(text)
        guard value.count >= 8 else { return nil }
        guard value.contains("-") || value.contains("/") else {
            return LogLineParser.parseTimestamp(value, referenceDate: referenceDate)
        }
        if let iso = iso8601(value) { return iso }
        for format in [
            "yyyy-MM-dd HH:mm:ss.SS ZZZZ",
            "yyyy-MM-dd HH:mm:ss ZZZZ",
            "yyyy-MM-dd HH:mm:ss.SSSXXXXX",
            "yyyy-MM-dd HH:mm:ss.SS",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd",
        ] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.isLenient = true
            formatter.dateFormat = format
            if let parsed = formatter.date(from: value) { return parsed }
        }
        return LogLineParser.parseTimestamp(value, referenceDate: referenceDate)
    }

    static func iso8601(_ text: String) -> Date? {
        let withFractions = ISO8601DateFormatter()
        withFractions.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = withFractions.date(from: text) { return parsed }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    /// `TcoderMonitor-2026-09-18-132231.ips` 这类文件名里带的时间（报告头缺失时用）。
    static func dateFromFileName(_ path: String) -> Date? {
        guard let groups = fileNameDatePattern.groups(in: (path as NSString).lastPathComponent),
              groups.count >= 5,
              let year = Int(groups[1] ?? ""),
              let month = Int(groups[2] ?? ""),
              let day = Int(groups[3] ?? ""),
              let hour = Int(groups[4] ?? ""),
              year > 1970, (1...12).contains(month), (1...31).contains(day), (0...23).contains(hour)
        else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = groups.count > 5 ? (Int(groups[5] ?? "") ?? 0) : 0
        components.second = groups.count > 6 ? (Int(groups[6] ?? "") ?? 0) : 0
        components.timeZone = TimeZone.current
        return Calendar.current.date(from: components)
    }
}
