import 'error_code.dart';
import 'event_def.dart';
import 'models/manifest.dart';
import 'package_content.dart';
import 'require_expr.dart';
import 'scene_v2.dart';
import 'validation_error.dart';

/// v2 内容包校验器。
///
/// **一个实现，两处使用**：游戏内安装第三方包时在这里拦，仓库的
/// `tools/pack_default_v2.py` 也调 `tool/validate_pack.dart` 在打包前拦
/// （以前那份 python 体检与这里各写一套，容易互相漂移）。
///
/// 校验的是**作者面**的契约：情景/事件的 `target` 出口、`require` 表达式、
/// 变量注册、立绘齐全、资源存在。与「引擎层的固定约定」（入口固定 start、
/// 主页背景固定 home.png、角色由 characters/ 下的文件夹决定）无关的字段
/// 都已经从 manifest 删掉，所以这里也不再校验它们。
class PackageValidator {
  const PackageValidator();

  ValidationReport validate(PackageContent content) {
    final errors = <ValidationError>[];
    final warnings = <ValidationError>[];

    _validateLayout(content, errors, warnings);
    _validateManifest(content, errors);
    _validateVariables(content, errors);
    _validateCharacters(content, errors, warnings);
    _validateScenes(content, errors, warnings);
    _validateEvents(content, errors, warnings);
    _validateDayStart(content, warnings);
    _validateReachability(content, warnings);

    return ValidationReport(errors: errors, warnings: warnings);
  }

  /// 可达性：从入口那一幕出发，沿出口（含事件的选择题选项）走一遍，
  /// 走不到的场景/事件报 warning。
  ///
  /// 现有校验只保证「出口指向的东西存在」，保证不了「它被人指着」：
  /// 作者新写一幕却忘了从别处接过去时，它在游戏里就是凭空不存在，
  /// 而体检是绿的。只报 warning、不改通过与否——第三方包里刻意留的
  /// 备用幕也不该因此被拒。
  void _validateReachability(
    PackageContent content,
    List<ValidationError> warnings,
  ) {
    final scenes = content.scenes;
    final events = content.eventDefs;
    final reachedScenes = <String>{};
    final reachedEvents = <String>{};
    final pending = <({String kind, String id})>[];

    void push(ExitTarget t) => pending.add((kind: t.kind, id: t.to));

    final entry = PackageManifest.entrypointId;
    if (scenes.containsKey(entry)) pending.add((kind: 'story', id: entry));

    while (pending.isNotEmpty) {
      final cur = pending.removeLast();
      if (cur.kind == 'event') {
        if (!reachedEvents.add(cur.id)) continue;
        final e = events[cur.id];
        if (e == null) continue;
        for (final b in e.target) {
          b.kinds.forEach(push);
        }
        for (final o in e.choice?.options ?? const <EventChoiceOption>[]) {
          push(o.target);
        }
      } else if (cur.kind == 'story') {
        if (!reachedScenes.add(cur.id)) continue;
        final s = scenes[cur.id];
        if (s == null) continue;
        for (final b in s.target) {
          b.kinds.forEach(push);
        }
      }
      // 其它 kind（appShell 等）是尽头，不再展开
    }

    for (final id in scenes.keys) {
      if (reachedScenes.contains(id)) continue;
      warnings.add(
        ValidationError(
          code: ErrorCodes.invalidValue,
          message: '情景 "$id" 从入口（$entry）出发走不到：没有任何出口指向它，'
              '玩家在游戏里不会遇到它',
          path: '/stories/$id.json',
          hint: '补一条指向它的出口，或者删掉这一幕',
        ),
      );
    }
    for (final id in events.keys) {
      if (reachedEvents.contains(id)) continue;
      warnings.add(
        ValidationError(
          code: ErrorCodes.invalidValue,
          message: '事件 "$id" 从入口（$entry）出发走不到：没有任何出口指向它',
          path: '/events/$id/event.json',
          hint: '补一条指向它的事件出口，或者删掉这个事件',
        ),
      );
    }
  }

  /// 入口那一幕与 `day` 默认值必须配套。
  ///
  /// 约定的写法是「`day` 默认 **0** + 入口那一幕入场 `day +1` = 第 1 天」（默认包与教学包都是这套）。
  /// 两种不配套的写法会让人看到的不是想看到的：
  /// * 默认 0、入口**没有** `day +1` → 开局停在第 0 天；
  /// * 默认 1、入口**又**写了 `day +1` → 开局直接第 2 天。
  void _validateDayStart(
    PackageContent content,
    List<ValidationError> warnings,
  ) {
    final entry = content.scenes[PackageManifest.entrypointId];
    if (entry == null) return;
    final bumpsDay = entry.fixedEffects.any((f) => f.id == 'day' && f.value > 0);
    final day = content.variable('day');
    if (day == null) return;

    if (day.defaultValue == 0 && !bumpsDay) {
      warnings.add(
        const ValidationError(
          code: ErrorCodes.invalidValue,
          message: 'day 的默认值是 0，但入口情景（start）的入场改值里没有 day +1：'
              '新游戏会停在第 0 天。在 start 的 fixedEffects 里加一条 day +1 就正常了'
              '（新的一天也这么写）',
          path: '/stories/start.json/fixedEffects',
          hint: 'day 默认 0 + 入场 +1 = 第 1 天',
        ),
      );
      return;
    }
    if (day.defaultValue == 1 && bumpsDay) {
      warnings.add(
        const ValidationError(
          code: ErrorCodes.invalidValue,
          message: '入口情景（start）一进场就 day +1，而 day 的默认值是 1：'
              '新游戏会直接从第 2 天开始。默认值改成 0 才对得上',
          path: '/manifest/variables/day/default',
          hint: 'start 的 fixedEffects 里有 day +1',
        ),
      );
    }
  }

  // ------------------------------------------------------------------ layout

  /// 扁平 v2 只有 characters/ stories/ events/ + manifest.json + home.png。
  /// `assets/`、`graph.json` 一律禁止。
  void _validateLayout(
    PackageContent content,
    List<ValidationError> errors,
    List<ValidationError> warnings,
  ) {
    for (final path in content.filePaths) {
      if (path == 'graph.json') {
        errors.add(
          const ValidationError(
            code: ErrorCodes.forbiddenField,
            message: 'graph.json 不再支持：出口写在每篇 story 自己的 target 里',
            path: '/graph.json',
          ),
        );
      } else if (path.startsWith('assets/')) {
        errors.add(
          ValidationError(
            code: ErrorCodes.forbiddenField,
            message: 'v2 没有 assets/ 目录（立绘与背景放在 characters/、stories/ 里）',
            path: '/$path',
          ),
        );
      }
    }
    // 主页背景固定用包根的 home.png（不是致命错误：缺了只是主页没有底图）。
    if (content.filePaths.isNotEmpty &&
        !content.filePaths.contains('home.png')) {
      warnings.add(
        const ValidationError(
          code: ErrorCodes.unknownAsset,
          message: '包根缺 home.png：主页会用主题色兜底',
          path: '/home.png',
        ),
      );
    }
  }

  // ---------------------------------------------------------------- manifest

  void _validateManifest(PackageContent content, List<ValidationError> errors) {
    final m = content.manifest;
    if (m.packageId.trim().isEmpty) {
      errors.add(ProtocolErrors.missing('/manifest', 'packageId'));
    }
    if (m.version.trim().isEmpty) {
      errors.add(ProtocolErrors.missing('/manifest', 'version'));
    }
    if (m.name.trim().isEmpty) {
      errors.add(ProtocolErrors.missing('/manifest', 'name'));
    }
    // 入口固定是 start：包缺 start.json 时 loader 已经会抛，这里再报一次更清楚。
    if (content.scenes.isNotEmpty && !content.scenes.containsKey('start')) {
      errors.add(
        const ValidationError(
          code: ErrorCodes.unknownReference,
          message: '入口情景固定为 start，但 stories/start.json 不存在',
          path: '/stories/start.json',
        ),
      );
    }
  }

  // --------------------------------------------------------------- variables

  void _validateVariables(PackageContent content, List<ValidationError> errors) {
    // 变量 id 唯一性由 `VariableRegistry.fromManifestJson` 在**装载时**直接
    // fail fast，所以走到这里时不可能有重复 id。
    for (var i = 0; i < content.variables.length; i++) {
      final v = content.variables[i];
      final path = '/manifest/variables/$i';
      if (v.defaultValue != null) {
        final e = v.validateValue(v.defaultValue, path: '$path/default');
        if (e != null) errors.add(e);
      }
      if (v.min != null && v.max != null && v.min! > v.max!) {
        errors.add(
          ValidationError(
            code: ErrorCodes.invalidValue,
            message: '变量 "${v.id}" 的 min > max',
            path: '$path/min',
            hint: 'min=${v.min} max=${v.max}',
          ),
        );
      }
    }
  }

  // -------------------------------------------------------------- characters

  void _validateCharacters(
    PackageContent content,
    List<ValidationError> errors,
    List<ValidationError> warnings,
  ) {
    // 一个角色都没有的包是**不能玩**的：对话、立绘、记忆全都挂在角色上。
    if (content.characters.isEmpty) {
      errors.add(
        const ValidationError(
          code: ErrorCodes.unknownCharacter,
          message: '包里至少要有一个角色：characters/<角色id>/character.json'
              '（没有角色就没人可以对话）',
          path: '/characters',
          hint: '在创作台的「角色」页新建一个，或手写 characters/<id>/character.json',
        ),
      );
    }
    for (var i = 0; i < content.characters.length; i++) {
      final c = content.characters[i];
      final path = '/characters/${c.id}';
      // prompt 这里不再报 warning：装载期 `reqStr('prompt')` 会先抛
      // （character.dart），空 prompt 根本走不到校验器，那条分支是死代码，
      // 还给人「prompt 可以省」的错觉。
      if (c.states.isEmpty) {
        errors.add(ProtocolErrors.missing(path, 'states'));
      }
      if (c.emotions.isEmpty) {
        errors.add(ProtocolErrors.missing(path, 'emotions'));
      }
      if (c.states.isNotEmpty && !c.states.contains(c.defaultState)) {
        errors.add(
          ValidationError(
            code: ErrorCodes.invalidValue,
            message: '角色 "${c.id}" 的 defaultState 不在 states 里',
            path: '$path/defaultState',
            hint: 'defaultState=${c.defaultState}',
          ),
        );
      }
      if (c.emotions.isNotEmpty && !c.emotions.contains(c.defaultEmotion)) {
        errors.add(
          ValidationError(
            code: ErrorCodes.invalidValue,
            message: '角色 "${c.id}" 的 defaultEmotion 不在 emotions 里',
            path: '$path/defaultEmotion',
            hint: 'defaultEmotion=${c.defaultEmotion}',
          ),
        );
      }
      // 立绘不再有映射表：文件名必须是 `characters/<id>/<状态>_<情绪>.png`。
      // 缺一张就意味着模型选了却解析不到，运行时只能落占位图。
      final missing = <String>[];
      for (final st in c.states) {
        for (final em in c.emotions) {
          final rel = c.portraitPathFor(st, em);
          if (content.filePaths.isNotEmpty &&
              !content.filePaths.contains(rel)) {
            missing.add('${st}_$em');
          }
        }
      }
      if (missing.isNotEmpty) {
        errors.add(
          ValidationError(
            code: ErrorCodes.unknownAsset,
            message: '缺立绘（states × emotions 必须齐全）：${missing.join('、')}',
            path: '$path',
            hint: '命名约定：${c.portraitPathFor('<状态>', '<情绪>')}',
          ),
        );
      }
    }
  }

  // ------------------------------------------------------------------ scenes

  void _validateScenes(
    PackageContent content,
    List<ValidationError> errors,
    List<ValidationError> warnings,
  ) {
    if (content.scenes.isEmpty) {
      errors.add(
        const ValidationError(
          code: ErrorCodes.missingField,
          message: 'v2 包必须有 stories/<情景 id>.json（start.json 必需）',
          path: '/stories',
        ),
      );
      return;
    }

    final registered = <String>{for (final v in content.variables) v.id};

    for (final scene in content.scenes.values) {
      final p = '/stories/${scene.id}.json';
      if (scene.displayName.trim().isEmpty) {
        errors.add(ProtocolErrors.missing(p, 'displayName'));
      }
      final bg = scene.background;
      if (bg != null && bg.isNotEmpty && content.filePaths.isNotEmpty) {
        final rel = bg.contains('/') ? bg : 'stories/$bg';
        if (!content.filePaths.contains(rel)) {
          errors.add(
            ValidationError(
              code: ErrorCodes.unknownAsset,
              message: 'background 指向的文件不存在',
              path: '$p/background',
              hint: bg,
            ),
          );
        }
      }
      _validateActors(content, scene, p, errors, warnings);
      _validateFixedEffects(content, scene.fixedEffects, '$p/fixedEffects', errors);
      _validateSettlement(content, scene, p, registered, errors);
      _validateTargets(
        content,
        scene.target,
        '$p/target',
        registered,
        errors,
        warnings,
        missingHint: '本情景没有可用出口：点「下一阶段」会提示暂时不能进入',
      );
      // 可达性提示：所有出口块都带 require 且没有无条件兜底时，
      // 如果这些条件在当前数值 + 本幕最大结算下都不可能成立，玩家会卡死。
      // 校验器不知道运行时数值，只能提示作者「没有兜底出口」这个结构风险。
      if (scene.target.isNotEmpty &&
          scene.target.every((b) => b.require != null && b.require!.trim().isNotEmpty)) {
        warnings.add(
          ValidationError(
            code: ErrorCodes.missingField,
            message: '本情景所有出口都带条件、没有无条件兜底块：'
                '如果这些条件在当前数值下都不成立，玩家会卡在这一幕（反复点「下一阶段」无效）',
            path: '$p/target',
            hint: '建议在最后加一个无条件出口块（不写 require），'
                '或确认各条件在本幕结算后确实可达',
          ),
        );
      }
    }
  }

  void _validateActors(
    PackageContent content,
    SceneDef scene,
    String p,
    List<ValidationError> errors,
    List<ValidationError> warnings,
  ) {
    if (scene.characters.isEmpty) {
      warnings.add(
        ValidationError(
          code: ErrorCodes.missingField,
          message: '这一幕没有出场角色：游戏里这一幕没人可对话',
          path: p,
          hint: '在「出场角色」里加一条（charId 必须是 characters/ 下已有的角色）',
        ),
      );
    }
    for (var i = 0; i < scene.characters.length; i++) {
      final actor = scene.characters[i];
      final ap = '$p/characters/$i';
      final def = content.character(actor.charId);
      if (def == null) {
        errors.add(
          ValidationError(
            code: ErrorCodes.unknownCharacter,
            message: 'charId "${actor.charId}" 没有对应的 characters/<id>/ 目录',
            path: '$ap/charId',
          ),
        );
        continue;
      }
      final state = actor.state ?? '';
      final emotion = actor.emotion ?? '';
      if (state.isNotEmpty && !def.states.contains(state)) {
        errors.add(
          ValidationError(
            code: ErrorCodes.invalidValue,
            message: 'state "$state" 不在角色 "${def.id}" 声明的 states 里',
            path: '$ap/state',
            hint: 'states=${def.states.join(',')}',
          ),
        );
      }
      if (emotion.isNotEmpty && !def.emotions.contains(emotion)) {
        errors.add(
          ValidationError(
            code: ErrorCodes.invalidValue,
            message: 'emotion "$emotion" 不在角色 "${def.id}" 声明的 emotions 里',
            path: '$ap/emotion',
            hint: 'emotions=${def.emotions.join(',')}',
          ),
        );
      }
      if (actor.scenePrompt.trim().isEmpty) {
        warnings.add(
          ValidationError(
            code: ErrorCodes.missingField,
            message: 'scenePrompt 是空的：本情景没有额外人格提示词，模型只能靠基础人格猜',
            path: '$ap/scenePrompt',
          ),
        );
      }
    }
  }

  /// `fixedEffects`：正数为加、负数为减，所以只能作用在**数值变量**上。
  void _validateFixedEffects(
    PackageContent content,
    List<VariableChange> changes,
    String path,
    List<ValidationError> errors,
  ) {
    for (var i = 0; i < changes.length; i++) {
      final fx = changes[i];
      final fp = '$path/$i';
      if (fx.id.trim().isEmpty) {
        errors.add(ProtocolErrors.missing(fp, 'id'));
        continue;
      }
      final def = content.variable(fx.id);
      if (def == null) {
        errors.add(
          ValidationError(
            code: ErrorCodes.unknownVariable,
            message: '引用了未注册变量 "${fx.id}"（会被静默忽略）',
            path: '$fp/id',
          ),
        );
        continue;
      }
      if (def.type != 'int' && def.type != 'number') {
        errors.add(
          ValidationError(
            code: ErrorCodes.invalidType,
            message: 'fixedEffects 只能加减数值变量，"${fx.id}" 是 ${def.type}',
            path: '$fp/id',
          ),
        );
      }
      if (fx.value == 0) {
        errors.add(
          ValidationError(
            code: ErrorCodes.invalidValue,
            message: 'value 是 0：这条 fixedEffects 什么也不做，删掉它',
            path: '$fp/value',
          ),
        );
      }
    }
  }

  /// 结算校验：`settlement[]` 里**每个变量一个块**，各自带判定提示词与单次上限。
  void _validateSettlement(
    PackageContent content,
    SceneDef scene,
    String p,
    Set<String> registered,
    List<ValidationError> errors,
  ) {
    final seen = <String>{};
    for (var i = 0; i < scene.settlement.length; i++) {
      final s = scene.settlement[i];
      final sp = '$p/settlement/$i';
      final def = content.variable(s.varId);
      if (def == null) {
        errors.add(
          ValidationError(
            code: ErrorCodes.unknownVariable,
            message: 'settlement 里的变量 "${s.varId}" 没有注册（会被静默忽略）',
            path: '$sp/var',
            hint: registered.isEmpty ? '没有注册任何变量' : registered.join(', '),
          ),
        );
      } else if (def.type != 'int' && def.type != 'number') {
        errors.add(
          ValidationError(
            code: ErrorCodes.invalidType,
            message: '结算只能加减数值变量，"${s.varId}" 是 ${def.type}',
            path: '$sp/var',
          ),
        );
      }
      if (!seen.add(s.varId)) {
        errors.add(
          ValidationError(
            code: ErrorCodes.duplicateId,
            message: '同一个变量在 settlement 里出现了两次："${s.varId}"'
                '（合并成一条，把判定说明写在一起）',
            path: '$sp/var',
          ),
        );
      }
      if (s.prompt.trim().isEmpty) {
        errors.add(
          ValidationError(
            code: ErrorCodes.missingField,
            message: '这一项没写判定提示词 prompt：模型不知道该按什么标准给 "${s.varId}" 加减',
            path: '$sp/prompt',
            hint: '写「本幕怎么看这个变量」，例如「她是否表现出更亲近的举动，有则 +1/+2，没有则 0」',
          ),
        );
      }
      if (s.maxAbsDelta <= 0) {
        errors.add(
          ValidationError(
            code: ErrorCodes.invalidValue,
            message: 'maxAbsDelta 必须为正整数',
            path: '$sp/maxAbsDelta',
            hint: 'value=${s.maxAbsDelta}',
          ),
        );
      }
      if (s.onNoEvidence != 'zero' && s.onNoEvidence != 'abort') {
        errors.add(
          ValidationError(
            code: ErrorCodes.invalidValue,
            message: 'onNoEvidence 只能是 zero（这一个变量保持原值）或 abort（拒绝本次离场）',
            path: '$sp/onNoEvidence',
            hint: 'value=${s.onNoEvidence}',
          ),
        );
      }
    }
  }

  /// 出口块校验：story 与 event 用的是**同一套** [TargetBlock]。
  void _validateTargets(
    PackageContent content,
    List<TargetBlock> blocks,
    String path,
    Set<String> registered,
    List<ValidationError> errors,
    List<ValidationError> warnings, {
    required String missingHint,
  }) {
    if (blocks.isEmpty) {
      warnings.add(
        ValidationError(
          code: ErrorCodes.missingField,
          message: missingHint,
          path: path,
        ),
      );
      return;
    }
    for (var i = 0; i < blocks.length; i++) {
      final block = blocks[i];
      final bp = '$path/$i';
      final req = block.require;
      if (req != null) {
        final err = RequireExpr.check(req);
        if (err != null) {
          errors.add(
            ValidationError(
              code: ErrorCodes.invalidValue,
              message: 'require 写错了：$err',
              path: '$bp/require',
              hint: req,
            ),
          );
        } else {
          for (final name in RequireExpr.variablesIn(req)) {
            if (registered.isNotEmpty && !registered.contains(name)) {
              errors.add(
                ValidationError(
                  code: ErrorCodes.unknownVariable,
                  message: 'require 引用了未注册变量 "$name"（读不到值 → 条件恒假）',
                  path: '$bp/require',
                  hint: 'registered=${registered.join(', ')}',
                ),
              );
            }
          }
        }
      }
      if (block.kinds.isEmpty) {
        errors.add(ProtocolErrors.missing(bp, 'kind'));
        continue;
      }
      for (var k = 0; k < block.kinds.length; k++) {
        _validateExitTarget(content, block.kinds[k], '$bp/kind/$k', errors);
      }
    }
  }

  /// 单个目的地校验（story / event / appShell）—— 出口块与选择题选项共用。
  void _validateExitTarget(
    PackageContent content,
    ExitTarget t,
    String tp,
    List<ValidationError> errors,
  ) {
    switch (t.kind) {
      case 'story':
        if (!content.scenes.containsKey(t.to)) {
          errors.add(
            ValidationError(
              code: ErrorCodes.unknownReference,
              message: '出口指向的情景 "${t.to}" 不存在',
              path: '$tp/to',
            ),
          );
        }
      case 'event':
        if (!content.eventDefs.containsKey(t.to)) {
          errors.add(
            ValidationError(
              code: ErrorCodes.unknownEvent,
              message: '出口指向的事件 "${t.to}" 不存在',
              path: '$tp/to',
            ),
          );
        }
      case 'appShell':
        // appShell 只有一个目的地（回主页）。不校验的话，「回设置」这种写法
        // 体检/装载全过，运行时却回主页 —— 按钮文字与真实去向对不上。
        if (t.to != 'home') {
          errors.add(
            ValidationError(
              code: ErrorCodes.invalidValue,
              message: 'appShell 只能去 home（回主页），"${t.to}" 不支持',
              path: '$tp/to',
              hint: 'value=${t.to}',
            ),
          );
        }
      default:
        errors.add(
          ValidationError(
            code: ErrorCodes.invalidValue,
            message: 'kind "${t.kind}" 不支持（只有 story / event / appShell）',
            path: '$tp/kind',
            hint: 'kind=${t.kind}',
          ),
        );
    }
  }

  /// 选择题出口（事件专有）：标题可空、选项 1~5 个，每个选项都要有字与目的地。
  void _validateChoice(
    PackageContent content,
    EventChoice choice,
    String path,
    List<ValidationError> errors,
  ) {
    if (choice.options.isEmpty) {
      errors.add(
        ValidationError(
          code: ErrorCodes.missingField,
          message: '选择题至少要有一个选项（不然玩家点到最后一屏就没得选）',
          path: '$path/options',
        ),
      );
      return;
    }
    if (choice.options.length > EventChoice.maxOptions) {
      errors.add(
        ValidationError(
          code: ErrorCodes.invalidValue,
          message: '选择题最多 ${EventChoice.maxOptions} 个选项',
          path: '$path/options',
          hint: '现在是 ${choice.options.length} 个',
        ),
      );
    }
    for (var i = 0; i < choice.options.length; i++) {
      final o = choice.options[i];
      final op = '$path/options/$i';
      if (o.text.trim().isEmpty) {
        errors.add(
          ValidationError(
            code: ErrorCodes.missingField,
            message: '选项没写字：这会是玩家看到的一个空按钮',
            path: '$op/text',
          ),
        );
      }
      _validateExitTarget(content, o.target, op, errors);
    }
  }

  // ------------------------------------------------------------------ events

  void _validateEvents(
    PackageContent content,
    List<ValidationError> errors,
    List<ValidationError> warnings,
  ) {
    final registered = <String>{for (final v in content.variables) v.id};
    for (final e in content.eventDefs.values) {
      final p = '/events/${e.id}/event.json';
      if (e.slides.isEmpty) {
        errors.add(
          ValidationError(
            code: ErrorCodes.missingField,
            message: '事件至少要有 1 块 slides',
            path: '$p/slides',
          ),
        );
      }
      for (var i = 0; i < e.slides.length; i++) {
        final slide = e.slides[i];
        if (slide.text.isEmpty) {
          warnings.add(
            ValidationError(
              code: ErrorCodes.missingField,
              message: '这一块没有任何句子（玩家点了不会有反应）',
              path: '$p/slides/$i/text',
            ),
          );
        }
        final img = slide.image;
        if (img != null && img.isNotEmpty && content.filePaths.isNotEmpty) {
          final rel = img.contains('/') ? img : 'events/${e.id}/$img';
          if (!content.filePaths.contains(rel)) {
            errors.add(
              ValidationError(
                code: ErrorCodes.unknownAsset,
                message: 'slides 引用的图片不存在',
                path: '$p/slides/$i/image',
                hint: rel,
              ),
            );
          }
        }
      }
      // 出口二选一：`target`（条件 + 等概率）或 `choice`（选择题，玩家自己选）。
      if (e.choice != null && e.target.isNotEmpty) {
        errors.add(
          ValidationError(
            code: ErrorCodes.invalidValue,
            message: '事件的出口二选一：写了 choice（选择题）就不要再写 target（出口块）',
            path: p,
            hint: '两条路都留着时，运行时只用选择题，target 会被忽略',
          ),
        );
      }
      if (e.choice != null) {
        _validateChoice(content, e.choice!, '$p/choice', errors);
      } else {
        _validateTargets(
          content,
          e.target,
          '$p/target',
          registered,
          errors,
          warnings,
          missingHint: '事件没有出口：播完会提示暂时不能进入下一阶段',
        );
      }
    }
  }
}
