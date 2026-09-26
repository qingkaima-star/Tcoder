/// OWNER: 总工（性能线）—— 自 `PerfHitchGuardTests.swift` 整块搬来的**规则负责人名单**（`ownerNotes`）。
/// 声明本体一字未改。搬的理由写在原处那条指路注释里：#97 加一条 prefs 规则就把宿主顶过 400 行门，
/// 而这把门的口径是「拆，不抬线」。**新增一条规则时必须同时在这张表里登记负责人**，
/// 否则报错时打不出"这格归谁、终点是哪"，基线就退化成遮羞布。
import Foundation

extension PerfHitchGuardTests {

    /// 每条规则的负责人 / 里程碑，只在报错时打出来，避免"基线是遮羞布"。
    static let ownerNotes: [String: String] = [
        "directFormatters": "M1 WS-W：DateFormatter/NumberFormatter 提 static let（终点 0）",
        "dynamicColorConstruction": "UI 流（Views/Shell）：把 `Color(nsColor: .separatorColor)` / "
            + "`Color(nsColor: .quaternaryLabelColor)` 换成 `Theme.Palette` 里已缓存的 `static let` 角色"
            + "（终点 0）。**2026-09-22 才有的尺子**：这条以前完全没人量——"
            + "`directFormatters` 的模式不认 `Color(`，于是渲染路径里现造动态色可以一路绿灯。"
            + "性能侧不接手：改的是 `Views/**`，归 UI 总工派发。",
        "tokenReference": "旧名 `dynamicNSColor`（2026-09-22 改名，因为名字在撒谎：它量的不是 NSColor）。"
            + "令牌由「每次访问现造」改成缓存之后，本条量的不再是分配次数，"
            + "而是**渲染路径里引用令牌成员的次数**——它是重算面的**读数**，"
            + "**终点不是 0**（打到 0＝页面不再着色）。它仍只许减不许增，但谁也不许把它当「还掉多少债」报。"
            + "落地前 88（只认 .textColor），放宽到四成员后实测 107（+19 处 .graphicColor，全在图表 Mark/循环里）。"
            + "**2026-09-20 拧到 86**：`165faa7`（M1-集成，图表取色上提进 Design/）还掉了 21 处 Views 侧引用，"
            + "**2026-09-21 再拧到 59**：`c60abbd`（观感·批次 ABC 颜色面积收敛）又还掉 27 处。"
            + "两次都是同一条『现量/上限』打印＋`.scratch` 台账抓出来的——不打印就没人知道基线在漏。"
            + "而这条棘轮当时不报现量、没人看得见那 21 处余量——现在它每次跑都打「现量/上限」。",
        "fullSort": "M1 WS-P/WS-W：body 内派生集合缓存或移到 publish 里算（终点 0）",
        "syncFileIO": "M1 WS-W：body 读的计算属性里那个文件尺寸检查移到扫描期（终点 0）；"
            + "另一处 `chooseLogFiles` 的 `fileExists` 是一次点击一次的事件路径，已具名豁免（#72）",
        "syncPrefs": "全流（现量 0，新增即红）：渲染路径里不许出现 `UserDefaults`／`CFPreferences`／"
            + "`PropertyListSerialization`——prefs 读是**打盘的同步读**，§177 那批 time-profile 里 "
            + "`CFPreferences` 一族占首帧后主线程栈 40%（那部分是 AppKit 首用初始化，不是我们的代码）。"
            + "⚠ 这条**不覆盖 `@AppStorage`**：那是属性声明，字面不在跨度内（#97 后半，另格）。",
    ]

}
