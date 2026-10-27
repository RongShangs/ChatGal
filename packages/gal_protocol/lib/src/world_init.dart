import 'package_content.dart';
import 'runtime_cursor.dart';
import 'variable_apply.dart';
import 'world_snapshot.dart';

/// 新档的初始世界（**纯函数**，不碰 IO）。
///
/// 规则（顺序必须与 `TransitionCoordinator` 的入场处理**一致**，否则同一个
/// `fixedEffects` 在新档与换场两条路上会得出不同的值）：
/// 1. 注册表每个变量的 `default` 落进扁平命名空间（角色变量也在这里）；
/// 2. `day` 缺省为 1；
/// 3. 本情景的 `fixedEffects`（正数为加、负数为减）——按类型精度 + 上下限。
WorldSnapshot initialWorldFor(PackageContent content, {String? sceneId}) {
  final registry = content.variableRegistry;
  final entry = content.scenes[sceneId ?? 'start'] ??
      (content.scenes.isNotEmpty ? content.scenes.values.first : null);

  final vars = <String, Object?>{};
  registry.defaults.forEach((id, value) {
    if (value != null) vars[id] = value;
  });
  vars['day'] = (vars['day'] as num?)?.toInt() ?? 1;

  if (entry != null) {
    applyVariableChanges(vars, entry.fixedEffects, registry: registry);
  }

  final startId = entry?.id ?? 'start';
  final cursor = RuntimeCursor(
    mode: RuntimeCursor.modeStoryChat,
    storyId: startId,
    visitId: 0,
  );

  return WorldSnapshot(
    variables: vars,
    characters: const {},
    eventHistory: const {},
    // story 只是**镜像**：day 的权威是上面的扁平变量。
    story: {
      'storyId': startId,
      'nodeId': startId,
      'day': vars['day'],
    },
    presentation: {
      'scene': entry?.background ?? '',
      'narration': entry?.narration ?? '',
      'actors': entry?.characters.map((a) => a.toJson()).toList() ?? const [],
      'appearance': const {'expressionId': ''},
      'cursor': cursor.toJson(),
    },
    rngState: 1,
  );
}
