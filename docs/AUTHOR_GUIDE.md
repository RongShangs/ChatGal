# 创作指南（内容包 v2：扁平结构 + JSONC + 中缀条件）

内容包就是一包 JSON + PNG：**不需要写 Dart**。写完跑一次打包脚本，装上 `.chatgal` 就能玩。
本文件是**作者面对的唯一格式说明**；字段的机器可读版本在 `schemas/v2/`，冲突处以代码为准。

## 0. 一句话格式

```
包根：manifest.json + home.png + characters/<角色id>/ + stories/<情景id>.json + events/<事件id>/event.json
```

- **所有 JSON 都允许写注释**：`//` 行注释、`/* */` 块注释、数组/对象末尾多余的逗号都会被
  加载器剥掉再解析（`jsonc.dart`）。所以可以像下面这样在字段旁边直接写说明：
  ```jsonc
  {
    //情景展示名（左上角显示「第N天 · 展示名」）
    "displayName": "白天·学校",
    "background": "xx_q.png",   // stories/ 下的文件名
  }
  ```
- 名字即身份：**情景 id = 文件名 stem**、**事件 id = 文件夹名**、**角色 id = 目录名（也就是游戏内显示的角色名）**。
  这三样都不在文件里再写一遍。

## 1. 目录树

```
<包根>                      ← .chatgal 是 zip，顶层就是包根（没有外层目录）
├─ manifest.json            包名/版本 + 变量注册（variables[]）
├─ home.png                 主页背景，**固定这个名字**（缺了只 warning，主页用主题色兜底）
├─ characters/
│  └─ <角色 id>/            目录名 = 角色 id = 游戏内角色名
│     ├─ character.json     基础人格 prompt + states/emotions + 默认状态与情绪
│     └─ <状态>_<情绪>.png  立绘，必须 states × emotions 齐全（默认包 6 × 9 = 54 张）
├─ stories/
│  ├─ start.json            **必须存在**：包入口固定是 start
│  ├─ <情景 id>.json        其余各幕，文件名就是情景 id
│  └─ <背景>.png            背景图放同目录，多幕可复用同一张
└─ events/
   └─ <事件 id>/            目录名 = 事件 id = 世界控制台里显示的事件名
      ├─ event.json         一图多句的 slides + 出口（target 出口块 **或** choice 选择题，二选一）
      └─ cover.png          事件图片，按 slides[].image 的文件名引用
```

**禁止**：`assets/` 目录与 `graph.json`（出口只写在每篇 story 自己的 `target` 里）—— 打包体检
**直接报错**；`stories/` 下建子目录（加载器不认，那一幕会静默消失）；story 文件名写成
`index.json`（同样会被跳过）；`manifest.assetIndex` 永远不要再写
（PNG 由加载器自动索引，写了也只是被忽略）。

## 2. `manifest.json`

```jsonc
{
  //包身份：决定安装唯一性，也决定存档能否继续使用
  "packageId": "top.rongshangs.hellojj.default",
  //版本号只能是数字，而且只能往高版本升（打包时会与 git HEAD 里那份比较，低了直接失败）
  "version": "250",
  //游戏内显示的包名：主页标题、包与存档页都用它
  "name": "你好戒戒",
  "author": "戎Shang / ChatGal migration",
  "description": "14 天主线 + 三个结局后的日常。",

  //注册变量：注册后才能在 fixedEffects 里改、在 require 里判断、在世界控制台里看到
  "variables": [
    //系统变量：天数。day 请保留，剧情分支全靠它
    //默认 0：开局进 start 时由入场改值 +1 = 第 1 天（之后每一天也这么 +1）
    //上下限不写 = 不设限（天数想写多长都行）
    { "id": "day", "type": "int", "default": 0 },

    //角色可见变量：中文 id + label（控制台显示）
    { "id": "戒戒好感", "type": "int", "default": 50, "min": 0, "max": 100, "label": "好感" },
    { "id": "戒戒信任", "type": "int", "default": 50, "min": 0, "max": 100, "label": "信任" },
    { "id": "戒戒服从", "type": "int", "default": 50, "min": 0, "max": 100, "label": "服从" },
    { "id": "戒戒堕落", "type": "int", "default": 0,  "min": 0, "max": 100, "label": "堕落" }
  ]
}
```

| 字段 | 必填 | 说明 |
|------|------|------|
| `packageId` | 是 | 包的唯一 id |
| `version` | 是 | **只能是数字**的字符串（`"250"`，不能是 `2.5.0`）；**只能往高版本升**；还必须与应用的 `AppServices.defaultPackageVersion` 逐字一致 |
| `name` | 是 | 游戏内显示的包名 |
| `author` / `description` | 否 | 只影响展示 |
| `variables[]` | 否 | 变量注册表，**唯一来源**；未注册的 id 一律包非法 |

变量项：`id`（全局唯一，习惯用「<角色名><属性名>」）、`type`（`int` / `number` / `string` / `bool` / `enum`）、
`default`、`min` / `max`（结算的最后一道夹取，**留空＝不设那一侧限制**）、`label`（控制台显示名）、
`enum`（仅 `enum` 型）、`description`（给自己看的）。

**两处已经不需要写**：

- **没有变量属主分组**（旧的 `characterVariables.<角色id>[]` 已删除）：所有变量住在同一个扁平命名空间，
  属主由引擎按「**最长的角色 id 前缀**」推导（「戒戒好感」→ 角色「戒戒」；匹配不上就是系统变量），
  世界控制台与记忆树按这个推导结果分组。
- **没有 `schemaVersion` / `engineCompatibility` / `entrypoints` / `characters` / `homeBackground` /
  `assetIndex` / `license` / `contentTags`**：入口固定 `start`、主页背景固定包根 `home.png`、
  角色由 `characters/` 下的文件夹决定 —— 这些都是引擎层的固定约定，写了也不会被读。

## 3. `characters/<角色 id>/character.json`

```jsonc
{
  //角色 id 同时就是目录名与游戏内显示的角色名
  "id": "戒戒",
  //基础人格：内联的完整文本，换行写成 \n（角色目录里不再有 prompt.md）
  "prompt": "你是「戒戒」。\n\n身份：哥哥的妹妹……\n说话：短句为主，常有停顿。\n动作：一律用全角括号（）写动作与心理。",
  //本情景没声明 state/emotion 时用的默认值
  "defaultState": "校服",
  "defaultEmotion": "平常",
  //状态与情绪词表：立绘文件名由它们拼出来，所以是精确的，不靠猜
  "states": ["校服", "睡裙", "便服", "校服猫化", "睡裙猫化", "便服猫化"],
  "emotions": ["平常", "开心", "伤心", "害羞", "生气", "惊讶", "思考", "感动", "失落"]
}
```

| 字段 | 说明 |
|------|------|
| `id` | 必填，必须与目录名、以及 story 里写的 `charId` 完全一致；同时是游戏内角色名 |
| `prompt` | 必填，**唯一一份基础人格**，内联写在这里（`\n` 表示换行）。缺了或空字符串在装载时就报错 |
| `defaultState` / `defaultEmotion` | 可选，本幕没声明时用；不写就取自己 `states` / `emotions` 的第一个；写了必须在里面 |
| `states` / `emotions` | 必填（空则报错）。词表，也是本幕可用立绘的范围 |

**立绘只靠命名约定解析**，没有映射表（旧的 `portraits` 字段已删除）：

```
characters/<角色 id>/<状态>_<情绪>.png        例如 characters/戒戒/校服_开心.png
```

`states × emotions` 的**每一种组合都必须有图**，缺一张打包体检就报错并列出缺哪些。
规则：一个情景里模型**只能换表情、不能换服装/形态**，所以「校服猫化」这种形态要合成一个状态词写进 `states`。

## 4. `stories/<情景 id>.json`（一幕）

**扁平结构**：没有 `id`（文件名 stem 就是 id）、没有 `enter`/`leave`/`exit` 三层包装、
**时段（segment）概念整套删除**（没有 `segment` 字段、没有 `setSegment`、过场动画里也不再有时段名）。

```jsonc
{
  "displayName": "白天·学校",          //左上角显示「第N天 · 白天·学校」
  "background": "xx_q.png",           //stories/ 下的文件名
  "narration": "【白天·学校】上课铃响过第二遍，教室里终于坐满……",   //入场词，展示在对话流顶部
  "atmosphere": "走廊里回荡着上课铃，教室里渐渐坐满了人。",          //换幕过场动画里的那句话，可空

  //本幕出场角色：state/emotion 锁定本幕立绘；scenePrompt 是本情景的额外提示词
  "characters": [
    {
      "charId": "戒戒",
      "state": "校服",
      "emotion": "平常",
      "scenePrompt": "现在是主线第一阶段（第 1~7 天）的白天，地点是学校教室。她穿校服，坐在靠窗的位置……"
    }
  ],

  //进入本幕时的固定加减：正数为加、负数为减
  "fixedEffects": [ { "id": "day", "value": 1 } ],

  //离场结算：每个受控变量一个块（各自的判定提示词 + 各自的单次上限）
  "settlement": [
    { "var": "戒戒好感",
      "prompt": "她有没有表现出更亲近你的举动或态度？有明确证据才给正数；明显疏远给负数；看不出来 0。",
      "maxAbsDelta": 3,
      "onNoEvidence": "zero" },
    { "var": "戒戒信任",
      "prompt": "她有没有更敢把事情交给你、更愿意依赖你？有证据才给正数；戒备加深给负数；看不出来 0。",
      "maxAbsDelta": 3 }
  ],

  //出口块：自上而下首个 require 成立者被锁定，块内等概率
  "target": [
    { "require": "\"day\" == 14 & \"戒戒好感\" + \"戒戒信任\" < 120",
      "kind": [ { "kind": "event", "to": "end_badend14" } ] },
    { "kind": [ { "kind": "story", "to": "1-7afternoon" } ] }
  ]
}
```

### 4.1 展示与文字

| 字段 | 说明 |
|------|------|
| `displayName` | 必填。左上角固定显示「**第N天 · 展示名**」 |
| `background` | 背景图文件名，相对 `stories/`；指向不存在的文件是校验错误 |
| `narration` | 入场词，进这一幕时展示在对话流顶部 |
| `atmosphere` | **决定「切进这一幕要不要播过场」**：写了 → 播过场并显示「第 N 天 / 情景名 / 这一句」；**留空 → 不播过场**（静默换幕，适合同一时段里节奏快的切换）。过场里的天数是**算完这一幕入场改值之后**的天数，背景铺的就是本幕的 `background`（压暗 + 轻微模糊；没写 `background` 时退回主题色薄纱） |

### 4.2 `characters[]`

`charId` 必填（必须存在对应目录）；`state` / `emotion` 决定本幕能用的立绘，必须是角色声明过的词；
`scenePrompt` 是**本情景**的额外提示词 —— 请把**地点、时间、当下情境**直接写清楚（这一层正是「阶段人格」），
角色基础人格不重复写。**第一个角色同时是离场结算取证据的角色**（取它的短期记忆）。

### 4.3 `fixedEffects[]`：入场固定加减

```jsonc
"fixedEffects": [ { "id": "day", "value": 1 } ]   // day + 1
"fixedEffects": [ { "id": "戒戒好感", "value": -5 } ]  // 好感谢 -5
```

- `value` **正数为加、负数为减**，**不能为 0**（什么都不做的条目会被体检拦下）。
- 只能作用在 `int` / `number` 变量上，且变量必须注册过。
- **天数的唯一约定**：`day` 默认 **0**，**每一天的第一个情景**（入口 `start` 也算）
  在入场 `fixedEffects` 里写 `{ "id": "day", "value": 1 }`。
  * 开局进 `start`：`0 + 1` = **第 1 天**；
  * 走到 `dayN_3` 时 `day == N`（`dayN_1` 那一步已经 +1），所以「第 N 天」的判定读到 N，
    「最后一幕结束后」的终局判定也不会变成 N+1。
  默认包（你好戒戒）与教学包（与戒戒的每一天）都是这套写法，新建工程也会自动替你写好 start 的 `day +1`。
  体检会拦两种不配套的写法：默认 0 但入口没 +1（停在第 0 天）、默认 1 但入口又 +1（开局第 2 天）。
- 入场改值在**进入本幕**时执行 —— 这也是「过场里显示的天数」的口径：切进新一天的
  第一幕时，过场直接显示 +1 之后的新天数。

### 4.4 `require`：中缀文本条件

出口条件现在是**一段中缀文本**（不是对象式 DSL），校验器与运行时共用同一个解析器
（`packages/gal_protocol/lib/src/require_expr.dart`）。

```jsonc
"require": "\"day\" > 7 & \"戒戒好感\" > 80 & \"戒戒信任\" > 70"
"require": "\"戒戒好感\" + \"戒戒信任\" < 120"
"require": "\"day\" == 14 & \"戒戒好感\" + \"戒戒信任\" < 120"
"require": "!(\"戒戒堕落\" >= 60) | \"day\" < 3"
```

| 类别 | 写法 |
|------|------|
| 变量名 | **一律用双引号包起来**：`"day"`、`"戒戒好感"`（单引号也认，但请统一用双引号） |
| 数字 | 直接写，不加引号 |
| 比较 | `>` `<` `>=` `<=` `==` `!=`（单个 `=` 会报错） |
| 逻辑 | `&`（与，也接受 `&&`）、`|`（或，也接受 `||`）、`!`（非） |
| 算术 | `+` `-`（例如「好感 + 信任」），可用括号 `( )` 分组 |
| 优先级 | 算术 > 比较 > `!` > `&` > `|`；不确定就加括号 |

- 两边都是文本时只支持 `==` / `!=`（其它比较恒假）；数字比较按数值。
- 引号里的一律当**变量名**（没有字符串字面量），所以 `"name" == "jj"` 是拿两个变量比，
  不是拿变量比字符串。目前也没有字符串型变量，条件基本都是数值比较。
- 变量必须**在 manifest 注册过**：语法错、引用未注册变量都在**装载期**报错（不会拖到运行时静默失败）；
  运行时取不到值一律当 0。
- 判定读的数值：**结算之后的**变量值；`day` 就是**本情景所属的那一天**（见 4.3）。

### 4.5 `target`：出口块数组（唯一写法）

```jsonc
//8-14night.json（第 14 天最后一幕）
"target": [
  //① 顺序就是优先级：首个 require 成立的块被锁定
  { "require": "\"day\" == 14 & \"戒戒好感\" + \"戒戒信任\" < 120",
    "kind": [ { "kind": "event", "to": "end_badend14" } ] },
  { "require": "\"day\" == 14 & \"戒戒堕落\" <= 35 & \"戒戒服从\" <= 65",
    "kind": [ { "kind": "event", "to": "end_csrj" } ] },
  { "require": "\"day\" == 14",
    "kind": [ { "kind": "event", "to": "end_kwdl" } ] },

  //② 不写 require 的块无条件成立 —— 放最后当保底
  { "kind": [ { "kind": "story", "to": "day8_1" } ] }
]

//endless_cat_afternoon.json（无尽：同一块的多个目的地等概率，这里各 1/2）
"target": [
  { "kind": [ { "kind": "story", "to": "endless_cat_night" },
              { "kind": "story", "to": "endless_cat_afternoon_special" } ] }
]
```

- **判定顺序**：自上而下轮询，首个 `require` 成立的块被锁定；块内 `kind` 数组**等概率**随机取一个
  （3 个目的地各 1/3；其中两个指向同一目标就是 2/3）。
  随机数走存档里的 `rngState`，所以同一份存档重放结果一致。
- **没有 `weight` 字段**（旧的加权随机已删除）；要调概率就多写几条指向同一目标的条目。
- `kind` 三种：`story`（去 `stories/<to>.json`）、`event`（去 `events/<to>/`）、
  `appShell`（回主页，`to` 写 `home`）。目标不存在是校验错误。
- **没有 `target` 是合法的**（只 warning）：所有块都不成立时也一样 —— 运行时返回「无出口」，
  界面提示玩家「**暂时不能进入下一阶段噢**」，玩家留在原情景继续对话。
  因此「循环场景」直接不写出口（或出口条件不成立）即可，不需要造终止场景。

### 4.6 离场结算（`settlement[]`，**每个变量一个块**）

```jsonc
"settlement": [
  { "var": "戒戒好感", "prompt": "……这一个变量怎么判……", "maxAbsDelta": 3, "onNoEvidence": "zero" }
]
```

| 块里的字段 | 说明 |
|------|------|
| `var` | 受 AI 控制的变量 id：必须是已注册的 int/number 变量（可以是中文）。同一幕同一个变量只能出现一次 |
| `prompt` | **这一个变量**的判定提示词：写「出现什么表现算加、什么算减、看不出来怎么办」。不要在这里写数值上限，也不要提别的变量 |
| `maxAbsDelta` | **这一个变量**单次最多加减多少（逐维夹取，不是所有变量共用一个数字）。默认 3，转折幕可以给 5 |
| `onNoEvidence` | 拿不到证据时：`zero`（这个变量保持原值、照常换幕，默认）或 `abort`（拒绝整笔离场、原情景可重试） |

- **不写 `settlement`（或写空数组）= 本幕不结算**。大多数日常幕都该这样。
- 引擎**只发一次请求**：把所有块的 `prompt` 一起交给模型，让模型一次给出全部增量；
  每个增量再按它**自己那条块**的 `maxAbsDelta` 收口，最后按变量注册的 `min`/`max` 夹一次。
- 模型给了本幕之外的变量名 → 整笔离场作废、原情景保留可重试。
- 有任一块写了 `onNoEvidence: "abort"` 且模型没给出该变量的结果（整体为 null **或** proposal 里缺这个键）→ 整笔离场被拒。
- **幂等**：幂等键是 `sid_<sessionId>_<情景id>_<访问号>`（一幕一次），重试不会双加。
- 证据取本幕 `characters[]` **第一个角色**的短期记忆（L1 窗口 + L2 片段）与可知状态，不注入整场原文。
- ⚠ **旧的扁平写法（`judgePrompt` / `vars` / `maxAbsDelta` / `onNoEvidence` 写在情景顶层）
  已经不再被读取**：写了就是「静默不结算」。要改用 `settlement` 数组。

## 5. `events/<事件 id>/event.json`

**文件夹名就是事件 id**，也是世界控制台里显示的名字（文件里不再写 `id` / `name`）。

```jsonc
{
  //一块 = 一屏：点一下翻下一块；块内多句换行显示在同一屏
  "slides": [
    { "image": "cover.png", "text": ["第十四天 · 雨中畸变", "十四天的羁绊终究不够。"] },
    { "image": null,        "text": ["在暴雨中，她最后一次看向你——", "她转身消失在雨中。"] }
  ],

  //出口：与 story 完全同格式、同判定
  "target": [ { "kind": [ { "kind": "appShell", "to": "home" } ] } ]
}
```

- `slides[]`：一块 = **一屏**（**一张图 + 这一屏的全部文字**）。
  `image` 是相对本事件目录的文件名；`image` 写 `null` 或省略 = **沿用上一张图**（连续几屏共用一张 CG）。
  `text` 是**句子数组**（没有单字符串写法），一行一句，都会换行显示在同一屏里；
  空数组 = 一屏空白（只给 warning）。
- `target`：与 story 的出口**完全同格式、同判定**（首个 `require` 成立的块被锁定，块内等概率）。
- **已删除**：`onFinish`、`effects`、`unlockEnding`、`endingId` —— 播完之后走的就是上面这套 `target`；
  结局 id 变量已删除，事件「已触发」靠存档台账 `pendingGalleryUnlocks`（世界控制台显示的名字就是文件夹名）。
- 没有 `target`（或条件都不成立）不是错误：事件正常收尾后提示「暂时不能进入下一阶段噢」。

### 5.1 选择题出口 `choice`（事件专有，与 `target` 二选一）

结局之后想给玩家一个**自己决定去哪**的岔路（「回主页，还是继续留在这里」），就写 `choice`：

```jsonc
{
  "slides": [ { "image": "cover.png", "text": ["十四天结束了。"] } ],
  "choice": {
    "title": "要继续留在这里吗？",            // 选项上方那句问题，可留空
    "options": [
      { "text": "回到主页",     "kind": "appShell", "to": "home" },
      { "text": "继续留在这里", "kind": "story",    "to": "endless_human_day" }
    ]
  }
}
```

- 播放到**最后一屏**时，选项会铺在屏幕上：屏幕不再响应「点一下结束」，玩家点哪个选项就去哪个。
- 每个选项 = **按钮上的字**（`text`）+ **去哪**（`kind` / `to`，与出口目的地同一套：`story` / `event` / `appShell`）。
  **不判数值、不随机** —— 所以选项里没有 `require`、也没有权重。
- `options` **最多 5 个**（第 6 个起体检报 error），至少 1 个；`text` 不能空着（会是一个空按钮）。
- **`choice` 与 `target` 二选一**：同时写体检直接报错（运行时也只会用选择题）。
- 只有事件能写 `choice`；情景的出口仍然是 `target`（按条件 + 等概率随机）。

## 6. 校验与打包

```powershell
# 生成/重建默认包（幂等，输出带注释的 JSONC；作者改默认内容的唯一入口）
python tools\rebuild_default_v2_demo.py

# 结构体检 + 打包成 .chatgal（体检不过直接 FATAL，不会产出坏包）
python tools\pack_default_v2.py

# 只体检（第三方包/自己的包）：与游戏内安装时用的是同一套校验器
cd packages\gal_protocol
dart run tool\validate_pack.dart ..\..\my_pack
```

`pack_default_v2.py` 额外守三件事：`version` 与应用的 `defaultPackageVersion` 一致、
版本是数字且**比 git HEAD 里那份高**、没有 `assets/` 目录。

体检覆盖（error = 装不进去，warning = 提醒）：

| 级别 | 检查 |
|------|------|
| error | `stories/start.json` 存在；**包里至少一个角色**（没有角色就没人可对话）；变量 id 唯一、类型/上下限自洽；角色 `states × emotions` 立绘**齐全**；`charId`/`state`/`emotion`/变量必须存在；`background` 与 `slides[].image` 的文件存在；`require` 可解析且变量已注册；`target` 目标存在；`settlement[]` 每块的 `var` 已注册且是数值变量、`prompt` 非空、`maxAbsDelta` 为正、`onNoEvidence` ∈ {zero, abort}、同一变量不重复；`fixedEffects` 只作用于数值变量且 `value ≠ 0`；出现 `graph.json` 或 `assets/` |
| warning | 本幕 / 本事件**没有出口**（合法的「暂时不能进入下一阶段」状态）；**从入口 `start` 出发走不到的情景/事件**（新写一幕却忘了接出口时，它在游戏里就是凭空不存在）；`home.png` 缺失（主页用主题色兜底）；`scenePrompt` 为空；事件某一块没有句子 |

## 7. 规则摘要

- 条件与动作都是声明式，**禁止脚本**。
- 变量必须先注册再用（`fixedEffects`、`settlement[].var`、`require` 都查注册表）。
- **数值只有两处会变**：情景的「入场改值」（`fixedEffects`）与「离场结算」（`settlement[]` 的块）。
  **模型不能改数值**：提示词协议里已经不要求它回数值，回了也会被忽略（旧的「每回合属性提案」通道与
  `role` 字段已在第 18 轮整体删除）。
- 引擎不把聊天文本当事实；改状态只有「入场改值」与「离场结算」两处。
- 记忆阈值（五层 + L5 上限）属于**游戏外设置**，包不声明也不保存。
- 一个情景里角色只能换表情，不能换服装/形态 —— 要换形态就换一幕（或多声明几个 `state` 并在 story 里指定）。
