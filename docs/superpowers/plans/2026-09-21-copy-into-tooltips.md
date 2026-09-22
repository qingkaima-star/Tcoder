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

## 6. 集成台账（总工逐片记，数字全部来自守卫自己打印的现量）

尺子播种自 main `14a1f29` 实扫：**A 上界 88 / B 下界 101 / 双语未登记上界 28**。

| 片 | 落 main 的 head | 独立门禁（真实尾行） | 落完之后 A 现量 |
|---|---|---|---|
| 底座 + 三条守卫 | `5b107a6` `fa782da` | 负责人自跑双绿 | 88（播种值） |
| S2 代码两页 | `e161eae` | 970 / 0 | 76 |
| S3 Git 与贡献者 | `c1365ac` | 971 / 0 | 74 |
| S6 健康评分 | 键登记 `2b44d8f` | 随 S3 那趟 | 74 |
| S4 依赖 | `8de2d17` | 987 / 0（本树 84→84，基数早于 S2/S3） | 待合后实扫 |
| 尺子修复 + 扫描面动态化 | `846fe84` | 随片兜底 | 72 |
| S7 总览第二步（三处 + `BannerRow.help:`） | 在跑（`e40afa7` 尺子补齐 + `f554404` 记账改写同批） | 见下 | 62 |
| 双语补账轮（四处 `Text(变量)` 改查表） | `7fc37a7` → 合入 `c4bdc6f` 之前 | 1008 / 0（main 兜底） | 62 |
| S5 性能与日志 | 第一次被拒（尺子误报，见下），修尺子后 `2f3f0f9` | 997 / 0 | 69 |
| S4 依赖 | `8de2d17` | 987 / 0 | 69 |
| S1 总览与外壳 | 在跑（已 2 个提交，本树报 86→83） | — | — |

**合完 main `2b44d8f` 的兜底全量**：detached 验证树 `976` 例、`12` skipped、`0` 失败（`VERIFY_EXIT=0`）。

### 被拒的那一趟（必须留名，否则空目录会被读成"量过了"）

`ws/s5-perflogs` 合入 main 之后门禁红在 `PerfLogsTooltipTests.swift:118`
「合法样例被误报」。**归因不在 S5**：共享尺子的 `sight()` 按**整行**判 hover，
而本轮标准形状 `NoteLine("常驻短句", help: "另一句长口径")` 同一行既有可见槽位又有 hover 槽位 ——
按行判会朝两个方向同时错（常驻那份被记成已藏 → A 虚降；整行记成 hover → B 看不见有人删了常驻句）。
修法在 `ws/i18n-ruler`：`literalSlots(in:)` 逐字面量判槽位、判不出来才退回整行线索，
并补 `test_meta_mixedLineCountsEachLiteralOnItsOwnSlot`。原始失败行留在
`.scratch/s5-gate-refused-2026-09-21.txt`。

### 同一批里顺手补掉的两个共享盲区

1. **双语扫描面写死五个目录**（`Views/Design/App/Services/Models`），而 `Utilities/` 是第六个 ——
   改成 `SurfaceScanKit.sourceFiles(under: "")` 动态枚举，另钉一条元测试
   「六个一级目录一个都不许少」（新增目录自动进来，改名或消失会红）。
2. **ⓘ 的落点躲着双语棘轮**：`CopyHelpBadge(整句)` 与 `help:` / `subtitleHelp:` / `captionHelp:`
   这几个标签都不在入口族里，而这些组件内部替调用方过了 `localizedCopy` ——
   也就是说调用点那句中文**就是键**，扫不到它等于本轮搬进 ⓘ 的字全部隐形。
   入口族补上之后现量要重测：**涨了不是新增债，是多看见的债**（同 `22 → 28` 那次）。

### 建议删除（各片报上来、由总工判；一句未删，B 下界因此仍是 101）

| 片段 | 出处 | 判定 |
|---|---|---|
| 「默认不联网时漏洞判定恒为 0 条…」两处逐字重复 | S4 | **收成一处常量**（去重不是删口径，不进豁免口） |
| `DependencySafetyVerdict.summaryCaption` 的 `.unchecked` 三段 | S4 | 暂不删：与常驻的 `deps.networkLookupNote` 并非逐字同义（截至日/未覆盖生态只在其中一份里） |
| 「内置快照与安全公告均未命中」与安全公告卡空态句同屏两遍 | S4 新发现 | 待复核，删时须同步改 `CodeGitRestyleTests+DependencyAndAbsence` 的等值断言 |

### 双语现量的台账（守卫自己打印，`TCODER_I18N_LEDGER` 落该树 `.scratch/i18n-ledger.txt`）

一天之内动了两次数字，两次都是**实扫现量**：`19 → 21`（S5 合流，搬字那趟新造 2 条内插短句，
新增债在 diff 里显形）→ `21 → 19`（补账轮把四处 `Text(变量)` 改成查表，它们不再是"没登记的串"）。

**现在这 19 条全部是内插短句**，分布 9 个文件：`CodeRiskAdvice` 4、`ShellLayout` 3、
`GitInsightsSections` 3、`CodeRiskView` 2，`LogsMetricGrid` / `LogsErrorClusters` /
`HealthAdviceCards` / `GitInsightsView` / `CodeViewSupport` / `ContributorRows` /
`DependenciesView` 各 1 上下。还法只有一条：逐句改成
`localizedFormat("整句 %1$@ …", …)` —— 键里没有插值，目录才接得住。
**这条就是本轮留给双语流 P6 的收尾线**，不在本轮做是因为每改一句都要重写整句措辞。

### 补账轮顺手补掉的一个真缺陷（`Text(变量)` 不查表）

`PerformanceProcessGroups.swift` 里四处是"变量喂进 `Text`"：内置分组名（「Java 服务」「Node 服务」，
常量住在 `Models/Performance.swift`）、分组三态短标题（纯函数返回的元组）、
以及 `GroupMetricCell` 的 `label` / `caption`。这些位置**登记键也没用**
（键存在≠查得中，双语方案 §7.1），已全部改成 `Text(localizedCopy(…))`，
并登记 3 条键。防回归不是新写一条守卫，而是把该文件加进
`LocalizationGuardTests.renderPointHosts` —— 那条闸门本来就在，判据本体一字未动，
只是**纳管了一个文件**（它原本只管 `Design/**` 加两个点名文件）。

### S7（外壳第二步）交回时的三条判定

| 事项 | 判定 |
|---|---|
| `DashboardLiveReadout.liveReadingsCaliber` 与性能页页头那条键是**同一句话的第二份字面量** | 本轮**不合并**。并成一份常量要把 `Views/Performance/**` 的生产者上提到 `Design/` 或 `Services/`，那是跨流搬代码，不值在收尾做；先由 `ShellReadoutTooltipTests` 钉住两处措辞一致，改哪一处都会红 |
| 暂停态**故意不给 ⓘ**（`cadenceCaliber` 返回 `nil`） | 收下，且这是本片最值钱的一条判断：整句口径的结尾是「点「继续」恢复实时刷新」，而那颗按钮只住在性能页 —— 在总览页挂一句指向本页没有的按钮的指引，是写假指引，比留着长句更坏 |
| `EmptyStateView.message` 改 `String?`（S1 报的契约缺口） | **缓做**。改了要让每个空态调用点重新判"这一页到底要不要屏上那句"，九页已交回，本轮不再动全部调用点；缺口记在此处，下一轮开ⓘ 类组件时一起处理 |

### 两处自伤的疤（写下来，不等别人发现）

1. 尺子那片合进 main 的分支提交 `d8e9ba8` 的说明是 `/tmp/m3.txt` —— 我把 `git commit -F` 写成了
   `-qam <文件>`，参数位被当成消息。合并提交（`846fe84`）用的是 `-F`，内容没丢，
   但分支提交这条疤改不回来（它已是 main 的祖先）。规矩已进记忆：**从文件取消息只写 `-F`，
   提交后回读 `%s`**。
2. S5 那一趟被拒的门禁**只在 `/tmp` 留过日志**，已补 `.scratch/s5-gate-refused-2026-09-21.txt`。

### 收尾时的读数（守卫自己打印，不是我复刻的）

`ⓘ 收纳棘轮：可见长句 62 / 上限 62（tooltip 承载 49 条 / 扫描面 42 个文件）`
→ **总量 111、下界 101：屏上长句从播种的 88 降到 62（−26），一句都没删。**
`双语存量棘轮：现量 19 / 上限 19（已登记键 585）`。

A 的降账逐片：88 →（S2）76 →（S3）74 →（尺子改逐字面量判 + S6 键登记）72 →（S1）69
→（S5 19 处、S4 3 处、S7 3 处）62。S7 那三处**本身没让 A 降**（它量过：屏上短句都在
24 半角宽以内，`commitTile` 那条 27 宽的写在 `report?.git.map { localizedFormat(…) }` 里、
行内没有可见线索）—— 它的净贡献是给 `BannerRow` 开了 `help:` 槽、把三条挂在整条横幅上的
匿名 `.help` 收进可见的问号，以及**点名了 `subtitleHelp:`/`captionHelp:` 不进 A/B 两本账这个洞**。

### S7 交回时抓到我这对成对守卫的一个洞（已修）

`\bhelp\s*:` 撞上的是小写 `help`，而 `subtitleHelp:` / `captionHelp:` 里是大写 `Help`
⇒ 这两个新槽的字面量按「一个参数一行」排版时判成 `.skipped`：**A 与 B 同时看不见**。
B 存在的全部理由就是"别让搬字变成删字"，而这条洞里删掉一句 `captionHelp:` 的整句
不会让总量掉红 —— 洞比 A 漏计严重得多。已由 `e40afa7` 补齐两支正则
（carrier 与逐字面量前缀一起），并把 S7 那条"盲区记账"断言改成正向守护
（`f554404`：五种排版形状必须同向）。S7 一片没踩这个洞（它三格收的都是生产者不是裸字面量），
是它**主动报上来的**。

### ④ 的对表工具已落进仓库（不是 `/tmp` 里的一次性脚本）

`scripts/report_parity.py` —— GUI 落盘那份 `reports/<uuid>.json` 对 `tcoder scan --out`，
逐字段比、**容忍清单逐条点名**（`*At` 时间戳、`project.*` 身份、`code.durationMs` 本次扫描耗时），
不许写成通配。最终头 `baee37c` 上的读数：两边都是「文件 359 · 码行 54,094 · 热点榜 20 项 ·
综合 75 · 代码口径 90 · 分量 6 · 缺席路 []」，**逐项不等 0 处 / 按口径容忍 13 处**。
13 条里要单独点名一条**不是时间戳**的：`project.lastScanAt` 只有 CLI 那份有 ——
GUI 那趟的项目记录是沙箱 `projects.json` 预置的（"上次扫描"由 store 另管），
CLI 那趟是就地造的 `MonitoredProject`。两边都不是判定字段，但把它记成
"identity 子树整体容忍"里的一条，是为了让下一个读表的人不用自己猜。
这把尺子已经抓出两个真缺陷（F10 退出码挂死、F11 榜单尾部不可复现），所以它值得常驻。

## ⑤ 收官：最终头 `dc4c53f` 的交付证明（2026-09-22 02:00–02:01）

F12（CLI 入口不再把读不动的目录报成全零成功）合入后 main 又前进了一笔
`dc4c53f`（同族、另一条流在主树直提：走树时读不动的目录不再等同于"那里没有源码"），
所以**最终头是 `dc4c53f`**，下面每一项都是在这一个头上重跑的读数，不是引用上一轮。

驱动脚本 `.scratch/tools/final_proof.sh`（一次性，跑完自清），六步每步都要出声：

> 补一句时效：合这页文档时 main 又前进到 `79680e6`（P6-R 的 `Views/` 版式规则）。
> 上面六步的读数**全部在 `dc4c53f` 上量得**，不追到新头重跑 —— 理由是那一笔动的是渲染层，
> 它要的重拍是它自己的验收责任（见取证 §2.8 末尾"失效边界"那段），
> 而不是让 WS-CL 的交付证明跟着 main 赛跑。

**文档快修之后按要求补跑的全量兜底**（`MERGE_ALLOW_UNGATED=1` + `MERGE_ALLOW_STALE_BASE=1`
两次显式放行都写着"合完立刻在 main 上跑全量 test"，所以这条不是可选项）：
detached 树 `c56cb6a`（= 我的文档合并头，已含 P6 的 `dc4c53f` 与 `79680e6`）上
`./scripts/locked_build.sh test` →
`Executed 1037 tests, with 12 tests skipped and 0 failures (0 unexpected) in 183.841 (191.265) seconds`，
`TEST_EXIT=0`。比 `64b8828` 那趟（1033）多 4 例 —— 这 4 例来自 `dc4c53f` / `79680e6` 两笔里
新增的用例（**没逐笔归因**，只确认总数与 0 失败）⇒ **main 现在是绿的，
而且绿的是含他们改动的组合**，不只是各自分支的绿。

| 步 | 实测输出（原样摘自日志） |
|---|---|
| 合并前端禁（分支头 `5efc471`，已含 P6 的 `e6bcbac`） | `Executed 1033 tests, with 12 tests skipped and 0 failures (0 unexpected) in 241.032 (328.241) seconds` → `✅ ws/cli-tier4 可以合入 main` |
| 合并后兜底（`64b8828`，detached 树） | `Executed 1033 tests, with 12 tests skipped and 0 failures … in 215.520 (222.923) seconds`，`TEST_EXIT=0`，`Test Case.*failed` 命中 **0 行** |
| release 打包 | `Build complete` 1 次；二进制 `dist/Tcoder.app/Contents/MacOS/TcoderMonitor` |
| provenance | `✅ Info.plist 内 revision == HEAD`、`✅ presign ≠ 交付哈希`、`✅ 架构仅 arm64`（头 = `dc4c53f`） |
| 老路（预置沙箱 → 起 GUI → 等落盘） | 报告 **54,235 字节**；`综合健康分 = 75`、`工程质量(代码口径) = 90`；实例由脚本自己起的 pid 收走（`SCORE_TERM=1`） |
| 新路（一次 CLI `scan`） | 退出码 **0**；报告 **54,179 字节** |
| 逐项对表 | `逐项不等（判败）：0 处 · 按口径容忍（时间戳 / project 身份）：13 处` → `结论：两条路读数逐项一致 ✅`，`report_parity 退出码 = 0` |
| `score` 读数 | 退出码 0；`综合健康分 = 75`、`工程质量（代码口径） = 90`、`缺席维度 3 项`、`漏洞核对：未联网核对…` |

两点要说清，不然数字会被读错：

1. **总体是 `.worktrees/verify-main` 这份工作树**（内容 = `dc4c53f`），不是主仓库目录。
   13 条容忍里 `project.name` 因此是 `'Tcoder（自扫打分）'` vs `'verify-main'` ——
   沙箱里预置的名字与就地造的项目名，两边都不是判定字段。与 `baee37c` 那趟比，
   容忍条数一致（13），判败条数一致（0）。
2. `code.scanLimitations` 在这一次是 **3 条**（`2 个文件被跳过…`、`另有 9 个条目按规则未纳入统计。`、
   `重复率按全量命中计算…`）。第二条是 `dc4c53f` 那一路新长的**上屏句**，
   正是 F13 讲的机制在真实数据上的样子 —— 所以这一轮**照本文件 §1 的规矩重拍了九页**，
   没有用"渲染面差量为空"糊过去（那个论证的漏洞见 §2.8）。

顺带一条正向证据（① 的三态）：`coverage.hasData` 在 JSON 里**整键缺席**而不是 `false`，
`unreadableDirectoryCount = 0` —— "扫到的每个目录都读得动"这次是真话。

