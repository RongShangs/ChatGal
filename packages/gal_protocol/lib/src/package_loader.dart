import 'event_def.dart';
import 'jsonc.dart';
import 'models/character.dart';
import 'models/manifest.dart';
import 'package_content.dart';
import 'scene_v2.dart';
import 'variable_registry.dart';

/// v2 package loader (flat stories, no assets folder required).
///
/// Layout:
///   manifest.json
///   home.png
///   characters/{id}/character.json + 状态_情绪.png
///   stories/{sceneId}.json          # start.json required; 文件名 stem 就是情景 id
///   stories/{background}.png        # next to json
///   events/{eventId}/event.json     # 文件夹名就是事件 id
///
/// 所有 JSON 都允许写 `//` 注释（见 [decodeJsonc]）。**没有 graph.json**：
/// 出口一律写在每篇 story 的 `target` 里。
class PackageLoader {
  const PackageLoader._();

  static PackageContent fromFiles(Map<String, String> files) {
    Map<String, Object?> readJson(String path) {
      final raw = files[path];
      if (raw == null || raw.trim().isEmpty) {
        throw StateError('Missing package file: $path');
      }
      final decoded = decodeJsonc(raw);
      if (decoded is! Map) {
        throw StateError('Expected object in $path');
      }
      return Map<String, Object?>.from(decoded);
    }

    final manifestJson = readJson('manifest.json');
    final manifest = PackageManifest.fromJson(manifestJson);

    // 角色由 characters/<id>/character.json 的**实际存在**决定：包里有几个角色
    // 文件夹就是几个角色。manifest 不再声明角色表（也不再定顺序）。
    final discovered = <String>{};
    for (final key in files.keys) {
      final parts = key.split('/');
      if (parts.length == 3 &&
          parts[0] == 'characters' &&
          parts[2] == 'character.json') {
        discovered.add(parts[1]);
      }
    }
    final charOrder = discovered.toList()..sort();

    final characters = <CharacterDef>[];
    for (final id in charOrder) {
      final path = 'characters/$id/character.json';
      characters.add(
        CharacterDef.fromJson(readJson(path), path: '/characters/$id'),
      );
    }

    // flat stories/*.json —— 文件名 stem 就是情景 id（文件里不再写 id）。
    final scenes = <String, SceneDef>{};
    final sceneKeys = files.keys
        .where((k) =>
            k.startsWith('stories/') &&
            k.endsWith('.json') &&
            k.split('/').length == 2)
        .toList()
      ..sort();
    if (sceneKeys.isEmpty) {
      throw StateError(
        'v2 package required: stories/<sceneId>.json not found '
        '(flat layout; v1 nodes.json unsupported)',
      );
    }
    for (final key in sceneKeys) {
      if (key.endsWith('index.json')) continue;
      final id = key.split('/').last.substring(0, key.split('/').last.length - 5);
      final SceneDef scene;
      try {
        scene = SceneDef.fromJson(readJson(key), id: id);
      } on ArgumentError catch (err) {
        // 补上**是哪个文件**：不然安装/导入只报一句
        // 「Invalid argument(s): fixedEffects[] 每一项都必须有 id」，
        // 作者面对一整个包不知道该改哪一篇。
        // （PackageFormatException 自带 path，不动它。）
        throw ArgumentError('stories/$id.json 解析失败：${err.message}');
      }
      if (scenes.containsKey(scene.id)) {
        throw StateError('Duplicate scene id ${scene.id}');
      }
      scenes[scene.id] = scene;
    }
    if (!scenes.containsKey(PackageManifest.entrypointId)) {
      throw StateError('stories/start.json is required (包入口固定为 start)');
    }

    for (final scene in scenes.values) {
      for (final block in scene.target) {
        for (final t in block.kinds) {
          if (t.kind == 'story' && !scenes.containsKey(t.to)) {
            throw StateError(
              'Scene ${scene.id}: target story "${t.to}" missing',
            );
          }
        }
      }
    }

    final sceneGraph = SceneGraph(
      scenes: scenes,
      entrypoint: PackageManifest.entrypointId,
    );

    // events —— 文件夹名就是事件 id（event.json 里不再写 id/name）。
    final eventDefs = <String, EventDef>{};
    final eventKeys = files.keys
        .where((k) => k.startsWith('events/') && k.endsWith('/event.json'))
        .toList()
      ..sort();
    for (final key in eventKeys) {
      final parts = key.split('/');
      final id = parts.length >= 3 ? parts[parts.length - 2] : key;
      final EventDef e;
      try {
        e = EventDef.fromJson(readJson(key), id: id);
      } on ArgumentError catch (err) {
        // 同 story：解析失败要说清是哪个事件（选择题的选项写坏了尤其要看事件名）。
        throw ArgumentError('events/$id/event.json 解析失败：${err.message}');
      }
      eventDefs[e.id] = e;
    }
    for (final e in eventDefs.values) {
      for (final block in e.target) {
        for (final t in block.kinds) {
          if (t.kind == 'story' && !scenes.containsKey(t.to)) {
            throw StateError('Event ${e.id}: target story "${t.to}" missing');
          }
          if (t.kind == 'event' && !eventDefs.containsKey(t.to)) {
            throw StateError('Event ${e.id}: target event "${t.to}" missing');
          }
        }
      }
      // 选择题出口的选项也是目的地，同样不能悬空。
      for (final o in e.choice?.options ?? const <EventChoiceOption>[]) {
        final t = o.target;
        if (t.kind == 'story' && !scenes.containsKey(t.to)) {
          throw StateError(
            'Event ${e.id}: choice story "${t.to}" missing',
          );
        }
        if (t.kind == 'event' && !eventDefs.containsKey(t.to)) {
          throw StateError(
            'Event ${e.id}: choice event "${t.to}" missing',
          );
        }
      }
    }
    // story 的出口也可能指向事件（结局 → 事件）：事件表建好之后补一次校验，
    // 不然悬空目标要到运行时才炸。
    for (final scene in scenes.values) {
      for (final block in scene.target) {
        for (final t in block.kinds) {
          if (t.kind == 'event' && !eventDefs.containsKey(t.to)) {
            throw StateError(
              'Scene ${scene.id}: target event "${t.to}" missing',
            );
          }
        }
      }
    }

    final registry = VariableRegistry.fromManifestJson(
      manifestJson,
      characterIds: charOrder,
    );

    return PackageContent(
      manifest: manifest,
      characters: characters,
      variables: registry.defs.toList(),
      variableRegistry: registry,
      scenes: scenes,
      sceneGraph: sceneGraph,
      eventDefs: eventDefs,
      filePaths: files.keys.toSet(),
    );
  }
}
