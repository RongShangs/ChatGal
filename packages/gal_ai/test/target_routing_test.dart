import 'package:gal_ai/gal_ai.dart';
import 'package:gal_protocol/gal_protocol.dart';
import 'package:test/test.dart';

/// 出口判定只有**一个实现**（[TargetRouter]），情景与事件共用：
///
/// 1. 自上而下轮询，**首个 `require` 成立的块被锁定**；
/// 2. 锁定后在该块的 `kind` 里**等概率**取一个（没有 weight 了）；
/// 3. 没有任何块成立（或压根没有块）→ 返回 null，调用方给「没有出口」的结果。
WorldSnapshot _world(Map<String, Object?> vars) => WorldSnapshot(
      variables: vars,
      characters: const {},
      eventHistory: const {},
      story: const {'day': 14},
      presentation: const {},
      rngState: 1,
    );

TargetBlock _block(List<Map<String, Object?>> kinds, {String? require}) =>
    TargetBlock.fromJson({
      if (require != null) 'require': require,
      'kind': kinds,
    });

Map<String, Object?> _t(String kind, String to) => {'kind': kind, 'to': to};

void main() {
  group('顺序与首命中', () {
    final router = TargetRouter();

    test('首个 require 成立的块被锁定，后面的块不再看', () {
      final blocks = [
        _block([
          _t('event', 'end_badend14'),
        ], require: '"day" == 14'),
        _block([
          _t('event', 'end_csrj'),
        ], require: '"day" == 14 & "戒戒堕落" <= 35'),
        _block([
          _t('story', '8-14day'),
        ]),
      ];
      // 两块都成立 → 必须是第一块
      expect(
        router.route(blocks, _world({'day': 14, '戒戒堕落': 0}), rngState: 1)!.to,
        'end_badend14',
      );
    });

    test('前面的块不成立才轮到后面', () {
      final blocks = [
        _block([
          _t('event', 'end_badend14'),
        ], require: '"戒戒好感" + "戒戒信任" < 120'),
        _block([
          _t('event', 'end_csrj'),
        ], require: '"day" == 14'),
        _block([
          _t('story', '8-14day'),
        ]),
      ];
      // 好感 70 + 信任 60 = 130 → 第一块不成立
      expect(
        router.route(
          blocks,
          _world({'day': 14, '戒戒好感': 70, '戒戒信任': 60}),
          rngState: 1,
        )!.to,
        'end_csrj',
      );
    });

    test('没写 require 的块无条件成立（当保底用）', () {
      final blocks = [
        _block([
          _t('story', 'nonexistent'),
        ], require: '"day" == 999'),
        _block([
          _t('story', 'fallback'),
        ]),
      ];
      final chosen = router.route(blocks, _world({'day': 1}), rngState: 1);
      expect(chosen!.to, 'fallback');
      expect(chosen.kind, 'story');
    });
  });

  group('没有出口', () {
    final router = TargetRouter();

    test('没有块 → null', () {
      expect(router.route(const [], _world({'day': 1}), rngState: 1), isNull);
    });

    test('所有块的 require 都不成立 → null（不是错误）', () {
      final blocks = [
        _block([
          _t('story', 'a'),
        ], require: '"day" == 1'),
        _block([
          _t('story', 'b'),
        ], require: '"好好感" > 999'),
      ];
      expect(router.route(blocks, _world({'day': 14}), rngState: 1), isNull);
    });

    test('没有 target 的情景也能安全判定（空列表）', () {
      final scene = SceneDef.fromJson(const {'displayName': 'x'}, id: 'x');
      expect(scene.target, isEmpty);
      expect(router.route(scene.target, _world({}), rngState: 1), isNull);
    });
  });

  group('块内等概率', () {
    test('两个目的地都会出现（同一 rng 顺序里可回放）', () {
      final router = TargetRouter();
      final block = [
        _block([
          _t('story', 'endless_human_night'),
          _t('story', 'endless_human_afternoon_special'),
        ]),
      ];
      final counts = <String, int>{};
      for (var seed = 1; seed <= 64; seed++) {
        final chosen = router.route(block, _world({'day': 40}), rngState: seed);
        counts[chosen!.to] = (counts[chosen.to] ?? 0) + 1;
      }
      expect(
        counts.keys,
        containsAll(['endless_human_night', 'endless_human_afternoon_special']),
        reason: '「加权随机永不生效」是历史 bug：两条分支都必须真的出现',
      );
      // 等概率：64 次里两边都不该是极少数
      expect(counts['endless_human_night']!, greaterThan(16));
      expect(counts['endless_human_afternoon_special']!, greaterThan(16));
    });

    test('同一个 rngState 回放结果一致（存档可复现）', () {
      final router = TargetRouter();
      final block = [
        _block([
          _t('story', 'a'),
          _t('story', 'b'),
          _t('story', 'c'),
        ]),
      ];
      final first = router.route(block, _world({}), rngState: 7);
      for (var i = 0; i < 5; i++) {
        expect(router.route(block, _world({}), rngState: 7)!.to, first!.to);
      }
    });

    test('三个目的地各占约 1/3', () {
      final router = TargetRouter();
      final block = [
        _block([
          _t('story', 'a'),
          _t('story', 'b'),
          _t('story', 'c'),
        ]),
      ];
      final counts = <String, int>{};
      for (var seed = 1; seed <= 90; seed++) {
        final to = router.route(block, _world({}), rngState: seed)!.to;
        counts[to] = (counts[to] ?? 0) + 1;
      }
      expect(counts.keys.toSet(), {'a', 'b', 'c'});
      for (final n in counts.values) {
        expect(n, greaterThan(15), reason: '90 次三等分，每支都该在 30 上下');
      }
    });

    test('两个目的地指向同一目标 = 2/3', () {
      final router = TargetRouter();
      final block = [
        _block([
          _t('story', 'night'),
          _t('story', 'special'),
          _t('story', 'night'),
        ]),
      ];
      var night = 0;
      for (var seed = 1; seed <= 60; seed++) {
        if (router.route(block, _world({}), rngState: seed)!.to == 'night') {
          night++;
        }
      }
      expect(night, greaterThan(20), reason: '两个 kind 指向同一目标就该更常出现');
    });
  });

  group('条件的容错', () {
    test('require 里的变量取不到值时按 0 处理，不抛异常', () {
      final router = TargetRouter();
      final blocks = [
        _block([
          _t('story', 'a'),
        ], require: '"从未注册" > 0'),
        _block([
          _t('story', 'b'),
        ], require: '"从未注册" == 0'),
      ];
      expect(router.route(blocks, _world({'day': 1}), rngState: 1)!.to, 'b');
    });

    test('同一个 require 文案只解析一次（重复判定不会抛第二次）', () {
      final router = TargetRouter();
      final blocks = [
        _block([
          _t('story', 'a'),
        ], require: '"day" == 14'),
      ];
      expect(router.matches(blocks.first, _world({'day': 14})), isTrue);
      expect(router.matches(blocks.first, _world({'day': 1})), isFalse);
    });
  });
}
