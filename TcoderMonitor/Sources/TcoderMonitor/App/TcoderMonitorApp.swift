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
        .defaultSize(width: CaptureWindow.width, height: CaptureWindow.height)
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

/// 取证窗口尺寸。**不设环境变量就是产品默认值 1280×820，一个像素都不变。**
///
/// 存在的理由是验收口径本身有问题：`scripts/capture_pages_isolated.sh` 用
/// `screencapture -l<窗口号>` 只拍**视口**，而页面是 `ScrollView` ——
/// 820pt 高的窗口意味着九页里六页的图表、表格、热点榜**根本没进证据**。
/// 那时长页的"实拍复核通过"其实只在第一屏成立（这条已经写进
/// `docs/界面语言-对齐AiX.md` §6.1 的缺口清单）。本机屏高 1080pt，
/// 开到 1000pt 可以多覆盖约 22% 的纵向内容。
///
/// 取值一律夹在 `[680, 4000]`：手打错一个数量级会拍出一种"看起来通过"的废图，
/// 那比拍不到更坏。
enum CaptureWindow {
    static let defaultWidth: CGFloat = 1280
    static let defaultHeight: CGFloat = 820
    static let minimum: CGFloat = 680      // = 产品的 minHeight，再小就是废图
    static let maximum: CGFloat = 4000

    static func dimension(from rawValue: String?, fallback: CGFloat) -> CGFloat {
        guard let rawValue, let parsed = Double(rawValue) else { return fallback }
        guard parsed >= Double(minimum), parsed <= Double(maximum) else { return fallback }
        return CGFloat(parsed)
    }

    static var width: CGFloat {
        dimension(from: ProcessInfo.processInfo.environment["TCODER_CAPTURE_WINDOW_WIDTH"],
                  fallback: defaultWidth)
    }

    static var height: CGFloat {
        dimension(from: ProcessInfo.processInfo.environment["TCODER_CAPTURE_WINDOW_HEIGHT"],
                  fallback: defaultHeight)
    }
}
