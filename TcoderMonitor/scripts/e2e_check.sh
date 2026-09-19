#!/bin/bash
# 端到端验收：让 App 用真实目录跑完整分析链路，再把落盘的测量结果读回来核对。
# 原理：ProjectStore 会把项目注册表持久化到 Application Support，
# 预置一个指向夹具目录的项目后，ProjectDetailView.onAppear 会自动触发一次真实扫描。
# 用法: scripts/e2e_check.sh [夹具目录]
set -euo pipefail
cd "$(dirname "$0")/.."

FX="${1:-/tmp/tcoder-fixture}"
SUPPORT="$HOME/Library/Application Support/TcoderMonitor"
UUID="11111111-2222-3333-4444-555555555555"
APP="dist/Tcoder Monitor.app"

if [ ! -d "$FX" ]; then echo "!! 夹具目录不存在: $FX"; exit 1; fi

echo "==> 1/6 构建并打包"
./scripts/build_app.sh release >/dev/null 2>&1 || { echo "!! 构建失败"; ./scripts/locked_build.sh build; exit 1; }

# 本脚本必须清空 Application Support 才能逼 App 走一次真实扫描，
# 而那份状态就是用户自己的项目列表——曾经被这把脚本清掉过一次，先备份再收尾还原。
BACKUP=""
if [ -d "$SUPPORT" ]; then
  BACKUP="/tmp/tcoder-archive/appstate-pre-e2e-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$(dirname "$BACKUP")"
  cp -R "$SUPPORT" "$BACKUP"
  echo "    已备份用户现有状态 -> $BACKUP（收尾自动还原；如需保留夹具结果设 KEEP_E2E_STATE=1）"
fi

echo "==> 2/6 预置真实目录项目（清空旧状态）"
rm -rf "$SUPPORT"
mkdir -p "$SUPPORT/reports"
python3 - "$SUPPORT" "$UUID" "$FX" <<'PY'
import json, sys, datetime
support, uuid, path = sys.argv[1], sys.argv[2], sys.argv[3]
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
project = {
    "id": uuid, "name": "夹具项目 e2e", "path": path,
    "addedAt": now, "isDemo": False,
}
with open(f"{support}/projects.json", "w") as fh:
    json.dump({"projects": [project], "selectedProjectID": uuid}, fh, indent=2)
print(f"    项目路径 = {path}")
PY

echo "==> 3/6 启动 App"
# 只允许优雅退出。本仓库规约明令"不向任何进程发送信号、kill、重启"，
# 所以这里绝不能用 pkill 兜底——旧版本里那条 `|| pkill -x TcoderMonitor` 是违规，已删除。
# 多实例还有实害：它们共用 ProjectStore，旧实例在退出时会把内存里的项目列表回写，
# 覆盖掉本脚本刚预置的夹具项目，于是读回的报告根本不是本次扫描的产物。
osascript -e 'tell application id "com.tcoder.monitor" to quit' 2>/dev/null || true
sleep 3
STILL=$(pgrep -x TcoderMonitor | wc -l | tr -d ' ')
if [ "$STILL" != "0" ]; then
  echo "!! 仍有 $STILL 个实例不响应退出：$(pgrep -x TcoderMonitor | tr '\n' ' ')"
  echo "!! 它们会在退出时回写 ProjectStore，污染本次取证。请手动 Cmd+Q 后重跑。"
  echo "!! 已备份的状态在：${BACKUP:-（无）}"
  exit 1
fi
rm -rf "$HOME/Library/Saved Application State/com.tcoder.monitor.savedState" 2>/dev/null || true
# 曾经崩溃过一次的话，macOS 会一直弹「是否重新打开窗口」并挡住主窗口创建；
# Info.plist 的 NSQuitAlwaysKeepsWindows=false 对已记录的崩溃不生效，需要这条。
defaults write com.tcoder.monitor ApplePersistenceIgnoreState -bool YES
open "$APP"
sleep 14

PID=$(pgrep -x TcoderMonitor | head -1 || true)
if [ -z "$PID" ]; then echo "!! App 未启动"; exit 1; fi
echo "    pid=$PID"

# 预置项目必须还活着，否则后面的报告就是别人的扫描结果。
if ! grep -q "$UUID" "$SUPPORT/projects.json" 2>/dev/null; then
  echo "!! 预置项目已被回写覆盖，取证不作数"; exit 1
fi

WIN=$(xcrun swift /tmp/winlist.swift "$PID" 2>/dev/null | head -1 | cut -f1 || true)
if [ -n "$WIN" ]; then
  screencapture -x -o -l"$WIN" /tmp/tcoder_e2e.png && echo "    截图 -> /tmp/tcoder_e2e.png (window $WIN)"
else
  echo "    !! 没拿到窗口 id，跳过截图"
fi

echo "==> 4/6 读回落盘的测量结果"
REPORT="$SUPPORT/reports/$UUID.json"
for _ in $(seq 1 20); do [ -f "$REPORT" ] && break; sleep 3; done
if [ -f "$REPORT" ]; then
  python3 - "$REPORT" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
def show(title, keys, obj):
    print(f"  {title}")
    for k, fmt in keys:
        v = obj.get(k) if obj else None
        if v is None: v = "缺失"
        if isinstance(v, float): v = f"{v:.3f}"
        print(f"    {k:<22} {v}")
code = r.get("code") or {}
git  = r.get("git") or {}
logs = r.get("logs") or {}
deps = r.get("dependencies") or {}
health = r.get("health") or {}
show("代码扫描", [("totalFiles",0),("codeLines",0),("commentLines",0),("blankLines",0),
                  ("duplicationRatio",0),("todoCount",0),("fixmeCount",0),
                  ("longFunctions",0),("averageFunctionLength",0),
                  ("averageCyclomaticComplexity",0),("analyzedFunctionCount",0)], code)
print("    languages              ", [ (l["language"], round(l["share"],3)) for l in code.get("languages",[]) ][:5])
print("    topComplexFunctions    ", [ (f["name"], f["cyclomaticComplexity"]) for f in code.get("topComplexFunctions",[]) ][:3])
print("    hugeFiles              ", [ (f["path"].split("/")[-1], f["lineCount"]) for f in code.get("hugeFiles",[]) ][:3])
show("Git 分析", [("isRepository",0),("branch",""),("totalCommits",0),("commitsAnalyzed",0),
                  ("historyTruncated",0),("discoveryMode",""),("resolvedRepositoryRoot",""),
                  ("projectAgeDays",0),
                  ("totalAdditions",0),("totalDeletions",0),("filesTouched",0)], git)
print("    authors                ", [ (a["name"], a["commits"], a["additions"], a["deletions"]) for a in git.get("authors",[]) ])
show("日志分析", [("errorCount",0),("exceptionCount",0),("warningCount",0),("crashCount",0),
                  ("totalLinesScanned",0)], logs)
print("    topErrors              ", [ (e["signature"], e["count"]) for e in logs.get("topErrors",[]) ][:5])
print("    scannedFiles           ", [ f["path"].split("/")[-1] for f in logs.get("scannedFiles",[]) ])
show("依赖分析", [("totalDependencies",0),("outdatedCount",0),("vulnerableCount",0)], deps)
print("    ecosystems             ", [ (e["ecosystem"], len(e.get("dependencies",[]))) for e in deps.get("ecosystems",[]) ])
print("    advisories             ", [ a["id"] for a in deps.get("advisories",[]) ])
show("健康评分", [("overall",0),("narrative","")], health)
print("    components             ", [ (c["name"], c["score"], round(c["weight"],2)) for c in health.get("components",[]) ])
PY
else
  echo "  !! 没有生成报告：$REPORT（扫描可能未完成）"
fi

echo "==> 5/6 扫描耗时"
python3 - "$REPORT" <<'PY' 2>/dev/null || true
import json, sys
r = json.load(open(sys.argv[1]))
c = r.get("code") or {}
print(f"    代码扫描 durationMs = {c.get('durationMs')} ms"
      f"（{(c.get('durationMs') or 0)/1000:.1f} 秒）")
PY

echo "==> 6/6 收尾"
if [ -n "$BACKUP" ] && [ "${KEEP_E2E_STATE:-0}" != "1" ]; then
  osascript -e 'tell application id "com.tcoder.monitor" to quit' 2>/dev/null || true
  sleep 3
  if [ "$(pgrep -x TcoderMonitor | wc -l | tr -d ' ')" != "0" ]; then
    echo "    !! 仍有实例在跑，暂不还原（还原会被它退出时回写覆盖）"
    echo "    !! 请 Cmd+Q 后手动：rm -rf \"$SUPPORT\" && cp -R \"$BACKUP\" \"$SUPPORT\""
  else
    rm -rf "$SUPPORT"
    cp -R "$BACKUP" "$SUPPORT"
    echo "    已还原用户原有项目列表 <- $BACKUP"
  fi
fi
echo "完成。App 报告保留在 $SUPPORT"
