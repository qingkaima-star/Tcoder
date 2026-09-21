import Foundation

// MARK: - Git log --numstat 解析（WS-B · 子代理1）
//
// OWNER: WS-B subagent 1. 纯函数层：把 `git log --numstat` 的整段 stdout 变成
// `[ParsedCommit]`，不做任何 IO、不触碰 `@MainActor`，可在 `Task.detached` 里调用。
// 下游消费方是 `GitAggregation.swift`（子代理2），它只用本文件提供的
// `ParsedCommit` / `ParsedFileChange` 两个形状，以及 `normalizeEmail`、`localHour`、
// `localWeekdayMondayFirst`、`parseAuthorTimestamp` 这几个静态工具函数。
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
// * git 的 stdout 行尾恒为 LF；但 `%s` 会**原样吐出裸 CR**（实测
//   `git commit -m "$(printf 'has\rcarriage')"` -> `has^Mcarriage`），所以本实现
//   只折叠 CRLF，绝不把单独的 CR 当行尾，否则这种提交会被切碎。

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
                if isBlank(segment) { continue }
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

        let isBinary = parts[0] == "-" || parts[1] == "-"

        var additions = 0
        var deletions = 0
        if !isBinary {
            guard let a = parseCount(parts[0]), let d = parseCount(parts[1]), a >= 0, d >= 0 else { return nil }
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
            let step = unquoteEscape(bytes[index], bytes: bytes, index: index, closingQuote: closingQuote)
            switch step {
            case .byte(let value, let next), .octal(let value, let next):
                out.append(value)
                index = next
            case .malformed:
                return nil                                  // 未知转义
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// 反斜杠之后那一个转义序列的展开。表与边界逐字照抄拆分前那 12 个 `case`：
    /// `\"` `\\` `\a` `\b` `\f` `\n` `\r` `\t` `\v` 各自映射到的字节没动，
    /// 八进制仍是最多 3 位、值超过 0xFF 与未知转义同样判非法（`.malformed`）。
    enum UnquoteStep {
        case byte(UInt8, Int)
        case octal(UInt8, Int)
        case malformed
    }

    static func unquoteEscape(_ escaped: UInt8, bytes: [UInt8], index: Int,
                              closingQuote: Int) -> UnquoteStep {
        switch escaped {
        case 0x22: return .byte(0x22, index + 1)            // \"
        case 0x5C: return .byte(0x5C, index + 1)            // \\
        case 0x61: return .byte(0x07, index + 1)            // \a
        case 0x62: return .byte(0x08, index + 1)            // \b
        case 0x66: return .byte(0x0C, index + 1)            // \f
        case 0x6E: return .byte(0x0A, index + 1)            // \n
        case 0x72: return .byte(0x0D, index + 1)            // \r
        case 0x74: return .byte(0x09, index + 1)            // \t
        case 0x76: return .byte(0x0B, index + 1)            // \v
        case 0x30...0x37:                                   // 八进制 \0 ~ \377
            return unquoteOctal(bytes: bytes, index: index, closingQuote: closingQuote)
        default: return .malformed                          // 未知转义
        }
    }

    /// 八进制转义：从 `index` 起最多取 3 位八进制数字，值超过 0xFF 判非法。
    static func unquoteOctal(bytes: [UInt8], index: Int, closingQuote: Int) -> UnquoteStep {
        var value = 0
        var cursor = index
        var digits = 0
        while digits < 3, cursor < closingQuote, (0x30...0x37).contains(bytes[cursor]) {
            value = value * 8 + (Int(bytes[cursor]) - 0x30)
            cursor += 1
            digits += 1
        }
        guard value <= 0xFF else { return .malformed }
        return .octal(UInt8(value), cursor)
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

    static func trimWhitespace(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// numstat 的计数列：先按原样解析（git 输出不会有空格），失败再容忍性地去空白。
    private static func parseCount(_ text: Substring) -> Int? {
        if let direct = Int(text) { return direct }
        return Int(text.trimmingCharacters(in: .whitespaces))
    }

    /// 只看 UTF-8 视图判断是否全是空白/换行，避免每行都走一次 NSString 裁剪。
    private static func isBlank(_ text: String) -> Bool {
        for byte in text.utf8 where byte != 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D {
            return false
        }
        return true
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

}
