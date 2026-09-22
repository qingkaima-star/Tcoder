# R5b · 覆盖率报告**身份层**要新增的契约字段清单

> 工单：`docs/检测正确性整改清单.md` 的 **RD-25 / RD-26** 剩余那半（身份层）+ §6 链路契约。
> 负责流：**WS-R5B CovIdentity**（R5 触顶后接手）。工作树 `.worktrees/r5b-covidentity`，分支 `ws/r5b-covidentity`。
> 本篇是**设计件，先于代码**：`Models/**` 是冻结区，下列字段一律**由总工落**，本流只在派生类型里跑通端到端。
> 过程证据与实跑读数在 Obsidian `112 WS-R5 覆盖率身份与去重真修.md`（续写，不另起笔记）。

## 0. 为什么必须有这一层（现场，逐条 `Read` 到过）

`Services/Coverage/CoverageAnalyzer.swift` 把多份报告合并后**只留一个百分比**：
落盘契约 `CoverageMetrics` 里写着 `reports[]` 与 `scannedFileCount`，**没有一处写着每份报告是谁**。
于是三份模块级 lcov 相加在界面上与一份全量报告**长得一模一样**，读的人无法知道：

1. 分母是不是同一份源码（`prefix(6)` 之外，R5 已修的那半）；
2. 有没有被上限丢掉（丢了多少、丢了哪几份）；
3. 两份报告是不是**同一次测试运行**的两种落法（同一份证据数两遍）。

R5 已交付：四类身份的**计算**与按源码行求并（`CoverageReportIdentity` / `CoverageLineLedger` /
`CoverageMergePlanner`）。但身份只活在内存里的派生类型上，**没落盘 ⇒ 上不了屏 ⇒ 换个人读不到**。
本清单就是"落盘那半"。

## 1. 六条点名字段（一律 Optional；非 Optional 带默认值会让旧报告整份解码失败）

| 字段 | 类型 | 谁来写 | 谁来读 | 量不到时上屏打什么 |
|---|---|---|---|---|
| `CoverageReport.format` | `String?` | `CoverageAnalyzer.parse(url:…)`：`CoverageReportFormat.identify(fileName:)` 这张**唯一来源表**（现写进的是 `toolName`，中文/带空格的展示名，不能当身份键） | 去重判定（`isCoPublishedPair`）、覆盖率页"来源"标签、`scripts/report_parity.py` 对表 | `nil` = 旧报告没记过这一格 ⇒「**格式未记录（旧报告，不声称与任何一份同源）**」；`"unrecognized"` = 文件名在候选清单里但认不出格式 ⇒「认不出格式，不与任何报告合并」。**两者不是同一件事，不许都渲染成 `nil`** |
| `CoverageReport.runKey` | `String?` | `CoverageReportIdentity.derive(…)`（R5b 改判后：证据 = **同一输出目录共位** + **正文互证**（对偶格式数字核对／逐行账本一致／正文里的运行时刻）；**不再取路径子串猜来的 unit/集成归类**） | `CoverageMergePlanner.dropSameRunDuplicates` 的分组键；覆盖率页"同一来源已合并 N 份" | `nil` = 认不出 ⇒「**这份报告认不出属于哪次运行：<文件名>**」，且**不参与任何去重**（宁可留重复，也不许凭猜合并掉证据） |
| `CoverageReport.moduleKey` | `String?` | 同上：报告路径相对被扫根、剥掉"产物目录段"后剩下的相对目录（`""` = 仓库根） | 覆盖率页的分组呈现；「全仓报告 vs 模块报告」的重叠判定 | `nil` = 相对形状切不出来（报告在被扫目录之外）⇒「**模块未知（报告在被扫目录之外）**」；不许把绝对路径原样当模块键（换机器就换键，本轮实测踩过 `/var` ↔ `/private/var`） |
| `CoverageReport.sourceFingerprint` | `String?` | `CoverageSourceBinding`：被扫仓库 `git rev-parse HEAD` 短哈希（现只在 `CoverageSourceState.headCommit`，随分析丢掉） | 新鲜度那句（`generationSummaryText` 的替代者）、陈旧证伪、健康分的"按新鲜数据计"判定 | `nil` = 非 git 目录 / git 读失败 ⇒「**未绑定提交（非 git 或 git 读失败），不按新鲜数据声称**」。**边界必须写死**：这一格记的是"扫描时源码的指纹"，**不是**"报告测量时源码的指纹"——覆盖率产物侧没有任何一处写着它测哪个提交，所以 `mtime ≥ 该提交时刻` 只能说"未见更早证据"，**绝不允许**渲染成"绑定在该提交上" |
| `CoverageMetrics.droppedByCap` | `Int?` | `CoverageMergePlanner` / 发现阶段（`CoverageReportDiscovery`）：命中上限（深度 ≤6、40 份）而**没能进合并**的合法报告份数 | 覆盖率页页尾句、`report_parity.py`、健康分的"扫描面完整吗" | `nil` = 旧报告没统计 ⇒「**未统计是否有报告被上限丢弃**」（不许渲染成"没有问题"）；`0` = 一份没丢（一句真话，必须写 0 不许留 nil）；`>0` ⇒「**另有 N 份未合并**」+ 逐条点名（见 §2 的 `undisplayedReports`） |
| `CoverageMetrics.mergeConfident` | `Bool?` | `CoverageMergeConfidence.evaluate(…)`（R5b 新增，**纯函数**）：结论只来自"进入总数的每一份报告四格身份齐全 **且** 互相核对过"。**禁止**由"有几份报告 / 只剩一份所以谈不上合并"推出 | 覆盖率页的"这个总数可不可信"角标、`Services/Health/HealthBreakdown.swift` 的 `MissingDimensionReason.testingAbsence`（现在它在本该说"有数字但不可核对"时错说"里面没有可用的行覆盖数字"）、健康评分是否采信该总数 | `nil` = **压根没给总数**（缺证据 ≠ 不可信）；`false` = 给了总数但身份不全 ⇒「**总数不可信：N 份报告缺 <runKey/格式/模块/源码指纹>**，已分开呈现」；`true` = 进总数的每份身份互证齐全。**三态不许压成布尔**，`false` 与 `nil` 混掉就等于把"没测"说成"测了但可疑" |

## 2. 配套的两组（不点名但缺了上面就落不了地）

### 2.1 §6.1 统一显示形状（三道截断共用一个样式，全站同形）

| 字段 | 类型 | 语义（本链的具体含义） |
|---|---|---|
| `CoverageMetrics.truncationTotalCount` | `Int?` | 真实总数 = 已看到的候选 + **已点名**的超限项。深于 6 层根本没下潜的部分**不在**这个数里（它进 `unmeasuredScope`），所以这一格必须配 §6.1 那句"没测/测不准的范围"一起读，单独读它是**低估** |
| `CoverageMetrics.displayedCount` | `Int?` | 真正交给解析/合并的份数（= `consideredCount` 与上限之差） |
| `CoverageMetrics.undisplayedCount` | `Int?` | `max(0, totalCount - displayedCount)`，**逐条带稳定坐标**：`undisplayedReports: [String]?`（超限那份报告的文件路径，可点名）、`unexaminedDirectories: [String]?`（因深度上限没下潜的目录，点名到目录） |
| `CoverageMetrics.unmeasuredScope` | `String?` | 人话 + 计数：「N 个目录深于 6 层没看、M 个目录读不动」。**这一格非空时，"该项目没有覆盖率报告"这句话不成立** |

### 2.2 R5 已提过、身份层要用到的其余格子（原文在 Obsidian `112` 的 ## 契约缺口，此处只登记新增的两格）

`consideredReportCount` / `droppedReports[]` / `parseFailureReasons` / `basis` /
`conflictingFileCount` / `excludedFoundLines` / `bindingState` —— 口径不变，R5 已逐条写过理由。
新增：`runEvidence: String?`（`contentStamp` / `coPublishedPair` / `identicalLineSet` /
`sameDirectoryOnly` / `none`）**为什么要它**：`runKey` 只有"键"没有"凭的是什么"，
读的人无法分辨"同一次运行的对偶落法"与"恰好放进了同一个目录"，
后者不足以声称同源 ⇒ 键相同但证据只是 `sameDirectoryOnly` 时**不去重**（本流已这样实现）。

## 3. 落字段的顺序与自带守卫（按 AGENTS §3 冻结区 additive 登记规矩）

1. **additive、只加不改**：任何既有成员一字不动；新字段全部 Optional、不进 `CodingKeys` 的必填路径
   （`encodeIfPresent` 的"整键缺席"表达"没测到"，与 `ProjectStoreRoundTripTests` 同源）。
2. **自带守卫**（缺了守卫下一轮就长回去）：
   - 三态钉法：`nil` / `0` / `>0` 三种输入各一条用例（`droppedByCap` 已有同形状先例
     `CoverageAnalyzerTests` 的 `unreadableDirectoryCount` 两向用例）。
   - `mergeConfident` 的三态各一条，外加一条**反例**：只有一份报告、但该报告缺 `sourceFingerprint`
     ⇒ 必须 `false`（钉住"不许由份数推出 confident"这条）。
   - `runKey == nil` 的披露句必须**有牙**：单独摘掉那句 ⇒ 用例转红（R5 的反证⑤同形状）。
3. **本流在字段落地前已完成的部分**：身份计算本身（`CoverageReportIdentity` +
   `CoverageRunIdentity` + `CoverageMergeConfidence`）写成**纯函数、可注入、不读盘**，
   单测直接吃字符串与 URL 参数；等总工落字段后只需把值抄进契约，判定不必重写。
