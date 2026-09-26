# Tcoder 性能规范 v1 · 120Hz 流畅（含"简约无界"合并轮）

- 状态：已批准执行（用户 2026-09-20 15:0x「给自己定个目标 开始吧」）
- 负责人：总工程师（性能 + 设计总监双身份）
- 基线提交：`2981ae5`（行为等价于产物 `465f5a6`，见下）
- 合并范围：本轮与 `2026-09-20-borderless-minimal-ui-redesign-design.md` **同一批文件、同一次交付**，
  不再分两轮付两遍钱。视觉契约看那份，性能契约看这份；**冲突时以本文件的"不掉帧"为硬约束，
  以那份的"观感"为软目标**——凡两者冲突处必须在交付报告里点名，不许静默取舍。

---

## 0. 一句话病因（实测，非推断）

**空闲不动的时候，这个 App 每 1.5 秒把自己钉住 5~7 帧。**

## 1. 改动前基线（xctrace 只读采样，pid 96992 = `dist/Tcoder.app`，release，`GIT_CLEAN=true`，rev `465f5a6`）

工具：`xcrun xctrace record --template "Animation Hitches" / "Time Profiler" --attach <pid>`，
沙箱无需（未写 `defaults`、未启动第二实例）。解析器 `scripts/perf_harness.sh` 内嵌的
`trace_report.py`（本文件写作时的原始数据在 `/tmp/tcoder-perf-baseline/`，**是产物，不入库**）。

| 指标 | 实测值 | 预算 | 判定 |
|---|---|---|---|
| 内建屏 3024×1964 最大刷新率 | **120 Hz**（`device-display-info`，主显=Yes） | — | 8.33ms/帧预算成立 |
| 外接 4K 最大刷新率 | 120 Hz | — | 同上 |
| render 相位（2394 帧） | p50 2.73 / p95 4.06 / p99 4.77 / max 25.12 ms | ≤8.33 | **健康**，超预算 **10 帧 = 0.42%** |
| app-update 相位（7 个 hitch） | **10.8 / 11.1 / 13.2 / 15.0 / 16.0 / 18.6 / 24.8 ms** | ≤8.33 | **全线超预算 1.3~3.0 倍** |
| hitch 次数 / 速率 | 7 次 / 20 s = **0.35 /s** | 0（硬上限 <1/s） | 超 |
| hitch 帧时长 | 33.33 ~ **58.33 ms**（=4~7 帧） | 0 | 超 |
| `potential-hangs`（Potential Interaction Delay） | **13 次 / 25 s**，中位 **42.6 ms**、最大 59.8 ms、累计 **573 ms** | 单次 ≤8.33 ms | 严重超 |
| 主线程 CPU | 684 / 807 样本（**占全进程 84.8%**），25 s 内 ≈ 684 ms | 空闲 ≤2% 且零突发 | 达标但**全挤在 13 次突发里** |
| 主线程热点 | **64.3% 在 `ViewGraphRootValueUpdater._updateViewGraph` / `AG::Graph::UpdateStack::update()`**；另有 `_platform_memmove` 16、`iokit_user_client_trap ← IOGPUCommandQueueSubmitCommandBuffers` 17、`icu::UnicodeString::setToUTF8` 4 | — | 病因=视图图更新面，不是算不动 |

**两次心跳的间隔实测为 1.50 / 1.51 / 1.50 / 1.65 s** —— 与 `AppState.init` 里
`monitor.start(intervalMilliseconds: 1_500)` 同相位。**约每两次 tick 就有一次 hitch（13 tick / 7 hitch）。**

### 1.1 这次测量推翻了我自己的排序（备案） —— **内容已搬进本目录 `2026-09-20-perf-baseline-detail.md` 的同号小节，一行没改写。**
（09-24 19:45 拆卷：本规范撞上全仓 ≤800 行口径，搬走的只是历史读数明细；规范性条文与被引用最多的 §1.3/§1.4 留在原地，小节编号不变。）

### 1.2 勘查数字勘误（总工独立计数复核，15:37） —— **内容已搬进本目录 `2026-09-20-perf-baseline-detail.md` 的同号小节，一行没改写。**
（09-24 19:45 拆卷：本规范撞上全仓 ≤800 行口径，搬走的只是历史读数明细；规范性条文与被引用最多的 §1.3/§1.4 留在原地，小节编号不变。）

### 1.3 **基线状态：未成立**（15:20 自我收回，别拿下表当"改动前"）

下表（run1）是**单一采样、条件未受控**。同一份 release 二进制（`465f5a6`）后来又采了两次，
三者互相矛盾，而代码一行没变：

| 样本 | 时刻/时长 | hitch 次数 | **Hitch Time Ratio**（Apple 主指标） | 帧时长分布 | 当时的机器条件 |
|---|---|---|---|---|---|
| run1 | 15:03 / 20s | 7 = 0.35/s | **11.67 ms/s → 危急(>10)** | 33.3 / 41.7 / 50.0 / 58.3 ms（每次晚 **4~7 帧**） | **我正在并发跑几十个 `swiftc -typecheck` 探针**（抢满 15 核）→ 抬高 |
| run2 | 16:03 / 25s | — | **无效** | — | 该次 `hitches` 表 export 失败（`Document Missing Template Error`，后台任务被中途杀）⇒ **空文件**。先前记的"2 次"来自同一份坏解析，**作废** |
| run2b | 16:12 / 20s | 9 = 0.45/s | **0.83 ms/s → 无感(<5)** | 8.3×7 / 16.7×2 ms（每次只晚 **1~2 帧**） | `vm.loadavg={82.38 …}`、**前台是别的 App** → 后台窗口被节流，假性地好看 |

**这张表最重要的一条不是"降了多少"，而是「次数根本不是判别量」**：
run1 与 run2b 的 hitch **次数几乎相同（7 vs 9）**，严重度却差 **14 倍**（11.67 vs 0.83 ms/s），
因为前者每次晚 4~7 帧、后者每次只晚 1~2 帧。**这正是 Apple 把指标定义成时间占比而非次数的理由**，
也说明我最初拿"7 次 / 连丢 7 帧"当卖点是**选错了量纲**（方向没错，口径错了）。

**所以**：既不能说"改动前 11.67 ms/s 就是基线"（run1 条件被污染），
也不能拿 run2b 的 0.83 说"已达标"（后台态、条件不合格）。**处置**：`perf_harness.sh` 已加 `preflight_context()`
（并发编译器 / `load1 ≤ 核数×1.5` / 被测窗口必须前台 / 非 hidden，全部连同读数落
`measurement-context.txt`），按该协议**连测 ≥3 次且取值一致**的那一组，才是本规范"改动前基线"一栏该填的数。
在此之前，§3 的 T1/T2 目标值仍按 Apple 口径推导（120Hz ⇒ 8.33ms/帧），**不依赖**这张表；
但 §6 验收里"HTR 降到 <5、目标 0"这一项在基线重定之前**不得申报达成**。

**「取值一致」用哪几把尺（2026-09-26 需求方裁定 A）**：判定量按档位取 —— 交互档比 `hitch/s`，
idle 档比**每趟自身分布的 p90 与均值**（两把都必须过，且互不重叠；"留一池子的 p95"那版已撤回，
理由写在 §BH）。`displayed-surfaces p50`（出帧速率）从本日起是**参考项**：极差超过 10 帧/s 仍然
印出一行，但不再参与判定。凭据是台账卷十 §167 —— 同一次构建、同一个窗口、93 发采样全部确证在画的
八趟里，任取三趟有 **27%** 只被这一维打回，而两把主尺 **0/56** 从没拦过任何东西。
⚠ **这不是放宽阈值**：`FPS_SPREAD_BAR` 的数值一个字没改，改的是它担任不担任判据（本仓红线是
"不许为了好看放宽阈值"，不是"不许纠正选错的量"）。守卫在 selfcheck 第 39 与第 74 项：
把出帧那一维偷偷改回判据、或者让它连参考行都不印，两格都会红。


`app-update` 那一行也按同一方式复核过：`hitches-updates` 表 n=14、
去重后仍是 **10.8 / 11.1 / 13.2 / 15.0 / 16.0 / 18.6 / 24.8 ms**（每个值在 Brown+Red 两行各出现一次，
工具侧早有 `dedupe_pairs` 处理），**§1 的该行无需更正**——
记下这条是为了免得后来人以为同一个 ref bug 也污染了它。
（run2b 同法复核：1.9~3.0 ms、超预算 0 个。）

**09-24 19:45 补：上面那句「连测 ≥3 次且取值一致」的判法，现在按档位分开**（需求方同日裁定 A）。
原来它只有一个数（极差比 ≤2.0×），于是被两件事夹住：交互档比 hitch/s 是成立的，
但 idle 档当时的判据量取的是**每趟 `app-update` 的最大值**——极值统计量在 n≈13~14 的窗口里，
**光是抽样**就能把极差比顶到 1.2~1.8×（同趟内部自助重抽实测），而多一趟只会让它更大
⇒ 对极值型判据，「重复到一致」是个**不会终止的协议**（实测：五趟可用仍 2.1×）。
⇒ 现在的判法：`interaction` 比每趟 hitch/s；**`idle` 比每趟自身事件分布的 p90 与均值两把尺**，
两条都必须在 2.0× 带宽内。`max` 仍逐趟判达标、仍是「最长孤例单独查」的输入，**只是不再当重复性判据**。
尺子与理由：`TcoderMonitor/scripts/perf_trio_agreement.py`（含一次被自己撤回的实现：
「留一趟合并池」的极差比会因池子互相重叠而构造性收敛到 1 ⇒ 那是永真绿，不能用）；
反例形状住在 `perf_harness.sh selfcheck` 的第 39 与第 55 项。

### 1.4 一次"两把尺子对不上"的结案：错的是我，不是工具

`perf_harness.sh report` 重打 run1 时，`render 超预算帧` 给 **10 帧 (0.42%)**，
我此前手算给 **5 帧 (0.21%)**。我一度判工具坏了（理由看起来很像样：那 10 个值恰好是 5 个值各出现两次，
而两边行数都是 2394）。**结论反了**：

- 我的复核脚本写的是 `val.get(int(m.group(2)))`，而 id 字典的键是**字符串** ⇒
  **所有 `<duration ref="N"/>` 形式的时长被静默当成 0**。
  2394 行里约 54 行走 ref，正好就是"消失的那 5 帧"。
- p50/p95 只差在小数点后第二位，所以这个 bug **不会**在分位数上露馅，只在"超阈值计数"上露馅——
  而阈值计数恰好是验收要看的那一列。
- 这是 xctrace XML 的 id/ref 内部引用**第 3 次**咬人（前两次：线程 `fmt` 只出现在首次出现的行、
  窗口号 `fmt`）。**同一族坑第 3 次，说明"我记得这个坑"不等于"我的每条新代码都不踩它"。**

**处置（已落到尺子里）**：`trace_report.py` 新增 `cross_check_durations()` ——
汇总表里 render 一列**必须用两条独立解析（`Doc` 的 id/ref 解引用 vs 逐行正则）比对**，
不一致就把这一列标成"未报（两把解析不一致）"并打印差异，**绝不允许挑一个好看的数用**。
§1 的 render 行已按工具口径改正：**p50 2.73 / p95 4.06 / p99 4.77 / max 25.12，超预算 10 帧 = 0.42%**。
（结论不变：render 相位健康，不是本轮瓶颈；改的是数，不是判断。）


### 1.5 第一次**受控**读数（2026-09-21 10:49，release，脏=0）——**N=1，且归错了对象，因此不作数**

> **本节先自纠一处**：我原先把这次读数写成"rev `e991c6d`"。错了。
> `measurement-context.txt` 里的 `HEAD=` 记的是**当时工作树**的头，
> 而我 attach 的那个 `dist/Tcoder.app` 是 09:49 从 **`41add9e`** 建的（见
> `dist/RELEASE_MANIFEST.env`），两者之间隔着 **39 个 `Sources/` + 2 个 `Resources/` 文件**
> （整批 i18n P5-c2..c5 与我自己的 `PerfReadoutCells.thermal` 修复）。
> ⇒ **这份读数量的是两小时前的旧二进制**，只是恰好在新树上按了回车。
> 尺子当时**没有这一维闸门**——已补第六维 `provenance_ok`（见 §1.6 第 4 条）：
> 二进制 rev ≠ 当前 HEAD、或构建时树是脏的、或读不到 manifest，一律拒跑。
> 这条自纠的教训比读数本身有用：**"上下文里有 HEAD"不等于"HEAD 是被测对象的身份"。**

闸门修好（`e991c6d`：前台名比对错对象）之后第一次真出数。上下文原样抄，不给美化：

```
时间=2026-09-21 10:49:46  HEAD=e991c6d  工作树改动数=0
被采pid=88924  口径=release  实例数=1  前台App=Tcoder  被测进程visible=有在屏窗口（Tcoder）
load1=4.13  核数=15  并发swiftc=无  人输入静默=17.36s  hitches_seconds=20  tp_seconds=25
```

| 指标 | 本次（受控 N=1） | 对 §3 的意思 |
|---|---|---|
| `app-update` 单次耗时 | **0.6 / 0.6 / 0.8 / 0.8 / 1.0 / 1.0 / 1.0 / 1.0 ms** | T2（心跳期主线程占用 ≤4.0 ms）**这一趟**在红线内，余量 4 倍 |
| hitch 次数 / HTR | 0 次 / **0.00 ms/s** | T-心跳期无 hitch |
| `potential-hangs` | 0 次 | 无 ≥ 主线程长占用突发 |
| render 相位 | p50 2.41 / p95 8.07 / p99 14.60（n=**181**） | 见 §1.6 第 1 条：**这行不许与 §1 的 2394 帧互比** |
| render 超预算帧 | 9 帧 = 4.97%（n=181） | 绝对判定仍为"超"，但分母与基线差 13 倍 |
| 主线程 CPU 样本占比 | 37/159 = 23.3% | 对照列未受控 ⇒ **不判趋势**（§1.6 第 2 条） |
| 主线程热点第一名 | 56.8% `ViewGraphRootValueUpdater._updateViewGraph` | **仍是它**——病因没换，只是变轻 |

**为什么这一趟不足以申报 T2 达标**：§1.3 定的规矩是"按协议**连测 ≥3 次且取值一致**"。
同一轮里第 2、3 趟被闸门拒了（`前台App=AiX`，其余四条闸全合格，拒因落在
`measurement-context.txt`）⇒ **目前只有 1 次可用**。
顺带一条：这台闸门此前是**恒拒**（比的是进程名 `TcoderMonitor`，而 `lsappinfo` 给显示名 `Tcoder`），
现在它一次放行、两次拒绝，才第一次具备"判别力"这个前提——**恒拒的闸门看起来最像尽职**。

> **截至 12:08 的样本账**：带正确身份标签的受控 idle 共 2 趟，
> 但**它们不是同一个 rev**（§1.5 那趟产物是 `41add9e`、§1.5b 是 `082f403`，中间隔着 39 个产物文件），
> 而 §1.3 要的是"**同一份代码**上连测 ≥3 次且取值一致" ⇒ **在 `082f403` 上还差 2 趟**，
> 不能把两趟不同 rev 的读数叠成 N=2。


### 1.5b 第二趟受控读数（2026-09-21 12:05，产物 rev `082f403`、构建时树干净） —— **内容已搬进本目录 `2026-09-20-perf-baseline-detail.md` 的同号小节，一行没改写。**
（09-24 19:45 拆卷：本规范撞上全仓 ≤800 行口径，搬走的只是历史读数明细；规范性条文与被引用最多的 §1.3/§1.4 留在原地，小节编号不变。）

### 1.5c 一处**留给总工裁定**的口径矛盾（我不动阈值）

`render 超预算帧` 的绝对判据写的是 `pct < 0.1%`，而 §1 基线自己实测 **0.42%**、
这趟 **0.43%**——也就是说这一行**对基线和现状同时判"超"**，永远红。
两种可能，只能由定指标的人选：① 0.1% 是我们想要的**目标**，那该明写成
"目标 0.1%，现状 0.4%，仍超"（现在的写法会让人以为基线健康而现状恶化）；
② 0.1% 是我当初抄错了的数（Apple 的口径是 hitch **时间占比**，不是"超预算帧百分比"）。
**处置**：不自作主张改数（红线 5），把它登记成待裁定项；裁定前这一行的"超"两个字
不许被任何人（包括我）当成"性能回退"的证据引用。

### 1.5d **T2 成立**：同一 rev 上三趟一致（2026-09-21 12:0x–12:2x，产物 rev `9e60fec`，构建时树干净） —— **内容已搬进本目录 `2026-09-20-perf-baseline-detail.md` 的同号小节，一行没改写。**
（09-24 19:45 拆卷：本规范撞上全仓 ≤800 行口径，搬走的只是历史读数明细；规范性条文与被引用最多的 §1.3/§1.4 留在原地，小节编号不变。）

### 1.5e 采样纪律（新增一条硬规矩）

`Design/ReadoutKit.swift` 里的运行时漏翻台账由 `TCODER_I18N_RUNTIME_LEDGER` 控制：
不设时 `record()` 第一次判断就返回（渲染路径零成本），设了则按"每 200 次查表 / 每个新漏翻键"
节流写盘。**⇒ 做性能采样时一律不许设它**，否则量到的是台账自己的开销。
已写进 `perf_preflight.sh` 的上下文行旁边（见 §4 尺子一节）。

### 1.5f T4 九页冷启动（2026-09-21 15:2x，rev `5a5d55c` 产物）

| 页 | 启动到就绪 | 页 | 启动到就绪 | 页 | 启动到就绪 |
|---|---|---|---|---|---|
| 总览 | 796 ms | Git 洞察 | 776 ms | 错误日志 | 837 ms |
| 代码规模 | 786 ms | 贡献者 | 764 ms | 依赖分析 | 795 ms |
| 复杂度风险 | 781 ms | 性能监控 | **845 ms** | 健康评分 | 774 ms |

⇒ **九页全部 ≤1.0 s，T4 成立**（⚠ 09-23 15:50 复核：这批**没记测量环境**，而同机 A/B 连 `5a5d55c` 自己那份产物今天都量出 1.9~2.2 s ⇒ 这句只对"当时那组未记录的条件"成立，当前状态以 §6.1 的「待重测」为准；包 16 之后冷启动档才逐页写环境）；最慢的是"性能监控"页（它一起来就在采数据），顺序符合预期。
这条判据原先**在数学上不可能达标**：旧实现把 `life-cycle-period` 整表求和当首帧，
而 App 一直活到录制窗口结束 ⇒ 每页都算成 ≈10 s。改成 `launch_ready_ms()`（剔除运行期尾巴）
后才是真数，selfcheck 第 19 项三向钉（剔尾巴 / 无尾巴取末端 / 空表 None）。

### 1.6 随该读数一起落进尺子的五条口径规则（同日，`fd5d06e` 与后续两笔）

1. **比率不许跨出帧机制裸比。** `render 超预算帧` 原先并排打 `0.42%` 与 `4.97%`，
   读出来就是"恶化 12 倍"，而两边帧数是 **10 对 9**——差的全是分母
   （基线 20 s 连出 2394 帧 ≈120 fps；本次同窗口 181 帧 ≈9 fps）。
   ⇒ `BASELINE` 补上 spec §1 明写过、但只进过百分比的 **`render_total_frames=2394`**，
   新增纯函数 `regime_note()`：出帧速率相差 >2 倍即报"机制不同 + 倍数"，
   任一分数缺失一律按不可比（不猜）。判定列继续按**绝对预算**判，跨趟的话由它明说不能讲。
2. **未受控的对照列不许当"从 X 降到 Y"的 X。** §1.3 早已判那批数未受控，可这条规则
   **只写在注释里**——表一打出来 `84.8% → 23.3% | 改善` 就是一份结论。
   ⇒ 规则进数据（`BASELINE["controlled"]=False` + 原因），表头自己声明身份，
   相关判定改口"对照列未受控→不判趋势"。**没有**顺手换成绝对阈值：
   `84.8%` 是"主线程占**本进程**样本"，§3 的"空闲 ≤2%"是"占**墙钟**时间"，
   两个分母不同名，拿一个判另一个就是换个口径冒充判据。
3. 附带修的崩表：`trace_report.py summary <目录>`（它文件头自己推荐的入口）在真产物上必 TypeError——
   `meta.json` 的秒数是 shell 变量塞进去的**字符串** `"20"`，而自测第 7 项的夹具写的是**数字** 20
   且 `|| true` 吞退出码 ⇒ **夹具全绿、真跑必崩**。
   ⇒ 加 `as_int()` 收敛三处来源；夹具改成照生产侧形状（字符串秒 + 一份带 `id` 的 `hitches.xml`），
   并断言速率 `2 次 / 20 s = 0.10 /s`——这样"秒数没当分母"与"崩表"两个方向都咬得住。
   反向验三次（`regime_note` 永真 / 撤 `as_int` / `as_int` 恒返 0）都能红，恢复后 16 项 0 失败。

4. **闸门新增第六维：被量的二进制必须就是这份代码。** 见 §1.5 开头那条自纠——
   `HEAD=` 只证明"我在哪棵树上按了回车"，不证明"我量的是哪个二进制"。
   ⇒ `provenance_ok(<manifest rev>, <HEAD>, <构建时 clean>)` 纯函数：三个失效方向
   （rev 不同 / 读不到 `dist/RELEASE_MANIFEST.env` / 构建时工作树本来就脏）一律拒，
   放行方向也必须钉（否则又养出一条恒拒的闸门）；selfcheck 第 14 项五向对账。
   `measurement-context.txt` 同时多印一行 `产物构建rev=… 构建时树clean=…`，
   让人**不用跑脚本也能看见两行 rev 对不对得上**。
5. **对照列的文字不许是字典的第二份手抄。** `fmt_row` 里原先抄着
   `p50 2.73 / p95 4.06 …`、`684/807 = 84.8%` 等 14 处字面量，
   而同一批数在 `BASELINE` 里还有一份——§1.4 那轮更正恰好证明这两会分叉。
   ⇒ 七个 `base_*_line()` 生成器 + selfcheck 第 15 项双向钉
   （"改字典文字必须动"与"打印行不许再出现这些数"）。扫描面是**除注释行以外的整份文件**，
   不是"含 `fmt_row(` 的行"——后者会漏掉续行上的字面量。


### 1.5g 度量链今天下午新长的四条规矩（每条都对应一次真实失效） —— **内容已搬进本目录 `2026-09-20-perf-baseline-detail.md` 的同号小节，一行没改写。**
（09-24 19:45 拆卷：本规范撞上全仓 ≤800 行口径，搬走的只是历史读数明细；规范性条文与被引用最多的 §1.3/§1.4 留在原地，小节编号不变。）

## 2. 能力边界（编译探针实测，`xcrun swiftc -typecheck -target arm64-apple-macos14.0`）

| 能力 | macOS 14 下限 | 结论 |
|---|---|---|
| `CVDisplayLinkCreateWithActiveCGDisplays` | 可用 | 帧节拍内建探针的**兜底**时间源（主时间源见 §2.1） |
| `CGDisplayCopyDisplayMode(...).refreshRate`、`CGDisplayCopyAllDisplayModes` | 可用 | 运行时取真实 Hz，**不硬编码 120** |
| `os_signpost`（`OSSignpostID` 老式 API） | 可用 | 打点；`OSSignposter` 新式 API 的 `emit`/`signpost` 成员在本 SDK **签名不同，用前先探针** |
| `TimelineView(.animation(minimumInterval:paused:))`、`Canvas` | 可用 | 重画曲线/矩阵的原语 |
| `EquatableView(content:)`、`View.drawingGroup(opaque:colorMode:)` | 可用 | 手工短路重算 |
| `CADisplayLink` | **可用——但只能经 `NSView.displayLink(target:selector:)` 拿到**（见 §2.1） | 直接构造子 `CADisplayLink(target:selector:)` 在 macOS **不可用**；成员 `preferredFramesPerSecond` / `frameInterval` / `preferredFrameDuration` 也不可用 |
| MetricKit 的 `MXAnimationDiagnostic` / `MXMemoryDiagnostic` / `MXCPUDiagnostic` | **macOS 上不存在**（只有 `MXMetricManager`、`MXAppLaunchMetric`） | 线上帧率回传方案不成立 |
| `GlassEffectContainer` / `.glassEffect` | 仅 macOS 26 | 闸门仍只准集中在 `Design/Glass.swift` |
| `.containerBackground(_, for: .window)` | 仅 macOS 15+ | 需 `#available` 兜底，同样只准集中在 Design 层 |
| `onScrollPhaseChange` / `onScrollGeometryChange(for:of:action:)` | **仅 macOS 15+**（14 下限报 "only available in macOS 15.0 or newer"） | T3 不能用它们（页面禁散写 `#available`） |
| `NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDragged, .rightMouseDragged])`、`NSScrollView.didLiveScrollNotification` | **macOS 14 可用** | **T3 交互期暂停就走这条**（见 §4.1） |
| 本机运行系统 | **macOS 26.5.2** | 真玻璃路径在本机生效，测出来的数就是 26 路径的数 |

### 2.1 纠正一处我自己写错的结论（15:33 复核，编译探针）

本文件初稿在 §2 写过「`CADisplayLink` 不可用 → 照抄 iOS 帧率方案这条路是死的」。**那是错的**，
错因就是我刚在别处提醒过别人的那个坑：**半截探针会得出反向结论**。我探的是
`CADisplayLink(target:selector:)` 直接构造子（确实 "unavailable in macOS"），
但**没有探 `NSView.displayLink(target:selector:)`** —— 它返回的正是 `CADisplayLink`，
且整套在 macOS 14 下限可用：

```swift
let dl = someView.displayLink(target: handler, selector: #selector(H.tick(_:)))  // -> CADisplayLink
dl.add(to: RunLoop.main, forMode: .common)     // 注意：add(_:) 单参版不存在，必须 to:forMode:
dl.isPaused = true                             // 不是 .paused
dl.remove(from: RunLoop.main, forMode: .common); dl.invalidate()
// 回调参数可用成员：timestamp / duration / targetTimestamp
// 不可用成员：preferredFrameDuration / preferredFramesPerSecond / frameInterval
```

**结论改动**：`FramePulse` 的主时间源从 `CVDisplayLink` 升级为 **`NSView.displayLink` 拿到的
`CADisplayLink`**（它是"这个视图所在显示器真正呈现的节拍"，比 `CVDisplayLink` 的"显示器名义节拍"
更贴近用户看到的卡顿）；`CVDisplayLink` 与 `CGDisplayMode.refreshRate` 降为**无窗口时的兜底与名义 Hz 来源**。
两把尺子仍然互相校验，但**不得共享同一盲区**：`displayLink` 挂在具体 `NSView` 上，
测不到"窗口不可见时"的行为，这部分留给 xctrace 外部尺子。

## 3. 目标（T1~T9，全部可机器断言）

### 3.0 口径出处（Apple 原文，不是我自己推的）

来源：Apple Developer Tech Talk **《Explore UI animation hitches and the render loop》**
（`developer.apple.com/videos/play/tech-talks/10855/`），以及其推荐的配套会话
《Eliminate animation hitches with XCTest》（WWDC20 `wwdc2020/10077`）、
《Find and fix hitches in the commit phase》《Demystify and eliminate hitches in the render phase》。

| Apple 原文口径 | 本规范怎么用 |
|---|---|
| hitch =「**any time a frame appears on screen later than expected**」 | 判据定义，不自造 |
| 帧预算：60 Hz 每 **16.67 ms** 出一帧；ProMotion 120 Hz 每 **8.33 ms** 一帧 | T1/T2 的预算值来源（本机 `device-display-info` 实测 120Hz ⇒ 8.33ms） |
| 正式指标是 **Hitch Time Ratio**（一段时间内 hitch 总时长 ÷ 该段时间，单位 **hitch-ms/秒**） | **主指标改用它**；我原先写的"hitch ratio < 0.1%"是自造口径，**撤销** |
| 档位：**<5 无感**；**5–10 用户可察觉、需排查**；**>10 严重影响体验、需立刻处理**；**理想 = 0** | T1 验收线 = **<5，目标 0**；run1 实测 **11.67 ms/s** 属"危急"档 |
| hitch 分 **commit hitch**（本进程错过 VSYNC：布局/绘制/事件处理慢）与 **render hitch**（render server 侧） | 归因分层：本轮打的全是 commit 侧（`_updateViewGraph`），render 侧实测健康 |

**本仓库的算法**：`HTR = Σ max(0, 帧时长 − 预算) / 录制秒数`，数据源是
`Animation Hitches` 模板的 `hitches` 表（帧时长）。这是 Apple 定义的**保守上界**
（它按"晚了多少"算，我们按整帧时长减预算算，不会低估）。已实现进 `trace_report.py`。

- **T1 交互期不掉帧**：切页 / 滚动 / 悬停 / 拖窗 / resize 期间 **Hitch Time Ratio < 5 ms/s，目标 0**；
  p95 帧间隔 ≤ **8.4 ms**、p99 ≤ 16.7 ms。改动前基线（未受控，见 §1.3）**= 11.67 ms/s（`perf_harness.sh report` 实算，非口算）= Apple 的"危急"档**。

- **T2 心跳不越一帧**：1.5 s 一次 publish 引起的 **app-update 相位 ≤ 8.33 ms**（冲刺目标 4.0 ms）。
  起点 10.8~24.8 ms ⇒ 需要 **2~6 倍**收窄，只靠"少画几个点"不可能达到，必须收失效面。
  - **T2 的归因已经拆成两半量掉了（2026-09-20 23:49，`PerfMainThreadBudgetTests`，无需等安静窗口）**：
    | 心跳里的一段 | 实测 | 在哪个线程 |
    |---|---|---|
    | 九格 publish（每格各写一次变了的新值，载荷含两张 20 条榜单 + 90 点曲线 + 组表） | **中位 0.01 ms** | 主线程 |
    | 派生 `PerfLeads.derive`（900 进程、12 组、两次排序 + 组匹配，取实测 260~920 的上沿） | **中位 9.3 ms** | **后台**（M0 已挪走） |
    结论口径要说准：**这里量的是"写入本身"**——测试进程里那些格子背后没挂 SwiftUI 视图，
    所以"写入 → 视图重算"那一段不包含在内，那一段只能由 xctrace 量（也正是 §1 那 10.8~24.8 ms 的所在）。
    而这恰恰是它的价值：写入侧只有 0.01 ms，**采集侧重活已经在后台**（9.3 ms 不占主线程，
    按 0.67 Hz 折算约占一个核的 0.6%），所以 4.0 ms 预算**不可能**被采集/publish 撑爆——
    超支必然发生在"失效之后的重算"，也就是工单 §0.4 第 1 步那 16 处粗读点——
    **但其中只有 10 处承重**：`publish()` 里只有 `latestSnapshot`/`history` 是无闸门写（每 tick 必然换值），
    另外五处粗属性已经走等值闸门，单独迁它们在帧率上测不出差异（分级由守卫从源码现读，非手抄）。
    **这一条把"该改哪儿"从推测变成了排除法**，且两半都不依赖帧率窗口即可复现。
- **T3 交互优先**：滚动 / 拖窗期间冻结实时写入，交互停止 150 ms 后恢复（用户已批准）。
  **不新增"未刷新"占位态**（`DesignAbsenceStateTests` 的 `bypassCeiling = 1` 只减不增），
  暂停期显示的仍是真实末值。若任何一次暂停实测 >500 ms，本条判失败并回退。
- **T4 冷启动**：到可交互 ≤ 1.0 s（`App Launch` 模板），首帧 ≤ 3 个显示节拍。
- **T5 主线程禁则**（静态守卫钉死，见 §4）：`body` 与图表 Mark 闭包内 **0 次** new
  `NSColor` / `DateFormatter` / `NumberFormatter` / `Font`；**0 次**全量 `sorted`/`filter`/`reduce`；
  **0 次**同步文件 I/O（`stat`/`Data(contentsOf:)`/JSON 解码）。
  - **T5 的"零"到底指什么（2026-09-20 23:35 明写，防止被读成"把令牌引用删光"）**。
    C 包落地后 `ColorToken`/`ThemeTokens` 的 `color`/`font` 已是**存储常量**，
    守卫里 `dynamicNSColor` 那条正则量的东西随之变了：**不再是"每 tick new 多少个 `NSColor`"，
    而是"渲染路径里引用令牌成员的次数"**。
  - **2026-09-22：那条混用的尺子已经拆成两条。** 上面这段"语义变了"的结论是对的，
    但当时**只改了说明、没改尺子**，于是留下两个方向的失效，都是实测撞出来的：
    ① `dynamicNSColor` 顶到 62/62 零余量后，谁在 body 里新写一处**正确**的令牌取色就把闸门打红；
    ② 真正该拦的现造形状 `Color(nsColor: …)` **一条规则都不抓**
    （`directFormatters` 的模式只列 `NSColor|DateFormatter|NumberFormatter` 后跟 `(`，`Color(` 不在内），
    现扫立刻抓到 2 处（`Views/Shell/SidebarRows.swift`、`Views/Shell/ProjectSidebar.swift`）。
    ⇒ 拆成 `dynamicColorConstruction`（现造＝债，终点 **0**）与 `tokenReference`（引用＝**读数**，终点不是 0）。
    另记一条反面教训：那 8 处 `Design/**` 的引用曾被读成"性能侧还有一趟缓存化可做"，
    实际 `role(for:)` 返回 `static let`、`.textColor` 读的是 init 里算好的 `let color`——
    **去做这趟只会把 62 抬成 54 而运行时一个字节都不省，是假还债。**
    所以五条禁则的终点并不一样：
    | 规则 | 现量/上限（2026-09-22 复扫） | 终点 | 为什么 |
    |---|---|---|---|
    | `directFormatters` | 1/1 | **0** | 真违规：渲染路径里现造 formatter |
    | `dynamicColorConstruction` | 2/2 | **0** | 真违规：渲染路径里现造动态色（2026-09-22 起才有尺子；归 UI 流） |
    | `fullSort` | 9/9 | **0** | 真违规：body 内全量排序（缓存或挪到 publish） |
    | `syncFileIO` | 2/2 | **0** | 真违规：body 内 `exists`/`attributesOfItem` |
    | `tokenReference` | 62/**下限 40** | **不是 0，也不是债**（#68 起它是**读数**，住 `PerfHitchGuardTests+Readings.swift`）。取色本身没错，错的是"每次访问现造"。⚠ 2026-09-22~09-25 期间它曾以 `62/62` 零余量**上限**的形式留在债表里，于是"body 里新写一处正确的令牌取色"会被门禁打红——那正是这条拆分的初衷的反面，机制与注释互相矛盾了三天。达标判据仍是两件事：① `Design/**` 里不许再出现 `var color: Color {` 这类计算属性（已有守卫）；② 引用点不许嵌在 O(n) 循环 / Mark 闭包里重复求值（**这条靠人工核，不靠上限**——上限只会拦错方向）。 |
    **不许为了凑"零动态色"去删令牌引用**——那会同时砸掉观感一致性与 T8（颜色承载语义），
    属于"为了指标改语义"，是本规范第一条禁止的事。
- **T6 合成层预算**：内容层 0 填充、投影只给 `.floating`、每屏材质/backdrop 层 ≤ 2。
  理由记在观感账上（§1.1），不记在帧率账上。
- **T7 扫描期仍可交互**：扫描（实测 Git 11.4 s / 代码 1830 ms）运行中点击响应 ≤ 100 ms，
  分析器不得占住 `@MainActor`；`sampleNow` 这类全量 sweep（260~920 进程）一律离开主线程。
- **T8 诚实性不降级**：两帧才出速率、缺数据 `--`、轴台阶 ∈{1,2,2.5,5}×10ⁿ 且只抬不降 ≤2 倍、
  不可信点从曲线剔除并在卡面计数、`historyTruncated` 窗口标注、零证据不得给满分——
  **一条都不许为了帧率改语义**。`PerformanceDisplayTests` / `PerformanceMemoryHonestyTests` /
  `HealthScore*Tests` 全绿是硬门禁。
- **T9 只减不增**：hitch 数、单次 update 时长、主线程样本占比、T5 三类禁则命中数，
  全部进回归门禁；任何回退判红。**阈值不许为了变绿而放宽。**

## 4. 尺子（M0 先落，先量后改）

1. `scripts/perf_harness.sh`（新）：**七档**，全部只读——`idle`（attach 现有实例，录 Animation Hitches +
   Time Profiler，**期间不碰它**）、`interact`（录法同 idle，唯一区别是**期间持续有滚动**：
   真人或 `INPUT=synth` 的 CGEvent 投递）、`switch`（逐页冷启动）、`report`（重打已有目录）、
   `probe`（读 `FramePulse` 脉冲，`--start` 可现采）、`pulse`（**边投合成滚动边读全部帧的间隔分位数**）、
   `selfcheck`（拿合成夹具验尺子自己）。解析封装在 `xctrace export --xpath` 逐表导出 +
   `perf_trace_xml.py`（id/ref 解引用）/ `perf_trace_metrics.py`（统计与 §1 基线）/ `trace_report.py`（子命令），
   出一张固定形状的结果表（hitch 数、hitch/s、帧时长分布、app-update 分布、`potential-hangs`、
   主线程热点 Top20、按线程样本数）。**表头第一行写「测量期间」**：`idle` 那批明说
   "只答心跳期，不许拿去交 T1"，`interaction` 那批才标"有资格答 T1"——两批数同形状不同含义，
   不写进表头就一定会有人混着用（本仓反复踩的"口径不对齐"）。输出目录**必须带被拍二进制自己的 rev**
   （`$SCRATCH/tcoder-perf-<rev>/`，即仓库内被忽略的 `.scratch/`；rev 从 manifest 取、由脚本自己拼，
   2026-09-26 §171 手填 HEAD 造出过错归属批次），否则后一批覆盖前一批。

   ### 4.0 每条判据由哪个仪器回答（2026-09-22 补，因为发现有一条压根没人量）

   | 判据（验收句里的半句） | 直接仪器 | 说明 |
   |---|---|---|
   | 交互期 **hitch 帧 = 0** | xctrace `hitches` 表（`interact` 档） | 它只列**超预算**的那些帧 |
   | **p95 帧间隔 ≤ 8.4 ms** | **只有 `FramePulse`**（`pulse` 档 / `probe` 档） | 这是**全部帧**的分位数；hitches 表没有这一列，`displayed-surfaces-per-second` 也只有"每秒几张"——09-22 之前这条**没有任何仪器在量** |
   | 1.5 s 心跳主线程占用 ≤ 4.0 ms | xctrace `hitches-updates`（`idle` 档） | 逐次 update 时长；只用 max 判会同时说反两件事（见 §1.6） |
   | body/Mark 零动态色/零排序/零同步 I/O | 静态守卫 `PerfHitchGuardTests` + 台账 | 每条打"现量/上限"并逐条可点名。**这句的真实射程（#65，09-25 写死）**：跨度只认 `var body: some View` 与 `Chart { … }`；helper 跳展开**只在同一份文件内**；词表认的是那几类形状（09-25 起含 `resolvingSymlinksInPath()` 与 `Process(`/`NSTask(`）。⇒ 它答的是"**渲染跨度内**没有这些写法"，**不答**"主线程在任何地方都没打过盘"——后者由 §D-持久化 那条量级尺与 T2/T4 的实测管 |

   ⇒ 交叉核对的义务：`pulse` 读的是 **CVDisplayLink 回调送达时刻**，不等于"上屏时刻"。
   同一次 `interact` 采样里的 `displayed-surfaces-per-second` 是独立第二把尺子
   （若出帧 ≈120/s 而 p95 仍 9.1 ms，说明尾巴在回调时序而非呈现上），
   两者不一致时**谁都不许单独宣布达标或未达标**。
   **不设合成输入的 `scroll` 档**（原计划里有，现撤）：合成滚轮要 `CGEvent.post`，而本机 System Events
   权限被拒（§4.1 探测时实测），事件会被静默丢弃——那会造出"交互期 0 hitch"的**假绿**。
   交互由人真滚，`interact` 档负责把它标成交互期样本。
   **【19:38 实况修订：这条撤因的前提被今天的排演推翻，撤销它】**
   原句把两件不同的东西混成了一件：**System Events 的 AppleScript 路线**确实被权限拒过
   （取证脚本 `osascript` 那条路），但 `perf_synth_scroll.swift` 走的是
   `CGEvent(scrollWheelEvent2Source:units:.pixel,…)` 投给**目标 pid 的窗口中心**，不经 System Events。
   实测证据（2026-09-22 19:23 排演，脚本 `TcoderMonitor/.scratch/rehearse_synth_pairing.sh`——
   `.scratch` 会被清，所以这里把**读数原文**留下，不拿路径当证据存活）：
   投事件**前**静默探针读 `scrollWheel=1502.24s 静默=756.95s`，投事件**中**读
   `scrollWheel=0.00s 静默=0.00s`，同一把尺子（`input_quiescence.swift` 用
   `CGEventSource.secondsSinceLastEventType(.combinedSessionState, …)`）当场翻转 ⇒
   **事件真进了系统事件流，没有被静默丢弃**。
   历史上那两批 25 Hz 合成读数被移出充数，原因是**输入节奏不对**（25 Hz 冒充不了 120 Hz 体感），
   不是"事件没投递进去"——这两条撤因当时被混着引用，害得我差点又放弃一次可自动化的档。
   ⇒ 现在 `INPUT=synth`（14px/8ms ≈ 125 Hz 事件节奏）是**合法输入源**，写进 meta 的
   `input_source` 与 `scroll_target` 两栏，谁引用谁负责注明节奏。
   **一条仍然没证的东西（不许顺手当成已成立）**：合成滚动有没有触发 App 自己的
   `NSEvent` 本地监视器、也就是 T3 的"交互期暂停实时刷新"。
   这半句要从**同一趟样本的 Time Profiler 表**里判：若 `MachSystemMonitor` 的采样回调
   在这 20 秒里仍按 1.5 s 节奏出现 ⇒ 暂停没触发 ⇒ 这批数读的是"一边刷新一边滚"的混合态，
   方向上**比真实交互更严**（不是假绿），但必须注明，不许当"用户体感"引用。
   **02:31 补第二条独立的撤因（免得下一个人重新想到同一条路）**：也**不要**改成"让 App 自己滚"
   （进程内 `NSScrollView` 程序化滚动，看起来能绕开权限）。它绕开了权限，却绕不开语义：
   T3 的暂停是靠 `AppState` 的 **`NSEvent` 本地监视器**认"有人在滚"（§4.1），
   程序化滚动**不产生 NSEvent**，于是监视器不触发、实时刷新不暂停——
   测出来的将是一个"一边刷新一边滚"的混合态，与真实交互不是同一件事。
   **要自动化就必须连暂停语义一起造，而那等于测我自己造的假现场。**
   ⇒ ~~T1 的这一档必须人滚 20 秒，这是度量前提，不是工具没做完。~~
   **19:38 改口**：人手**或** `INPUT=synth` 都行——两者共用同一道开录闸门与同一道收尾复核
   （那两道读的是 `.combinedSessionState`，本来就不区分手与 CGEvent）。
   前提换成了另一条更实的：**滚动必须落在被 xctrace attach 的那个 pid 上**，
   所以合成投递改由录制档发起（`MEASURE_LAUNCH=1`，见工单包 8），排程器不再自己起实例。
2. `FramePulse`（新，`Services/Performance/`）：`CVDisplayLink` 时间戳 + 主线程 runloop 心跳看门狗
   + `os_signpost`，**仅 `TCODER_PERF_PROBE=1` 时启动**（常驻开销不可接受），
   读数落 `$TCODER_PERF_OUT` 或 `/tmp` 文件——**取证 print 必须落文件**，`swift test` 会丢子进程 stdout 后半段。
   它是常驻门禁的尺子，与 xctrace 这把外部尺子**互相校验**（两把尺子不得共享同一盲区）。
   **一条语义边界（09-21 写死，也写进了脉冲文件的文件头）**：`心跳最大间隔` 是主线程 runloop
   两次「结束等待」之间的**唤醒间隔**，不是"主线程被占住多久"——那段时间没事件时它同样很大。
   所以 **T2（心跳主线程占用）只认 xctrace 的 `app-update` 相位**，`FramePulse` 对 T2 不举证；
   `FramePulse` 举证的是 **T1 的帧间隔 p95**（它跟着真实出帧节拍）。
   把这句话写进产物文件头，是因为"读错自己的仪表"不需要人犯错，只需要仪表的字段名含糊。
   2026-09-20 补：这把尺子原先**只产数不读数**（没人解析那个文件），已补
   `perf_framepulse.py` + `probe` 档，并由 `PerfFramePulseRulerTests` 拿**产品真实产出的摘要行**
   跨语言对账格式（Swift 侧改字段名 → 那条立刻红，而不是静默把"没数"读成"0 hitch"）。
3. T5 三条静态禁则守卫 + **每条配元测试**（故意造违规样本确认它会红）。理由见记忆
   「扫描型测试要配元测试」：本仓上一轮的病因正是"令牌定义了但零引用"，旧守卫查不出来。
   同一道理现在也覆盖尺子自己：`selfcheck` 六项里每项都配了反例（把已修的缺陷放回去，它必须红）。

## 4.1 T3「交互期暂停」的实现位置（由探针决定，不由偏好决定）

候选 API 探测结果：`onScrollPhaseChange` / `onScrollGeometryChange` 是 **macOS 15+**，
而红线禁止页面散写 `#available`（AGENTS.md §3 横切约束 1、无界红线 7）→ **不能用**。
可用的是 **macOS 14 就有**的 `NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel,
.leftMouseDragged, .rightMouseDragged])` 与 `NSScrollView.didLiveScrollNotification`。

因此机制定死为：**`AppState` 装一个本地事件监视器记 `lastInteractionAt`**，心跳 tick 到来时
若 `now - lastInteractionAt < 150ms` 就**跳过发布**；页面**零改动**、Design 层零 `#available`。
两条硬要求：
1. **暂停不许丢数据**：跳过的帧仍要进环形缓冲，恢复时一次性补齐；**严禁把暂停期画成 0 或空白**
   （那等于制造假读数，违反 T8 与 `PerformanceMemoryHonestyTests` 的精神）。
2. **暂停不许变成"永远暂停"**：监视器必须成对释放；单次连续暂停实测 **>500ms 即本条判失败并回退**。
   实测方式：人在装了 `TCODER_PERF_PROBE=1` 的实例上滚 / 拖窗若干秒，
   再 `perf_harness.sh probe <脉冲文件> --interaction` 读帧间隔分布。
   **不做合成输入**（本机 System Events 权限被拒，`CGEvent.post` 会被静默丢弃，
   那只会造出"交互期 0 hitch"的假绿），拿不到脉冲文件就**明写"未覆盖"**，不许拿 idle 档的数冒充。

## 4.2 归因档（`BLAME_INSTRUMENT=1`）：只回答「这段卡在跑什么」，不参与 §1.3 的达标判定

**为什么单独一档**：长 `update` 的调用栈归因要求 hitches 家族与 Time Profiler 落在**同一次录制**里，
否则两条时间轴是两个窗口，join 出来的栈属于另一段时间——数字各自都真、结论是假的，
这比报错难发现（它看着就是一张正常的归因表）。开法：

```bash
MODE=idle BLAME_INSTRUMENT=1 scripts/perf_run_batch.sh blame1 3 1800
python3 scripts/perf_update_stacks.py <那一趟的产物目录> --min-ms 100
```

**这一档被结构上挡在达标之外**，不靠自觉：`period_eligibility`（住在 `perf_eligibility.py`）
读到 `meta` 里的 `blame_instrument=1` 就判「不给资格」，报表表头与一致性尺 `_meta_or_none`
共用同一个出口 ⇒ 一个问题上只有一把判据。理由不是洁癖：这一档在被测进程身上多挂了一枚 1 ms 采样器，
拿它去认证「没被采样器改过的条件」就是自欺。

**尺子的三条口径**（写在 `perf_update_stacks.py` 头注，判定处只此一家）：
同窗是硬前提（`meta` 里没有 `blame_instrument` 就**拒绝出数**，显式写 `0` 也拒）；
窗口里 0 个样本只能说「取不到」，不能说「没有栈」（1 ms 采样有空隙）；
叶子帧剔掉 RunLoop 管道帧，但剔掉多少照印。
行→事件与达标口径共用 `unique_event_spans`——一条 update 在表里带多枚 `event-concept`
（Brown 与 Red 各占一行），所以是「6 行 → 3 个事件」，不是重复录制。

**归属必须出声**：手动 `--attach` 出来的探针档没有 `binary=` / `measured_rev=`，
尺子会先打一行「⚠ 这份栈说不出属于哪份内容……只能当线索，不许写进缺陷单」。
这不是假想——2026-09-25 就被这种形状骗过一次：那批 `_platform_memcmp` 热点其实来自
`.scratch/rev-trees/<旧 rev>` 的产物，不是当时的 main。

**守卫**：selfcheck 第 63 项十格（同窗、双行收成事件、区间外不许点名、别家进程不许顶包、
没采到栈写「取不到」、管道帧剔掉但照印、缺表拒跑、归属三态）＋第 63b 项（附加仪器确实作为
**一个**参数进 `xctrace`、导出落 `blame-time-profile.xml` 而不盖掉认证档那份 `time-profile.xml`）。

## 5. 分工（零文件重叠，按"谁消费谁负责"）

### M0 总工串行（不占三家名额，`ws/perf-base` 一棵树，我 merge）

**实况修订（2026-09-20 15:16，边写边被并行会话抢先落地）**：下表 S/T 两包**已由并行会话的无界基座落进 main**
（`6ca0578` 令牌、`6d7b35e` 表面换血、`04453f6` DataTable 上提，tag `m0-borderless-base`）。
本文件 §1 的基线数字取自 `465f5a6` 产物，即**无界基座之前**的读数——复测时必须注明这一点，
否则会把"表面换血"的收益错记到性能工头上。M0 实际剩余独占有三件：

| 包 | 内容 | 路径 | 归属 |
|---|---|---|---|
| R 尺子 | `perf_harness.sh`、`trace_report.py` + `perf_trace_xml.py` + `perf_trace_metrics.py` + `perf_framepulse.py`、`FramePulse`、T5 守卫 + 元测试 | `scripts/**`、`Services/Performance/FramePulse.swift`、`Tests/TcoderMonitorTests/Perf*Tests.swift` | 总工独占（新建文件，零重叠） |
| P 心跳链路 | `publish` 拆细粒度读模型、派生榜单（`processesByMemory`、`history.suffix(90)`）在 publish 里算一次并缓存、`sampleNow` 移出主线程、T3 交互期暂停 | `Services/Performance/**`(除 FramePulse)、`App/AppState.swift`（本轮解冻，`SystemSnapshot` 契约不动） | **无界三家按 spec 不得碰 `Services/**`，此包总工独占** |
| C 令牌缓存 | `ColorToken.swift` 每次访问 new `NSColor(name:nil){}` → 缓存；`ThemeTokens` 的 `var font: Font {` 计算属性 → `static let`；`ChartTokens.areaGradient` 每调用现造 `LinearGradient` → 按 (index,intensity) 缓存 | `Design/**` | **与无界轮 `Design/**` 归属冲突，待用户裁定后才能动**（见 §7.7） |

`SourceFileReachabilityTests` 的 `censusBaseline`、800 行棘轮、`DesignTokenTests`/`DesignKitTests`
里钉当前值的断言，**只由总工在 M0 串行更新**，三家一律不许自己翻基线。

### M1 三家并行（各一棵工作树、各 ≤3 子代理、一家同时只跑 1 个编译）

| 流 | 页面 | 独占 Services | 性能包（除无界化重排外） | Obsidian |
|---|---|---|---|---|
| **WS-O** 外壳与总览 | `Views/RootView.swift`、`Views/ProjectDetailView.swift`、`Views/DashboardView.swift`、`Views/Shell/**` | — | 侧栏与总览**脱离心跳失效面**（`ProjectSidebar.sidebarFooter`、`DashboardView.snapshot`、`CPUHistoryChart`）、`AnyView` 归零、`ReadoutStrip`、T3 暂停接线到滚动 | `80 WS-O 外壳与总览无界化.md` |
| **WS-P** 代码与 Git 五页 | `Views/Code/**`、`Views/Git/**`、`Views/Dependencies/**`、`Views/CodeGit/**` | `Services/Code`、`Services/Git`、`Services/Dependencies` | 720 柱 + 168 格矩阵改 `Canvas`/lazy、稳定 identity（去 `id: \.offset`）、body 内派生集合缓存、扫描 11.4 s / 1830 ms 离开主线程且不重入 | `82 WS-P 代码与Git五页无界化.md` |
| **WS-W** 性能·日志·评分 | `Views/Performance/**`、`Views/PerfLogs/**`、`Views/Health/**`、`Views/Logs/**` | `Services/Logs`、`Services/Health` | `LogsView.attachedItems` 的 `body` 内 `stat()` 移出、图表渐变与 `suffix(90)` 缓存、`DateFormatter` 提 `static let`、进程榜 20 行的 `.help` 拼串降本 | `84 WS-W 性能日志评分无界化.md` |

三家共同红线（沿用 AGENTS.md §3 与无界化 spec §5.2）：
不得改 `Design/**`、`App/Theme.swift`、`Models/**`、`Package.swift`、`Services/Performance/**`（M0 后归总工）；
视图签名 `XxxView(report: ProjectReport?)` 冻结；新文件 ≤800 行；
拍图必须 `SWITCH_MODE=argv` + 各自 `CAPTURE_SANDBOX` + 带**被拍二进制 rev** 的输出目录（用 `paired_page_evidence.sh`，它自己从 manifest 取名）；
交回前先 `git merge main`，再 `locked_build.sh build --build-tests` + `test` 双绿 + `premerge_check.sh`；
**每组先过门再 commit**（子代理有 150 轮上限，截断时未提交的只剩磁盘）。

### M2 总工收口
逐家过门合入 → 终测（同一把尺子复测，前后逐列对齐）→ `capture_pages_isolated.sh` 九页×深浅取证 →
更新 `docs/九页实拍读数.md`、`README.md`、`docs/口径与已知限制.md`、Obsidian `90` →
确认 `ahead=0 && dirty=0` 后 `git worktree remove` + `git branch -d` 清树。

## 5.1 跨流共同禁则：采样节拍与窗口只许一个来源（15:50 实拆）

`docs/口径与已知限制.md` 记的是"三处独立字面量"，**实测是六处，而且节拍本身也有两处来源**：

| 形状 | 位置 | 风险 |
|---|---|---|
| 节拍代码来源 × **2** | `AppState` 的 `monitor.start(intervalMilliseconds: 1_500)`、`MachSystemMonitor` 内部默认路径的 `start(intervalMilliseconds: 1_500)` | 两处各写一份，改一处另一处照旧跳 1.5s |
| 显示字面量 × **4** | `DashboardView` 副标题"每 1.5 秒采样"、`PerformanceLiveCharts` 副标题"每 1.5 秒"、`PerformanceProcessGroups` 提示"约 1.5 秒后"、`PerformanceView.sampleIntervalText` | 节拍一改，界面就**说谎** |
| 节拍进算术 × **1** | `PerformanceView.windowSeconds`（`Double(chartPointLimit) * 1.5`） | 窗口秒数静默失配，而它同时是曲线轴的依据 |

**规矩（M0 由 P 落，M1 由三家消费）**：

1. `MachSystemMonitor` 暴露**唯一**节拍真值（毫秒数 + 由它派生的展示文案 + 由它派生的窗口秒数），
   `AppState` 只在启动处传一次，不许再出现第二个 `1_500`。
2. 上述 4 处显示点与 1 处算术点**一律改为读该真值**；页面里**不许再出现 `1.5` 这个字面量**
   （`ChartChrome` 的 1.5pt 线宽、`HealthComponentTable` 的 ±1.5 容差、`barRadius 1.5`、
   侧栏宽度注释里的 1.5 GB 与节拍无关，**不在禁列**，守卫的锚点必须按语义区分，不许整词 grep `1.5` 判红）。
3. 守卫：`Views/**` 里"采样节拍语义"的 `1.5` 字面量计数**只减不增**，基线 = 本表 5（4 显示 + 1 算术），
   目标 0 由 WS-O（1 处）+ WS-W（4 处）在 M1 清零。**元测试要用真形状**
   （`"每 1.5 秒"` 这种字符串），并且必须证明它不会把 `barRadius: CGFloat = 1.5` 误判成违规——
   两个方向都要测，否则这把尺子量的是个模糊集。
4. T3 交互期暂停让"上一次刷新距今"可以大于节拍值，**副标题不许继续显示"每 1.5 秒"当现状**：
   读数本身仍是真的（末值有效），但节奏文案要么随暂停态调整、要么由 P 提供"最近一次发布时间"入口，
   由 WS-W 在 M1 决定画法并交《预期视觉变化清单》。**这条不许 silently 选一个**。

## 5.2 M1 性能工单（与无界工单**同一次交付**，两家合并执行）

每条都带"改动前实测"与"交回时要拿出的数"。**没有数的报告按未完成处理。**

### WS-O 外壳与总览 —— 性能包

| 工 | 改动前实测病因 | 交回判据 |
|---|---|---|
| O-1 侧栏脱离心跳失效面 | `ProjectSidebar.sidebarFooter` 读 `monitor.latestSnapshot`，其失效域含整个 `List` 内容闭包 → **每 1.5s 重建全部项目行**（`ProjectSidebar.projectsSection`、`ProjectRow.body`） | 停在总览页跑 `perf_harness.sh idle`，`potential-hangs` 从 **13 次/25s → 0**；`ProjectRow` 路径上不再出现每秒级重建 |
| O-2 总览脱离整页重算 | `DashboardView.snapshot` + `livePerformanceCard` + `CPUHistoryChart.body`：一次 publish 让 4 枚 tile + 3 张静态卡 + 90 点×2 mark 全量重算；主线程 **64.3%** 样本在 `AG::Graph::UpdateStack::update()` | 主线程热点第一名**不再是** `_updateViewGraph`；总览页 app-update 相位 ≤ 8.33ms |
| O-3 `AnyView` 归零 | `GlassSection.trailing: AnyView?` 声明 1 处，Views 内 `AnyView` 13 处 | 全仓 `AnyView` 计数 **0**，且写进守卫（元测试自证抓得住坏样例） |
| O-4 切页首帧 | 无实测（待 `switch` 档基线） | 交 `switch` 档改前/改后同形状读数；**测不到就明写"未覆盖"** |

### WS-P 代码与 Git 五页 —— 性能包

| 工 | 改动前实测病因 | 交回判据 |
|---|---|---|
| P-1 密集矩阵降本 | `ContributorHourRow.bar(for:)`：30 行 × 24 柱 = **720 个 `RoundedRectangle` + 720 个 `.help(String(format:))`**，且 `peak` 每柱重算；`GitActivityHeatmap.body` 非懒 **168 格 + 168 tooltip**，`intensity` 内两次 `.max()` | 改 `Canvas` 或懒加载；交回给出**视图实例数改前/改后**（同一计数口径：`grep -c` 的调用点数 + 渲染期实例数算法要写清） |
| P-2 长列表懒加载 | **`LazyVStack` 实测仍为 0、`Table(` 为 0**（但 tile 网格已有 **11 处 `LazyVGrid`，那些别动**）；`DependenciesView.body` 用 `ScrollView{VStack}` 一次实例化 N 生态 × 40 行 | 名下五页**长列表**改 lazy；列头仍只能用 `Design/DataTable.swift`（红线 1，只许调用不许改） |
| P-3 body 内派生集合缓存 | `DependencySafetyVerdict` 在 body 里被构 4 次（每次 `flatMap`+`filter` 全量依赖）；`CodeRiskAnalysis.suggestions` ≈10 次 filter/map/max/reduce；`CodeDuplicationBlockRow.hint` 对**全部** occurrence 做 `pathTail`；`HealthView.historyPoints` 每 body 重排 | 命中数进 R 的 T5 棘轮基线并**只减不增**；名下页目标 0 |
| P-4 扫描离开主线程 | 实测扫描耗时 **Git 11.4s / 8.0s、代码 1830ms**；5 分析器 `async let` 并发 + 16 路 `classifyConcurrently`，扫描期 CPU 抢占为"高" | 扫描运行中点击响应 ≤ 100ms（T7），并给出 `perf_harness.sh` 扫描期读数；**扫描结果数值必须逐位不变**（不许为提速改口径） |
| P-5 稳定 identity | 实测 `id: \.self` **8 处**、`id: \.offset` **4 处**（勘查曾把两个数写反，见 §1.2；另有 `\.element` 6、`\.key` 1、`\.raw` 1 属可接受形状） | 名下页 `\.offset` 归零、`\.self` 只允许留在真正不可变且唯一的字符串键上，逐条给理由 |

### WS-W 性能·日志·评分 —— 性能包

| 工 | 改动前实测病因 | 交回判据 |
|---|---|---|
| W-1 `body` 内同步 I/O 归零 | `LogsView.attachedItems` 在**一次 body 里被求值 3 次**，每次对每个附加文件走一趟 `FileManager.attributesOfItem`（`LogsView.fileSize(of:)`） | 求值挪进 `@State` + `.task`，或把 `attachedItems` 改存储属性；R 的 T5-③ 守卫该流命中数**只减不增**（`fileExists` 在按钮动作里，不计入、不改） |
| W-2 图表降本 | `LiveSeriesChart.body` 每点 AreaMark+LineMark，**每 mark 现场构造 `LinearGradient` + 动态 `NSColor`**（C 包已把构造变成缓存，但重算面还在）；`trustedMemoryPoints` 每 tick 被跑 **4 遍 = 360 个 `SampleContext`**（`memoryAxis` 内访问 `trustedMemory` 两次 + 曲线一次 + `rejectedMemoryPoints` 为拿计数再一遍） | 停在该页跑 `idle`，app-update ≤ 8.33ms；`trustedMemoryPoints` 每 tick **≤ 1 遍**（`trustedMemory` 改存储属性或由 P 的缓存供给；计数不许靠重过滤整数组来求） |
| W-3 轴标签 formatter | **实测唯一定义点：`Views/PerfLogs/ChartChrome.swift` 的 `DateFormatter()`**（总工工单初稿误写成 `LiveSeriesChart.xLabel`，已改）；它在轴标签循环里逐次现造 | 提 `static let`；R 的 T5-① 守卫该文件命中 0 |
| W-4 进程榜 | `PerformanceProcessTable.row`：20 行 × 6 个 `LiveNumber` 格式化 + 每行 2 处 `.help` 拼串；`PerformanceView.rankedProcesses` → `MachSystemMonitor.processesByMemory` 每次访问全量 `sorted`（本机 `ps ax` = 920） | 排序消费 P 缓存的榜单（**不再自算**）；榜长与内容逐位不变 |
| W-5 消费 P 的细粒度契约 | 现状：性能页整页 body 读每秒变化的值 | 改读 P 在 M0 交付的细粒度入口 + P 的《必须迁移清单》，粗 API 棘轮该流命中数 → 0 |

**三家共同**：`AnyView` 归零（各自名下）、T5 三条守卫全绿且元测试自证、
**§5.1 的节拍唯一来源迁移**（WS-O 名下 1 处：`DashboardView` 副标题；WS-W 名下 4 处：
`PerformanceLiveCharts` 副标题、`PerformanceProcessGroups` 提示语、`PerformanceView.sampleIntervalText`
与 `windowSeconds` 的算术；WS-P 名下 0 处）、
`git merge main` 后 `build --build-tests` + `test` 双绿 + `premerge_check.sh` 回执、
**每组先过门再 commit**（子代理有 150 轮上限）、Obsidian 名下笔记贴真实输出。

## 5.3 M0 交付的细粒度契约（三家直接消费，别自己造第二套）

`MachSystemMonitor` 现在把每次 tick 的读数装进 **9 个独立观察格**
（`@Observable final class PerfCell<Value: Equatable>`，挂在 `let` 上——`let` 不进观察图，
所以**写 A 格不会唤醒只读 B 格的视图**；`apply()` 同值直接返回 `false`，不产生第二次唤醒）：

| 读法（`state.monitor.…`） | 里面是什么 | 该用它的地方 |
|---|---|---|
| `cpu.value` → `PerfCPULead` | `usage: Double?`（**无上一帧即 nil，不是 0**）、`coreCount`、`load1/5/15`、`thermal`、`uptimeSeconds` | `LiveCPUBadge`、CPU tile、侧栏底栏 |
| `memory.value` → `PerfMemoryLead` | `usedBytes`、`totalBytes`、`pressure` | 内存 tile / 内存卡 |
| `rates.value` → `PerfRateLead` | 读写盘与网络四个 `UInt64?`（**全可选**，两帧才出数） | 磁盘/网络 tile |
| `ledger.value` → `PerfProcessLedger` | `systemWideCount`、`countIsSystemWide`、`measuredCount`、`metricsTruncated` | 进程榜副标题、"被测 N / 共 M"口径 |
| `pulse.value` → `PerfPulse` | `sampleAt: Date?`、`historyCount` | 一切"最近 N 点 · 每 X 秒 · 窗口约 Y 秒"类副标题 |
| `curve.value` → `[SystemSnapshot]` | **已经切好窗口**（`curveWindowPoints`），视图里**不要再 `suffix`** | 实时曲线、总览历史曲线 |
| `cpuRanking.value` / `memoryRanking.value` | 排好序的前 N 个 `ProcessSnapshot` | 进程榜两张表——**视图内一律不再 `sorted`** |
| `groupRanking.value` | `[ProcessGroupSnapshot]` | 分组卡 |

**节拍与窗口**：`sampleIntervalMilliseconds` / `sampleIntervalText`（例「1.5 秒」）/
`windowSeconds(pointCount:)`；数值真值只有 `defaultSampleIntervalMilliseconds` 一处（§5.1）。

**交互暂停**（页面只在**切页动画**这类自己知道的时机用；滚动与拖窗已由 `AppState` 的
`NSEvent` 监视器统一接管，页面**不要**再接第二条）：
`beginInteractionPause(.pageTransition)` / `endInteractionPause(.pageTransition)`，
状态读 `isInteractionPaused`；源枚举 `LivePauseSource = .pointerStream | .windowDrag | .pageTransition`。

**旧的粗表面**（`latestSnapshot` / `history` / `topProcesses` / `allProcesses` / `trackedGroups`）
**暂时保留是为了让三家不必同批改完就能编译**，但它们仍会带动整棵 body：
`PerfInvalidationRatchetTests` 数着"还在读粗表面"的调用点，**只减不增、终点 0**。
迁完一处就少一处；**不许新增对粗表面的读**，也不许把新页面架在它上面。

## 5.4 待量化后才决定做不做的（登记，不预先动手）——**2026-09-20 21:49 已量化，两笔都判定为"不做"**

量法：`PerfMainThreadBudgetTests`（只出量级读数、**不设阈值**，因为计时断言在并发编译的机器上
必然漂，而漂的后果就是有人去放宽阈值）。夹具是取证沙箱里落盘的**真报告**
（`/tmp/tcoder-capture-sandbox-20260920-130112/reports/….json`，**42,663 字节**），
与 §1 的 29–43 KB 同一档。两次独立跑（0.54 / 0.51 ms 与 1.41 / 1.29 ms）互差 < 0.15 ms。

| 项 | 实测主线程占用 | 判定 |
|---|---|---|
| 一次 `upsertReport`（encode + 写报告 + 写注册表，全在主线程） | **中位 0.5 ms**，p95 1.0 ms | **不动**。它是 T2 预算（≤4.0 ms）的 ~1/8，而且只在扫描收尾触发，不在 1.5 s 节拍下触发 |
| 其中 `encode(.prettyPrinted + .sortedKeys)` 单算 | 中位 0.26 ms | 编码不是瓶颈，无需换格式或去 `sortedKeys` |
| 其中 `.atomic` 写盘单算 | 中位 0.17 ms | 落盘不是瓶颈，无需异步化（异步化反而会引入"退出前未 flush 丢报告"，而 `e2e_check.sh` / `verify_pages.sh` 正靠读回这些 JSON 判定） |
| 启动 `load()` 同步解码 4 份真报告（读文件 + 解码） | **中位 1.3 ms** | **不动**。相对 T4 的 1.0 s 冷启动预算是 0.13%，为它引入后台队列与"报告尚未就绪"的三态语义不划算 |

**这条读数的真正用处是把怀疑对象收窄**：持久化不在主线程预算里占位置，
所以 T2 那 10.8~24.8 ms 的 app-update 只能长在**视图图更新**上——
也就是 §0 的病因判断与 §0.1/§0.2 那 16 处粗读点迁移，仍然是唯一有收益的那条路
（16 处里 **10 处承重**，见工单 §0.4 的加权表：那一条是从 `publish()` 现读的，不是抄的）。

| 项 | 证据 | 为什么现在不改 |
|---|---|---|
| ~~`ProjectStore` 的主线程编码+落盘~~ | 已量：单次 0.5 ms（见上表） | **结案：不改**。原先"缺绝对值"这个理由已经不成立，现在成立的是"绝对值小到不值得动它，而动它要引入丢报告风险" |
| ~~`ProjectStore.load()` 启动同步解码 4 份报告~~ | 已量：1.3 ms（见上表） | **结案：不改**，占冷启动预算 0.13% |

**2026-09-22 16:16 独立复量（`ProjectStoreCostProbeTests`，真数据沙箱）**：把真实支持目录整份拷进
`TCODER_SUPPORT_DIR` 沙箱跑生产代码路径本身 ⇒ 上面两行的**结案成立**，并且补了此前没人量过的那一路：

| 事件（都在主 actor 上） | 实测 | 占一帧预算（8.33 ms） |
|---|---|---|
| 切项目 `setSelectedProject` → `persist()` | **0.40 ms** | 4.8% |
| 记分 `recordScore` → 全量历史落盘 | **0.29 ms** | 3.5% |
| 扫描完成 `upsertReport`（42 KB 那份） | **1.18 ms** | 14% |
| 扫描完成 `upsertReport`（**最大 104,913 B**） | **1.41 ms** | 17% |
| 连续 5 次 upsert 累积 | 4.97 ms | 每次 ≈1 ms |

三点必须一起读，否则这组数会被用错：
1. **`load` 两次数不一样不是尺子分叉，是总体不同**：上表 1.3 ms 量的是"4 份报告"，
   我这次沙箱里有 6 份 / 272 KB ⇒ 4.99 ms（另一次冷启动 7.19 ms）。
   ⇒ 谁看到两个数都别去"调平"，要动的是**说明它量的是哪份数据**（这一类错证据本仓记过二十次）。
2. **别外推**：我先按"字节数线性"估最大那份约 4.8 ms（那就意味着要动异步化了），
   实测 **1.41 ms**，差了 **3.4 倍** ⇒ 这类"要不要改架构"的决定只能靠量，不能靠比例推算。
3. **`load` 是启动一次性成本**，不进心跳期也不进交互期 ⇒ 它归 T4（冷启动 ≤1.0 s，占 0.5%），
   **不许**拿它去解释帧率；交互期真正相关的是 0.40 ms 那一行。
⇒ 持久化这条轴**结案并有独立复量**：不改。省下的人力应该花在还开着的两条上——
   16 处粗读点（细粒度消费仍 0 处）与渲染路径那 14 处（见工单 §P）。

## 6. 验收判据（改完必须交这些）

1. `perf_harness.sh idle` + `report` 的改后读数，与**§1.3 重定后的受控基线**逐列同形状对齐（**不是** run1 那张未受控的表）：
   hitch 数 → **0**、单次 app-update → **≤8.33 ms**、`potential-hangs` → **0**、
   主线程热点第一名不再是 `_updateViewGraph`；交互期那一条另交
   `perf_harness.sh probe <脉冲文件> --interaction`（T1：hitch=0 且 p95 ≤ 实测期望间隔×1.01）。
   两次读数必须来自**同一测量协议**
   （`measurement-context.txt` 两栏并列贴出：前台 App、`load1`、并发编译器、实例数），
   上下文不一致的对比等于没对比。
2. T5 三条守卫 + 元测试全绿，且元测试能证明守卫抓得住坏样例。
3. `locked_build.sh test` 全绿（当前 645 例基线，只许增不许减）。
4. 九页×深浅截图 + 《预期视觉变化清单》（无界化 spec §6.3）。
5. 每家 Obsidian 笔记：真实命令输出数字、契约缺口、已知问题。
6. **未覆盖项必须明写"未覆盖"**（例如交互期那一档：没有真人滚动就没有 `--interaction`，
   此时只交 idle 读数并标注，不许拿相邻档的数冒充）。
   **尺子自己也要交证据**：`perf_harness.sh selfcheck` 六项全绿才算"读数可信"，
   它坏了的时候所有测量数字一律作废（2026-09-20 就靠它兜出过 `cmd_switches` 的 `NameError`）。

### 6.1 证据现状（2026-09-21 晚，写在判据旁边而不是别处）

| 判据 | 现在的资格 | 依据 | 为什么 |
|---|---|---|---|
| T1 交互期 hitch=0 / p95≤8.4 ms | **两半句都要重开**：`0 丢帧`已成立；`p95` 这条**未达标但待交叉核对** | —（依据写在最后一格里） | `pulse` 档三趟 ×20 s、**7 513 帧**（rev `70af045`、release、synth@8ms≈125Hz）：p50 8.33 / p95 **9.12 / 9.26 / 8.98** / p99 ~9.3 / **max 9.35 ms**，`hitch(>1.5×)=0 次`（580 拍全 0）⇒ **没有任何一帧晚到 12.5 ms**（这半句成立）。p95 这一半：**按 8.41 ms 判是未达标**，但结论悬在一件没定的事上——p50 恰好 8.33、p95 8.98~9.26、max 9.35 ⇒ **有一大片帧比一个周期晚了约 1 ms**；若 CVDisplayLink 回调送达时刻与真正上屏时刻同形，"未达标"成立；若回调本身系统性偏晚约 1 ms，这 1 ms 要从读数里扣掉、结论翻转（工单 §M）。**交叉核对完成之前，两种结论都不许写进验收**。<br>**两件事没做完，不许把它当结论**：① 这一列只有 CVDisplayLink 一把仪器在量，回调送达时刻≠上屏时刻，必须用同批 xctrace 的 `displayed-surfaces-per-second` 交叉核对；② xctrace 的 `interact` 档（另一半句 hitch 计数）仍未采到——有循环在反复起实例而不收尾（工单 §K-2），闸门要求实例数恰为 1。此前那两批 25 Hz 合成输入的读数（42 与 5 次 hitch）已移出充数。 |
| T1 口径改判（2026-09-22 23:20 需求方裁定 + 23:37 实测） | **相对地板判据** | `perf_cadence.py --baseline <≥2 份空闲档>` | 面板实测节拍 119.33~119.39 Hz ⇒ 绝对阈值 8.41 ms 在**空闲档也做不到**（8.509/8.52），那条量的是仪器与面板地板。裁定三条一起用：① 交互档 p95 与晚到帧率两项**都不得劣于**空闲基线（多份基线取中位数，差值小于基线自身散布判「分不开」）；② 晚到帧绝对计数继续压，「不劣于」不算「够了」；③ 名义 8.4 ms 那一栏**照旧并报未达标**，不随改判消失。**当前状态：与基线分不开**（差 −0.004 ms，带宽 ±0.020 ms）⇒ 这条判据现在答不了「达标/未达标」，要加趟数或先压噪声。 |
| T1 实测结论（2026-09-23 00:39，产物 `dd46cbe`＝已并 main 的内容，交互 3 趟 vs 同产物空闲 2 趟） | **p95 达标 / hitch=0 未达标** | `perf_cadence.py --baseline`（3 趟各自对 2 份基线） | ① **p95 这半句过了**：呈现侧 p95 = **8.346 / 8.345 / 8.344 ms** ≤ 名义预算 8.417，三趟都达标，且与空闲基线（中位 8.345，散布 0.001）同高——不再是漂移前那趟的 8.51。② **hitch 帧=0 这半句未达标**：晚到帧率 **1.32 / 1.03 / 0.98 每秒** vs 空闲基线中位 0.86（带宽 ±0.15）⇒ 两趟判"劣于基线"、一趟"分不开"。③ 归因：滚动期 render 相位 p50 从空闲的 2.73 涨到 **4.03~4.71 ms**（p95 5.5~6.4），≈ 半个帧预算被每帧渲染吃掉；这正是 §Q 派给 UI 轮那批（14 处具名存量 + 粗读点）要压的东西。 |
| T1 复测（2026-09-23 02:35，产物 `fa26f4c`＝上一行之后的头，交互 3 趟，全部带真实内容种子 + 合成投递） | **p95 三趟都达标 / hitch=0 未达标且该维度不可复现** | `perf_cadence.py` + 新尺 `perf_trio_agreement.py` | ① 呈现侧 p95 = **8.34 / 8.35 / 8.34 ms** ≤ 名义预算 8.417 ⇒ 这半句三趟都过（实测均匀周期 8.409~8.426 ms ≈ 118.7~118.9 Hz，仍是名义值偏宽的那把）。② **hitch 计数这一档判「取值不一致」**：1.20 / 1.30 / **18.80** 每秒 ⇒ 极差比 15.7×（上限 2.0×），按 §1.3 不许报「3/3 达标」。③ 而 run3 那 15 倍**只有 hitch 表自己在动**：同趟 render 相位 p50 4.35 ms（前两趟 4.10 / 3.93）、上屏实测 p50 都是 **119 帧/秒**、六维上下文逐条合格（load 6.6~10.5 / 15 核、并发重活=无）⇒ 合成器起点间隔与上屏帧数两把独立尺子都没跟上这个数。④ 结论口径：T1 的 hitch 半句以**最好那一组**为现量（`dd46cbe` 三趟 1.15~1.45 /s，一致）报"未达标"，**不**拿 18.8/s 做外推；这一维在钉死计数口径之前不可比（同包 10 对 `hitches-updates` 的处理）。 ⑤ **三趟量的都是「总览」页**：`launch_measured_instance` 不传 `-selectedDetailSection`，落在 `@AppStorage("selectedDetailSection")` 的默认值 `.overview` ⇒ 见下一行：交互档的**页**此前既没被记录也没被控制。 |
| 脉冲仪器管多大范围（2026-09-23 10:05 自查） | **§M 那个"回调比上屏晚约 0.7 ms"的偏移量撤回，改判「未定」** | `perf_framepulse.stale_instance()`（selfcheck 第 41 项钉五种形状） | 报表此前一路写着「同窗 FramePulse」，可 `a5298d5-interact-run1` 的摘要是 `帧数=26941 ≈ 225 s` 而录制窗口只有 20 s：`cmd_idle` 的顺序是"起实例 → 录 hitches → 录 time-profile → **最后**才读脉冲"，所以那份总数是**生命期累计**、分位数来自环形缓冲（容量住在产品侧）。⇒ 影响一条：§M 的偏移量不能再用；**不影响 T1 的 p95 判定**，因为那一栏本来就是按呈现侧（合成器逐帧起点差）判的（三趟 8.34/8.35/8.34 ≤ 8.417）。重测前置见交接笔记 §AA。 |
| T1 逐帧判据的现量（2026-09-23 12:05，产物 `a5298d5` 交互档 3 趟、20 s/趟） | **`hitches` 那把尺未达标；逐帧两件套 0 帧超各自预算；三趟的差异全在流水线延迟档位** | `.scratch/per_frame_stats.py`（倍率与表名用 `ast` 从待应用补丁里**抠**出来，不重抄第二把尺子）+ 每帧预算由生产 `summary_refresh_row` 现算（120 Hz ⇒ 8.333 ms） | ① `hitches` 行数 14 / 22 / **364**（每行一个唯一起点，已复核）⇒ 按 xctrace 权威计数那句 **hitch 帧 = 0 未达标**，不许因为另两趟只有 14/22 就挑那两趟说。② 逐帧排队等待：p50 **8.86 / 8.86 / 8.92**、p95 9.74 / 9.88 / 9.93、max 11.48 / 11.10 / 11.22 ms，三趟**没有任何一帧**超 1.5× 预算（12.500 ms）。③ 逐帧 GPU 用时：p50 3.77 / 缺件 / 3.45，max 5.52 / — / 6.03 ms，**0 帧超 1× 预算**；run2 那张表没导出就写缺件，**不拿 0 顶**。④ 内容寿命 p50 **24.98 / 24.98 / 33.31** ms（= 3 帧 → 4 帧流水线延迟），max 41.66 / 41.66 / 1067.98 ⇒ 这一张**不对单帧预算判**（25 ms 天生是 3 帧寿命，判它就是 100% 超，与 §AB/包 10 同一类单位错）。⑤ 三趟 n=2431 / 2416 / 2450 帧，`Doc` 与逐行正则两把解析**每趟每张表都一致**。⑥ 单位别再混：这里 `framewait` 的 p95（9.74~9.93 ms）是**每帧排队等待时长**，与上一行呈现侧的**帧间隔** p95（8.34 / 8.35 / 8.34 ≤ 8.417）不是同一个量，两句各自成立、不许互相顶替 ⇒ p95 那半句仍然达标。⑦ 待办：本行是三趟已有产物的**手工复算**，判据接线（导出清单 + 报表行 + 逐表预算 + selfcheck 第 42 项）还没进树（`pending-patches/per-frame-tables.patch`，任务 #27）；进树后要用**新导的**逐帧表重报一遍才算交付读数。<br>**2026-09-26 §173 接线状态改口（现量）**：那句"还没进树"已过期——`scripts/perf_trace_frames.py` 在树里、逐表预算与报表行都在跑、selfcheck 第 42 项在册（任务 #27 已交卷）。**但"用新导的逐帧表重报一遍"这一件仍然没做**（09-23 之后没有任何交互档批次）⇒ 本行那三趟仍是**手工复算**，不许因为"接线进了树"就读成已交付。 |
| T1 的**页**此前没被控制（2026-09-23 02:50 自查） | **所有交互档读数的适用面只有「总览」页** | 起实例时不传页参数 ⇒ 落在 `@AppStorage` 默认值 `.overview`；`meta.json` 里此前没有 `section` 字段 | §Q 移交的 14 处按页摊开：只有 **3 处**会在总览页上被渲染（`Views/Shell/SidebarRows.swift:89` 与 `Views/Shell/ProjectSidebar.swift:231` 两处动态色＝侧栏常驻；`Views/PerfLogs/ChartChrome.swift:293` 那个 formatter 被 `DashboardHero` 引用）。**其余 11 处（9 个排序 + 2 处同步 I/O）长在代码规模 / 依赖分析 / Git 洞察 / 错误日志几页上** ⇒ 拿"总览页滚动期 render p50 4.10 ms"去验收"日志页的排序"是**盲尺**，反过来还掉那 11 处也不会让今天这条曲线动。⇒ 验收靶子改成**页内** render 相位：`MEASURE_SECTION=<页名>` 起实例、`meta.section` 落盘、报表印「测量页面」（补丁已备好 `.scratch/per-page-section.patch`，等测量链让位再应用——**不在链跑到一半时改正在被 source 的脚本**）。<br>**2026-09-26 §173 改口**：那条补丁**早已应用**——`MEASURE_SECTION` 现在接在 `perf_harness.sh`／`perf_probes.sh`／`perf_selfcheck_context.sh` 三处，`perf_trace_summary.py` 会印「测量页面」（任务 #25 已交卷）。⇒ 这一格剩下的**不是工具欠账而是读数欠账**：09-23 之后没有任何交互档批次，逐页靶子仍然等 #77 那次真人滚动窗口。 |
| T2 心跳期占用 ≤4.0 ms | **认证成立（2026-09-26 16:33，对象 = `Sources` tree `0f2070129535`）：八趟整批、中位每趟 p90 1.49 ms、范围 1.28~1.72 ms，判定「一致」退出码 0** | —（依据写在最后一格里） | 同一产物码 `7be9386…` 的三趟 `app-update`：**max 2.08 / 1.69 / 1.40 ms**（n=16/6/9，**三趟超预算 0 个**）⇒ 红线 ≤4.0 ms，余量过半，且三趟互相印证。测量条件：静默 57 s~25 min、`TCODER_GIT_CLEAN=true` 的 release 产物、provenance 全过。<br>**同批的 hitch / HTR 两行不作数**：实测出帧掉到 10/s（静止窗口 ProMotion 降频），按 §6.2 只记形状不判档——这正是 T2 的判据用 `app-update` 而不用 hitch 计数的理由。旧内容（产物 `1eb1286…`）上的 1.98 / 2.49 / 2.17 保留为量级线索，不挂"当前头部"。<br>**2026-09-22 13:17–13:35 重量未成功，原因是环境不是尺子**：release 已重打到当前树（产物码 `58fbb2d…`、Sources `36c70a8f`），但 `perf_wait_window.sh` 等满 900 s 仍被"实例数恰为 1"拒（现场从 4 个 foreign 实例涨到 8 个，来源见工单 §K 的 `ax_tooltip_report.sh` 缺 `trap`）⇒ rc=1、零样本。**这一格现在写"未覆盖"，不写"达标"**：谁拿到一个没人跑取证循环的 5 分钟，跑 `MODE=idle ./scripts/perf_wait_window.sh <rev> 3 900` 就能把它变成结论。<br>**2026-09-26 16:33 这一格从「未覆盖」升成「认证成立」（cert10 批次）**：同一棵 `Sources` tree `0f2070129535`（09-25 18:33 起产品码一字未动）上八趟**整批**（不是从 56 组里挑出来的那一组）复算，每趟 p90 现量 1.28~1.72 ms ⇒ 极差比 1.3×、均值 1.11~1.39 ms 极差比 1.3×，两把尺都在 2.0× 带宽内，判定「一致」退出码 **0**；逐趟 `update max` 全部不到 4.0 ms 预算的一半，93 发在场采样全「在屏」，`起跑前实例数=0 … 收尾后实例数=0`。报数口径：**中位 p90 1.49 ms + 范围**，不报均值。<br>⚠ 必须跟读数一起给的一句：**一致性判据是在这批数据采集之后才改的**（2026-09-26 需求方裁定 A，见 §1.3——「出帧 p50 极差」摘出判据、保留为参考项）。没做的事是"挑一组通过来宣布成立"：用的是整批八趟，档位与窗口条件由 preflight 逐趟盖章；改的是"哪一维参与判定"，而那一维在改之前也没被任何第二把尺佐证过（0/56、0/220）。凭据与过程自记见台账 §168。<br>⚠ **取法同一笔（2026-09-26 §173）：这批"每趟 p90"实际就是"每趟 max"**——本尺取分位用 `percentile(values, p) = sorted[int(n·p)]`（`perf_trace_metrics.py:183`，注释明写"换算法等于换门禁"所以**取法不动**），而 cert10 每趟事件数 **n=5~10**，`int(10×0.9)=9`＝末位 ⇒ **n≤10 时该下标恒等于极大值**。所以「极差比 1.3×」这一维是**按逐趟极值**算的散布（不是按中心趋势），报表现在自己印这一句；不受影响的是第二把尺（每趟**均值** 1.11~1.39，极差比同为 1.3×）。方向上要说清：**逐趟极值比中心统计量通常更散，所以"通得过"偏保守，但这是直觉不是定理**，本尺不拿它当保证。 |
| T2 复测（2026-09-22 22:36，产物 `d73bea4`。**注意归属范围**：当时它的 `Sources` 与 main 现头逐字节相同；09-23 00:08 复核时 main 已经又前进了 **23 个渲染路径文件**（UI 轮那批粗读迁移等陆续落地）⇒ 这两个数**只描述 `d73bea4`**，不描述 main 当前内容，已在 `61b7181` 把 main 并进来重测 | **2/3 达标，协议未满足** | 同一趟 `app-update`：run1 `p50 1.25 / p95 1.63 / max 1.63 ms`（n=8，超预算 0）、run3 `p50 1.46 / p95 1.68 / max 1.68 ms`（n=4，超预算 0）；run2 被收尾复核判「窗口内有人动手 ⇒ 污染」，**不充数** | 两趟都远在 4.0 ms 红线内（余量 2.4 倍），且 `displayed-surfaces/s p50 120` 与自扫一致。但 §1.3 的规矩是「连测 ≥3 次且取值一致」⇒ **只能说 2/3，等第三趟**（等待器 v4 会补）。附带钉住一件事：`hitches-updates` 那张表在交互档的「1113/1113 超预算」**不是** T2 的依据，T2 用的是心跳档那几个 n=4~9 的数（见 §R/包 10）。 |
| T4 逐页冷启动 ≤1.0 s | **待重测**（旧数 764~845 ms 同上） | —（依据写在最后一格里） | `switch` 档自带一条更严的闸："本机有别的实例就拒"（今早实测拒因里直接列出 7 个 pid）。`SWITCH_ALLOW_COEXIST=1` 可以共存态跑，但那批只能标成"共存态"，不进验收表。 |
| 九页取证 | **已拍到 `evidence-ac0e6e4-m3-9pages/`（2026-09-26 22:04 复拍：4/4 趟 × 深浅两态 × 顶/尾 = 36 张）；新鲜度守卫现量「表里 10 行 → 过期 0 行」，本树实查 72 格、不成立 0 处** | —（依据写在最后一格里） | （09-23 16:45 那趟核过两件事：① 新鲜度守卫**当时**现量「表里 10 行、覆盖 11 页 → 过期 0 行」；② 从拍完到 `fbca4f3` 的**渲染面差量为零**——`git diff --name-only 2a05a28..HEAD -- Sources/**/Views Sources/**/Design` 打出 0 个文件，中间落的只有 scripts 与文档。⚠ 这条验收**不需要点击**：翻页走 `-selectedDetailSection`，见 `AGENTS.md` §2.2 的白名单。）<br>19:29 改口：`3aa5a7f`（卷二 hero 的英文窄态普查）与 `363dd74`（P66 改了 `Design/` 两处）各把一页拧过期，守卫现量「过期 2 行（已挂账 2、没挂账 0）」——**上一格那句「不需重拍」已经不成立**，欠拍挂在那两笔作者名下，宽限到 09-24。<br>旧的那批：`.scratch/pages-4797a39/`：9 张 / 9 页、失败 0、内容完全相同的图组数 0；**没有跳过 provenance**（`SKIP_PROVENANCE` 未设），沙箱走 `TCODER_SUPPORT_DIR` 所以用户状态未被触碰；收尾只对本脚本自己起的 pid 发 SIGTERM ⇒ **没给下一个再添漏网实例**。<br>**2026-09-26 22:04 复拍（cert 之后的 M2 取证格）**：动机**不是屏上变了**——`Sources` tree `0f2070129535` 自 09-25 18:33 一字未动，逐页账十行至今判「无」。要换掉的是**有效期的性质**：它一直靠"恰好没人落上屏产品码"撑着，而没有任何守卫保护这件事。改后：`paired_page_evidence.sh m3-9pages` ⇒ 4/4 趟合格、36 张逐张过极性判定，归属 `rev=ac0e6e4`（**被拍二进制自己的**提交，从 manifest 取）而 `head_at_capture=20b9a56`，放行依据仍是「产物码 tree 相同」；十行账整体改指新批次并把 `git log ac0e6e4..HEAD` 同步换上，表下**追加**复拍记录（历史叙述一字未动）。凭据：`--filter EvidenceFreshnessTests` ⇒ 17 例 0 失败，两行读数「过期 0 行」+「表里 10 行 · 本树有产物 10 行 → 实查 **72** 格，不成立的格 **0** 处」——第二行那句「本树有产物 10」是这一格的价值所在（批次不在跑测试那棵树里时这条腿逐行 skip，而 skip 与"查过且全对"在汇总行上长得一样）。**仍有一腿未跑**：主树那侧的 72 格本轮没跑（需要一次合法的主树构建），准确措辞是**权威份就位、主树读数待下一次合法构建时补**。hover/悬停取证仍未覆盖。见台账 §171。 |
| body/Mark 零动态色/零排序/零同步 I/O | **未达标（终点 0）：2026-09-26 21:41 现量 12 真债 + 1 具名豁免，全部在 `Views/**`（UI 流名下），禁则尺五档全部零余量** | —（依据写在最后一格里） | 并完 main（`e929a47`）之后现扫台账：`directFormatters 1/1`、`dynamicNSColor 62/64`、`fullSort 9/9`、`syncFileIO 2/2` ⇒ 台账自己报出 2 格隐形余量，已按"只紧不松"拧到 **62**。粗读点仍 **16/16 未迁、细粒度消费 0 处**（`ⓘ` 收纳那两批一处都没动这条轴）。<br>**2026-09-22 复扫（尺子拆分后，五档口径）**：`directFormatters 1/1`、**`dynamicColorConstruction 2/2`（新尺子，第一次抓到现场：`Views/Shell/SidebarRows.swift` + `ProjectSidebar.swift` 各一处 `Color(nsColor:`）**、`fullSort 9/9`、`syncFileIO 2/2`、`tokenReference 62/62`。⇒ "零动态色"这半句**从今天起才真正有判据**，且四条真判据全部零余量、终点 0 的存量**一处不剩在性能侧名下**。<br>**2026-09-26 21:41 现量（守卫自印，两次）**：拧之前 `directFormatters 1/1`、`dynamicColorConstruction 2/2`、**`fullSort 8/9（可拧到 8）`**、`syncFileIO 1/1`、`tokenReference 62/下限 40`；拧之后 `--filter PerfHitchGuardTests` ⇒ 20 例 0 失败、同一行印 **`fullSort 8/8`**。这一格动的是**上限追到现值**（9→8，方向只许变紧，见该线注释"留 1 处余量等于新增 1 处照样绿"），不是放宽判据。<br>**真账逐点（12 债 + 1 豁免）**：动态色构造 2 处（`Views/Shell/ProjectSidebar.swift`、`Views/Shell/SidebarRows.swift`，＝#19 的对象）；全量排序 8 处（CodeMetricsView / DependenciesView / ContributorRows ×2 / ContributorsView / LogsFileTables ×2 / LogsTrendCard）；直建 formatter 1 处（`Views/PerfLogs/ChartChrome.swift`）；同步 I/O 真债 1 处（`Views/Logs/LogsView.swift` 的 `attributesOfItem`，body 读的计算属性 ⇒ 每帧 stat）＋**具名豁免 1 处**（同文件 `chooseLogFiles` 的 `fileExists`，一次点击一次、紧接弹模态 ⇒ 不是每帧，#72 裁定）。`tokenReference 62` 只是**读数**（下限 40，不是债）。⇒ 12 格全在 `Views/**`，本会话不写 Views，名单交 #69/#19。**未追的一件事**（写下来不假装完整）：fullSort 从 9 到 8 少掉的那一格**是谁还的、还的哪一处，我没追**（清单文件每次跑被覆写，旧名单只剩台账里那句点名）⇒ 规矩应补成"禁则守卫落盘清单时同时写进行内『较上次少了哪一格』"，否则"还掉一处债"与"少报一处"在文档上同形——本节只登记、未实现。见台账 §170。 |
| 诚实性语义不降级 | 守住并在加长 | —（依据写在最后一格里） | 期间自我矛盾样本 rc=3、哨兵不可当读数、磁盘/空值一律判不合格、样本根必须被 git 忽略；今晚再加三条：**样本根不许退回 `$TMPDIR`（改拒录）**、**selfcheck 每一项必须出声（项间共享 `bad` 会让一项红吞掉后续项的绿）**、**批次按产物码归类而不是按 rev 字面**。<br>**2026-09-26 再加四条**（目标第四条的加长，不是新判据）：① **改判据方向的红线写进规范性文本**（§1.3 那段）——"不许为好看而放宽阈值"与"不许纠正一个选错的量"是两件事，裁定 A 之所以合法是因为它摘掉的那一维**从未被第二把尺佐证过**（0/56、0/220），而参考项**照旧印**（读数不许因为不当判据就从表里消失）；② **批次无论怎么结束都要留一行读得到的收尾**（`perf_run_batch.sh` 的 `finalize()` 被 INT/TERM/EXIT 三条 trap 打到，正常/中断两种结束都落 TSV，见台账 §169）；③ **一档判据必须同时新增门禁调用它**，且不许用退出码当"跑过了"的证据（selfcheck 72/73/74：台账装订普查 + 打回率尺哨兵）；④ **集体看不见不构成绿**——普查尺读 0 份产物时直接 rc=1，而不是报"通过"（§166 抓到的是我自己写的假绿）。 |

⇒ 规矩：**产物不在，判据就不算绿**。文字记录（本文、Obsidian）只是过程记录，
不能替代 `.trace` 与导出表；取证产物落 **`.scratch/`**（唯一根名单 = `perf_preflight.sh` /
`perf_harness.sh` 的 `SCRATCH`，仓库根下、已 gitignore；`TCODER_SCRATCH=` 可覆盖但必须自己保证被忽略），
每轮收尾扫 `$TMPDIR` 的 `.ktrace` 残骸、可用 < 20 GiB 拒跑，
且**建不出来就直接拒绝录制**——不许再出现"退回全局临时目录"这种同一个失效的第二副面孔。


### 6.2 一条从实测里长出来的口径：hitch 的档位词必须先问"还在不在 120Hz 档"

`.scratch/tcoder-perf-5236033-idle-run2` 报 `HTR 18.33「危急·立刻处理」`、超预算 36 帧，
但同一份数据里主线程 **88.6% 样本在等事件**、整窗 **零人手输入**（距上次事件 846 s）、
`app-update` 最大 **2.49 ms**、实测出帧 **p50 48/s**。
⇒ 窗口静止时 ProMotion 降到 ~50 Hz，一帧本就该花 ~20 ms；
  用 120 Hz 的 8.333 ms 预算去判，"超预算帧数"与 HTR **系统性偏坏**。
  对照列早有"出帧机制不同 ⇒ 只各判绝对预算"，但 **hitch 三行的档位词没跟着改口**——
  我第一反应就被那两个字唬住，把一份降频读数当成了缺陷线索。
⇒ `in_display_regime(实测出帧, 预算)` + `hitch_regime_suffix(...)`：越档时三行统一追加
  「实测出帧 X/s，已不在 120.0 Hz 档 ⇒ 不判档，只记形状」；
  拿不到出帧数**保守判在档内**（不许用"未知"给坏消息打折）。
  selfcheck 第 25 项钉四边界（119.7/96.0 在档、95.9/49.8 越档）与三态话术。

两条自我更正（都写进文档，不只留在聊天里）：
① 报表 `app-update` 那行印的是**截断列表**（`0.2 0.2 0.3 …`），
   照抄会把 2.49 ms 误说成 1.3 ms —— 我今晚第二次没回原始数据就复述数字；
② 元测试的夹具必须长成**生产形状**（`load_measure` 的 json/doc/present 三件套）：
   只塞 `{"json": None}` 时真红的是夹具本身（`fps_counts` 去摸不存在的 `doc` 键）。


## 7. 风险与备案

1. **M0 落地后、三家交回前 main 是过渡态界面**（无界化 spec 已备案），本轮叠加"心跳语义变了但页面还没改完"的窗口。
2. **既有测试会大面积变红**（它们钉的是当前值）。M0 由总工统一更新；**页面级断言归各流**，
   谁为了让它绿而删断言，视为返工。
3. **release 产物符号可读、但未优化内联更激进**：绝对值以 release 为准，火焰图归因以 debug 为准，
   两把尺子分开写，**不混**（`465f5a6` 是 release，本基线就是 release 口径）。
4. **T3 暂停实测 >500 ms 即回退**（§3）。
5. **xctrace 需要独占实例**：用户自己的实例（曾为 pid 96992）在采样期间不得同时开第二个写 `defaults` 的实例。
6. **120Hz 不是恒定出帧**：静止界面无所谓帧率。凡有人拿"我这里有 120 帧读数"当交付证据，
   先问"这段时间有没有东西在动"。
8. **五道闸看不见"显示系统层面的外部争用"**（2026-09-21 实测）：同一 rev、同一实例、
   五维上下文逐条相同的三趟里，hitch 次数是 43 / 3 / 1，而 `app-update` 稳定在 2.6~2.9 ms。
   ⇒ 心跳期只认 `app-update`；hitch 计数只在"与 `app-update` 一起读"时才有意义。
   要收这一维得换判据（例如把 `displayed-surfaces-per-second` 的整机基线也量进来），
   本轮不做，先写下"别把外部抖动算成 App 的账"。
7. **两个"总工"同时在推同一棵树**（实测：本文件写作期间，并行会话连推 `5ce35ce`→`a709813` 五个提交、
   建好 `o-borderless`/`p-borderless`/`w-borderless` 三棵树待派）。`Design/**` 与 `Views/**` 的归属
   因此是**真冲突**而不是假想风险：谁在未经裁定的情况下改对方名下的文件，就是 AGENTS.md 记过的那次
   "未提交重构把 main 弄坏"的重演。§5 的 C 包与 M1 三家在裁定前一律不动。

9. **`hitches-updates` 的读数不许被报表印成「N 个主线程 stall」，也不许单独给出"该查主线程"的归因**
   （2026-09-23 定，包 10 的报表侧收口）：同一趟交互档样本里 **1841/2090 行超一帧预算**、
   迟到帧只有 **24 个**、上屏实测 **119~120 帧/秒** —— 三个数只有在
   "这张表的行数与帧不同源、单位待核"时才互相自洽；老报告那句
   "主线程 stall 1841 个（88.1%）＋ 几乎一比一 ⇒ 先查主线程"是把 76.7 倍读成了 1:1。
   ⇒ 判据住在一处（`perf_trace_metrics.interval_shaped`，`trace_report.caveat_for` 改调它，不留第二份数值）；
   **窄分布**与**比值悬殊**（超预算 >1.5× 迟到帧）两种形状一律**不判**并指路另两把独立尺子
   （render 相位、time-profile 的 Main Thread 忙样本），"stall N 个"只留给少数孤例（<20% 行超预算）。
   它到底是回调间隔还是别的，仍未定（那要问仪器定义，不能靠形状猜）——**但不定就不判，这不影响交付口径的诚实性。**
