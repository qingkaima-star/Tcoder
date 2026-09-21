# 用自家 CLI 反扫 Tcoder：改进清单

产出：2026-09-21 · 归属：总工（WS-CL）· 输入：`tcoder score` 首跑本仓库

被扫总体（不写清就无法互相比较）：**树 = `.worktrees/cli`（分支 `ws/cli-headless`，
HEAD `9c28245`），构建口径 = debug，文件 335 / 有效码行 50 542 / 提交 672**。
读数：综合 75、工程质量（代码口径）91、在场 6 维、缺席 3 维、端到端 4 秒。

判据分三档：**已落地**（本轮改完并过门禁）／**可修待排**（改法明确，等窗口）／
**记账不动**（登记但不改判据，避免"为了自己好看改尺子"）。

## F1 缺席维度的"为什么"只活在 View 层 —— 已落地（`d1bb9ae`，随 `ddf535a` 合入）

`HealthBreakdown`（挑出哪些维度缺席）、`DimensionDisplay`（显示名映射）、
`MissingDimensionReason`（缺席原因）**全部住在 `Views/Health/HealthComponentTable.swift`**，
而 `Design/DataTable.swift` 的权重列头又要反过来引用 `HealthBreakdown.weightColumnHelp` ——
即 Design → Views 的反向依赖。后果：GUI 界面能告诉用户"运行稳定性缺席，因为未发现可读的日志文件"，
而 CLI / AI 只拿到 6 个分量 + 一句 narrative，读不出那 3 维是"没扫"还是"扫了没产出"。

**改法**：三段按类型整块下移到 `Services/Health/HealthBreakdown.swift`（逐字搬动，不改判据），
界面与 CLI 共用同一份；顺手删掉一个**零调用**的私有函数 `MissingDimensionReason.coverageHasData`
（全文件只出现一次 = 它自己的定义，`private` 决定了外部不可能调它）；
并去掉一条重复了两遍的文档注释行。副产品：`HealthComponentTable.swift` 从 396 行降到约 130 行，
离 400 行闸门有了余量。

**落地后的实测**：搬动前后**逐字节对账**（两文件并起来只比原文少 2 行 = 被删死函数的那两行，
多出 9 行全是新文件头注释）；全量门禁 `931 例 / 0 失败`（比上一轮多的 2 例正是本次两条新断言）；
`HealthComponentTable.swift` 实测 **397 → 131 行**，新文件 275 行；普查分母 141 → 142（台账已记引用方）。

**唯一没照抄的是人称**：原因表里那句「上次扫描「X」失败」讲的是界面上的**历史**报告，
而 CLI 一次性的读数里失败就是**本次** —— 照抄会把本次读成历史账。所以这一类改成
「所属分析路本次失败，原因见上面「失败路」那一行」，并由
`CLIHeadlessTests.test_absentDimensionsPointBackToThisRunsFailures` 双向钉住
（断言明确禁止「上次扫描」出现在 CLI 读数里）。实际输出：

```
综合健康分 = 75
缺席维度 3 项（不参与计分、也不按 0 计入）：运行稳定性 — 未发现可读的日志文件。 ·
依赖健康 — 「依赖分析」完成但该分量未产出。 · 测试覆盖 — 该项目没有产出覆盖率报告，不参与计分。
```

CLI 侧的新读数形状（失败路 → **缺席维度 + 原因** → 综合分）：

```
缺席维度 3 项：运行稳定性 — 未发现可读的日志文件。 · 依赖健康 — … · 测试覆盖 — 该项目没有产出覆盖率报告，不参与计分。
```

## F2 同一屏两个行数分母不打招呼 —— 已落地（`b24f15f`）

CLI 首行「码行 50 542」与注释维度的依据句「…源码 69,199 行，标记扣 2 分」**同一屏并存**，
差的那 19k 行是空行与注释。两个数各自都对，但并排出现而不标口径，读的人（人和 AI 一样）
会把它当成"同一个量的两次读数不一致"。本仓这类事故已经记过不止一次（跨页对同一个量）。

**做法（已做）**：依据句改成「总行 69,199（含空行与注释）」，与首行的「码行」明确成两个名字。
纯文案，阈值与判据一字未动；改前查过没有任何测试钉着旧字面。
新增 `test_theTwoLineDenominatorsNameThemselves` 双向钉住（禁止再出现「源码 N 行」这种两边都能读的说法）。
原以为要等评分流一起做，实测一行改动 + 一条断言就够，没必要挂账。

**当时的定位记录**：那句由 `Services/Health/ScoreCurvesCode.swift` 组装，
其中"注释过多同样扣分"是它的 `band` 取值。**这一条本轮没动**：它是评分依据句、属冻结区
`Services/Health/**` 的文案，且 `HealthScoreTests` 一类守卫钉着措辞，改它应当与评分流一起做、
一次改到位（同时把两处"行数"统一成"总行（含空行与注释）/ 有效码行"两个明确名字）。

## F3 守卫的扫描面靠"按名字点名的目录清单" —— 已落地（`846fe84`）

`LocalizationGuardTests.sourceFiles()` 写死 `["Views", "Design", "App", "Services", "Models"]`。
本轮我把 CLI 放进 `Services/CLI/` 而不是新建顶层 `CLI/`，**正是因为**新建顶层目录会被这把尺子
静默跳过 —— 双语存量棘轮会报"0 违例"，而那个 0 是"没扫到"不是"没有"。
这是本仓已知缺陷类（按名字点名的清单不会自动长大）的又一个实例。

**改法**：改成动态枚举 `Sources/TcoderMonitor/` 的直接子目录 + 保留"分母必须 > 0"的断言 + 配元测试
（造一个"新目录下有未登记中文串"的坏样例，必须被扫到）。
**排队要求**：这条改的是 `LocalizationGuardTests.swift`，双语流 P6-F/G/H 连着三轮都在动它名下，
必须等那条流交回再动，否则两边互相覆盖。

**实际落地的形状（与上面预案的两处偏离，都记下来）**：
① 没有另起一份"枚举直接子目录"的代码，而是改用全站同一把读盘尺子
   `SurfaceScanKit.sourceFiles(under: "")`（它本来就扫整个 `Sources/TcoderMonitor`）——
   少一份实现就少一处会漂的口径；`LocalizationGuardTests+ChineseTypography.swift` 名下那份
   抄来的五目录清单同时删掉，两处并成一处。
② 元测试**没有**用"新造一个带中文串的目录"那种坏样例（那要往仓库里落夹具，
   下一轮扫描会把它当成真存量 —— 本仓在 `/tmp` 夹具上吃过假绿）。改成钉住
   `test_meta_scanSurfaceCoversEveryTopLevelDirectory`：**从守卫自己看见的路径**里取一级目录集合，
   断言六个已知目录一个都不许少。新增目录自动进来（枚举是动态的），
   而目录被改名或整片消失会让存量"假短" —— 那条断言正是钉这个方向的。

**扩口的代价已经结清**：入口族同期补进 `CopyHelpBadge(` 与 `help:` / `subtitleHelp:` /
`captionHelp:` 之后双语现量 17 → 30（多看见 12 条一直在盲区的 ⓘ 键），同日登记 11 条落到 **19**，
棘轮按实扫现量从 28 收到 19。剩下 19 条的构成（17 内插串 + 2 处 `Text(变量)`）记在
`docs/superpowers/plans/2026-09-21-copy-into-tooltips.md` §6，不当已还。

## F4 CLI 复现不了 GUI 的「手动附加日志」—— 已落地（`fa0ba9c`）

`AppState.extraLogURLs` 让界面用户手动指日志文件，CLI 只能吃 `[]`。
于是一个日志不放在 `Logs/error.log`、`crash.log`、`~/Library/Logs` 约定位置的项目，
经 CLI 扫出来「运行稳定性」这一维**永远缺席**，而 AI 不会知道这是入口少了一个参数、
而不是这个项目真的没有日志。属于"入口造成的假无"。

**做法（已做）**：`--log=<file>`（可重复）+ `--window-days=<n>`（默认 7 = `CLIScan.logWindowDays`），
直接映射到 GUI 已有的两个入参，不新增判据。`--log` 指向不存在的文件时**判用法错 64**、不悄悄收下
（悄悄收下 = 让"路径打错"长成"这个项目没有日志"，正是本清单第 4 条要消灭的那种假无）。

实测（同一棵树、同一个 debug 二进制）：不带 `--log` → 综合 75、缺席 3 维含"运行稳定性 — 未发现可读的日志文件"；
带一个真日志文件 → 综合 80、缺席 2 维，运行稳定性进入场，连代码口径那句
"已排除 …、运行稳定性"也跟着变了（同一条判据在两处一起动，没有第二份实现）。

## F5 self_score.sh 换 CLI 之后，GUI 落盘链路少了一把尺子 —— 记账不动

改造前它顺带验证了「报告能写进 `reports/<uuid>.json` 且能被解码」这整条持久化链路；
现在 CLI 零写盘，这条不再被它覆盖。判据本身没有丢失（`ProjectStoreRoundTripTests` 在测同一件事），
所以要写的不是"补一条测试"，而是**把"现在由谁量"落到纸面**，别留下"看起来有人管"的空档。
→ README 的自扫段与 `docs/口径与已知限制.md` 各加一句指明接手者。

## F6 默认不联网时，CLI 读数不提醒"没查 ≠ 没有病" —— 已落地（`d1bb9ae`）

界面依赖页早有那句「默认不联网时漏洞判定恒为 0 条，这是「没有查」，不是「没有病」」，
而 CLI 的 `score` 只把 `networkLookupPerformed=false` 埋在 JSON 里。
AI 读 JSON 不看那个键 = 把"0 条漏洞"当结论。

**改法（已做）**：`score` 文本读数在"结论"之后加一行 `漏洞核对：<分析器自己产出的那句>`，
**文案沿用 `DependencyReport.networkLookupNote`，不在 CLI 里另写一份**；
note 为空时整行不出现（由 `test_offlineVulnerabilityNoteRidesAlongWithTheReadout` 双向钉住：
分析器没说没查时不许凭空造一句）。
**这条与 ⓘ 收纳是同一类问题**：如果界面把这句收进 hover（只有悬停才看得见），
CLI 就更必须把它打在文本读数里 —— 两边的诚实性得一起搬，不能一边藏一边漏。

## F7 综合分没有机器可读的缺席名单 —— 记账 + 提案

`HealthSubScore`（代码口径）带 `includedDimensions` / `excludedDimensions`，
而 `HealthScore`（综合分）只有 `components`。F1 之后**文本读数**能说出缺席原因，
但 `scan` 输出的 JSON 里仍然只有"在场的 6 个"。

**提案**：给 `HealthScore` 加一个 `absentDimensions: [AbsentDimension]?`（**必须 Optional** ——
本仓踩过：带默认值的非 Optional 会让旧报告整份解码失败）。
登记为提案不落地：动 `Models/**` 落盘契约要连带界面、评分器、旧报告兼容三处，
不是一轮 CLI 的账。**不许**为此改用"从 components 反推"的派生口径 —— 那是第二把尺子。

## F8 本轮新造的 ⓘ 落点整片躲着双语棘轮 —— 已落地（`846fe84` + `7fc37a7`）

「碎文案收进 ⓘ」这一轮把长句搬进 `CopyHelpBadge(整句)` 与 `help:` / `subtitleHelp:` /
`captionHelp:` 这些槽位，而这些**标签与位置参数一个都不在双语守卫的入口族里**。
组件内部确实替调用方过了 `localizedCopy`（`Design/CopyHelp.swift` 的规矩 2），
所以调用点那句中文**就是键** —— 但扫不到它就等于：**本轮搬进 ⓘ 的字的英文译文有没有登记，
没有任何一把尺子知道**。把入口族补全之后实扫现量 17 → 30（多看见 12 条一直在盲区的存量），
同日登记 11 条落到 **19**；S5 合流涨回 21，补账轮登记「Java 服务」「Node 服务」两条
（它们本来就在台账里，只是被 `title:` 入口扫到）又落回 **19**（`unregisteredLiteralCeiling`，
只由总工改；中间那次 19 → 21 是 S5 搬字新造 2 条内插短句，属**新增债显形**，不是放宽）。

**判据留一条**：扩扫描面/入口族会让存量涨。涨的数字必须是**某次实扫的现量**、
必须在提交说明与注释里写清"多看见的"还是"新造的"，两者都不是"闸门坏了"。

## F9 「登记了键却查不中」的 `Text(变量)` 形状 —— 已落地（`7fc37a7`）

`PerformanceProcessGroups.swift` 四处是变量喂进 `Text`：内置分组名（常量住在
`Models/Performance.swift`）、分组三态短标题（纯函数返回的元组）、`GroupMetricCell`
的 `label` / `caption`。这些位置**登记键也没用**（双语方案 §7.1：`Text(变量)` 走 verbatim，
不查表），英文态就是中文。全部改成 `Text(localizedCopy(…))` 并登记 3 条键。

防回归**没有新写守卫**：`LocalizationGuardTests` 名下本来就有
`test_designRenderPointsActuallyLookUpTheCatalog`（专抓 `Text(变量)`），
只是它按文件点名纳管，这个文件不在名单里。把文件加进 `renderPointHosts` 即可 ——
判据本体一字未动。**"仓库里已经有这把尺子"不等于"它量到了你这儿"**，
这是本仓"按名字点名的清单不会自动长大"缺陷类的又一次实测。

## F10 "四档退出码"只有 in-process 证据；真二进制里第 3 档挂死 —— 已修（本轮 P0）

交付时我写过两句"已验证"：`CLIHeadlessTests` 20 条全绿覆盖四档退出码，
以及设计文档 §2 说"CLI 生命周期挂在 `App.init()` 上"这个风险**已由 §1 的 spike 证伪**。
两句都不成立。2026-09-21 深夜对 release 二进制（`provenance: rev=e929a47 clean=true`）
做完成度审计时实测：

```
$ dist/Tcoder.app/Contents/MacOS/TcoderMonitor score /Users/one/does-not-exist
（16 分钟不出声；0.6 秒 CPU；无子进程；
 fd 上开着 /private/var/folders/…/T/com.tcoder.monitor.savedState/{data.data,windows.plist}）
```

连我自己写的 600 秒 `CLIConfig.hardTimeout` 都没出声 —— 说明卡点不在信号量，
而在 `exit()` 与 AppKit 窗口状态恢复互等：`App.init()` 被调到的那一刻启动流程还没走完。
20 条单测全绿的原因很简单：**它们在同一进程里直接调 `CLIRouter.main`，从不经过 `@main` 那条路**。
而 spike 跑的是"真干了 1 秒活的那一档"，没跑**即时返回**的那几档（rc3 / rc64 / `--version`）——
**"我验过一条"被我写成了"这个机制没问题"**，这是本条真正的病灶。

**修法（`f7bd835`，一处治因一处治果）**：① 新增 `App/TcoderEntry.swift` 持有 `@main`，
命中子命令词就在**任何 AppKit 之前**跑完退出，否则原样把控制权交给 `TcoderMonitorApp.main()`
（GUI 一字不动）；② `CLIRouter.runReport` 把路径校验提到**装信号量之前**同步回 3，
"根本没开跑"这一档不许依赖并发池。普查分母 143 → 144、`frameworkWhitelist` 随之换名。

**新增的尺子（本仓第一次真把交付二进制起来测）**：`Tests/TcoderMonitorTests/CLIProcessTests.swift`
6 条真·子进程断言，每条带**墙钟上限**（超时即判败）：rc3 用时 0.123 秒、rc64 0.124 秒、
`--version` 0.119 秒、`doctor` 0.599 秒、自建临时小仓库 `score` ⇒ rc2 且读数在（0.607 秒）、
以及"无头调用前后 `savedState` 目录 mtime 一字不动"。拿不到被测产物**判败不许跳过**。

## F11 热点榜的**尾部**不可复现：并列项只听输入顺序 —— 已修（`1c6668d`）

新老两条路逐项对表（GUI 落盘那份 vs `tcoder scan --out`）时，唯一对不上的一项是
`code.topComplexFunctions[19]`：一次是 `parseTarget`(31 行 · 3 参)，一次是
`gradleDependencies`(60 行 · 2 参)。同一条 CLI 连扫三次互相一致，但对上 GUI 那一趟就差这一项。

根因不在这条路上，在**排序本身**：`rankedHotspots` 只有「复杂度、行数」两把键，
CC=14 的一大群函数正好挤在 20 名的截断线上，而 **Swift 的 `sorted` 不是稳定排序**、
五路并发扫完的合并顺序也不固定。于是"谁在第 20 名"由输入顺序决定 ——
而界面上那 20 行是**指名道姓列出来的**，读的人以为那是一份确定的榜。

**修法**：并列时按 路径 → 起始行 → 函数名 定序（**阈值与上限一字未动**，
还是前 20、还是 CC 判级）。补 `HotspotRankingDeterminismTests` 两条，并做了一次 A/B：
旧写法下它**红 2 条**并点名那对并列项（`perf_trace_xml.py:159` / `ShellGitAnalyzer.swift:187`），
补键之后绿；榜里实有 3 对并列由 tie-break 定序 ⇒ 判据不是永真。

**推广（这条比修 itself 更值钱）**：任何"截断 + 展示前 N 名"的读数，
比较器必须构成**全序**。只写主键的排序在单测里几乎总能过（同一份输入顺序固定），
只有在并发采集或换一条入口路径时才露馅 —— 所以"两条路对同一总体逐项一致"这种对表
本身就是抓这类缺陷的尺子，值得为它留一条常驻脚本。

## F12 存在但读不了的目录，被四路当成"空仓库"报成功 —— 已修（`835557b`）

这条是**为了写"第 4 档在真二进制里也得验"而探夹具时撞出来的**，不是读代码读出来的。

`fileExists(atPath:)` 对 `chmod 000` 的目录返回 `true`，所以 `CLIScan.validatedURL` 只查
"存在 + 是目录"就把这个路径放行了。后果不是"报错不够准"，而是：

```
$ TcoderMonitor scan <一个读不了的目录> --compact
code: 键在 · totalFiles 0 · codeLines 0 · scannedAt 有值
failedSections: ["Git 分析"]        # 只有 Git 那路真的喊了失败
logs / dependencies / coverage: 全部存在，全部是零
退出码 2
```

也就是说**四路各自交出"成功但全零"的读数**。界面拿到这份报告会画出一页
"0 个文件 · 0 行"——那是一副"这个仓库是空的"的样子，而不是"我没读到"的样子。
本仓为「空态伪装成健康值」记过一整条账（`--` 而不是 0、缺证据不给满分），
这是它的**入口版本**：缺陷不在渲染层，在"谁替'读不到'说了句话"。

**修法只一行判据**：`validatedURL` 在存在性之外再单独问一次 `isReadableFile`，
不可读就地走第 3 档（消息原本就写着"不存在、不是目录或不可读"）。
**没动任何阈值、上限或评分判据。** 两层各补一条测试（单元层 + 真进程层），
并做 A/B：撤掉那一行，真进程那条当场红。修复后 `score <chmod 000 目录>` ⇒ rc=3、
stderr 含「不可读」，0.1 秒内返回。

**没修的那一半（记账，别当成已了结）**：单个文件读不了时各分析器仍然"跳过并继续"，
所以"部分可读"的仓库还是会少报文件数而不吭声。那属于
`CodeMetrics.scanLimitations`（P7-C 刚开的字段）该管的事 ——
**要连着界面与评分一起接，不是 CLI 一轮的账**。这里写清楚，是为了不让 F12 的
"已修"被读成"零读数问题全解决了"。

## 一句话结论

CLI 这一轮真正的收益不是"省了 300 秒"，而是**把界面里那些只画给人看的诚实性说明
（F1 缺席原因、F6 没查≠没病）逼成了必须有机器可读出口的东西** ——
凡是只有 hover 或只有界面能看见的口径说明，AI 一律读不到，而它不会像人一样去猜。
F10 是同一句话的反面教材：**只有函数返回值能看见的证据，也一律不算交付证据** ——
AI 调用方拿到的是进程，它等到的是"命令不回、退出码永远等不到"。
