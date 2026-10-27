/// 出场角色：本情景锁定哪套立绘 + 本情景的人格提示词。
///
/// `state` / `emotion` 决定本幕可用的立绘（模型只能在这套 state 里换表情）；
/// `scenePrompt` 是**本情景**的额外提示词（把地点/时间/情境写清楚），
/// 角色基础人格在 `characters/<id>/character.json` 的 `prompt` 里。
class SceneActor {
  const SceneActor({
    required this.charId,
    this.state,
    this.emotion,
    this.scenePrompt = '',
  });

  final String charId;
  final String? state;
  final String? emotion;
  final String scenePrompt;

  factory SceneActor.fromJson(Map<String, Object?> json) {
    final charId = '${json['charId'] ?? ''}';
    if (charId.isEmpty) {
      throw ArgumentError('characters[] 每一项都必须有 charId');
    }
    return SceneActor(
      charId: charId,
      state: json['state'] as String?,
      emotion: json['emotion'] as String?,
      scenePrompt: (json['scenePrompt'] as String?) ?? '',
    );
  }

  Map<String, Object?> toJson() => {
        'charId': charId,
        if (state != null) 'state': state,
        if (emotion != null) 'emotion': emotion,
        'scenePrompt': scenePrompt,
      };
}

/// 进入情景时要改的值：**正数为加、负数为减**（`{"id":"day","value":1}` = day+1）。
///
/// 只作用于注册过的数值变量；绝对赋值不再需要（结局 id 那类字符串变量已删除）。
class VariableChange {
  const VariableChange({required this.id, required this.value});

  final String id;
  final num value;

  factory VariableChange.fromJson(Map<String, Object?> json) {
    final id = '${json['id'] ?? ''}';
    if (id.isEmpty) {
      throw ArgumentError('fixedEffects[] 每一项都必须有 id');
    }
    final raw = json['value'];
    if (raw is! num) {
      throw ArgumentError('fixedEffects[] 的 value 必须是数字（正数为加、负数为减）');
    }
    return VariableChange(id: id, value: raw);
  }

  Map<String, Object?> toJson() => {'id': id, 'value': value};
}

/// 一个「受 AI 控制」的变量：它自己的判定提示词 + 它自己的单次加减上限。
///
/// 结算不再有一条公共的 `judgePrompt`：**每个变量各自说明该怎么看它**，
/// 这样作者可以给「好感」写「有没有更亲近」、给「服从」写「有没有按指令行动」，
/// 而不是所有变量共用一句泛泛的判定说明。
///
/// 对应 JSON：`{ "var": "戒戒好感", "prompt": "……", "maxAbsDelta": 3, "onNoEvidence": "zero" }`
class SettlementVar {
  const SettlementVar({
    required this.varId,
    required this.prompt,
    this.maxAbsDelta = 3,
    this.onNoEvidence = 'zero',
  });

  /// 变量 id（manifest 注册过的，可以是中文）。
  final String varId;

  /// 这一个变量的判定提示词。
  final String prompt;

  /// 这一个变量单次能变多少（绝对值上限）。
  final int maxAbsDelta;

  /// 这个变量拿不到证据时：`abort` = 整笔离场拒绝（保留原情景可重试）；
  /// 其它值（默认 `zero`）= 这个变量保持原值，照常进入下一幕。
  final String onNoEvidence;

  factory SettlementVar.fromJson(Map<String, Object?> json) {
    final id = '${json['var'] ?? ''}'.trim();
    if (id.isEmpty) {
      throw ArgumentError('settlement[] 每一项都必须有 var（变量 id）');
    }
    return SettlementVar(
      varId: id,
      prompt: (json['prompt'] as String?) ?? '',
      maxAbsDelta: (json['maxAbsDelta'] as num?)?.toInt() ?? 3,
      onNoEvidence: (json['onNoEvidence'] as String?) ?? 'zero',
    );
  }

  Map<String, Object?> toJson() => {
        'var': varId,
        'prompt': prompt,
        'maxAbsDelta': maxAbsDelta,
        'onNoEvidence': onNoEvidence,
      };
}

/// 出口目的地：去哪（`kind` = story / event / appShell，`to` 写文件名或目录名）。
class ExitTarget {
  const ExitTarget({required this.kind, required this.to});

  final String kind;
  final String to;

  factory ExitTarget.fromJson(Map<String, Object?> json) {
    final kind = '${json['kind'] ?? ''}';
    final to = '${json['to'] ?? ''}';
    if (kind.isEmpty || to.isEmpty) {
      throw ArgumentError('出口目的地必须同时有 kind 与 to');
    }
    return ExitTarget(kind: kind, to: to);
  }

  Map<String, Object?> toJson() => {'kind': kind, 'to': to};
}

/// 出口块：可选的 `require`（中缀文本条件）+ 若干等概率的目的地。
///
/// 判定顺序 = 数组顺序，**首个 require 成立**的块被锁定；锁定后在该块的
/// [kinds] 里**等概率**随机取一个（3 个目的地各 1/3；两个指向同一目标就是 2/3）。
/// 没有 `require`（或写空串）= 无条件成立，通常放最后当保底。
class TargetBlock {
  const TargetBlock({this.require, this.kinds = const []});

  /// 中缀条件文本，例如 `"day" > 7 & "戒戒好感" > 80`。null 表示无条件。
  final String? require;
  final List<ExitTarget> kinds;

  bool get isFallback => require == null || require!.trim().isEmpty;

  factory TargetBlock.fromJson(Map<String, Object?> json) {
    final raw = json['require'];
    final kinds = (json['kind'] as List? ?? const [])
        .map((e) => ExitTarget.fromJson(Map<String, Object?>.from(e as Map)))
        .toList();
    return TargetBlock(
      require: raw is String && raw.trim().isNotEmpty ? raw : null,
      kinds: kinds,
    );
  }

  Map<String, Object?> toJson() => {
        if (require != null) 'require': require,
        'kind': kinds.map((t) => t.toJson()).toList(),
      };
}

/// 情景定义（`stories/<情景id>.json`）。
///
/// **扁平结构**：不再有 `enter` / `leave` / `exit` 三层包装，也不再声明 `id`
/// （文件名 stem 就是 id）。时段概念（`segment`）已整套删除。
class SceneDef {
  const SceneDef({
    required this.id,
    required this.displayName,
    this.background,
    this.narration = '',
    this.atmosphere = '',
    this.characters = const [],
    this.fixedEffects = const [],
    this.settlement = const [],
    this.target = const [],
  });

  final String id;
  final String displayName;

  /// stories/ 下的文件名（例如 `ji_q.png`），不是完整路径。
  final String? background;

  /// 入场词：展示在对话流顶部。
  final String narration;

  /// 换到本情景时过场动画里显示的那一句（地点氛围）。可空。
  final String atmosphere;

  final List<SceneActor> characters;

  /// 进入本情景时执行的值变动（正数为加、负数为减）。
  final List<VariableChange> fixedEffects;

  /// 受 AI 控制的变量：每个变量一个块（自己的提示词 + 自己的上限）。
  /// 空 = 本幕不结算。
  final List<SettlementVar> settlement;


  /// 出口块（顺序即优先级）。
  final List<TargetBlock> target;

  factory SceneDef.fromJson(Map<String, Object?> json, {required String id}) {
    return SceneDef(
      id: id,
      displayName: '${json['displayName'] ?? id}',
      background: json['background'] as String?,
      narration: (json['narration'] as String?) ?? '',
      atmosphere: (json['atmosphere'] as String?) ?? '',
      characters: (json['characters'] as List? ?? const [])
          .map((e) => SceneActor.fromJson(Map<String, Object?>.from(e as Map)))
          .toList(),
      fixedEffects: (json['fixedEffects'] as List? ?? const [])
          .map(
            (e) => VariableChange.fromJson(Map<String, Object?>.from(e as Map)),
          )
          .toList(),
      settlement: (json['settlement'] as List? ?? const [])
          .map((e) => SettlementVar.fromJson(Map<String, Object?>.from(e as Map)))
          .toList(),
      target: (json['target'] as List? ?? const [])
          .map((e) => TargetBlock.fromJson(Map<String, Object?>.from(e as Map)))
          .toList(),
    );
  }

  Map<String, Object?> toJson() => {
        'displayName': displayName,
        if (background != null) 'background': background,
        'narration': narration,
        if (atmosphere.isNotEmpty) 'atmosphere': atmosphere,
        'characters': characters.map((a) => a.toJson()).toList(),
        'fixedEffects': fixedEffects.map((f) => f.toJson()).toList(),
        'settlement': settlement.map((s) => s.toJson()).toList(),
        'target': target.map((t) => t.toJson()).toList(),
      };
}

/// Package scene graph for transitions.
class SceneGraph {
  const SceneGraph({
    required this.scenes,
    this.entrypoint = 'start',
  });

  final Map<String, SceneDef> scenes;
  final String entrypoint;

  SceneDef? scene(String id) => scenes[id];
}
