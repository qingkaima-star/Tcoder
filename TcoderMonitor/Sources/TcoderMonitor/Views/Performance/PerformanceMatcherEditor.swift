import SwiftUI

/// 匹配模式编辑器（置底，不与首屏争注意力——《40 WS-H》§8.6）。
///
/// 规则本身只新增/删除一条匹配模式，不触碰任何进程；这一点写进按钮提示与说明行。
struct PerformanceMatcherEditor: View {
    let onAdd: (String, String) -> Void

    @State private var pattern = ""
    @State private var title = ""

    private var trimmedPattern: String { pattern.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 两个字段都非空才允许提交，避免留下一条命中一切的怪规则。
    var canAdd: Bool { !trimmedPattern.isEmpty && !trimmedTitle.isEmpty }

    var body: some View {
        GlassSection("匹配模式", subtitle: "新增分组规则（只读观测，不干预任何进程）", icon: .add) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(spacing: Theme.Spacing.sm) {
                    TextField("匹配模式，例如 java", text: $pattern)
                        .textFieldStyle(.roundedBorder)
                        .flexCell()
                    TextField("分组名称，例如「后端服务」", text: $title)
                        .textFieldStyle(.roundedBorder)
                        .flexCell()
                    GlassButton("添加分组", icon: .add, style: .prominent, isEnabled: canAdd) { add() }
                }
                .onSubmit { if canAdd { add() } }
                NoteLine("匹配模式对进程名与命令行做包含匹配，例如 java、nginx、mysqld。规则本身不改变任何进程。")
            }
        }
    }

    private func add() {
        guard canAdd else { return }
        onAdd(trimmedTitle, trimmedPattern)
        pattern = ""
        title = ""
    }
}
