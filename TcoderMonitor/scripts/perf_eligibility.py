#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""样本资格与基线新鲜度：**这批量的是什么条件、这读数能不能用**的那一层。

为什么从 `perf_trace_summary.py` 切出来（2026-09-25）：那个文件涨到 **417 行**，
被产品自扫的「巨大文件 400 行」同一条口径（`SourcesSizeAuditTests` /
`FileSystemCodeAnalyzer.mediumFileLines`）判红。本仓对这条债只有一个正解：
**拆文件才是修复**——抬线、塞挂账清单、把文件挪出扫描面都不算。
三枚函数（`period_eligibility` / `refusal_headline` / `freshness_note`）**一字未动**地搬进来。

【谁是真入口】本文件是这三枚判据的**唯一住处**；`perf_trio_agreement.py` 直接 import 这里。
`perf_trace_summary.py` 顶部仍留一行同名 import，那是给 selfcheck 里九处 heredoc 用的**别名**，
不是第二份实现——要清掉它，得同时改那九处引用，别只删别名。
"""
from perf_trace_metrics import input_rate_qualification


def human_recheck_refusal(meta):
    """收尾人手复核**没做成** ⇒ 返回该拒的那一句；做成了／老批次没这一格 ⇒ 返回 ""。

    为什么单独一枚函数而不是往 `period_eligibility` 里塞：那枚函数现在 42 行，
    再长就撞「函数 ≤ 50 行」那把门（本仓口径：拆一格一个函数才是修复，抬线不算）。

    【#127】`post_window_quiescence` 原来在探针取不到时**只印一行 stdout 就返回**，
    meta 一个字段都不落 ⇒ 下面那句「没有污染标记就算合格」把它读成「做成且没人动」：
    交互档拿「有资格答 T1」、心跳档拿「只答心跳期」，两句都是绿灯，
    而这同一句还被 `perf_trio_agreement` 读进 3/3 的计数（一把判据、两个读者）。
    现在写侧显式落 `quiescence_recheck=unavailable|measured`，读侧在这里拒。

    ⚠ **不追溯**：`quiescence_recheck` 缺失＝这一格还没被写过的老批次（含 09-27 那几批
    录制前就被闸门拒掉的 REFUSED 趟，它们已经出不了对照表）。把「缺字段」一律判死
    会顺手改动历史读数，而本函数的职责只是「不许把未判读成达标」。
    """
    if str(meta.get("quiescence_recheck") or "").strip() != "unavailable":
        return ""
    return ("收尾人手复核没做成（meta.quiescence_recheck=unavailable：那一刻静默探针取不到）"
            "⇒ 这一趟既没证「窗口内有人在动」也没证「没人动」，"
            "① 不许交、也不许进 ② 的 3/3；要重录到探针在场的那一趟")


def load_window_refusal(meta):
    """整窗负载**没采到** ⇒ 返回该拒的那一句；采到了／老批次没这一格 ⇒ 返回 ""。

    【#128】与 `human_recheck_refusal` 同一族、只差一维：写侧 `load_window_verdict`
    在 `load-in-window.tsv` 为空时**已经**落了 `load_in_window=未采到`（比 #127 那条诚实），
    但**这个值全仓没有任何读者**——资格判据读的是 `contaminated_by_foreign_load`
    与收窗那两个点（`load1_at_end`/`heavy_at_end`），于是「中段有没有编译挤满」这一维
    在零采样的那趟里被**缺席**补成了「干净」。而 §AP 立这一维的原因恰恰是
    「八趟里唯一落在 4.0 ms 红线内的那趟，收窗负载 19.73，两端看不件中段的编译」。
    ⇒ 「标记落地而判据住空集合」（第 38 类）：这一格必须有读者，否则记它等于没记。

    ⚠ 同样**不追溯**：`load_samples` 与 `load_in_window` 两个都没有的老批次
    （盘上现量 109 批，早于窗口内采样这一维）按原样处理，不在这里改口。
    """
    if str(meta.get("load_in_window") or "").strip() != "未采到":
        return ""
    return ("窗口内负载一个样本都没采到（meta.load_in_window=未采到）"
            "⇒ 闸门只看得到起窗与收窗两个点，中段有没有重活**未判**；"
            "两端干净不许补成整窗干净，这一趟不得作为判据①/② 的达标证据")


def period_eligibility(meta):
    """档位**声明**与收尾**复核**是否一致 → (样本可用吗, 给表头看的一句话)。

    `perf_preflight.sh` 在录制窗口结束后会**再问一次**人手探针，把结论写进 meta：
      interaction 档 → `no_human_input_during_window=1`：整窗一次人手都没有 ⇒ 那批量的是心跳期；
      idle 档        → `contaminated_by_human_input=1`：窗口里有人动手 ⇒ 样本被污染。
    这两个标记此前**只有写的人、没有读的人**（全仓 grep 只有一个写点），
    于是"没人配合"的那一趟照样能打印「有资格答 T1」。
    ⇒ 写进 meta 不等于被看见；判资格必须把复核读回来。
    """
    period = str(meta.get("period") or "idle")
    # 【同窗双仪器档不参与达标判定】归因那一趟为了拿栈，在同一次录制里多挂了一枚
    # Time Profiler ⇒ 被测进程身上真的多了一个采样器。它的读数**不是假的**，
    # 但**不是同一把尺量出来的那个量**：拿它去填 §1.3 的 3/3，等于用被仪器改过的条件
    # 认证"没被仪器改过"。这一维与「人手污染」同一条纪律：**写进 meta 的标记必须有读者**，
    # 而这里就是那个读者（`perf_trio_agreement._meta_or_none` 走同一个出口 ⇒ 两把读者一把判据）。
    if str(meta.get("blame_instrument") or "").strip() == "1":
        return False, ("这一趟挂了第二枚仪器（meta.blame_instrument=1，为了把长 update 归到调用栈）"
                       "⇒ 采集条件与认证档不同，只用于定位，**不得**进 §1.3 的达标计数")
    # 窗口结束时整机在忙 ⇒ 两档都不作数（争用会把 hitch 间隔压到每帧一次，见交接笔记 §AB）。
    # 与「人手污染」同一条纪律：**写进 meta 的标记必须有读者**，否则等于没记。
    if str(meta.get("contaminated_by_foreign_load") or "") == "1":
        return False, ("窗口结束时负载显示整机在忙（meta.load1_at_end / heavy_at_end）"
                       "⇒ 这批量的是别人占着机器时的帧，不得作为结论提交")
    # 【#127／#128】「没量到」与「量到了且干净」是两件事，前者不许折算成后者。
    # 两维共用一个出口：人手复核没做成、整窗负载零采样——都按未判拒掉（缺格的老批次不追溯）。
    refusal = human_recheck_refusal(meta) or load_window_refusal(meta)
    if refusal:
        return False, refusal
    # 输入来源**与投递节奏**决定这句话能不能说"真人"、能不能答"到不到 120Hz"。
    # 25 Hz 的合成滚动器（每 40 ms 一拍）比 8.333 ms 的帧预算还慢，出帧上限是仪器锁的
    # —— 今晚实测过，那两批差点被当"交互期 hitch 读数"直接引用（现已移出充数）。
    # 混为一谈就是造假证据：合成输入答不了主观手感，慢节奏连"到不到 120Hz"都答不了。
    rate_ok, tag = input_rate_qualification(meta.get("input_source"))
    if period == "interaction":
        if str(meta.get("no_human_input_during_window") or "") == "1":
            return False, ("声明交互期，但收尾复核记着**整窗没一次人手事件** ⇒ 不可当交互期样本，"
                           "要判 T1 得重录并真的持续滚动")
        if not rate_ok:
            return False, (tag + " ⇒ 这一档不许交 T1：判据里的 p95 帧间隔，"
                           "正好是被输入节奏锁死的那一维")
        return True, tag + "有资格答 T1（交互期 hitch = 0）"
    if str(meta.get("contaminated_by_human_input") or "") == "1":
        return False, ("声明心跳期，但收尾复核记着**窗口内有人动手** ⇒ 样本已污染，"
                       "不得进前后对比表")
    return True, "只答心跳期；**不许**拿去交 T1，要判 T1 用 interact 档重录"


def refusal_headline():
    """被打回那一趟，表头该喊的那一句（**不含拒因**）。

    原先这里一律写「档位声明与收尾复核**互相矛盾**」。那是个**指错方向**的话术：
    `contaminated_by_foreign_load` 那批里，声明与复核完全一致（确实是心跳期、确实没人动），
    被打回是因为**整机在忙**。2026-09-23 20:49 三趟 idle 就是这种形状，而那句"互相矛盾"
    把我带去查一个根本不存在的期间谎报——话术把排查方向带走，和漏印一行一样贵。
    ⇒ 拒因只住在 `period_eligibility` 返回的那一句里（表头上一行刚印它），这一行只说"打回"。
    """
    return ("本趟被收尾复核打回 ⇒ 读数只当过程记录，不得作为结论提交；具体拒因就在上一行")


def freshness_note(drift):
    """`main_product_drift` → 一句人话。**这里不重算**：口径只住在 `provenance_main_drift`
    （只数碰 `Sources`/`Resources` 的提交），本函数只把三种取值分开说清——
    数字 / 未取到 / **旧产物里压根没这枚键**。后两种都只能读成"不知道"，
    不许读成"没落后"（本仓第 1 类静默失效：把"没查"渲染成"没有"）。
    """
    d = str(drift or "").strip()
    if not d.isdigit():
        return ("未取到（旧产物没这枚键，或这里不是 git 仓库）⇒ **不知道**这批落后几笔，"
                "别把不知道读成没落后")
    if int(d) > 0:
        return ("落后 main %s 笔**碰产品码的**提交 ⇒ 这批结论绑 `measured_rev`，"
                "**不绑**当前交付头（口径只数产品码，不是提交总数）" % d)
    return "与 main 同码（按产品码口径；这一格为 0 才谈得上「认证＝交付头」）"
