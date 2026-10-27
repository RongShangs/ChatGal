# -*- coding: utf-8 -*-
"""把旧 Fusion 项目里的**内容遗产**一次性导入本仓库（可复现、可审计）。

读：
  <fusion_root>/pages/game/main.lua        （主线 42 幕正文 / 阶段人格 /
                                                                  关键词记忆 / 好感档位 /
                                                                  无尽事件池 / 无尽阶段提示词 / 转场气氛）
  <fusion_root>/pages/{badend7,badend14,csrjend,xtgsend,kwdlend}/main.lua  （五个结局页正文）

写：
  tools/legacy_content.json           —— 上面解析出来的文本（作者脚本读它，不再依赖旧源码路径）

为什么要转成 JSON：作者脚本（rebuild_default_v2_demo.py）必须**自足**才能重建包；
直接读旧源码路径会让重建依赖仓库外的目录。这里转换一次并入库，
以后改文案就改 tools/legacy_content.json。

注：v1 的 `content/default/` 目录已删除（素材早已复制进 default_v2，
文本早已落进 tools/legacy_content.json），所以本脚本只读仓库外的旧源码；
旧源码目录不在时脚本会报错退出 —— 那是预期的（本脚本是一次性导入工具）。

用法：python tools/import_legacy_content.py <fusion_root>
"""
import json
import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description="一次性导入旧 Fusion 内容（正常构建不需要）")
parser.add_argument("fusion_root", type=pathlib.Path, help="旧 Fusion 项目的根目录")
args = parser.parse_args()
FUSION = args.fusion_root.resolve()
LUA = FUSION / "pages" / "game" / "main.lua"
OUT = ROOT / "tools" / "legacy_content.json"
STORIES = ROOT / "content" / "default_v2" / "stories"

ENDING_DIRS = ["badend7", "badend14", "csrjend", "xtgsend", "kwdlend"]

if not LUA.exists():
    print(f"FATAL: 找不到旧项目脚本 {LUA}")
    sys.exit(1)

text = LUA.read_text(encoding="utf-8")

# ------------------------------------------------------------- 主线 42 幕
# DAILY_SCRIPT["dayN_M"] = {c=服装代号, cat=是否猫化, w=天气, loc=地点, ev=剧情正文}
# 这是老项目主线的**真正内容**（14 天 × 白天/傍晚/晚上）。
daily_block = re.search(r"local DAILY_SCRIPT = \{(.*?)\n\}", text, re.S)
daily_script = {}
if daily_block:
    for m in re.finditer(
        r'\["(\w+)"\]\s*=\s*\{\s*c\s*=\s*"(\w)"\s*,\s*cat\s*=\s*(true|false)\s*,\s*'
        r'w\s*=\s*"(\w+)"\s*,\s*loc\s*=\s*"(\w+)"\s*,\s*'
        r'ev\s*=\s*"((?:[^"\\]|\\.)*)"\s*\}',
        daily_block.group(1),
    ):
        daily_script[m.group(1)] = {
            "clothing": m.group(2),
            "cat": m.group(3) == "true",
            "weather": m.group(4),
            "location": m.group(5),
            "text": m.group(6).replace('\\"', '"'),
        }
print(f"  主线幕: {len(daily_script)} 条（预期 42）")
if len(daily_script) != 42:
    print("FATAL: DAILY_SCRIPT 解析异常，主线不能靠残data重建")
    sys.exit(1)

# ------------------------------------------------------- 阶段人格 + 词表
def grab_prompt(name):
    m = re.search(rf'local {name} = "((?:[^"\\]|\\.)*)"', text)
    return m.group(1).replace('\\"', '"') if m else ""


phase_prompts = {
    "phase1": grab_prompt("PHASE1_PROMPT"),
    "phase2": grab_prompt("PHASE2_PROMPT"),
}
print(f"  阶段人格: {[k for k, v in phase_prompts.items() if v]}")

# 关键词记忆：提到才想起来的细节（项链 / 妈妈 / 父亲 / 陈老师）
km_block = re.search(r"local KEYWORD_MEMORY = \{(.*?)\n\}", text, re.S)
keyword_memory = {}
if km_block:
    for m in re.finditer(
        r'\["([^"]+)"\]\s*=\s*"((?:[^"\\]|\\.)*)"', km_block.group(1)
    ):
        keyword_memory[m.group(1)] = m.group(2).replace('\\"', '"')
print(f"  关键词记忆: {len(keyword_memory)} 条")

# 好感档位：0~100 分成 5 档（世界控制台与文案都用得上）
tier_block = re.search(r"local AFFECTION_TIERS = \{(.*?)\n\}", text, re.S)
affection_tiers = []
if tier_block:
    for m in re.finditer(
        r'\{\s*name\s*=\s*"([^"]+)"\s*,\s*min\s*=\s*(\d+)\s*,\s*max\s*=\s*(\d+)\s*\}',
        tier_block.group(1),
    ):
        affection_tiers.append(
            {"name": m.group(1), "min": int(m.group(2)), "max": int(m.group(3))}
        )
print(f"  好感档位: {len(affection_tiers)} 档")

# 地点 / 时段 / 服装代号 → 中文（映射到本包的立绘 state 与背景文件名）
def grab_table(name):
    # 这些表可能写在一行（LOCATIONS / WEATHERS / clothing_names），
    # 所以不能要求 `}` 前面有换行。
    m = re.search(rf"local {name} = \{{(.*?)\}}", text, re.S)
    out = {}
    if m:
        for mm in re.finditer(r'(\w+)\s*=\s*"([^"]+)"', m.group(1)):
            out[mm.group(1)] = mm.group(2)
    return out


locations = grab_table("LOCATIONS")
weathers = grab_table("WEATHERS")
clothing_names = grab_table("clothing_names")
seg_m = re.search(r'local SEGMENT_NAMES = \{(.*?)\}', text)
segment_names = (
    [s.strip().strip('"') for s in seg_m.group(1).split(",") if s.strip()]
    if seg_m
    else []
)
print(f"  地点 {len(locations)} / 天气 {len(weathers)} / 时段 {segment_names}")

# ---------------------------------------------------------- 无尽阶段提示词
block = re.search(r"local ENDLESS_PROMPTS = \{(.*?)\n\}", text, re.S)
endless_prompts = {}
if block:
    for m in re.finditer(r'(\w+)\s*=\s*"((?:[^"\\]|\\.)*)"', block.group(1)):
        endless_prompts[m.group(1)] = m.group(2)
if len(endless_prompts) != 3:
    print(f"FATAL: 无尽阶段提示词解析异常（拿到 {list(endless_prompts)}）")
    sys.exit(1)

# ------------------------------------------------------------- 无尽事件池
pool_block = re.search(r"local ENDLESS_EVENTS = \{(.*?)\n\}", text, re.S)
events = []
if pool_block:
    for m in re.finditer(
        r'\{\s*key\s*=\s*"([^"]+)"\s*,\s*seg\s*=\s*(\d)\s*,\s*'
        r'tags\s*=\s*\{([^}]*)\}\s*,\s*text\s*=\s*"((?:[^"\\]|\\.)*)"\s*\}',
        pool_block.group(1),
    ):
        tags = [t.strip().strip('"') for t in m.group(3).split(",") if t.strip()]
        events.append(
            {
                "key": m.group(1),
                "seg": int(m.group(2)),
                "tags": tags,
                "text": m.group(4).replace('\\"', '"'),
            }
        )
if len(events) < 100:
    print(f"WARN: 事件池只解析出 {len(events)} 条（预期 100+）")
else:
    print(f"  无尽事件池: {len(events)} 条")

# --------------------------------------------------------- 转场气氛文案
atm_block = re.search(r"local SCENE_ATMOSPHERE = \{(.*?)\n\}\n", text, re.S)
atmosphere = {}
if atm_block:
    for loc_m in re.finditer(r"(\w+)\s*=\s*\{(.*?)\n  \}", atm_block.group(1), re.S):
        loc, body = loc_m.group(1), loc_m.group(2)
        for m in re.finditer(r"\[(\d)\]\s*=\s*\"([^\"]*)\"", body):
            atmosphere[f"{loc}:{m.group(1)}"] = m.group(2)
        rain = re.search(r'rain\s*=\s*"([^"]*)"', body)
        if rain:
            atmosphere[f"{loc}:rain"] = rain.group(1)
print(f"  转场气氛: {len(atmosphere)} 条")

# ------------------------------------------------------------- 结局页正文
ending_text = {}
for d in ENDING_DIRS:
    p = FUSION / "pages" / d / "main.lua"
    if not p.exists():
        print(f"WARN: 缺 {p}")
        continue
    raw = p.read_text(encoding="utf-8")
    m = re.search(r"local ending_summary = \[\[(.*?)\]\]", raw, re.S)
    if not m:
        print(f"WARN: {d} 里找不到 ending_summary")
        continue
    paras = [b.strip() for b in m.group(1).strip().split("\n\n") if b.strip()]
    ending_text[d] = paras
print(f"  结局页正文: {sorted(ending_text)}")

payload = {
    "_comment": "由 tools/import_legacy_content.py 从旧 Fusion 项目导入；改文案改这里。",
    "endless_prompts": endless_prompts,
    "endless_events": events,
    "atmosphere": atmosphere,
    "ending_text": ending_text,
    "daily_script": daily_script,
    "phase_prompts": phase_prompts,
    "keyword_memory": keyword_memory,
    "affection_tiers": affection_tiers,
    "locations": locations,
    "weathers": weathers,
    "clothing_names": clothing_names,
    "segment_names": segment_names,
}
OUT.write_text(
    json.dumps(payload, ensure_ascii=False, indent=1) + "\n", encoding="utf-8"
)
print(f"  写出 {OUT.relative_to(ROOT)}（{OUT.stat().st_size // 1024} KB）")
