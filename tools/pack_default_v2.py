# -*- coding: utf-8 -*-
"""打包 content/default_v2 -> apps/chatgal/assets/hellojj_default.chatgal。

顶层即包根（无外层目录）。v2 扁平布局没有 assets/ 目录，PNG 由加载器自动索引。
内容文件的 JSON **允许写 `//` 注释**（作者要在文件里说明字段含义），所以这里读
manifest 前先剥注释 —— 与 Dart 侧 `stripJsonComments` 同一套规则。

结构体检查**只有一份实现**：本脚本调 packages/gal_protocol/tool/validate_pack.dart
（与游戏内安装第三方包用的是同一个 PackageValidator）。这里只额外守三件 python
侧才知道的事：

1. manifest.version 必须与 AppServices.defaultPackageVersion 一致 —— 两者不同步
   会让「安装新版 → 清理旧版」把刚装上的包删掉（历史上踩过）。
2. **version 只能是数字，而且只能往高版本升**（与 git HEAD 里那份比）。
3. 没有 assets/ 目录。
4. tools/rebuild_default_v2_demo.py 的 VERSION 也要相等 —— 那个脚本生成 manifest 时
   会**无条件**写入自己那份版本号，是同一个数字的第四份副本。

任一不过直接 FATAL 退出，不产出坏包。
"""
import json
import re
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
src = ROOT / "content" / "default_v2"
out = ROOT / "apps" / "chatgal" / "assets" / "hellojj_default.chatgal"
APP_SERVICES = ROOT / "apps" / "chatgal" / "lib" / "app" / "app_services.dart"
VALIDATOR = ROOT / "packages" / "gal_protocol" / "tool" / "validate_pack.dart"
REBUILD = ROOT / "tools" / "rebuild_default_v2_demo.py"

DART = Path(shutil.which("dart") or "dart")


def strip_comments(text: str) -> str:
    """剥掉 // 与 /* */ 注释、以及尾逗号（字符串里的 // 不动）。"""
    out = []
    i, n = 0, len(text)
    in_str = False
    escaped = False
    while i < n:
        ch = text[i]
        if in_str:
            out.append(ch)
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_str = False
            i += 1
            continue
        if ch == '"':
            in_str = True
            out.append(ch)
            i += 1
            continue
        if ch == "/" and i + 1 < n:
            nxt = text[i + 1]
            if nxt == "/":
                i += 2
                while i < n and text[i] != "\n":
                    i += 1
                continue
            if nxt == "*":
                i += 2
                while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
                    i += 1
                i = i + 2 if i + 2 <= n else n
                continue
        out.append(ch)
        i += 1
    joined = "".join(out)
    return re.sub(r",(\s*[}\]])", r"\1", joined)


def read_jsonc(path: Path):
    return json.loads(strip_comments(path.read_text(encoding="utf-8")))


manifest = read_jsonc(src / "manifest.json")
version = str(manifest["version"])
match = re.search(
    r"defaultPackageVersion\s*=\s*'([^']+)'",
    APP_SERVICES.read_text(encoding="utf-8"),
)
if match is None:
    print("FATAL: defaultPackageVersion not found in app_services.dart")
    sys.exit(1)
if match.group(1) != version:
    print(
        "FATAL: version mismatch — the installed pack would be uninstalled as stale\n"
        f"  app_services.defaultPackageVersion = {match.group(1)}\n"
        f"  content/default_v2/manifest.version  = {version}"
    )
    sys.exit(1)

if not version.isdigit():
    print(f"FATAL: manifest.version 只能是数字（现在是 {version!r}）")
    sys.exit(1)

# 版本号其实有第四份副本：重建脚本的 VERSION 会在生成 manifest 时**无条件**写进去。
# 内容更新时忘了同步它，跑一次重建就把 manifest 的版本静默写回旧值
# （下一轮打包会以 version mismatch 拦住，但 manifest 已经坏了，且看不出是谁干的）。
rebuild_match = re.search(
    r'^VERSION\s*=\s*"([^"]+)"',
    REBUILD.read_text(encoding="utf-8"),
    re.MULTILINE,
)
if rebuild_match is None:
    print(f"FATAL: 在 {REBUILD} 里找不到 VERSION = \"…\"")
    sys.exit(1)
if rebuild_match.group(1) != version:
    print(
        "FATAL: 重建脚本的 VERSION 与 manifest 不一致 —— 跑一次重建就会把版本写回旧值\n"
        f"  tools/rebuild_default_v2_demo.py VERSION = {rebuild_match.group(1)}\n"
        f"  content/default_v2/manifest.version      = {version}"
    )
    sys.exit(1)

# 只能往高版本升：与 git HEAD 里那一份比（没有可比对象/旧版不是数字时只提示）。
try:
    prev = subprocess.run(
        ["git", "show", "HEAD:content/default_v2/manifest.json"],
        cwd=str(ROOT),
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    if prev.returncode == 0 and prev.stdout.strip():
        prev_version = str(json.loads(strip_comments(prev.stdout)).get("version", ""))
        if prev_version.isdigit():
            if int(version) < int(prev_version):
                print(
                    "FATAL: version 只能往高版本升（现在是降级）\n"
                    f"  HEAD  = {prev_version}\n"
                    f"  现在  = {version}"
                )
                sys.exit(1)
            if int(version) == int(prev_version):
                # 版本没变是允许的（幂等重打），但要提醒：内容真改过就得加 1，
                # 否则已装用户不会收到更新（清单里的版本号没变）。
                print(
                    f"version {version}（与 HEAD 相同 — 只是重打；"
                    "如果这轮改了内容，请把版本号 +1）"
                )
            else:
                print(f"version {prev_version} -> {version} (↑)")
        else:
            print(f"version {version}（HEAD 那份是 {prev_version!r}，不是数字，跳过比较）")
except Exception as exc:  # git 不在/不是仓库：不影响打包
    print(f"version {version}（拿不到 git HEAD 的版本，跳过比较：{exc}）")

if (src / "assets").exists():
    print(
        "FATAL: content/default_v2/assets/ exists — v2 layout has no assets "
        "folder (PNGs are auto-indexed)"
    )
    sys.exit(1)

print("→ 结构体检（PackageValidator）…")
res = subprocess.run(
    [str(DART), "run", str(VALIDATOR), str(src)],
    cwd=str(ROOT / "packages" / "gal_protocol"),
    capture_output=True,
    text=True,
    encoding="utf-8",
)
sys.stdout.write(res.stdout)
sys.stderr.write(res.stderr)
if res.returncode != 0:
    print("FATAL: 结构体检不过，未打包")
    sys.exit(1)

with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
    for p in sorted(src.rglob("*")):
        if not p.is_file() or p.name.startswith("."):
            continue
        rel = p.relative_to(src).as_posix()
        # 固定时间戳：否则 writestr 会写入「当前时间」，同样输入每次打出来的
        # .chatgal 字节都不同 —— 入库的那个文件会每轮都产生无意义的改动，
        # 也没法复现构建。
        info = zipfile.ZipInfo(rel, date_time=(1980, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o644 << 16
        z.writestr(info, p.read_bytes())

names = zipfile.ZipFile(out).namelist()
print("version", version, "(matches app_services)")
print("entries", len(names))
print("top", sorted({n.split("/")[0] for n in names}))
print("wrote", out.relative_to(ROOT))

# --- 内置教学包：content/daily_v2 -> assets/hellojj_daily.chatgal ---
daily_src = ROOT / "content" / "daily_v2"
daily_out = ROOT / "apps" / "chatgal" / "assets" / "hellojj_daily.chatgal"
if daily_src.is_dir():
    daily_manifest = read_jsonc(daily_src / "manifest.json")
    daily_version = str(daily_manifest["version"])
    app_text = APP_SERVICES.read_text(encoding="utf-8")
    m2 = re.search(r"dailyPackageVersion\s*=\s*'([^']+)'", app_text)
    if m2 is None:
        print("FATAL: dailyPackageVersion not found in app_services.dart")
        sys.exit(1)
    if m2.group(1) != daily_version:
        print(
            "FATAL: daily version mismatch\n"
            f"  app_services.dailyPackageVersion = {m2.group(1)}\n"
            f"  content/daily_v2/manifest.version = {daily_version}"
        )
        sys.exit(1)
    if not daily_version.isdigit():
        print(f"FATAL: daily manifest.version must be digits ({daily_version!r})")
        sys.exit(1)
    print("→ daily_v2 结构体检…")
    res2 = subprocess.run(
        [str(DART), "run", str(VALIDATOR), str(daily_src)],
        cwd=str(ROOT / "packages" / "gal_protocol"),
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    sys.stdout.write(res2.stdout)
    sys.stderr.write(res2.stderr)
    if res2.returncode != 0:
        print("FATAL: daily_v2 结构体检不过")
        sys.exit(1)
    with zipfile.ZipFile(daily_out, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for p in sorted(daily_src.rglob("*")):
            if not p.is_file() or p.name.startswith("."):
                continue
            rel = p.relative_to(daily_src).as_posix()
            info = zipfile.ZipInfo(rel, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            z.writestr(info, p.read_bytes())
    dnames = zipfile.ZipFile(daily_out).namelist()
    print("daily version", daily_version)
    print("daily entries", len(dnames))
    print("wrote", daily_out.relative_to(ROOT))
else:
    print("skip daily_v2 (目录不存在)")
