# ChatGal schema v2

对应规格：`docs/内容包结构改动规划.md`（**§18「第 15 轮：内容包格式重构」是当前最新事实**，
冲突处以 §18 与代码为准）；作者面向的完整说明见 `docs/AUTHOR_GUIDE.md`。

| 文件 | 用途 |
|------|------|
| `manifest.json` | 包清单：包身份 + 展示信息 + `variables[]` 变量注册（扁平，无 `characterVariables`） |
| `scene.json` | 一幕 `stories/<情景 id>.json`（**扁平**：displayName / background / narration / atmosphere / characters / fixedEffects / settlement[] / target），并定义共用的 `targetBlock` |
| `condition.json` | 出口块 `require` 的**中缀文本表达式**（字符串 + 语法说明；解析器 `require_expr.dart`） |
| `event.json` | 事件 `slides[]`（一块 = 一张图 + 若干句）+ 与 story 同格式的 `target` |
| `memory-entry.json` | 记忆条目（sourceMemIds / l5ReviewedBy / audience） |
| `processed-range.json` | 已处理的轮次区间（防重复提炼） |
| `save-slot.json` | 存档 v2（与 `SaveSlot.toJson()` 一一对应） |

**所有内容包 JSON 都允许写 `//`、`/* */` 注释与尾逗号**（JSONC）：加载器在解析前统一剥掉
（`packages/gal_protocol/lib/src/jsonc.dart`），所以字段旁边可以直接写说明。这里的 schema 本身是
严格 JSON（不能带注释），只是用来描述字段。

**已删除、不要再写**（写了也读不到）：

- `manifest`：`schemaVersion` / `engineCompatibility` / `entrypoints`（入口固定 `start`）/
  `characters`（角色由 `characters/` 下的文件夹决定）/ `homeBackground`（固定包根 `home.png`）/
  `assetIndex`（永远禁止）/ `characterVariables`（属主按「最长的角色 id 前缀」推导）/ `license` /
  `contentTags`。
- `character.json`：`name`（与目录名 = id 合并）、`promptFile`（角色目录里不再有 `prompt.md`，
  基础人格内联在 `prompt` 里）、`portraits`（立绘只靠 `characters/<id>/<状态>_<情绪>.png` 命名约定）。
- story：`id`（文件名 stem 就是 id）、`enter` / `leave` / `exit` 三层包装、
  顶层 `segment` 与 `enter.setSegment`（时段概念整套删除）、`leave.memory`、
  `settlement.rules[]` / `settlement.enabled` / `maxAbsDeltaPerVar` / rule 的 `id`/`charId`/`when`。
- `exit[].when` 的对象式条件 DSL、`targets[].weight`（改为 `target[]` 出口块 + 中缀 `require` + 块内等概率）。
- event：`id` / `name`（文件夹名即 id 与显示名）、`onFinish` / `effects` / `unlockEnding` / `endingId`；
  `slides[].text` 的单字符串写法（统一写句子数组）。
- 其它：`graph.json`（出口写在每篇 story 自己的 `target` 里）、`assets/` 目录与
  `manifest.assetIndex`、`stories/<id>/nodes.json` 这种 v1 嵌套布局、引擎动作表（含 `adjustStat`）。

## 校验与打包

```powershell
# 结构体检 + 打包（体检不过直接 FATAL，不会产出坏包）
python tools\pack_default_v2.py
```

`pack_default_v2.py` 另外守三件 python 侧才知道的事：`version` 与
`AppServices.defaultPackageVersion` 一致、版本只能是数字且**只能往高版本升**（与 git HEAD 比较）、
没有 `assets/` 目录。

校验**只有一份实现**：`packages/gal_protocol` 的 `PackageLoader` + `PackageValidator`
（游戏内安装第三方包用的是同一套）。命令行版入口：

```powershell
cd packages/gal_protocol
dart run tool/validate_pack.dart ..\..\content\default_v2
```

校验覆盖（当前）：入口 `stories/start.json` 必须存在、变量 id 唯一且类型/上下限自洽、
角色 `states × emotions` 立绘齐全、场景引用的 `charId`/`state`/`emotion`/变量存在、
`background` 与事件 `slides[].image` 的文件存在、`require` 可解析且变量已注册、
`target` 目标存在、`settlement[]` 每块的字段自洽（`var` 已注册且是数值、`prompt` 非空、
`maxAbsDelta` 为正、`onNoEvidence` ∈ {zero, abort}、同一变量不重复）、
`fixedEffects` 只作用于数值变量且 value ≠ 0。**没有出口只是 warning**（不是校验错误），
`home.png` 缺失也从 error 降为 warning；`assets/` 与 `graph.json` 仍然禁止。

## 示例包

`examples/min_pack/`：三幕（start → s1 → s2）+ 一个结局事件的最小合规 v2 示例包，
同时是校验器测试的夹具。
