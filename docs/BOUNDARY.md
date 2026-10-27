# ChatGal 分层边界：应用写死 vs 内容包决定

更新：2026-09-13（内容包 v2 / 基础对话期；第 15 轮内容包格式重构：扁平 + JSONC + 中缀 `require`）

原则：**应用与协议层不认识具体角色**。角色性格、剧情、资源、数值、出口全部来自
`.chatgal` 包；客户端只提供「机制」。

判断某个东西该放哪：

| 问题 | 判断 |
|------|------|
| 换一个完全不同的包，这段代码还要不要改？ | 要改 → 应用层写错了，应该读包 |
| 是否影响多作者并存、可导入导出、可复现回放？ | 影响 → 必须进包或进通用协议 |
| 是否属于安全 / 一致性 / 性能底线？ | 是 → 写死在应用层 |

---

## A. 应用层写死（不该进包）

### 1. 客户端与 UI
- Flutter 工程、路由、四套主题 token（紫罗兰/樱花/夜紫/深海蓝）、设计系统组件
- 布局：气泡、立绘尺寸与位置、输入坞、安全区/键盘 inset、换幕过场动画
- 「第 N 天」计数器本身（值来自 `world.variables.day`）
- 设置页（供应商、主题、记忆阈值、回复长度、立绘大小）、包与存档管理页

### 2. 协议与存储（`gal_protocol` / `gal_storage`）
- 内容包结构与校验规则（`PackageLoader` / `PackageValidator`），v2 只有扁平
  `stories/*.json`、`characters/<id>/`、`events/<id>/` + `manifest.json` + `home.png`
- 存档 schema（`SaveSlot`：世界 / 全量聊天记录 / 记忆树 + L1 窗口 / 游标 /
  已结算 id / 事件台账 / pending）
- contentHash、安装 staging、路径穿越防护、串行写队列
- 确定性 RNG（xorshift32 + lowbit 散列）、`initialWorldFor`（新档世界是纯函数）
- 记忆阈值的数据结构与 `normalized()`（值来自**游戏外设置**，包与存档都不声明）

### 3. AI 编排（`gal_ai`）
- 回合串行、revision + CancelToken 双保险（迟到响应不提交）
- 上下文组装的层序与预算（各层独立预算，超了从低优先裁，**绝不抛错**）
- 离场九步事务、幂等 id（transitionId / settlementId / 事件 commitId）
- 结算限幅（本幕 `maxAbsDelta` **逐维** → 注册表 `min`/`max`）
- 立绘解析链（模型给的名字 → 本幕 state → 默认表情 → 占位图）
- 「括号（动作）」的渲染机制、表情/情绪标签的注入机制

### 4. 不要写死
好感阈值（60/120 之类）、堕落关键词、任何具体剧情文本、任何立绘文件名、
角色 id、角色名。

---

## B. 内容包决定（应用禁止硬编码）

| 数据 | 包内位置 |
|------|----------|
| 角色 id / 名字 | `characters/<id>/character.json` 的 `id`（**文件夹名 = id = 游戏内角色名**，不再有 `name`） |
| 基础人格提示词 | `character.json.prompt`（**内联**的完整基础人格，换行写 `\n`；角色目录里没有 `prompt.md`） |
| 阶段/场景人格 | 每幕 `characters[].scenePrompt`（把地点/时间/情境写清楚） |
| 状态与情绪词表 | `character.json.states` / `emotions`（立绘范围的唯一来源） |
| 立绘 | 命名约定 `characters/<id>/<状态>_<情绪>.png`（**没有映射表**；`states × emotions` 必须齐全） |
| 场景 | `stories/<情景 id>.json`（文件名 stem 即 id）：`displayName` / `background` / `narration` / `atmosphere` / `characters[]` / `fixedEffects[]` / `settlement[]` / `target[]`（**扁平，没有 enter/leave/exit 包装**） |
| 出口与结局 | `target[]` 出口块：首个 `require` 成立的块被锁定，块内 `kind` **等概率**；**没有出口是合法状态**（提示「暂时不能进入下一阶段噢」） |
| 条件 | `require` 中缀文本（变量名双引号、`&`/`|`/`!`、`+`/`-` 与括号），解析器 `require_expr.dart` |
| 事件 | `events/<事件 id>/event.json`（**文件夹名 = 事件 id 与显示名**）：`slides[]` 一图多句（`image: null` 沿用上一张）+ 与 story **同格式**的 `target` |
| 变量与数值 | `manifest.json` 的 `variables[]`（**唯一注册表**，扁平命名空间；角色属性用中文 id + `label`，属主按「最长的角色 id 前缀」推导；数值只被「入场改值」与「离场结算」改变） |
| 数值上下限 | 变量声明里的 `min`/`max`（入场改值与结算的最后一道闸） |
| 结算规则 | 每幕顶层的 `settlement[]`：**每个受控变量一个块**（`var` + `prompt` + `maxAbsDelta` + `onNoEvidence`），一次请求结算全部，幂等键 `sid_<会话>_<情景>_<访问号>` |
| 背景 | 情景的 `background` 文件名（图放 `stories/` 里，可复用） |

**验收口诀**
1. 引擎/应用里不出现「戒戒」「jj_」「你好戒戒」这类字符串。
2. 换一个完全不同的包，UI 代码零改动即可跑。
3. 包缺人格提示词时，只回退到通用协议壳，不回退到某个原版人格。
4. UI 只认包声明的情绪词与立绘键，不认任何写死的文件名。

---

## C. 当前已知的越界/局限（待处理）

| 位置 | 现状 | 说明 |
|------|------|------|
| 无出口时的提示文案 | 应用写死 | 「暂时不能进入下一阶段噢」写在应用层，包没有覆盖入口；`target` 为空是合法状态（只 warning） |
| 出口随机的分布 | 只能等概率 | `target` 块内一律等概率，**没有 `weight`**；要偏向某目标就多写几条指向同一目标的条目 |
| 记忆阈值 | 只在**设置**里 | 包不能声明默认阈值（有意为之：阈值是玩家/产品的手感项，不该由剧情包决定） |
| 立绘只能在本幕 state 内换 | 机制限制 | 提交给模型的表 = 本幕 state × 情绪；要跨服装/形态需场景声明多套 state（或多开一幕） |

---

## D. 数据流（当前形态）

```
UI(通用)
  → PackageRef（已安装的包）
  → loadPlaySession: manifest + characters + prompt + scenes/events + 变量注册表
  → initialWorldFor(content)                      # 新档：注册表默认值 + 入口场景
  → 每回合：MemoryContextAssembler 组装上下文（人格/场景/世界事实/立绘表/五层记忆/L1窗口/关键词）
  → TurnCoordinator + DialogueProvider(用户配置的模型)
  → 模型回 JSON（segments[] 逐段文本 + expressionId + portraitId）
  → 立绘解析链 → 逐段切图（**模型不改数值**：回里带了数值字段也会被忽略）
  → 「下一阶段」：TransitionCoordinator 九步（锁 → pending → L1→L2 → 结算 → 出口 → 入场 → 保存）
  → SaveRepository（世界 + 全量消息 + 记忆树 + 游标 + 台账 + pending）
```
