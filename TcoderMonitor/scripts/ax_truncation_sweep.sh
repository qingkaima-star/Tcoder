#!/bin/bash
# 屏上文字**装不装得下**的活界面读数器（**报告器，不是闸门**）。
#
# 为什么要有它：「乱」的五个轴里，**溢出/截断这一轴到今天一条机器判据都没有**——
# 乱清单 §2 那五行全是人眼从 36 张图里找出来的。眼睛能找到的前提是那张图里
# 恰好有被裁的字，而九页 × 两态 × 两种语言 = 72 张，逐张找不成立。
#
# 走过的弯路（记下来免得有人再走）：**无障碍的值通道看不见截断**。
# 第一版判"值以 … 结尾"，正对照当场打脸——侧栏那条 51 字的长项目名
# 在像素上画成 `Tcoder（截断正…出来的夹具项目名`，而树里的 `AXValue` 是**完整的 51 字**。
# 于是换成几何：这串字按本 App 正文字号画出来要多宽 vs 元素实宽（`scripts/ax_frames.swift`）。
#
# 已知误判类（2026-09-22 在 `fb94e88` 上量出来的，逐条人工判过）：
# **会折行的文本会被报成装不下，那不是缺陷。** 例：复杂度风险页尾那句
# 「榜内只列 20 个… 另有 91 个块 / 629 行未列入榜内。 另有 253 处拷贝…」，
# 实宽 586 / 单行需 639 / 实高 13pt，看着像被裁；其实它由 `DataFootnote` 渲染，
# 那里没有 `lineLimit` 且带 `.fixedSize(horizontal:false, vertical:true)` ⇒ 它会折成两行，
# 而 AX 把整段文字挂在**第一行那个元素**上，交回来的高就是一行。
# 该趟九页共报 17 条：正对照 9 条 + 这一类 8 条，**真缺陷 0 条**。
#
# 所以这份清单必须逐条分诊，分诊只看一件事——它由哪个组件渲染：
#   会折行（报出来≈噪声）：`DataFootnote` / `DataCaption` / `NoteLine` / `GlassSection` 的 subtitle；
#   真会裁（报出来=缺陷）：`DataTable.tableCell` 的定宽格（那里写死 `.lineLimit(1)`）、侧栏项目名。
# 想把这一层做成机器判据，得先有一个「这个元素允不允许折行」的通道——AX 里没有，别猜。
#
# 正对照（没有它这条判据就是"读不到 = 没有溢出"的永真绿）：
# 夹具注册一条名字极长的项目，侧栏那一格**必然**装不下。
#   它被报出来 ⇒ 尺子通，主门的数读得出口；
#   它没被报出来 ⇒ **仪器不成立**，当场 exit 1，不许把 0 当成"界面干净"。
#
# 用法: ./scripts/ax_truncation_sweep.sh [页名...]        默认九页全跑
#   CAPTURE_LANG=en     以英文态跑（英文串更长，这才是截断真正会咬人的地方）
#   BODY_FONT_PT=11     正文字号（AX 不给字体，只能注明是猜的；改字号=换一把尺子）
#   退出码：0 = 正对照成立且扫完；1 = 正对照不成立或有页面没读到树；2 = 前置缺失
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
ROOT=$(git rev-parse --show-toplevel)
SCRATCH="${TCODER_SCRATCH:-$ROOT/.scratch}"
BOX="$SCRATCH/tcoder-ax-truncation"
SANDBOX="$BOX/sandbox"
OUT="$BOX/dump"
FRAMES="$SCRATCH/ax_frames"
BIN="$PWD/dist/Tcoder.app/Contents/MacOS/TcoderMonitor"
UUID="11111111-2222-3333-4444-555555555555"
FONT="${BODY_FONT_PT:-11}"
# 这条名字就是正对照：侧栏那一格装不下它。
LONG_NAME="Tcoder（截断正对照）这是一条故意拉得很长很长用来验证尺子会不会把装不下的格子报出来的夹具项目名"

if [ ! -x "$FRAMES" ] || [ scripts/ax_frames.swift -nt "$FRAMES" ]; then
    xcrun swiftc -O scripts/ax_frames.swift -o "$FRAMES" 2> "$FRAMES.compile.log" \
        || { echo "!! ax_frames 编译失败：$(head -3 "$FRAMES.compile.log" | tr '\n' ' ')"; exit 2; }
fi
[ -x "$BIN" ] || { echo "!! 缺 $BIN —— 先跑 scripts/build_app.sh release"; exit 2; }

if [ $# -gt 0 ]; then SECTIONS=("$@"); else
  SECTIONS=("总览" "代码规模" "复杂度风险" "Git 洞察" "贡献者" "性能监控" "错误日志" "依赖分析" "健康评分")
fi
rm -rf "$SANDBOX" "$OUT"; mkdir -p "$SANDBOX/reports" "$OUT" || exit 2
python3 - "$SANDBOX" "$UUID" "$ROOT" "$LONG_NAME" <<'PY' || exit 2
import json, sys, datetime
support, uuid, path, name = sys.argv[1:5]
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump({"projects": [{"id": uuid, "name": name, "path": path,
                         "addedAt": now, "isDemo": False}], "selectedProjectID": uuid},
          open(f"{support}/projects.json", "w"), indent=2)
PY

LANG_ARGS=(); [ "${CAPTURE_LANG:-}" = "en" ] && LANG_ARGS=(-AppleLanguages "(en)")
echo "== 被拍产物 $BIN；沙箱 $SANDBOX；语言态 ${CAPTURE_LANG:-zh}；正文字号 ${FONT}pt（猜的，见头注）"

pids=(); FAILED=0
cleanup() {  # 只对自己起的、二进制路径核对过的那几个 pid 发 TERM（规约：绝不按 bundle id 广播）
    for p in "${pids[@]:-}"; do
        [ -n "$p" ] || continue
        if lsof -p "$p" 2>/dev/null | awk '$4 ~ /^txt/ {print $NF}' | grep -q "^$BIN$"; then
            kill -TERM "$p" 2>/dev/null
        fi
    done
}
trap cleanup EXIT INT TERM

for page in "${SECTIONS[@]}"; do
    export TCODER_SUPPORT_DIR="$SANDBOX"
    "$BIN" -ApplePersistenceIgnoreState YES -selectedDetailSection "$page" "${LANG_ARGS[@]+"${LANG_ARGS[@]}"}" \
        > "$OUT/$page.instance.log" 2>&1 &
    pid=$!; pids+=("$pid")
    sleep 20
    "$FRAMES" "$pid" "$FONT" > "$OUT/$page.txt" 2>&1
    rc=$?
    echo "   $page：退出码 $rc  $(grep -o 'SUMMARY .*' "$OUT/$page.txt" | head -1)"
    if [ "$rc" -ne 0 ]; then
        echo "   !! 这一页没读到树 —— 不是「没有溢出」，是仪器没通"
        FAILED=1
    fi
    cleanup; pids=()
done
[ "$FAILED" = "0" ] || { echo "!! 有页面没读到树 —— 本批不出数"; exit 1; }

python3 - "$OUT" "$LONG_NAME" <<'PY'
import os, sys
out, long_name = sys.argv[1:3]
rows = []                      # (页, 实宽, 需要宽, 值)
control_seen = False
for fn in sorted(f for f in os.listdir(out) if f.endswith('.txt')):
    page = fn[:-4]
    for line in open(os.path.join(out, fn), encoding='utf-8', errors='replace'):
        if not line.startswith('FRAME\t'):
            continue
        parts = line.rstrip('\n').split('\t')
        if len(parts) < 8:
            continue
        w, h, need, want, have, slack, value = parts[1:8]
        if long_name[:12] in value:
            control_seen = True
        # 容差：超出 6pt 或实宽 8% 以上才算一处疑似（取大者）。
        # 为什么留容差：小徽标上"差 3pt"实测全是字号猜错造成的误报
        # （「风险：高」这类 6 处，截图里字是完整的）。宁可漏报 3pt，
        # 也不要让报告器吐出 2/3 的假阳——那等于让下一个读它的人自己再筛一遍。
        if int(slack) > max(6, int(int(w) * 0.08)):
            rows.append((page, int(w), int(h), int(need), int(want), int(have), int(slack), value))

print(f'== 正对照：夹具那条长名字有没有被量成「装不下」 —— {"✅ 报了" if control_seen else "❌ 没报"}')
if not control_seen:
    print('   ⇒ 仪器不成立（要么宽度算错、要么这类元素压根没进树）。'
          '主门那些 0 一律读成「没量到」，不许读成「界面上没有溢出」。')
    sys.exit(1)

pages = sorted({r[0] for r in rows})
print(f'== 主门：量出「格子给不起那么多行」的文本 {len(rows)} 处，分布在 {len(pages)} 页：{pages}')
for page, w, h, need, want, have, slack, value in sorted(rows, key=lambda r: -r[6])[:25]:
    print(f'   [{page}] {w}×{h}pt：要 {want} 行、给得起 {have} 行、**多出 {slack}pt**'
          f'（单行需 {need}pt）：「{value[:46]}」')
if len(rows) > 25:
    print(f'   …另 {len(rows) - 25} 处，见 {out}/')
sys.exit(0)
PY
