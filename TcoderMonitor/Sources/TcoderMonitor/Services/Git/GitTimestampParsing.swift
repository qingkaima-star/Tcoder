// MARK: - Git 作者时间戳与作者时区换算（WS-B · 子代理1）
//
// 从 GitLogParser.swift 拆出，只为守住本轮的文件规模线（单文件 ≤ 400 行）
// 以及把 parseAuthorTimestamp 的 27 个分支降到阈值以下。
// 时间串的**判定顺序、字节常量、取值界，以及「绝对时刻 = 本地秒 - offsetSeconds」
// 这条折算全部逐字照抄**，没有改动任何口径。
// 文件头部那份 git 实测事实清单（`--date=iso-local`、`%aI` 尾部偏移、裸 CR 不折叠）
// 仍住在 GitLogParser.swift；这里只处理它交下来的那一个时间串。
//
// 跨文件后原先的 `private` 一律放宽到模块内可见（internal），除可见性外没有任何变化。

import Foundation

extension GitLogParser {
    // MARK: 时间戳

    /// 严格 ISO 8601 串的字节游标：只负责「按固定宽度取十进制 / 看下一个字节 / 吃掉某字节」。
    /// 三条判定与拆分前的三个嵌套函数逐字相同，包括一个容易忽略的细节：
    /// `digits` 取到一半发现非数字时，**已经吃掉的那几位不回退**（原实现也是如此——
    /// 整串随后一定以 nil 收场，游标位置不再被读到）。
    struct TimestampCursor {
        let bytes: [UInt8]
        var index: Int

        init(bytes: [UInt8]) {
            self.bytes = bytes
            self.index = bytes.startIndex
        }

        mutating func digits(_ count: Int) -> Int? {
            var value = 0
            for _ in 0..<count {
                guard index < bytes.endIndex, (0x30...0x39).contains(bytes[index]) else { return nil }
                value = value * 10 + (Int(bytes[index]) - 0x30)
                index += 1
            }
            return value
        }

        func peek() -> UInt8? { index < bytes.endIndex ? bytes[index] : nil }

        mutating func eat(_ character: UInt8) -> Bool {
            guard peek() == character else { return false }
            index += 1
            return true
        }
    }

    /// 解析 git 的严格 ISO 8601 带偏移时间串：
    /// `2026-09-19T08:12:33+08:00`、`2026-09-19T08:12:33-05:30`、`2026-09-19T08:12:33Z`。
    /// 全程纯算术，不使用本机时区；`offsetSeconds` 是尾部偏移（`+08:00` -> 28800）。
    ///
    /// 本函数只按拆分前的**同一顺序**把四段读下来，再过长度界与日历界：
    /// 日期时间 → 亚秒 → UTC 偏移 → 尾部只允许空白 → 各字段取值范围。
    /// 绝对时刻仍是 `本地秒 - offsetSeconds`，这条折算一字未动。
    static func parseAuthorTimestamp(_ text: String) -> (date: Date, offsetSeconds: Int)? {
        var cursor = TimestampCursor(bytes: Array(trimWhitespace(text).utf8))
        guard cursor.bytes.count >= 19 else { return nil }
        guard let parts = readCivilDateParts(&cursor) else { return nil }
        guard let fraction = readTimestampFraction(&cursor) else { return nil }
        guard let offsetSeconds = readUTCOffset(&cursor) else { return nil }

        // 尾部只允许空白，否则视为不是 ISO 串。
        guard trimWhitespace(String(decoding: cursor.bytes[cursor.index...], as: UTF8.self)).isEmpty else {
            return nil
        }

        guard parts.month >= 1, parts.month <= 12,
              parts.day >= 1, parts.day <= daysInMonth(year: parts.year, month: parts.month),
              parts.hour <= 23, parts.minute <= 59, parts.second <= 60 else { return nil }

        let days = daysFromCivil(year: parts.year, month: parts.month, day: parts.day)
        let localSeconds = days * secondsInDay
            + Double(parts.hour * 3_600 + parts.minute * 60 + parts.second) + fraction
        return (Date(timeIntervalSince1970: localSeconds - Double(offsetSeconds)), offsetSeconds)
    }

    /// 日期 + 时间那一段（`YYYY-MM-DD` 与 `HH:MM:SS`）。判定顺序与分隔符接受集
    /// （`T` / `t` / 空格）与拆分前一致。
    static func readCivilDateParts(_ cursor: inout TimestampCursor) -> (year: Int, month: Int, day: Int,
                                                                        hour: Int, minute: Int,
                                                                        second: Int)? {
        guard let year = cursor.digits(4) else { return nil }
        guard cursor.eat(0x2D), let month = cursor.digits(2) else { return nil }   // '-'
        guard cursor.eat(0x2D), let day = cursor.digits(2) else { return nil }
        guard cursor.eat(0x54) || cursor.eat(0x74) || cursor.eat(0x20) else { return nil } // T / t / 空格
        guard let hour = cursor.digits(2), cursor.eat(0x3A), let minute = cursor.digits(2),
              cursor.eat(0x3A), let second = cursor.digits(2) else { return nil }
        return (year, month, day, hour, minute, second)
    }

    /// 闰秒/亚秒：git 只发整秒，但容忍一下小数部分（不参与绝对时刻以外的计算）。
    /// `.` 与 `,` 都当小数点；点了小数点却一个数字都没有，仍判整串非法（返回 nil）。
    /// 没有小数点时返回 0.0，不消耗游标。
    static func readTimestampFraction(_ cursor: inout TimestampCursor) -> Double? {
        guard cursor.peek() == 0x2E || cursor.peek() == 0x2C else { return 0.0 }   // '.' / ','
        cursor.index += 1
        var value = 0
        var scale = 1.0
        var any = false
        while let byte = cursor.peek(), (0x30...0x39).contains(byte) {
            value = value * 10 + (Int(byte) - 0x30)
            scale *= 10
            cursor.index += 1
            any = true
        }
        guard any else { return nil }
        return Double(value) / scale
    }

    /// 尾部 UTC 偏移：`Z`/`z` 记 0、`+08:00` 与 `+0800` 按符号算、什么都没有按 UTC 记 0。
    /// 「冒号可选」与 `offsetHour <= 23, offsetMinute < 60` 这条界，以及越界时整串判非法，
    /// 全部与拆分前逐字相同。
    static func readUTCOffset(_ cursor: inout TimestampCursor) -> Int? {
        switch cursor.peek() {
        case 0x5A, 0x7A:                                                            // 'Z' / 'z'
            cursor.index += 1
            return 0
        case 0x2B, 0x2D:                                                            // '+' / '-'
            let sign: Int = cursor.peek() == 0x2D ? -1 : 1
            cursor.index += 1
            guard let offsetHour = cursor.digits(2) else { return nil }
            _ = cursor.eat(0x3A)                                                    // 冒号可选：+0800 也吃
            let offsetMinute: Int
            if cursor.peek().map({ (0x30...0x39).contains($0) }) == true {
                guard let m = cursor.digits(2) else { return nil }
                offsetMinute = m
            } else {
                offsetMinute = 0
            }
            guard offsetHour <= 23, offsetMinute < 60 else { return nil }
            return sign * (offsetHour * 3_600 + offsetMinute * 60)
        default:
            return 0                                                                // 无偏移按 UTC
        }
    }

    /// 该年该月的天数（proleptic 公历；闰年规则 4/100/400）。
    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        case 2: return isLeapYear(year) ? 29 : 28
        default: return 0
        }
    }

    private static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    /// 公历 -> 1970-01-01 起的天数（Howard Hinnant 算法，避开任何 Calendar）。
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Double {
        var shiftedYear = year
        if month <= 2 { shiftedYear -= 1 }
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400                                   // [0, 399]
        let monthIndex = month > 2 ? month - 3 : month + 9
        let dayOfYear = (153 * monthIndex + 2) / 5 + day - 1                      // [0, 365]
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100          // [0, 146096]
        return Double(era * 146_097 + dayOfEra + dayOfYear - 719_468)
    }

    // MARK: 时区工具（一律按作者自己的偏移，不用本机时区）

    /// 按作者自己的 UTC 偏移把绝对时刻换算成当地 0..<24 小时。
    static func localHour(of date: Date, offsetSeconds: Int) -> Int {
        let localized = localizedSeconds(of: date, offsetSeconds: offsetSeconds)
        guard localized.isFinite else { return 0 }
        let hour = Int(floor(modD(localized, secondsInDay) / 3_600))
        return clamp(hour, 0, 23)
    }

    /// 同上，返回周一为 0 的 0..<6 星期索引（1970-01-01 是星期四 -> +3）。
    static func localWeekdayMondayFirst(of date: Date, offsetSeconds: Int) -> Int {
        let localized = localizedSeconds(of: date, offsetSeconds: offsetSeconds)
        guard localized.isFinite else { return 0 }
        let dayNumber = Int(floor(localized / secondsInDay))
        return mod(dayNumber + 3, 7)
    }

    /// 当地（作者时区）的 epoch 秒。
    private static func localizedSeconds(of date: Date, offsetSeconds: Int) -> Double {
        let absolute = date.timeIntervalSince1970
        guard absolute.isFinite, abs(absolute) < 1e15 else { return 0 }
        return absolute + Double(offsetSeconds)
    }
    private static func clamp(_ value: Int, _ lower: Int, _ upper: Int) -> Int {
        if value < lower { return lower }
        if value > upper { return upper }
        return value
    }

    /// 结果恒在 `[0, modulus)`，负数安全。
    private static func mod(_ value: Int, _ modulus: Int) -> Int {
        guard modulus > 0 else { return 0 }
        let remainder = value % modulus
        return remainder < 0 ? remainder + modulus : remainder
    }

    private static func modD(_ value: Double, _ modulus: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: modulus)
        return remainder < 0 ? remainder + modulus : remainder
    }

    /// 一天的秒数。只被本文件的时间戳与时区工具用到，随它们一起搬了过来。
    static let secondsInDay = 86_400.0

}
