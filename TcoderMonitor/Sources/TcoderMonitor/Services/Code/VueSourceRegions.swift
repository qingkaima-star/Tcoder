import Foundation

// OWNER: R2 (Vue / TS 识别与模板字符串) —— Vue 单文件组件（SFC）的语言分区（RD-07）。
//
// 要解决的事：`.vue` 一份文件里住着三种语言（`<script>` 是 TS/JS、`<template>` 是 HTML、
// `<style>` 是 CSS），HEAD 的口径是**整份文件按 Vue 一种语言处理**：
//   * 词法档案 = `SourceLanguageCatalog` 里那条 `LanguageRule(language: "Vue", …,
//     linePrefixes: [], blockStart: "<!--", blockEnd: "-->")`；
//   * 于是 `<script>` 里的 `//` 与 `/* */` 全被算成代码行（注释行漏计），
//     `<style>` 里的 `/* */` 同样被算成代码行；
//   * 函数识别那侧靠 `ComplexityEngine.computeScriptMask` 的「本行含 `<script` 就进、
//     含 `</script` 就出」粗判，模板区里 `@click="() => doThing()"` 这种内联箭头
//     虽然进不了榜，但**串与花括号的状态机是拿整份文件喂的**：模板区里一个没配对的引号
//     或反引号，就能把后面 `<script>` 里的真函数整段吞掉。
//
// 这里给出一个**结构化的分区**：逐行标出它属于哪个区域、该用哪种语言的词法，
// 三条消费路径（函数识别、注释统计、代码行统计）都按同一份分区归位。
//
// 边界判据：只有**顶格**（列 0）的 `<script` / `<template` / `<style` 与 `</script` /
// `</template` / `</style` 才算 SFC 区块边界。SFC 的顶层块按约定顶格，
// 而模板里嵌套的 `<template #slot>` 一律带缩进 —— 不要求顶格就会把模板区从中间劈开。

extension ComplexityEngine {

    /// `.vue` 一份文件的逐行区域归属。检测失败（不是 SFC 形状）返回 nil，调用方退回旧口径。
    struct VueRegionMap: Sendable {
        enum Region: Sendable {
            /// `<script>` 块内部（不含标签行本身）
            case script
            /// `<template>` 块内部
            case template
            /// `<style>` 块内部
            case style
            /// SFC 的标签行（`<script setup lang="ts">`、`</template>`…）与顶层注释
            case structure
            /// 区块之外的正文
            case other
        }

        let regions: [Region]
        /// `<script>` 块该按哪种语言清洗（`lang="ts"` → TypeScript，缺省 JavaScript）
        let scriptLanguage: String

        var scriptMask: [Bool] { regions.map { $0 == .script } }

        func scriptLineCount() -> Int { regions.filter { $0 == .script }.count }

        /// 逐行语言档案：非代码区域给 nil（清洗成空行、不进花括号增量、不带定界符状态）。
        func lineProfiles(jsFamily: LangProfile, html: LangProfile, css: LangProfile) -> [LangProfile?] {
            regions.map { region in
                switch region {
                case .script: return jsFamily
                case .template: return nil
                case .style: return nil
                case .structure, .other: return nil
                }
            }
        }
    }

    /// 分区后的行归位读数（RD-20 的相关半边：注释率不许把模板/样式注释混进同一个分母）。
    struct VueRegionTally: Sendable, Equatable {
        var scriptCodeLines = 0
        var scriptCommentLines = 0
        var templateCodeLines = 0
        var templateCommentLines = 0
        var styleCodeLines = 0
        var styleCommentLines = 0
        /// SFC 标签行与区块之外的行
        var structureCodeLines = 0
        var structureCommentLines = 0

        /// 脚本区注释占脚本区（代码 + 注释）的比例。分母只含脚本区 —— 这是「分区归位」的落点。
        var scriptCommentRatio: Double {
            let denominator = scriptCodeLines + scriptCommentLines
            return denominator == 0 ? 0 : Double(scriptCommentLines) / Double(denominator)
        }
    }

    /// 扫一遍行，给出 SFC 分区；没有识别出任何顶层块就返回 nil（退回整份文件一种语言的旧口径）。
    static func detectVueRegions(_ lines: [String]) -> VueRegionMap? {
        var regions = [VueRegionMap.Region](repeating: .other, count: lines.count)
        var scriptLanguage: String?
        var opened = false
        var index = 0
        while index < lines.count {
            guard let tag = topLevelSFCOpeningTag(lines[index]) else { index += 1; continue }
            var end = index
            while end < lines.count, lines[end].contains(">") == false { end += 1 }
            if end >= lines.count { break }                      // 标签都没闭合：不是可信的 SFC
            let tagText = lines[index...end].joined(separator: " ")
            if tag == "script" { scriptLanguage = sfcScriptLanguage(in: tagText) }
            for line in index...end { regions[line] = .structure }
            let close = closingTagLine(lines, from: end, tag: tag)
            let body = close - 1
            if body > end {
                for line in (end + 1)...body where regions[line] == .other {
                    regions[line] = regionKind(of: tag)
                }
            }
            if close < lines.count { regions[close] = .structure }
            opened = true
            index = close + 1
        }
        guard opened else { return nil }
        return VueRegionMap(regions: regions, scriptLanguage: scriptLanguage ?? "JavaScript")
    }

    static func regionKind(of tag: String) -> VueRegionMap.Region {
        switch tag {
        case "script": return .script
        case "template": return .template
        default: return .style
        }
    }

    /// 顶格（列 0）才认：SFC 顶层块按约定顶格，模板里嵌套的 `<template #slot>` 带缩进。
    static func topLevelSFCOpeningTag(_ line: String) -> String? {
        guard line.hasPrefix("<script") || line.hasPrefix("<template") || line.hasPrefix("<style") else {
            return nil
        }
        for tag in ["script", "template", "style"] where line.hasPrefix("<" + tag) { return tag }
        return nil
    }

    /// `</xxx` 且顶格才算区块结束；`<script …></script>` 写在同一行时也当场收口。
    static func closingTagLine(_ lines: [String], from: Int, tag: String) -> Int {
        let closing = "</" + tag
        var index = from
        while index < lines.count {
            if lines[index].hasPrefix(closing) { return index }
            // 同一行里标签刚闭合就跟着结束标签（`<script src="x"></script>`）
            if index == from, let range = lines[index].range(of: closing) {
                return lines[index][range.lowerBound...].hasPrefix(closing) ? index : index + 1
            }
            index += 1
        }
        return lines.count
    }

    /// `<script setup lang="ts">` / `<script lang=ts>` → "TypeScript"；缺省与未知一律 JavaScript。
    static func sfcScriptLanguage(in tagText: String) -> String {
        let lowered = tagText.lowercased()
        guard let at = lowered.range(of: "lang") else { return "JavaScript" }
        let rest = lowered[at.upperBound...]
        guard let equals = rest.firstIndex(of: "=") else { return "JavaScript" }
        let value = rest[rest.index(after: equals)...].drop(while: { $0 == " " || $0 == "\"" || $0 == "'" })
        var name = ""
        for c in value {
            if c.isLetter || c.isNumber { name.append(c) } else { break }
        }
        switch name {
        case "ts", "typescript": return "TypeScript"
        case "tsx": return "TypeScript"
        case "js", "javascript", "jsx": return "JavaScript"
        default: return "JavaScript"
        }
    }
}
