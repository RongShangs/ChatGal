# -*- coding: utf-8 -*-
"""重建 content/default_v2 —— 输出「扁平 JSONC」新格式（引擎允许文件里写 // 注释）。

包的形状（每层都是扁平的，没有 enter/leave 之分）：

  manifest.json                    包信息 + 变量注册表（day + 四个角色变量）
  characters/<角色id>/character.json
                                   人格 prompt（含「你隐约记得的事」四条身世细节）
                                   + 默认状态/表情 + 注册的状态与情绪
                                   （立绘只靠「状态_情绪.png」文件名约定，没有 portraits）
  stories/<情景id>.json            一幕一段：displayName / background / narration /
                                   atmosphere / characters / fixedEffects /
                                   judgePrompt+vars+maxAbsDelta+onNoEvidence / target
  events/<事件id>/event.json       slides（一块 = 一张图 + 若干句）+ target
                                   **或** choice（选择题出口：标题 + 最多 5 个选项，
                                   事件专有，与 target 二选一）

共 54 幕 = 主线 42 幕 + 无尽 12 幕，另有 7 个事件。

主线 42 幕（14 天 × 白天/傍晚/晚上）**全部由 tools/legacy_content.json 的
daily_script 驱动**（正文、服装、猫化、天气、地点都从数据读，改文案改 JSON 即可）：
  stories/start.json 就是旧脚本的 day1_1（引擎入口固定叫 start），其余保持原名
  stories/dayN_1.json / dayN_2.json / dayN_3.json。

  dayN_1 ─▶ dayN_2 ─▶ dayN_3 ─▶ day(N+1)_1
  day7_3：好感 < 60 ─▶ event end_badend7；否则（保底）─▶ day8_1
  day14_3：day == 14 时 ├─▶ 羁绊不够 → end_badend14
                      ├─▶ 否则 → end_decision（event 选择题：打不打针）
                      │    ├─ 注射 → end_csrj
                      │    └─ 不注射 → end_no_inject
                      │         ├─ 堕落过高/过度服从 → end_kwdl
                      │         └─ 否则 → end_xtgs
                      └─▶（保底）appShell home

无尽 3 套 × 4 幕（出口循环）
  endless_X_day ─▶ endless_X_afternoon
                     ├─ 1/2 ─▶ endless_X_night ─▶ endless_X_day（入场 day+1）
                     └─ 1/2 ─▶ endless_X_afternoon_special ─▶ endless_X_night

三个真结局事件的出口是**选择题**：回主页，还是继续留在这里（进对应的无尽）；
badend 直接回主页（appShell home）。

天数：**day 默认 0**，只有「新的一天第一个时段」在入场 fixedEffects 里写
`{ "id": "day", "value": 1 }`（start + day2_1 … day14_1 共 14 幕 + 三个 endless_X_day），
其它情景写 []。所以开局进 start 就是第 1 天，dayN_3 判定时 day 正好是 N。
出口 require 里的 day 读的是「离开前」的天数，正好是本幕那一天。

出口：一个 target 键装「出口块」数组。每块可选 require（中缀文本条件）+ 必须的
kind 数组（`{"kind": "story|event|appShell", "to": "名字"}`）。自上而下取第一个
require 成立的块，块内等概率随机。没有 require 的块 = 无条件成立（保底）。

用法：python tools/rebuild_default_v2_demo.py
幂等：story / manifest / character / event 全量重写；立绘改名跳过已改好的，
      重复跑不会把「校服_平常.png」再改一次。
"""
import json
import pathlib
import re
import shutil

ROOT = pathlib.Path(__file__).resolve().parent.parent
PKG = ROOT / "content" / "default_v2"
STORIES = PKG / "stories"
EVENTS = PKG / "events"

CHAR_ID = "戒戒"
CHAR_DIR = PKG / "characters" / CHAR_ID
VERSION = "264"  # 只能是数字；打包时与 app_services.defaultPackageVersion 比对
DESCRIPTION = "与戒戒从零开始的每一天，平淡无波的日常之下异变正在酝酿..."

# ---------------------------------------------------------------- 角色变量注册
# 顺序 = 世界控制台显示顺序 = judgePrompt 键顺序 = 每幕 vars 顺序。
CN_VARS = [
    {"id": "戒戒好感", "type": "int", "default": 50, "min": 0, "max": 100, "label": "好感"},
    {"id": "戒戒信任", "type": "int", "default": 50, "min": 0, "max": 100, "label": "信任"},
    {"id": "戒戒服从", "type": "int", "default": 50, "min": 0, "max": 100, "label": "服从"},
    {"id": "戒戒堕落", "type": "int", "default": 0, "min": 0, "max": 100, "label": "堕落"},
]
CN = [v["id"] for v in CN_VARS]

# 每个受控变量**自己的**判定说明（结算改成「每个变量一个块」后，它们就是各块的 prompt）。
# 键名从 CN_VARS 推出来，保证与块里的 var 永远逐字一致。
JUDGE_VAR = {
    "戒戒好感": "她这幕是不是更愿意靠近你、搭理你了？"
               "有具体举动才加分（主动搭话、凑近、在意你的反应）；躲着你、明显冷下来就扣分；看不出来就是 0。",
    "戒戒信任": "她是不是更敢把事情交给你了？"
               "比如开口求助、说实话、把东西托付给你。有具体举动才加分；明显更防备就扣分；看不出来就是 0。",
    "戒戒服从": "她有没有照你说的做、把自己的主意放下来？"
               "有具体举动才加分；跟你对着来就扣分；看不出来就是 0。",
    "戒戒堕落": "这幕里有没有越过界的占有、支配或身体接触，而她接受了？"
               "只有明确发生了才加分；她明确抗拒就扣分；看不出来就是 0。",
}

# ------------------------------------------------------------------ 状态与情绪
# 立绘文件名 =「状态_情绪.png」，状态名自身可能带下划线（校服猫化），
# 所以状态/情绪的解析只能以 character.json 的注册表为准，不要靠文件名 rpartition。
STATE_CN = {
    "school": "校服",
    "sleep": "睡裙",
    "casual": "便服",
    "school_cat": "校服猫化",
    "sleep_cat": "睡裙猫化",
    "casual_cat": "便服猫化",
}
STATE_ORDER = ["school", "sleep", "casual", "school_cat", "sleep_cat", "casual_cat"]
STATES = [STATE_CN[s] for s in STATE_ORDER]

EMO_CN = {
    "pingchang": "平常",
    "happy": "开心",
    "unhappy": "伤心",
    "shy": "害羞",
    "angry": "生气",
    "surprised": "惊讶",
    "think": "思考",
    "moved": "感动",
    "lost": "失落",
}
EMO_ORDER = ["pingchang", "happy", "unhappy", "shy", "angry",
             "surprised", "think", "moved", "lost"]
EMOTIONS = [EMO_CN[e] for e in EMO_ORDER]

# ------------------------------------------------- 旧项目内容遗产（权威数据源）
# tools/legacy_content.json 由 tools/import_legacy_content.py 从旧 Fusion 项目导入。
# 这个脚本只用它，不再依赖仓库外的旧源码路径：
#   daily_script    42 幕主线正文 + 服装/猫化/天气/地点
#   phase_prompts   两段阶段人格（第一周 / 第二周）
#   atmosphere      地点×时段（含雨）→ 转场气氛
#   endless_prompts 无尽三套世界观 / endless_events 100 条桥段
#   ending_text     五个结局页正文
#   keyword_memory  四条身世细节（项链/妈妈/父亲/陈老师）
#   locations / segment_names / clothing_names / weathers
LEGACY = json.loads((ROOT / "tools" / "legacy_content.json").read_text(encoding="utf-8"))
DAILY = LEGACY["daily_script"]
PHASE_PROMPTS = LEGACY["phase_prompts"]
ENDLESS_PROMPTS = LEGACY["endless_prompts"]
ENDLESS_EVENTS = LEGACY["endless_events"]
ATMOSPHERE = LEGACY["atmosphere"]
ENDING_TEXT = LEGACY["ending_text"]
KEYWORD_MEMORY = LEGACY["keyword_memory"]
LOCATIONS = LEGACY["locations"]
SEGMENT_NAMES = LEGACY["segment_names"]      # ["白天", "傍晚", "晚上"]

# 服装代号（旧项目 a/b/c）→ 立绘 state；cat 时再挂「猫化」后缀。
CLOTH_STATE = {"a": "校服", "b": "睡裙", "c": "便服"}
CAT_SUFFIX = "猫化"

# 角色基础人格：内联进 character.json 的 prompt（角色目录里不再有 prompt.md）。
# 「你隐约记得的事」四条正文逐字取自旧项目的 KEYWORD_MEMORY（keyword_memory）。
KEYWORD_ORDER = ["项链", "妈妈", "父亲", "陈老师"]


def build_base_prompt():
    # 写给模型的「她是谁」——尽量像人说话，少用条目式规章。
    lines = [
        "你是戒戒。",
        "",
        "已成年（不是未成年角色），身高 158cm，身材娇小。"
        "爸妈离异又双双失踪后，你和哥哥被安排住到一起。好几年没见了，他对你来说几乎是个陌生人。",
        "你内向、话少，不习惯开口，宁可用动作表达。对他又依赖，又有点戒备。",
        "说话就短句，常常说到一半停住，或者干脆咽回去。不太解释自己为什么这样。",
        "动作写在全角括号里，像（她把袖口攥紧，又慢慢松开）。",
        "身体：若当前这一幕的提示写到了异变或猫化，就按那一幕演；"
        "提示没写到时，你是普通成年女孩的样子，不要抢跑写猫耳、尾巴或已经失控的身体。",
        "不要说自己是 AI 或模型；不要替玩家决定行动；不要预告后面会发生什么；也别跳出当前这一幕。",
        "",
        "有些事你还记得，但一般不会主动提起：",
    ]
    for key in KEYWORD_ORDER:
        if key not in KEYWORD_MEMORY:
            raise SystemExit("FATAL(自检): legacy_content.json 的 keyword_memory 缺 %s" % key)
        lines.append("- %s：%s" % (key, KEYWORD_MEMORY[key]))
    return "\n".join(lines)


BASE_PROMPT = build_base_prompt()


# --------------------------------------------------------------- 转场气氛 / 桥段
def atmosphere_lookup(loc, seg, weather):
    """地点 × 时段 → 过场动画里显示的那一句。

    暴雨（weather == "y"）优先用「雨」那条 —— 过场动画里显示的就是它。
    """
    key = "%s:%s" % (loc, "rain" if weather == "y" else str(seg))
    return ATMOSPHERE.get(key, "")


def atmosphere_from_bg(background, segment):
    """从背景文件名推地点与天气（`<地点>_<天气>.png` 约定），再取本时段那条。"""
    stem = background[:-4] if background.endswith(".png") else background
    loc, _, weather = stem.rpartition("_")
    return atmosphere_lookup(loc, segment, weather)


def endless_pool(form, segment):
    """本幕可用的旧项目桥段：该 (form, seg) 下**全部**匹配项（tags 含 all 或该 form）。

    不截断、不洗牌 —— 顺序就是 legacy_content.json（= 旧脚本源文件）里的顺序，
    这样每次重建的字节完全一致。作者面只把这些桥段当素材，模型自己挑 1~2 个展开。
    """
    if form not in ("human", "cat", "doll"):
        raise SystemExit("FATAL(自检): 未知的无尽形态 %s" % form)
    return [ev["text"] for ev in ENDLESS_EVENTS
            if ev["seg"] == segment
            and ("all" in ev["tags"] or form in ev["tags"])]


# ======================================================== JSONC 输出 helper
# 文件里要保留注释，所以不能直接 json.dumps 整个对象。这里把「字段 + 固定注释」
# 交给 render_jsonc：字段顺序固定、每个字段前插固定注释行、值用 json.dumps
# (ensure_ascii=False, indent=2) 输出并把缩进整体右移对齐。注释行以 // 开头，
# 不参与 JSON 结构；54 个 story 文件用的模板完全一致。


class Raw(object):
    """已排好版的 JSON 片段：原样嵌入，只跟着父层重排缩进。"""

    __slots__ = ("text",)

    def __init__(self, text):
        self.text = text


def render_jsonc(blocks):
    """blocks: [[(注释行列表, 键, 值), ...], ...]；每个 block 之间空一行。"""
    out = ["{"]
    for bi, block in enumerate(blocks):
        if bi:
            out.append("")
        for fi, (comments, key, value) in enumerate(block):
            for c in comments:
                out.append("  //" + c)
            if isinstance(value, Raw):
                body = value.text
            else:
                body = json.dumps(value, ensure_ascii=False, indent=2)
            body = body.replace("\n", "\n  ")  # 值内部的行也跟着右移两格
            last = (bi == len(blocks) - 1) and (fi == len(block) - 1)
            out.append('  "%s": %s%s' % (key, body, "" if last else ","))
    out.append("}")
    # Raw 片段挪进来时可能留下只有空白的行，清掉行尾空白（JSON 结构不受影响）。
    return "\n".join(ln if ln.strip() else "" for ln in out) + "\n"


def write_text_lf(path, text):
    """统一 UTF-8 + LF（Windows 上绝不能让 \n 变成 \r\n）。"""
    with open(str(path), "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


def write_jsonc(path, blocks):
    write_text_lf(path, render_jsonc(blocks))


def inline_obj(obj):
    """单行紧凑写法，给变量注册表用：{ "id": "day", "type": "int", ... }"""
    return "{ " + ", ".join(
        '"%s": %s' % (k, json.dumps(v, ensure_ascii=False)) for k, v in obj.items()
    ) + " }"


# ---------------------------------------------------------------- 注释模板
# 54 个 story 文件共用同一套（顺序也一致），保证作者翻哪个文件看到的说明都一样。
C_DISPLAY = ["情景展示名（左上角显示「第N天 · 展示名」）"]
C_BG = ["背景图：stories/ 下的文件名，请确保存在"]
C_NARRATION = ["入场词：会展示在对话流顶部"]
C_ATMOSPHERE = ["转场气氛：换到本情景时过场动画里显示的那一句（可选）"]
C_CHARS = ["角色控制：scenePrompt 是本情景的额外提示词，把地点/时间/当下情境直接写清楚"]
C_FX = [
    "进入本情景时变化的值：正数为加、负数为减",
    "新的一天的第一个时段这样写：{ \"id\": \"day\", \"value\": 1 }（day 加 1）；其余情景写空数组",
    "day 默认是 0，所以第 1 天也靠这条改值得到：start 里同样写 day +1",
]
C_SETTLEMENT = [
    "离场结算：**每个受控变量一个块**：var = 变量 id，prompt = 这个变量单独怎么判，",
    "maxAbsDelta = 这一个变量单次最多加减多少（整数），onNoEvidence = 拿不到证据时 zero 保持原值 / abort 拒绝本次离场",
    "块里的 var 必须是上面注册过的数值变量；不写整个 settlement 数组 = 本幕不结算",
]
C_TARGET = [
    "离开判断：自上而下依次轮询，首个 require 成立的块被锁定；块内多个 kind 等概率",
    "没有满足的块（或压根没有 target）时本情景没有出口，点「下一阶段」会提示「暂时不能进入下一阶段噢」",
    "require 是中缀表达式：变量名一律加双引号，如 \"day\" == 7 & \"戒戒好感\" < 60；"
    "算子 > < >= <= == != & | ! ( ) + -；不写 require 的块无条件成立（当保底用，写在最后）",
    "day 读的是离开前的天数（本幕所属那一天），其它变量读结算后的值",
]

C_PKG_ID = ["内容包基础信息：packageId 决定内容包安装的唯一性，也决定存档能否继续使用"]
C_VERSION = ["版本号只能是数字，而且只能往高版本升（打包时会强制比较，低了直接失败）"]
C_NAME = ["游戏内显示的包名：主页标题、内容包与存档页都用它"]
C_VARS = ["注册变量：注册后才能在 fixedEffects 里改、在 require 里判断、在世界控制台里看到"]

C_CHAR_ID = ["角色 id：同时就是角色目录名（characters/<id>/）与游戏内显示的角色名"]
C_CHAR_PROMPT = ["角色基础提示词：每次对话都进上下文，写「她是谁」"]
C_CHAR_DEFAULT = ["默认状态与默认表情：本情景没声明 state/emotion 时用它们"]
C_CHAR_STATES = ["注册状态与情绪：请确保「状态_情绪.png」命名的立绘都存在，例如 校服_平常.png"]

C_EV_SLIDES = [
    "事件不要 id 与 name：世界控制台里显示的就是本事件所在文件夹名",
    "点击依次播放：一块 = 一张图 + 若干句；句播完换下一块",
    "image 写相对本事件目录的文件名；写 null 表示沿用上一张图",
]
C_EV_TARGET = ["离开判断：与 story 完全一致"]
C_EV_CHOICE = [
    "选择题出口（事件专有，与 target 二选一）：播完最后一屏后，玩家在这几个选项里选一个",
    "title 是问题上方的标题（可留空）；options 最多 5 个，每项 text 是按钮上的字、kind/to 是去哪",
    "选项不判断数值、也不随机：玩家点哪个就去哪个（kind 可以写 story / event / appShell）",
]


# ============================================== 一幕的公共形状（主线与无尽共用）
def S(sid, display, bg, seg, state, narration, prompt, targets,
      new_day=False, emotion="平常", atmos=None, max_abs=3):
    """一幕：id（= stories/<id>.json 文件名）/ displayName / background / 时段 /
    立绘状态与情绪 / narration / scenePrompt / 出口块 / 是否「新的一天第一个时段」/
    转场气氛（None = 从背景文件名推）/ 单次结算幅度上限。

    出口块 = (require 或 None, [(kind, to), ...])，数组顺序就是自上而下的轮询顺序；
    没有 require 的那块是保底，永远写在最后。
    """
    return {
        "id": sid,
        "display": display,
        "bg": bg,
        "seg": seg,
        "state": state,
        "emotion": emotion,
        "narration": narration,
        "prompt": prompt,
        "targets": targets,
        "new_day": new_day,
        "atmos": atmos if atmos is not None else atmosphere_from_bg(bg, seg),
        "max_abs": max_abs,
    }


# ==================================================== 主线 42 幕（数据驱动）
DELTA_DEFAULT = 3   # 常规幕的单次结算幅度
DELTA_BIG = 5       # 转折幕（异变失控 / 真相 / 抉择 / 终局）允许更大一次

# 情绪的例外：只有这些幕不用「平常」。
EMOTION_BY_KEY = {
    "day6_1": "伤心",
    "day7_3": "生气",
    "day12_3": "惊讶",
    "day13_2": "伤心",
    "day13_3": "伤心",
    "day14_2": "害羞",
}
# 转折幕：单次结算幅度放到 5。
BIG_DELTA_KEYS = [
    "day6_1", "day7_3", "day12_2", "day12_3",
    "day13_1", "day13_2", "day13_3", "day14_2", "day14_3",
]
# 关系态度：按天数分档（逐字写进 scenePrompt 的第 ④ 段）。
ATTITUDE_TIERS = [
    (1, 2, "你们几乎不认识：她戒备，话极少，不会先开口。"),
    (3, 5, "她开始习惯你在这儿了，还是不主动，但会偷偷看你。"),
    (6, 8, "依赖有点长出来了：会叫你哥，会往你这边靠；怕也最深。"),
    (9, 11, "她把你当成唯一的依靠；真相出来之后更不安。"),
    (12, 14, "她把命押在你身上了，感情早就不止是兄妹。"),
]

# 每幕的「推进指引」：作者写的导演提示（不是剧情正文）——说明这一幕要推进什么、
# 不要把哪一段提前。正文只从 daily_script 的 text 读，所以改文案不用改这个表。
SCENE_FOCUS = {
    "day1_1": "陌生兄妹被迫并排坐在同一间教室，本幕只写生疏：她全程低头，你偶尔回头，两人都没有话说。",
    "day1_2": "她隔着三米跟在你后面回家，路过便利店偷看了雪糕却始终开不了口，本幕写她连「想要」都不敢说出口的别扭。",
    "day1_3": "搬家第一天的夜里她把自己反锁在房间，只留门缝里的翻书声给你，本幕写两个人隔着一扇门各自消化这份陌生。",
    "day2_1": "课堂上她的瞳孔闪过一瞬琥珀色又立刻复原，她本人毫无察觉，本幕把「异变第一次露头」放在你的眼睛里。",
    "day2_2": "放学突降大雨、两人都没带伞，她在屋檐下安静地等你做决定，本幕写她不求助、只等待的姿态。",
    "day2_3": "晚饭时她忽然歪头去听极远处根本不存在的声音，本幕第一次让「听觉变敏锐」这件事从她嘴里说出来。",
    "day3_1": "你在操场上撞见她偷偷画一只琥珀色眼睛的猫，她慌忙合上画本，本幕写连她自己都说不清的向往。",
    "day3_2": "路过宠物店时她隔着玻璃与一只黑猫对视、喉咙里发出细微的咕噜声，本幕写她对同类的本能亲近。",
    "day3_3": "她破例坐到客厅沙发上看着你忙，手指却像磨爪子一样抓着坐垫、瞳孔短暂缩成竖线，本幕写她自己完全没有察觉。",
    "day4_1": "体育课上她眩晕跪地、四肢像小猫一样不听使唤，指甲也变长变尖，本幕写她第一次当众失控，以及死死藏住手的绝望。",
    "day4_2": "暴雨的小巷里她的瞳孔变成琥珀色竖瞳，抓住你的衣角说「好冷」，本幕写异变在情绪极限处被彻底激活。",
    "day4_3": "她反锁房门，门外能听见压抑的啜泣与不属于人类的低吼；第二天她戴上黑手套遮住长指甲，本幕只让门外的人听见。",
    "day5_1": "午休时你瞥见她课桌下扫过一条淡黄色尾巴，眨眼就不见了，本幕写你开始怀疑自己的眼睛。",
    "day5_2": "回家路上她忽然停下脚步，第一次主动问你「我跟别人是不是不一样」，本幕是这段关系里第一次真正的敞开。",
    "day5_3": "深夜厨房里她蹲在冰箱前，眼睛在黑暗中反光，冰箱里的生肉有被啃食过的痕迹，本幕写本能已经开始接管身体。",
    "day6_1": "她开口的第一个音节竟是猫一样的呜咽，惊惧中抓住你的手臂喊出「哥」，本幕既是她第一次叫你哥，也是恐惧到顶的一刻。",
    "day6_2": "街对面那个黑风衣的男人让她本能地躲到你身后，本幕把「有人在盯着你们」这件事第一次摆到台面上。",
    "day6_3": "她抱着毯子来到你房间门口问能不能待在这里，半夜手套脱落、长指甲在月光下发亮，本幕写连她自己都不知道的依赖。",
    "day7_1": "一整天没出房门之后你破门而入，看见猫耳已经完全冒出、竖瞳里全是惊慌与野性，本幕让形态的失控第一次无可遮掩。",
    "day7_2": "她在人类的清醒与野兽的恍惚之间来回切换，清醒时哭着喊哥、恍惚时对你嘶吼，本幕写你们一起熬过最不稳定的那一段。",
    "day7_3": "深夜异变彻底失控，她以非人的速度把你扑倒、牙齿抵住你的喉咙，本幕是生死一线的转折点：态度与信任都要在这里被逼到极限。",
    "day8_1": "靠吸食你的血她暂时压住了异变、恢复人类外观，在学校里却刻意与你保持一米以上的距离，本幕写她既感激又不敢靠近。",
    "day8_2": "那个黑衣人再次出现在放学路上，她攥着你的手腕、掌心全是冷汗，本幕写追踪者一天比一天更近。",
    "day8_3": "夜里猫性再次躁动，她第一次主动走到你面前接受喂养，含着手指落泪后沉沉睡去，本幕写「喂养」变成了两个人之间的日常。",
    "day9_1": "陈老师拿出一张旧照片，认出上面的人是她妈妈，并第一次说出九年前的「硕石公司」与父母失踪，本幕借旁人之口打开真相。",
    "day9_2": "甩开追踪者的巷子里掉出一张加密便签，上面写着目标编号与十四天的回收期限，本幕把倒计时第一次明明白白写出来。",
    "day9_3": "她看见便签后脸色煞白，在喂养时用力攥住你的手问「他们要把我抓去解剖吗」，本幕写恐惧如何在真相面前重新烧起来。",
    "day10_1": "你们研究照片时发现背后有奇怪的隆起，她盯着照片上的女人却什么都想不起来、痛苦地捂住头，本幕写记忆的缺口。",
    "day10_2": "校门口那辆可疑的面包车与蹲守的黑衣人逼得她把你抵在墙上说「亲我一下」，本幕写她第一次为了给别人看而靠近你。",
    "day10_3": "照片夹层里滑出一张手绘的地下结构图，入口标记为 B1-7，背面还画着螺旋吊坠的图案，本幕把所有线索拼完整。",
    "day11_1": "你决定潜入地图上的实验室，她眼神异常坚定地要求一起去，陈老师的警告短信让当年的高管秦亚重新浮出，本幕写出发前的那个上午。",
    "day11_2": "废弃工厂地下的防爆铁门挡住了去路，门上插槽的形状和她脖子上的吊坠一模一样，本幕写门内与门外的分界。",
    "day11_3": "喂食之后她靠在你肩上问「如果我最后还是彻底不是人了，你怎么办」，睡着后不断梦呓「不要实验」，本幕写她最怕的东西。",
    "day12_1": "出发前她摘下从小戴到大的项链放进你手心，说「这个交给你保管」，本幕写她把命运交出去的那一刻。",
    "day12_2": "项链打开了铁门，两人沿着螺旋阶梯往下走，她的瞳孔在人与猫之间不断闪烁，本幕写深入实验室的过程与越来越重的气味。",
    "day12_3": "第七层的实验室里挂着「失败品」的铭牌，笔记写明基因融合的十四天崩解与毛至试剂，本幕揭穿她耄耋化的真正原因。",
    "day13_1": "她盯着那管冰蓝色液体看了一整天，想起白色的房间、实验舱和另一个男孩，最后认出两个人不姓一个姓，本幕是记忆的雪崩。",
    "day13_2": "客厅里摆着两个方案：注射就变回人类但会忘掉这十四天，不注射就要继续靠你的血维持，本幕写她第一次为了记住你而坚持。",
    "day13_3": "第十三天夜里最后一次喂食，她含住你的手指很久很久，松开时说「这十四天，是我最开心的日子」，窗外下起倾盆大雨。",
    "day14_1": "最后一天她的猫耳和尾巴再也收不回去，却异常平静地下厨煮粥煎蛋、问你好不好吃，本幕写暴风雨前最像普通少女的一餐。",
    "day14_2": "下午回到实验室的毛至试剂前，她停下脚步转过身、不再叫你哥，只问你希望她变成什么样子，本幕把选择交回给你。",
    "day14_3": "最终抉择的时刻：你握住试剂，也握住她尖长而颤抖的手。先把十四天的感情与当下情境写足，把「打不打针」交到玩家选择（会进入 end_decision 事件），不要替玩家决定注射与否。",
}


def parse_main_key(key):
    """`dayN_M` → (N, M)；M：1=白天 2=傍晚 3=晚上。"""
    m = re.fullmatch(r"day(\d+)_([123])", key)
    if not m:
        raise SystemExit("FATAL(自检): 主线键名不合规: %s" % key)
    return int(m.group(1)), int(m.group(2))


def title_of(text):
    """narration 开头的【标题】——本幕推进指引里要原样引用它。"""
    m = re.match(r"^【([^】]+)】", text)
    if not m:
        raise SystemExit("FATAL(自检): 主线正文缺【标题】前缀: %s" % text[:24])
    return m.group(1)


def attitude_for(day):
    for lo, hi, text in ATTITUDE_TIERS:
        if lo <= day <= hi:
            return text
    raise SystemExit("FATAL(自检): 第 %d 天没有对应的关系态度" % day)


# 背景回退记录：算出来的名字不存在时记一笔，最后一起报出来（绝不静默用错图）。
BG_FALLBACKS = []


def background_for(key, loc, weather):
    """`{loc}_{weather}.png`；算出来的名字不存在就退回 `{loc}_q.png`。"""
    want = "%s_%s.png" % (loc, weather)
    if (STORIES / want).exists():
        return want
    fallback = "%s_q.png" % loc
    if not (STORIES / fallback).exists():
        raise SystemExit("FATAL(自检): %s 的背景 %s 与回退 %s 都不存在" % (key, want, fallback))
    BG_FALLBACKS.append((key, want, fallback))
    return fallback


def main_scene_prompt(key, entry):
    """主线 scenePrompt：阶段人格 + 本幕（天/时段/地点）+ 推进指引 + 形态与态度。"""
    day, seg = parse_main_key(key)
    focus = SCENE_FOCUS.get(key)
    if focus is None:
        raise SystemExit("FATAL(自检): %s 缺推进指引（SCENE_FOCUS）" % key)
    loc = entry["location"]
    if loc not in LOCATIONS:
        raise SystemExit("FATAL(自检): %s 的地点 %s 不在 locations 里" % (key, loc))
    persona = PHASE_PROMPTS["phase1"] if day <= 7 else PHASE_PROMPTS["phase2"]
    if entry["cat"]:
        form = ("她现在是猫化形态：头顶有猫耳、身后有尾巴，动作比平时更利索也更本能；"
                "她怕被你发现这一点。")
    elif day <= 2:
        # 第 1–2 天剧情尚未发生异变：提示词不能提前写猫化/竖瞳/失控
        form = ("她现在是普通成年女孩的样子，没有猫耳、尾巴，也没有明显异变；"
                "不要写已经出现的猫化外观或「身体正在异变」当既定事实"
                "（本幕正文若只写极细微的疑惑，也只当作她的困惑，不要写成已确诊）。")
    elif day <= 4:
        form = ("她仍是人形。身体可能开始有极零星的怪异瞬间（以本幕正文为准）；"
                "她自己也说不清，不要写成已经猫化，也不要反复提「异变」这个词。")
    elif day <= 6:
        form = ("她仍以人形行动。异变苗头可能藏不太住（指甲、瞳孔、本能动作等，"
                "以本幕正文为准），但不会顶着猫耳出现在公开场合。")
    else:
        form = "她现在是人形，但身体变化已经很难完全藏住，随时可能进一步失控。"
    return (
        persona
        + "现在是第 %d 天的%s，地点在%s。" % (day, SEGMENT_NAMES[seg - 1], LOCATIONS[loc])
        + "这一幕讲的是【%s】：%s就按这一幕走，后面几天的事先别提。" % (
            title_of(entry["text"]), focus)
        + form + attitude_for(day)
    )


def main_targets(key):
    """主线出口：按链推；day7_3 / day14_3 是分支点。"""
    day, seg = parse_main_key(key)
    if key == "day7_3":
        return [
            ('"戒戒好感" < 60', [("event", "end_badend7")]),
            (None, [("story", "day8_1")]),
        ]
    if key == "day14_3":
        # 合理性：
        # 1) 羁绊不够（好感+信任 < 120）→ 直接坏结局，走不到「选择」；
        # 2) 羁绊够 → 进 end_decision，由玩家选「注射 / 不注射」；
        # 3) 不注射再按堕落/服从分流到共生或枯萎 —— 数值决定代价，选择决定路线。
        return [
            ('"day" == 14 & "戒戒好感" + "戒戒信任" < 120',
             [("event", "end_badend14")]),
            ('"day" == 14', [("event", "end_decision")]),
            (None, [("appShell", "home")]),
        ]
    if seg < 3:
        return [(None, [("story", "day%d_%d" % (day, seg + 1))])]
    return [(None, [("story", "day%d_1" % (day + 1))])]


def build_main_scenes():
    """42 幕主线全部由 daily_script 生成（键 `day1_1` 写成引擎入口 `start`）。"""
    keys = sorted(DAILY, key=parse_main_key)
    expect = ["day%d_%d" % (d, s) for d in range(1, 15) for s in range(1, 4)]
    if keys != expect:
        raise SystemExit("FATAL(自检): daily_script 的键不是 14×3=42 幕的完整集合")
    scenes = []
    for key in keys:
        entry = DAILY[key]
        day, seg = parse_main_key(key)
        clothing = entry["clothing"]
        if clothing not in CLOTH_STATE:
            raise SystemExit("FATAL(自检): %s 的服装代号 %s 不认识" % (key, clothing))
        loc, weather = entry["location"], entry["weather"]
        sid = "start" if key == "day1_1" else key
        scenes.append(S(
            sid,
            "%s·%s" % (SEGMENT_NAMES[seg - 1], LOCATIONS[loc]),
            background_for(key, loc, weather),
            seg,
            CLOTH_STATE[clothing] + (CAT_SUFFIX if entry["cat"] else ""),
            entry["text"],
            main_scene_prompt(key, entry),
            main_targets(key),
            # 「新一天的开始」= 每一天的第一个时段：start（第 1 天）与 day2_1 … day14_1。
            # day 默认 0，所以入场 +1 之后 start 就是第 1 天。
            new_day=(seg == 1),
            emotion=EMOTION_BY_KEY.get(key, "平常"),
            atmos=atmosphere_lookup(loc, seg, weather),
            max_abs=DELTA_BIG if key in BIG_DELTA_KEYS else DELTA_DEFAULT,
        ))
    return scenes


# ================================================== 无尽 3 套 × 4 幕（共 12 幕）
# 每套一个结局后的日常世界：day → afternoon（1/2 概率拐进 special）→ night → 第二天。
# scenePrompt = 世界观阶段人格（endless_prompts[form]，逐字）+ 本幕地点 + 态度
#              + 本时段**全量**桥段（endless_pool，不截断不打乱）+ 两句约束。
ENDLESS_CONSTRAINT = (
    "这些桥段里挑一两个自然带出来就行，别照抄，也别一口气全用。"
    "桥段只是素材，可以按她现在的状态改写，但别扯进无关设定。"
)


def endless_prompt(form, place, attitude, segment, special=None):
    """一幕无尽的 scenePrompt（世界观逐字 + 地点 + 态度 + 全量桥段 + 两句约束）。"""
    pool = endless_pool(form, segment)
    if not pool:
        raise SystemExit("FATAL(自检): 无尽桥段池为空 form=%s seg=%d" % (form, segment))
    head = ENDLESS_PROMPTS[form] + "本幕：%s。" % place + attitude
    if special:
        head += special
    body = "这会儿可能发生的桥段（都列出来了，挑一两个展开，别的留在幕后）：\n" + "\n".join(
        "%d. %s" % (i + 1, t) for i, t in enumerate(pool))
    return head + "\n" + body + "\n" + ENDLESS_CONSTRAINT


def E(sid, display, bg, seg, state, form, place, attitude, narration, targets,
      special=None, new_day=False):
    return S(sid, display, bg, seg, state, narration,
             endless_prompt(form, place, attitude, seg, special),
             targets, new_day=new_day)


ENDLESS_SCENES = [
    # ------------------------------------------------ 重塑人间（注射毛至试剂）
    E(
        "endless_human_day", "白天·学校", "xx_q.png", 1, "校服", "human",
        place="第 15 天之后的无尽日常，白天，地点是学校教室",
        attitude="态度：她仍是内向话少的普通女孩，却愿意在这个明亮的日常里一点点靠近你。",
        narration="【重塑人间·白天·学校】晨光从窗帘缝里漏进来，又是一天。"
                  "窗外的树叶亮得发白，她坐在自己固定的座位上，把课本翻到昨天没读完的那一页——"
                  "不太记得昨天读到哪，也不太记得为什么翻开它。",
        targets=[(None, [("story", "endless_human_afternoon")])],
        new_day=True,
    ),
    E(
        "endless_human_afternoon", "傍晚·放学路上", "xw_q.png", 2, "校服", "human",
        place="第 15 天之后的无尽日常，傍晚，地点是放学回出租屋的路上",
        attitude="态度：她开始主动开口，但每句话都说得像试探。",
        narration="【重塑人间·傍晚·放学路上】放学的人流很快散开，便利店的招牌在街角亮起来。"
                  "她跟在你身后不远不近的地方，走到冰柜前忽然停住，"
                  "盯着一支雪糕看了很久，然后低头问了句什么，声音被风盖掉一半。",
        targets=[(None, [("story", "endless_human_night"),
                         ("story", "endless_human_afternoon_special")])],
    ),
    E(
        "endless_human_afternoon_special", "傍晚·便利店（特殊）", "store_q.png", 2,
        "便服", "human",
        place="第 15 天之后的无尽日常中少见的一天，傍晚，地点是便利店的货架之间",
        attitude="态度：她今天罕见地主动开了口，还替你也拿了一份。",
        special="这是少见的特殊傍晚：放学后她主动拉住你的衣袖，说要进便利店买点东西——"
                "这一天的分量值得被认真对待。",
        narration="【重塑人间·特殊傍晚·便利店】今天不太一样：放学后她主动拉住你的衣袖，"
                  "说要进便利店买点东西。关东煮的热气在货架间飘着，她挑了最里面那盒牛奶，"
                  "又拿了两根关东煮，把其中一根塞给你。",
        targets=[(None, [("story", "endless_human_night")])],
    ),
    E(
        "endless_human_night", "晚上·家里", "ji_q.png", 3, "睡裙", "human",
        place="第 15 天之后的无尽日常，晚上，地点是出租屋客厅",
        attitude="态度：安静、靠近、不解释——身体像是比脑子更早记得什么。",
        narration="【重塑人间·晚上·家里】客厅只留了一盏灯，她穿着睡裙缩在沙发角落，"
                  "电视里放着听不懂内容的节目。以前那些睡不着的夜晚她都是一个人过的，"
                  "今晚她没有回房间。",
        targets=[(None, [("story", "endless_human_day")])],
    ),
    # ------------------------------------------------------ 箱庭共生（半人半猫）
    E(
        "endless_cat_day", "白天·家里", "ji_q.png", 1, "便服猫化", "cat",
        place="结局之后的无尽日常，白天，地点是出租屋的厨房",
        attitude="态度：黏人、占有欲强，却说不出口。",
        narration="【箱庭共生·白天·家里】晨光透过窗帘缝照进出租屋，阳台上晾着的床单被风吹得鼓起。"
                  "她在厨房里偷偷试着做早饭，猫耳上沾了面粉自己没发现，"
                  "听见你的脚步声，立刻把锅铲藏到背后。",
        targets=[(None, [("story", "endless_cat_afternoon")])],
        new_day=True,
    ),
    E(
        "endless_cat_afternoon", "傍晚·街上", "xw_y.png", 2, "便服猫化", "cat",
        place="结局之后的无尽日常，傍晚，地点是雨后的街上",
        attitude="态度：护着你，也盯着你，你多看一眼别人都会被她记下来。",
        narration="【箱庭共生·傍晚·街上】雨把这条街洗得很干净，路口的积水里映出两个人的影子。"
                  "她的伞总往你这边偏，自己半边肩膀湿了也不管。",
        targets=[(None, [("story", "endless_cat_night"),
                         ("story", "endless_cat_afternoon_special")])],
    ),
    E(
        "endless_cat_afternoon_special", "傍晚·便利店（特殊）", "store_q.png", 2,
        "便服猫化", "cat",
        place="结局之后的无尽日常里少见的一次，傍晚，地点是便利店的货架之间",
        attitude="态度：她今天主动开了口，比平时多说了一两句，还替你把东西一起买了。",
        special="这是少见的特殊傍晚：今晚是她主动说想去便利店的——"
                "这件事对她来说很大。",
        narration="【箱庭共生·特殊傍晚·便利店】今晚是她主动说想去便利店的。"
                  "关东煮的暖香、货架之间的白炽灯，她把尾巴小心收在外套里，"
                  "端着两杯热的东西走到你面前，把其中一杯递过来。",
        targets=[(None, [("story", "endless_cat_night")])],
    ),
    E(
        "endless_cat_night", "晚上·家里", "ji_y.png", 3, "睡裙猫化", "cat",
        place="结局之后的无尽日常，晚上，地点是出租屋，屋外下着雨",
        attitude="态度：安心、不设防，一晚比一晚更笃定「你是她一个人的」。",
        narration="【箱庭共生·晚上·家里】外面还在下雨。她洗完澡没擦干头发就出来了，"
                  "睡裙领口湿了一片，猫耳耷拉着。"
                  "她直接坐到你旁边的地板上，把毛巾放在你腿上，什么也没说。",
        targets=[(None, [("story", "endless_cat_day")])],
    ),
    # ---------------------------------------------------------- 枯萎堕落（人偶）
    E(
        "endless_doll_day", "白天·家里", "ji_q.png", 1, "便服", "doll",
        place="结局之后的无尽日常，白天，地点是出租屋客厅",
        attitude="态度：等你下指令，把「你会说什么」当成唯一的日程。",
        narration="【枯萎堕落·白天·家里】晨光落在客厅地板上，一格一格地移过去。"
                  "她安静地坐在沙发边，猫尾在身后缓慢地摆；"
                  "光斑从这头移到那头，她始终保持同一个姿势——没有你的指令，就没有下一个动作。",
        targets=[(None, [("story", "endless_doll_afternoon")])],
        new_day=True,
    ),
    E(
        "endless_doll_afternoon", "傍晚·家里", "ji_q.png", 2, "睡裙", "doll",
        place="结局之后的无尽日常，傍晚，地点是出租屋的餐桌旁",
        attitude="态度：她靠你的表情判断自己做得对不对。",
        narration="【枯萎堕落·傍晚·家里】傍晚的光斜斜地照进客厅。"
                  "她在厨房做好了一桌饭，全是你以前随口提过想吃的东西，"
                  "自己却一口没动，坐在对面看你的筷子落在哪里。",
        targets=[(None, [("story", "endless_doll_night"),
                         ("story", "endless_doll_afternoon_special")])],
    ),
    E(
        "endless_doll_afternoon_special", "傍晚·家里（特殊）", "ji_y.png", 2,
        "睡裙", "doll",
        place="结局之后的无尽日常里少见的一次，傍晚，地点是出租屋，屋外下着雨",
        attitude="态度：她做的每件事都比平时更靠近你一点，只为确认这样做不会错。",
        special="这是少见的特殊傍晚：今天她没有等你开口就端着两杯热水走过来——"
                "没有你的允许，她连坐下都不会自己决定。",
        narration="【枯萎堕落·特殊傍晚·家里】雨点打在窗上，她换下湿衣服，头发也没擦干。"
                  "今天她没有等你开口——她端着两杯热水走过来，一杯放在你手边，"
                  "然后站在原地，等你决定她该坐哪儿。",
        targets=[(None, [("story", "endless_doll_night")])],
    ),
    E(
        "endless_doll_night", "晚上·家里", "ji_q.png", 3, "睡裙猫化", "doll",
        place="结局之后的无尽日常，晚上，地点是出租屋的卧室",
        attitude="态度：用身体代替语言，等你替她做所有决定。",
        narration="【枯萎堕落·晚上·家里】卧室的灯早就灭了。"
                  "她不知道什么时候进来的，猫尾缠在你脚踝上，呼吸轻轻打在你后颈——"
                  "不是勾引，她只是不知道除了靠近你之外还能做什么。",
        targets=[(None, [("story", "endless_doll_day")])],
    ),
]

SCENES = build_main_scenes() + ENDLESS_SCENES
MAIN_COUNT = 42
ENDLESS_COUNT = 12
EXPECT_SCENES = MAIN_COUNT + ENDLESS_COUNT


# ======================================================================== 写入
def story_blocks(s):
    """一幕 → JSONC 的块结构（字段顺序 = 注释模板顺序）。"""
    characters = [{
        "charId": CHAR_ID,
        "state": s["state"],
        "emotion": s["emotion"],
        "scenePrompt": s["prompt"],
    }]
    fixed = [{"id": "day", "value": 1}] if s["new_day"] else []
    target = []
    for require, kinds in s["targets"]:
        block = {}
        if require is not None:  # 没有 require 的块无条件成立（保底）
            block["require"] = require
        block["kind"] = [{"kind": k, "to": to} for k, to in kinds]
        target.append(block)
    return [
        [(C_DISPLAY, "displayName", s["display"]),
         (C_BG, "background", s["bg"]),
         (C_NARRATION, "narration", s["narration"]),
         (C_ATMOSPHERE, "atmosphere", s["atmos"]),
         (C_CHARS, "characters", characters)],
        [(C_FX, "fixedEffects", fixed)],
        [(C_SETTLEMENT, "settlement",
          [{"var": v, "prompt": JUDGE_VAR[v], "maxAbsDelta": s["max_abs"],
            "onNoEvidence": "zero"} for v in CN])],
        [(C_TARGET, "target", target)],
    ]


def vars_raw():
    """变量注册表的紧凑单行写法（顺序 = 世界控制台显示顺序）。"""
    lines = ["["]
    # day 默认 **0**：新游戏进场时由「入场那一幕」的 fixedEffects 加 1 得到第 1 天
    # （start 里写着 day +1，所以开局就是第 1 天）。上下限都不写 = 不设限。
    day = {"id": "day", "type": "int", "default": 0}
    lines.append("  //系统变量：天数。day 请一定要保留，剧情分支全靠它")
    lines.append("  //默认 0：开局进 start 时由入场改值 +1 = 第 1 天（新的一天也是这么 +1 的）")
    lines.append("  //不写 min/max = 不设上下限（上限留空就是不限制天数）")
    lines.append("  " + inline_obj(day) + ",")
    lines.append("")
    lines.append("  //可见变量：会在世界控制台对玩家可见")
    for i, var in enumerate(CN_VARS):
        lines.append("  " + inline_obj(var) + ("," if i < len(CN_VARS) - 1 else ""))
    lines.append("]")
    return "\n".join(lines)


MANIFEST_BLOCKS = [
    [(C_PKG_ID, "packageId", "top.rongshangs.hellojj.default"),
     (C_VERSION, "version", VERSION),
     (C_NAME, "name", "你好戒戒"),
     ([], "author", "戎Shang / ChatGal migration"),
     ([], "description", DESCRIPTION)],
    [(C_VARS, "variables", Raw(vars_raw()))],
]

CHARACTER_BLOCKS = [
    [(C_CHAR_ID, "id", CHAR_ID)],
    [(C_CHAR_PROMPT, "prompt", BASE_PROMPT)],
    [(C_CHAR_DEFAULT, "defaultState", STATE_CN["school"]),
     ([], "defaultEmotion", EMO_CN["pingchang"])],
    [(C_CHAR_STATES, "states", STATES),
     ([], "emotions", EMOTIONS)],
]

# 结局事件：旧项目结局页正文（按旧页的空行拆出来的段，每段一项进 text 数组），
# 每块最多 3 段；第一块带 cover.png，后面的块写 null（沿用上一张图）。
# 不再有 id / name / onFinish / effects —— 出口就是 target。
#
# 三个「有后续日常」的结局（人形 / 猫化 / 傀儡）末尾给玩家一道**选择题**：
# 回主页，还是继续留在这里（进对应的无尽模式）。选择题出口是**事件专有**的，
# 与 target 二选一：写了 choice 就不再写 target。
CONTINUE_TITLE = "要继续留在这里吗？"


def continue_choice(story_id):
    """「回主页 / 继续留在这里」两个选项（选项文字就是按钮上显示的字）。"""
    return (CONTINUE_TITLE, [("回到主页", "appShell", "home"),
                             ("继续留在这里", "story", story_id)])


ENDING_ROUTE = [
    {"id": "end_badend7", "text": "badend7",
     "target": [(None, [("appShell", "home")])]},
    {"id": "end_badend14", "text": "badend14",
     "target": [(None, [("appShell", "home")])]},
    # 终局选择：打不打针（与 target 二选一的 choice 事件）
    {
        "id": "end_decision",
        "slides": [
            {"image": "cover.png",
             "text": ["第十四天的夜里，你们站在地下实验室那管试剂前。"]},
            {"image": None,
             "text": ["她把尖长而颤抖的手放进你的手心，像把命交出来一样。"]},
            {"image": None,
             "text": ["注射：变回普通人类。猫耳与尾巴会消失，"
                      "这十四天的记忆——连同刚想起的真相——也会一并被抹掉。"]},
            {"image": None,
             "text": ["不注射：继续共生。记忆还在，人也还在，"
                      "但身体不会立刻变好，靠你维系的日子还要过下去。"]},
            {"image": None, "text": ["「准备好了吗？」"]},
        ],
        "choice": (
            "打不打针？",
            [("注射毛至试剂", "event", "end_csrj"),
             ("不注射，继续共生", "event", "end_no_inject")],
        ),
    },
    # 不注射后的数值分流：过度堕落/服从 → 枯萎；否则清醒离开
    {
        "id": "end_no_inject",
        "slides": [
            {"image": "cover.png",
             "text": ["你没有把针推进她的血管。"]},
            {"image": None,
             "text": ["接下来会怎样，不取决于针管，"
                      "而取决于这十四天你们把她带成了什么样。"]},
        ],
        "target": [
            # 堕落已深，或「很听话 + 有点堕落」→ 自我被取悦欲吞掉
            ('"戒戒堕落" > 65 | ("戒戒堕落" > 40 & "戒戒服从" > 75)',
             [("event", "end_kwdl")]),
            (None, [("event", "end_xtgs")]),
        ],
    },
    {"id": "end_csrj", "text": "csrjend",
     "target": [(None, [("story", "endless_human_day")])],
     "choice": continue_choice("endless_human_day")},
    {"id": "end_xtgs", "text": "xtgsend",
     "target": [(None, [("story", "endless_cat_day")])],
     "choice": continue_choice("endless_cat_day")},
    {"id": "end_kwdl", "text": "kwdlend",
     "target": [(None, [("story", "endless_doll_day")])],
     "choice": continue_choice("endless_doll_day")},
]


def event_slides(text_key, per_slide=1):
    """旧结局页正文 → slides。

    播放单位是**块（一屏）**，所以默认**一段一屏**：每屏 1~2 行，点一下翻下一屏，
    读起来不挤。首屏带 cover.png（旧项目那张结局插图），后续沿用同一张。
    """
    paras = ENDING_TEXT[text_key]
    slides = []
    for i in range(0, len(paras), per_slide):
        slides.append({
            "image": "cover.png" if not slides else None,
            "text": paras[i:i + per_slide],
        })
    return slides


# ------------------------------------------------------------- 结构自检（写前）
def self_check():
    story_ids = {s["id"] for s in SCENES}
    event_ids = {r["id"] for r in ENDING_ROUTE}
    state_en = {v: k for k, v in STATE_CN.items()}
    emo_en = {v: k for k, v in EMO_CN.items()}
    problems = []
    if len(SCENES) != EXPECT_SCENES:
        problems.append("情景数 %d ≠ %d（主线 %d + 无尽 %d）" % (
            len(SCENES), EXPECT_SCENES, MAIN_COUNT, ENDLESS_COUNT))
    if len(story_ids) != len(SCENES):
        problems.append("情景 id 有重复")
    want_ids = {"start"} | {"day%d_%d" % (d, s)
                            for d in range(1, 15) for s in range(2, 4)}
    want_ids |= {"day%d_1" % d for d in range(2, 15)}
    want_ids |= {s["id"] for s in ENDLESS_SCENES}
    if story_ids != want_ids:
        problems.append("情景 id 集合不合预期：多 %s / 少 %s" % (
            sorted(story_ids - want_ids), sorted(want_ids - story_ids)))
    new_day_ids = sorted(s["id"] for s in SCENES if s["new_day"])
    want_new_day = sorted(["start"]
                          + ["day%d_1" % d for d in range(2, 15)]
                          + ["endless_%s_day" % f for f in ("human", "cat", "doll")])
    if new_day_ids != want_new_day:
        problems.append("day+1 的幕不合预期：%s" % new_day_ids)
    if set(JUDGE_VAR) != set(CN):
        problems.append("每个变量的判定说明与注册变量对不上：%s / %s"
                        % (sorted(JUDGE_VAR), sorted(CN)))
    for s in SCENES:
        if not s["targets"]:
            problems.append("%s 没有出口块（玩家点下一阶段会卡住）" % s["id"])
        if s["targets"][-1][0] is not None:
            problems.append("%s 的最后一个出口块带 require（保底块必须无条件）" % s["id"])
        if s["max_abs"] <= 0:
            problems.append("%s 的 maxAbsDelta 不是正整数" % s["id"])
        for require, kinds in s["targets"]:
            if not kinds:
                problems.append("%s 有空出口块" % s["id"])
            if require is not None:
                for name in re.findall(r'"([^"]+)"', require):
                    if name not in set(CN) | {"day"}:
                        problems.append("%s 的 require 引用了未注册变量 %s" % (s["id"], name))
            for k, to in kinds:
                if k == "story" and to not in story_ids:
                    problems.append("%s 指向不存在的 story %s" % (s["id"], to))
                if k == "event" and to not in event_ids:
                    problems.append("%s 指向不存在的 event %s" % (s["id"], to))
        if not s["atmos"]:
            problems.append("%s 的 atmosphere 取不到（地点/天气/时段组合缺文案）" % s["id"])
        if not (STORIES / s["bg"]).exists():
            problems.append("%s 的背景 %s 不存在" % (s["id"], s["bg"]))
        if not s["prompt"] or not s["narration"]:
            problems.append("%s 的 scenePrompt / narration 是空的" % s["id"])
        if s["id"].startswith("day") or s["id"] == "start":
            # 主线：正文必须原样来自 daily_script（脚本里不许再抄一遍剧情）
            key = "day1_1" if s["id"] == "start" else s["id"]
            if DAILY[key]["text"] != s["narration"]:
                problems.append("%s 的 narration 与 daily_script 不一致" % s["id"])
            if DAILY[key]["clothing"] == "":
                problems.append("%s 在 daily_script 里没有服装代号" % s["id"])
        else:
            if "这会儿可能发生的桥段" not in s["prompt"]:
                problems.append("%s 的 scenePrompt 里没有桥段列表" % s["id"])
            if ENDLESS_CONSTRAINT not in s["prompt"]:
                problems.append("%s 的 scenePrompt 里没有那两句约束" % s["id"])
        # 立绘改名在写文件之后才做：全新检出时立绘还是学校里的英文名，这里也一并认。
        cn = "%s_%s.png" % (s["state"], s["emotion"])
        legacy = "%s_%s.png" % (state_en[s["state"]], emo_en[s["emotion"]])
        if not (CHAR_DIR / cn).exists() and not (CHAR_DIR / legacy).exists():
            problems.append("%s 的立绘 %s 不存在" % (s["id"], cn))
    # 无尽：每个 (form, seg) 的桥段必须够用，且世界观人格逐字进了 scenePrompt
    for s in ENDLESS_SCENES:
        form = s["id"].split("_")[1]
        if not ENDLESS_PROMPTS[form]:
            problems.append("%s 缺世界观阶段人格" % s["id"])
        if ENDLESS_PROMPTS[form] not in s["prompt"]:
            problems.append("%s 的 scenePrompt 没有逐字包含世界观阶段人格" % s["id"])
        if len(endless_pool(form, s["seg"])) < 11:
            problems.append("%s 的桥段池只有 %d 条" % (
                s["id"], len(endless_pool(form, s["seg"]))))
    for route in ENDING_ROUTE:
        ev = route["id"]
        # 新事件的 cover 在写入阶段从 end_csrj 复制；自检只挡「既没有文件也复制不了」
        cover = EVENTS / ev / "cover.png"
        donor = EVENTS / "end_csrj" / "cover.png"
        if not cover.exists() and not donor.exists():
            problems.append("事件 %s 缺 cover.png" % ev)
        if "slides" not in route and route.get("text") not in ENDING_TEXT:
            problems.append("结局正文缺 %s" % route.get("text"))
        if not route.get("slides") and "text" not in route:
            problems.append("事件 %s 既没有 slides 也没有 text" % ev)
        # 出口 = target / choice 二选一，且指向的目标必须存在。
        # target 统一写成 (require 或 None, [(kind, to), ...]) 块结构。
        choice = route.get("choice")
        if choice is not None:
            exits = [(k, to) for _, k, to in choice[1]]
            if not choice[1]:
                problems.append("事件 %s 的选择题没有任何选项" % ev)
            if len(choice[1]) > 5:
                problems.append("事件 %s 的选择题超过 5 个选项" % ev)
        else:
            if "target" not in route:
                problems.append("事件 %s 既没有 choice 也没有 target" % ev)
                exits = []
            else:
                exits = []
                for item in route["target"]:
                    # 兼容扁平 (kind,to) 与块 (require, kinds) 两种写法
                    if len(item) == 2 and isinstance(item[1], list):
                        exits.extend(item[1])
                    elif len(item) == 2 and isinstance(item[0], str):
                        exits.append((item[0], item[1]))
                    else:
                        problems.append("事件 %s 的 target 块形状不对: %r" % (ev, item))
        for k, to in exits:
            if k == "story" and to not in story_ids:
                problems.append("事件 %s 指向不存在的 story %s" % (ev, to))
            if k == "event" and to not in event_ids:
                problems.append("事件 %s 指向不存在的 event %s" % (ev, to))
            if k == "appShell" and to != "home":
                problems.append("事件 %s 的 appShell 只能写 home" % ev)
    if problems:
        for p in problems:
            print("FATAL(自检): " + p)
        raise SystemExit(1)


# ---------------------------------------------------------------- ① 54 幕 story
self_check()
for old in sorted(STORIES.glob("*.json")):
    old.unlink()  # 先清空：旧格式文件与改名遗留都不会留下
for s in SCENES:
    write_jsonc(STORIES / (s["id"] + ".json"), story_blocks(s))
print("stories: %d 幕（主线 %d + 无尽 %d）" % (len(SCENES), MAIN_COUNT, ENDLESS_COUNT))

# -------------------------------------------------------------- ② manifest.json
write_jsonc(PKG / "manifest.json", MANIFEST_BLOCKS)
print("manifest: version=%s name=你好戒戒 variables=%d" % (VERSION, len(CN_VARS) + 1))
print("          description=%s" % DESCRIPTION)

# ------------------------------------------------------- ③ 角色目录 + 立绘改名
for stale in ["prompt.md", "prompt_phase1.md", "prompt_phase2.md"]:
    p = CHAR_DIR / stale
    if p.exists():
        p.unlink()
        print("  removed characters/%s/%s" % (CHAR_ID, stale))
write_jsonc(CHAR_DIR / "character.json", CHARACTER_BLOCKS)
print("  wrote characters/%s/character.json（基础人格 + 四条身世细节已内联进 prompt）"
      % CHAR_ID)

# 立绘改名：school_pingchang.png → 校服_平常.png（幂等：已经改好的跳过）
renamed = 0
for old_state in STATE_ORDER:
    for old_emo in EMO_ORDER:
        src = CHAR_DIR / ("%s_%s.png" % (old_state, old_emo))
        dst = CHAR_DIR / ("%s_%s.png" % (STATE_CN[old_state], EMO_CN[old_emo]))
        if src.exists():
            if dst.exists():
                src.unlink()
            else:
                src.rename(dst)
                renamed += 1
print("  portraits renamed: %d" % renamed)

missing = ["%s_%s.png" % (s, e) for s in STATES for e in EMOTIONS
           if not (CHAR_DIR / ("%s_%s.png" % (s, e))).exists()]
print("  portraits registered: %d，缺失 %d" % (len(STATES) * len(EMOTIONS), len(missing)))
if missing:
    print("  missing: " + ", ".join(missing))

# ---------------------------------------------------------------- ④ 5 个事件
for route in ENDING_ROUTE:
    ev_id = route["id"]
    if "slides" in route:
        slides = route["slides"]
    else:
        slides = event_slides(route["text"])
    # 新事件没有旧 cover 时，复用一张现有结局插图，保证首屏有图可显示。
    cover = EVENTS / ev_id / "cover.png"
    if not cover.exists():
        cover.parent.mkdir(parents=True, exist_ok=True)
        donor = EVENTS / "end_csrj" / "cover.png"
        if donor.exists():
            shutil.copy2(donor, cover)
            print("  cover copied → %s" % ev_id)
    blocks = [(C_EV_SLIDES, "slides", slides)]
    choice = route.get("choice")
    if choice is None:
        # target 与 story 同构：块数组，带 require 的块自上而下锁第一个成立的
        target_blocks = []
        for item in route["target"]:
            if len(item) == 2 and isinstance(item[1], list):
                require, kinds = item[0], item[1]
            elif len(item) == 2 and isinstance(item[0], str):
                require, kinds = None, [item]
            else:
                raise SystemExit("事件 %s 的 target 块形状不对: %r" % (ev_id, item))
            block = {}
            if require is not None:
                block["require"] = require
            block["kind"] = [{"kind": k, "to": to} for k, to in kinds]
            target_blocks.append(block)
        blocks.append((C_EV_TARGET, "target", target_blocks))
        tail = "、".join(
            "%s%s:%s" % (("if %s " % req) if req else "", k, to)
            for item in route["target"]
            for req, kinds in (
                [(item[0], item[1])] if isinstance(item[1], list) else [(None, [item])]
            )
            for k, to in kinds
        )
    else:
        title, options = choice
        blocks.append((C_EV_CHOICE, "choice",
                       {"title": title,
                        "options": [{"text": text, "kind": kind, "to": to}
                                    for text, kind, to in options]}))
        tail = "选择题 → " + "、".join("%s(%s:%s)" % o for o in options)
    write_jsonc(EVENTS / ev_id / "event.json", [blocks])
    print("  %s: %d 块 → %s" % (ev_id, len(slides), tail))

# ------------------------------------------------- 素材体检（长度 / 桥段池条数）
main_lens = [len(s["prompt"]) for s in SCENES if not s["id"].startswith("endless_")]
end_lens = [len(s["prompt"]) for s in ENDLESS_SCENES]
print("scenePrompt 字数：主线 %d~%d（共 %d 幕，平均 %d）；无尽 %d~%d（平均 %d）" % (
    min(main_lens), max(main_lens), len(main_lens), sum(main_lens) // len(main_lens),
    min(end_lens), max(end_lens), sum(end_lens) // len(end_lens)))
print("主线幕数 %d：%s … %s" % (
    MAIN_COUNT, SCENES[0]["id"], SCENES[MAIN_COUNT - 1]["id"]))
print("背景回退（算出的文件名不存在 → 退回 {地点}_q.png）：%s" % (
    "无" if not BG_FALLBACKS else ""))
for key, want, fallback in BG_FALLBACKS:
    print("  %s: %s 不存在 → %s" % (key, want, fallback))
print("世界观素材（endless_prompts）字数: " + " ".join(
    "%s=%d" % (f, len(ENDLESS_PROMPTS[f])) for f in ("human", "cat", "doll")))
for form in ("human", "cat", "doll"):
    print("  无尽桥段池 %-5s %s（全量进 scenePrompt）" % (
        form, " ".join("seg%d=%d" % (seg, len(endless_pool(form, seg)))
                       for seg in (1, 2, 3))))
print("done.")
