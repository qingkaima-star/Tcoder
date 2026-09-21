# 实施计划：把九页碎文案收进圆圈问号（ⓘ hover 才显详细）

日期：2026-09-21 · 归属：总工 · 输入：`docs/superpowers/specs/2026-09-21-ui-copy-tooltip-inventory.md`

用户判词：**"小文案实在是太多了，把这些小文案都隐藏到那些圆圈问号里面，鼠标放上去的时候再显示详细文案。"**
产品红线（本仓一贯）：**诚实性告知不许为了"简约"消失**。这两件事的交点就是本计划要量出来的东西。

## 0. 前置（WS-X8 正在做，做完才许开切片）

1. 三处上屏渲染点 `DataFootnote` / `DataCaption` / `NoteLine` 真的去查本地化表。
   不先修就是把中文钉死在英文态 —— 往 `Localizable.strings` 加键**不产生任何效果**。
2. 共用组件 `Design/CopyHelp.swift` 的 `CopyHelpBadge(_ text: String, label: String? = nil)`。
   全站此前所有 tooltip 都匿名挂在数字上，鼠标得猜哪里能 hover。

前置未合入之前，任何页面切片都不许开工（否则各页自造一份帮助图标，就是"三种画法"老坑的重演）。

## 1. 三条机器守卫（**只由总工写一次**，切片负责人只许调用不许改）

写进 `Tests/TcoderMonitorTests/TooltipMigrationGuardTests.swift`，每条配元测试：

| 守卫 | 判据 | 为什么是这个形状 |
|---|---|---|
| **A 常驻长句棘轮**（只减不增） | 扫 `Views/**`，数"解释性长句仍常驻上屏"的条数：串长 > 24 汉字、走 `subtitle:` / `caption` / `NoteLine` / `DataFootnote` / `DataCaption` 这类可见槽位、且**不在** `.help(` 或 `CopyHelpBadge(` 的实参里 | 用户要的是"看得见的字变少"。用一个可复算的计数代替"感觉清爽了"。基线必须由**某次实扫的现量**填，不许拍脑袋 |
| **B 口径不许丢** | 盘点表 129 条里的键，**每一条必须仍在源码里出现**（可见或 tooltip 皆可） | 防的是把"藏起来"执行成"顺手删了"。B 与 A 是一对：A 只许降、B 一条不许少 |
| **C 核心承诺必须常驻** | 一个显式名单 `mustRemainVisible`：如"取不到的一律显示 `--`，不会补成 0""统计基于非合并提交""默认不联网时漏洞判定恒为 0 条，这是「没有查」，不是「没有病」""启发式加权计算，未调用外部模型"等，断言这些串**不在** help/badge 实参内 | 一旦只有 hover 才看得见，用户就把"没查/算不出/窗口内"读成一个真实的 0 或一个结论。这条是 A 的**上界**：A 想再降，就得先证明没有把 C 里的东西藏起来 |

三条都要 **分母 > 0**（扫不到任何东西 = 扫描器坏了，不是代码干净），
且各配"注入坏样例必须红、合法样例不许误报"的元测试。

## 2. 切片（按**目录**切，互不重叠；每片一个负责人）

| 片 | 页面 | 可写路径 | 条数（盘点表编号） |
|---|---|---|---|
| S1 | 总览与外壳 | `Views/Shell/**`、`Views/DashboardView.swift`、`Views/ProjectDetailView.swift`、`Views/RootView.swift` | A 组 9 |
| S2 | 代码两页 | `Views/Code/**`、`Views/CodeGit/**` | B 17 + C 10 |
| S3 | Git 与贡献者 | `Views/Git/**` | D 14 + E 9 |
| S4 | 依赖 | `Views/Dependencies/**` | H 15 |
| S5 | 性能与日志 | `Views/Performance/**`、`Views/Logs/**`、`Views/PerfLogs/**` | F 25 + G 12 |
| S6 | 健康评分 | `Views/Health/**` | I 18 |

**每片共同的红线**：
- **不得改 `Resources/en.lproj/Localizable.strings`**（唯一写者 = 总工）。
  本片新增的短读数键写进汇报里的《待登记键》清单，由总工在合流时一次性登记。
  理由：6 片同时往一个 `.strings` 追加 = 必冲，而冲突解错的代价是静默丢键。
- 不得改 `Design/**`、`Services/**`、`Models/**`、`Package.swift`、守卫文件。
- 只做"搬"与"删"，**不改任何判据、阈值、数字本身**；`留短藏长` 的短标签要来自原句，不许新造修辞。
- 视图签名 `XxxView(report: ProjectReport?)` 冻结；排版一律走 `View.typed(_:)`；页面零 `#available`。
- 不启动 App（取证格同一时刻一人），改完交《预期视觉变化清单》，由总工排期逐页复拍。

## 3. 每片的验收动作（缺一条按未完成处理）

1. `./scripts/locked_build.sh build --build-tests` 零 error；`test` 全绿（贴尾行真实数字）。
2. 报三个数：**本片 A 棘轮降了多少条 / B 名单是否仍一条不少 / C 名单是否仍全部常驻**。
3. 本片涉及的每个"藏"动作都能指到 `CopyHelpBadge(` 或 `.help(` 一处，**不是**只删了字。
4. 汇报带《待登记键》清单（中文原文，一条不落）。

## 4. 总工在每片合流时做的事

1. 把《待登记键》批量登记进 `Localizable.strings`（英文值完整成句，不接在别人句子后面 ——
   本仓踩过"半句键"：英文语序必坏）。
2. 按实扫现量收紧 A 的基线（**只降不升**，降了要在注释里写"哪一片还的债"）。
3. `premerge_check.sh` 独立树跑全量；合完在 detached 验证树再跑一次兜底。
4. 逐页复拍（`capture_pages_isolated.sh` + `SWITCH_MODE=argv` + 各自沙箱与输出目录），
   并**逐张核亮度与对比度不回归** —— 版面上"少了一块字"会挪动相邻读数带的位置。

## 5. 风险与不做的事

| 风险 | 应对 |
|---|---|
| "藏"之后 hover 不到 = 口径彻底看不见 | C 名单兜底；macOS 的 `.help` 对 `questionmark.circle` 这种小目标命中一般，若实测有难点不藏 |
| 短读数与 tooltip 各说一半，两半都不成立 | 要求短标签必须来自原句，禁止改写；B 守卫保证原句完整存在 |
| 六片同时改 `Localizable.strings` | 见上：唯一写者 = 总工，切片只报键 |
| A 棘轮被"少写字"反向动机利用（干脆不写口径） | B + C 成对；且汇报里每片必须给出"藏到哪去了"的行级指认 |

**不做**：为了少字删掉任何口径说明；把 C 名单里的句子移进 tooltip；
给 tooltip 加投影/材质去"提示可悬停"（全仓投影唯一性与无材质红线不许动）；
在本轮引第三方 popover 库。
