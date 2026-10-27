/// Authority snapshot of story facts. Chat text never mutates this directly.
///
/// 只有变量、角色外观、事件台账、story 镜像、presentation 与 rngState ——
/// v1 的 `inventory` / `quests`（物品与任务）已随旧引擎删除。
class WorldSnapshot {
  const WorldSnapshot({
    required this.variables,
    required this.characters,
    required this.eventHistory,
    required this.story,
    required this.presentation,
    required this.rngState,
  });

  final Map<String, Object?> variables;
  final Map<String, Map<String, Object?>> characters;
  final Map<String, int> eventHistory;
  final Map<String, Object?> story;
  final Map<String, Object?> presentation;
  final int rngState;

  WorldSnapshot copyWith({
    Map<String, Object?>? variables,
    Map<String, Map<String, Object?>>? characters,
    Map<String, int>? eventHistory,
    Map<String, Object?>? story,
    Map<String, Object?>? presentation,
    int? rngState,
  }) {
    return WorldSnapshot(
      variables: variables ?? Map.unmodifiable(this.variables),
      characters: characters ?? Map.unmodifiable(this.characters),
      eventHistory: eventHistory ?? Map.unmodifiable(this.eventHistory),
      story: story ?? Map.unmodifiable(this.story),
      presentation: presentation ?? Map.unmodifiable(this.presentation),
      rngState: rngState ?? this.rngState,
    );
  }

  Map<String, Object?> toJson() => {
        'variables': variables,
        'characters': characters,
        'eventHistory': eventHistory,
        'story': story,
        'presentation': presentation,
        'rngState': rngState,
      };

  factory WorldSnapshot.fromJson(Map<String, Object?> json) {
    return WorldSnapshot(
      variables: Map<String, Object?>.from(json['variables']! as Map),
      characters: Map<String, Map<String, Object?>>.from(
        (json['characters']! as Map).map(
          (k, v) => MapEntry(k as String, Map<String, Object?>.from(v as Map)),
        ),
      ),
      eventHistory: Map<String, int>.from(json['eventHistory']! as Map),
      story: Map<String, Object?>.from(json['story']! as Map),
      presentation: Map<String, Object?>.from(json['presentation']! as Map),
      rngState: (json['rngState']! as num).toInt(),
    );
  }
}
