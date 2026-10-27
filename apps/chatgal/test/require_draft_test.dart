import 'package:chatgal/features/studio/require_editor.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「条件行 ↔ 中缀文本」的双向转换：简单模式能表达的才转，复杂的必须老实回退。
void main() {
  group('文本 → 条件行', () {
    test('空文本 = 无条件成立', () {
      final d = parseRequireDraft('');
      expect(d, isNotNull);
      expect(d!.rows, isEmpty);
    });

    test('用 & 连的两行', () {
      final d = parseRequireDraft('"day" == 7 & "戒戒好感" < 60')!;
      expect(d.rows.length, 2);
      expect(d.joiner, '&');
      expect(d.rows[0].variable, 'day');
      expect(d.rows[0].op, '==');
      expect(d.rows[0].rhs, '7');
      expect(d.rows[1].variable, '戒戒好感');
      expect(d.rows[1].op, '<');
      expect(d.rows[1].rhs, '60');
    });

    test('用 | 连的两行（含 && / || 写法）', () {
      expect(parseRequireDraft('"day" == 1 | "day" == 14')!.joiner, '|');
      expect(parseRequireDraft('"a" > 1 && "b" > 2')!.joiner, '&');
      expect(parseRequireDraft('"a" > 1 || "b" > 2')!.joiner, '|');
    });

    test('各种比较符与负数/小数', () {
      final d = parseRequireDraft('"a" >= -5.5 & "b" != 3')!;
      expect(d.rows[0].op, '>=');
      expect(d.rows[0].rhs, '-5.5');
      expect(d.rows[1].op, '!=');
    });

    test('右边可以是另一个变量', () {
      final d = parseRequireDraft('"戒戒好感" > "戒戒信任"')!;
      expect(d.rows.single.rhs, '"戒戒信任"');
    });

    test('复杂表达式老实返回 null（交给高级模式，不猜）', () {
      expect(parseRequireDraft('("a" + "b") < 120'), isNull, reason: '括号/算术');
      expect(parseRequireDraft('"a" + "b" < 120'), isNull, reason: '算术');
      expect(parseRequireDraft('!("a" > 1)'), isNull, reason: '取反');
      expect(parseRequireDraft('"a" > 1 & "b" > 2 | "c" > 3'), isNull,
          reason: '且与或混用');
      expect(parseRequireDraft('"a" > "b" + 1'), isNull, reason: '右边不是数字/变量');
      expect(parseRequireDraft('day > 7'), isNull, reason: '变量名没加引号');
    });
  });

  group('条件行 → 文本', () {
    test('拼回中缀文本', () {
      final text = buildRequireText(
        joiner: '&',
        rows: [
          RequireRow(variable: 'day', op: '==', rhs: '7'),
          RequireRow(variable: '戒戒好感', op: '<', rhs: '60'),
        ],
      );
      expect(text, '"day" == 7 & "戒戒好感" < 60');
    });

    test('没填完的行会被跳过；全空 = 空串（无条件）', () {
      expect(
        buildRequireText(
          joiner: '&',
          rows: [
            RequireRow(variable: 'day', op: '==', rhs: ''),
            RequireRow(variable: '', op: '>', rhs: '3'),
          ],
        ),
        '',
      );
      expect(
        buildRequireText(
          joiner: '|',
          rows: [
            RequireRow(variable: 'day', op: '==', rhs: '1'),
            RequireRow(variable: 'day', op: '==', rhs: ''),
          ],
        ),
        '"day" == 1',
      );
    });

    test('往返一致（能被引擎解析器吃下）', () {
      const original = '"day" == 14 & "戒戒堕落" <= 35 & "戒戒服从" <= 65';
      final d = parseRequireDraft(original)!;
      final again = buildRequireText(rows: d.rows, joiner: d.joiner);
      expect(again, original);
      // 再解析一次还是同一组条件
      final d2 = parseRequireDraft(again)!;
      expect(d2.rows.length, d.rows.length);
      expect(d2.joiner, d.joiner);
    });
  });
}
