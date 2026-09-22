import SwiftUI

// OWNER: R3 依赖证据链 · 分 scope 统计（RD-13c）
//
// runtime / dev / test / build / platform / 未标注 **各算一行**，不许混成一个数。
// 旧页面上只有「运行时 / 开发 = 68 / 11」这一对，而 scope 实际有六档：
// 测试依赖（junit / pytest / rspec）与构建插件（asm / spotless）被并进了"运行时"，
// 于是"开发依赖不随产物发布"那句口径说明是假的 —— 分不出来就没法说清哪一档要负责。
//
// 三列数各自回答一个不同的问题，缺一个就会有人拿"声明数"当"核对数"用：
// 声明 / 漏洞已核对 / 版本已核对（外加命中数只在非零时出声）。

/// 一张紧凑的 scope 账表。判定与数字一律读 `DependencyEvidence`，页面自己不另算一套。
struct DependencyScopeBreakdown: View {
    let deps: DependencyReport

    private var rows: [DependencyScopeCount] {
        DependencyEvidence.ledger(for: deps).scopeBreakdown.filter { $0.declared > 0 }
    }

    var body: some View {
        GlassSection("分用途统计", subtitle: "声明范围按 scope 分开汇总，不并成一个数", icon: .package) {
            VStack(alignment: .leading, spacing: DataRowMetrics.rowGap) {
                if rows.isEmpty {
                    Text("没有可统计的依赖声明")
                        .foregroundStyle(.secondary)
                        .typed(Theme.Typo.body)
                } else {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 { DataRowSeparator() }
                        DataFieldRow(label: row.scope,
                                     value: Self.caption(row),
                                     style: .text,
                                     valueColor: row.vulnerable > 0
                                         ? Theme.Semantic.danger.textColor : Theme.Semantic.neutral.textColor)
                            .help(Self.help(row))
                    }
                }
            }
        }
    }

    static func caption(_ row: DependencyScopeCount) -> String {
        "声明 \(NumberFormat.grouped(row.declared)) · 漏洞已核对 \(NumberFormat.grouped(row.vulnerabilityChecked))"
            + " · 版本已核对 \(NumberFormat.grouped(row.versionChecked))"
            + (row.vulnerable > 0 ? " · 命中 \(NumberFormat.grouped(row.vulnerable))" : "")
    }

    /// 每一格都补一句"未核对的那部分去哪儿了"——覆盖度不能只报分子。
    static func help(_ row: DependencyScopeCount) -> String {
        let uncovered = row.declared - row.vulnerabilityChecked
        guard uncovered > 0 else { return "该档 \(row.declared) 条全部完成漏洞核对" }
        return "该档还有 \(NumberFormat.grouped(uncovered)) 条未完成漏洞核对（未查 / 失败 / 版本未解析 / 生态不支持 / 预算未覆盖），"
            + "「未发现已知漏洞」只对已核对的那部分成立"
    }
}
