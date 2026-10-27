import 'event_def.dart';
import 'models/character.dart';
import 'models/manifest.dart';
import 'models/variable_def.dart';
import 'scene_v2.dart';
import 'variable_registry.dart';

/// 内存里的 v2 内容包。
///
/// 只有场景（`scenes`/`sceneGraph`）、事件、角色、变量注册表与包内文件路径表。
/// v1 的 StoryDef/StoryNode/StoryEvent/物品/任务已随引擎一起删除。
class PackageContent {
  const PackageContent({
    required this.manifest,
    required this.characters,
    required this.variables,
    this.variableRegistry = VariableRegistry.empty,
    this.scenes = const {},
    this.sceneGraph,
    this.eventDefs = const {},
    this.filePaths = const {},
  });

  final PackageManifest manifest;

  final List<CharacterDef> characters;

  /// 扁平命名空间：manifest 里声明的全部变量都在同一个列表里。
  final List<VariableDef> variables;

  /// 注册表真相（含推导出来的变量属主）。
  final VariableRegistry variableRegistry;

  /// v2 场景表（id → 场景）。
  final Map<String, SceneDef> scenes;
  final SceneGraph? sceneGraph;
  final Map<String, EventDef> eventDefs;
  final Set<String> filePaths;

  CharacterDef? character(String id) {
    for (final c in characters) {
      if (c.id == id) return c;
    }
    return null;
  }

  VariableDef? variable(String id) {
    for (final v in variables) {
      if (v.id == id) return v;
    }
    return null;
  }

  EventDef? eventDef(String id) => eventDefs[id];

  SceneDef? scene(String id) => scenes[id];
}
