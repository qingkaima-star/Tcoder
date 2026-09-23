#!/bin/bash
# 屏上文字**装不装得下**的活界面读数器。
# P53 之前它是**纯报告器**（分不了"有意裁短"与"字丢了"，只能把 13 条一起吐给人看）；
# P54 起它对**其中一档**是闸门：装不下且没有去处的那些，exit 非 0。
# 另一档（装不下但 ⓘ 里有全文）仍然只报数、不判红。
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
# 想把这一层做成机器判据，得先有一个「这个元素允不允许折行」的通道。
# **P54 把这句话量掉了**（2026-09-23，已知答案的夹具 = 侧栏那条 51 字长名，屏上必被裁）：
#   `AXTruncated`  —— 每个 `AXStaticText` 都回 err -25212（属性不支持），SwiftUI 没实现；
#   `AXVisibleCharacterRange` —— 那一格回 `0+50 / 全长 50`，报的是"值多长"不是"看得见多少"。
# ⇒ "允不允许折行"这条通道**确实没有**，旧结论没错，但问题问错了：
#   该问的不是"它会不会折"，而是**被裁掉的那一半有没有去处**。
# 去处就是 `AXHelp`（侧栏名字格正是靠 `.help(project.name)` 把全名还给用户的）。
# 于是分两档，只有一档判红：**装不下 + 有 help = 有意裁短（报数）；装不下 + 无 help = 字丢了（exit 1）**。
# `ax_frames` 的第 9 列带这一位，夹具那一格**必须**落在"有 help"档 —— 它落进主门
# 就说明第 9 列没读到东西，整把尺子的分档当场判不成立。
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
# 窄态那趟的产物**另起一个目录**：与默认宽度的 dump 同名互相覆盖的话，
# 台账里"主门 0 处"就说不清是哪一档量出来的了。
OUT="$BOX/dump${SWEEP_WINDOW_WIDTH:+-$SWEEP_WINDOW_WIDTH}"
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
# 窗口宽。**不设 = 产品默认的 1280**；传 1080 = 本 App 自己的 `minWidth`（窄态那一档）。
# 为什么要开这个口子：这把尺子过去只在 1280 上量过，而"读数带被撑高 / 值折两行"
# 这一类缺陷**只在窄态现形**（乱的清单 §6 第 0 条就是这么漏掉的）。
# 宽度打进抬头，一批的口径因此是写在产物里的，不靠人记得"那次是窄态跑的"。
WIDTH_ARGS=(); [ -n "${SWEEP_WINDOW_WIDTH:-}" ] && WIDTH_ARGS=(TCODER_CAPTURE_WINDOW_WIDTH="$SWEEP_WINDOW_WIDTH")
echo "== 被拍产物 $BIN；沙箱 $SANDBOX；语言态 ${CAPTURE_LANG:-zh}；窗口宽 ${SWEEP_WINDOW_WIDTH:-1280（产品默认）}pt；正文字号 ${FONT}pt（猜的，见头注）"

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
    env ${WIDTH_ARGS[@]+"${WIDTH_ARGS[@]}"} "$BIN" -ApplePersistenceIgnoreState YES -selectedDetailSection "$page" "${LANG_ARGS[@]+"${LANG_ARGS[@]}"}" \
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
rows = []                      # 每条是 9 元组：页/实宽/实高/需宽/要几行/给几行/超出pt/值/有无 help
control_seen = False
control_has_help = False     # 夹具那一格有没有读到 AXHelp —— 第 9 列的分档自证
for fn in sorted(f for f in os.listdir(out) if f.endswith('.txt')):
    page = fn[:-4]
    for line in open(os.path.join(out, fn), encoding='utf-8', errors='replace'):
        if not line.startswith('FRAME\t'):
            continue
        parts = line.rstrip('\n').split('\t')
        if len(parts) < 8:
            continue
        w, h, need, want, have, slack, value = parts[1:8]
        # 第 9 列 = 有没有 `AXHelp`（P54 加的）。**老读数没有这一列**，
        # 缺列一律按"没有去处"算：宁可多判一条缺陷，也不许因为产物旧而自动放行。
        has_help = (parts[8] == "H") if len(parts) > 8 else False
        if long_name[:12] in value:
            control_seen = True
        # 容差：超出 6pt 或实宽 8% 以上才算一处疑似（取大者）。
        # 为什么留容差：小徽标上"差 3pt"实测全是字号猜错造成的误报
        # （「风险：高」这类 6 处，截图里字是完整的）。宁可漏报 3pt，
        # 也不要让报告器吐出 2/3 的假阳——那等于让下一个读它的人自己再筛一遍。
        if int(slack) > max(6, int(int(w) * 0.08)):
            rows.append((page, int(w), int(h), int(need), int(want), int(have), int(slack),
                         value, has_help))
            # 夹具**进了疑似清单**才算这一档的对照：它屏上一定被裁，而画法上
            # 就是"折一行加省略号 + 全名进 ⓘ" ⇒ 它必须落在「有意裁短」那一档。
            # 它要是进了主门，说明第 9 列根本没读到东西。
            if long_name[:12] in value:
                control_has_help = has_help

print(f'== 正对照：夹具那条长名字有没有被量成「装不下」 —— {"✅ 报了" if control_seen else "❌ 没报"}')
if not control_seen:
    print('   ⇒ 仪器不成立（要么宽度算错、要么这类元素压根没进树）。'
          '主门那些 0 一律读成「没量到」，不许读成「界面上没有溢出」。')
    sys.exit(1)

# **P54 的分档**：装不下 ≠ 缺陷。分两种，只有一种判红：
#   有 `AXHelp` ⇒ 被裁的那一半**有去处**（悬停看全文，侧栏名字格就是这个画法）——有意裁短，报数不判红；
#   没有 `AXHelp` ⇒ 字**丢了**，这一屏上没有任何地方能读到全文 —— 这才是 §2 那一轴的缺陷。
# 为什么用 help 而不是"猜这是数据还是文案"：无障碍层压根没有"被截断"这条通道
# （`AXTruncated` 全部 err -25212、`AXVisibleCharacterRange` 回的是**全文长**，
# 两条都在已知答案的夹具上量过，见 `ax_frames.swift` 头注）。
# 主门的**逐条容忍清单**（P54）。为什么要有它：无障碍层没有"这个元素允不允许折行"
# 的通道（本文件头注量过），所以"会折行的正文"与"被裁掉的短标签"在第 9 列上长得一样。
# 清单不是把判据放松 —— 它把**每一例外是谁、凭什么**写死在这里：
# 不在清单上的"装不下且无 help"一律 exit 1。加一条必须带类别与证据，
# 只写"这条看着没事"不算理由（同《守恒线要逐条留名的豁免口》）。
#
#   类别 W = 由 `DataFootnote` / `DataCaption` / `NoteLine` 渲染的整段口径：那里没有
#            `lineLimit` 且带 `.fixedSize(horizontal:false, vertical:true)` ⇒ 它会折行，
#            而 AX 把整段挂在**第一行那个元素**上、交回来的高就是一行（头注那 8 条即此类）；
#   类别 F = 短标签，超出量 ≤ 12pt 且格宽 ≤ 130pt —— 本尺子的字号是**猜的 11pt**，
#            这个量级正是字号猜错的分辨率（头注"差 3pt 全是误报"同一条，上界取 12pt）。
#
# 匹配用**值的前缀**：不写行号也不写坐标，那些每次布局都会漂。
TOLERANCE = [
    ("榜内只列", "W", "复杂度风险页尾那句，`DataFootnote` 会折两行；fb94e88 那轮人工判过"),
    ("最活跃时段", "W", "Git 洞察热力图脚注，`DataFootnote`；25a85c0 英文态已不再报"),
    ("的代码行落在重复块内", "F", "代码规模页 99pt 小格标签，超 9pt = 字号猜 11pt 的分辨率内"),
    ("仅统计 ≥2 行的函数", "F", "同上族，88pt / 超 8pt"),
    ("条 / 千行有效代码", "F", "同上族，79pt / 超 7pt"),
    # 豁免的键**不许含测得值**。P54 那四条写的是「第一次 3 天前 · 最近 3 天前」这种整串，
    # P55 拿窄态（1080）复跑时数据自己变成「2 天前」⇒ 前缀对不上 ⇒ 两条当场掉回主门。
    # 一条会因为**被扫的仓库又提交了一次**而失效的豁免，等于没有豁免。
    # 现在只钉到数字前面那个空格为止（这两句的句式是固定的，变的是里面的天数）。
    ("第一次 ", "F", "错误日志页的『第一次 / 最近』时间标签，窄态 124pt / 超 ≤12pt"),
    ("首次 ", "F", "总览 hero 同一句话的短形式，窄态 114pt / 超 ≤11pt"),
]


def tolerated(value, slack, width):
    """这条例外成不成立：**类别与量级都要对得上**，不是"前缀见过就放行"。

    W 类不设量级上界（整段口径本来就会差出一整行）；F 类必须仍在字号猜错的分辨率内
    （超 >12pt 或格宽 >130pt 就不该再算"字号猜错"，那是真装不下）。
    """
    for prefix, kind, _ in TOLERANCE:
        if not value.startswith(prefix):
            continue
        if kind == "W":
            return True
        if slack <= 12 and width <= 130:
            return True
        return False        # 前缀对上了但量级越界 ⇒ 不再豁免，报出来
    return False


defects = [r for r in rows if not r[8] and not tolerated(r[7], r[6], r[1])]
tolerated_rows = [r for r in rows if not r[8] and tolerated(r[7], r[6], r[1])]
escapes = [r for r in rows if r[8]]
print(f'== 分档自证：夹具那一格{"带" if control_has_help else "不带"} help ⇒ '
      f'{"落在「有意裁短」档，第 9 列读到了" if control_has_help else "落进主门，第 9 列没读到 help（尺子坏了）"}')
if not control_has_help:
    print('   ⇒ 第 9 列没生效：要么 `ax_frames` 没重新编译，要么 help 挂在别的元素上。'
          '这时"主门 0 处"是假绿，不许交付。')
    sys.exit(1)
dp = sorted({r[0] for r in defects})
print(f'== 主门：装不下**且没有去处**的文本 {len(defects)} 处，分布在 {len(dp)} 页：{dp}')
for page, w, h, need, want, have, slack, value, _ in sorted(defects, key=lambda r: -r[6])[:25]:
    print(f'   [{page}] {w}×{h}pt：要 {want} 行、给得起 {have} 行、**多出 {slack}pt**'
          f'（单行需 {need}pt）：「{value[:46]}」')
if len(defects) > 25:
    print(f'   …另 {len(defects) - 25} 处，见 {out}/')
def matched_kind(value, slack, width):
    """命中清单里的哪一类（打印用）。判据仍走 `tolerated`，这里只负责**说清凭什么**。"""
    for prefix, kind, _ in TOLERANCE:
        if value.startswith(prefix):
            if kind == "W" or (slack <= 12 and width <= 130):
                return kind
            return "越界"
    return "?"


print(f'== 另一档（有意裁短、全文在 ⓘ 里）：{len(escapes)} 处，'
      f'页分布 {sorted({r[0] for r in escapes})}')
kinds = [matched_kind(r[7], r[6], r[1]) for r in tolerated_rows]
print(f'== 容忍清单（逐条留名，见脚本内 TOLERANCE）：命中 {len(tolerated_rows)} 处 '
      f'= W 类（会折行的整段口径）{kinds.count("W")} 处 '
      f'+ F 类（字号猜错的分辨率内）{kinds.count("F")} 处'
      + (f' + 越界 {kinds.count("越界")} 处（应当出现在主门里）' if kinds.count("越界") else ''))
# 清单里今天没出现的条目要**念出来**：不念的话它会悄悄烂在里面，
# 下一个人以为"这条还在豁免什么"，而那个东西早就改版了（点名清单不自动长大的反面）。
hit = {p[0] for p in TOLERANCE for r in tolerated_rows if r[7].startswith(p[0])}
idle = [f'{p[0]}（{p[1]}）' for p in TOLERANCE if p[0] not in hit]
if idle:
    print(f'   本轮没命中的豁免条目 {len(idle)} 条（不是失败，是提醒可以删）：{idle}')
sys.exit(1 if defects else 0)
PY
