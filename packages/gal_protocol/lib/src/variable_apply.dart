import 'models/variable_def.dart';
import 'scene_v2.dart';
import 'variable_registry.dart';

/// 把 `fixedEffects`（入场改值）落到扁平变量表：正加负减。
///
/// **按类型处理精度**：
/// - `int`：向零取整（保持整数语义）；
/// - `number`：保留小数精度；
/// - 其他类型（string/bool/enum）：不参与数值叠加，跳过。
///
/// 同时执行注册表 `min/max` 上下限（入场改值以前绕过限幅，导致
/// 合法的 number 初值 1.5 加 0.75 会变成 1，且可能越界）。
void applyVariableChanges(
  Map<String, Object?> vars,
  List<VariableChange> changes, {
  VariableRegistry registry = VariableRegistry.empty,
}) {
  for (final fx in changes) {
    final def = registry[fx.id];
    // 未注册变量仍允许写入（兼容无注册表的最小包），按 number 处理。
    final type = def?.type ?? VariableDef.typeNumber;
    if (type == VariableDef.typeString ||
        type == VariableDef.typeBool ||
        type == VariableDef.typeEnum) {
      // 非数值类型不参与加减叠加。
      continue;
    }
    final isInt = type == VariableDef.typeInt;
    final oldRaw = vars[fx.id];
    final old = oldRaw is num ? oldRaw : (isInt ? 0 : 0.0);
    var n = old + fx.value;
    if (isInt) n = n.toInt();
    // 上下限夹取（与结算同一套规则）。
    final min = def?.min;
    final max = def?.max;
    if (min != null && n < min) n = isInt ? min.toInt() : min;
    if (max != null && n > max) n = isInt ? max.toInt() : max;
    vars[fx.id] = n;
  }
}

/// 结算增量落地：按类型精度 + 注册表上下限。
///
/// [delta] 是模型给出的整数增量（结算契约只收整数）；
/// 对 `number` 类型保留小数现值精度，对 `int` 向零取整。
Object? applySettlementDelta(
  Object? current,
  int delta, {
  required String type,
  num? min,
  num? max,
}) {
  final isInt = type == VariableDef.typeInt;
  final old = current is num ? current : (isInt ? 0 : 0.0);
  var n = old + delta;
  if (isInt) n = n.toInt();
  if (min != null && n < min) n = isInt ? min.toInt() : min;
  if (max != null && n > max) n = isInt ? max.toInt() : max;
  return n;
}
