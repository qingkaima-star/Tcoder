import SwiftUI

// MARK: - 外壳层专属度量
//
// 全页共用的版面锚点在 `Theme.Layout`（WS-G 基座）。这里只收**侧栏 / 页面切换 / 评分环**
// 这类外壳独有、基座里没有对应档的尺寸。存在的唯一理由是让 `Views/Shell/**` 与三个外壳
// 页面里不再出现裸数字（WS-I §2.6 的工单口径：列宽/尺寸改命名常量表，参照 `DepColumns`）。

enum ShellLayout {
    /// 侧栏三档宽度。220 → 240：项目行从「48pt 两行卡」收成「30pt 单行」之后，
    /// 项目名与右侧两格定宽读数（`37k 行` / `健康 61`）挤在同一行，220 下名字被截成
    /// `Tcoder…`（17:17 实拍实测）。max 收到 340 防止拉宽侧栏把 1080 起窗的内容区挤到不可用。
    static let sidebarMinWidth: CGFloat = 240
    static let sidebarIdealWidth: CGFloat = 272
    static let sidebarMaxWidth: CGFloat = 340

    /// 健康评分环的描边宽度。环是「一个数字 + 一圈进度」，描边必须粗到能从 40pt 数字
    /// 里抢走注意力，但细到不跟数字争读法；12 是 170 直径下的实测比例（约 7%）。
    static let ringLineWidth: CGFloat = 12

    /// 侧栏项目前的健康色点。9pt 是可点行里最小的稳定可辨尺寸，
    /// 再小在深色底上会被材质吃掉。
    static let statusDotDiameter: CGFloat = 9

    /// 实时读数里数字列的定宽。等宽数字仍要定宽，是因为 `ByteFormat` 的
    /// 「1.5 GB / 128 MB」位数不同，不锁宽会把整条侧栏底栏推着走。
    ///
    /// 40 → 56：18:00 实拍实测 `30.6 GB` 在 40pt 里**折成两行**（`30.6` / `GB`），
    /// 底栏被撑歪 —— 而全仓没有一条断言量过这一格（`ShellDesignTests` 只量项目行那两格）。
    /// 「定宽格」不量就等于没钉。下限由
    /// `ShellBorderlessTests.test_sidebarLiveReadoutColumnFitsTheWorstCase` 钉住。
    static let liveReadoutColumnWidth: CGFloat = 56

    // MARK: 侧栏行

    /// 侧栏行高。48 → 30（风格契约 7）。
    ///
    /// 旧值 48 是**行卡**的高度：两行文字 + 上下内边距 + 一块 `.contentInset` 材质。
    /// 现在行卡没了，选中态交回 `.listStyle(.sidebar)` 原生绘制，行就是一行文字 ——
    /// 还留 48pt 等于在原生列表里手工撑出第二套行距，两侧一起用力必然显挤。
    /// 30 是「11pt 读数 + 上下各 8pt 命中余量」的自然结果，也仍在可点下限之上。
    static let rowMinHeight: CGFloat = 30
    /// 行内左右内边距。系统 sidebar 行本身已有缩进，这里只补图标与文字的呼吸。
    static let rowPadding: CGFloat = Theme.Spacing.xs

    /// 两个读数各占一个**右对齐定宽格**。
    ///
    /// 为什么光有 `.monospacedDigit()` 不够：它只保证「每个数字一样宽」，
    /// 但 `NumberFormat.compact` 的结果本身会跨位数变宽（`9k` → `20k` → `182k`），
    /// 健康分从两位进三位同理 —— 变宽的那个字符串会把它**右边**的文本整格推走，
    /// 扫描过程中就能看到「健康 61」在左右跳。定宽右对齐之后邻居位置完全不动，
    /// 这也是活动监视器数字列的排法（WS-H §2.1）。
    static let lineCountColumnWidth: CGFloat = 58
    static let healthColumnWidth: CGFloat = 54

    /// 引导卡最小高度。低于这个高度，「把文件夹拖到这里」会被看成一条被截断的提示，
    /// 而不是一块可以继续添加项目的区域。
    static let guideMinHeight: CGFloat = 96
    /// 已有项目时引导卡收成一行的高度。
    static let guideCompactHeight: CGFloat = 28
    /// 引导卡虚线描边的虚实段（2 段循环）。用令牌拼出来，不写裸数字：
    /// 0.5pt 实线 + 4pt 空档，读起来是「可投放区域」而不是「被截断的边框」。
    static let guideDash: [CGFloat] = [Theme.Stroke.hairline, Theme.Spacing.xxs]
}

// MARK: - 缺数据的说明句式（WS-H §7.3）
//
// 数字位的四态（实测值 / 未发现 / 算不出 / 未分析）在 `Design/DataAbsence.swift`，
// 这里只管**说明文字**：数字位说不了「为什么空」，说明句负责把「没查」和
// 「查了但是空的」这两句话讲开。把「没查」渲染成 `0` 或绿色结论，
// 等于把「我们没有证据」伪装成「我们查过、是安全的」。

/// 缺数据句式的**主语 / 原因**。做成枚举而不是让调用方随手传一句中文，是双语逼出来的：
/// 「尚未分析X」翻成英文时词序会反过来（`Code size not analysed yet`），
/// 把 X 当碎片各翻一次，拼出来就是坏英文（`Not analysed yet this project`）。
/// 所以**碎片不进目录，整句成键**，键的字面量就写在下面 switch 里 ——
/// 守卫 3 要求每个键在 `Sources/**` 真实出现，运行时拼出来的键不算，
/// 那正是「改了原文没同步目录」该被抓到的情形。
enum CopySubject: String {
    case thisProject = "该项目"
    case allMetrics = "全部指标"
    case codeSize = "代码规模"
    case gitHistory = "Git 历史"
    case errorLogs = "错误日志"
    case errorLevelLogs = "错误级别日志"
    case errors = "错误"
    case commits = "提交记录"
    case strengthsAndRisks = "优点与风险项"
    case noLogFiles = "未接入任何日志文件"
    case notAGitRepo = "该目录不是 Git 仓库，或提交记录为空"
}

enum ShellCopy {
    /// ③ 尚未跑过分析器。
    static func notAnalyzed(_ subject: CopySubject) -> String {
        switch subject {
        case .thisProject: return localizedCopy("尚未分析该项目")
        case .allMetrics: return localizedCopy("尚未分析全部指标")
        // 键与今天界面上的串**一字不差**（"尚未分析" 与 "Git 历史" 之间没有空格），
        // 双语不许顺手改排版：改了就是另一张图，P1 的"中文零变化"回归判据会失真。
        case .gitHistory: return localizedCopy("尚未分析Git 历史")
        case .codeSize: return localizedCopy("尚未分析代码规模")
        case .errorLogs: return localizedCopy("尚未分析错误日志")
        default: return localizedFormat("尚未分析%1$@", localizedCopy(subject.rawValue))
        }
    }

    /// ② 分析器跑完了、没有命中项 —— 这是结论，可以给定心丸语气，但要带「已完成扫描」。
    static func scannedButFoundNone(_ subject: CopySubject) -> String {
        switch subject {
        case .commits: return localizedCopy("已完成扫描，未发现提交记录")
        case .errors: return localizedCopy("已完成扫描，未发现错误")
        case .errorLevelLogs: return localizedCopy("已完成扫描，未发现错误级别日志")
        case .strengthsAndRisks: return localizedCopy("已完成扫描，未发现优点与风险项")
        default: return localizedFormat("已完成扫描，未发现%1$@", localizedCopy(subject.rawValue))
        }
    }

    /// ③ 测不了，且必须给原因。空态三段式的第三段（下一步怎么做）由调用方补。
    static func cannotAnalyze(_ reason: CopySubject) -> String {
        switch reason {
        case .noLogFiles: return localizedCopy("无法分析：未接入任何日志文件")
        case .notAGitRepo: return localizedCopy("无法分析：该目录不是 Git 仓库，或提交记录为空")
        default: return localizedFormat("无法分析：%1$@", localizedCopy(reason.rawValue))
        }
    }
}
