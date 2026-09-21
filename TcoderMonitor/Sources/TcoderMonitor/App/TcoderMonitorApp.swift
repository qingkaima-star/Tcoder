import SwiftUI

@main
struct TcoderMonitorApp: App {
    init() {
        // 运行时漏翻台账要在退出时落盘（只在设了 TCODER_I18N_RUNTIME_LEDGER 时才写）。
        atexit { LocalizationLedger.shared.flush() }
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
