import 'error_code.dart';
import 'models/manifest.dart';
import 'models/variable_def.dart';
import 'validation_error.dart';

/// 包内所有变量的扁平注册表（`manifest.variables[]` 一个来源）。
///
/// 所有变量（系统的与角色属性）都住在**同一个扁平命名空间**：
/// 作者在 `require` / `settlement[].prompt` / `fixedEffects` 里直接写变量自己的 id
/// （例如「戒戒好感」），世界把值存在 `world.variables[<id>]`。
///
/// **属主是推导出来的**：以前的 `characterVariables.<charId>[]` 分组字段已从
/// manifest 删除，所以这里按「**最长的角色 id 前缀**」把变量归给角色
/// （「戒戒好感」→ 角色「戒戒」；匹配不上就是系统变量）。世界控制台与记忆树
/// 靠它分组。
class VariableRegistry {
  const VariableRegistry._(this._byId, this._ownerOf);

  static const empty =
      VariableRegistry._(<String, VariableDef>{}, <String, String>{});

  final Map<String, VariableDef> _byId;

  /// variable id → owning charId（推导得到；系统变量不在表里）。
  final Map<String, String> _ownerOf;

  Iterable<String> get ids => _byId.keys;
  Iterable<VariableDef> get defs => _byId.values;
  int get length => _byId.length;
  bool get isEmpty => _byId.isEmpty;

  bool contains(String id) => _byId.containsKey(id);
  VariableDef? operator [](String id) => _byId[id];

  /// Owning character of a character variable; null for system variables.
  String? ownerOf(String id) => _ownerOf[id];

  /// Every character variable declared for [charId], in declaration order.
  List<VariableDef> varsOf(String charId) =>
      _byId.values.where((v) => _ownerOf[v.id] == charId).toList();

  /// Characters that own at least one variable.
  List<String> get charIds {
    final seen = <String>[];
    for (final v in _byId.values) {
      final o = _ownerOf[v.id];
      if (o != null && !seen.contains(o)) seen.add(o);
    }
    return seen;
  }

  bool isCharacterVariable(String id) => _ownerOf.containsKey(id);

  /// id → declared bounds, for settlement clamping.
  Map<String, ({num? min, num? max})> get ranges => {
        for (final v in _byId.values)
          if (v.min != null || v.max != null) v.id: (min: v.min, max: v.max),
      };

  /// id → declared default (may be null when the author omitted it).
  Map<String, Object?> get defaults => {
        for (final v in _byId.values) v.id: v.defaultValue,
      };

  /// Build the flat namespace. Duplicate ids are an authoring error and are
  /// reported instead of silently winning.
  factory VariableRegistry.build({
    List<VariableDef> variables = const [],
    List<String> characterIds = const [],
  }) {
    final byId = <String, VariableDef>{};
    final ownerOf = <String, String>{};
    final errors = <ValidationError>[];

    // 最长的前缀优先：「戒戒」与「戒」同时存在时，「戒戒好感」归「戒戒」。
    final sortedChars = [...characterIds]..sort((a, b) => b.length - a.length);

    for (final v in variables) {
      if (byId.containsKey(v.id)) {
        errors.add(
          ValidationError(
            code: ErrorCodes.duplicateId,
            message: '变量 "${v.id}" 声明了两次',
            path: '/manifest/variables/${v.id}',
          ),
        );
        continue;
      }
      byId[v.id] = v;
      for (final c in sortedChars) {
        if (c.isNotEmpty && v.id.startsWith(c)) {
          ownerOf[v.id] = c;
          break;
        }
      }
    }
    if (errors.isNotEmpty) throw PackageFormatException(errors);

    return VariableRegistry._(
      Map.unmodifiable(byId),
      Map.unmodifiable(ownerOf),
    );
  }

  /// 从 manifest 原始 JSON 建注册表。[characterIds] 用来推导变量属主。
  static VariableRegistry fromManifestJson(
    Map<String, Object?> json, {
    List<String> characterIds = const [],
  }) {
    final variables = <VariableDef>[];
    final raw = json['variables'];
    if (raw is List) {
      for (final v in raw) {
        if (v is Map) {
          variables.add(
            VariableDef.fromJson(
              Map<String, Object?>.from(v),
              path: '/manifest/variables',
            ),
          );
        }
      }
    }
    return VariableRegistry.build(
      variables: variables,
      characterIds: characterIds,
    );
  }
}
