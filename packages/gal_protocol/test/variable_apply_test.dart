import 'package:gal_protocol/gal_protocol.dart';
import 'package:test/test.dart';

/// 数值按类型处理精度 + 入场/结算都执行注册表上下限。
void main() {
  group('applyVariableChanges：入场改值按类型精度 + 上下限', () {
    test('number 类型保留小数：1.5 + 0.75 = 2.25', () {
      final reg = VariableRegistry.build(variables: [
        const VariableDef(
          id: '分数',
          type: VariableDef.typeNumber,
          defaultValue: 1.5,
          min: 0,
          max: 100,
        ),
      ]);
      final vars = <String, Object?>{'分数': 1.5};
      applyVariableChanges(
        vars,
        [const VariableChange(id: '分数', value: 0.75)],
        registry: reg,
      );
      expect(vars['分数'], 2.25);
    });

    test('int 类型向零取整：5 + 0.7 → 5（int + 0 → int）', () {
      final reg = VariableRegistry.build(variables: [
        const VariableDef(
          id: '好感',
          type: VariableDef.typeInt,
          defaultValue: 5,
          min: 0,
          max: 100,
        ),
      ]);
      final vars = <String, Object?>{'好感': 5};
      // VariableChange.value 是 num；int 类型应向零取整
      applyVariableChanges(
        vars,
        [const VariableChange(id: '好感', value: 0.7)],
        registry: reg,
      );
      // 5 + 0.7 = 5.7 → toInt → 5
      expect(vars['好感'], 5);
    });

    test('入场改值也执行 min/max 上下限', () {
      final reg = VariableRegistry.build(variables: [
        const VariableDef(
          id: '好感',
          type: VariableDef.typeInt,
          defaultValue: 98,
          min: 0,
          max: 100,
        ),
      ]);
      final vars = <String, Object?>{'好感': 98};
      applyVariableChanges(
        vars,
        [const VariableChange(id: '好感', value: 5)],
        registry: reg,
      );
      expect(vars['好感'], 100); // 被 max 夹住
    });

    test('负数（减）也夹 min', () {
      final reg = VariableRegistry.build(variables: [
        const VariableDef(
          id: '好感',
          type: VariableDef.typeInt,
          defaultValue: 3,
          min: 0,
          max: 100,
        ),
      ]);
      final vars = <String, Object?>{'好感': 3};
      applyVariableChanges(
        vars,
        [const VariableChange(id: '好感', value: -10)],
        registry: reg,
      );
      expect(vars['好感'], 0); // 被 min 夹住
    });

    test('string/bool/enum 类型跳过数值叠加', () {
      final reg = VariableRegistry.build(variables: [
        const VariableDef(id: '名字', type: VariableDef.typeString),
        const VariableDef(id: '已见', type: VariableDef.typeBool),
      ]);
      final vars = <String, Object?>{'名字': '戒戒', '已见': true};
      applyVariableChanges(
        vars,
        [
          const VariableChange(id: '名字', value: 1),
          const VariableChange(id: '已见', value: 1),
        ],
        registry: reg,
      );
      expect(vars['名字'], '戒戒');
      expect(vars['已见'], true);
    });
  });

  group('applySettlementDelta：结算增量按类型精度 + 上下限', () {
    test('number 保留小数现值：1.5 + 1 = 2.5', () {
      final n = applySettlementDelta(
        1.5,
        1,
        type: VariableDef.typeNumber,
        min: 0,
        max: 100,
      );
      expect(n, 2.5);
    });

    test('int 向零取整：5 + 1 = 6', () {
      final n = applySettlementDelta(
        5,
        1,
        type: VariableDef.typeInt,
        min: 0,
        max: 100,
      );
      expect(n, 6);
      expect(n, isA<int>());
    });

    test('上下限夹取', () {
      expect(
        applySettlementDelta(98, 5, type: 'int', min: 0, max: 100),
        100,
      );
      expect(
        applySettlementDelta(3, -10, type: 'int', min: 0, max: 100),
        0,
      );
    });
  });
}
