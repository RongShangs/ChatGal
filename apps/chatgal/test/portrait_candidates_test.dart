import 'package:chatgal/app/app_services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('portraitCandidates', () {
    test('exact name from the model wins', () {
      final c = portraitCandidates(
        state: '校服',
        requested: '校服_开心',
        defaultEmotion: '平常',
        defaultState: '校服',
      );
      expect(c.first, '校服_开心');
    });

    test('an emotion word is composed with the scene-locked state', () {
      final c = portraitCandidates(
        state: '校服猫化',
        requested: '开心',
        defaultEmotion: '平常',
        defaultState: '校服',
      );
      // 场景锁定猫化形态 → 优先用「校服猫化_开心」，而不是默认状态的立绘
      expect(c, contains('校服猫化_开心'));
      expect(c.indexOf('校服猫化_开心'), lessThan(c.indexOf('校服_开心')));
    });

    test('nothing usable falls back to scene state + default emotion', () {
      final c = portraitCandidates(
        state: '睡裙',
        requested: '',
        defaultEmotion: '平常',
        defaultState: '校服',
      );
      expect(c.first, '睡裙_平常');
      // 最后一级兜底永远是「默认状态_默认表情」，所以绝不会解析不到
      expect(c.last, '校服_平常');
    });

    test('an off-list answer still gets a sane default (no guessing)', () {
      final c = portraitCandidates(
        state: '便服',
        requested: '狂喜',
        defaultEmotion: '平常',
        defaultState: '校服',
      );
      expect(c.first, '狂喜');
      expect(c, contains('便服_狂喜'));
      expect(c.last, '校服_平常');
    });

    test('带修饰的词按包内情绪词包含匹配（否则全都落到默认图）', () {
      final c = portraitCandidates(
        state: '校服',
        requested: '有点害羞',
        defaultEmotion: '平常',
        defaultState: '校服',
        emotions: const ['平常', '开心', '害羞', '生气'],
      );
      expect(c, contains('校服_害羞'));
      expect(c.indexOf('校服_害羞'), lessThan(c.indexOf('校服_平常')));
    });
  });
}
