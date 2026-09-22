import Foundation
import XCTest
@testable import TcoderMonitor

// MARK: - 批次 P26：插值拼出来的中文串 = 查表永远查不到的那一类（只减不增棘轮）
//
// **形状**：`subtitle: "只有 \(n) 个历史点"`。整句里嵌了插值 ⇒ 源码里从来没有
// "只有 N 个历史点"这个**键**，`localizedCopy` 无从查起 ⇒ 英文态下这一行必然还是中文。
// 正确写法是整句键 + 位置参数：`localizedFormat("只有 %1$@ 个历史点", …)` ——
// 它字面量里没有 `\(`，所以这条尺子对**用对形状的**写法天然免疫（不是靠白名单豁免）。
//
// 立它的直接理由：英文态全量取证（交付头 `64c5418`，36 张）第一次逐张用眼睛看英文态，
// 照出「评分趋势」卡上**卡名是英文、紧挨着的副标题是中文**——
// 而那两行一个走查表、一个是插值拼串。这类缺陷中文态永远看不见。
//
// 为什么只钉本轮 UI 面（Health / Performance / Logs / PerfLogs / Shell）：
// 全站实测 114 处 / 26 个文件，榜首是 `Views/Dependencies/`（12 处），
// 那条目录此刻归整改轮 R3 在写。给别人的活跃面套自己的棘轮是误伤
// （守恒线要留逐条留名的豁免口，同理适用于"别把闸门下到别人车道上"）；
// 全站那 114 处属双语线存量（要逐处重构成整句键），登记在
// `docs/界面语言-对齐AiX.md` §6.26，由那条线按文件收。

extension LocalizationGuardTests {

    /// 本轮 UI 面。加目录要在这里加，并且基线要跟着实扫重量。
    static let interpolatedScanDirs = ["Health", "Performance", "Logs", "PerfLogs", "Shell"]

    /// 纯函数：数一段源码里"同时含 `\\(` 与汉字"的字符串字面量。
    /// 逐原始行 + 只剥整行注释（与全站其它扫描器同一道边界）。
    static func interpolatedHanLiterals(in content: String) -> [String] {
        let literal = try! NSRegularExpression(pattern: "\"((?:[^\"\\\\]|\\\\.)*?)\"")
        var hits: [String] = []
        for line in SurfaceScanKit.codeLines(content) {
            let range = NSRange(line.startIndex..., in: line)
            for match in literal.matches(in: line, options: [], range: range) {
                guard let inner = Range(match.range(at: 1), in: line) else { continue }
                let text = String(line[inner])
                let isHan = text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
                if text.contains("\\(") && isHan { hits.append(text) }
            }
        }
        return hits
    }

    /// 2026-09-22 在 `64c5418` 之后实扫播种：**40 处 / 12 个文件**
    /// （最多的一档是 `Logs/LogsMetricGrid.swift` 8 处）。只许往下调。
    private static let interpolatedCopyCeiling = 40

    func test_interpolatedChineseCopyInUiFaceDoesNotGrow() throws {
        var perFile: [String: Int] = [:]
        for dir in Self.interpolatedScanDirs {
            for file in try SurfaceScanKit.sourceFiles(under: "Views/\(dir)") {
                let n = Self.interpolatedHanLiterals(in: file.content).count
                if n > 0 { perFile[file.path] = n }
            }
        }
        let total = perFile.values.reduce(0, +)
        // 分母必须 > 0：扫不到文件时"0 处违规"是假零（这条守卫第一次写就要防这个）。
        XCTAssertFalse(perFile.isEmpty, "本轮 UI 面一个插值中文串都没扫到 ⇒ 先怀疑扫描面坏了")
        let ranked = perFile.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
        print("插值中文串现量 \(total) / 上限 \(Self.interpolatedCopyCeiling)，"
            + "分布：" + ranked.prefix(5).map { "\($0.key) \($0.value)" }.joined(separator: "、"))
        XCTAssertLessThanOrEqual(total, Self.interpolatedCopyCeiling,
                                 "插值拼出来的中文串涨了 \(total - Self.interpolatedCopyCeiling) 处："
                                 + "这种形状没有整句键，英文态永远查不到 ⇒ 改成 localizedFormat(\"整句 %1$@\", …)")
    }

    /// 元测试：用对形状的免疫、用错形状的必须抓到。
    func test_interpolatedCopyScannerSeparatesBothShapes() {
        // 原始字符串里 `\(` 就是字面量两个字符（插值需要写成 `\#(`），
        // 所以这里造的是"源码文本"，不是真的去插值一个不存在的 `n`。
        let wrong = #"subtitle: "只有 \(NumberFormat.grouped(n)) 个历史点""#
        XCTAssertEqual(Self.interpolatedHanLiterals(in: wrong).count, 1,
                       "插值中文串没被抓到 ⇒ 这条棘轮数不出东西")
        let right = #"subtitle: localizedFormat("只有 %1$@ 个历史点", NumberFormat.grouped(n))"#
        XCTAssertTrue(Self.interpolatedHanLiterals(in: right).isEmpty, "整句键 + 位置参数的被误伤")
        let pureInterpolation = #"Text("\(NumberFormat.grouped(n))")"#
        XCTAssertTrue(Self.interpolatedHanLiterals(in: pureInterpolation).isEmpty,
                      "没有汉字的纯数字插值被误伤")
    }
}
