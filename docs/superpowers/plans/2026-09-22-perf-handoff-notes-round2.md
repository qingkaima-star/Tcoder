# 性能侧 → UI 总工的交接备忘（第二轮：2026-09-22 中午起）

> 从 [`2026-09-21-perf-handoff-notes.md`](./2026-09-21-perf-handoff-notes.md) 拆出来的一截，
> **拆的原因是 `SelfScanDogfoodTests` 的 ≤800 行棘轮分母含 `.md`、ceiling=0**：
> 本篇涨到 810 行，按"拆，不拧阈值"的既有裁定处理（同一形状 2026-09-21 已经用过一次）。
> 逐字节搬动，§N~§U 的文字与第一轮那篇一致，没有改写；前半截（§A~§M）留在原文件。
> 工单本体：[`2026-09-20-perf-followup-tickets.md`](./2026-09-20-perf-followup-tickets.md)

## §N（2026-09-22 12:44）一条尺子拆成两条 —— 附赠一份"别去做这趟假还债"的告示

### 我要点单的那件事本来不存在

并完 main 之后我把渲染路径台账按文件聚合，`dynamicNSColor 62` 里有 **8 处落在 `Design/**`**。
AGENTS 的分工写的是「`Design/**` 取值归 UI 侧；**`Design/**` 内部缓存化归性能侧**」，
于是我准备把这 8 处做成缓存 `static let`，把数字从 62 抬到 54 并顺手拧基线。

**动手前查了一下它们到底在做什么，结论是这趟是假的**：

| 环节 | 现状 | 每次访问的成本 |
|---|---|---|
| `Theme.Semantic.role(for:)` | `switch` 返回 `static let accent/success/…` | 无分配 |
| `SemanticRole.textColor` | `var … { text.color }`，而 `text` 是 `let DualColor` | 一次存储属性读 |
| `DualColor.color` | `let color`，在 **init** 里由 `makeDynamicNSColor` 算好 | 无分配 |

⇒ 62 处**没有一处**在渲染路径上 new `NSColor`。做那趟"缓存化"只会让台账少 8 行、运行时一个字节都不省，
而且我会把它报成"还掉 8 处债"。**这就是假还债**，数字变了但代码没变好。

### 同一件事的另一半：该红的从来没有尺子

`dynamicNSColor` 的模式是 `\.(textColor|graphicColor|badgeFill|onFillColor)\b`——**纯引用**。
而真·现造的形状 `Color(nsColor:` 不在任何模式里（`directFormatters` 只列
`NSColor|DateFormatter|NumberFormatter` 后跟 `(`，`Color(` 不匹配）。现扫当场抓到 2 处：

```
Views/Shell/ProjectSidebar.swift:222  isDropTargeted ? Theme.Semantic.accent.textColor : Color(nsColor: .separatorColor)
Views/Shell/SidebarRows.swift:89      ? Color(nsColor: .quaternaryLabelColor)
```

⇒ 一条尺子同时量"现造"和"引用"，结果是**该红的漏了（0 处判据覆盖真债）、该绿的挡路**
（顶到 62/62 零余量后，谁在 body 里新写一处**正确**的令牌取色就把闸门打红）。

### 已改（性能侧名下，不碰 `Views/**`）

- `PerfHitchScan.rules` 拆成 `dynamicColorConstruction`（现造，上限 **2**，终点 **0**）
  与 `tokenReference`（引用，上限 62，**终点不是 0**，只许减不许增但不许当还债报数）。
- 两条各配**双向**元测试：构造样例必须红、令牌引用必须不被判成构造
  （模式一旦放宽到把 `.textColor` 也算债，它会立刻长出 62 处"新债"，那条反向断言当场红）。
- 补一条我一直漏的洞：基线取不到计数会退化成 `-1` 而 `-1` 永远不"超"上限
  ⇒ 改错一个键名，那条规则就**从闸门上消失且全绿**。现在钉
  `Set(knownBaseline.keys) == Set(rules.map(.name))`（`ownerNotes` 同样钉）。
- 台账位置 `$TMPDIR` → **`.scratch/tcoder-perf-renderpath-debt.txt`**，并改成
  写不出去就 `XCTFail`（`try?` 会把"没有台账"伪装成成功）、写完读回来比对。

验收：`./scripts/locked_build.sh test --filter PerfHitchGuardTests` →
`Executed 15 tests, with 0 failures`，表头
`directFormatters 1/1  dynamicColorConstruction 2/2  fullSort 9/9  syncFileIO 2/2  tokenReference 62/62`。

### 派给 UI 侧的一条（很小，但是真债）

把那 2 处 `Color(nsColor: .separatorColor/.quaternaryLabelColor)` 换成 `Theme.Palette` 里
已缓存的 `static let`（`Design/ThemePalette.swift:23` 就有一个 `separator`，
是现成的、语义相同的一份）。终点 0；棘轮今天起会拦新增。
顺带这也是设计一致性：这两处是 `Views/**` 里**仅有**的直接取系统 `NSColor` 的写法
（`grep -rn 'Color(nsColor:' Views/` 只出这两条；裸 `Color.gray` 那类另一条轴，归颜色面积收敛）。

## §O（2026-09-22 15:35）一次性红：`CoverageAnalyzerTests` 报 0.0 ≠ 78.0 —— 报了，没动它

15:14 那轮全量门禁在 `testUnitAndIntegrationKindsAreSeparated` 判红
（`XCTAssertEqualWithAccuracy ("0.0") != ("78.0")`）。**不是我的改动**（那三笔只动尺子/文档），
而**先怀疑自己的取数**是对的：我第一反应是"我的 `--filter` 跑污染了覆盖率产物"，
读了 `CoverageAnalyzerTests.swift:5-30` 才发现夹具根是
`NSTemporaryDirectory()/tcoder-cov-<UUID>/`、每个用例新建、tearDown 删除
⇒ **跨次污染这个解释不成立**，写下来免得下一个人白查一遍。

15:20 原样重跑（代码一字未改）⇒ `Executed 1050 tests, with 12 skipped and 0 failures`、
回执按头钉死（`0bd7643`）。所以这是一次性红，最可能的原因是负载
（同一次 wall 508 s vs cpu 262 s，机器上同时有别人的 `swift-test` 与 release 构建）。

**按红线处理：不改那个文件、不拧阈值、不给自己的分支加豁免。** 但留一条**建议**给尺子主人
（不是要求）：这条用例断言的是"分析器把 unit/integration 两类报告分开"，
高负载下若真存在超时/并发读目录的路径，值得看一眼 `CoverageAnalyzer` 的目录扫描是否有
时间预算——`metrics.unreadableDirectoryCount` 这个字段的存在说明它已经在容忍读不到的目录，
那么"读不到"与"读到 0"在数值上是不是同一个形状，是可查的一问。

## §P（2026-09-22 16:59）渲染路径 14 处具名存量：给一条命令，别抄我这张表

`tokenReference 62` 是**读数不是债**（§N 已经说清），所以真正要还的是这 **14 处 / 10 个文件**。
下表是 16:52 那一轮门禁现扫的快照（**它是快照，会腐烂**；重算方法就在下面那两条命令）：

| 规则（现量/上限） | 处数 | 落在哪些文件 |
|---|---|---|
| `fullSort` 9/9 | 9 | `ContributorRows`×2、`LogsFileTables`×2、`CodeMetricsView`、`DependenciesView`、`ContributorsView`、`LogsMetricGrid`、`LogsTrendCard` |
| `syncFileIO` 2/2 | 2 | `Views/Logs/LogsView.swift`×2（`attachedItems` → `fileSize(of:)` 两跳进 body） |
| `dynamicColorConstruction` 2/2 | 2 | `Views/Shell/SidebarRows.swift`、`Views/Shell/ProjectSidebar.swift` |
| `directFormatters` 1/1 | 1 | `Views/PerfLogs/ChartChrome.swift`（`DateFormatter()` 提 `static let`；**行号以台账为准**，本文这格从 :268 已漂到 :293） |

```bash
./scripts/locked_build.sh test --filter PerfHitchGuardTests    # 每次跑都打「现量/上限」
sed -n '1,200p' .scratch/tcoder-perf-renderpath-debt.txt        # 逐条带 文件:行 + 原文
```

三条使用约定：
1. **并完 main 就重跑再看**，别拿本文里的数字派活（§H 那条"交集 = 0"就是没重算而误导了两天）。
2. **还掉之后要有人拧基线**：`现量 < 上限` 的那一格就是"新增一处照样绿"的隐形余量，
   而台账自己会打『可拧到 N』——**看到那句话的人就是该拧的人**，不必等总工。
3. 这 14 处里 `DependenciesView`（n 可到上千）与 `ContributorRows`、`CodeMetricsView`
   是**滚动/切页期**成本 ⇒ 影响 **T1**，不影响心跳期 T2；
   别和 §H 那 16 处粗读点混成一句"清完渲染路径"——两批的验收窗口不是同一个。


## §Q（2026-09-22 20:09）§P 那 14 处**正式移交 UI 轮**：验收口径是台账四格，不是"门禁全绿"

性能轮不动手写 `Views/**`（用户 09-20 21:15 裁定，仍然有效），所以这批**只能派**。
此前一直挂在我这边没派出去，是我欠的账；这一节把它变成可执行移交。

**① 唯一事实来源是台账，不是本文件**
```bash
./scripts/locked_build.sh test --filter PerfHitchGuardTests
sed -n '1,200p' .scratch/tcoder-perf-renderpath-debt.txt
```
行号会漂，漂是静默的：本文件 §P 表里写 `ChartChrome.swift:268`，19:50 那一份台账已经是 `:293`。
⇒ 派活前重跑一次并**从台账里抄 `文件:行 + 原文`**，别抄本表。

**② 冲突面：19:58 实测零重叠**（11 个文件在其他任何一条流的树里都不 dirty）⇒ 不必排队，可整批派。
这条是**点测量**，动手前在**仓库根**重核（在别的目录跑那个 glob 会空匹配，zsh 还会直接报错退出）：
```bash
for t in .worktrees/*/; do git -C "$t" status --porcelain \
  | grep -oE '(ChartChrome|ProjectSidebar|SidebarRows|CodeMetricsView|DependenciesView|ContributorRows|ContributorsView|LogsFileTables|LogsMetricGrid|LogsTrendCard|LogsView)\.swift' \
  | sort -u | sed "s|^|$(basename $t) · |"; done
```

**③ 建议批次（按文件互不重叠，一批一个负责人，别跨批共享文件）**
- **A · Logs 系（6 处 / 4 文件）**：`LogsFileTables`×2 排序、`LogsMetricGrid` 排序、`LogsTrendCard` 排序、
  `LogsView`×2 同步 I/O（`attachedItems` → `fileSize(of:)` 两跳进 body，所以要连模型一起改）。
- **B · Git/Code/依赖（5 处 / 5 文件）**：`ContributorRows`×2、`ContributorsView`、`CodeMetricsView`、`DependenciesView`。
  这批是**滚动/切页期**成本 ⇒ 直接影响 T1，是三批里收益最大的。
- **C · 侧边栏（2 处现造动态色）**：`ProjectSidebar:231`、`SidebarRows:89` ⇒ 换成 `Theme` 里已有的令牌 `let`。
- **D · 一个 formatter**：`ChartChrome` 的 `DateFormatter()`。提 `static let` 前先确认只在主线程用，
  否则改无状态路径——**不要为了还债引入数据竞争**。

**④ 四条硬约定**（都是我这边踩过或量过的，不是仪式）
1. 不许抬上限、不许加豁免、也不许把代码挪成"守卫扫不到但仍在渲染路径上"的形状——
   那是躲尺子，债务一分没还。判据只有一个：**每还一处，那一格 `现量` 掉一格**。
2. 排序债的正解在模型/服务层（publish 之前排好、页面只读）。反面教训见 §N：
   在 `body` 里"再算一份缓存"会把分配挪进渲染路径，现量降了而实际更慢。
3. 视觉改动与性能改动**分开提交、各过各的门禁**；牵动文案或键就要过 i18n 棘轮。
4. 回执请写成「四格现量从 9/9、2/2、2/2、1/1 掉到 X/X…」并附台账那一行，
   **不要写"全绿"**——全绿只说明门禁没拦住，不说明债少了。

**⑤ 还完之后要复测的是 T1，不是 T2**：心跳期那 1.5 s 一次的主线程占用与这批排序无关；
这批全部发生在滚动/切页期。今晚 `MEASURE_LAUNCH=1` 已经打通，一个窗口能同时拿到
hitch 计数与 `p95` 交叉核对（`perf_framepulse.py --sample-dir <目录>` 会直接印合判），
所以**每还一批复测一趟 20 秒交互档**就够了，不必重跑全套。


## §R（2026-09-22 22:52）第一趟"四个条件齐"的交互档样本——以及我自己误读又自纠的那一条

样本 `.scratch/tcoder-perf-d73bea4-interact-run1`（头 `d73bea4`）。
⚠ 归属范围：量它的时候 `Sources` 与 main 逐字节相同；**09-23 00:08 复核时 main 已前进 23 个渲染路径文件**
⇒ 这一行的数描述的是 `d73bea4` 那一份产物，不描述 main 当前内容；已在 `61b7181` 合并 main 后重测。
四个条件第一次同时成立：被测对象**有真实数据**（沙箱按授权复制真实支持目录，5 份真报告）✓、
`前台=Tcoder` 且 `visible=有在屏窗口` ✓、`pid == scroll_target`（滚动落在被 attach 的那个进程上）✓、
收尾复核判"窗口内确有输入事件" ✓、七维上下文合格（并发重活=无）✓。

### 只有三条结论可以说（每条都有互相独立的仪器点头）

1. **呈现侧没有掉帧**：`displayed-surfaces-per-second` p50 **120.00** / p95 120.00（42 秒，设备 120 Hz）。
   这是 WindowServer 侧的数，与 App 内的两把尺子都独立。
2. **确有少量晚到帧**：xctrace `hitches` n=10（p50 8.33 / p95 25.00 / max 25.00 ms），
   FramePulse `hitch(>1.5×)` 17 次 / 20 秒 ⇒ 两把仪器同向。
   ⇒ **「交互期 hitch 帧 = 0」这一半句目前不成立**；但量级是 ~0.5 帧每秒，不是"普遍卡顿"。
3. **p95 那 0.84 ms 的尾巴在回调时序上**（合判结论，见 §Q 那条工具）：
   上屏跟满而 `FramePulse` p95 9.17 ms > 预算 8.41 ms。
   ⚠ 标定之前**两种结论都不许写**：既不许说"p95 达标"，也不许把 9.17 ms 当成掉帧面积。

### 我误读过的一条（写下来，因为它长得太像证据了）

同一行里 `hitches-updates n=1113 p50=10.22 ms 超预算 100%`，我当场写成
"交互期主线程 update 每帧超过一帧预算 ⇒ 瓶颈钉死在主线程"。**错了**，两处：

· 反证用错：我配的算术"1113 × 10.22 ms = 11.5 s 塞不进 20 秒"本身是假的（11.4 s 塞得进）。
· 真反证来自**同一趟样本的第三把仪器**：`time-profile` 的 Main Thread 5765 个采样里
  **99.9% 栈顶是 `static TcoderEntry.main()` 事件循环本体**（报表原话："主线程绝大部分样本是在等事件，不是算不动"）
  ⇒ 主线程在等，就不在忙；配合上屏 120/s 与帧间隔 p50 8.33 才自洽。

⇒ 现在工具会自己提醒（`trace_report.py caveat_for` + selfcheck 第 34 项，双向夹具）：
逐值贴着一条基线下限、分布极窄的那种形状，**不许当"主线程忙了多久"引用**。
至于这张表的官方单位是什么，仍未定——**没定就写"待核"，不要靠猜贴标签**。

### 这批债的验收窗口

§Q 那 14 处与 16 处粗读点全部在滚动/切页期起作用 ⇒ **还完之后复测的是这一档**（`interact`），
一条命令即可（含 p95 合判）：
```bash
MEASURE_SEED_DIR="$HOME/Library/Application Support/TcoderMonitor" \
MODE=interact INPUT=synth MEASURE_LAUNCH=1 ./scripts/perf_wait_window.sh $(git rev-parse --short HEAD) 3 900
```
判据还是那三条：`hitches` 计数、FramePulse `hitch(>1.5×)`、上屏 p50/p95。
**别拿 `hitches-updates` 那格当"主线程占用"交差**（见上）。


## §S（2026-09-22 23:00）§M 结掉了，但结出一个更根本的问题：**预算的基准 Hz 是名义值**

新仪器 `scripts/perf_cadence.py`（`report` 档已自动印，selfcheck 第 35 项双向夹具）
把"p95 帧间隔"这半句拆成两台独立仪器，同一窗口对照：

| 仪器 | 量的东西 | p50 | p95 | p99 | max |
|---|---|---|---|---|---|
| `FramePulse` | CVDisplayLink **回调送达**间隔 | 8.33 | **9.17** | 9.30 | 333 ms |
| `hitches-renders` 逐帧起点差 | **合成器实际出帧**节拍 | 8.33 | **8.51** | 8.56 | 33.1 ms |

⇒ **§M 要的那个系统性偏移 = +0.66 ms（p99 差 +0.74 ms，p50 差 ≈0）**：
尾巴主要是回调时序，不是呈现延迟。这条第一次有了数，不再是推测。

⇒ 但把呈现侧自己拉出来看，又发现预算的基准就不对：
用合成器时间线反算（跨度 ÷ 间隔数）得到**实测周期 8.376~8.380 ms ≈ 119.33~119.39 Hz**，
而 App 里 `CGDisplayCopyDisplayMode(current)` 报的是**名义 120.0 Hz**
⇒ 名义预算 8.417 ms 天生比"实测周期 × 1.01 = 8.46 ms"小 0.5%。

**两把预算并排印出来的结果（同一份交互档样本）：**
```
按名义(120Hz)预算 8.417 ms：p95 未达标（超 0.088 ms）
按实测周期预算 8.464 ms：  p95 未达标（超 0.041 ms）
晚到帧(>1.5×实测周期 12.57 ms) 9 个 ⇒ 0.43 帧每秒
```
而**空闲档同一仪器**：p95 8.52 ms、晚到帧 11 个（0.52 帧每秒）
⇒ 交互档在两个指标上都不比空闲档差，甚至略好。

### 这条为什么重要，以及为什么我不能自己定

"残差 0.041~0.088 ms"**小于两台仪器的分歧（0.66 ms）**，也小于面板自身节拍的标准差（0.85 ms）。
也就是说：**p95 ≤ 8.4 ms 这半句在当前硬件上已经贴近地板，不是再优化代码能翻过来的**。
但"因此换用实测周期当预算"会让判据变松 0.5%——**这是改阈值，AGENTS 明令不许由测量方为了变绿来做**。
⇒ 只把两把尺子并排印出来 + 把决定权交出去（已问需求方）。
在裁定之前，验收口径仍按名义 8.4 ms 写"**未达标**（超 0.04~0.09 ms，且交互档不劣于空闲档）"。

### 顺带被这次分析纠正的两件事
1. `hitches-updates` 那 1113 个"超预算"（§R）——不是主线程忙时，见包 10 的 caveat。
2. 节拍仪器的夹具第一版**没带 `id` 属性**，被生产解析器读成 0 帧 ⇒ 三例全判"样本不足"。
   形状像不等于解析得动；`Doc` 是按 id 建表回查的（第 35 项的注释里记了这条）。

### §S 追加（23:37）：相对地板判据第一次跑，结论是**"分不开"，不是"通过"**

基线换成 2 份空闲档、取中位数并给出散布之后（`perf_cadence.py --baseline a.xml,b.xml`）：
```
基线 2 份：p95 中位 8.509（散布 0.020）  晚到帧率中位 0.43 /s（散布 0.18）
交互档：p95 8.505 ⇒ -0.004 ms   晚到帧率 0.43 /s ⇒ +0.00 /s
两项判定：p95 分不开（带宽 ±0.020 ms）  晚到帧率 分不开（带宽 ±0.18 /s）
结论：**与基线分不开** ⇒ 这条判据当前答不了，加趟数或先压噪声，不许选一 favourable 的说法
```
第一版只比**一份**基线时，判据会随换基线在"不劣于/劣于"之间翻面（−0.013 ms → +0.006 ms），
所以我没有把它写成"通过"：**能翻面的判据不是判据**。现在多份取中位数 + 差值落在基线散布内就判"分不开"。
⇒ 要把这一条从"分不开"推到"能判"，缺的是**趟数**（交互 3 趟 + 空闲 3 趟同一产物），
   以及 UI 侧还完 §Q 那批之后晚到帧绝对计数会不会降。两者都在跑/已派。


## §T（2026-09-23 00:39–01:03）交互档第一次满 3 趟：p95 **达标**，hitch=0 **未达标**，归因给了渲染相位

在"已并 main 的同一份内容"（`dd46cbe`）上，第一次拿到 3 趟四条件齐的交互样本，
并且基线用**同一产物的 2 趟空闲档**（不是昨天那批旧头），三趟各对基线跑一次相对判据：

| 交互趟 | 呈现侧 p95 | 名义预算 8.417 | 缺口率(≠hitch) | 相对基线（p95 8.345 散布 0.002；缺口 0.93 ±0.29） |
|---|---|---|---|---|
| run1 | **8.346 ms** | 达标 | 1.32 /s | p95 分不开、晚到帧**劣** ⇒ 未达标 |
| run2 | **8.345 ms** | 达标 | 1.03 /s | p95 分不开、晚到帧**劣** ⇒ 未达标 |
| run3 | **8.344 ms** | 达标 | 0.98 /s | p95 不劣、晚到帧分不开 ⇒ 判不了 |

⇒ 拆成两句说，不许合成一句好听的话：
· **「p95 帧间隔 ≤8.4 ms」这半句在交付内容上成立**（3/3，且与空闲基线同高）；
  昨天那趟 8.51 的差，随 main 那 23 个渲染路径文件（UI 轮粗读迁移等）落地一起消失了——
  这是本轮第一次看到"别人的改动把判据从不合格推到合格"的直接证据。
· **「交互期 hitch 帧 = 0」不成立**：xctrace `hitches` 权威计数 **24 / 23 / 29 个每 20 秒**（1.15~1.45 /s，均为 8.33 ms 单帧），两趟明确劣于空闲基线。上表"缺口率"量的是合成器起点间隔，**不等于 hitch**（空闲档没有新内容也计缺口）⇒ 工具已把它改名并并排印权威数（`perf_cadence.py`，见 §T 末）。
· 归因不猜：滚动期 **render 相位 p50 4.03~4.71 ms**（空闲 2.73，p95 5.5~6.4），
  即每帧渲染吃掉约半个帧预算；`app-update` 那张表按包 10 的口径**不能**当主线程占用引用。
  ⇒ §Q 那批的价值现在有了可核对的靶子：**把滚动期 render 相位 p50 压回 3 ms 量级**，
  验收就看晚到帧率能不能落到空闲基线的带宽内（±0.15 /s）。

另记两条仪器事实（都是这轮才有的）：
· 空闲基线自身 p95 散布只有 **0.001 ms** ⇒ 相对判据的带宽极窄，
  所以"p95 分不开"是**真的分不开**（差 0.001 ms），不是判据失灵；
  而晚到帧率的散布是 ±0.15 /s，交互档 +0.12 那一趟因此只能判"分不开"。
· 昨天那次"回调 − 上屏 = +0.66 ms"的偏移在三趟里稳定复现（**+0.71 / +0.71 / +0.62 ms**）
  ⇒ §M 的结论可以定死了：**`FramePulse` 的 p95 系统性偏晚约 0.7 ms，判"掉帧"必须用合成器侧节拍**。

## §U 报给「九页拍图」属主：`capture_pages_isolated.sh` 的收尾是选装开关，默认不收（2026-09-23 上午）

现场：10:04–10:20 之间机器上出现 **6 个 `ppid=1` 的被测实例**，全部落在
`/Users/one/Documents/Tcoder/TcoderMonitor/dist/Tcoder.app`，每约 20 s 多一个 ——
正是九页逐页拍图的节奏。所有人（包括我）的闸门里有一条"实例数恰为 1"，
这六个从夜里一路把帧率测量押死到上午。

归因（现扫，不是猜）：`scripts/capture_pages_isolated.sh` 在 per-instance 模式下
**每页起一个实例**，收尾函数 `retire_instance()` 里那句 `kill -TERM` 躲在
`CAPTURE_TERM=1`（不传就是 0）后面，默认路径只印"待人工退出：pid …"就返回；
文件里那把 `trap` 只删锁目录，不碰实例。**这不是恶意设计**——那句默认是刻意避免
按 bundle id 广播退出的（2026-09-20 三家互杀到九页拍成 0 张的教训），我完全同意保留。

请属主在三个里挑一个（**我不改这个文件，也不给自己的闸门加豁免**）：
① 收尾时只对自己那个 pid 走"精确关窗"（例如 `osascript` 按 pid 关，或等 `$!` 自然退），
   保持"绝不广播"这条不动；② 把 `CAPTURE_TERM=1` 变成脚本自己的默认并在话术里写明
   它已核对二进制路径；③ 保留默认，但退出前把"我起了哪些 pid"落盘（一行一个），
   让看门狗/下一条闸有依据判断该谁收。

我这侧已经把**形状**变得可见了（不改别人的码也能做到）：
`scripts/perf_launcher_audit.sh` 的「trap」一格拆成 `kill` / `trap` 两格，
新增 `--tsv` 事实行（人看表、机器看事实行，同源）；第 29 项闸门改读事实行，
第 37 项用三个夹具双向钉住"无条件 / 躲在开关后面 / 没有"三种形状。
**现量**：认出 11 个会起实例/录制的脚本，7 个是"该收尾却没无条件收尾 / 会广播退"的形状，
其中 1 个的收尾全躲在默认关掉的开关后面（就是上面这个）；**性能侧名下 0 个**。
selfcheck 41 项 0 失败。

## §V 报表侧撤掉两处 over-claim（2026-09-23 02:26，`a38a472` + `11b003d`）

同一趟交互档样本里三个数互相矛盾：`hitches-updates` **1841/2090 行超一帧预算**、
迟到帧只有 **24 个**、上屏实测 **119~120 帧/秒**。老报告却从这张表印出
"主线程 stall 1841 个（88.1%）"，归因行又印"比 7671% ⇒ 几乎一比一 ⇒ 先查主线程"。
`7671%` 是算术错（超预算次数远多于迟到帧时那是**倍数**不是百分比），
后一句是拿一张**行数与帧不同源、单位待核**的表定归因。

改后的口径（判据只留一份：`perf_trace_metrics.interval_shaped`，`trace_report.caveat_for` 改调它）：
· **窄分布**（逐值下限 ≥0.8× 预算）⇒ 单位不是占用时长 ⇒ 不判；
· **比值悬殊**（超预算 >1.5× 迟到帧）⇒ 比值不含归因信息 ⇒ 不判；
· "stall N 个"只留给**少数孤例**（<20% 行超预算），反向也钉住（孤例不许被一并降格成"不判"）；
· 两种"不判"都指路另两把独立尺子：**render 相位**（本次实测 p50 4.10 ms）与
  **time-profile 的 Main Thread 忙样本**。

对 §Q 验收的影响：靶子没变（滚动期 render 相位 p50 压回 3 ms 量级、缺口率落进空闲基线带宽），
但**验收报告里不会再出现"1841 个 stall"这种句子**——谁在别处看到这句话，那是 `a38a472` 之前的旧报表。

## §W 补测改动前基线已经可走（2026-09-23 02:39，`249d6ee`）——"X 拿不到"不再是理由

以前每张交互档表都挂一句"**对照列未受控**（run1 采在总工并发几十个 swiftc 抢满 15 核期间）⇒
不作任何『从 X 降到 Y』的 X"（spec §1.3）。根因不是没人愿意量旧内容，而是**尺子只肯比 HEAD**：
`perf_provenance.sh` 把产物与当前工作树比，于是"量另一个 rev 的产物"结构性做不到。

现在这条路通了，而且**判定一条没放宽**：
```
eval "$(scripts/perf_measure_rev.sh env 465f5a6)"      # PERF_BIN + MEASURE_REV 一起给
MODE=interact ./scripts/perf_wait_window.sh 465f5a6 3 900
scripts/perf_measure_rev.sh clean 465f5a6
```
真数据四向验过：`HEAD`/`HEAD~1`（只动 docs）⇒ 按产物码 tree 放行；`d73bea4`（Sources 不同）⇒ 拒并印两个 sha；
不存在的 rev ⇒ 回空并拒（`--verify --quiet`，不是裸 `git rev-parse`——后者会把入参原样吐回来）。
钉在 selfcheck 第 38 项。

两个已知边界，别当缺陷报：
1. `465f5a6` 在无界基座之前，**没有 FramePulse** ⇒ 它的 p95 那半句注定"未采到"。
   这一趟只取 `hitches` 计数、render 相位、Time Profiler 三样。
2. 它用的是**当年那份 `.scratch` 之外的旧产物布局**；`prepare` 找不到预期二进制会当场死，不会假装量过。

`measure19` 正按这条队列补测 `465f5a6` 三趟交互档 —— 等它落完，§1 的对照列就有受控的 X 了。

## §X 「可用 3/3」不等于「取值一致」——新尺子第一次跑就把自己那把抓出来了（2026-09-23 02:45）

`[interact] rc=0 ⇒ 可用 3/3 趟` 这句话在 `fa26f4c` 那三趟上是**真**的，也是**没意义**的：
三趟 hitch/s = **1.20 / 1.30 / 18.80**，而"可用"数的一直是结构
（产物齐、没被 REFUSED、收尾复核没打回）。spec §1.3 要求的那半句「且取值一致」
**全仓没有一支尺子在量** —— 于是所有人都（包括我）把 3/3 读成"协议满足"。

- 新尺 `scripts/perf_trio_agreement.py`：hitch/s 极差比（上限 **2.0×**）+ 出帧 p50 极差（上限 10 帧/s）
  两把一起看；缺件/被复核打回/秒数读不出 ⇒ 不参与散布；<3 趟 ⇒ `rc=2`「样本不足」，
  **绝不**把"少一趟"算成"那趟 hitch=0 ⇒ 很稳"。取数走 `summary_load`/`period_eligibility`，不自己解析 XML。
- run3 那 15 倍**只长在 xctrace 的 hitch 计数上**：同趟 render 相位 p50 4.35 ms（前两趟 4.10/3.93）、
  上屏实测三趟都是 **119 帧/秒**、呈现侧 p95 三趟都是 **8.34/8.35/8.34 ms**（≤ 名义预算 8.417）⇒
  两把独立尺子都没跟上。与包 10 对 `hitches-updates` 的处理同一条：**钉不死计数口径之前，
  这一维只报最好一组的现量（`dd46cbe` 三趟 1.15~1.45 /s，判"一致"），不做中位外推。**
- 我自己的第一版被这把尺抓回来一次：拿 hitch/s 的极差比量 **idle 档** ⇒
  `0.00~0.95 ⇒ 19.0× ⇒ 严重不一致`。可 idle 档的 hitch 真值就该在 0 附近（§6.2 明写那档只记形状不判档），
  一个 ≈0 的量做除法，什么噪声都是"不一致"。⇒ **判据量跟着档位走**：
  `interaction` 比 hitch/s、`idle` 比 `app-update` 最大值（T2 的既有判据，现量 1.83~2.30 ms ⇒ 一致）；
  混档一律不判。第 39 项把这七种形状各钉一次。
- 排程器侧（`measure17/18`）**当时正在跑，没改**；下一棒起在数完 `可用 N/3` 之后
  必须再跑一次 `perf_trio_agreement.py`，`rc≠0` 就不许写"3/3 达标"。
