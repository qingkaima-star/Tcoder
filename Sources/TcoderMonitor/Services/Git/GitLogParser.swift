import Foundation

// MARK: - Git log --numstat 解析（WS-B · 子代理1）
//
// OWNER: WS-B subagent 1. 纯函数层：把 `git log --numstat` 的整段 stdout 变成
// `[ParsedCommit]`，不做任何 IO、不触碰 `@MainActor`，可在 `Task.detached` 里调用。
// 下游消费方是 `GitAggregation.swift`（子代理2），它只用本文件提供的
// `ParsedCommit` / `ParsedFileChange` 形状与 4 个静态工具函数。
//
// 上游主命令（由 `ShellGitAnalyzer` 侧执行）：
//     git log --no-merges -n 20000 --date=iso-local \
//         --pretty=format:%H%x1f%an%x1f%ae%x1f%aI%x1f%s%x1e --numstat
//
// 实测输出形状（Apple Git-155 / 2.50.1，`cat -et` 观察，^_ = \x1f、^^ = \x1e、^I = tab）：
//     <sha>^_<an>^_<ae>^_<aI>^_<subject>^^$        <- pretty 头，\x1e 在行尾
//     0^I0^ISources/App/{main.swift => entry.swift}$   <- 该提交的 numstat 行
//     -$                                          <- 空行，然后才是下一个头
// 关键结论：**numstat 行出现在 \x1e 之后**，即 \x1e 属于「它下面那批 numstat」的
// 上一个头。所以不能「按 \x1e split 后把块内 numstat 归给块内 header」（会整体错位
// 一个提交），本实现按行扫描：含 \x1f 的行开一个新提交，其后的 numstat 行归属它。
//
// 其余实测事实：
// * 二进制文件 -> `-\t-\tpath`（增删都是单个 `-`）。
// * 重命名三种形式（`diff.renames` 默认开启）：
//     `oldname.txt => renamed.txt`                       —— 无公共前后缀，整路径
//     `Sources/{App => Lib}/keepme.swift`                —— 公共前后缀 + 大括号
//     `Sources/App/{version1.swift => version2.swift}`   —— 同目录改名（带修改也是这个形状）
//   相似度低于阈值时 git 不做重命名检测，退化为「新增 + 删除」两行普通 numstat。
// * `core.quotePath` 默认 true：非 ASCII / 空格 / 制表符 / 引号会被 C 风格引用，
//   且**重命名两侧各自加引号**：`"docs/\346\272\220.txt" => "docs/\347\233\256.txt"`，
//   也可能只有一侧需要引号：`docs/plain.txt => "docs/\347\233\256.txt"`。
//   因此必须先按「引号外的大括号」定位箭头、再逐侧解引号，绝不能先剥首尾引号。
// * 高字节以八进制转义（`\346\272\220`）输出，必须按字节还原成 UTF-8。
// * 空提交：头行之后直接是空行，没有 numstat 行。
// * 末尾无换行、提交之间有空行；\x1e 与头在同一物理行的末尾。

// MARK: - 解析结果模型

/// 一次提交里单个文件的变更（`--numstat` 一行）。
struct ParsedFileChange: Equatable, Sendable {
    /// 变更后的最终路径（重命名取新名字；已解引用与还原转义）。
    var path: String
    /// 新增行数（二进制文件记 0）。
    var additions: Int = 0
    /// 删除行数（二进制文件记 0）。
    var deletions: Int = 0
    /// git 以 `-\t-\t` 上报的二进制文件。
    var isBinary: Bool = false
    /// 重命名前的路径；非重命名为 nil。
    var renameFrom: String?
}

/// 一条提交 + 它的文件级变更。
struct ParsedCommit: Equatable, Sendable {
    var sha: String
    var authorName: String
    /// 原始邮箱（未归一化；归一化请用 `GitLogParser.normalizeEmail`）。
    var authorEmail: String
    /// 绝对时刻，已按作者自己的 UTC 偏移折算好。
    var date: Date
    /// 作者提交时的 UTC 偏移秒数，来自 `%aI` 尾部偏移，如 `+08:00` -> 28800。
    var authorOffsetSeconds: Int = 0
    var subject: String = ""
    var changes: [ParsedFileChange] = []

    /// 新增行合计（二进制行贡献 0）。
    var additions: Int { changes.reduce(0) { $0 + $1.additions } }
    /// 删除行合计（二进制行贡献 0）。
    var deletions: Int { changes.reduce(0) { $0 + $1.deletions } }
    /// 本次提交触达的文件数。
    var filesChanged: Int { changes.count }
}

// MARK: - 解析器

enum GitLogParser {

    /// 提交记录分隔符（`\x1e`，pretty 头行的末尾）。
    private static let recordSeparator: Character = "\u{1e}"
    /// 字段分隔符（`\x1f`）。
    private static let fieldSeparator: Character = "\u{1f}"

    private static let secondsInDay = 86_400.0
    private static let arrowBytes: [UInt8] = [0x20, 0x3D, 0x3E, 0x20]   // " => "

    // MARK: 主入口

    /// 主命令产出的整段 stdout -> 提交数组，保持 git 给定的新→旧顺序。
    ///
    /// 容错策略：字段数不足 5 的块、时间戳无法解析的块一律**整条丢弃**（不崩溃、
    /// 不伪造 1970 日期，否则会污染 first/last commit 与项目年龄）；空串返回 `[]`。
    static func parse(_ output: String) -> [ParsedCommit] {
        guard !output.isEmpty else { return [] }

        // 关键坑：Swift 里 "\r\n" 是**一个**扩展字素簇，`split(separator: "\n")` 切不开
        // CRLF 文本（实测会把整段当成一行）。先把 CRLF 折叠成 LF，再按 LF 切。
        let text = output.replacingOccurrences(of: "\r\n", with: "\n")

        var commits: [ParsedCommit] = []
        var pending: ParsedCommit?

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(trimTrailingNewlines(rawLine))     // 残余裸 CR（老 Mac 行尾）

            // \x1e 只会出现在头行末尾；按它切开后，含 \x1f 的那段才是头。
            for piece in line.split(separator: recordSeparator, omittingEmptySubsequences: false) {
                let segment = String(piece)
                if segment.contains(fieldSeparator) {
                    if let finished = pending { commits.append(finished) }
                    pending = commit(fromHeaderLine: segment)
                    continue
                }
                if segment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                guard pending != nil, let change = numstatLine(segment) else { continue }
                pending?.changes.append(change)
            }
        }
        if let finished = pending { commits.append(finished) }
        return commits
    }

    /// 头行（5 个 \x1f 字段）-> 提交；不合法返回 nil。
    private static func commit(fromHeaderLine header: String) -> ParsedCommit? {
        // subject 里理论上不会再出现 \x1f，仍限制最多切 4 刀把尾巴整体留给 subject。
        let fields = header.split(separator: fieldSeparator, maxSplits: 4,
                                 omittingEmptySubsequences: false)
        guard fields.count == 5 else { return nil }

        let sha = trimWhitespace(String(fields[0]))
        guard !sha.isEmpty else { return nil }

        guard let stamp = parseAuthorTimestamp(trimWhitespace(String(fields[3]))) else { return nil }

        return ParsedCommit(sha: sha,
                            authorName: trimWhitespace(String(fields[1])),
                            authorEmail: trimWhitespace(String(fields[2])),
                            date: stamp.date,
                            authorOffsetSeconds: stamp.offsetSeconds,
                            subject: String(fields[4]),
                            changes: [])
    }

    // MARK: numstat 行

    /// 一行 numstat（`新增\t删除\t路径`）-> 变更；无法识别时返回 nil。
    static func numstatLine(_ line: String) -> ParsedFileChange? {
        let text = trimTrailingNewlines(Substring(line))

        // 路径本身不会含裸 tab（git 会引用成 \t），所以最多切两刀，第三段整段是路径。
        let parts = text.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }

        let added = trimWhitespace(String(parts[0]))
        let deleted = trimWhitespace(String(parts[1]))
        let isBinary = (added == "-" || deleted == "-")

        var additions = 0
        var deletions = 0
        if !isBinary {
            guard let a = Int(added), let d = Int(deleted), a >= 0, d >= 0 else { return nil }
            additions = a
            deletions = d
        }

        let resolved = resolvedRenamePath(String(parts[2]))
        guard !resolved.final.isEmpty else { return nil }        // 空串 = 解引用/转义失败

        return ParsedFileChange(path: resolved.final,
                                additions: additions,
                                deletions: deletions,
                                isBinary: isBinary,
                                renameFrom: resolved.from)
    }

    /// 把 numstat 的路径字段还原成「最终路径 + 重命名来源」。
    /// 处理三种形状：`a/b.txt => a/c.txt`、`a/{b => c}/x.txt`、`a/b.{txt => md}`。
    /// 返回 `final == ""` 表示该字段解不出合法路径（调用方据此丢弃该行）。
    private static func resolvedRenamePath(_ field: String) -> (final: String, from: String?) {
        let bytes = Array(field.utf8)

        // 1) 引号/大括号之外的箭头 —— 整路径重命名，两侧各自可能被引用。
        if let arrow = topLevelArrowIndex(in: bytes) {
            let left = String(decoding: bytes[0..<arrow], as: UTF8.self)
            let right = String(decoding: bytes[(arrow + arrowBytes.count)..<bytes.count], as: UTF8.self)
            guard let from = unquotePath(left), let final = unquotePath(right),
                  !final.isEmpty else { return ("", nil) }
            return (final, from.isEmpty ? nil : from)
        }

        // 2) 大括号形状（整字段可能被一对引号包住，先还原再拆括号）。
        let decoded = unquotePath(field) ?? ""
        if !decoded.isEmpty, let brace = braceRename(decoded) { return brace }

        // 3) 普通路径。
        guard let plain = unquotePath(field), !plain.isEmpty else { return ("", nil) }
        return (plain, nil)
    }

    /// 在字节序列里找第一个「引号外且大括号外」的 ` => `，返回其起始下标。
    private static func topLevelArrowIndex(in bytes: [UInt8]) -> Int? {
        var index = 0
        var braceDepth = 0
        var inQuote = false
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            if inQuote {
                if escaped { escaped = false }
                else if byte == 0x5C { escaped = true }        // 反斜杠
                else if byte == 0x22 { inQuote = false }        // 双引号
                index += 1
                continue
            }
            switch byte {
            case 0x22: inQuote = true
            case 0x7B: braceDepth += 1                         // {
            case 0x7D: if braceDepth > 0 { braceDepth -= 1 }   // }
            case 0x20 where braceDepth == 0:                   // 空格
                if hasPrefix(arrowBytes, at: index, in: bytes) { return index }
            default: break
            }
            index += 1
        }
        return nil
    }

    /// `prefix{old => new}suffix` -> (新路径, 旧路径)；不是这个形状时返回 nil。
    private static func braceRename(_ text: String) -> (final: String, from: String?)? {
        let bytes = Array(text.utf8)
        guard let open = bytes.firstIndex(of: UInt8(ascii: "{")) else { return nil }
        guard let close = bytes.firstIndex(of: UInt8(ascii: "}")), close > open + 1 else { return nil }
        let inner = open + 1..<close
        var split: Int?
        var cursor = inner.lowerBound
        while cursor < inner.upperBound {
            if bytes[cursor] == 0x20, hasPrefix(arrowBytes, at: cursor, in: bytes) {
                split = cursor
                break
            }
            cursor += 1
        }
        guard let arrow = split else { return nil }
        let prefix = bytes[0..<open]
        let suffix = bytes[(close + 1)..<bytes.count]
        let oldMid = bytes[inner.lowerBound..<arrow]
        let newMid = bytes[(arrow + arrowBytes.count)..<inner.upperBound]
        let oldPath = String(decoding: prefix, as: UTF8.self)
            + String(decoding: oldMid, as: UTF8.self)
            + String(decoding: suffix, as: UTF8.self)
        let newPath = String(decoding: prefix, as: UTF8.self)
            + String(decoding: newMid, as: UTF8.self)
            + String(decoding: suffix, as: UTF8.self)
        guard !newPath.isEmpty, !oldPath.isEmpty else { return nil }
        return (newPath, oldPath)
    }

    private static func hasPrefix(_ needle: [UInt8], at index: Int, in bytes: [UInt8]) -> Bool {
        guard index + needle.count <= bytes.count else { return false }
        for offset in 0..<needle.count where bytes[index + offset] != needle[offset] { return false }
        return true
    }

    /// 去掉 git 的 C 风格路径引用并还原转义（`\"`、`\\`、`\t`、`\n`、八进制 `\346` …）。
    /// 未被引号包裹的输入原样返回；转义非法时返回 nil。
    private static func unquotePath(_ field: String) -> String? {
        let bytes = Array(field.utf8)
        guard let first = bytes.first, first == 0x22 else { return field }
        guard bytes.count >= 2, bytes.last == 0x22 else { return nil }

        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var index = 1
        let closingQuote = bytes.count - 1
        while index < closingQuote {
            let byte = bytes[index]
            guard byte == 0x5C else {                       // 非反斜杠：原样
                out.append(byte)
                index += 1
                continue
            }
            index += 1
            guard index < closingQuote else { return nil }  // 悬空反斜杠
            switch bytes[index] {
            case 0x22: out.append(0x22); index += 1         // \"
            case 0x5C: out.append(0x5C); index += 1         // \\
            case 0x61: out.append(0x07); index += 1         // \a
            case 0x62: out.append(0x08); index += 1         // \b
            case 0x66: out.append(0x0C); index += 1         // \f
            case 0x6E: out.append(0x0A); index += 1         // \n
            case 0x72: out.append(0x0D); index += 1         // \r
            case 0x74: out.append(0x09); index += 1         // \t
            case 0x76: out.append(0x0B); index += 1         // \v
            case 0x30...0x37:                               // 八进制 \0 ~ \377
                var value = 0
                var digits = 0
                while digits < 3, index < closingQuote, (0x30...0x37).contains(bytes[index]) {
                    value = value * 8 + (Int(bytes[index]) - 0x30)
                    index += 1
                    digits += 1
                }
                guard value <= 0xFF else { return nil }
                out.append(UInt8(value))
            default: return nil                             // 未知转义
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: 时间戳

    /// 解析 git 的严格 ISO 8601 带偏移时间串：
    /// `2026-09-19T08:12:33+08:00`、`2026-09-19T08:12:33-05:30`、`2026-09-19T08:12:33Z`。
    /// 全程纯算术，不使用本机时区；`offsetSeconds` 是尾部偏移（`+08:00` -> 28800）。
    static func parseAuthorTimestamp(_ text: String) -> (date: Date, offsetSeconds: Int)? {
        let bytes = Array(trimWhitespace(text).utf8)
        guard bytes.count >= 19 else { return nil }
        var index = bytes.startIndex

        func digits(_ count: Int) -> Int? {
            var value = 0
            for _ in 0..<count {
                guard index < bytes.endIndex, (0x30...0x39).contains(bytes[index]) else { return nil }
                value = value * 10 + (Int(bytes[index]) - 0x30)
                index += 1
            }
            return value
        }
        func peek() -> UInt8? { index < bytes.endIndex ? bytes[index] : nil }
        func eat(_ character: UInt8) -> Bool {
            guard peek() == character else { return false }
            index += 1
            return true
        }

        guard let year = digits(4) else { return nil }
        guard eat(0x2D), let month = digits(2) else { return nil }        // '-'
        guard eat(0x2D), let day = digits(2) else { return nil }
        guard eat(0x54) || eat(0x74) || eat(0x20) else { return nil }     // 'T' / 't' / ' '
        guard let hour = digits(2), eat(0x3A), let minute = digits(2), eat(0x3A),
              let second = digits(2) else { return nil }

        // 闰秒/亚秒：git 只发整秒，但容忍一下小数部分（不参与绝对时刻以外的计算）。
        var fraction = 0.0
        if peek() == 0x2E || peek() == 0x2C {                            // '.' / ','
            index += 1
            var value = 0
            var scale = 1.0
            var any = false
            while let byte = peek(), (0x30...0x39).contains(byte) {
                value = value * 10 + (Int(byte) - 0x30)
                scale *= 10
                index += 1
                any = true
            }
            guard any else { return nil }
            fraction = Double(value) / scale
        }

        var offsetSeconds = 0
        switch peek() {
        case 0x5A, 0x7A:                                                  // 'Z' / 'z'
            index += 1
        case 0x2B, 0x2D:                                                  // '+' / '-'
            let sign: Int = peek() == 0x2D ? -1 : 1
            index += 1
            guard let offsetHour = digits(2) else { return nil }
            _ = eat(0x3A)                                                 // 冒号可选：+0800 也吃
            let offsetMinute: Int
            if peek().map({ (0x30...0x39).contains($0) }) == true {
                guard let m = digits(2) else { return nil }
                offsetMinute = m
            } else {
                offsetMinute = 0
            }
            guard offsetHour <= 23, offsetMinute < 60 else { return nil }
            offsetSeconds = sign * (offsetHour * 3_600 + offsetMinute * 60)
        default:
            offsetSeconds = 0                                             // 无偏移按 UTC
        }

        // 尾部只允许空白，否则视为不是 ISO 串。
        guard trimWhitespace(String(decoding: bytes[index...], as: UTF8.self)).isEmpty else { return nil }

        guard month >= 1, month <= 12, day >= 1, day <= daysInMonth(year: year, month: month),
              hour <= 23, minute <= 59, second <= 60 else { return nil }

        let days = daysFromCivil(year: year, month: month, day: day)
        let localSeconds = days * secondsInDay
            + Double(hour * 3_600 + minute * 60 + second) + fraction
        return (Date(timeIntervalSince1970: localSeconds - Double(offsetSeconds)), offsetSeconds)
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

    // MARK: 邮箱归一化

    /// 邮箱归一化：去尖括号、去首尾空白、转小写；Gmail 风格 `+alias`
    /// （`x+y@gmail.com` -> `x@gmail.com`）只对 `gmail.com` / `googlemail.com` 生效。
    static func normalizeEmail(_ email: String) -> String {
        var value = trimWhitespace(email)
        if value.contains("<") || value.contains(">") {
            value = value
                .replacingOccurrences(of: "<", with: "")
                .replacingOccurrences(of: ">", with: "")
            value = trimWhitespace(value)
        }
        value = value.lowercased()

        guard let at = value.lastIndex(of: "@") else { return value }
        let local = String(value[value.startIndex..<at])
        let domain = String(value[value.index(after: at)...])
        guard domain == "gmail.com" || domain == "googlemail.com" else { return value }
        guard let plus = local.firstIndex(of: "+") else { return value }
        let name = String(local[local.startIndex..<plus])
        return name.isEmpty ? value : name + "@" + domain
    }

    // MARK: 小工具

    private static func trimWhitespace(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 逐个标量地削掉尾部换行。不能只看 `hasSuffix("\r")`：Swift 里 `"\r\n"` 是一个
    /// 字素簇，`last` 拿到的是整个 CR+LF，与 `"\r"` 或 `"\n"` 都不相等。
    private static func trimTrailingNewlines(_ text: Substring) -> Substring {
        var trimmed = text
        while let scalar = trimmed.unicodeScalars.last, scalar == "\n" || scalar == "\r" {
            trimmed = trimmed.dropLast()
        }
        return trimmed
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
}
