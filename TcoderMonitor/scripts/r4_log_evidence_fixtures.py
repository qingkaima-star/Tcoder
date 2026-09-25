#!/usr/bin/env python3
"""R4 日志与崩溃证据链的十条验收夹具（检测正确性整改轮 · 台账 RD-21~24）。

**脚本住在这里（受版本控制的 `scripts/`），产物住在那边（`.scratch/r4/fixtures/`）**。
这条分离是踩出来的：上一版脚本落在 `.scratch/r4/` 里，而它开头就是
`rmtree(BASE)` —— 重跑一次把自己也删了，于是修前那棵夹具树只剩磁盘上的一份、
再也造不出来（取证产物不可复现 = 台账 §0 的"可追溯"缺一半）。

用法：
    python3 scripts/r4_log_evidence_fixtures.py            # 造树，打印两个路径
    TCODER_R4_FIXTURE_OUT=<目录> python3 scripts/r4_log_evidence_fixtures.py

然后（归属那一类必须给假的 `~/Library/Logs` 根，真目录是全机所有 App 的报告，禁读）：
    export TCODER_LIBRARY_LOGS_DIR="$(python3 scripts/r4_log_evidence_fixtures.py | tail -1)"
    .build/debug/TcoderMonitor scan  "$TCODER_R4_FIXTURE_DIR" --out=/dev/stdout
    .build/debug/TcoderMonitor score "$TCODER_R4_FIXTURE_DIR" --window-days=7

清残骸：`chmod -R u+rwX .scratch/r4` 之后再删（`locked.log` 是 000 权限）。
"""
import json
import os
import plistlib
import shutil
import subprocess
import sys
from datetime import datetime, timedelta

REPO = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True,
                      check=True).stdout.strip()
BASE = os.environ.get("TCODER_R4_FIXTURE_OUT") or os.path.join(REPO, ".scratch", "r4", "fixtures")
WINDOW_DAYS = 7
NOW = datetime.now().replace(microsecond=0)


def moment(ago_days: float, hh: int = 10, mm: int = 11, ss: int = 12) -> datetime:
    """窗口类判据不能写常量日期，否则随日历翻页失真 —— 全部按"离现在多少天"算。"""
    stamp = NOW - timedelta(days=ago_days)
    return stamp.replace(hour=hh, minute=mm, second=ss)


def apple_time(when: datetime) -> str:
    return when.strftime("%Y-%m-%d %H:%M:%S.00 +0800")


def name_time(when: datetime) -> str:
    return when.strftime("%Y-%m-%d-%H%M%S")


def iso(ago_days: float) -> str:
    return (NOW - timedelta(days=ago_days)).strftime("%Y-%m-%dT%H:%M:%S")


def project_root() -> str:
    return os.path.join(BASE, "R4FixtureApp")


def library_logs_root() -> str:
    return os.path.join(BASE, "fake-library-logs")


def put(rel: str, text: str, mtime=None, mode=None) -> str:
    path = os.path.join(project_root(), rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)
    if mtime is not None:
        os.utime(path, (mtime.timestamp(), mtime.timestamp()))
    if mode is not None:
        os.chmod(path, mode)
    return path


def ips(proc: str, version: str, incident: str, when: datetime,
        exc_type="EXC_BAD_ACCESS", signal="SIGSEGV",
        subtype="KERN_INVALID_ADDRESS at 0x0000000000000010",
        bundle_id="com.example.R4FixtureApp", termination="Segmentation fault: 11") -> str:
    """结构完整的 .ips：首行 header JSON + 其余 body JSON（字段名对齐真实 CrashReporter）。"""
    header = {"app_name": proc, "app_version": version, "bug_type": "309",
              "incident_id": incident, "os_version": "macOS 26.5.1 (25F80)",
              "timestamp": apple_time(when), "version": 2}
    body = {"procName": proc, "bundleID": bundle_id, "app_version": version,
            "incident_id": incident, "timestamp": apple_time(when),
            "os_version": "macOS 26.5.1 (25F80)", "product": "MacBookPro18,3", "bug_type": "309",
            "exception": {"Type": exc_type, "Signal": signal, "Subtype": subtype,
                          "Codes": "0x000000000000000d 0x0000000000000000"},
            "termination": {"reason": termination, "indicator": signal, "flags": "0x80"},
            "crashedThread": 0,
            "threads": [{"id": 1, "triggered": True, "queue": "com.apple.main-thread",
                         "backtrace": {"frames": [
                             {"imageIndex": 0, "symbol": "R4FixtureAppStore.flush()",
                              "symbolLocation": 64,
                              "sourceLineInfo": {"file": "R4FixtureApp/Store.swift", "line": 77}},
                             {"imageIndex": 0, "symbol": "main", "symbolLocation": 52}]}},
                        {"id": 2, "triggered": False, "frames": []}],
            "usedImages": [{"name": "R4FixtureApp", "base": 4399955968, "size": 49152}]}
    return json.dumps(header, ensure_ascii=False) + "\n" + \
        json.dumps(body, ensure_ascii=False, indent=2) + "\n"


def wipe():
    """只清产物目录；脚本自己不在这个目录里，所以删不掉自己（这条是上一版的病灶）。"""
    if os.path.isdir(BASE):
        for dirpath, _, names in os.walk(BASE):
            for name in names:
                try:
                    os.chmod(os.path.join(dirpath, name), 0o644)
                except OSError:
                    pass
        shutil.rmtree(BASE)
    os.makedirs(project_root(), exist_ok=True)
    os.makedirs(os.path.join(library_logs_root(), "DiagnosticReports"), exist_ok=True)


def build():
    wipe()
    # ① 正常日志：窗口内两条 ERROR + 一条 INFO + 一条 WARN，窗口外一条 ERROR
    put("diagnostic.log", "".join([
        f"{iso(1)} ERROR db pool exhausted while serving /orders\n",
        f"{iso(1)} INFO health probe ok\n",
        f"{iso(2)} ERROR java.net.SocketTimeoutException: connect timed out\n",
        f"{iso(2)} WARN retry 1 of 3\n",
        f"{iso(20)} ERROR old failure outside the window\n",
    ]))
    # ② 空文件：读到尽头确实没有行
    put("empty.log", "")
    put("Reports/empty.ips", "")
    # ③ 损坏 IPS（截断）与"只是扩展名像"的 .ips
    report = ips("R4FixtureApp", "2.0 (9)", "B0B0B0B0-1111-2222-3333-444444444444", moment(1, 9, 5, 30))
    put(f"Reports/R4FixtureApp-{name_time(moment(1, 9, 5, 30))}-broken.ips",
        report[: len(report) // 2] + "\n<<<TRUNCATED")
    put(f"Reports/R4FixtureApp-{name_time(moment(1, 9, 6, 0))}-garbage.ips",
        "这里没有任何报告字段\nINFO 一切正常\n")
    # ④ 读不动（权限）
    put("Logs/locked.log", f"{iso(1)} ERROR 读不动的那一份\n", mtime=moment(1), mode=0o000)
    # ⑤ 真实崩溃 + ⑥ 同一事件的多份报告（逐字节副本 + 跨目录改名副本）=> 去重后算 1 次
    current = ips("R4FixtureApp", "2.0 (9)", "A1A1A1A1-1111-2222-3333-444444444444", moment(1))
    put(f"Reports/R4FixtureApp-{name_time(moment(1))}.ips", current, mtime=moment(1))
    put(f"Reports/copies/a/R4FixtureApp-{name_time(moment(1))}.ips", current, mtime=moment(1))
    put("Reports/copies/b/copy-of-same-event.ips", current, mtime=moment(1))
    # ⑦ 新旧混合：20 天前那次是**历史报告**，窗口内不许算它
    put(f"Reports/R4FixtureApp-{name_time(moment(20, 8, 1, 2))}-old.ips",
        ips("R4FixtureApp", "2.0 (9)", "C2C2C2C2-1111-2222-3333-444444444444", moment(20, 8, 1, 2)),
        mtime=moment(20, 8, 1, 5))
    # ⑧ 旧构建报告：窗口内、真崩溃，但版本不是当前 => 不算当前版本缺陷
    put(f"Reports/R4FixtureApp-{name_time(moment(3, 7, 7, 7))}-v1.ips",
        ips("R4FixtureApp", "1.0 (1)", "D3D3D3D3-1111-2222-3333-444444444444", moment(3, 7, 7, 7)),
        mtime=moment(3, 7, 7, 10))
    # ⑨ 无事件时间的确认崩溃：有崩溃类型与崩溃线程，没有 Date/Time 也没有行内时间戳
    put("Logs/undated_crash.log",
        "Incident Identifier: E4E4E4E4-5555-6666-7777-888888888888\n"
        "Exception Type:  EXC_CRASH (SIGABRT)\n"
        "Termination Reason: Namespace SIGNAL, Code 6\n"
        "Thread 3 Crashed:\n"
        "0   R4FixtureApp  0x0000000102040000 R4FixtureAppCache.flush() + 128 (Cache.swift:41)\n")
    # ⑩ 归属混合（配合 TCODER_LIBRARY_LOGS_DIR）：自己的 / 别人的 App / 前缀相近的 Helper
    diag = os.path.join(library_logs_root(), "DiagnosticReports")
    for name, text, mtime in [
        (f"R4FixtureApp-{name_time(moment(2, 6, 30, 0))}.ips",
         ips("R4FixtureApp", "2.0 (9)", "F5F5F5F5-1111-2222-3333-444444444444", moment(2, 6, 30, 0)),
         moment(2, 6, 30, 5)),
        (f"SomeOtherApp-{name_time(moment(1, 23, 0, 0))}.ips",
         ips("SomeOtherApp", "9.9 (9)", "A6A6A6A6-1111-2222-3333-444444444444",
             moment(1, 23, 0, 0), bundle_id="com.example.unrelated"),
         moment(1, 23, 0, 5)),
        (f"R4FixtureAppHelper-{name_time(moment(1, 22, 0, 0))}.ips",
         ips("R4FixtureAppHelper", "3.3 (3)", "B7B7B7B7-1111-2222-3333-444444444444",
             moment(1, 22, 0, 0), bundle_id="com.example.helper"),
         moment(1, 22, 0, 5)),
    ]:
        path = os.path.join(diag, name)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.utime(path, (mtime.timestamp(), mtime.timestamp()))

    # 项目**自己声明**的产品名（归属不靠目录名）+ 一个子目录扫描入口
    put("Package.swift", '// swift-tools-version:6.0\nlet package = Package(name: "R4FixtureApp",'
        ' targets: [.executableTarget(name: "R4FixtureApp")])\n')
    os.makedirs(os.path.join(project_root(), "Resources"), exist_ok=True)
    with open(os.path.join(project_root(), "Resources", "Info.plist"), "wb") as handle:
        plistlib.dump({"CFBundleName": "R4FixtureApp", "CFBundleExecutable": "R4FixtureApp",
                       "CFBundleIdentifier": "com.example.R4FixtureApp",
                       "CFBundleShortVersionString": "2.0", "CFBundleVersion": "9"}, handle)
    put("Sources/App/main.swift", 'print("R4 fixture product")\n')
    # git 锚点：扫根与扫子目录要解出同一个身份
    subprocess.run(["git", "init", "-q"], cwd=project_root(), check=False)
    # 只留一个提交点：`git init` 之后再 commit，扫子目录才能证明"同一份自动输入"不靠历史
    return project_root(), library_logs_root()


EXPECTED = {
    "crashCount": 2,           # 窗口内 + 有事件时间 + 当前构建 + 去重后
    "errorCount": 2,           # 窗口内两条真错误（第三条在窗口外）
    "warningCount": 1,
    "infoLineCount": 1,
    "readFailedFiles": 1,      # 权限不足那一份
    "undatedConfirmed": 1,     # ⑨
    "historicalConfirmed": 1,  # ⑦
    "staleBuildConfirmed": 1,  # ⑧
    "suspected": 2,            # ②的空 .ips + ③的 garbage
    "parseFailed": 1,          # ③的截断 .ips
    "duplicatesMerged": 2,     # ⑥的两份副本
}

if __name__ == "__main__":
    root, lib = build()
    print("夹具树（scan/score 的目标）：" + root)
    print("假的 Library/Logs 根（TCODER_LIBRARY_LOGS_DIR 的值）：" + lib)
    print("独立真值（期望读数，不来自被测实现）：" + json.dumps(EXPECTED, ensure_ascii=False))
