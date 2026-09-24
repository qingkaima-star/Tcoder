# 性能规范 §1 的历史读数明细（拆卷）

这里放的是被搬出规范正文的**历史采样明细**：一次读数一份条件，所以它们**不是当前值声明**（本仓规矩：带头的快照只追加不改写）。
正文里留着同号小节的指针行 ⇒ 别处引 `§1.1 / §1.2 / §1.5b / §1.5d / §1.5g` 不会因为搬文件而断链。
搬动一行内容都没改写，包括那些被我自己推翻并标了「作废 / 不作数」的读数。
判据与理由：`SelfScanDogfoodTests` 的全仓 ≤800 行棘轮（ceiling=0，分母含 `.md`）。

### 1.1 这次测量推翻了我自己的排序（备案）

勘查阶段我把"每屏 88 层材质+投影"列为头号嫌疑（`Glass.materialLayer` 一处 `.shadow` 被 88 个入口继承）。
实测 **render p95 = 4.05 ms、p99 = 4.67 ms**：在 M5 Pro 上合成根本不缺时间。
所以：

1. **`Design/Glass.swift` 表面换血继续做，但理由改成"观感（明暗关系反了、投影滥用）+ 顺带省 GPU"，
   不得再宣称它是性能主因。** 谁在报告里写"去材质所以不卡了"就是错证据。
2. 头号工是 **收窄一次 publish 引起的视图图更新面**（§3 T2/T5）。

### 1.2 勘查数字勘误（总工独立计数复核，15:37）

三名勘查子代理的结论方向正确，但**四个数字是错的**，其中一个会造出假零守卫。
以本表为准（计数命令附后，口径 = `grep -rhoE <正则> <目录> --include='*.swift' | wc -l`，在 `m0-borderless-base` 之后的 `ws/perf-base` 上跑）：

| 项 | 勘查报的 | **实测** | 影响 |
|---|---|---|---|
| Views 内动态色成员（`.textColor/.graphicColor/.badgeFill/.onFillColor`） | 115 | **116** | 差 1，无实质影响 |
| `id: \.offset` / `id: \.self` | 8 / 7 | **4 / 8**（另有 `\.element` 6、`\.key` 1、`\.raw` 1） | **两个数写反了**，工单 P-5 按实测派 |
| "全仓 0 个 Lazy" | 0 个 LazyVStack | `LazyVStack` 确实 **0**，但 **`LazyVGrid` 已有 11 处**（总览/健康/代码/依赖/日志/性能/Git/贡献者的 tile 网格） | 工单 P-2 必须收窄成**只改长列表**，误改已是 Lazy 的网格属于白烧 |
| "`LogsView.attachedItems` 在 body 里做 `stat()`，每次 body 3~4 轮 syscall" | 3~4 轮 | **两个半边各对一半**：符号不是 `stat(` 而是 `FileManager.attributesOfItem`（定义处 1 个：`LogsView.fileSize(of:)`）；但 `attachedItems` 在**一次 body 里被求值 3 次**（`LogsView.body` 的 `if !attachedItems.isEmpty`、"已附加 N 个文件" 文案、`ForEach(attachedItems)`），每次求值对**每个附加文件**一趟同步 syscall ⇒ "3~4 轮"说的是求值次数，没错。另：`fileExists` 在 `chooseLogFiles()` 按钮动作里，**不属渲染路径、不用改** | 工单 W-1 已按实测改写；② **T5-③ 守卫若只正则匹配 `stat(` 会永远得 0 = 假零守卫** |
| Views 内 `.font(` | 183（含 Design） | **Views 内 148**，Views+Design 合计 183 | 口径分两个数写，别当同一个 |
| `trustedMemoryPoints` 每 tick 跑几遍 | 3 遍 / 270 个 `SampleContext` | **4 遍 / 360 个**：`PerformanceLiveCharts.memoryAxis` 一次 body 内访问 `trustedMemory` **两次**（`.map` 求 peak + `isEmpty` 判空）、曲线再取一次、`SystemReadings.rejectedMemoryPoints` 又跑一遍——**而它只是为了拿一个计数，把整数组重过滤一遍就把结果丢掉** | 工单 W-2 已按实测改写；这第四遍是最容易改也最没人想到要改的 |
| 全仓 `#available` | 4 处全在 `Design/Glass.swift` | 9 处，分布在 `Design/Glass.swift` + `Design/GlassComponents.swift` | 两份都在 `Design/**`，**"页面不散写"红线未被违反**，不改工单 |
| `Sources/**` 实现文件数 / 超 800 行文件数 | 110 / — | **110 / 0** | 与 `SourceFileReachabilityTests.censusBaseline = 110` 一致；M0 每加一个新文件该基线 +1，**只由总工改** |

> **给 R 的硬要求（写在这里防止守卫长成假零）**：T5-③「渲染路径同步 I/O」的正则**必须至少覆盖**
> `fileExists`、`attributesOfItem`、`contentsOfDirectory`、`Data(contentsOf:`、`String(contentsOf:`、
> `stat(`、`lstat(`、`FileManager`；且元测试要用 **`attributesOfItem`** 这种真实形状造坏样例，
> 而不是用最显眼的 `stat(`——否则扫描器只会抓一种写法却对外宣称抓全部。

### 1.5b 第二趟受控读数（2026-09-21 12:05，产物 rev `082f403`、构建时树干净）

这趟是**第一趟带正确身份标签的**读数：`measurement-context.txt` 现在有
`产物构建rev=082f403…  构建时树clean=true` 一行，与 `HEAD=` 并排可核。

| 指标 | 本趟 | 与 §1.5 第一趟的差别 |
|---|---|---|
| `app-update` 单次耗时 | 0.6 / 0.7 / 1.0 / 1.1 / 1.1 / 1.2 / 1.3 ms（T2 红线 ≤4.0） | 同量级 ⇒ 一致 |
| hitch / HTR / potential-hangs | 0 次 / 0.00 ms/s / 0 次 | 同 |
| render 相位 | p50 3.57 / p95 5.53 / p99 7.00 / max 15.53（**n=1644**） | 第一趟 n 只有 181（≈9 fps，不同机制） |
| render 超预算帧 | 7 帧 = **0.43%**（n=1644） | 与基线 0.42%（n=2394）**同机制可比**：82fps vs 120fps，比率 1.46 < 2 |
| 主线程热点第一名 | 51.1% `UC::DriverCore::continueProcessing` ⇒ **已换位** | 第一趟还是 56.8% `_updateViewGraph` |

**顺带证伪了我自己一小时前的一处担心**：§1.6 第 1 条加的"机制不互比"没有变成万能挡箭牌——
这趟分母回到 1644 帧（≈82 fps）时，尺子**不再**报"不可比"，而是让 0.43% 与 0.42% 直接对上了。
一条只会在坏情况下说话的判据，得同时证明它在好情况下闭嘴。

### 1.5d **T2 成立**：同一 rev 上三趟一致（2026-09-21 12:0x–12:2x，产物 rev `9e60fec`，构建时树干净）

三趟的五维上下文逐条相同（同实例 pid 48929、前台=Tcoder、有在屏窗口、无并发编译、
人手静默 631/1331/1444 s），`app-update` 相位的**真实最大值**：

| 趟 | n | 最大 app-update | 中位 | 判据 ≤4.0 ms |
|---|---|---|---|---|
| run1 | 16 | **2.91 ms** | 2.71 | 达标 |
| run2 | 11 | **2.65 ms** | 1.95 | 达标 |
| run3 | 13 | **2.70 ms** | 1.95 | 达标 |

⇒ **T2（1.5 s 心跳期主线程占用 ≤4.0 ms）按 §1.3 的"≥3 次一致"成立**，余量约 1.3 倍。
（§1.5 第一趟是 `41add9e` 的二进制、不参与本结论；§1.6 第 4 条的闸门就是为这件事加的。）

**但同一批样本暴露了一件我原来量不到的事**：三趟的 **hitch 次数是 43 / 3 / 1**，
HTR 22.50 / 1.67 / 0.83 ms/s——**五维上下文完全相同**的前提下差 43 倍。
`app-update` 三趟却都是 2.x ms 量级，说明差异不在被测 App 的主线程上，
而在**窗口合成/显示系统层面的外部争用**（别人前台的 App、WindowServer、外接屏），
这是我五道闸**看不见的一维**。
⇒ 三条结论：① **hitch 计数不能单独当心跳期的合格判据**，必须与 `app-update` 一起读
   （否则会把外部抖动算成 App 的账）；② 心跳期真正要交的就是 T2 这条占用，
   它三趟一致；③ "hitch=0" 的正式判据属于 **T1（交互期）**，仍待人工滚动举证。
   登记为 §7 风险第 8 条。

### 1.5g 度量链今天下午新长的四条规矩（每条都对应一次真实失效）

1. **落一个证据标记，同一笔里就必须有读者。**
   `perf_preflight.sh` 早就把 `no_human_input_during_window=1` / `contaminated_by_human_input=1`
   写进 meta，而**全仓零个读者** ⇒ "整窗没人滚"的 interaction 样本照样打印
   「测量期间：interaction —— 有资格答 T1」。前三轮 T1 作废是我自己读终端判掉的，工具没拦过。
   ⇒ 现在由 `period_eligibility(meta)` 把复核读回来：自我矛盾的样本额外打一行 ⚠，
   且 `report` 以 **rc=3** 退出（脚本化的比较只看退出码；表头多一行说明会被下一环当绿灯放过）。
   元测试第 21 项钉四种形状，并要求**话术跟着翻转**（只改退出码也算不合格）。

2. **反向复用同一把尺子之前，先问它的失败值落在数轴哪一端。**
   idle 档判"够静默"是 `q >= 8`；照抄成交互档 `q < 3` 就造出一条**恒真**的开录闸门——
   探针取不到时打 `静默=-1.00s`，-1 是数轴最小值，"量不到"变成"最有人在动"。
   ⇒ 加一道与数值无关的 `probe_usable()`；元测试还**反向承认**哨兵确实骗得过
   `human_input_in_window`（哪天骗不过了，说明守卫的理由消失了，连守卫一起改）。

3. **"在场即重活"对 xctrace 不成立，会让闸门永远不可满足。**
   补上 xctrace 这一维之后，T1 采样器立刻被永久押住：拦路的是**别的工程 21 小时前**
   留下的孤儿 xctrace（%cpu=0.0、cputime 5 秒走 0.01 秒、`--attach` 目标进程已不存在）。
   ⇒ xctrace 只认"真在采"（2 秒窗口内 cputime 增长 >0.2s）；
   编译类（swiftc / swift-test / xctest）仍按在场即重活——它们在场本身就说明在吃 CPU，
   看增量反而给"刚起还没跑起来"的编译留空子。双向合成测试用自起的烧 CPU / 睡觉 bash 当夹具。
   教训与"恒拒的闸门看起来最像尽职"同族：**一条不可能满足的判据，代价是不举证**。

4. **取数原语必须自带默认，合格线不许跟着搬。**
   `perf_wait_window.sh` 直接 source 探针族，而 `QUIESCE_BIN` 只在 `perf_harness.sh` 头部赋过
   ⇒ 一进 `set -u` 就 `unbound variable`，脚本在"即将开录"那一刻死掉（最贵的断法：
   白烧的是人手配合的那一次）。现在探针自带默认（路径按 `BASH_SOURCE` 算），
   `QUIESCE_MIN=5` 这类**阈值**留在闸门侧；第 22 项双向钉住这条分界。
   同族小案：新增量忘了进 `local` 清单 ⇒ 第 17 项单维破坏那一支**静默中止**整条闸门
   （selfcheck 少跑 4 项、只留退出码 1）。`set -u` 下的 `${VAR:-}` 不是洁癖，是给单维破坏留活路。
