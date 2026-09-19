# Tcoder 项目监控

Apple Silicon 原生 macOS App（Swift + SwiftUI），对本地开发项目做一站式工程指标监控。

- 模块名 `TcoderMonitor` · bundle id `com.tcoder.monitor` · 仅 arm64 · macOS 14+
- 架构：SwiftUI Views → `AppState`（MVVM 根）→ Service Layer → 系统能力
- 并行开发规约见 [`TcoderMonitor/AGENTS.md`](TcoderMonitor/AGENTS.md)

## 功能

| 页面 | 产出 |
|---|---|
| 总览 Dashboard | 健康评分环、CPU/内存/今日错误/最近提交、代码规模与语言占比、实时性能曲线、最近提交、Top Errors、测试覆盖率 |
| 代码规模 | 文件数、总行/空行/注释行/有效代码行、语言占比、TODO·FIXME、最大文件 |
| 复杂度风险 | 巨大文件与中文拆分建议、圈复杂度最高的函数、重复代码率与重复块明细 |
| Git 洞察 | 提交数、项目年龄、提交趋势、24×7 活跃热力（按作者自己的时区）、分支与 HEAD |
| 贡献者 | 提交/增删/占比排行、每人活跃时段、Bus Factor 风险 |
| 性能监控 | 本机 CPU/内存/磁盘/网络实时曲线 + Top 进程 + **工程进程组**（按匹配模式汇总某服务的 CPU/RAM/Threads/Open Files） |
| 错误日志 | 解析 `Logs/error.log`、`crash.log`、macOS `.ips`；今日错误/崩溃/异常/警告、Top Errors 聚类（次数、首次、最近） |
| 依赖分析 | `package.json` / `pom.xml` / `build.gradle(.kts)` / `Package.swift` / `requirements.txt` / `pyproject.toml` / `go.mod` / `Cargo.toml` / `Podfile` / `Gemfile`；版本过旧与已知漏洞，可选在线查 OSV.dev 与 npm registry |
| 健康评分 | 9 维加权评分与优点/问题/建议。**启发式本地计算，未调用任何外部模型**，界面已如实标注 |

## 构建与运行

```bash
cd TcoderMonitor

# 开发期编译（多智能体并行时必须走这把锁，SwiftPM 的 .build 不支持并发）
./scripts/locked_build.sh build
./scripts/locked_build.sh test

# 产出可双击的 .app 到 dist/
./scripts/build_app.sh release
open "dist/Tcoder Monitor.app"
```

## 验收脚手架

```bash
# 端到端：预置一个真实目录让 App 自动扫描，再把落盘的测量结果读回来逐项核对
# （会先备份并自动还原你现有的项目列表；有其他实例在跑时会拒绝执行以免污染结果）
./scripts/e2e_check.sh /path/to/repo

# 九个页面逐页截图取证。开头硬门禁：从当前源码重建 + 测试必须跑绿，
# 否则 exit 1 —— 避免拿旧 dist 二进制截出九张"看着可信"的废图。
./scripts/verify_pages.sh

# 真实仓库取证（默认跳过，因为要对 59 万行做全量分析）：
# 断言的是诚实性——提交总数不得是截断采样值、不在仓库根也要认出父仓库、
# 无覆盖率报告时 hasData 必须为 false 而不是 0%。
TCODER_REAL_REPO=1 ./scripts/locked_build.sh test --filter RealRepositoryEvidenceTests
```

## 数据与隐私

- 所有分析**在本机完成**，不上传任何源码内容。
- 依赖在线查询默认关闭，需在「依赖分析」页手动开启；单次请求 5 秒硬超时，失败只降级为离线快照。
- 项目列表与报告存在 `~/Library/Application Support/TcoderMonitor/`，删除该目录即清空。
- 进程监控**只读展示**，不向任何进程发送信号。

## 已知限制

- 无 root 时逐进程指标只覆盖当前用户可见的进程；进程总数走 `sysctl(KERN_PROC_ALL)`，与 `top`/`ps -A` 同源。
- 内存口径为 `total - (free + speculative + purgeable)`，与活动监视器一致。
- 首次扫描 `~/Documents`、`~/Desktop` 下的目录时 macOS 可能弹一次文件访问授权。
- 覆盖率只读取仓库已生成的报告（lcov / istanbul / JaCoCo / coverage.py / clover），不会代为执行测试。
