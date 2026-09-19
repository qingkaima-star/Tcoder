//
// 时间戳解析：ISO / 空格 / log4j 逗号毫秒 / syslog（无年份回退上一年）/ epoch
//
// 从 LogParsing.swift 拆出：只为控制单文件长度，语义与拆分前完全一致。
//
import Foundation

extension LogLineParser {
    // MARK: 时间戳

    /// 先在行首 80 字符内试固定格式（前缀优先），再退回全串扫描。
    static func parseTimestamp(_ text: String, referenceDate: Date) -> Date? {
        let nsLength = (text as NSString).length
        let prefixLimit = min(nsLength, 80)
        if let date = timestamp(in: text, prefixLimit: prefixLimit, referenceDate: referenceDate) { return date }
        if let date = timestamp(in: text, prefixLimit: nil, referenceDate: referenceDate) { return date }
        return formatterFallback(in: text, prefixLimit: prefixLimit)
    }

    static func timestamp(in text: String, prefixLimit: Int?, referenceDate: Date) -> Date? {
        if let date = isoStyleDate(in: text, prefixLimit: prefixLimit) { return date }
        if let date = syslogDate(in: text, prefixLimit: prefixLimit, referenceDate: referenceDate) { return date }
        if let date = epochDate(in: text, prefixLimit: prefixLimit) { return date }
        return plainDateOnly(in: text, prefixLimit: prefixLimit)
    }

    /// groups: 1年 2月 3日 4时 5分 6秒 7小数秒 8时区
    static func isoStyleDate(in text: String, prefixLimit: Int?) -> Date? {
        guard let result = stamp.first(in: text), withinPrefix(result.range.location, prefixLimit) else { return nil }
        guard
            let year = Int(rxGroup(result, 1, in: text) ?? ""),
            let month = Int(rxGroup(result, 2, in: text) ?? ""),
            let day = Int(rxGroup(result, 3, in: text) ?? ""),
            let hour = Int(rxGroup(result, 4, in: text) ?? ""),
            let minute = Int(rxGroup(result, 5, in: text) ?? ""),
            let second = Int(rxGroup(result, 6, in: text) ?? "")
        else { return nil }

        let nanosecond = nanoseconds(from: rxGroup(result, 7, in: text))
        let zone: TimeZone?
        if let token = rxGroup(result, 8, in: text) {
            zone = timeZone(for: token)
        } else {
            zone = TimeZone.current
        }
        return date(year: year, month: month, day: day, hour: hour, minute: minute,
                    second: second, nanosecond: nanosecond, timeZone: zone)
    }

    /// groups: 1月名 2日 3时 4分 5秒 6小数秒
    /// syslog `Sep 19 08:12:33` 无年份：按 referenceDate 的年份组装，落在未来就整年退一格。
    static func syslogDate(in text: String, prefixLimit: Int?, referenceDate: Date) -> Date? {
        guard let result = syslogStamp.first(in: text), withinPrefix(result.range.location, prefixLimit) else { return nil }
        guard
            let monthToken = rxGroup(result, 1, in: text),
            let month = monthNumbers[monthToken],
            let day = Int(rxGroup(result, 2, in: text) ?? ""),
            let hour = Int(rxGroup(result, 3, in: text) ?? ""),
            let minute = Int(rxGroup(result, 4, in: text) ?? ""),
            let second = Int(rxGroup(result, 5, in: text) ?? "")
        else { return nil }

        let nanosecond = nanoseconds(from: rxGroup(result, 6, in: text))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let year = calendar.component(.year, from: referenceDate)
        guard let candidate = date(year: year, month: month, day: day, hour: hour, minute: minute,
                                   second: second, nanosecond: nanosecond, timeZone: .current) else { return nil }
        guard candidate > referenceDate else { return candidate }
        return date(year: year - 1, month: month, day: day, hour: hour, minute: minute,
                    second: second, nanosecond: nanosecond, timeZone: .current)
    }

    /// epoch 只认行首 24 字符内的独立 token：正文里的 10 位订单号不该被当成时间。
    static func epochDate(in text: String, prefixLimit: Int?) -> Date? {
        guard let limit = prefixLimit else { return nil }
        guard let result = epochStamp.first(in: text), withinPrefix(result.range.location, min(limit, 2)) else { return nil }
        guard let token = rxGroup(result, 1, in: text), let value = Double(token) else { return nil }
        let seconds: Double
        switch token.count {
        case 10: seconds = value
        case 13: seconds = value / 1_000
        default: return nil
        }
        // 10 位数字也可能是订单号 / 构建号，用 2000-2100 的合理性窗口挡掉
        guard seconds >= 946_684_800, seconds <= 4_102_444_800 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    static func plainDateOnly(in text: String, prefixLimit: Int?) -> Date? {
        guard let result = dateOnlyStamp.first(in: text), withinPrefix(result.range.location, prefixLimit) else { return nil }
        let token = (text as NSString).substring(with: result.range)
        return LogDateFormat.dateOnly.date(from: token)
    }

    /// 最后一道兜底：把行首可能的时间戳片段交给缓存好的 ISO8601 格式化器。
    static func formatterFallback(in text: String, prefixLimit: Int) -> Date? {
        let ns = text as NSString
        guard ns.length > 8 else { return nil }
        let head = ns.substring(to: min(ns.length, prefixLimit)).trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = [head, head.trimmingCharacters(in: CharacterSet(charactersIn: "[]()<>"))]
        for candidate in candidates {
            if candidate.count >= 10, candidate.contains("-"), candidate.contains(":") {
                if let date = LogDateFormat.isoDate(candidate) { return date }
            }
        }
        return nil
    }

    static func nanoseconds(from fraction: String?) -> Int {
        guard let fraction, fraction.isEmpty == false else { return 0 }
        let digits = String(fraction.prefix(9))
        guard let value = Int(digits) else { return 0 }
        return value * Int(pow(10.0, Double(9 - digits.count)))
    }

    static func timeZone(for token: String) -> TimeZone? {
        if token.uppercased() == "Z" { return TimeZone(secondsFromGMT: 0) }
        let sign: Int = token.hasPrefix("-") ? -1 : 1
        let digits = token.drop(while: { $0 == "+" || $0 == "-" }).filter { $0.isNumber }
        guard digits.isEmpty == false else { return nil }
        var hours = 0
        var minutes = 0
        if digits.count >= 4 {
            hours = Int(digits.prefix(2)) ?? 0
            minutes = Int(digits.dropFirst(2).prefix(2)) ?? 0
        } else {
            hours = Int(String(digits.prefix(min(2, digits.count)))) ?? 0
            if digits.count > 2 { minutes = Int(digits.dropFirst(2)) ?? 0 }
        }
        return TimeZone(secondsFromGMT: sign * (hours * 3_600 + minutes * 60))
    }

    static func date(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int,
                             nanosecond: Int, timeZone: TimeZone?) -> Date? {
        guard year >= 1_970, year <= 2_999, (1...12).contains(month), (1...31).contains(day),
              hour <= 23, minute <= 59, second <= 60 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        if let timeZone { calendar.timeZone = timeZone }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.nanosecond = nanosecond
        return calendar.date(from: components)
    }

    static func withinPrefix(_ location: Int, _ limit: Int?) -> Bool {
        guard let limit else { return true }
        return location <= limit
    }
}
