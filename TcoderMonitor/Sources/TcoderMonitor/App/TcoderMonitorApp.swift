import SwiftUI

/// 界面那一路。进程入口与"无头 / GUI"的分派在 `App/TcoderEntry.swift`
/// （那里必须是**任何 AppKit 之前**的第一站，否则 `exit()` 会撞上窗口状态恢复）。
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
                .background(CaptureWindowSizer())
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

/// 取证时把窗口内容尺寸真正设成 `CaptureWindow` 要的那档。
///
/// 为什么 `.defaultSize` 不够（2026-09-21 实测）：SwiftUI 会把窗口帧写进 app 的
/// defaults 域（键名形如 `NSWindow Frame SwiftUI.ModifiedContent<…>-1-AppWindow-1`），
/// 下次启动**恢复的帧优先于 `.defaultSize`** —— 于是取证脚本传了
/// `TCODER_CAPTURE_WINDOW_HEIGHT=1000` 之后图仍然是 1640px（= 820pt），
/// 长页折叠线以下照样没进证据。`-ApplePersistenceIgnoreState YES` 管的是
/// restorable state，管不到这条帧自动保存。
/// 只在设了环境变量时动作，且**只执行一次**：之后用户手动拖窗口不该被 App 拽回去。
///
/// ⚠ **这个类型不许声明成 `private`**（2026-09-27 实测，台账卷十二 §191／工单 #108）：
/// Swift 给**文件私有作用域里的类型**生成的运行时名字带一段 `(unknown context at $<地址>)`，
/// 而那个地址随每次构建的二进制布局变。这个类型挂在 `WindowGroup` 的内容链上，
/// 而 AppKit/SwiftUI 的窗口与分栏自动保存键**就用内容链的类型名**——
/// 于是每构建换一次键：这台机器上实测攒出 `NSWindow Frame*` 1574 条 ＋
/// `NSSplitView Subview Frames*` 2030 条（整个域 1.53 MB，真正属于用户状态的只有 5 条），
/// 而启动时要把这整域读进来、再拿一条 320 字符的长键去查。
/// 由 `SceneTypeNameStabilityTests` 钉住（判据＝显示名里不许出现那段地址）。
struct CaptureWindowSizer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { apply(to: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // 首帧可能还没有 window，补一次；`applied` 保证只真的改一次。
        DispatchQueue.main.async { apply(to: nsView.window) }
    }

    private static var applied = false

    private func apply(to window: NSWindow?) {
        guard !Self.applied, let window,
              ProcessInfo.processInfo.environment["TCODER_CAPTURE_WINDOW_HEIGHT"] != nil
                || ProcessInfo.processInfo.environment["TCODER_CAPTURE_WINDOW_WIDTH"] != nil else { return }
        let target = NSSize(width: CaptureWindow.width, height: CaptureWindow.height)
        guard window.contentView?.frame.size != target else { Self.applied = true; return }
        window.setContentSize(target)
        window.center()
        Self.applied = true
    }
}

/// 取证滚动开关。**不设环境变量 = 完全不生效**，页面照旧从顶部开始。
///
/// 为什么窗口开高还不够：AppKit 会把窗口高度**钳到屏幕可见高**
/// （实测请求 1600pt 只拿到 1050pt），所以最长那几页的尾部
/// （错误日志趋势图、贡献者第 3 名之后）仍然在视口之外。
/// 设成 `bottom` 时页骨架滚到底部，取证脚本再拍一趟就拿到"下半屏"。
enum CaptureScroll {
    static let tailID = "tcoder.capture.tail"

    /// 判据本体（纯函数，供单测）：只有字面量 `bottom` 生效。
    /// 别的值（含拼错、含空串）一律当作"没设"——取证宁可少滚一趟，
    /// 也不要按一个猜出来的语义滚动，那会让"拍到的那一屏"无法复述。
    static func isBottom(_ rawValue: String?) -> Bool { rawValue == "bottom" }

    static var scrollToTail: Bool {
        isBottom(ProcessInfo.processInfo.environment["TCODER_CAPTURE_SCROLL"])
    }
}
