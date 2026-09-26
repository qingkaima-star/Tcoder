// OWNER: 性能轮总工（工单 #108，台账卷十二 §191）。
//
// 判据：**挂进 `WindowGroup` 内容链的类型，运行时显示名里不许出现"文件私有作用域"那一段地址**。
// 为什么要有这条：AppKit/SwiftUI 的窗口与分栏自动保存键**直接拿内容链的类型名**当键，
// 而 Swift 给文件私有类型生成的名字带 `(unknown context at $<地址>)`，地址随每次构建变 ⇒
// 键每构建换一个、旧的永不清理。本仓实测一台机器上攒出 1574 条 `NSWindow Frame*`
// ＋ 2030 条 `NSSplitView Subview Frames*`（整个 defaults 域 1.53 MB，真正的用户状态只有 5 条），
// 而启动时这整域要被读进来、再拿一条 320 字符的长键去查。
//
// ⚠ 射程要说清：这条守的是**类型名稳不稳定**，不守"键的总数不再涨"——
// 视图链本身变了（加一层 `.frame`／换个 modifier）照样换键，那是 SwiftUI 的语义，不在这里管。
import XCTest
@testable import TcoderMonitor

/// 判定本体是纯函数（`instability(in:)`），测试只负责喂真名字与假名字——
/// 这样"判据坏没坏"与"代码合不合"是两件事，不会被捆在一起看不见。
final class SceneTypeNameStabilityTests: XCTestCase {

    /// 名单＝判据的射程。往里加一枚类型 = 声明"它会被写进 AppKit 的持久化键"。
    static let sceneContentTypes: [(name: String, type: Any.Type)] = [
        ("CaptureWindowSizer", CaptureWindowSizer.self),
        ("RootView", RootView.self),
    ]

    static let unstableMarker = "(unknown context at"

    static func instability(in typeName: String) -> String? {
        guard typeName.contains(unstableMarker) else { return nil }
        return "名字里带每次构建都会变的地址 ⇒ 拿它当持久化键，就是每构建攒一条没人再读的孤儿记录：\(typeName)"
    }

    func testSceneContentTypesHaveBuildStableNames() {
        XCTAssertFalse(Self.sceneContentTypes.isEmpty,
                       "名单为空 ⇒ 这条判据在空转（第 46 类：读不到东西不许给绿灯）")
        for entry in Self.sceneContentTypes {
            let display = String(reflecting: entry.type)
            XCTAssertNil(Self.instability(in: display), "\(entry.name)：\(Self.instability(in: display) ?? "")")
            XCTAssertTrue(display.hasPrefix("TcoderMonitor."),
                          "显示名不带本模块前缀 ⇒ 量的可能不是这个模块的类型：\(display)")
        }
    }

    /// 反例：文件私有类型正是 §191 那一版写出来的东西。**没有这条，上面那条绿等于零**——
    /// 谁都可能把 `instability` 改成一个永不命中的串。
    /// ⚠ 若哪天 Swift 的 mangling 变了、私有类型不再带地址，这条会红；
    ///    那说明**判据的前提消失了**，正确处置是连判据一起撤，而不是给它加豁免。
    func testRulerFiresOnAFilePrivateType() {
        let display = String(reflecting: UnstableByDesign.self)
        XCTAssertNotNil(Self.instability(in: display),
                        "文件私有类型的显示名里已经没有那段地址 ⇒ 判据作废，连同正向那条一起撤；实测拿到：" + display)
        print("【#108 反例实测】" + display)
    }
}

/// 故意造成"当初那版"的形状：文件私有作用域里的类型。
private struct UnstableByDesign {}
