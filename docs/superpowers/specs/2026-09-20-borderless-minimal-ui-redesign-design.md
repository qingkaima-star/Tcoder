# Tcoder 全站 UI 重构 · 简约无界（Borderless Minimal）

- 状态：待评审
- 日期：2026-09-20
- 负责人：总工程师（设计总监角色）
- 基线提交：`465f5a6`
- 参考锚点：用户提供的 Ledgerix 财务面板实拍（iPad），风格定性为「简约无界」

---

## 0. 为什么必须重做，而不是继续还债

上一轮（WS-G/H/I/K/L/M）已经把**设计纪律**还清了。实测：

| 指标 | 当前值 | 结论 |
|---|---|---|
| `Design/` 里 `.shadow(` 调用 | 1 处 | 令牌纪律已达标 |
| `Views/` 里裸 `Color(red:)/hex/white` | 3 处 | 已达标 |
| `Views/` 里硬编码 `.padding(_, N)` | 0 处 | 已达标 |
| `Views/` 里裸 `Font.system(size:)` | 2 处 | 已达标 |

**所以这一轮的病因不是"页面没守规范"，而是"规范本身定错了"。** 继续加令牌、加守卫不会让界面变好看。以下五条根因都有取样数字。

### 根因 ① 明暗关系是反的 → 「黑黢黢、脏」

从用户实拍逐点取样（`/tmp/pixsample`，AppKit 直读像素）：

| 位置 | 实测 | 与上一层对比 |
|---|---|---|
| 窗口/内容底 | `#FFFFFF` → `#F8F8F8` | — |
| 内容卡 `.content` | `#E9EBED` | **1.07:1** |
| tile / 导航 chip `.contentInset` | `#E3E5E7` | **1.05:1** |

人眼要 ≥ ~1.15:1 才读得出"这是另一层"。现在每层只差 6–13 个 RGB 阶，且**每一层都比窗口白底更暗**，叠三层必糊成脏灰。

成因代码：`Design/Glass.swift` 的 `View.surface(layer:shape:)` 把 `.content` 与 `.contentInset` 都路由到 `materialLayer(material: .regular, …)`；`Glass.materialLayer` 又给 `.contentInset` 叠一层 `Color.primary.opacity(dimmed ? 0.03 : 0)`。macOS 上材质背后无内容时退化为一平涂半透明灰。

**讽刺处**：`Theme.Palette.Surface.card`（`controlBackgroundColor`，正确的实心卡色）在 `ThemeTokens.swift` 的 `Theme.Palette.Surface` 里定义好了，**全仓零引用**。

对照参考图：整页只有**一个**地面色 `#F1F1F3`（两处取样对比 **1.00:1**，即零卡面填充）。

### 根因 ② 一行代码 = 约 80 处投影

`Glass.materialLayer` 尾巴上那条 `.shadow`（全仓唯一一处），而**三个层都走这个函数**。实测调用面：

- `GlassSection` **40 处**（每个内部再套一个 `GlassCard` → 双层）
- `MetricTile` **29 处**
- 显式 `surface(layer:)` 14 处

→ 一屏叠十几个投影，卡里套 tile 就是双投影。这就是"滥用投影"。

### 根因 ③ 没有主次：三分之二的文字挤在 10–12pt

全仓 `Theme.Typo.*` 引用 122 次的分布：

| 档位 | 次数 | 字号 |
|---|---|---|
| `label` + `monoSmall` + `microLabel` + `narrative` | **82（67%）** | 10–12pt |
| `cardTitle` + `pageTitle` + `body` | 14 | 13–17pt |
| `heroMetric` + `metricNumber` + `metricMid` | **7（6%）** | 28–40pt |

最大/最小字号跨度只有 **4:1**。参考图是 **~19:1**，且 `heroMetric` 全仓仅 3 处调用。

同时**最重的墨没有给最大的数**：参考图全页最暗像素 `#000000`，落在最大的数字上，墨/底对比 **18.6:1**；Tcoder 全页最暗 `#2F2F2F`，落在小号正文上，而最大的数字（`182,430`）被涂成 `info` 蓝 `0x0A5BCC`（`DashboardView.codeScaleCard`），墨/底对比只有 **10.7:1**。

彩色占比两家其实接近（参考 1.26% vs Tcoder 1.66%）——**所以"简约无界"的杠杆不是去色，是"最重的墨给最重要的数"。**

### 根因 ④ 蓝色同时是数据色和交互色

`Theme.Semantic.info/accent` 被涂在数字/图标上共 **36 处**（CPU、内存、提交数、代码行数、SHA、进程名……）。仓库自己在 WS-H §5.2 定过「一色一义」，健康色阶的蓝档为此被删掉了（`Theme.Semantic.role(forScore:)`），但**指标 tile 漏了**。

### 根因 ⑤ 间距没有"呼吸档"，且侧栏不像 macOS 侧栏

`Theme.Spacing.section = 40` 定义了却**零引用**。总览里主区块之间用 `md`(16)、网格里用 `gutter`(12)，与卡片**内部**条目间距同一个数——没有任何东西告诉眼睛"一组在这里结束"。这就是拥挤的机械成因。

`ProjectSidebar.ProjectRow.body`把每行包成 48pt 高的材质胶囊 + 自带投影。系统侧栏本是**无边框文字行 + 原生选中胶囊**。

---

## 1. 风格契约（八条，逐条可反查）

1. **单一地面**。全页一层底色：浅 `#F1F1F3` / 深 `#1C1C1E`。内容区不存在第二种填充。
2. **分组只靠 micro-label + 留白**。分区标题 = 10pt medium + 字间距 `0.06em` + `.secondary`；**无卡面、无描边、无图标底色**。
3. **井是唯一例外**。表格 / 日志列表 / 代码块允许一层 `#EAEAEC`（浅）/ `#2A2A2C`（深）+ 0.5pt 分隔线。除此之外无面。
4. **墨色阶梯**：`heroMetric 56` → `metricNumber 34` → `body 13` → `microLabel 10`（跨度 4:1 → **5.6:1**）。主读数一律 `.primary` 纯墨。
5. **颜色只承载语义**。健康分档、风险徽标、日志等级、增/删可以有色；数据序列默认灰阶，只在需要区分类别时上色。
6. **投影全仓 1 处**，只给浮层（`.floating`）。
7. **导航安静且原生**。删掉顶部 9 枚 chip 条；侧栏纯文字行 + 系统原生选中，零胶囊零投影。
8. **节奏**：页边距 24 / 分组间 32 / 页级段落 40 / 组内 16 / 列表行 8。

### 1.1 对既有规范的两处修订（以设计总监身份改，并备案）

- **修订 WS-H §4 的卡标题档**：原 `cardTitle` 13pt semibold 作分区标题 → 改 10pt medium + tracking 的 micro-label。理由：无界风格里标题是**唯一的分组线索**，它必须比内容轻、比内容安静，而不是更像一块面板。
- **修订 WS-H §9 的内容层材质**：原「内容层 = 标准材质 `.regularMaterial`」→ 改「内容层 = 无填充」。原判断的依据（Apple「Don't use Liquid Glass in the content layer」）是对的，但结论错在**用材质替代了实心色**；正确解法是内容层根本不画面。

### 1.2 两处刻意偏离参考图（已报备）

- **保留 macOS 原生侧栏**，不抄 iPad 顶部 icon rail。9 个中文页名不能只给图标；项目列表 + 拖放添加是真功能（`ProjectSidebar.body` 上的 `dropDestination`）。「导航安静」用原生 source list 达成。
- **不把彩色砍到零**。Tcoder 是监控工具，红=危险是功能线；砍了会违反仓库自己的「色 + 文字 + 图标三通道」（`Design/SharedComponents.swift` 的 `RiskBadge`）与评分诚实性线。第 5 条是「结构去色、语义留色」。

---

## 2. 基座改造（总工单点提交，先落 main）

**这是本轮唯一的串行前置。** 三家页面流必须在它之上开工，否则三家会同时改 `Design/**` 而互相覆盖。

### 2.1 `Design/Glass.swift`：表面系统换血

`GlassLayer` 四个 case，**保留既有 case 名**，这样 40 处 `GlassSection` / 29 处 `MetricTile` 调用点不必同时改就集体变干净：

| case | 新语义 | 浅 | 深 | 描边 | 投影 |
|---|---|---|---|---|---|
| `.content` | 无填充（`Color.clear`） | — | — | 无 | **无** |
| `.contentInset` | 实心井 | `#EAEAEC` | `#2A2A2C` | 0.5pt `separator` | 无 |
| `.chrome` | 控件层 | macOS 26 真玻璃不变；≤15 兜底改实心 `controlBackgroundColor` + 0.5pt 描边 | 同左 | 兜底有 | **无** |
| `.floating`（新增） | 浮层 | 真玻璃 / 实心 + 唯一投影 | 同左 | — | **唯一允许** |

- 把 `.shadow` 从 `materialLayer` 的公共尾巴**移进 `.floating` 专属分支**。
- 删掉 `.contentInset` 上的 `Color.primary.opacity(0.03)` 压暗层。

两个新地面令牌：

| 令牌 | 浅 | 深 | 用途 |
|---|---|---|---|
| `Surface.ground` | `#F1F1F3` | `#1C1C1E` | 唯一页面底色 |
| `Surface.ink` | `#0A0A0A` | `#F2F2F5` | 主读数专用 |

**为什么 `ink` 不能就用 `.primary`**：macOS 的 `labelColor` 是 85% 不透明黑，铺在 `#F1F1F3` 上合成出来约 `#262626`——正是当前全页最暗像素 `#2F2F2F` 的来源。参考图最暗像素是 `#000000`。所以 34pt 及以上的主读数必须显式用 `ink`，`.primary` 只给 13pt 以下正文。

**分工**：基座提交（M0）只**定义** `ground` 与 `ink` 并让 `.contentInset` 用上 `well`；把 `ground` **挂到滚动容器**上属 `ProjectDetailView`，归 WS-O 在 M1 做。

### 2.2 `Design/ThemeTokens.swift`：令牌变更

```
新增  Surface.ground / Surface.well / Surface.ink
改    Typo.heroMetric   40 → 56
改    Typo.metricNumber 28 → 34
改    Spacing.group     = 32   （新，主分组间距）
启用  Spacing.section   = 40   （原零引用）
改    Spacing.pageMargin      = 24
改    Layout.maxWidthOverview = 1200
删    Elevation.card / .raised（只留 .overlay 给 .floating）
```

`Typo` 新增 `groupLabel`（10pt medium + tracking 0.06 + `.secondary`）作为分区标题的唯一档。

### 2.3 `Design/SharedComponents.swift` / `GlassComponents.swift`

- `MetricTile` → **去掉 `.surface()`**，改为 `label(10) / 数字(34, `.primary`) / caption(11, `.secondary`)` 三行无边框。禁止 `.tertiary`。
- 新增 `ReadoutStrip`：横向若干 `MetricTile`，列间 0.5pt 分隔线，对标活动监视器底栏。
- `GlassSection` → 保留签名 `GlassSection(_ title:subtitle:icon:trailing:content:)`，body 改为「`groupLabel` 标题 + 内容」，**不画面、不加投影**。`icon` 参数保留但默认灰色、不再涂 accent。
- `SemanticBadge` 保留（它是语义色 + 文字 + 图标三通道的载体，属于第 5 条的"语义留色"侧）。

### 2.4 表格系统上提（解掉跨流耦合）

`Views/CodeGit/CodeGitTable.swift` → **`Design/DataTable.swift`**。

理由：`DataTableHeader` / `DataColumn` 被 10 个文件跨 6 个目录引用（Code / Git / Dependencies / Logs / Performance / Health / PerfLogs / CodeGit）。留在 `Views/CodeGit/` 意味着 WS-P 拥有它、另两家只能被动受影响。AGENTS.md 已把这条标为「归属错位，上提进 `Design/` 需总工拍板」——本轮即拍板。

**连带义务**：`TableHeaderConvergenceTests` 钉的是「只许存在一套列头系统」，上提后断言仍成立，但它若含**路径假设**必须同步改。改完必须单独跑一次并**人为制造一次重复实现确认它会红**——否则就是把守卫改成了假绿（见记忆 [[tcoder-scan-tests-need-meta-test]]）。

---

## 3. 导航与外壳

- 侧栏两个分组：`Section("项目")` + `Section("分析视图")`（9 行）。
- **`DetailSection` 枚举、`rawValue` 中文页名、`@AppStorage("selectedDetailSection")` 全部不动** → `capture_pages_isolated.sh` 的 `-selectedDetailSection` 传页继续可用，九页取证链路不破。
- `ProjectRow` 删掉 `.surface()` 与 48pt 胶囊，行高收到 30pt，让 `.listStyle(.sidebar)` 画原生选中。
- 视图行用手动选中态（`List(selection:)` 只能有一根绑定，项目与视图是两个选择轴）：选中 = 原生 accent 淡底胶囊 + `.primary` 文字；未选中 = 纯文字。
- `isReachable(reportAvailable:)` 纯函数及其守卫**平移**到视图行，不许删。
- `SectionNav.swift` 的 chip 条整体删除；`ProgressOverlay` 改用 `.floating`。
- `ProjectDetailView` 头部：项目名 20pt + 路径/分析时间一行 11pt，**不再挂 chip 条**，腾出的 44pt 还给内容区。

---

## 4. 逐页重排要求

### 4.1 已验证的具体病灶（总工实读）

**总览 `DashboardView.swift`**
- 结构是「hero 卡 + 4 tile + 4 卡」，全部同一表面重量，无主次。
- `DashboardView.codeScaleCard` 的 `182,430` 涂 `info` 蓝 → 改 `Surface.ink`。
- `代码规模` 一张卡塞了 28pt 大数 + 5 条占比 + 3 个 `StatLine` + 覆盖率 4 行说明 → **拆成分组**，覆盖率口径说明降为脚注层（10pt）。
- 四枚 tile → 一条 `ReadoutStrip`。
- 主区块间距 `md`(16) → `group`(32)。
- `#37`/`#38` 的诚实性文案（口径说明、报告生成时间、含测试代码对比）**一个字都不许删**，只许降排版层级。

**侧栏**：见 §3。

### 4.2 其余七页：按契约自查，不许照抄旧结构

各流对自己名下页面**逐条量**这四件事，并在交付报告里给出改动前后数字：

1. 该页 `GlassSection` 数量与最大字号 → 是否出现「两个 28pt 争位」或「全是 10–12pt」。
2. `.tertiary` 是否落在**测得值**上（路径、时间戳可以；数字不行）。
3. 倾向色是否涂在非语义数据上。
4. 单组内容量：一组里超过 **6 行同类条目**就拆组或收进可展开区。

各页既有**功能性与诚实性**内容（WS-D/WS-R 的修正、`historyTruncated` 窗口标注、`ShellCopy` 三态句式、UTC 分桶口径、零证据不得给满分）**一律保留**。本轮是重排与去面，**不得借美化之名删信息**。任何一条被删，视为返工。

---

## 5. 并行结构

### 5.1 前置（不占三家名额）

总工在 main 落 §2 的基座提交，双绿 + 表格上提 + 守卫自证。三家从该提交切树。

### 5.2 三条流（各 ≤3 子代理、各一工作树）

| 流 | 负责 | 可写路径 | Obsidian |
|---|---|---|---|
| **WS-O** 外壳与总览 | 侧栏 source list、删 chip 条、总览重排 | `Views/RootView.swift`、`Views/ProjectDetailView.swift`、`Views/DashboardView.swift`、`Views/Shell/**` | 新建 `80 WS-O 外壳与总览无界化.md` |
| **WS-P** 代码与 Git 五页 | 代码规模 / 复杂度风险 / Git 洞察 / 贡献者 / 依赖 | `Views/Code/**`、`Views/Git/**`、`Views/Dependencies/**`、`Views/CodeGit/**`（`CodeGitTable.swift` 已被上提，此处只剩页面） | 新建 `82 WS-P 代码与Git五页无界化.md` |
| **WS-W** 性能·日志·评分 | 杀手功能三页 | `Views/Performance/**`、`Views/Logs/**`、`Views/Health/**`、`Views/PerfLogs/**` | 新建 `84 WS-W 性能日志评分无界化.md` |

三家共同红线（沿用 AGENTS.md §3）：

- 不得改 `Design/**` 与 `App/Theme.swift`（基座归总工）；不得改 `Services/**`、`Models/**`、`Package.swift`。
- 视图签名 `XxxView(report: ProjectReport?)` 冻结。
- 新文件 ≤ 800 行（`SelfScanDogfoodTests` 棘轮 `ceiling = 0`）。
- **拍图必须 `SWITCH_MODE=argv` + 各自 `CAPTURE_SANDBOX` + 各自输出目录**。`single` 模式会 `defaults write com.tcoder.monitor`，那是全机共享域，三家会互相改页。
- 一家之内同一时刻只跑 1 个编译；活跃对话 ≤ 3。
- 交回前先 `git merge main`（门禁 `merge_stream.sh` 已机器断言「main 须是被测头祖先」），再跑双绿 + `premerge_check.sh`。
- 合入由总工执行；完成后各自 `git worktree remove`。

---

## 6. 验收判据

### 6.1 机械反查（守卫测试，三家各写自己名下）

| 判据 | 现在 | 目标 |
|---|---|---|
| `Design/` 内 `.shadow(` 出现处 | 1 处 × 约 80 个调用点 | 只允许在 `.floating` 分支内 |
| 内容面数（`.content` 渲染的填充） | 材质灰 3 层 | **0**（`Color.clear`） |
| `Theme.Palette.Surface.well` 引用数 | — | **> 0**，M0 即成立（`.contentInset` 就是它） |
| `Theme.Palette.Surface.ground` 引用数 | — | **> 0**，此条**归 M2 由总工断言**（M0 只定义不接线，M1 由 WS-O 挂到 `ProjectDetailView`；在 M0 就断言会逼出假接线） |
| 承载测得值的 `Text` 上的 `.tertiary` | 42 处 `.tertiary` | **0** |
| 数字被涂 `info/accent` | 36 处 | **0**（语义状态除外） |
| `Spacing.section` 引用数 | 0 | **> 0** |
| 相邻分组间垂直间距 | 16 | **≥ 24** |
| 全仓 `Typo` 大字档（hero/metricNumber/metricMid）引用占比 | 6% | **≥ 12%** |

**每条守卫都要配元测试**（故意造一个违规样本确认它会红）。理由见记忆 [[tcoder-scan-tests-need-meta-test]]：本轮的病因之一就是"令牌定义了但零引用"，而旧守卫只查"有没有散写魔法数"，查不出"定义了没人用"这一类。

### 6.2 截图读数（报告，不是闸门）

`scripts/pixel_audit.swift` 对每张截图打印「大面积明度众数 + 最暗像素落点」，
**退出码恒为 0**。它是给人看的读数，不做 pass/fail。

这一条是标定失败换来的，写下来防止有人再把它改回闸门：

| 试过的判据 | 结果 |
|---|---|
| 版心两两对比 > 1.10:1 即判存在卡面填充 | 拿重构前旧图跑**判通过**——"脏"本身就是 1.05:1 的微差 |
| 大面积明度众数 ≥ 3 即判地面不唯一 | 旧图只剩 2 个众数（差得太近被并进同档）；而对照用的参考图判 3 个失败——那张是**手持平板的照片**，含黑边框与手指 |

**结论**：1.05:1 级别的分层丢失，像素采样判不准。机械判定全部落在 §6.1 的源码守卫上
（`.shadow(` 处数、材质字符串、零引用令牌——这些是离散事实，可以精确断言并配元测试），
视觉结论落在 §6.3 的人眼核对上。**读数仍要出**，因为"改前 219@72% 207@14% / 改后应当
众数收敛到 1 个"这种趋势，人眼看数字比看图快。

### 6.3 目视核对

每家交《预期视觉变化清单》+ 九页（名下页）× 深浅截图；总工目视核对后才合。最终由总工跑一次完整 `capture_pages_isolated.sh` 出交付基准，更新 `docs/九页实拍读数.md`。

---

## 7. 风险与备案

1. **`.content` 变无填充会让 8 页瞬间"塌成一条长滚动带"**。这是设计意图，但要求三家同时完成重分组——基座提交后、三家交回前，main 上的界面是过渡态。故基座提交**不单独作为交付里程碑**，只有三家合完才算一轮完成。
2. **既有测试会大面积变红**。`DesignTokenTests`、`DesignKitTests`、`CodeGitRestyleTests`、`PerformanceDesignDebtGuardTests`、`HealthDisplayTests`、`LogsDisplayTests`、`PerformanceDisplayTests` 钉的是**当前值**（字号、材质、投影）。基座提交里由总工一并更新；页面级断言归各流。
3. **`heroMetric` 40→56 会撑破现有布局**，尤其窄列。若某页放不下，该页降一档用 `metricNumber`(34)，**不许回头改令牌值**，把缺口报总工。
4. **中文在 56pt 下偏笨重**（参考图是拉丁数字）。故 `heroMetric` 只用于**纯数字**读数；含中文标签的标题一律 ≤ 20pt。
5. **部署下限 macOS 14 不变**。真玻璃只在 `.chrome`/`.floating` 的 `#available(macOS 26)` 分支，闸门仍集中在 `Glass.swift`。本轮把内容层改成实心色后，**14/15/26 三套系统的内容观感反而完全一致**（原来不一致，材质在不同版本折射不同）。
6. **`TableHeaderConvergenceTests` 路径假设**：见 §2.4，改完必须自证不是假绿。

---

## 8. 里程碑

- **M0**（总工）：基座提交落 main = §2 全部 + §6.1 的基座侧守卫。判据：双绿 + 守卫自证。
- **M1**（三家并行）：各自名下页面按 §1 契约与 §4.2 自查清单重排 + 各自守卫 + 各自九页×深浅截图。判据：双绿 + `merge main` + `premerge_check.sh` 过。
- **M2**（总工）：依次合入 → 跑完整九页取证 → 更新 `docs/九页实拍读数.md` 与 `README.md` → 清三家工作树（判据 `ahead=0` 且 `dirty=0`，用 `git branch -d`）。
- **M3**（可选后续）：`docs/使用说明.md` 与 WS-H 规范笔记同步本轮两处修订。
