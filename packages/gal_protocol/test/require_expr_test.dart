import 'package:gal_protocol/gal_protocol.dart';
import 'package:test/test.dart';

/// 出口条件 `require` 的**中缀文本**语法。校验器与运行时共用同一个解析器，
/// 所以「能装载」与「能判真」是同一件事。
///
/// 语法：变量名一律加双引号；比较 `> < >= <= == !=`；逻辑 `& | !`（也接受
/// `&&` / `||`）；算术 `+ -` 与括号。未注册/取不到的变量当 0 或空串，
/// **绝不抛异常**（坏条件不能把离场事务炸掉）。
WorldSnapshot _world(Map<String, Object?> vars) => WorldSnapshot(
      variables: vars,
      characters: const {},
      eventHistory: const {},
      story: const {},
      presentation: const {},
      rngState: 1,
    );

void main() {
  group('比较', () {
    final w = _world({'day': 14, '戒戒好感': 70, '戒戒信任': 45});

    test('六个比较运算符', () {
      expect(RequireExpr.parse('"day" > 7').evaluate(w), isTrue);
      expect(RequireExpr.parse('"day" >= 14').evaluate(w), isTrue);
      expect(RequireExpr.parse('"day" < 14').evaluate(w), isFalse);
      expect(RequireExpr.parse('"day" <= 14').evaluate(w), isTrue);
      expect(RequireExpr.parse('"day" == 14').evaluate(w), isTrue);
      expect(RequireExpr.parse('"day" != 14').evaluate(w), isFalse);
    });

    test('数字字面量可以直接比', () {
      expect(RequireExpr.parse('7 < "day"').evaluate(w), isTrue);
      expect(RequireExpr.parse('"day" == 14.0').evaluate(w), isTrue);
    });

    test('字符串变量之间只支持 == / !=', () {
      final named = _world({'name': 'jj', 'alias': 'jj', 'other': 'xy'});
      expect(RequireExpr.parse('"name" == "alias"').evaluate(named), isTrue);
      expect(RequireExpr.parse('"name" != "alias"').evaluate(named), isFalse);
      expect(RequireExpr.parse('"name" != "other"').evaluate(named), isTrue);
      // 大小比较没有意义：判假，而不是抛
      expect(RequireExpr.parse('"name" > "other"').evaluate(named), isFalse);
      // 双引号里**永远是变量名**（没有字符串字面量）：拿一个未注册的名字当
      // 右操作数，取不到值 → 与 'jj' 不等。
      expect(RequireExpr.parse('"name" == "jj"').evaluate(named), isFalse);
    });
  });

  group('算术与括号', () {
    final w = _world({'戒戒好感': 70, '戒戒信任': 45, 'day': 14});

    test('加法：典型的好感 + 信任 门槛（70 + 45 = 115）', () {
      expect(
        RequireExpr.parse('"戒戒好感" + "戒戒信任" < 120').evaluate(w),
        isTrue,
      );
      expect(
        RequireExpr.parse('"戒戒好感" + "戒戒信任" < 100').evaluate(w),
        isFalse,
      );
      expect(
        RequireExpr.parse('"戒戒好感" + "戒戒信任" == 115').evaluate(w),
        isTrue,
      );
    });

    test('减法', () {
      expect(
        RequireExpr.parse('"戒戒好感" - "戒戒信任" > 20').evaluate(w),
        isTrue,
        reason: '25 > 20',
      );
      expect(
        RequireExpr.parse('"戒戒好感" - "戒戒信任" > 30').evaluate(w),
        isFalse,
      );
    });

    test('括号：布尔分组与「操作数位置」的算术分组', () {
      // 布尔分组：括号里的整条比较作为一个整体
      expect(
        RequireExpr.parse('("day" == 1 | "day" == 14) & "戒戒好感" > 60')
            .evaluate(w),
        isTrue,
      );
      expect(
        () => RequireExpr.parse('("day" == 1 2)'),
        throwsA(isA<RequireSyntaxException>()),
        reason: '括号里必须是完整比较，多写一个数字要报错',
      );
      // 算术分组：括号放在**操作数位置**上
      expect(
        RequireExpr.parse('"戒戒好感" + ("戒戒信任" - 5) > 100').evaluate(w),
        isTrue,
        reason: '70 + 40 = 110 > 100',
      );
      // 整个和式被括号包住时也要能解析（作者很自然会这么写）
      expect(
        RequireExpr.parse('("戒戒好感" + "戒戒信任") < 120').evaluate(w),
        isTrue,
        reason: '70 + 45 = 115 < 120',
      );
      expect(
        RequireExpr.parse('("戒戒好感" + "戒戒信任") < 100').evaluate(w),
        isFalse,
        reason: '115 >= 100',
      );
    });

    test('算术不支持乘法：语法错而不是静默算错', () {
      expect(
        () => RequireExpr.parse('("戒戒好感" + 5) * 1 > 70'),
        throwsA(isA<RequireSyntaxException>()),
      );
    });

    test('负号与一元正号', () {
      expect(RequireExpr.parse('-1 < "day"').evaluate(w), isTrue);
      expect(RequireExpr.parse('+1 < "day"').evaluate(w), isTrue);
    });
  });

  group('逻辑', () {
    final w = _world({'day': 14, '戒戒好感': 70, '戒戒信任': 45});

    test('与：整条 require 与逐段 & 等价', () {
      expect(
        RequireExpr.parse('"day" == 14 & "戒戒好感" > 60').evaluate(w),
        isTrue,
      );
      expect(
        RequireExpr.parse('"day" == 14 & "戒戒好感" > 80').evaluate(w),
        isFalse,
      );
      // && / || 是同样的东西
      expect(
        RequireExpr.parse('"day" == 14 && "戒戒好感" > 60').evaluate(w),
        isTrue,
      );
    });

    test('或：任一成立即成立', () {
      expect(
        RequireExpr.parse('"day" == 1 | "戒戒好感" > 60').evaluate(w),
        isTrue,
      );
      expect(
        RequireExpr.parse('"day" == 1 | "戒戒好感" > 80').evaluate(w),
        isFalse,
      );
      expect(
        RequireExpr.parse('"day" == 1 || "戒戒好感" > 80').evaluate(w),
        isFalse,
      );
    });

    test('非', () {
      expect(RequireExpr.parse('!"day" == 1').evaluate(w), isTrue);
      expect(RequireExpr.parse('!("day" == 14)').evaluate(w), isFalse);
      expect(RequireExpr.parse('!("day" == 14 | "day" == 1)').evaluate(w),
          isFalse);
    });

    test('括号改变优先级：& 先于 | 的默认分组被显式打破', () {
      expect(
        RequireExpr.parse('"day" == 1 & "day" == 14 | "day" == 14').evaluate(w),
        isTrue,
      );
      expect(
        RequireExpr.parse('"day" == 1 & ("day" == 14 | "day" == 14)')
            .evaluate(w),
        isFalse,
      );
    });

    test('空文本是无条件成立（兜底块）', () {
      expect(RequireExpr.parse('   ').evaluate(w), isTrue);
    });
  });

  group('取不到的变量不抛异常', () {
    test('未注册变量当 0 / 空串', () {
      final w = _world({'day': 1});
      expect(RequireExpr.parse('"没有这个变量" == 0').evaluate(w), isTrue);
      expect(RequireExpr.parse('"没有这个变量" != 0').evaluate(w), isFalse);
      expect(RequireExpr.parse('"没有这个变量" == 1').evaluate(w), isFalse);
      expect(RequireExpr.parse('"没有这个变量" > 0').evaluate(w), isFalse);
      expect(RequireExpr.parse('"没有这个变量" <= 0').evaluate(w), isTrue);
      expect(RequireExpr.parse('"" == ""').evaluate(w), isTrue);
    });

    test('变量是字符串时参与算术当 0（不炸）', () {
      final w = _world({'day': '不是数字'});
      expect(RequireExpr.parse('"day" + 0 == 0').evaluate(w), isTrue);
    });
  });

  group('语法错误在装载期就被拦下', () {
    test('check 对合法表达式返回 null', () {
      expect(RequireExpr.check('"day" == 14'), isNull);
      expect(
        RequireExpr.check('"day" == 14 & "戒戒好感" + "戒戒信任" < 120'),
        isNull,
      );
      expect(RequireExpr.check(''), isNull);
    });

    test('check 对非法表达式返回人话错误', () {
      for (final bad in const [
        '"day" = 14', // 单个等号
        '"day" 14', // 缺比较运算符
        '"day" == ', // 右边缺操作数
        '"day" =="，', // 右边是坏符号
        '"没闭合 == 1', // 引号没闭合
        '"day" == 1)', // 括号不匹配
        '("day" == 1', // 括号没闭合
        '"day" == 1 2', // 多余内容
        '"day" & "day" == 1', // & 左边不是比较
      ]) {
        expect(
          RequireExpr.check(bad),
          isNotNull,
          reason: '应当被拒：$bad',
        );
        expect(
          () => RequireExpr.parse(bad),
          throwsA(isA<RequireSyntaxException>()),
          reason: bad,
        );
      }
    });

    test('variablesIn 列出表达式里引用到的变量名', () {
      expect(
        RequireExpr.variablesIn('"day" == 14 & "戒戒好感" + "戒戒信任" < 120'),
        ['day', '戒戒好感', '戒戒信任'],
      );
      expect(RequireExpr.variablesIn('"day" == 1'), ['day']);
      expect(RequireExpr.variablesIn('1 == 1'), isEmpty);
    });
  });
}
