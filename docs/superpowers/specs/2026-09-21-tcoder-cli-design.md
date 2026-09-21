# Tcoder 无头 CLI 设计（供 AI 自己调用）

日期：2026-09-21 · 归属：总工（WS-CL）· 状态：已获用户批准开工

## 0. 一句话目标

给 Tcoder 一个不启动 GUI 就能取数的入口，让 AI（本仓的会话与子代理）**用产品自己的尺子**
读一个仓库的工程指标，而不是各自手写 `find | wc`、`git shortlog` 造第二把尺子。

交付形态：**内部工具优先**（用户 2026-09-21 裁定）。不做 PATH 安装、不承诺对外 JSON schema
稳定、不写用户手册、不做 MCP server。这四条是**明确不做**，不是"以后再说"。

## 1. 为什么值得做（现场证据，不是设想）

本仓目前唯一能从终端读到 Tcoder 结论的路径是 `scripts/self_score.sh`，它的形状是：

预置沙箱 `projects.json` → **起一个 GUI 实例** → 每 5 秒轮询 `reports/<uuid>.json`
是否落盘（上限 **300 秒**）→ 尺寸稳定 3 轮再读 → python 解析 → 通报 pid 等人工 Cmd+Q。

代价与风险都不小：一轮读数要占一个 App 实例（全机共享 `defaults` 与 `Application Support`，
所以取证格同一时刻只能有一人用），而"报告没落盘"和"分析器算出空值"在终端上看起来是同一种失败。

**本次 spike 实测（2026-09-21 19:30，`ws/cli-headless` 树，`.build/debug`，
被扫总体 = 该树仓库根 330 文件 / 49 864 码行 / 671 提交）：五路分析里有代表性的两路
（code + git）跑完 3.3 秒，进程干净退出，GUI 未被带起（`pgrep -x TcoderMonitor` 保持改动前的
同一个 pid 8828，未新增实例）。** 口径注意：debug 构建、且只量了五路中的两路，
不等于 release 下五路全跑的端到端时间 —— 端到端数由 §7 的验收去量，不在这里预支。

## 2. 方案取舍

| | 做法 | 判定 |
|---|---|---|
| **A** | **同一个二进制，argv 分派**：`TcoderMonitorApp.init()` 认出子命令词就跑无头流程，跑完 `exit(code)` | **选它** |
| B | 第二个 `executableTarget` + 把分析层抽成 library | 否 |
| C | 写 shell 拼 `git` + `wc` 出读数 | 否 |

- **A 的理由**：`Package.swift` 不动、`build_app.sh` / `verify_provenance.sh` / `dist` 一字不改，
  "交付二进制 == HEAD"这句话仍然只指一个二进制；schema 天然同源（同一个模块内的同一个类型）。
  代价是一个 GUI 二进制里带着 CLI 代码，以及 CLI 生命周期挂在 `App.init()` 上 —— 后者已由 §1 的 spike 证伪。
- **B 否的理由**：SwiftPM 里 `executableTarget` 不能作为另一个 `executableTarget` 的依赖，
  所以只能把 `Sources/TcoderMonitor` 整体降级为 library + 薄 GUI 壳。全仓 `@testable import TcoderMonitor`、
  `.build` 布局、打包与来源证明链都要跟着震，还会撞逐符号零引用普查与 400/800 行棘轮。
  为一个内部读数工具付整个仓库重分层的价格，不成立。
- **C 否的理由**：本仓历史上"三个口径别混""两把尺子先互相复现"这类事故（AGENTS 与自扫闸门反复点名）
  全都源于有人另造了一份计数逻辑。CLI 的存在意义恰恰是**消灭**第二把尺子，不能再造一把。

## 3. 命令面（三个子命令）

统一约定：`<bin>` = `.build/debug/TcoderMonitor` 或 `dist/Tcoder.app/Contents/MacOS/TcoderMonitor`。
`stdout` 只放读数（`--json` 时只放 JSON），人类看的进度与警告一律走 `stderr`，便于 `| jq`。

| 命令 | 行为 | 输出 |
|---|---|---|
| `scan <path>` | 五路并行分析 + 评分 | `ProjectReport` 的 JSON（默认 pretty） |
| `score <path>` | 同上，但只打读数 | 文本：失败路 → 综合分 → 代码口径 → 分量表 → 问题/建议，**首行带总体** |
| `doctor [<path>]` | **不跑分析**，只自检 | 二进制绝对路径、构建口径（debug / release）、bundle 版本、`<path>` 是否存在且为目录、是否 git 仓库 |

`doctor` 的用途只有一个：**AI 在相信任何读数之前，先确认自己用的是哪个二进制**。
它故意不调分析器，所以秒回；HEAD 与总体这两个数不在这里重复造，
它们本来就分别躺在 `git.headSHA` 与 `score` 首行里。

参数（只这些，多了不加）：

- `--out=<file>`：把 JSON 另写一份到该路径（`scan` 用）。写的是**调用方指定的路径**，不是 App 的支持目录。
- `--compact`：JSON 压成单行，便于 `| jq -c` 与管道。
- `--allow-network`：显式打开依赖分析的在线查（OSV / npm registry）。默认 **false**，
  与 GUI 的 `AppState.allowNetworkLookups = false` 对齐。
- `--log=<file>`（**可重复**）与 `--window-days=<n>`（默认 7）：对应界面的「附加日志文件」与
  日志窗口天数。**为什么这两个是必需而不加会留坑**：CLI 少了 `--log`，一个日志不放在
  `Logs/error.log`、`crash.log`、`~/Library/Logs` 约定位置的项目就永远扫出"运行稳定性缺席"，
  而读的人分不清是"这项目真没日志"还是"入口没给"。实测：同一棵树不带 `--log` 是
  综合 75 / 缺席 3 维，带一个真日志文件变综合 80 / 缺席 2 维，运行稳定性进入场。
  `--log` 指向不存在的文件时**直接判用法错（64）**，不悄悄收下。
- `--help` / `-h` / `help` / `--version`：用法与版本，**退出码 0**（不是 64）。

没有 `--json`：`scan` 的存在意义就是吐 JSON，再加一个同名开关等于给自己造两种口径。

**入参必须与 GUI 逐字对齐**，否则"新老两条路对表"这句话就是空的：
`ScanOptions.default`、`extraLogURLs: []`、`withinDays: 7`、`allowNetwork: false`。
CLI 内部就是把 `AppState.scan` 那五路扇出搬过来（`code / git / logs / deps / coverage`
→ `HealthInputs` → `WeightedHealthScorer.score`），`previousScore` 传 **nil**。

`previousScore` 传 nil 为什么安全（已核实，不是猜的）：`overall` 的定义是
`Σ(score·weight)`（`WeightedHealthScorer.swift:32-35`），`previousOverall` 只进
`HealthScore.trend` 与界面"上次"那格，**不参与 `overall` 的数值**。
且 `self_score.sh` 现走的 GUI 路本来就喂一个空沙箱、拿到的也是 nil，两侧同值。

### 退出码（没有"静默成功"这一档）

| 码 | 含义 | 判据 |
|---|---|---|
| 0 | 五路全回来 | `failedSections.isEmpty` |
| 2 | 报告可用但有路失败 | `failedSections` 非空且未全败 |
| 3 | 被扫路径不可用 | 不存在 / 不是目录 / 不可读 |
| 4 | 五路全失败 | `failedSections.count == 5` |
| 64 | 命令行用法错 | 未知子命令、缺 `<path>`、未知参数 |

`score` 与 `scan` 共用这套码。**AI 消费者契约**：非 0 退出时读到的数字**不许**当成
"这个仓库就是这样"，必须先读 `failedSections`。

## 4. Schema 同源与诚实性（这份设计真正的风险所在）

1. **JSON 就是 `ProjectReport` 本体**，不新建 DTO、不新建 `Codable` 包装类型。
   理由：两个类型描述同一个东西，早晚分叉（本仓已为此写过专门的红线）。
   `ProjectReport` 需要 `MonitoredProject`，CLI 现场合成一个
   （`name` = 目录基名、`path` = 解析后的绝对路径、`id` = 每次新建的 `UUID()`），
   它是**入参的如实记录**，不是假数据。
2. **缺数据不得写成 `0`**。`Models/**` 已按"落盘字段必须 Optional / 三态"整改过
   （`hugeFileCount: Int?` 那类），CLI 直接享受这个形状，不得为了 JSON 好看补默认值。
   新增任何面向 CLI 的字段都走同一条规矩。
3. **`score` 的文本读数把失败路打在分数前面** —— 先说"哪几路没跑出来"，再说分。
   顺序颠倒就等于让 AI 先看到 68 再看到"日志分析失败"。
4. **读数必须自带总体**。`score` 首行与 `scan` 的 JSON 都要能读出
   被扫目录的绝对路径、`totalFiles`、`codeLines`、`git.headSHA`。本仓每条读数都要带总体：
   同一仓库扫仓库根与扫某棵 worktree 的分数**不可互相比较**，这是发生过的事实
   （`190/35471`、`220/43118`、`296/45732` 三个总体下的分数互不可比）。
   CLI 是 AI 用的，AI 不会像人一样记得去问总体，所以把总体印在读数旁边。
5. **CLI 零写盘**：不碰 `TCODER_SUPPORT_DIR`、不写 `projects.json`、不写 `reports/`、
   **不写 `score-history.json`**。GUI 与 CLI 共用的只是"读同一套分析器 + 同一个 Codable 类型"，
   落盘与历史仍只归 GUI。理由：AI 每扫一次就污染一次真实用户的历史与项目列表，
   是比"没有 CLI"更糟的结果。

## 5. 分派条件（不许误判 GUI）

`TcoderMonitorApp.init()` 里，仅当 **`CommandLine.arguments[1]` 精确等于**
`scan` / `score` / `doctor` / `--help` / `-h` / `help` / `--version` 之一时进 CLI 流程；
其余一律照常起 GUI。

为什么必须这么窄：现有取证链会传 `-ApplePersistenceIgnoreState YES`（`self_score.sh`），
LaunchServices 起 App 会传 `-psn_…`，它们都以 `-` 开头、都不在这张词表里。
词表命中即进 CLI、不命中即 GUI，**没有第三种"猜"**。

## 6. 文件与守卫

新增（全部落在 `Sources/TcoderMonitor/CLI/**`，每个文件守 400 行线）：

| 文件 | 内容 |
|---|---|
| `CLIRouter.swift` | 词表判定 + 参数解析 + 用法文案 |
| `CLIScan.swift` | 五路扇出、`HealthInputs` 组装、`ProjectReport` 编码 |
| `CLIScoreText.swift` | `score` 的文本读数（失败路优先的形状） |

被引用性：三者都由 `TcoderMonitorApp.init()` 这条产品代码路径调用，天然过逐符号零引用普查。
`censusBaseline`（现 110）**只由总工按实测更新**，且新增文件的注释要写清"谁加的、凭什么被引用"。

**可测性要求（不写下来就做不到）**：`CLIScan` 必须把五路分析器做成**带默认值的构造参数**
（`init(code: CodeAnalysisProviding = FileSystemCodeAnalyzer(), git: … , …)`）。
这不是给冻结协议加要求 —— 冻结区只说"不得给协议加参数"，而"给自己的具体类型加带默认值的入参"
正是它指定的做法。没有这个缝，退出码 2 / 4 就只能靠真扫一个坏仓库去凑，那种测试既慢又脆。

新增测试 `Tests/TcoderMonitorTests/CLIRouterTests.swift`（+ 按需 `CLISchemaTests.swift`，
每个 <400 行）：

- 词表：命中 `scan` 进 CLI、`-ApplePersistenceIgnoreState` 与 `-psn_` 不进、未知子命令 → 64、`--help` → 0；
- 退出码 0/2/3/4/64 各自可达（用假分析器/假路径造，不靠真扫）；
- **`scan` 的 JSON 输出当场 `JSONDecoder` 解回 `ProjectReport` 并断言关键字段一致** ——
  这条是"CLI 与 GUI 同一把尺子"的实质证明，不靠话说一致；
- 缺数据三态：构造 `code == nil` 的输入，断言 JSON 里是 `null`/缺席而**不是 `0`**；
- 配**元测试**（本仓规矩：扫描型守卫必须能抓到坏样例，否则是永真绿）。

## 7. 验收（Definition of Done）

1. `./scripts/locked_build.sh build && ./scripts/locked_build.sh test` 双绿（贴真实输出）。
2. **端到端数**：release 构建下，`tcoder score <仓库根>` 的墙钟时间，与替换前
   `self_score.sh`（GUI 路）的墙钟时间，各测一次并报口径。
3. **新老对表**：同一总体（显式 `SCORE_TARGET=<仓库根>`）下，逐项对齐
   综合分 / 代码口径 / 分量表每一维 / 问题与建议条数 / `totalFiles` / `codeLines`。
   **这一条只进汇报与笔记，不进常驻测试** —— 把产品的分数钉成回归基线是 AGENTS 明令禁止的。
4. `self_score.sh` 改造后仍保留 provenance 前置与 `.scratch` 自清，且**读不到余量一律判败**的语义不变。
5. `dist` 打包链与 `verify_provenance.sh` 零改动即通过（证明"只有一个二进制"这句话为真）。

## 8. 风险与回退

| 风险 | 应对 |
|---|---|
| `App.init()` 里阻塞主线程导致某路分析器需要主线程 while 等待 → 死锁 | spike 已证两路可跑；实现时给整体等待加硬上限，超时按退出码 4 并**明写"超时未回"而不是"没有数据"** |
| 五路里 `deps` 在线查在 CI 无网时慢 | 默认 `allowNetwork=false`，在线查只在 `--allow-network` 下发生 |
| 新增三个 Sources 文件撞零引用普查 / 400 行线 | 提交前先跑 `build --build-tests` + 全量 `test`，撞了就是拆，不调阈值 |
| 未来有人拿 CLI 当"官方接口"，把 schema 当契约依赖 | 本轮只在 `docs/口径与已知限制.md` 记一句"CLI 为内部工具，schema 不承诺稳定" |

**回退**：CLI 是纯增量入口，不动任何分析器实现。出问题就把 `App.init()` 里那一分派调用摘掉
（GUI 行为回到改动前），`self_score.sh` 保留原 GUI 轮的形态到一个提交，随时可退。

## 9. 明确不做（防范围膨胀）

MCP server、PATH 安装与对外 `tcoder` 命令、`--watch` 常驻模式、多项目列表管理、
运行时 CPU/内存指标的 CLI 化（`MachSystemMonitor` 是长驻语义、且"两帧才出速率"，
一次性和它谈不来）、外部参数解析库、以及**任何为了 CLI 好看而改动的评分语义或阈值**。
