import SwiftUI

@main
struct TcoderMonitorApp: App {
    init() {
        // 运行时漏翻台账要在退出时落盘（只在设了 TCODER_I18N_RUNTIME_LEDGER 时才写）。
        atexit { LocalizationLedger.shared.flush() }
        // 无头模式：argv[1] 精确命中子命令词才走这里，跑完直接 exit，GUI 永不出现。
        // 为什么放在 init 而不是另起一个 executable target：见
        // `docs/superpowers/specs/2026-09-21-tcoder-cli-design.md` §2（一个二进制 = 一句
        // "交付二进制 == HEAD"仍然只指一个东西，打包链与来源证明链一字不动）。
        if CLIRouter.isHeadlessInvocation(argv: CommandLine.arguments) {
            exit(CLIRouter.main(argv: CommandLine.arguments))
        }
    }

    @State private var state = AppState()

    var body: some Scene {
        WindowGroup("Tcoder") {
            RootView()
                .environment(state)
                .frame(minWidth: 1080, minHeight: 680)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(after: .newItem) {
                Button("添加项目…") {
                    NotificationCenter.default.post(name: .requestAddProject, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command])

                Divider()

                Button("重新分析") {
                    state.scanSelected()
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(state.isScanning)
            }

            CommandGroup(after: .toolbar) {
                // .commands content is NOT part of the scene's view tree, so it does not
                // inherit .environment(state). Capture `state` here instead of reading
                // @Environment(AppState.self) inside a child view — that traps at launch.
                Menu("前往") {
                    ForEach(DetailSection.allCases) { section in
                        Button(section.title) {
                            NotificationCenter.default.post(name: .requestSelectSection, object: section)
                        }
                    }
                }
            }
        }
    }
}

extension Notification.Name {
    static let requestAddProject = Notification.Name("tcoder.requestAddProject")
    static let requestSelectSection = Notification.Name("tcoder.requestSelectSection")
}
