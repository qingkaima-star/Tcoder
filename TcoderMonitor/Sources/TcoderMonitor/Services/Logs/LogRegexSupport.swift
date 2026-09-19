//
// 正则缓存与日期格式器缓存（WS-C 日志层共享底座）
//
// 从 LogParsing.swift 拆出：只为控制单文件长度，语义与拆分前完全一致。
//
import Foundation

// MARK: - 正则缓存

// MARK: - 正则缓存

/// NSRegularExpression 只编译一次：日志按行解析是热路径，逐行编译会慢一个数量级。
final class RX {
    let regex: NSRegularExpression?

    init(_ pattern: String, options: NSRegularExpression.Options = []) {
        regex = try? NSRegularExpression(pattern: pattern, options: options)
    }

    func first(in text: String, from location: Int = 0) -> NSTextCheckingResult? {
        guard let regex else { return nil }
        let ns = text as NSString
        let start = max(0, min(location, ns.length))
        guard start < ns.length else { return nil }
        return regex.firstMatch(in: text, options: [], range: NSRange(location: start, length: ns.length - start))
    }

    func replaces(_ text: String, with template: String) -> String {
        guard let regex else { return text }
        let ns = text as NSString
        guard ns.length > 0 else { return text }
        return regex.stringByReplacingMatches(in: text, options: [],
                                              range: NSRange(location: 0, length: ns.length),
                                              withTemplate: template)
    }
}

func rxGroup(_ result: NSTextCheckingResult, _ index: Int, in text: String) -> String? {
    guard index < result.numberOfRanges else { return nil }
    let range = result.range(at: index)
    guard range.location != NSNotFound else { return nil }
    let ns = text as NSString
    guard NSMaxRange(range) <= ns.length else { return nil }
    let value = ns.substring(with: range)
    return value.isEmpty ? nil : value
}

/// 时间戳解析用的格式器全部 static 缓存；主路径走分组组装 DateComponents，格式化器只做兜底。
enum LogDateFormat {
    static let isoWithZone = makeISO(options: [.withInternetDateTime])
    static let isoWithZoneAndFraction = makeISO(options: [.withInternetDateTime, .withFractionalSeconds])

    static let dateOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }()

    static func isoDate(_ text: String) -> Date? {
        if let date = isoWithZoneAndFraction.date(from: text) { return date }
        if let date = isoWithZone.date(from: text) { return date }
        return nil
    }

    private static func makeISO(options: ISO8601DateFormatter.Options) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = options
        return formatter
    }
}
