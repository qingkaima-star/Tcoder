#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""perf_trio_false_reject.py —— 量「一致性尺里某一维有多常把人打回」：把一批读数枚举成所有 k 元子集喂给**那把真尺**。

为什么要有它（台账卷十 §167，#53 的裁定材料）：cert9a 四趟「整窗在场」全 `在屏`、两把主尺（每趟 p90 与
均值）都过 1.2×，却因为「出帧 p50 极差 20 > 10」被判不一致。需求方要在
**裁 A**（把出帧那一维摘出一致性判据、只当参考项）与**裁 B**（升成资格判据：低到某个值这趟作废）之间选，
而我手上只有一个 n=4 的样本 —— 那不足以支撑任何一边。于是把问题换成一个可数的量：
**同一批读数里任取 k 趟，两把主尺都过的那一组，有多少比例只被出帧那一维打回。**

⚠ 三条口径（不写出来就会被说过头）：
① **判据不许有两把手抄尺子**：散布怎么算、哪一维算"拦住了"，全部走 `perf_trio_agreement._judge_spread`
   （本文件只做"枚举子集 + 分类计数"）。所以它红/它绿，就是那把尺红/那把尺绿。
② 它量的是**这一批内部的子集抽样**，不是全产品抖动率；跨批合池时那句 caveat 要一起报（§167 两个数就是这么给的）。
③ **分母不成立就不出数**：可用趟数 < k ⇒ 明写"本次不作数"并 rc=1。假 0 比不报更贵（本仓记过很多次）。

用法：`python3 scripts/perf_trio_false_reject.py <run 目录>…`（通常在 `TcoderMonitor/` 下，
产物在**工作树根**的 `.scratch/tcoder-perf-<批名>-<档>-runN/`）。
"""
import itertools
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import perf_trio_agreement as trio        # noqa: E402  复用交付里那把尺，不自造第二把

FPS_TAG = "出帧 p50"                       # 与 _judge_spread 里那句告警共用的字样
K_LIST = (3, 4)                           # 三趟是协议下限，四趟是常见批长
PASS, FPS_ONLY, ELSEWHERE = "通过", "只被出帧拦", "别处也拦"


def load_readings(dirs):
    """逐趟读 meta＋表 ⇒ (可用读数, 被跳过的趟名)。跳过的**不进分母**。"""
    kept, skipped = [], []
    for d in dirs:
        reading = trio.read_run(d)
        (kept if reading else skipped).append((os.path.basename(str(d).rstrip("/")), reading))
    return [r for _, r in kept], [n for n, _ in skipped]


def classify(readings):
    """一组读数交给真尺子 ⇒ 三选一：全过 / 只被出帧那一维拦 / 别处也拦。"""
    bad, _lines, _name, _q = trio._judge_spread(list(readings), "idle")
    if not bad:
        return PASS, []
    return (FPS_ONLY if all(FPS_TAG in b for b in bad) else ELSEWHERE), bad


def sweep(readings, k):
    """枚举 C(n,k) 组 ⇒ {三分类: 计数}，外加最多两条"别处也拦"的实例（要给读者看，不许只报数）。"""
    counts = {PASS: 0, FPS_ONLY: 0, ELSEWHERE: 0}
    examples = []
    for combo in itertools.combinations(readings, k):
        verdict, bad = classify(combo)
        counts[verdict] += 1
        if verdict == ELSEWHERE and len(examples) < 2:
            examples.append([b for b in bad][:1])
    return counts, examples


def ratio_line(counts, k):
    """把计数折成一句人话。分母用"两把主尺都过的那些组"，**不是全部组**。"""
    agree = counts[PASS] + counts[FPS_ONLY]
    total = sum(counts.values())
    return ("   k=%d：共 %d 组 ⇒ 通过 %d、只被「%s」拦 %d、别处也拦 %d；"
            "两把主尺都过的 %d 组里这一维单独打回 %.0f%%"
            % (k, total, counts[PASS], FPS_TAG, counts[FPS_ONLY], counts[ELSEWHERE],
               agree, 100.0 * counts[FPS_ONLY] / agree if agree else 0.0))


def main(argv=None):
    dirs = [a for a in (argv or sys.argv[1:]) if not a.startswith("--")]
    if len(dirs) < min(K_LIST):
        print("!! 给出的 run 目录不足 %d 个 ⇒ 这支尺没被喂够数据，**本次不作数**" % min(K_LIST))
        return 1
    readings, skipped = load_readings(dirs)
    for name in skipped:
        print("   跳过 %s（read_run 返回空：缺表、解不动或被收尾复核打回）" % name)
    print("【一致性尺的组内打回率】可用趟数 = %d（给出 %d 个目录）" % (len(readings), len(dirs)))
    print("   出帧 p50 各趟 = %s" % "/".join("%.0f" % r["surfaces_p50_fps"] for r in readings))
    printed = 0
    for k in K_LIST:
        if len(readings) < k:
            print("   k=%d：趟数不够（%d < %d）⇒ 这一档不出数" % (k, len(readings), k))
            continue
        counts, examples = sweep(readings, k)
        print(ratio_line(counts, k))
        for first_bad in examples:
            print("      别处也拦的实例：%s" % first_bad)
        printed += 1
    if not printed:
        print("本次**不作数**：一档都没算出来。")
        return 1
    print("⚠ 口径：以上只在「这批读数的子集抽样」这一层成立，**不是全产品抖动率**；"
          "跨批合池时要另说一句机器状态差（§167 把两个数分开写就是这个原因）。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
