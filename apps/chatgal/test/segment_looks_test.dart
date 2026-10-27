import 'package:chatgal/app/app_services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 立绘选择校验（复审重点）：
/// * 每一段都要落到**本幕立绘表里真实存在**的一张上；
/// * 分级清楚：逐字命中 / 仅情绪可映射 / 场景默认兜底 / 保持当前；
/// * **不再轮换换脸**——模型持续不合规时用稳定兜底，并给出可诊断的信息。
void main() {
  const options = [
    '便服_平常',
    '便服_开心',
    '便服_伤心',
    '便服_害羞',
    '便服_生气',
  ];
  const emotions = ['平常', '开心', '伤心', '害羞', '生气'];

  group('resolveSegmentLooks', () {
    test('模型逐字给了立绘名 → exact', () {
      final looks = resolveSegmentLooks(
        segments: const [(expression: '开心', portrait: '便服_开心')],
        portraitOptions: options,
        emotions: emotions,
        current: '平常',
      );
      expect(looks.single.portrait, '便服_开心');
      expect(looks.single.expression, '开心');
      expect(looks.single.fromModel, isTrue);
      expect(looks.single.quality, LookQuality.exact);
      expect(looks.single.degraded, isFalse);
    });

    test('只给了情绪词 → 映射到本幕同一情绪的那张（emotionMapped）', () {
      final looks = resolveSegmentLooks(
        segments: const [(expression: '害羞', portrait: '')],
        portraitOptions: options,
        emotions: emotions,
        current: '平常',
      );
      expect(looks.single.portrait, '便服_害羞');
      expect(looks.single.fromModel, isTrue);
      expect(looks.single.quality, LookQuality.emotionMapped);
      expect(looks.single.degraded, isFalse);
    });

    test('情绪词带修饰（有点害羞）也能对上包内情绪', () {
      final looks = resolveSegmentLooks(
        segments: const [(expression: '', portrait: '有点害羞')],
        portraitOptions: options,
        emotions: emotions,
        current: '平常',
      );
      expect(looks.single.portrait, '便服_害羞');
    });

    test('什么都没给 → 稳定兜底到场景默认表情，不再轮换换脸', () {
      final looks = resolveSegmentLooks(
        segments: const [
          (expression: '', portrait: ''),
          (expression: 'default', portrait: ''),
          (expression: '不认识的表情', portrait: '不存在的立绘'),
        ],
        portraitOptions: options,
        emotions: emotions,
        defaultEmotion: '伤心',
        current: '开心',
      );
      expect(looks.every((l) => l.degraded), isTrue);
      expect(looks.every((l) => l.fromModel), isFalse);
      // 三段都是同一个场景默认表情：**不换脸**，而不是按顺序轮一圈。
      expect(looks.map((l) => l.portrait).toList(),
          ['便服_伤心', '便服_伤心', '便服_伤心']);
      expect(looks.every((l) => l.quality == LookQuality.sceneDefault), isTrue);
      // 兜底也只在包内声明的立绘里选，不会自造
      expect(looks.every((l) => options.contains(l.portrait)), isTrue);
    });

    test('连场景默认都没有 → 保持当前这张脸（keptCurrent）', () {
      final looks = resolveSegmentLooks(
        segments: const [(expression: '', portrait: '')],
        portraitOptions: const [],
        emotions: const [],
        current: '开心',
      );
      expect(looks.single.quality, LookQuality.keptCurrent);
      expect(looks.single.expression, '开心');
      expect(looks.single.portrait, '');
    });

    test('错误服装 / 未知名字都不能越过候选表', () {
      final looks = resolveSegmentLooks(
        // 别的形态（睡裙）下的立绘、以及编造的名字，都不该被直接采用。
        segments: const [
          (expression: '', portrait: '睡裙_开心'),
          (expression: '', portrait: '便服_不存在'),
          (expression: '', portrait: '随便编一张'),
        ],
        portraitOptions: options,
        emotions: emotions,
        defaultEmotion: '平常',
        current: '平常',
      );
      // 铁律：**落地的立绘一律来自本幕候选表**，模型给的原字符串一个都不采用。
      expect(looks.every((l) => options.contains(l.portrait)), isTrue);
      expect(looks.any((l) => l.portrait == '睡裙_开心'), isFalse);
      expect(looks.any((l) => l.portrait == '便服_不存在'), isFalse);
      // 情绪能从名字里认出来（睡裙_开心 → 开心）→ 用本幕同情绪的图，换掉错形态；
      // 完全认不出的两条走场景默认兜底。
      expect(looks[0].quality, LookQuality.emotionMapped);
      expect(looks[0].portrait, '便服_开心');
      expect(looks[1].degraded, isTrue);
      expect(looks[2].degraded, isTrue);
    });

    test('没有立绘表（场景没声明形态）时不会崩，只留情绪标签', () {
      final looks = resolveSegmentLooks(
        segments: const [(expression: '开心', portrait: '便服_开心')],
        portraitOptions: const [],
        emotions: emotions,
        current: '平常',
      );
      expect(looks.single.portrait, '');
      expect(looks.single.expression, '开心');
    });
  });

  group('describeLookDiagnostics', () {
    test('把原始响应形态、逐段字段、词表和分级都写出来', () {
      final segs = const [
        (expression: 'default', portrait: ''),
      ];
      final looks = resolveSegmentLooks(
        segments: segs,
        portraitOptions: options,
        emotions: emotions,
        defaultEmotion: '平常',
        current: '平常',
      );
      final text = describeLookDiagnostics(
        segments: segs,
        looks: looks,
        portraitOptions: options,
        emotions: emotions,
        state: '便服',
        current: '平常',
        rawText: '你回来啦。',
      );
      // 原始响应：模型到底回了什么，是排查的第一手证据
      expect(text, contains('你回来啦。'));
      expect(text, contains('非 JSON'));
      expect(text, contains('段数=1'));
      expect(text, contains('兜底段数=1'));
      expect(text, contains('当前形态=「便服」'));
      expect(text, contains('portraitId=「」'));
      expect(text, contains('expressionId=「default」'));
      expect(text, contains('便服_平常'));
    });

    test('超长响应只留前 160 字，不把日志冲爆', () {
      final text = describeLookDiagnostics(
        segments: const [(expression: '', portrait: '')],
        looks: const [],
        portraitOptions: options,
        emotions: emotions,
        state: '',
        current: '',
        rawText: 'x' * 400,
      );
      expect(text, contains('…'));
      expect(text.length, lessThan(600));
    });
  });
}
