#!/bin/bash
# 披露入口活性取证（**报告器，不是闸门**）：按下去到底会不会多出行？
#
# 为什么需要它：`FunctionalHonestyGuardTests` 的 G10 只能证明"源码里那句
# 『已按当前排序列出前 N 项，另有 M 个未列出』旁边配了披露按钮"，
# 证不了那个按钮**按得动** —— 而"报数必须给入口"这条规矩的后一半正是后者。
# 合成鼠标到不了的地方，`AXUIElementPerformAction` 到得了（见 `ax_press.swift` 头部）。
#
# 判据三条，缺一不可：
#   1. 按之前后各读一次无障碍树，`visited` 必须**变大**（放出来的行就在树里）；
#   2. 按钮自身的 `AXDescription` 必须从「展开其余 …」翻成「收起 …」——
#      这是"状态真的翻了"的独立凭据，不只看元素数；
#   3. 一页上有多个披露入口时，**逐个按全**（先 `--list` 列出各自的 desc，
#      再按整条 desc 精确命中）。第一版按「展开其余」这个前缀在「复杂度风险」上
#      命中 2 个被自己拒了 —— 拒得对，但那一页就白跑了一趟。
#
# 用法: ./scripts/ax_disclosure_liveness.sh [页名...]      默认九页全跑
#   退出码：0 = 至少一处入口被证明是活的；1 = 一处都没有（要么真没入口，要么仪器没通）
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT=$(git rev-parse --show-toplevel)
SCRATCH="${TCODER_SCRATCH:-$ROOT/.scratch}"
BOX="$SCRATCH/tcoder-ax-tooltip"
BIN="$PWD/dist/Tcoder.app/Contents/MacOS/TcoderMonitor"
UUID="11111111-2222-3333-4444-555555555555"
SANDBOX="$BOX/sandbox-disclosure"
OUT="$BOX/disclosure"
DUMP="$SCRATCH/ax_dump"
PRESS="$SCRATCH/ax_press"

# 前置：两个工具必须在，缺就判败 —— 上一版没查，自清时把二进制删了，
# 九趟全部只在打 "No such file or directory" 而脚本照样 exit 0。
for pair in "ax_dump:scripts/ax_dump.swift" "ax_press:scripts/ax_press.swift"; do
    name=${pair%%:*}; src=${pair#*:}
    if [ ! -x "$SCRATCH/$name" ] || [ "$src" -nt "$SCRATCH/$name" ]; then
        xcrun swiftc -O "$src" -o "$SCRATCH/$name" 2> "$SCRATCH/$name.compile.log" \
            || { echo "!! $name 编译失败：$(head -3 "$SCRATCH/$name.compile.log" | tr '\n' ' ')"; exit 1; }
    fi
done
[ -x "$BIN" ] || { echo "!! 缺 $BIN —— 先跑 scripts/build_app.sh release"; exit 1; }

if [ $# -gt 0 ]; then SECTIONS=("$@"); else
  SECTIONS=("总览" "代码规模" "复杂度风险" "Git 洞察" "贡献者" "性能监控" "错误日志" "依赖分析" "健康评分")
fi
mkdir -p "$SANDBOX/reports" "$OUT"
python3 - "$SANDBOX" "$UUID" "$ROOT" <<'PY' || exit 1
import json, sys, datetime
support, uuid, path = sys.argv[1:4]
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump({"projects": [{"id": uuid, "name": "Tcoder（披露入口夹具）", "path": path,
                         "addedAt": now, "isDemo": False}], "selectedProjectID": uuid},
          open(f"{support}/projects.json", "w"), indent=2)
PY

count_of() { grep -o 'visited=[0-9]*' "$1" | head -1 | cut -d= -f2; }   # 读不到就是空串

probe_page() {  # probe_page <页名>   返回 0 = 这一页至少一处入口被证明是活的
    local page="$1" pid before after label proved=0 desc
    export TCODER_SUPPORT_DIR="$SANDBOX"
    "$BIN" -ApplePersistenceIgnoreState YES -selectedDetailSection "$page" \
        > "$OUT/$page.instance.log" 2>&1 &
    pid=$!
    sleep 20   # 等第一轮分析落盘、列表渲染出来（不足就是没数据，量出来的差也是假的）
    "$DUMP" "$pid" > "$OUT/$page--before.txt" 2>&1
    before=$(count_of "$OUT/$page--before.txt")

    # 先把这一页所有「展开其余 …」列出来，再按整条 desc 挨个按
    "$PRESS" "$pid" --list > "$OUT/$page--list.txt" 2>&1
    while IFS= read -r desc; do
        [ -n "$desc" ] || continue
        "$PRESS" "$pid" "$desc" > "$OUT/$page--press.txt" 2>&1
        "$DUMP" "$pid" > "$OUT/$page--after.txt" 2>&1
        after=$(count_of "$OUT/$page--after.txt")
        label=$(grep -o '✅ 已按：.*' "$OUT/$page--press.txt" | head -1)
        if [ -n "$before" ] && [ -n "$after" ] && [ "$after" -gt "$before" ]; then
            printf '   ✅ %s：%s → %s 个元素（+%s）  %s\n' "$page" "$before" "$after" \
                "$((after - before))" "${label:-（没回读到按成功的凭据）}"
            proved=1
            before="$after"
        else
            printf '   ⚠ %s：按「%s」之后 %s → %s —— 没变多，这一处入口按不动或本就展开着\n' \
                "$page" "$desc" "${before:-取不到}" "${after:-取不到}"
        fi
    done < <(sed -n 's/.*desc=\(展开其余 .*\) value=.*/\1/p' "$OUT/$page--list.txt" | sort -u)

    [ "$proved" = 0 ] && printf '   —  %s：这一页在这个数据态没有披露入口（或列表没超出上限）\n' "$page"
    if ps -p "$pid" > /dev/null 2>&1; then
        local who
        who=$(lsof -p "$pid" 2>/dev/null | awk '$4=="txt" && /TcoderMonitor$/ {print $NF; exit}')
        [ "$who" = "$BIN" ] && kill -TERM "$pid" 2>/dev/null \
            || echo "   ⚠ pid $pid 的二进制是「$who」，不是 $BIN —— 不动手"
    fi
    return $((1 - proved))
}

LIVE=0
SCANNED=0
for page in "${SECTIONS[@]}"; do
    echo "== $page"
    SCANNED=$((SCANNED + 1))
    probe_page "$page" && LIVE=$((LIVE + 1))
done
echo "== 九页里 $LIVE / $SCANNED 页至少有一处披露入口被证明是活的"
[ "$LIVE" -gt 0 ] || { echo "!! 一处都没有 —— 要么仪器没通，要么入口真是死的，这一趟不算通过"; exit 1; }
exit 0
