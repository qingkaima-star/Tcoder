/// OWNER: WS-X3 TestSplit —— 自 ShellBorderlessTests.swift 拆出，扫描器自证：符号/间距/区块/投影四类判据各自的反例夹具。用例本体未改，只是搬了家。
import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import TcoderMonitor

extension ShellBorderlessTests {

    /// 整行注释？扫源码文本的判据都必须先过这一道，否则注释里正当提到的被禁写法会误判。
    static func isComment(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
    }

    /// 行首缩进（空格数）。用来判断一行属于哪一条 modifier 链。
    static func indent(of line: String) -> Int {
        line.prefix(while: { $0 == " " }).count
    }

    /// ① 某个符号在**代码**里被使用的行数（整行注释豁免）。
    static func symbolUses(_ symbol: String,
                           in files: [(path: String, content: String)]) -> [String] {
        files.flatMap { file in
            file.content.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .compactMap { index, raw in
                    let line = String(raw)
                    guard !isComment(line), line.contains(symbol) else { return nil }
                    return "\(file.path):\(index + 1)"
                }
        }
    }

    static func tertiaryInMeasuredTextBlocks(
        in files: [(path: String, content: String)]) -> [String] {
        files.flatMap { file -> [String] in
            let lines = file.content.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            var hits: [String] = []
            for (row, line) in lines.enumerated() {
                guard line.contains(".tertiary"), !isComment(line) else { continue }
                guard let block = textBlock(lines, at: row),
                      measuredMarkers.contains(where: { block.contains($0) }) else { continue }
                hits.append("\(file.path):\(row + 1)")
            }
            return hits
        }
    }

    /// 取第 `row` 行所属的那一个视图块（含它的整条 modifier 链），已剥注释。
    ///
    /// 块界靠缩进，而不是靠数括号：SwiftUI 里同一条链的 modifier 比宿主行深一档，
    /// 下一块的宿主行与上一块的宿主行**同档** —— 这就是天然的界。
    /// 回溯时跳过以 `.` 开头的行（那是 modifier 续行，不是块首）。
    static func textBlock(_ lines: [String], at row: Int, lookback: Int = 20) -> String? {
        let chainIndent = indent(of: lines[row])
        var start = row
        while start >= 0 && row - start <= lookback {
            let candidate = lines[start]
            if !isComment(candidate), indent(of: candidate) <= chainIndent,
               !candidate.trimmingCharacters(in: .whitespaces).hasPrefix(".") {
                break
            }
            if isBlank(candidate) { return nil }
            start -= 1
        }
        guard start >= 0, !isComment(lines[start]) else { return nil }
        let base = indent(of: lines[start])
        var end = row
        while end + 1 < lines.count {
            let next = lines[end + 1]
            if isBlank(next) { break }
            if !isComment(next), indent(of: next) <= base { break }
            end += 1
        }
        return lines[start...end].filter { !isComment($0) }.joined(separator: "\n")
    }

    static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 从 `marker`（某段声明的开头）到它配平的那个 `}`。
    /// 只量**页面级**容器：组内条目用小间距是合法用法，把它们一起判红，
    /// 下一步一定是有人为了过门去放宽阈值。
    static func region(in text: String, startingAt marker: String) -> String? {
        guard let head = text.range(of: marker) else { return nil }
        var depth = 0
        var scanned = ""
        for char in text[head.lowerBound...] {
            scanned.append(char)
            if char == "{" { depth += 1 }
            if char == "}" {
                depth -= 1
                if depth == 0 { return scanned }
            }
        }
        return nil
    }

    /// ④ 一段页面级布局里小于 `minimum` 的容器间距。
    /// 认两种写法：`spacing: Theme.Spacing.<成员>`（查成员真实取值）与
    /// `spacing: 数字`（裸数字本来就不该出现在页面里）。
    static func tightSpacings(in region: String, minimum: CGFloat) -> [String] {
        region.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            .compactMap { index, raw in
                let line = String(raw)
                guard !isComment(line), let range = line.range(of: "spacing:") else { return nil }
                let tail = line[range.upperBound...]
                if let token = spacingValues.keys.sorted().first(where: { tail.contains($0) }),
                   let value = spacingValues[token] {
                    return value < minimum ? "L\(index + 1) Theme.Spacing.\(token)=\(value)" : nil
                }
                let digits = tail.drop(while: { $0 == " " }).prefix { $0.isNumber || $0 == "." }
                if let literal = Double(digits), !digits.isEmpty {
                    return CGFloat(literal) < minimum ? "L\(index + 1) 裸值 \(literal)" : nil
                }
                return nil
            }
    }

}
