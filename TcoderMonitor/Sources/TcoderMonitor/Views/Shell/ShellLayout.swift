import SwiftUI

// MARK: - 外壳层专属度量
//
// 全页共用的版面锚点在 `Theme.Layout`（WS-G 基座）。这里只收**侧栏 / 页面切换 / 评分环**
// 这类外壳独有、基座里没有对应档的尺寸。存在的唯一理由是让 `Views/Shell/**` 与三个外壳
// 页面里不再出现裸数字（WS-I §2.6 的工单口径：列宽/尺寸改命名常量表，参照 `DepColumns`）。

enum ShellLayout {
    /// 侧栏三档宽度。min 取 220 是为了「复杂度风险」这类四字标题 + 健康点 + 行数副标题
    /// 在一行内不折行；max 收到 340 防止拉宽侧栏后把 1080 起窗的内容区挤到不可用。
    static let sidebarMinWidth: CGFloat = 220
    static let sidebarIdealWidth: CGFloat = 260
    static let sidebarMaxWidth: CGFloat = 340

    /// 健康评分环的描边宽度。环是「一个数字 + 一圈进度」，描边必须粗到能从 40pt 数字
    /// 里抢走注意力，但细到不跟数字争读法；12 是 170 直径下的实测比例（约 7%）。
    static let ringLineWidth: CGFloat = 12

    /// 侧栏项目前的健康色点。9pt 是可点行里最小的稳定可辨尺寸，
    /// 再小在深色底上会被材质吃掉。
    static let statusDotDiameter: CGFloat = 9

    /// 实时读数里数字列的定宽。等宽数字仍要定宽，是因为 `ByteFormat` 的
    /// 「1.5 GB / 128 MB」位数不同，不锁宽会把整条侧栏底栏推着走。
    static let liveReadoutColumnWidth: CGFloat = 40
}

// MARK: - 缺数据三态句式（WS-H §7.3）
//
// 三态：① 有数据（含真 0）② 查了但是空的 ③ 没查 / 查不了。
// 把 ③ 渲染成 `0` 或绿色结论，等于把「我们没有证据」伪装成「我们查过、是安全的」。
// 数字位统一走 `Theme.Placeholder.missingValue`（`--`），这里只管说明文字。

enum ShellCopy {
    /// ③ 尚未跑过分析器。
    static func notAnalyzed(_ subject: String) -> String { "尚未分析\(subject)" }

    /// ② 分析器跑完了、没有命中项 —— 这是结论，可以给定心丸语气，但要带「已完成扫描」。
    static func scannedButFoundNone(_ subject: String) -> String { "已完成扫描，未发现\(subject)" }

    /// ③ 测不了，且必须给原因。空态三段式的第三段（下一步怎么做）由调用方补。
    static func cannotAnalyze(_ reason: String) -> String { "无法分析：\(reason)" }
}
